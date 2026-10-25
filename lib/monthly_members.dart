// ============================================================
// Monthly Member Contribution Management (Super Admin only).
//
// Community members (not students, not app users - no login) who pay an
// ongoing monthly contribution to the Maktab. This file holds the
// Supabase wiring (public.monthly_members / monthly_dues /
// monthly_payments / monthly_notifications / monthly_reminder_schedule -
// see migration monthly_members_module for the full schema, RLS and
// SECURITY DEFINER functions, and Edge Functions send-monthly-notification
// / monthly-dues-cron for the WhatsApp/SMS side) plus every screen for it.
// ============================================================
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

import 'state.dart';
import 'main.dart';

// ============================================================
// Loading
// ============================================================

Future<void> loadMonthlyMembers() async {
  try {
    final rows = await sb.from('monthly_members').select().order('full_name');
    st.setMonthlyMembersFromDb([for (final r in (rows as List)) MonthlyMember.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {}
  try {
    final rows = await sb.from('monthly_dues').select();
    st.setMonthlyDuesFromDb([for (final r in (rows as List)) MonthlyDue.fromJson(r as Map<String, dynamic>)]);
  } catch (_) {}
}

Future<List<MonthlyPayment>> loadPaymentsForDue(String dueId) async {
  try {
    final rows = await sb.from('monthly_payments').select().eq('due_id', dueId).order('paid_at');
    return [for (final r in (rows as List)) MonthlyPayment.fromJson(r as Map<String, dynamic>)];
  } catch (_) {
    return [];
  }
}

Future<List<MonthlyNotificationLog>> loadNotificationsForMember(String memberId) async {
  try {
    final rows = await sb.from('monthly_notifications').select().eq('member_id', memberId).order('created_at', ascending: false);
    return [for (final r in (rows as List)) MonthlyNotificationLog.fromJson(r as Map<String, dynamic>)];
  } catch (_) {
    return [];
  }
}

Future<List<MonthlyNotificationLog>> loadAllNotifications() async {
  try {
    final rows = await sb.from('monthly_notifications').select().order('created_at', ascending: false).limit(200);
    return [for (final r in (rows as List)) MonthlyNotificationLog.fromJson(r as Map<String, dynamic>)];
  } catch (_) {
    return [];
  }
}

// ============================================================
// Member CRUD
// ============================================================

Future<String?> addMonthlyMemberRemote({
  required String name,
  required String phone,
  required double amount,
  required String joiningDate,
  String? address,
  String? remarks,
}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter the member\'s name';
  final p = digits(phone);
  if (p.length != 10) return 'Enter a 10-digit mobile number';
  if (amount <= 0) return 'Enter a monthly contribution amount greater than 0';
  if (!validDate(joiningDate)) return 'Pick a joining date';
  try {
    final row = await sb
        .from('monthly_members')
        .insert({
          'full_name': n,
          'phone': p,
          'monthly_amount': amount,
          'joining_date': joiningDate,
          'address': (address?.trim().isEmpty ?? true) ? null : address!.trim(),
          'remarks': (remarks?.trim().isEmpty ?? true) ? null : remarks!.trim(),
          'created_by': sb.auth.currentUser?.id,
        })
        .select('id')
        .single();
    final memberId = row['id'] as String;
    // Back-fills every month's due from the joining month through the
    // current month, so the new member immediately has their full history
    // of dues rather than waiting for the next 1st-of-month cron run.
    await sb.rpc('generate_member_dues_catchup', params: {'p_member_id': memberId});
    await loadMonthlyMembers();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '23505') return 'A member with this mobile number already exists.';
    if (e.code == '42501') return 'Only a Super Admin can add a member.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> editMonthlyMemberRemote({
  required MonthlyMember member,
  required String name,
  required double amount,
  String? address,
  String? remarks,
}) async {
  final n = name.trim();
  if (n.isEmpty) return 'Enter the member\'s name';
  if (amount <= 0) return 'Enter a monthly contribution amount greater than 0';
  try {
    await sb.from('monthly_members').update({
      'full_name': n,
      'monthly_amount': amount,
      'address': (address?.trim().isEmpty ?? true) ? null : address!.trim(),
      'remarks': (remarks?.trim().isEmpty ?? true) ? null : remarks!.trim(),
      'updated_by': sb.auth.currentUser?.id,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', member.id);
    await loadMonthlyMembers();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can edit a member.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Activate/deactivate - never deletes, so every past due and payment stays
// exactly as it was (spec: preserve historical payments when deactivated).
Future<String?> setMonthlyMemberActiveRemote(MonthlyMember member, bool active) async {
  try {
    await sb.from('monthly_members').update({
      'is_active': active,
      'updated_by': sb.auth.currentUser?.id,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', member.id);
    await loadMonthlyMembers();
    return null;
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

// Manual "Generate this month's dues now" - the same thing the daily cron
// does automatically on the 1st, exposed here so Super Admin can run it on
// demand (handy right after adding members, or while testing) instead of
// waiting for the schedule.
Future<String?> generateThisMonthDuesRemote() async {
  final now = DateTime.now();
  try {
    await sb.rpc('generate_month_dues_all', params: {'p_year': now.year, 'p_month': now.month});
    await loadMonthlyMembers();
    return null;
  } on PostgrestException catch (e) {
    return 'Could not generate: ${e.message}';
  } catch (_) {
    return 'Could not generate. Check your internet connection and try again.';
  }
}

// ============================================================
// Payments - idempotent, trigger-recalculated balance
// ============================================================

String _newIdempotencyKey() => '${st.user?.dbId ?? 'anon'}-${DateTime.now().microsecondsSinceEpoch}';

class RecordPaymentResult {
  final MonthlyPayment? payment;
  final String? error;
  const RecordPaymentResult({this.payment, this.error});
}

Future<RecordPaymentResult> recordMonthlyPaymentRemote({
  required MonthlyDue due,
  required double amount,
  required String method,
  String? txnRef,
  String? remarks,
}) async {
  if (amount <= 0) return const RecordPaymentResult(error: 'Enter an amount greater than 0');
  if (amount > due.outstanding + 0.01) {
    return RecordPaymentResult(error: 'That is more than the outstanding balance of Rs.${due.outstanding.toStringAsFixed(0)} for this month.');
  }
  try {
    final row = await sb
        .from('monthly_payments')
        .insert({
          'due_id': due.id,
          'member_id': due.memberId,
          'amount': amount,
          'method': method,
          'txn_ref': (txnRef?.trim().isEmpty ?? true) ? null : txnRef!.trim(),
          'remarks': (remarks?.trim().isEmpty ?? true) ? null : remarks!.trim(),
          'recorded_by': sb.auth.currentUser?.id,
          'idempotency_key': _newIdempotencyKey(),
        })
        .select()
        .single();
    final payment = MonthlyPayment.fromJson(row);
    // The AFTER INSERT trigger on monthly_payments already recalculated
    // amount_paid/status for this due server-side - just re-pull it so the
    // UI reflects the real, trigger-computed balance rather than a
    // client-side guess.
    await loadMonthlyMembers();
    // Fire-and-forget: the receipt is already final regardless of whether
    // the WhatsApp/SMS send succeeds - it logs its own outcome.
    unawaited(sb.functions.invoke('send-monthly-notification', body: {'notif_type': 'payment_received', 'payment_id': payment.id}));
    return RecordPaymentResult(payment: payment);
  } on PostgrestException catch (e) {
    if (e.code == '23505') {
      // Idempotency key collision - a retried/duplicate submit, not a new payment.
      return const RecordPaymentResult(error: 'This payment was already recorded.');
    }
    if (e.code == '42501') return const RecordPaymentResult(error: 'Only a Super Admin can record a payment.');
    return RecordPaymentResult(error: 'Could not save: ${e.message}');
  } catch (_) {
    return const RecordPaymentResult(error: 'Could not save. Check your internet connection and try again.');
  }
}

Future<Map<String, dynamic>?> retryMonthlyNotification({String? paymentId, String? dueId}) async {
  try {
    final body = paymentId != null ? {'notif_type': 'payment_received', 'payment_id': paymentId} : {'notif_type': 'due_reminder', 'due_id': dueId};
    final res = await sb.functions.invoke('send-monthly-notification', body: body);
    return (res.data as Map?)?.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> runDuesCronNowRemote() async {
  try {
    final res = await sb.functions.invoke('monthly-dues-cron');
    await loadMonthlyMembers();
    return (res.data as Map?)?.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
}

// ============================================================
// Reminder schedule (extra dates beyond the built-in 1st-of-month default)
// ============================================================

Future<List<int>> loadReminderScheduleDays() async {
  try {
    final rows = await sb.from('monthly_reminder_schedule').select('reminder_day').eq('is_active', true).order('reminder_day');
    return [for (final r in (rows as List)) r['reminder_day'] as int];
  } catch (_) {
    return [];
  }
}

Future<String?> addReminderDayRemote(int day) async {
  if (day < 1 || day > 28) return 'Pick a day between 1 and 28';
  try {
    await sb.from('monthly_reminder_schedule').upsert({'reminder_day': day, 'is_active': true, 'created_by': sb.auth.currentUser?.id});
    return null;
  } on PostgrestException catch (e) {
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<void> removeReminderDayRemote(int day) async {
  try {
    await sb.from('monthly_reminder_schedule').delete().eq('reminder_day', day);
  } catch (_) {}
}

// ============================================================
// CSV export (mirrors the student-import CSV convention already in main.dart)
// ============================================================

Future<void> exportMonthlyReportCsv(BuildContext context, int year, int month) async {
  final dues = st.monthlyDues.where((d) => d.year == year && d.month == month).toList();
  final rows = <List<String>>[
    ['Member', 'Phone', 'Amount Due', 'Amount Paid', 'Outstanding', 'Status'],
    for (final d in dues)
      [
        st.monthlyMemberById(d.memberId)?.fullName ?? '',
        st.monthlyMemberById(d.memberId)?.phone ?? '',
        d.amountDue.toStringAsFixed(0),
        d.amountPaid.toStringAsFixed(0),
        d.outstanding.toStringAsFixed(0),
        d.displayStatus,
      ],
  ];
  final csv = const ListToCsvConverter().convert(rows);
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/monthly_report_${year}_$month.csv');
    await file.writeAsString(csv);
    await Share.shareXFiles([XFile(file.path)], text: 'Monthly Members report - ${AppState.kMonthAbbrevs[month - 1]} $year');
  } catch (_) {
    if (context.mounted) toast(context, 'Could not export. Check storage/share permissions.');
  }
}

// ============================================================
// UI - shared bits
// ============================================================

Color monthlyStatusColor(String displayStatus) {
  switch (displayStatus) {
    case 'Paid':
      return const Color(0xFF2E7D32); // green
    case 'Partially Paid':
      return const Color(0xFFEF6C00); // orange
    case 'Overdue':
    case 'Due':
      return const Color(0xFFC62828); // red
    default:
      return Colors.grey;
  }
}

Widget monthlyStatusChip(String displayStatus) => Chip(
      label: Text(displayStatus, style: const TextStyle(color: Colors.white, fontSize: 12)),
      backgroundColor: monthlyStatusColor(displayStatus),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

// ============================================================
// Sub-dashboard entry point (the "Monthly Members" dashboard icon opens this)
// ============================================================

class MonthlyMembersDashboard extends StatefulWidget {
  const MonthlyMembersDashboard({super.key});
  @override
  State<MonthlyMembersDashboard> createState() => _MonthlyMembersDashboardState();
}

class _MonthlyMembersDashboardState extends State<MonthlyMembersDashboard> {
  @override
  void initState() {
    super.initState();
    loadMonthlyMembers();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: st,
        builder: (context, _) {
          final now = DateTime.now();
          final activeMembers = st.monthlyMembers.where((m) => m.isActive).length;
          final curDues = st.monthlyDues.where((d) => d.year == now.year && d.month == now.month).toList();
          final expected = curDues.fold<double>(0, (a, d) => a + d.amountDue);
          final received = curDues.fold<double>(0, (a, d) => a + d.amountPaid);
          final outstanding = curDues.fold<double>(0, (a, d) => a + d.outstanding);
          final paidCount = curDues.where((d) => d.status == 'complete').length;
          final partialCount = curDues.where((d) => d.status == 'part_paid').length;
          final pendingCount = curDues.where((d) => d.status == 'due' || d.status == 'overdue').length;

          return page([
            h('Monthly Members', icon: Icons.volunteer_activism),
            const Text('Members who pay an ongoing monthly contribution to the Maktab - powered by Faiz-E-Raza Group Mehkar.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
            const SizedBox(height: 8),
            grid([
              tile('Total active members', '$activeMembers', icon: Icons.groups),
              tile('Expected this month', 'Rs.${expected.toStringAsFixed(0)}', icon: Icons.payments),
              tile('Received this month', 'Rs.${received.toStringAsFixed(0)}', icon: Icons.check_circle, color: const Color(0xFFDFF3DA)),
              tile('Outstanding this month', 'Rs.${outstanding.toStringAsFixed(0)}', icon: Icons.error_outline, color: const Color(0xFFFFE3E0)),
              tile('Paid', '$paidCount', icon: Icons.done_all),
              tile('Partially paid', '$partialCount', icon: Icons.incomplete_circle),
              tile('Pending/overdue', '$pendingCount', icon: Icons.warning_amber),
            ]),
            h('Manage', icon: Icons.menu),
            // These push their own Scaffold+AppBar (an Add FAB, an export
            // icon, etc. - which pushPage's fixed AppBar has no room for),
            // so they're pushed directly rather than through pushPage,
            // same as SadqaCollectionScreen elsewhere in this app.
            Card(child: ListTile(leading: const Icon(Icons.people), title: const Text('Member List'), subtitle: const Text('Add, edit, search, activate/deactivate'), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MonthlyMemberListView())))),
            Card(child: ListTile(leading: const Icon(Icons.bar_chart), title: const Text('Monthly Due Report'), subtitle: const Text('Member-wise, with month/year filter and CSV export'), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MonthlyDueReportView())))),
            Card(child: ListTile(leading: const Icon(Icons.notifications), title: const Text('Payment & Notification History'), subtitle: const Text('Every receipt and reminder sent, with retry'), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MonthlyNotificationHistoryView())))),
            Card(child: ListTile(leading: const Icon(Icons.schedule), title: const Text('Reminder Schedule'), subtitle: const Text('The 1st of every month, plus any extra dates you add'), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MonthlyReminderScheduleView())))),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.auto_mode),
                  label: const Text('Generate this month\'s dues'),
                  onPressed: () async {
                    final e = await generateThisMonthDuesRemote();
                    if (!context.mounted) return;
                    toast(context, e ?? 'Done - every active member now has a due record for this month.');
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Run reminders now'),
                  onPressed: () async {
                    final res = await runDuesCronNowRemote();
                    if (!context.mounted) return;
                    toast(context, res == null ? 'Could not run. Check your internet connection.' : 'Ran the daily job now - ${res['reminders_attempted'] ?? 0} reminder(s) attempted.');
                  },
                ),
              ),
            ]),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'A daily job already does this automatically (dues generation on the 1st, overdue rollover, and reminders) - these buttons just let you run it on demand, handy while testing.',
                style: TextStyle(color: Colors.black54, fontSize: 11.5),
              ),
            ),
          ]);
        },
      );
}

// ============================================================
// Member List - search, filter, add
// ============================================================

class MonthlyMemberListView extends StatefulWidget {
  const MonthlyMemberListView({super.key});
  @override
  State<MonthlyMemberListView> createState() => _MonthlyMemberListViewState();
}

class _MonthlyMemberListViewState extends State<MonthlyMemberListView> {
  final search = TextEditingController();
  String filter = 'All'; // All | Active | Inactive | Paid | Due

  @override
  void initState() {
    super.initState();
    search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  MonthlyDue? _currentDue(String memberId) {
    final now = DateTime.now();
    for (final d in st.monthlyDues) {
      if (d.memberId == memberId && d.year == now.year && d.month == now.month) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: st,
        builder: (context, _) {
          final q = search.text.trim().toLowerCase();
          var list = st.monthlyMembers.where((m) {
            if (q.isNotEmpty && !m.fullName.toLowerCase().contains(q) && !m.phone.contains(q)) return false;
            switch (filter) {
              case 'Active':
                return m.isActive;
              case 'Inactive':
                return !m.isActive;
              case 'Paid':
                return _currentDue(m.id)?.status == 'complete';
              case 'Due':
                final s = _currentDue(m.id)?.status;
                return s == 'due' || s == 'overdue' || s == 'part_paid';
              default:
                return true;
            }
          }).toList()
            ..sort((a, b) => a.fullName.compareTo(b.fullName));

          return Scaffold(
            appBar: AppBar(title: const Text('Monthly Members')),
            floatingActionButton: FloatingActionButton(
              onPressed: () => _openAddEdit(context),
              child: const Icon(Icons.add),
            ),
            body: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                field(search, 'Search by name or mobile number'),
                Wrap(spacing: 6, children: [
                  for (final f in const ['All', 'Active', 'Inactive', 'Paid', 'Due'])
                    FilterChip(label: Text(f), selected: filter == f, onSelected: (_) => setState(() => filter = f)),
                ]),
                const SizedBox(height: 8),
                if (list.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No members match.')),
                for (final m in list)
                  Card(
                    child: ListTile(
                      title: Text(m.fullName),
                      subtitle: Text('${m.phone} - Rs.${m.monthlyAmount.toStringAsFixed(0)}/month${m.isActive ? '' : ' - Inactive'}'),
                      trailing: _currentDue(m.id) != null ? monthlyStatusChip(_currentDue(m.id)!.displayStatus) : null,
                      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MonthlyMemberDetailView(memberId: m.id))),
                    ),
                  ),
              ],
            ),
          );
        },
      );

  void _openAddEdit(BuildContext context) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final amount = TextEditingController();
    final address = TextEditingController();
    final remarks = TextEditingController();
    final joining = TextEditingController(text: kToday);
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add member'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 8),
              TextField(controller: phone, decoration: const InputDecoration(labelText: 'Mobile number'), keyboardType: TextInputType.phone),
              const SizedBox(height: 8),
              TextField(controller: amount, decoration: const InputDecoration(labelText: 'Monthly contribution (Rs.)'), keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () async {
                  final picked = await showDatePicker(context: ctx, initialDate: pd(joining.text), firstDate: DateTime(2015, 1, 1), lastDate: DateTime.now());
                  if (picked != null) setD(() => joining.text = fd(picked));
                },
                child: AbsorbPointer(child: TextField(controller: joining, decoration: const InputDecoration(labelText: 'Joining date (tap to pick)'))),
              ),
              const SizedBox(height: 8),
              TextField(controller: address, decoration: const InputDecoration(labelText: 'Address (optional)')),
              const SizedBox(height: 8),
              TextField(controller: remarks, decoration: const InputDecoration(labelText: 'Remarks (optional)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setD(() => busy = true);
                      final e = await addMonthlyMemberRemote(
                        name: name.text,
                        phone: phone.text,
                        amount: double.tryParse(amount.text) ?? 0,
                        joiningDate: joining.text,
                        address: address.text,
                        remarks: remarks.text,
                      );
                      if (!ctx.mounted) return;
                      setD(() => busy = false);
                      if (e != null) {
                        toast(ctx, e);
                        return;
                      }
                      Navigator.pop(ctx);
                      if (context.mounted) toast(context, 'Member added.');
                    },
              child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Member Detail - info, edit, activate/deactivate, dues & payments
// ============================================================

class MonthlyMemberDetailView extends StatefulWidget {
  final String memberId;
  const MonthlyMemberDetailView({super.key, required this.memberId});
  @override
  State<MonthlyMemberDetailView> createState() => _MonthlyMemberDetailViewState();
}

class _MonthlyMemberDetailViewState extends State<MonthlyMemberDetailView> {
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: st,
        builder: (context, _) {
          final m = st.monthlyMemberById(widget.memberId);
          if (m == null) return const Scaffold(body: Center(child: Text('Member not found.')));
          final dues = st.duesForMember(m.id).reversed.toList(); // most recent month first

          return Scaffold(
            appBar: AppBar(title: Text(m.fullName), actions: [
              IconButton(icon: const Icon(Icons.edit), onPressed: () => _openEdit(context, m)),
              IconButton(icon: const Icon(Icons.history), tooltip: 'Notification history', onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MonthlyMemberNotificationsView(memberId: m.id, memberName: m.fullName)))),
            ]),
            body: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.fullName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('Mobile: ${m.phone}'),
                      Text('Monthly contribution: Rs.${m.monthlyAmount.toStringAsFixed(0)}'),
                      Text('Joined: ${nice(m.joiningDate)}'),
                      if (m.address != null && m.address!.isNotEmpty) Text('Address: ${m.address}'),
                      if (m.remarks != null && m.remarks!.isNotEmpty) Text('Remarks: ${m.remarks}'),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: Icon(m.isActive ? Icons.block : Icons.check_circle_outline),
                        label: Text(m.isActive ? 'Deactivate member' : 'Activate member'),
                        onPressed: () async {
                          if (m.isActive) {
                            final ok = await confirmDialog(context, 'Deactivate ${m.fullName}?', 'They will stop getting new monthly dues and reminders. All past payments and history stay exactly as they are.', confirmLabel: 'Deactivate');
                            if (!ok) return;
                          }
                          if (!context.mounted) return;
                          final e = await setMonthlyMemberActiveRemote(m, !m.isActive);
                          if (!context.mounted) return;
                          toast(context, e ?? (m.isActive ? 'Deactivated.' : 'Activated.'));
                        },
                      ),
                    ]),
                  ),
                ),
                h('Monthly dues', icon: Icons.calendar_month),
                if (dues.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No due records yet.')),
                for (final d in dues)
                  Card(
                    child: ListTile(
                      title: Text(d.monthLabel),
                      subtitle: Text('Due Rs.${d.amountDue.toStringAsFixed(0)} - Paid Rs.${d.amountPaid.toStringAsFixed(0)} - Outstanding Rs.${d.outstanding.toStringAsFixed(0)}'),
                      trailing: monthlyStatusChip(d.displayStatus),
                      onTap: () => _openDueDetail(context, m, d),
                    ),
                  ),
              ],
            ),
          );
        },
      );

  void _openEdit(BuildContext context, MonthlyMember m) async {
    final name = TextEditingController(text: m.fullName);
    final amount = TextEditingController(text: m.monthlyAmount.toStringAsFixed(0));
    final address = TextEditingController(text: m.address ?? '');
    final remarks = TextEditingController(text: m.remarks ?? '');
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Edit member'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 8),
              TextField(controller: amount, decoration: const InputDecoration(labelText: 'Monthly contribution (Rs.)'), keyboardType: TextInputType.number),
              const Padding(padding: EdgeInsets.only(top: 4), child: Text('A new amount only applies to months generated from now on - past and current months already due keep their original amount.', style: TextStyle(color: Colors.black54, fontSize: 11.5))),
              const SizedBox(height: 8),
              TextField(controller: address, decoration: const InputDecoration(labelText: 'Address (optional)')),
              const SizedBox(height: 8),
              TextField(controller: remarks, decoration: const InputDecoration(labelText: 'Remarks (optional)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setD(() => busy = true);
                      final e = await editMonthlyMemberRemote(member: m, name: name.text, amount: double.tryParse(amount.text) ?? 0, address: address.text, remarks: remarks.text);
                      if (!ctx.mounted) return;
                      setD(() => busy = false);
                      if (e != null) {
                        toast(ctx, e);
                        return;
                      }
                      Navigator.pop(ctx);
                      if (context.mounted) toast(context, 'Saved.');
                    },
              child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _openDueDetail(BuildContext context, MonthlyMember m, MonthlyDue d) async {
    final payments = await loadPaymentsForDue(d.id);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, scroll) => Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: scroll,
            children: [
              Text(d.monthLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              monthlyStatusChip(d.displayStatus),
              const SizedBox(height: 8),
              Text('Amount due: Rs.${d.amountDue.toStringAsFixed(0)}'),
              Text('Amount paid: Rs.${d.amountPaid.toStringAsFixed(0)}'),
              Text('Outstanding: Rs.${d.outstanding.toStringAsFixed(0)}'),
              const SizedBox(height: 12),
              if (d.outstanding > 0)
                ElevatedButton.icon(
                  icon: const Icon(Icons.payments),
                  label: const Text('Record payment'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _openRecordPayment(context, m, d);
                  },
                ),
              const Divider(height: 24),
              const Text('Payment history', style: TextStyle(fontWeight: FontWeight.bold)),
              if (payments.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No installments recorded yet.')),
              for (final p in payments)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.receipt_long),
                  title: Text('Rs.${p.amount.toStringAsFixed(0)} - ${p.method}'),
                  subtitle: Text('${nice(p.paidAt.split('T').first)}${p.txnRef != null ? ' - Ref: ${p.txnRef}' : ''}${p.remarks != null ? ' - ${p.remarks}' : ''}'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openRecordPayment(BuildContext context, MonthlyMember m, MonthlyDue d) async {
    final amount = TextEditingController(text: d.outstanding.toStringAsFixed(0));
    final txnRef = TextEditingController();
    final remarks = TextEditingController();
    String method = 'cash';
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Record payment - ${d.monthLabel}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Outstanding: Rs.${d.outstanding.toStringAsFixed(0)}', style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 8),
              TextField(controller: amount, decoration: const InputDecoration(labelText: 'Amount received (Rs.)'), keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: method,
                decoration: const InputDecoration(labelText: 'Payment method', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'bank_transfer', child: Text('Bank Transfer')),
                  DropdownMenuItem(value: 'upi', child: Text('UPI')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => setD(() => method = v ?? method),
              ),
              const SizedBox(height: 8),
              TextField(controller: txnRef, decoration: const InputDecoration(labelText: 'Transaction / reference number (optional)')),
              const SizedBox(height: 8),
              TextField(controller: remarks, decoration: const InputDecoration(labelText: 'Remarks (optional)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setD(() => busy = true);
                      final res = await recordMonthlyPaymentRemote(due: d, amount: double.tryParse(amount.text) ?? 0, method: method, txnRef: txnRef.text, remarks: remarks.text);
                      if (!ctx.mounted) return;
                      setD(() => busy = false);
                      if (res.error != null) {
                        toast(ctx, res.error!);
                        return;
                      }
                      Navigator.pop(ctx);
                      if (context.mounted) toast(context, 'Payment recorded. A receipt notification is being sent.');
                    },
              child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save payment'),
            ),
          ],
        ),
      ),
    );
  }
}

// Per-member notification history (opened from the Member Detail app bar).
class MonthlyMemberNotificationsView extends StatefulWidget {
  final String memberId;
  final String memberName;
  const MonthlyMemberNotificationsView({super.key, required this.memberId, required this.memberName});
  @override
  State<MonthlyMemberNotificationsView> createState() => _MonthlyMemberNotificationsViewState();
}

class _MonthlyMemberNotificationsViewState extends State<MonthlyMemberNotificationsView> {
  List<MonthlyNotificationLog> logs = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await loadNotificationsForMember(widget.memberId);
    if (!mounted) return;
    setState(() {
      logs = l;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Notifications - ${widget.memberName}')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (logs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No notifications sent yet.')),
                  for (final l in logs) _notifRow(context, l, _load),
                ],
              ),
      );
}

