// ---------------- Declare Holiday (Super Admin) ----------------
//
// A Super Admin declares a holiday with a title, a message, a From and To
// date, for every Maktab or one chosen Maktab. Behind the one button the
// database function declare_holiday() (Super Admin only, enforced there)
// does three things in one transaction:
//  1. records the declaration (public.holiday_declarations),
//  2. posts a banner announcement every user's dashboard shows until the
//     holiday ends (public.announcements),
//  3. marks every date in the range as a 'holiday' for each affected Maktab
//     (public.maktab_events) so attendance, reports and parent attendance
//     views treat those days as holidays, exactly like a holiday a teacher
//     records for a single day.
// A declaration can be cancelled, which withdraws the banner and cancels
// those holiday dates again.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'main.dart' show sb, st, kGreen, page, toast, confirmDialog, askText, loadEvents, loadAnnouncements;
import 'state.dart' show fd, nice, diffDays;

class _Declaration {
  final String id;
  final String title;
  final String message;
  final String fromDate;
  final String toDate;
  final String? madrasaId;
  final bool cancelled;
  final String? cancelReason;
  _Declaration(this.id, this.title, this.message, this.fromDate, this.toDate, this.madrasaId, this.cancelled, this.cancelReason);
}

class HolidayDeclarationView extends StatefulWidget {
  const HolidayDeclarationView({super.key});
  @override
  State<HolidayDeclarationView> createState() => _HolidayDeclarationViewState();
}

