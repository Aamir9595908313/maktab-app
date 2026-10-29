// ---------------- Islamic Calendar: Super Admin management ----------------
//
// Two Super-Admin-only screens, both reached from Master Data > Super Admin
// Tools (main.dart):
//  - CalendarAdjustmentView: edits the single shared public.calendar_settings
//    row - the global Hijri offset every user's calendar now reads, replacing
//    the old per-device SharedPreferences control that used to live directly
//    on the Calendar screen (guest_tools.dart).
//  - IslamicEventManagementView: full CRUD over public.islamic_calendar_events
//    (add / edit / delete / search / filter), including the Permanent Annual
//    Event vs This Year Only recurrence rule the Calendar screen matches
//    against.
//
// Every write here goes straight to Supabase and takes effect immediately -
// there is deliberately no approval/pending workflow - and is enforced again
// at the database level by the *_super_write RLS policies (is_super_admin()),
// so a request from a non-Super-Admin account is rejected even if it somehow
// reached these calls, not just hidden from the menu. Each successful write
// also calls invalidateIslamicCalendarCache() (guest_tools.dart) so the
// public Calendar screen's cached data is dropped and refetched the next
// time it loads, instead of only picking up the change on a cold app start.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'main.dart' show sb, kGreen, page, toast, confirmDialog;
import 'guest_tools.dart' show hijriMonthsEn, invalidateIslamicCalendarCache;

const List<String> _kRecurrenceLabels = ['Permanent Annual Event', 'This Year Only'];
const List<String> _kRecurrenceValues = ['permanent', 'this_year_only'];

class IslamicCalendarEventAdmin {
  final String id;
  String name;
  int hijriMonth;
  int hijriDay;
  String place;
  String? description;
  String recurrenceType; // 'permanent' | 'this_year_only'
  int? hijriYear;
  DateTime? updatedAt;

  IslamicCalendarEventAdmin({
    required this.id,
    required this.name,
    required this.hijriMonth,
    required this.hijriDay,
    required this.place,
    this.description,
    required this.recurrenceType,
    this.hijriYear,
    this.updatedAt,
  });

  factory IslamicCalendarEventAdmin.fromJson(Map<String, dynamic> r) => IslamicCalendarEventAdmin(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? '',
        hijriMonth: r['hijri_month'] as int,
        hijriDay: r['hijri_day'] as int,
        place: (r['place'] as String?) ?? '',
        description: r['description'] as String?,
        recurrenceType: (r['recurrence_type'] as String?) ?? 'permanent',
        hijriYear: r['hijri_year'] as int?,
        updatedAt: r['updated_at'] == null ? null : DateTime.tryParse(r['updated_at'] as String),
      );

  String hijriDateLabel() {
    final month = hijriMonthsEn[hijriMonth - 1];
    if (recurrenceType == 'this_year_only') return '$hijriDay $month, $hijriYear AH - This Year Only';
    return '$hijriDay $month - Every Hijri Year';
  }
}

// is_active is left in every query/write below exactly as the column
// already defaults (true) - nothing here ever sets it false. Delete really
// deletes (confirmed first), matching "Delete events" in the brief literally
// rather than introducing a second soft-delete state the brief didn't ask for.
Future<List<IslamicCalendarEventAdmin>> fetchAllIslamicEventsAdmin() async {
  final rows = await sb.from('islamic_calendar_events').select().order('hijri_month', ascending: true).order('hijri_day', ascending: true).order('sort_order', ascending: true);
  return [for (final r in (rows as List)) IslamicCalendarEventAdmin.fromJson(r as Map<String, dynamic>)];
}