Widget _notifRow(BuildContext context, MonthlyNotificationLog l, Future<void> Function() onRetried) => Card(
      child: ListTile(
        leading: Icon(l.status == 'Failed' ? Icons.error : l.status == 'Sent' || l.status == 'Delivered' ? Icons.check_circle : Icons.hourglass_empty, color: l.status == 'Failed' ? Colors.red : l.status == 'Pending' ? Colors.orange : Colors.green),
        title: Text(l.notifType == 'payment_receipt' ? 'Payment receipt' : 'Due reminder'),
        subtitle: Text('${l.channel} - ${l.status}${l.errorDetail != null ? ' - ${l.errorDetail}' : ''}\n${l.createdAt}', style: const TextStyle(fontSize: 11.5)),
        isThreeLine: l.errorDetail != null,
        trailing: l.status == 'Failed'
            ? TextButton(
                onPressed: () async {
                  final res = await retryMonthlyNotification(paymentId: l.paymentId, dueId: l.dueId);
                  if (context.mounted) toast(context, res == null ? 'Could not retry. Check your internet connection.' : 'Status: ${res['status'] ?? 'unknown'}');
                  await onRetried();
                },
                child: const Text('Retry'),
              )
            : null,
      ),
    );

// All-members notification log (opened from the module dashboard).
class MonthlyNotificationHistoryView extends StatefulWidget {
  const MonthlyNotificationHistoryView({super.key});
  @override
  State<MonthlyNotificationHistoryView> createState() => _MonthlyNotificationHistoryViewState();
}