class _HolidayDeclarationViewState extends State<HolidayDeclarationView> {
  final title = TextEditingController();
  final message = TextEditingController();
  String from = '';
  String to = '';
  String scope = ''; // '' = all Makatib, else a madrasa db id
  bool busy = false;
  bool loading = true;
  String? error;
  List<_Declaration> items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    title.dispose();
    message.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await sb.from('holiday_declarations').select().order('from_date', ascending: false);
      if (!mounted) return;
      setState(() {
        items = [
          for (final r in (rows as List))
            _Declaration(r['id'] as String, (r['title'] as String?) ?? '', (r['message'] as String?) ?? '', r['from_date'] as String, r['to_date'] as String,
                r['madrasa_id'] as String?, r['cancelled_at'] != null, r['cancel_reason'] as String?),
        ];
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Could not load holidays. Check your internet connection and try again.';
      });
    }
  }

  String _scopeName(String? madrasaId) {
    if (madrasaId == null) return 'All Makatib';
    for (final m in st.madrasas) {
      if (m.dbId == madrasaId) return m.name;
    }
    return 'One Maktab';
  }

  Future<void> _pickDate(bool isFrom) async {
    final init = DateTime.tryParse(isFrom ? from : to) ?? DateTime.tryParse(from) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime(2035, 12, 31),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        from = fd(picked);
        if (to.isEmpty || diffDays(from, to) > 0) to = from; // keep To >= From
      } else {
        to = fd(picked);
      }
    });
  }

  Future<void> _declare() async {
    final t = title.text.trim();
    final m = message.text.trim();
    if (t.isEmpty) return setState(() => error = 'Enter a holiday title.');
    if (m.isEmpty) return setState(() => error = 'Enter the holiday message that everyone will see.');
    if (from.isEmpty || to.isEmpty) return setState(() => error = 'Choose both the From date and the To date.');
    if (diffDays(from, to) > 0) return setState(() => error = 'The To date must be on or after the From date.');
    setState(() => error = null);
    final where = scope.isEmpty ? 'all Makatib' : _scopeName(scope);
    final ok = await confirmDialog(
      context,
      'Declare this holiday?',
      '"$t"\n${from == to ? nice(from) : '${nice(from)} to ${nice(to)}'}\nFor: $where\n\nA banner with your message appears on every dashboard, and these dates are marked as holidays in attendance.',
      confirmLabel: 'Declare holiday',
      danger: false,
    );
    if (!ok || !mounted) return;
    setState(() => busy = true);
    try {
      await sb.rpc('declare_holiday', params: {'p_title': t, 'p_message': m, 'p_from': from, 'p_to': to, 'p_madrasa_id': scope.isEmpty ? null : scope});
      await Future.wait([loadAnnouncements(), loadEvents(), _load()]);
      if (!mounted) return;
      title.clear();
      message.clear();
      setState(() {
        from = '';
        to = '';
        scope = '';
        busy = false;
      });
      toast(context, 'Holiday declared. It now shows on every dashboard.');
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = e.code == '42501' ? 'Only a Super Admin can declare a holiday.' : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = 'Could not save. Check your internet connection and try again.';
      });
    }
  }

  Future<void> _cancel(_Declaration d) async {
    final reason = await askText(context, 'Reason for cancelling this holiday (optional)');
    if (reason == null || !mounted) return;
    final ok = await confirmDialog(context, 'Cancel "${d.title}"?', 'The banner is withdrawn and its dates stop being holidays in attendance.', confirmLabel: 'Cancel holiday');
    if (!ok || !mounted) return;
    try {
      await sb.rpc('cancel_holiday_declaration', params: {'p_id': d.id, 'p_reason': reason});
      await Future.wait([loadAnnouncements(), loadEvents(), _load()]);
      if (mounted) toast(context, 'Holiday cancelled.');
    } on PostgrestException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (_) {
      if (mounted) toast(context, 'Could not cancel. Check your internet connection and try again.');
    }
  }

  Widget _dateButton(String label, String value, bool isFrom) => Expanded(
        child: OutlinedButton.icon(
          onPressed: busy ? null : () => _pickDate(isFrom),
          icon: const Icon(Icons.event, size: 18),
          label: Align(alignment: Alignment.centerLeft, child: Text(value.isEmpty ? '$label date' : '$label: ${nice(value)}')),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final madrasas = [for (final m in st.madrasas) if (m.active && m.dbId != null) m];
    return page([
      const Text(
        'Declare a holiday for a date range with a message. It shows as a banner on every user\'s dashboard until the holiday ends, and the dates count as holidays in attendance.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      const SizedBox(height: 12),
      TextField(controller: title, enabled: !busy, decoration: const InputDecoration(labelText: 'Holiday title *', border: OutlineInputBorder())),
      const SizedBox(height: 10),
      TextField(controller: message, enabled: !busy, maxLines: 3, decoration: const InputDecoration(labelText: 'Message to everyone *', border: OutlineInputBorder())),
      const SizedBox(height: 10),
      Row(children: [_dateButton('From', from, true), const SizedBox(width: 8), _dateButton('To', to, false)]),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        value: scope,
        decoration: const InputDecoration(labelText: 'Applies to', border: OutlineInputBorder(), isDense: true),
        items: [
          const DropdownMenuItem(value: '', child: Text('All Makatib')),
          for (final m in madrasas) DropdownMenuItem(value: m.dbId!, child: Text(m.name)),
        ],
        onChanged: busy ? null : (v) => setState(() => scope = v ?? ''),
      ),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red, fontSize: 12.5))),
      const SizedBox(height: 10),
      ElevatedButton.icon(
        onPressed: busy ? null : _declare,
        icon: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.beach_access),
        label: const Text('Declare holiday'),
      ),
      const SizedBox(height: 18),
      const Text('Declared holidays', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: 6),
      if (loading) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(color: kGreen))),
      if (!loading && items.isEmpty) const Text('No holidays declared yet.'),
      ...items.map((d) {
        final today = fd(DateTime.now());
        final status = d.cancelled
            ? 'Cancelled${(d.cancelReason ?? '').isEmpty ? '' : ' - ${d.cancelReason}'}'
            : (diffDays(today, d.toDate) > 0 ? 'Completed' : (diffDays(today, d.fromDate) < 0 ? 'Upcoming' : 'Running now'));
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(d.fromDate == d.toDate ? nice(d.fromDate) : '${nice(d.fromDate)} to ${nice(d.toDate)}  -  ${_scopeName(d.madrasaId)}'),
              const SizedBox(height: 2),
              Text(d.message, style: const TextStyle(color: Colors.black87, fontSize: 13)),
              const SizedBox(height: 4),
              Row(children: [
                Chip(
                  label: Text(status, style: const TextStyle(fontSize: 11.5)),
                  backgroundColor: d.cancelled ? Colors.grey.shade300 : const Color(0xFFFFE3E0),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                if (!d.cancelled && diffDays(today, d.toDate) <= 0) TextButton(onPressed: () => _cancel(d), child: const Text('Cancel holiday')),
              ]),
            ]),
          ),
        );
      }),
    ]);
  }
}