Future<String?> createIslamicEventRemote({
  required String name,
  required int hijriMonth,
  required int hijriDay,
  required String place,
  String? description,
  required String recurrenceType,
  int? hijriYear,
}) async {
  try {
    await sb.from('islamic_calendar_events').insert({
      'name': name.trim(),
      'hijri_month': hijriMonth,
      'hijri_day': hijriDay,
      'place': place.trim(),
      'description': (description == null || description.trim().isEmpty) ? null : description.trim(),
      'recurrence_type': recurrenceType,
      'hijri_year': recurrenceType == 'this_year_only' ? hijriYear : null,
      'created_by': sb.auth.currentUser?.id,
      'updated_by': sb.auth.currentUser?.id,
    });
    invalidateIslamicCalendarCache();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can add Islamic events.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> updateIslamicEventRemote(
  IslamicCalendarEventAdmin item, {
  required String name,
  required int hijriMonth,
  required int hijriDay,
  required String place,
  String? description,
  required String recurrenceType,
  int? hijriYear,
}) async {
  final cleanDescription = (description == null || description.trim().isEmpty) ? null : description.trim();
  final year = recurrenceType == 'this_year_only' ? hijriYear : null;
  try {
    await sb.from('islamic_calendar_events').update({
      'name': name.trim(),
      'hijri_month': hijriMonth,
      'hijri_day': hijriDay,
      'place': place.trim(),
      'description': cleanDescription,
      'recurrence_type': recurrenceType,
      'hijri_year': year,
      'updated_by': sb.auth.currentUser?.id,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', item.id);
    item
      ..name = name.trim()
      ..hijriMonth = hijriMonth
      ..hijriDay = hijriDay
      ..place = place.trim()
      ..description = cleanDescription
      ..recurrenceType = recurrenceType
      ..hijriYear = year
      ..updatedAt = DateTime.now();
    invalidateIslamicCalendarCache();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can edit Islamic events.';
    return 'Could not save: ${e.message}';
  } catch (_) {
    return 'Could not save. Check your internet connection and try again.';
  }
}

Future<String?> deleteIslamicEventRemote(IslamicCalendarEventAdmin item) async {
  try {
    await sb.from('islamic_calendar_events').delete().eq('id', item.id);
    invalidateIslamicCalendarCache();
    return null;
  } on PostgrestException catch (e) {
    if (e.code == '42501') return 'Only a Super Admin can delete Islamic events.';
    return 'Could not delete: ${e.message}';
  } catch (_) {
    return 'Could not delete. Check your internet connection and try again.';
  }
}

// ---------------- Calendar Adjustment (Super Admin) ----------------
class CalendarAdjustmentView extends StatefulWidget {
  const CalendarAdjustmentView({super.key});
  @override
  State<CalendarAdjustmentView> createState() => _CalendarAdjustmentViewState();
}

class _CalendarAdjustmentViewState extends State<CalendarAdjustmentView> {
  int? _saved; // last value confirmed saved in the database
  int _pending = 0; // value shown/edited here, may differ from _saved until Save
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final row = await sb.from('calendar_settings').select('hijri_offset_days').eq('id', 1).maybeSingle();
      final v = (row?['hijri_offset_days'] as int?) ?? 0;
      if (!mounted) return;
      setState(() {
        _saved = v;
        _pending = v;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the current adjustment. Check your internet connection and try again.';
        _loading = false;
      });
    }
  }

  String _fmt(int v) => v == 0 ? 'No adjustment' : (v > 0 ? '+$v day(s)' : '$v day(s)');

  Future<void> _save() async {
    if (_pending == _saved) {
      toast(context, 'No change to save.');
      return;
    }
    final ok = await confirmDialog(
      context,
      'Apply calendar adjustment?',
      "This changes the Hijri date every user's app calculates, immediately after they refresh - the calendar "
          "display, date selection, event popups, today's event, and the running announcement all use this same "
          "adjusted date.\n\nNew adjustment: ${_fmt(_pending)}",
      confirmLabel: 'Apply',
      danger: false,
    );
    if (!ok) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await sb.from('calendar_settings').update({
        'hijri_offset_days': _pending,
        'updated_by': sb.auth.currentUser?.id,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', 1);
      invalidateIslamicCalendarCache();
      if (!mounted) return;
      setState(() {
        _saved = _pending;
        _busy = false;
      });
      toast(context, 'Calendar adjustment saved. All users will see it after their next refresh.');
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.code == '42501' ? 'Only a Super Admin can change the calendar adjustment.' : 'Could not save: ${e.message}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not save. Check your internet connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pushed via pushPage (main.dart), which already supplies the
    // Scaffold + AppBar - this only returns the body content, same as
    // AboutUsManagementView, so the screen doesn't end up with two
    // stacked app bars.
    if (_loading) {
      return page([const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))]);
    }
    final dirty = _saved != null && _pending != _saved;
    return page([
        const Text(
          'Nudges the Hijri date the app calculates, by a whole number of days, to match a local moon-sighting '
          "announcement or a specific calendar. Only a Super Admin can change this, and it applies to every "
          "user's app immediately after they refresh - the calendar display, date selection, event matching, "
          "today's event, and the running announcement all use this same adjusted date.",
          style: TextStyle(fontSize: 12.5, color: Colors.black54),
        ),
        const SizedBox(height: 18),
        Center(
          child: Column(children: [
            Text('Currently applied: ${_saved == null ? '-' : _fmt(_saved!)}', style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(iconSize: 32, onPressed: _busy ? null : () => setState(() => _pending -= 1), icon: const Icon(Icons.remove_circle_outline)),
              SizedBox(
                width: 150,
                child: Text(_fmt(_pending), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: kGreen)),
              ),
              IconButton(iconSize: 32, onPressed: _busy ? null : () => setState(() => _pending += 1), icon: const Icon(Icons.add_circle_outline)),
            ]),
          ]),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
        ],
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy || !dirty ? null : () => setState(() => _pending = _saved!),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ElevatedButton(
              onPressed: _busy || !dirty ? null : _save,
              style: ElevatedButton.styleFrom(backgroundColor: kGreen, foregroundColor: Colors.white),
              child: _busy ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'),
            ),
          ),
        ]),
      ]);
  }
}