class _MonthlyNotificationHistoryViewState extends State<MonthlyNotificationHistoryView> {
  List<MonthlyNotificationLog> logs = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await loadAllNotifications();
    if (!mounted) return;
    setState(() {
      logs = l;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Payment & Notification History')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (logs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No notifications sent yet.')),
                  for (final l in logs)
                    _notifRow(
                      context,
                      l,
                      _load,
                    ),
                ],
              ),
      );
}

// ============================================================
// Monthly Due Report - member-wise, month/year filter, CSV export
// ============================================================

class MonthlyDueReportView extends StatefulWidget {
  const MonthlyDueReportView({super.key});
  @override
  State<MonthlyDueReportView> createState() => _MonthlyDueReportViewState();
}

class _MonthlyDueReportViewState extends State<MonthlyDueReportView> {
  late int year = DateTime.now().year;
  late int month = DateTime.now().month;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: st,
        builder: (context, _) {
          final dues = st.monthlyDues.where((d) => d.year == year && d.month == month).toList()
            ..sort((a, b) => (st.monthlyMemberById(a.memberId)?.fullName ?? '').compareTo(st.monthlyMemberById(b.memberId)?.fullName ?? ''));
          final totalDue = dues.fold<double>(0, (a, d) => a + d.amountDue);
          final totalPaid = dues.fold<double>(0, (a, d) => a + d.amountPaid);

          return Scaffold(
            appBar: AppBar(title: const Text('Monthly Due Report'), actions: [
              IconButton(icon: const Icon(Icons.share), tooltip: 'Export CSV', onPressed: () => exportMonthlyReportCsv(context, year, month)),
            ]),
            body: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: month,
                      decoration: const InputDecoration(labelText: 'Month', border: OutlineInputBorder()),
                      items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(AppState.kMonthAbbrevs[m - 1]))],
                      onChanged: (v) => setState(() => month = v ?? month),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      value: year,
                      decoration: const InputDecoration(labelText: 'Year', border: OutlineInputBorder()),
                      items: [for (var y = DateTime.now().year - 3; y <= DateTime.now().year + 1; y++) DropdownMenuItem(value: y, child: Text('$y'))],
                      onChanged: (v) => setState(() => year = v ?? year),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Text('Expected: Rs.${totalDue.toStringAsFixed(0)}   Received: Rs.${totalPaid.toStringAsFixed(0)}   Outstanding: Rs.${(totalDue - totalPaid).toStringAsFixed(0)}'))),
                const SizedBox(height: 8),
                if (dues.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No due records for this month yet.')),
                for (final d in dues)
                  Card(
                    child: ListTile(
                      title: Text(st.monthlyMemberById(d.memberId)?.fullName ?? ''),
                      subtitle: Text('Due Rs.${d.amountDue.toStringAsFixed(0)} - Paid Rs.${d.amountPaid.toStringAsFixed(0)} - Outstanding Rs.${d.outstanding.toStringAsFixed(0)}'),
                      trailing: monthlyStatusChip(d.displayStatus),
                      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MonthlyMemberDetailView(memberId: d.memberId))),
                    ),
                  ),
              ],
            ),
          );
        },
      );
}

