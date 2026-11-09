// "My Monthly Records" - what a Monthly Member sees about themselves.
// Matched by login mobile number (server side, fn_my_monthly_member_ids),
// read-only, and independent of any role: it stays even if Super Admin
// removes the member's Working Committee access.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'monthly_members.dart';
import 'state.dart';

bool gIsMonthlyMember = false;

Future<void> refreshMonthlyMemberFlag() async {
  try {
    final ids = await Supabase.instance.client.rpc('fn_my_monthly_member_ids');
    final v = (ids is List) && ids.isNotEmpty;
    if (v != gIsMonthlyMember) {
      gIsMonthlyMember = v;
      st.notifyListeners();
    }
  } catch (_) {}
}

class MyMonthlyRecordsView extends StatefulWidget {
  const MyMonthlyRecordsView({super.key});
  @override
  State<MyMonthlyRecordsView> createState() => _MyMonthlyRecordsViewState();
}

class _MyMonthlyRecordsViewState extends State<MyMonthlyRecordsView> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _dues = [];
  List<Map<String, dynamic>> _payments = [];
  List<Map<String, dynamic>> _events = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ids = [for (final x in (await _sb.rpc('fn_my_monthly_member_ids') as List)) '$x'];
      if (ids.isEmpty) {
        _members = [];
        _dues = [];
        _payments = [];
        _events = [];
      } else {
        List<Map<String, dynamic>> L(dynamic r) => [for (final x in (r as List)) Map<String, dynamic>.from(x as Map)];
        _members = L(await _sb.from('monthly_members').select().inFilter('id', ids));
        _dues = L(await _sb.from('monthly_dues').select().inFilter('member_id', ids).order('year', ascending: false).order('month', ascending: false));
        _payments = L(await _sb.from('monthly_payments').select().inFilter('member_id', ids).order('paid_at', ascending: false));
        _events = L(await _sb.from('monthly_member_events').select().inFilter('member_id', ids).order('created_at', ascending: false));
      }
    } catch (_) {
      _error = 'Could not load your records. Check your internet connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  static const _months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String _rs(dynamic v) => 'Rs.${(double.tryParse('$v') ?? 0).toStringAsFixed(0)}';
  String _day(dynamic iso) => nice('${iso ?? ''}'.split('T').first);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Monthly Records')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), const SizedBox(height: 12), ElevatedButton(onPressed: _load, child: const Text('Retry'))])))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.all(12), children: [
                    if (_members.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No monthly membership found for your mobile number.')),
                    for (final m in _members) ...[
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.volunteer_activism),
                          title: Text('${m['full_name'] ?? ''}'),
                          subtitle: Text('${_rs(m['monthly_amount'])} / month - joined ${_day(m['joining_date'])}${m['is_active'] == false ? ' - inactive' : ''}'),
                        ),
                      ),
                    ],
                    if (_events.isNotEmpty) ...[
                      const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 4), child: Text('Account notes', style: TextStyle(fontWeight: FontWeight.bold))),
                      for (final e in _events)
                        Card(child: ListTile(dense: true, leading: Icon(e['kind'] == 'committee_removed' ? Icons.person_remove : Icons.how_to_reg), title: Text('${e['note'] ?? e['kind']}'), subtitle: Text(_day(e['created_at'])))),
                    ],
                    const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 4), child: Text('Monthly dues', style: TextStyle(fontWeight: FontWeight.bold))),
                    if (_dues.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No dues yet.')),
                    for (final d in _dues)
                      Card(
                        child: ListTile(
                          title: Text('${_months[(d['month'] as num?)?.toInt() ?? 0]} ${d['year']}'),
                          subtitle: Text('Due ${_rs(d['amount_due'])} - Paid ${_rs(d['amount_paid'])}'),
                          trailing: monthlyStatusChip(_status(d)),
                        ),
                      ),
                    const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 4), child: Text('Payment history', style: TextStyle(fontWeight: FontWeight.bold))),
                    if (_payments.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No payments recorded yet.')),
                    for (final p in _payments)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.receipt_long),
                          title: Text('${_rs(p['amount'])} - ${p['method']}'),
                          subtitle: Text('${_day(p['paid_at'])}${p['txn_ref'] != null ? ' - Ref: ${p['txn_ref']}' : ''}'),
                        ),
                      ),
                  ]),
                ),
    );
  }

  String _status(Map<String, dynamic> d) {
    final due = double.tryParse('${d['amount_due']}') ?? 0;
    final paid = double.tryParse('${d['amount_paid']}') ?? 0;
    if (paid >= due && due > 0) return 'Paid';
    if (paid > 0) return 'Partially Paid';
    return 'Due';
  }
}