// ---------------- Islamic Event Management (Super Admin) ----------------
class IslamicEventManagementView extends StatefulWidget {
  const IslamicEventManagementView({super.key});
  @override
  State<IslamicEventManagementView> createState() => _IslamicEventManagementViewState();
}

class _IslamicEventManagementViewState extends State<IslamicEventManagementView> {
  List<IslamicCalendarEventAdmin>? _all;
  String? _loadError;

  final _search = TextEditingController();
  int? _filterMonth;
  int? _filterDay;
  int? _filterYear;
  final _filterPlace = TextEditingController();
  String? _filterRecurrence; // null = any

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await fetchAllIslamicEventsAdmin();
      if (!mounted) return;
      setState(() {
        _all = items;
        _loadError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = 'Could not load events. Check your internet connection and try again.');
    }
  }

  List<IslamicCalendarEventAdmin> get _filtered {
    final all = _all ?? const [];
    final q = _search.text.trim().toLowerCase();
    final placeQ = _filterPlace.text.trim().toLowerCase();
    return all.where((e) {
      if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) return false;
      if (_filterMonth != null && e.hijriMonth != _filterMonth) return false;
      if (_filterDay != null && e.hijriDay != _filterDay) return false;
      if (_filterYear != null && e.hijriYear != _filterYear) return false;
      if (placeQ.isNotEmpty && !e.place.toLowerCase().contains(placeQ)) return false;
      if (_filterRecurrence != null && e.recurrenceType != _filterRecurrence) return false;
      return true;
    }).toList();
  }

  bool get _hasActiveFilters => _filterMonth != null || _filterDay != null || _filterYear != null || _filterPlace.text.trim().isNotEmpty || _filterRecurrence != null;

  void _clearFilters() => setState(() {
        _filterMonth = null;
        _filterDay = null;
        _filterYear = null;
        _filterPlace.clear();
        _filterRecurrence = null;
      });

  Future<void> _delete(IslamicCalendarEventAdmin item) async {
    final ok = await confirmDialog(
      context,
      'Delete event?',
      '"${item.name}" (${item.hijriDateLabel()}) will be permanently deleted and will stop appearing in the calendar popup and running announcement after this refreshes. This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!ok) return;
    final e = await deleteIslamicEventRemote(item);
    if (!mounted) return;
    if (e != null) {
      toast(context, e);
      return;
    }
    toast(context, 'Event deleted.');
    _load();
  }

  Future<void> _openForm({IslamicCalendarEventAdmin? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _IslamicEventFormDialog(existing: existing),
    );
    if (saved == true) {
      toast(context, existing == null ? 'Event added.' : 'Event updated.');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pushed via pushPage (main.dart), which already supplies the
    // Scaffold + AppBar - see the note on CalendarAdjustmentView.build().
    final items = _filtered;
    return page([
        const Text(
          'Add, edit, delete, search, and filter the events the Calendar screen matches against Hijri dates. '
          'Changes take effect immediately for every user - there is no approval step.',
          style: TextStyle(fontSize: 12.5, color: Colors.black54),
        ),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: () => _openForm(),
          icon: const Icon(Icons.add),
          label: const Text('Add Event'),
          style: ElevatedButton.styleFrom(backgroundColor: kGreen, foregroundColor: Colors.white),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Search by event name',
            border: const OutlineInputBorder(),
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _search.clear())),
          ),
        ),
        const SizedBox(height: 10),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Filters${_hasActiveFilters ? ' (active)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
          children: [
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<int?>(
                  value: _filterMonth,
                  decoration: const InputDecoration(labelText: 'Hijri month', isDense: true, border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('Any')),
                    for (var m = 1; m <= 12; m++) DropdownMenuItem<int?>(value: m, child: Text(hijriMonthsEn[m - 1])),
                  ],
                  onChanged: (v) => setState(() => _filterMonth = v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<int?>(
                  value: _filterDay,
                  decoration: const InputDecoration(labelText: 'Hijri day', isDense: true, border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('Any')),
                    for (var d = 1; d <= 30; d++) DropdownMenuItem<int?>(value: d, child: Text('$d')),
                  ],
                  onChanged: (v) => setState(() => _filterDay = v),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Hijri year (This Year Only)', isDense: true, border: OutlineInputBorder()),
                  onChanged: (v) => setState(() => _filterYear = int.tryParse(v.trim())),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _filterPlace,
                  decoration: const InputDecoration(labelText: 'Place', isDense: true, border: OutlineInputBorder()),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              value: _filterRecurrence,
              decoration: const InputDecoration(labelText: 'Recurrence type', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Any')),
                for (var i = 0; i < _kRecurrenceValues.length; i++) DropdownMenuItem<String?>(value: _kRecurrenceValues[i], child: Text(_kRecurrenceLabels[i])),
              ],
              onChanged: (v) => setState(() => _filterRecurrence = v),
            ),
            if (_hasActiveFilters) ...[
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _clearFilters, icon: const Icon(Icons.filter_alt_off, size: 18), label: const Text('Clear filters'))),
            ],
          ],
        ),
        const Divider(height: 28),
        if (_loadError != null) ...[
          Text(_loadError!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ] else if (_all == null) ...[
          const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
        ] else ...[
          Text('${items.length} of ${_all!.length} event(s)', style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 6),
          if (items.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No events match.', style: TextStyle(color: Colors.black54))),
          // A plain mapped list, not ListView.builder: this screen is always
          // laid out inside page()'s own scrolling ListView (see main.dart),
          // so a second independently-scrolling list can't be nested here.
          // Fine at the current data volume (134 seeded events plus whatever
          // a Super Admin adds); a very large event list would want real
          // server-side pagination instead, which isn't implemented here.
          ...items.map((e) => Card(
                child: ListTile(
                  title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.hijriDateLabel(), style: const TextStyle(color: kGreen, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    if (e.place.isNotEmpty) Text(e.place, style: const TextStyle(color: Colors.black54, fontSize: 12)),
                    if (e.description != null && e.description!.isNotEmpty) Text(e.description!, style: const TextStyle(color: Colors.black45, fontSize: 11.5), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ]),
                  isThreeLine: e.description != null && e.description!.isNotEmpty,
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') _openForm(existing: e);
                      if (v == 'delete') _delete(e);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
              )),
        ],
      ]);
  }
}

