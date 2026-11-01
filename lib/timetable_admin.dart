// ---------------- Sehri / Iftar Timetable: Super Admin management ----------------
//
// Super-Admin-only screen (Master Data > Super Admin Tools, main.dart) that
// manages public.sehri_iftar_timings: one row per Hijri date holding the
// Sehri End Time and/or Iftar Time. Nothing is ever calculated or
// pre-filled - a time exists only if a Super Admin typed it in. Everyone
// else just sees these times on the Calendar screen (guest_tools.dart); the
// database policies (sehri_iftar_super_write, is_super_admin()) reject any
// write from another role even if it somehow reached these calls. The
// table's unique (hijri_year, hijri_month, hijri_day) key guarantees one
// entry per date.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'main.dart' show sb, kGreen, page, toast, confirmDialog;
import 'guest_tools.dart' show hijriMonthsEn, SehriIftarTiming, formatTime12, hijriTodayParts;

Future<List<SehriIftarTiming>> _fetchAll() async {
  final rows = await sb
      .from('sehri_iftar_timings')
      .select()
      .order('hijri_year', ascending: false)
      .order('hijri_month', ascending: false)
      .order('hijri_day', ascending: false);
  return [for (final r in (rows as List)) SehriIftarTiming.fromJson(r as Map<String, dynamic>)];
}

String _err(Object e, String what) {
  if (e is PostgrestException) {
    if (e.code == '42501') return 'Only a Super Admin can $what timings.';
    if (e.code == '23505') return 'A timetable entry already exists for that Arabic date - edit that entry instead.';
    return 'Could not save: ${e.message}';
  }
  return 'Could not save. Check your internet connection and try again.';
}

class TimetableManagementView extends StatefulWidget {
  const TimetableManagementView({super.key});
  @override
  State<TimetableManagementView> createState() => _TimetableManagementViewState();
}

class _TimetableManagementViewState extends State<TimetableManagementView> {
  List<SehriIftarTiming> _items = [];
  bool _loading = true;
  String? _error;
  int _monthFilter = 0; // 0 = all months

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _fetchAll();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the timetable. Check your internet connection and try again.';
      });
    }
  }

  Future<void> _openForm([SehriIftarTiming? existing]) async {
    final def = existing == null ? await hijriTodayParts() : null;
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TimingFormDialog(existing: existing, defaultDate: def),
    );
    if (saved == true) {
      await _load();
      if (mounted) toast(context, existing == null ? 'Timing added.' : 'Timing updated.');
    }
  }

  Future<void> _delete(SehriIftarTiming t) async {
    final label = '${t.hijriDay} ${hijriMonthsEn[t.hijriMonth - 1]} ${t.hijriYear}';
    final ok = await confirmDialog(context, 'Delete timings for $label?', 'This removes the Sehri and Iftar times for that date. The calendar will show nothing for it.', confirmLabel: 'Delete');
    if (!ok) return;
    try {
      final gone = await sb.from('sehri_iftar_timings').delete().eq('id', t.id).select();
      if ((gone as List).isEmpty) {
        if (mounted) toast(context, 'Could not delete - you may not have access, or it was already removed.');
      } else if (mounted) {
        toast(context, 'Timing deleted.');
      }
    } catch (e) {
      if (mounted) toast(context, _err(e, 'delete'));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _monthFilter == 0 ? _items : _items.where((t) => t.hijriMonth == _monthFilter).toList();
    return page([
      const Text(
        'Enter Sehri End Time and Iftar Time for any Arabic (Hijri) date. Times are shown to every user on the Calendar screen for that date. Nothing is calculated automatically - a date with no entry (or a blank time) shows nothing.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ),
      const SizedBox(height: 10),
      ElevatedButton.icon(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Add timing')),
      const SizedBox(height: 10),
      DropdownButtonFormField<int>(
        value: _monthFilter,
        decoration: const InputDecoration(labelText: 'Show month', border: OutlineInputBorder(), isDense: true),
        items: [
          const DropdownMenuItem(value: 0, child: Text('All months')),
          for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(hijriMonthsEn[m - 1])),
        ],
        onChanged: (v) => setState(() => _monthFilter = v ?? 0),
      ),
      const SizedBox(height: 10),
      if (_loading) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: kGreen))),
      if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
      if (!_loading && _error == null && shown.isEmpty) const Text('No timings entered yet.'),
      ...shown.map((t) => Card(
            child: ListTile(
              title: Text('${t.hijriDay} ${hijriMonthsEn[t.hijriMonth - 1]} ${t.hijriYear} AH', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Sehri End: ${t.sehri == null ? '-' : formatTime12(t.sehri!)}\nIftar: ${t.iftar == null ? '-' : formatTime12(t.iftar!)}'),
              isThreeLine: true,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.edit), tooltip: 'Edit', onPressed: () => _openForm(t)),
                IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), tooltip: 'Delete', onPressed: () => _delete(t)),
              ]),
            ),
          )),
    ]);
  }
}