// ============================================================
// Reminder Schedule - extra reminder dates beyond the built-in 1st
// ============================================================

class MonthlyReminderScheduleView extends StatefulWidget {
  const MonthlyReminderScheduleView({super.key});
  @override
  State<MonthlyReminderScheduleView> createState() => _MonthlyReminderScheduleViewState();
}

class _MonthlyReminderScheduleViewState extends State<MonthlyReminderScheduleView> {
  List<int> days = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await loadReminderScheduleDays();
    if (!mounted) return;
    setState(() {
      days = d;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Reminder Schedule')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  const Card(child: Padding(padding: EdgeInsets.all(12), child: Text('A due reminder always goes out on the 1st of every month, to every active member with an unpaid or partially paid due. Add extra dates below if you want more reminder rounds during the month.'))),
                  const SizedBox(height: 8),
                  const ListTile(leading: Icon(Icons.event_available), title: Text('1st of every month'), subtitle: Text('Built-in - always on'), trailing: Icon(Icons.lock_outline)),
                  for (final d in days)
                    ListTile(
                      leading: const Icon(Icons.event),
                      title: Text('Day $d of every month'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await confirmDialog(context, 'Remove this reminder date?', 'Members will no longer get a reminder on day $d of the month (the 1st still always sends one).', confirmLabel: 'Remove');
                          if (!ok) return;
                          await removeReminderDayRemote(d);
                          await _load();
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add a reminder date'),
                    onPressed: () async {
                      final c = TextEditingController();
                      final day = await showDialog<int>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Add reminder date'),
                          content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Day of month (1-28)'), keyboardType: TextInputType.number),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                            ElevatedButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)), child: const Text('Add')),
                          ],
                        ),
                      );
                      if (day == null) return;
                      final e = await addReminderDayRemote(day);
                      if (!context.mounted) return;
                      if (e != null) {
                        toast(context, e);
                      } else {
                        await _load();
                      }
                    },
                  ),
                ],
              ),
      );
}