// Add/Edit form, as a dialog (works the same on phone, tablet, and desktop
// widths - page()'s own 760px cap keeps it readable on wide screens too).
class _IslamicEventFormDialog extends StatefulWidget {
  const _IslamicEventFormDialog({this.existing});
  final IslamicCalendarEventAdmin? existing;
  @override
  State<_IslamicEventFormDialog> createState() => _IslamicEventFormDialogState();
}

class _IslamicEventFormDialogState extends State<_IslamicEventFormDialog> {
  final _name = TextEditingController();
  final _place = TextEditingController();
  final _description = TextEditingController();
  final _year = TextEditingController();
  int? _month;
  int? _day;
  String _recurrence = 'permanent';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = e.name;
      _place.text = e.place;
      _description.text = e.description ?? '';
      _month = e.hijriMonth;
      _day = e.hijriDay;
      _recurrence = e.recurrenceType;
      _year.text = e.hijriYear?.toString() ?? '';
    }
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Event Name is required.');
      return;
    }
    if (_month == null) {
      setState(() => _error = 'Hijri Month is required.');
      return;
    }
    if (_day == null) {
      setState(() => _error = 'Hijri Day is required.');
      return;
    }
    if (_place.text.trim().isEmpty) {
      setState(() => _error = 'Place / Location is required.');
      return;
    }
    int? year;
    if (_recurrence == 'this_year_only') {
      year = int.tryParse(_year.text.trim());
      if (year == null || year <= 0) {
        setState(() => _error = 'Enter a valid Hijri Year for a This Year Only event.');
        return;
      }
    }
    setState(() {
      _busy = true; // also prevents a duplicate submission from a second tap
      _error = null;
    });
    final existing = widget.existing;
    final e = existing == null
        ? await createIslamicEventRemote(
            name: _name.text,
            hijriMonth: _month!,
            hijriDay: _day!,
            place: _place.text,
            description: _description.text,
            recurrenceType: _recurrence,
            hijriYear: year,
          )
        : await updateIslamicEventRemote(
            existing,
            name: _name.text,
            hijriMonth: _month!,
            hijriDay: _day!,
            place: _place.text,
            description: _description.text,
            recurrenceType: _recurrence,
            hijriYear: year,
          );
    if (!mounted) return;
    if (e != null) {
      setState(() {
        _busy = false;
        _error = e;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(isEdit ? 'Edit Event' : 'Add Event', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: kGreen))),
              IconButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), icon: const Icon(Icons.close)),
            ]),
            Flexible(
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Event Name *', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _month,
                        decoration: const InputDecoration(labelText: 'Hijri Month *', border: OutlineInputBorder(), isDense: true),
                        items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(hijriMonthsEn[m - 1]))],
                        onChanged: (v) => setState(() => _month = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _day,
                        decoration: const InputDecoration(labelText: 'Hijri Day *', border: OutlineInputBorder(), isDense: true),
                        items: [for (var d = 1; d <= 30; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                        onChanged: (v) => setState(() => _day = v),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  TextField(controller: _place, decoration: const InputDecoration(labelText: 'Place / Location *', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _recurrence,
                    decoration: const InputDecoration(labelText: 'Event Recurrence Type *', border: OutlineInputBorder(), isDense: true),
                    items: [for (var i = 0; i < _kRecurrenceValues.length; i++) DropdownMenuItem(value: _kRecurrenceValues[i], child: Text(_kRecurrenceLabels[i]))],
                    onChanged: (v) => setState(() => _recurrence = v ?? 'permanent'),
                  ),
                  if (_recurrence == 'this_year_only') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _year,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Hijri Year *', helperText: 'The Hijri (AH) year, not Gregorian.', border: OutlineInputBorder()),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: _description,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Description (optional)', border: OutlineInputBorder(), alignLabelWithHint: true),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
                  ],
                ]),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel'))),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  style: ElevatedButton.styleFrom(backgroundColor: kGreen, foregroundColor: Colors.white),
                  child: _busy
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(isEdit ? 'Update Event' : 'Save Event'),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