class _TimingFormDialog extends StatefulWidget {
  final SehriIftarTiming? existing;
  final List<int>? defaultDate; // [year, month, day] when adding
  const _TimingFormDialog({this.existing, this.defaultDate});
  @override
  State<_TimingFormDialog> createState() => _TimingFormDialogState();
}

class _TimingFormDialogState extends State<_TimingFormDialog> {
  late int year;
  late int month;
  late int day;
  TimeOfDay? sehri;
  TimeOfDay? iftar;
  bool busy = false;
  String? error;

  static TimeOfDay? _parse(String? t) {
    if (t == null) return null;
    final p = t.split(':');
    return TimeOfDay(hour: int.tryParse(p[0]) ?? 0, minute: p.length > 1 ? (int.tryParse(p[1]) ?? 0) : 0);
  }

  static String _db(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';
  static String _show(TimeOfDay t) => formatTime12(_db(t));

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final d = widget.defaultDate;
    year = e?.hijriYear ?? d?[0] ?? 1448;
    month = e?.hijriMonth ?? d?[1] ?? 9;
    day = e?.hijriDay ?? d?[2] ?? 1;
    if (day > 30) day = 30;
    sehri = _parse(e?.sehri);
    iftar = _parse(e?.iftar);
  }

  Future<void> _pick(bool isSehri) async {
    final cur = isSehri ? sehri : iftar;
    final picked = await showTimePicker(
      context: context,
      initialTime: cur ?? (isSehri ? const TimeOfDay(hour: 5, minute: 0) : const TimeOfDay(hour: 18, minute: 0)),
    );
    if (picked != null) setState(() => isSehri ? sehri = picked : iftar = picked);
  }

  Future<void> _save() async {
    if (sehri == null && iftar == null) {
      setState(() => error = 'Enter at least one time (Sehri End or Iftar).');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final body = {
      'hijri_year': year,
      'hijri_month': month,
      'hijri_day': day,
      'sehri_end_time': sehri == null ? null : _db(sehri!),
      'iftar_time': iftar == null ? null : _db(iftar!),
    };
    try {
      if (widget.existing == null) {
        await sb.from('sehri_iftar_timings').insert(body);
      } else {
        final changed = await sb.from('sehri_iftar_timings').update(body).eq('id', widget.existing!.id).select();
        if ((changed as List).isEmpty) {
          if (!mounted) return;
          setState(() {
            busy = false;
            error = 'Could not update - you may not have access, or the entry was removed.';
          });
          return;
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        busy = false;
        error = _err(e, widget.existing == null ? 'add' : 'edit');
      });
    }
  }

  Widget _timeRow(String label, TimeOfDay? v, bool isSehri) => Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: busy ? null : () => _pick(isSehri),
            icon: const Icon(Icons.access_time, size: 18),
            label: Align(alignment: Alignment.centerLeft, child: Text(v == null ? '$label (not set)' : '$label: ${_show(v)}')),
          ),
        ),
        if (v != null) IconButton(tooltip: 'Clear', icon: const Icon(Icons.clear), onPressed: busy ? null : () => setState(() => isSehri ? sehri = null : iftar = null)),
      ]);

  @override
  Widget build(BuildContext context) {
    final years = <int>{for (var y = year - 2; y <= year + 3; y++) y}.toList()..sort();
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add timing' : 'Edit timing'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<int>(
            value: year,
            decoration: const InputDecoration(labelText: 'Hijri year'),
            items: [for (final y in years) DropdownMenuItem(value: y, child: Text('$y AH'))],
            onChanged: busy ? null : (v) => setState(() => year = v ?? year),
          ),
          DropdownButtonFormField<int>(
            value: month,
            decoration: const InputDecoration(labelText: 'Hijri month'),
            items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(hijriMonthsEn[m - 1]))],
            onChanged: busy ? null : (v) => setState(() => month = v ?? month),
          ),
          DropdownButtonFormField<int>(
            value: day,
            decoration: const InputDecoration(labelText: 'Hijri day'),
            items: [for (var d = 1; d <= 30; d++) DropdownMenuItem(value: d, child: Text('$d'))],
            onChanged: busy ? null : (v) => setState(() => day = v ?? day),
          ),
          const SizedBox(height: 12),
          _timeRow('Sehri End Time', sehri, true),
          const SizedBox(height: 6),
          _timeRow('Iftar Time', iftar, false),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: Colors.red, fontSize: 12.5))),
        ]),
      ),
      actions: [
        TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: busy ? null : _save,
          child: busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
        ),
      ],
    );
  }
}
