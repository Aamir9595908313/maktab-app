import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:http/http.dart' as http;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'prayer_notifications.dart';
import 'state.dart' show AboutUsContent, AboutUsSection, kMadrasaCategories;

const Color _kGreen = Color(0xFF054D00);
// Sampled from the Durood e Taj PDF's own page background (the pale mint
// green behind its decorative border), so the Surah Yaseen reader - whose
// source PDF pages are plain white - uses the same tone around/behind the
// page for a consistent look between the two Arabic reading screens.
const Color _kArabicReaderBg = Color(0xFFCFE6D0);
const Color _kGold = Color(0xFFD4A72C);

const double _kaabaLat = 21.4225;
const double _kaabaLng = 39.8262;

// True bearing (degrees from true North) from (lat,lng) to the Kaaba.
// Note: this is the bearing relative to TRUE north. The device compass
// (flutter_compass) reports heading relative to MAGNETIC north, which is
// offset from true north by a location-dependent amount (magnetic
// declination, typically a few degrees). Correcting for that exactly needs
// a geomagnetic model (e.g. the WMM) that isn't wired up here - for most
// users the resulting error is small enough not to matter for prayer
// direction, but it means the arrow can be a few degrees off true in
// locations with high declination. Flagged as a known limitation.
double _qiblaBearing(double lat, double lng) {
  final phi1 = lat * math.pi / 180;
  final phi2 = _kaabaLat * math.pi / 180;
  final dLambda = (_kaabaLng - lng) * math.pi / 180;
  final y = math.sin(dLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  var theta = math.atan2(y, x) * 180 / math.pi;
  theta = (theta + 360) % 360;
  return theta;
}

String _compassPoint(double deg) {
  const pts = ['N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE', 'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW'];
  final i = ((deg / 22.5) + 0.5).floor() % 16;
  return pts[i];
}

PreferredSizeWidget guestAppBar(BuildContext context, String title) => AppBar(
      title: Text(title),
      backgroundColor: _kGreen,
      foregroundColor: Colors.white,
    );

// ---------------- Qibla ----------------
// Real GPS location + live compass heading. Needs the ACCESS_FINE_LOCATION
// permission at runtime, which this screen requests itself the first time
// it opens. If the user has no GPS fix yet, denies the permission, or the
// device has no magnetometer, that is shown as a clear in-screen message
// with a Retry button rather than a blank/frozen screen.
class QiblaScreen extends StatefulWidget {
  const QiblaScreen({super.key});
  @override
  State<QiblaScreen> createState() => _QiblaScreenState();
}

enum _QiblaStatus { loading, noService, permissionDenied, noSensor, ready }

class _QiblaScreenState extends State<QiblaScreen> {
  _QiblaStatus status = _QiblaStatus.loading;
  double? lat, lng;
  double? heading; // device compass heading, degrees from magnetic north
  StreamSubscription<CompassEvent>? _compassSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => status = _QiblaStatus.loading);

    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      setState(() => status = _QiblaStatus.noService);
      return;
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => status = _QiblaStatus.permissionDenied);
      return;
    }

    if (FlutterCompass.events == null) {
      setState(() => status = _QiblaStatus.noSensor);
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        lat = pos.latitude;
        lng = pos.longitude;
        status = _QiblaStatus.ready;
      });
      _compassSub = FlutterCompass.events?.listen((event) {
        if (!mounted || event.heading == null) return;
        setState(() => heading = event.heading);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => status = _QiblaStatus.noService);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: guestAppBar(context, 'Qibla Direction'),
      body: switch (status) {
        _QiblaStatus.loading => const Center(child: CircularProgressIndicator(color: _kGreen)),
        _QiblaStatus.noService => _message(Icons.location_off, 'Location is turned off', 'Turn on Location / GPS for this device, then retry.'),
        _QiblaStatus.permissionDenied => _message(Icons.location_disabled, 'Location permission needed', 'Qibla direction needs your location to calculate the bearing to Makkah. Allow location access in the app\'s permissions, then retry.'),
        _QiblaStatus.noSensor => _message(Icons.explore_off, 'No compass sensor found', 'This device does not appear to have a magnetometer, so a live compass direction isn\'t available here.'),
        _QiblaStatus.ready => _ready(),
      },
    );
  }

  Widget _message(IconData icon, String title, String body) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 40),
          Icon(icon, size: 56, color: Colors.black38),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 20),
          Center(child: ElevatedButton.icon(onPressed: _init, icon: const Icon(Icons.refresh), label: const Text('Retry'))),
        ],
      );

  Widget _ready() {
    final qibla = _qiblaBearing(lat!, lng!);
    final h = heading;
    // Arrow angle on screen: how far to rotate the pointer, relative to the
    // top of the screen, so it points at the Kaaba. If the live heading
    // isn't available yet, fall back to showing the bearing from north
    // (phone assumed flat and pointing north) rather than nothing.
    final arrowAngle = h == null ? qibla : (qibla - h + 360) % 360;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Your location', style: TextStyle(color: Colors.black54, fontSize: 12)),
        Text('${lat!.toStringAsFixed(4)}, ${lng!.toStringAsFixed(4)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 24),
        Center(
          child: SizedBox(
            width: 240,
            height: 240,
            child: Stack(alignment: Alignment.center, children: [
              Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: _kGreen, width: 3)),
              ),
              const Positioned(top: 6, child: Text('N', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
              const Positioned(bottom: 6, child: Text('S', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
              const Positioned(left: 10, child: Text('W', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
              const Positioned(right: 10, child: Text('E', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54))),
              AnimatedRotation(
                turns: arrowAngle / 360,
                duration: const Duration(milliseconds: 150),
                child: const Icon(Icons.navigation, size: 90, color: _kGold),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: Column(children: [
            Text('${qibla.toStringAsFixed(0)} deg (${_compassPoint(qibla)}) from North', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kGreen)),
            const SizedBox(height: 4),
            const Text('Direction to the Kaaba, Makkah', style: TextStyle(color: Colors.black54)),
            if (h == null) ...[
              const SizedBox(height: 4),
              const Text('Waiting for compass heading - hold the phone flat and move it in a figure-8 if this stays blank.', style: TextStyle(fontSize: 11.5, color: Colors.black45), textAlign: TextAlign.center),
            ],
          ]),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Move the phone in a figure-8 to recalibrate the compass.'))),
          icon: const Icon(Icons.explore),
          label: const Text('Recalibrate compass'),
        ),
        const SizedBox(height: 16),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Uses your phone\'s live GPS location and compass heading, so the arrow rotates as you turn the phone. No login needed. The bearing is relative to magnetic north; true-north correction (magnetic declination) is not applied, so it can be a few degrees off in some locations.',
              style: TextStyle(fontSize: 12.5, color: Colors.black54),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------- Calendar (Hijri approximation + Gregorian, Urdu/English) ----------------
List<int> _gregorianToHijri(DateTime g) {
  // Kuwaiti-algorithm style arithmetic approximation (tabular Islamic calendar).
  final jd = _gregorianToJulianDay(g);
  final l = jd - 1948440 + 10632;
  final n = ((l - 1) / 10631).floor();
  var ll = l - 10631 * n + 354;
  final j = (((10985 - ll) / 5316).floor() * ((50 * ll) / 17719).floor()) + ((ll / 5670).floor() * ((43 * ll) / 15238).floor());
  ll = ll - (((30 - j) / 15).floor() * ((17719 * j) / 50).floor()) - (((j) / 16).floor() * ((15238 * j) / 43).floor()) + 29;
  final m = ((24 * ll) / 709).floor();
  final d = ll - ((709 * m) / 24).floor();
  final y = 30 * n + j - 30;
  return [y, m + 1, d];
}

int _gregorianToJulianDay(DateTime g) {
  final a = ((14 - g.month) / 12).floor();
  final y = g.year + 4800 - a;
  final m = g.month + 12 * a - 3;
  return g.day + ((153 * m + 2) / 5).floor() + 365 * y + (y / 4).floor() - (y / 100).floor() + (y / 400).floor() - 32045;
}

const List<String> _hijriMonthsEn = ['Muharram', 'Safar', "Rabi-ul-Awwal", 'Rabi-ul-Aakhir', 'Jumada-al-Awwal', 'Jumada-al-Aakhir', 'Rajab', "Sha'ban", 'Ramadan', 'Shawwal', "Dhul-Qa'dah", 'Dhul-Hijjah'];
const List<String> _hijriMonthsUr = ['محرم', 'صفر', 'ربیع الاول', 'ربیع الثانی', 'جمادی الاول', 'جمادی الثانی', 'رجب', 'شعبان', 'رمضان', 'شوال', 'ذوالقعدہ', 'ذوالحجہ'];
const List<String> _gMonthsEn = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const List<String> _gMonthsUr = ['جنوری', 'فروری', 'مارچ', 'اپریل', 'مئی', 'جون', 'جولائی', 'اگست', 'ستمبر', 'اکتوبر', 'نومبر', 'دسمبر'];
const List<String> _wdEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _wdUr = ['پیر', 'منگل', 'بدھ', 'جمعرات', 'جمعہ', 'ہفتہ', 'اتوار'];

// A single recurring Islamic-calendar event: matched purely by its Hijri
// (month, day) - the same pair every Hijri year, with no year/Gregorian
// date stored at all, so recurrence is automatic (plain equality, not date
// math) and nothing here needs updating year to year.
class _IslamicEvent {
  final int hijriMonth;
  final int hijriDay;
  final String name;
  final String? place;
  _IslamicEvent({required this.hijriMonth, required this.hijriDay, required this.name, this.place});
}

// Loaded once and cached at module scope (not per CalendarScreen instance),
// so repeated visits to the Calendar screen - by a guest or a logged-in
// user alike - reuse the same fetch instead of hitting Supabase again, per
// the feature brief's "avoid unnecessary repeated database/API requests".
// Fetched the same way _AboutUsScreenState does: directly via
// Supabase.instance.client rather than through main.dart's `sb` getter,
// because this file doesn't import main.dart and this screen is reachable
// before login. The islamic_calendar_events_read_all RLS policy allows
// anon + authenticated select, so this works identically for guest and
// signed-in users.
List<_IslamicEvent>? _islamicEventsCache;
Future<List<_IslamicEvent>>? _islamicEventsFuture;

Future<List<_IslamicEvent>> _loadIslamicEvents() {
  final cached = _islamicEventsCache;
  if (cached != null) return Future.value(cached);
  return _islamicEventsFuture ??= Supabase.instance.client
      .from('islamic_calendar_events')
      .select('hijri_month, hijri_day, name, place')
      .eq('is_active', true)
      .then((rows) {
        final list = (rows as List)
            .map((r) => _IslamicEvent(
                  hijriMonth: r['hijri_month'] as int,
                  hijriDay: r['hijri_day'] as int,
                  name: r['name'] as String,
                  place: r['place'] as String?,
                ))
            .toList();
        _islamicEventsCache = list;
        return list;
      })
      .catchError((_) {
        // Network/RLS failure: behave exactly as the calendar did before
        // this feature existed - no popups, no today's-event banner -
        // rather than breaking the rest of the screen. Not cached, so the
        // next screen visit retries.
        _islamicEventsFuture = null;
        return <_IslamicEvent>[];
      });
}

// A slow, smooth, pausable horizontal "running" banner for today's event
// text. Built manually (AnimationController + SingleTickerProviderStateMixin,
// the same pattern already used elsewhere in this app for _LoginSplash /
// _AnnouncementBanner / _SpinningLogo in main.dart) rather than adding a new
// marquee/ticker package dependency.
class _EventMarquee extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  const _EventMarquee({required this.text, required this.onTap});
  @override
  State<_EventMarquee> createState() => _EventMarqueeState();
}

class _EventMarqueeState extends State<_EventMarquee> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  bool _paused = false;

  Duration _durationFor(String text) => Duration(milliseconds: (text.length * 90).clamp(6000, 30000));

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: _durationFor(widget.text))..repeat();
  }

  @override
  void didUpdateWidget(covariant _EventMarquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _c.duration = _durationFor(widget.text);
      if (!_paused) _c.repeat();
    }
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (_paused) {
      _c.stop();
    } else {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: LayoutBuilder(builder: (context, constraints) {
          final tp = TextPainter(
            text: TextSpan(text: widget.text, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: Colors.white)),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          final boxWidth = constraints.maxWidth;
          final travel = tp.width + boxWidth;
          return GestureDetector(
            onTap: widget.onTap,
            child: ClipRect(
              child: SizedBox(
                height: 24,
                width: boxWidth,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) {
                    final dx = boxWidth - _c.value * travel;
                    return Stack(clipBehavior: Clip.none, children: [
                      Positioned(
                        left: dx,
                        top: 0,
                        child: Text(widget.text, maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: Colors.white)),
                      ),
                    ]);
                  },
                ),
              ),
            ),
          );
        }),
      ),
      IconButton(
        onPressed: _togglePause,
        icon: Icon(_paused ? Icons.play_arrow : Icons.pause, color: Colors.white70, size: 20),
        tooltip: _paused ? 'Resume' : 'Pause',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      ),
    ]);
  }
}

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  bool urdu = false;
  // Was hardcoded to a fixed sample date (2026-09-19) regardless of the
  // device's actual date - that was the "wrong current date" bug. Both now
  // use the device's real current date.
  late DateTime shown = DateTime(DateTime.now().year, DateTime.now().month, 1);
  final DateTime today = DateTime.now();
  // No arithmetic Hijri calendar (this one included) can know in advance
  // what a local moon-sighting committee will actually announce - India's
  // observed Islamic date can legitimately differ by a day from any
  // calculated one. This lets whoever maintains the app nudge the shown
  // Hijri date to match that day's real announcement, persisted so it
  // applies for everyone until changed again.
  int hijriOffset = 0;

  // Islamic events loaded once (via the module-level cache above) and
  // indexed by 'hijriMonth-hijriDay' for O(1) lookup per calendar cell and
  // for today's date, both below.
  Map<String, List<_IslamicEvent>> _eventsByDate = {};

  @override
  void initState() {
    super.initState();
    _loadOffset();
    _loadEvents();
  }

  Future<void> _loadOffset() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt('hijri_offset_days') ?? 0;
    if (mounted) setState(() => hijriOffset = v);
  }

  Future<void> _setOffset(int v) async {
    setState(() => hijriOffset = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('hijri_offset_days', v);
  }

  Future<void> _loadEvents() async {
    final events = await _loadIslamicEvents();
    if (!mounted) return;
    final map = <String, List<_IslamicEvent>>{};
    for (final e in events) {
      map.putIfAbsent('${e.hijriMonth}-${e.hijriDay}', () => []).add(e);
    }
    setState(() => _eventsByDate = map);
  }

  List<_IslamicEvent> _eventsOn(int hMonth, int hDay) => _eventsByDate['$hMonth-$hDay'] ?? const [];

  void _showEventPopup(List<_IslamicEvent> events, int hMonth, int hDay, int hYear) {
    final months = urdu ? _hijriMonthsUr : _hijriMonthsEn;
    final dateLabel = '$hDay ${months[hMonth - 1]} $hYear ${urdu ? 'ہجری' : 'AH'}';
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 10, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.event, color: _kGreen),
                const SizedBox(width: 8),
                Expanded(child: Text(dateLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _kGreen))),
                IconButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close),
                  tooltip: urdu ? 'بند کریں' : 'Close',
                ),
              ]),
              const Divider(height: 18),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final e in events) ...[
                      Text(e.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      if (e.place != null && e.place!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3, bottom: 12),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Icon(Icons.location_on, size: 14, color: Colors.black45),
                            const SizedBox(width: 4),
                            Expanded(child: Text(e.place!, style: const TextStyle(fontSize: 12.5, color: Colors.black54))),
                          ]),
                        )
                      else
                        const SizedBox(height: 12),
                    ],
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hToday = _gregorianToHijri(today.add(Duration(days: hijriOffset)));
    final firstOfMonth = DateTime(shown.year, shown.month, 1);
    final daysInMonth = DateTime(shown.year, shown.month + 1, 0).day;
    final leading = (firstOfMonth.weekday - 1) % 7; // Monday = 0

    return Scaffold(
      appBar: guestAppBar(context, urdu ? 'کیلنڈر' : 'Calendar'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ToggleButtons(
            isSelected: [!urdu, urdu],
            onPressed: (i) => setState(() => urdu = i == 1),
            borderRadius: BorderRadius.circular(8),
            children: const [Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('English')), Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('اردو'))],
          ),
          const SizedBox(height: 14),
          Card(
            color: const Color(0xFFEEF4E8),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(urdu ? 'آج' : "Today", style: const TextStyle(color: Colors.black54, fontSize: 12)),
                Text('${today.day} ${urdu ? _gMonthsUr[today.month - 1] : _gMonthsEn[today.month - 1]} ${today.year}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text('${hToday[2]} ${urdu ? _hijriMonthsUr[hToday[1] - 1] : _hijriMonthsEn[hToday[1] - 1]} ${hToday[0]} ${urdu ? 'ہجری' : 'AH'}', style: const TextStyle(fontSize: 15, color: _kGreen, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          // Today's Islamic Event: fully hidden when nothing matches today's
          // Hijri (month, day) - no card, no space reserved - and otherwise a
          // single non-intrusive running banner (never an auto-opened
          // popup), covering every matching event in one scrolling line.
          // Tapping it opens the same detail popup a calendar-cell tap would.
          Builder(builder: (context) {
            final todayEvents = _eventsOn(hToday[1], hToday[2]);
            if (todayEvents.isEmpty) return const SizedBox.shrink();
            final text = todayEvents.map((e) {
              final place = e.place;
              return (place != null && place.isNotEmpty) ? '${e.name} — $place' : e.name;
            }).join('     •     ');
            return Column(children: [
              const SizedBox(height: 10),
              Material(
                color: _kGreen,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _showEventPopup(todayEvents, hToday[1], hToday[2], hToday[0]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(children: [
                      const Icon(Icons.campaign, color: _kGold, size: 22),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(urdu ? 'آج کا اسلامی دن' : "Today's Islamic Event", style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          _EventMarquee(text: text, onTap: () => _showEventPopup(todayEvents, hToday[1], hToday[2], hToday[0])),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
            ]);
          }),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(
              urdu ? 'اگر مقامی اعلان سے ایک دن آگے پیچھے ہو:' : 'If this is a day off from the local announcement:',
              style: const TextStyle(fontSize: 11.5, color: Colors.black54),
            ),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => _setOffset(hijriOffset - 1), icon: const Icon(Icons.remove_circle_outline, size: 20)),
            Text(hijriOffset == 0 ? (urdu ? 'درست' : 'No adjustment') : '${hijriOffset > 0 ? '+' : ''}$hijriOffset ${urdu ? 'دن' : 'day(s)'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
            IconButton(onPressed: () => _setOffset(hijriOffset + 1), icon: const Icon(Icons.add_circle_outline, size: 20)),
          ]),
          // This same +/- adjustment is the general-purpose way to align the
          // shown Hijri date to ANY specific moon-sighting source (a local
          // committee's announcement, or a particular named calendar such as
          // a Razwi one) - it is not limited to "the local announcement"
          // wording above. Nobody has supplied an actual Razwi calendar
          // source/dates to calibrate against yet, so there is nothing
          // Razwi-specific to encode here; once a source is provided, the
          // correct offset for it can be set the same way.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              urdu
                  ? 'نوٹ: یہی ایڈجسٹمنٹ کسی بھی مخصوص کیلنڈر (مثلاً رضوی کیلنڈر) سے ملانے کے لیے بھی استعمال کی جا سکتی ہے۔ فی الحال رضوی کیلنڈر کا کوئی مصدر فراہم نہیں کیا گیا، اس لیے کوئی علیحدہ ایڈجسٹمنٹ سیٹ نہیں کی گئی۔'
                  : 'Note: this same adjustment can be used to match any specific calendar (e.g. a Razwi calendar) once a source for it is provided - no Razwi-specific source has been supplied yet, so no separate adjustment has been set.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, color: Colors.black45, fontStyle: FontStyle.italic),
            ),
          ),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(onPressed: () => setState(() => shown = DateTime(shown.year, shown.month - 1, 1)), icon: const Icon(Icons.chevron_left)),
            Column(children: [
              Text('${urdu ? _gMonthsUr[shown.month - 1] : _gMonthsEn[shown.month - 1]} ${shown.year}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              // A Gregorian month almost always spans parts of two Hijri
              // months (Hijri months run ~29-30 days against a 30/31-day
              // Gregorian month) - like a printed Razvi calendar, this shows
              // both names ("Rajab - Sha'ban 1447") rather than just the
              // first day's month, which would silently drop the second one.
              Builder(builder: (context) {
                final hijriFirst = _gregorianToHijri(DateTime(shown.year, shown.month, 1).add(Duration(days: hijriOffset)));
                final hijriLast = _gregorianToHijri(DateTime(shown.year, shown.month, daysInMonth).add(Duration(days: hijriOffset)));
                final names = urdu ? _hijriMonthsUr : _hijriMonthsEn;
                final label = hijriFirst[1] == hijriLast[1] ? names[hijriFirst[1] - 1] : '${names[hijriFirst[1] - 1]} - ${names[hijriLast[1] - 1]}';
                final yearLabel = hijriFirst[0] == hijriLast[0] ? '${hijriFirst[0]}' : '${hijriFirst[0]}-${hijriLast[0]}';
                return Text('$label $yearLabel${urdu ? ' ہجری' : ' AH'}', style: const TextStyle(fontSize: 12, color: _kGreen, fontWeight: FontWeight.w600));
              }),
            ]),
            IconButton(onPressed: () => setState(() => shown = DateTime(shown.year, shown.month + 1, 1)), icon: const Icon(Icons.chevron_right)),
          ]),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 0.82,
            children: [
              for (final w in (urdu ? _wdUr : _wdEn)) Center(child: Text(w, style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.bold))),
              for (var i = 0; i < leading; i++) const SizedBox(),
              for (var d = 1; d <= daysInMonth; d++)
                Builder(builder: (context) {
                  final date = DateTime(shown.year, shown.month, d);
                  final isFriday = date.weekday == DateTime.friday;
                  final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
                  // Both dates in the one box - the Gregorian day large on
                  // top, the Hijri day (same month shown in the header
                  // above, so just the day number here) small underneath,
                  // same pairing a printed Razvi calendar box shows. Needs
                  // the full (month, day) pair - not just the day - to look
                  // up events correctly, since a Gregorian month view can
                  // span two different Hijri months.
                  final hDate = _gregorianToHijri(date.add(Duration(days: hijriOffset)));
                  final hMonth = hDate[1];
                  final hDay = hDate[2];
                  final hYear = hDate[0];
                  final matches = _eventsOn(hMonth, hDay);
                  return GestureDetector(
                    onTap: matches.isEmpty ? null : () => _showEventPopup(matches, hMonth, hDay, hYear),
                    child: Container(
                      margin: const EdgeInsets.all(1.5),
                      decoration: BoxDecoration(
                        color: isToday ? _kGreen : (isFriday ? const Color(0xFFFFF3CF) : const Color(0xFFFAFAF5)),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: isToday ? _kGreen : const Color(0xFFE3E0D0), width: 1),
                      ),
                      alignment: Alignment.center,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
                        Text('$d', style: TextStyle(color: isToday ? Colors.white : Colors.black87, fontWeight: isFriday || isToday ? FontWeight.bold : FontWeight.normal, fontSize: 24)),
                        const SizedBox(height: 2),
                        Text('$hDay', style: TextStyle(color: isToday ? Colors.white70 : const Color(0xFFC62828), fontSize: 14, fontWeight: FontWeight.w600)),
                        if (matches.isNotEmpty) ...[
                          const SizedBox(height: 1),
                          Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle, color: isToday ? Colors.white : _kGold)),
                        ],
                      ]),
                    ),
                  );
                }),
            ],
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                urdu
                    ? 'جمعہ کا دن نمایاں ہے۔ سنہری نشان والی تاریخ پر کسی اسلامی واقعہ کی تفصیل دیکھنے کے لیے ٹیپ کریں۔'
                    : 'Fridays are highlighted. Tap a date with a gold dot to see its Islamic event.',
                style: const TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- Tasbeeh Counter ----------------
class TasbeehScreen extends StatefulWidget {
  const TasbeehScreen({super.key});
  @override
  State<TasbeehScreen> createState() => _TasbeehScreenState();
}

class _TasbeehScreenState extends State<TasbeehScreen> {
  int count = 0;
  int target = 33;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        count = prefs.getInt('tasbeeh_count') ?? 0;
        target = prefs.getInt('tasbeeh_target') ?? 33;
        loaded = true;
      });
    } catch (_) {
      setState(() => loaded = true);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('tasbeeh_count', count);
      await prefs.setInt('tasbeeh_target', target);
    } catch (_) {
      // Offline-first: if storage is unavailable the count still works for this session.
    }
  }

  void _tap() {
    HapticFeedback.lightImpact();
    setState(() => count++);
    _save();
    if (count == target) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Target of $target reached. MashaAllah.')));
    }
  }

  void _reset() {
    setState(() => count = 0);
    _save();
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return Scaffold(appBar: guestAppBar(context, 'Tasbeeh Counter'), body: const Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: guestAppBar(context, 'Tasbeeh Counter'),
      body: Column(children: [
        const SizedBox(height: 10),
        Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
          for (final t in [33, 99, 100]) ChoiceChip(label: Text('$t'), selected: target == t, onSelected: (_) => setState(() => target = t)),
          ActionChip(
            label: const Text('Custom'),
            onPressed: () async {
              final v = await showDialog<String>(
                context: context,
                builder: (ctx) {
                  final c = TextEditingController(text: '$target');
                  return AlertDialog(
                    title: const Text('Set target'),
                    content: TextField(controller: c, keyboardType: TextInputType.number),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      ElevatedButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
                    ],
                  );
                },
              );
              final n = int.tryParse(v ?? '');
              if (n != null && n > 0) setState(() => target = n);
            },
          ),
        ]),
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: _tap,
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _kGreen, boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)]),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$count', style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.bold)),
                  Text('of $target', style: const TextStyle(color: Color(0xFFF0D98A), fontSize: 16)),
                ]),
              ),
            ),
          ),
        ),
        const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('Tap the circle to count', style: TextStyle(color: Colors.black54))),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(onPressed: _reset, icon: const Icon(Icons.refresh), label: const Text('Reset')),
        ),
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Text('No login needed. The count is saved on this phone.', style: TextStyle(fontSize: 12, color: Colors.black54)),
        ),
      ]),
    );
  }
}

// ---------------- Prayer Times (Hanafi) ----------------
class PrayerTimesScreen extends StatefulWidget {
  const PrayerTimesScreen({super.key});
  @override
  State<PrayerTimesScreen> createState() => _PrayerTimesScreenState();
}

enum _PrayerStatus { loading, noService, permissionDenied, networkError, ready }

class _PrayerTimesScreenState extends State<PrayerTimesScreen> {
  _PrayerStatus status = _PrayerStatus.loading;
  double? lat, lng;
  Map<String, String> timings = {};
  String? placeName;
  bool placeLoading = false;
  bool notifEnabled = false;
  bool notifBusy = false;

  @override
  void initState() {
    super.initState();
    _loadNotifPref();
    _init();
  }

  Future<void> _loadNotifPref() async {
    final enabled = await PrayerNotificationService.isEnabled();
    if (!mounted) return;
    setState(() => notifEnabled = enabled);
  }

  // Reverse-geocodes (lat, lng) to a human place name via OpenStreetMap's
  // free Nominatim API, so the screen can show "Mehkar, Maharashtra"
  // instead of raw coordinates - this runs on the end user's device/network
  // (not this build environment), so it's reachable at runtime even though
  // it can't be tested from here. Best-effort: on any failure the screen
  // just falls back to showing the coordinates, which were already shown
  // before this feature existed.
  Future<void> _reverseGeocode(double latitude, double longitude) async {
    setState(() => placeLoading = true);
    try {
      final uri = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$latitude&lon=$longitude&zoom=10&addressdetails=1');
      final res = await http
          .get(uri, headers: {'User-Agent': 'MaktabETajushshriahApp/1.0 (Faiz-E-Raza Group Mehkar)'})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw Exception('bad status');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = body['address'] as Map<String, dynamic>?;
      final city = addr?['city'] ?? addr?['town'] ?? addr?['village'] ?? addr?['county'] ?? addr?['suburb'];
      final state = addr?['state'];
      final parts = [city, state].whereType<String>().toList();
      final name = parts.isNotEmpty ? parts.join(', ') : (body['display_name'] as String?);
      if (!mounted) return;
      setState(() {
        placeName = name;
        placeLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => placeLoading = false);
    }
  }

  Future<void> _init() async {
    setState(() {
      status = _PrayerStatus.loading;
      placeName = null;
    });
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      setState(() => status = _PrayerStatus.noService);
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      setState(() => status = _PrayerStatus.permissionDenied);
      return;
    }
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      ).timeout(const Duration(seconds: 15));
      // method=1: University of Islamic Sciences, Karachi - the convention
      // most madaris in India/Pakistan already follow for Fajr/Isha angles.
      // school=1: Hanafi, so Asr is calculated at the later (shadow = 2x
      // object height) time instead of the other madhhabs' 1x-height time.
      final uri = Uri.parse('https://api.aladhan.com/v1/timings?latitude=${pos.latitude}&longitude=${pos.longitude}&method=1&school=1');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw Exception('bad status');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final t = (body['data'] as Map<String, dynamic>)['timings'] as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        lat = pos.latitude;
        lng = pos.longitude;
        timings = t.map((k, v) => MapEntry(k, v.toString()));
        status = _PrayerStatus.ready;
      });
      // Best-effort, non-blocking: the place name and any scheduled
      // reminders should never hold up showing the prayer times themselves.
      unawaited(_reverseGeocode(pos.latitude, pos.longitude));
      if (notifEnabled) {
        unawaited(PrayerNotificationService.scheduleUpcoming(latitude: pos.latitude, longitude: pos.longitude));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => status = _PrayerStatus.networkError);
    }
  }

  Future<void> _onToggleNotif(bool value) async {
    setState(() => notifBusy = true);
    if (value) {
      final granted = await PrayerNotificationService.requestPermissions();
      await PrayerNotificationService.setEnabled(true);
      if (!mounted) return;
      if (!granted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Notification permission wasn't granted, so reminders may not appear. You can allow it from the device's app settings."),
        ));
      }
      if (lat != null && lng != null) {
        await PrayerNotificationService.scheduleUpcoming(latitude: lat!, longitude: lng!);
      }
    } else {
      await PrayerNotificationService.setEnabled(false);
    }
    if (!mounted) return;
    setState(() {
      notifEnabled = value;
      notifBusy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: guestAppBar(context, 'Prayer Times (Hanafi)'),
      body: switch (status) {
        _PrayerStatus.loading => const Center(child: CircularProgressIndicator(color: _kGreen)),
        _PrayerStatus.noService => _message(Icons.location_off, 'Location is turned off', 'Turn on Location / GPS for this device, then retry.'),
        _PrayerStatus.permissionDenied => _message(Icons.location_disabled, 'Location permission needed', 'Prayer times are calculated for your exact location. Allow location access, then retry.'),
        _PrayerStatus.networkError => _message(Icons.wifi_off, 'Could not fetch prayer times', 'Check your internet connection, then retry.'),
        _PrayerStatus.ready => _ready(),
      },
    );
  }

  Widget _message(IconData icon, String title, String body) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 40),
          Icon(icon, size: 56, color: Colors.black38),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 20),
          Center(child: ElevatedButton.icon(onPressed: _init, icon: const Icon(Icons.refresh), label: const Text('Retry'))),
        ],
      );

  // The Aladhan API returns each time as 24-hour "HH:mm" (occasionally with
  // a trailing " (TZ)", already stripped elsewhere in this file for the
  // same reason) - shown as-is, that read like "13:10" instead of a time a
  // guest actually reads a clock in. Converts to 12-hour with AM/PM; falls
  // back to the raw string if it's ever not in the expected shape.
  String _fmt12Hour(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return '-';
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(hhmm.trim());
    if (m == null) return hhmm;
    var h = int.parse(m.group(1)!);
    final minute = m.group(2)!;
    final suffix = h >= 12 ? 'PM' : 'AM';
    h %= 12;
    if (h == 0) h = 12;
    return '$h:$minute $suffix';
  }

  Widget _ready() {
    final rows = [
      ['Fajr', _fmt12Hour(timings['Fajr'])],
      ['Sunrise', _fmt12Hour(timings['Sunrise'])],
      ['Dhuhr', _fmt12Hour(timings['Dhuhr'])],
      ['Asr', _fmt12Hour(timings['Asr'])],
      ['Maghrib', _fmt12Hour(timings['Maghrib'])],
      ['Isha', _fmt12Hour(timings['Isha'])],
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_on, size: 16, color: _kGreen),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                placeLoading ? 'Finding your location…' : (placeName ?? '${lat!.toStringAsFixed(3)}, ${lng!.toStringAsFixed(3)}'),
                style: const TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text('${lat!.toStringAsFixed(3)}, ${lng!.toStringAsFixed(3)}', style: const TextStyle(color: Colors.black38, fontSize: 11), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: status == _PrayerStatus.loading ? null : _init,
          icon: const Icon(Icons.my_location, size: 16),
          label: const Text('Update to my current location', style: TextStyle(fontSize: 12)),
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            value: notifEnabled,
            onChanged: notifBusy ? null : _onToggleNotif,
            activeColor: _kGreen,
            title: const Text('Notify me at prayer time', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            subtitle: const Text(
              'Shows an in-app notification the moment each prayer starts (not WhatsApp/SMS). Works even if the app is closed.',
              style: TextStyle(fontSize: 11.5),
            ),
          ),
        ),
        const SizedBox(height: 10),
        for (final r in rows)
          Card(
            child: ListTile(
              title: Text(r[0]!, style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: Text(r[1] ?? '-', style: const TextStyle(fontSize: 16, color: _kGreen, fontWeight: FontWeight.bold)),
            ),
          ),
        const SizedBox(height: 10),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              "Asr is calculated using the Hanafi method (the later time, when a shadow is twice the object's height, instead of once). Times are computed for your live GPS location and can be a few minutes off from your local mosque's posted timetable.",
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------- Surah Yaseen (bundled PDF, shown page by page) ----------------
// The bundled assets/surah_yaseen.pdf is the source of truth; this screen
// never extracts, re-shapes, or regenerates its Arabic text. Each page is
// rasterized from the PDF itself (Printing.raster, from the `printing`
// package) into an image and shown as-is, so what's on screen is a pixel-
// for-pixel copy of the original page - fonts, line breaks, word
// positions, verse-end symbols and page numbering included - with no
// Flutter text layout involved at all. Previous/Next buttons, a page
// number selector, and pinch-to-zoom (via InteractiveViewer) are added
// purely as viewer chrome around that image; the content itself is
// read-only.
class SurahYaseenScreen extends StatefulWidget {
  const SurahYaseenScreen({super.key});
  @override
  State<SurahYaseenScreen> createState() => _SurahYaseenScreenState();
}

class _SurahYaseenScreenState extends State<SurahYaseenScreen> {
  List<Uint8List>? _pages;
  String? _error;
  int _page = 0;
  final _pageCtl = PageController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await rootBundle.load('assets/surah_yaseen.pdf');
      final pdfBytes = bytes.buffer.asUint8List();
      final imgs = <Uint8List>[];
      await for (final raster in Printing.raster(pdfBytes, dpi: 200)) {
        imgs.add(await raster.toPng());
      }
      if (!mounted) return;
      setState(() => _pages = imgs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load Surah Yaseen: $e');
    }
  }

  void _goTo(int i) {
    final pages = _pages;
    if (pages == null || i < 0 || i >= pages.length) return;
    _pageCtl.animateToPage(i, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  Future<void> _pickPage() async {
    final pages = _pages;
    if (pages == null) return;
    final n = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Go to page'),
        children: [
          SizedBox(
            height: 260,
            width: 220,
            child: GridView.count(
              crossAxisCount: 5,
              children: [
                for (var i = 0; i < pages.length; i++)
                  InkWell(
                    onTap: () => Navigator.pop(c, i),
                    child: Container(
                      margin: const EdgeInsets.all(3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: i == _page ? _kGreen : const Color(0xFFEFEFEF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${i + 1}', style: TextStyle(color: i == _page ? Colors.white : Colors.black87)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (n != null) _goTo(n);
  }

  @override
  void dispose() {
    _pageCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    return Scaffold(
      backgroundColor: _kArabicReaderBg,
      appBar: guestAppBar(context, 'Surah Yaseen'),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center)))
          : pages == null
              ? const Center(child: CircularProgressIndicator(color: _kGreen))
              : Column(
                  children: [
                    Expanded(
                      child: PageView.builder(
                        controller: _pageCtl,
                        itemCount: pages.length,
                        // This is an Arabic book: a real swipe-right opens
                        // the next page, not the previous one. `reverse`
                        // flips PageView's gesture direction to match while
                        // `_page`/`_goTo` still count 0..n-1 in true page
                        // order, so the page-number label and picker grid
                        // below are unaffected.
                        reverse: true,
                        onPageChanged: (i) => setState(() => _page = i),
                        itemBuilder: (c, i) => InteractiveViewer(
                          minScale: 1,
                          maxScale: 4,
                          child: Center(child: Image.memory(pages[i], fit: BoxFit.contain)),
                        ),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Icons swapped to match RTL reading order: the
                            // book moves right-to-left, so "Next" points
                            // left and "Previous" points right.
                            IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Previous page', onPressed: _page > 0 ? () => _goTo(_page - 1) : null),
                            TextButton(onPressed: _pickPage, child: Text('Page ${_page + 1} of ${pages.length}')),
                            IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Next page', onPressed: _page < pages.length - 1 ? () => _goTo(_page + 1) : null),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ---------------- Durood e Taj (bundled PDF, shown page by page) ----------------
// Same approach as Surah Yaseen above: the bundled assets/durood_e_taj.pdf
// is the source of truth. Each page is rasterized from the PDF itself
// (Printing.raster) into an image and shown as-is - a pixel-for-pixel copy
// of the original, including the Urdu translation lines under each Arabic
// line - rather than being retyped or re-laid-out by Flutter. Getting a
// single diacritic wrong in a recitation text is not something to risk, so
// nothing here reconstructs the text; it only displays the provided PDF.
class DuroodTajScreen extends StatefulWidget {
  const DuroodTajScreen({super.key});
  @override
  State<DuroodTajScreen> createState() => _DuroodTajScreenState();
}

class _DuroodTajScreenState extends State<DuroodTajScreen> {
  List<Uint8List>? _pages;
  String? _error;
  int _page = 0;
  final _pageCtl = PageController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await rootBundle.load('assets/durood_e_taj.pdf');
      final pdfBytes = bytes.buffer.asUint8List();
      final imgs = <Uint8List>[];
      // dpi 200 matches Surah Yaseen - this PDF's pages (403x640pt) render
      // at a comparable pixel size to that one, so the same resolution
      // keeps zoomed-in text equally sharp without an oversized download.
      await for (final raster in Printing.raster(pdfBytes, dpi: 200)) {
        imgs.add(await raster.toPng());
      }
      if (!mounted) return;
      setState(() => _pages = imgs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load Durood e Taj: $e');
    }
  }

  void _goTo(int i) {
    final pages = _pages;
    if (pages == null || i < 0 || i >= pages.length) return;
    _pageCtl.animateToPage(i, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  Future<void> _pickPage() async {
    final pages = _pages;
    if (pages == null) return;
    final n = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Go to page'),
        children: [
          SizedBox(
            height: 260,
            width: 220,
            child: GridView.count(
              crossAxisCount: 5,
              children: [
                for (var i = 0; i < pages.length; i++)
                  InkWell(
                    onTap: () => Navigator.pop(c, i),
                    child: Container(
                      margin: const EdgeInsets.all(3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: i == _page ? _kGreen : const Color(0xFFEFEFEF),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${i + 1}', style: TextStyle(color: i == _page ? Colors.white : Colors.black87)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (n != null) _goTo(n);
  }

  @override
  void dispose() {
    _pageCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    return Scaffold(
      backgroundColor: _kArabicReaderBg,
      appBar: guestAppBar(context, 'Durood e Taj'),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(_error!, textAlign: TextAlign.center)))
          : pages == null
              ? const Center(child: CircularProgressIndicator(color: _kGreen))
              : Column(
                  children: [
                    Expanded(
                      child: PageView.builder(
                        controller: _pageCtl,
                        itemCount: pages.length,
                        // This is an Arabic book: a real swipe-right opens
                        // the next page, not the previous one. `reverse`
                        // flips PageView's gesture direction to match while
                        // `_page`/`_goTo` still count 0..n-1 in true page
                        // order, so the page-number label and picker grid
                        // below are unaffected.
                        reverse: true,
                        onPageChanged: (i) => setState(() => _page = i),
                        itemBuilder: (c, i) => InteractiveViewer(
                          minScale: 1,
                          maxScale: 4,
                          child: Center(child: Image.memory(pages[i], fit: BoxFit.contain)),
                        ),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Icons swapped to match RTL reading order: the
                            // book moves right-to-left, so "Next" points
                            // left and "Previous" points right.
                            IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Previous page', onPressed: _page > 0 ? () => _goTo(_page - 1) : null),
                            TextButton(onPressed: _pickPage, child: Text('Page ${_page + 1} of ${pages.length}')),
                            IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Next page', onPressed: _page < pages.length - 1 ? () => _goTo(_page + 1) : null),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ---------------- About Us ----------------
// Content transcribed from the Faiz-e-Raza Group's own introduction
// poster, in the same Hindi wording it was written in.
class _AboutSection {
  final String title;
  final List<String> paras;
  final List<String> bullets;
  const _AboutSection(this.title, {this.paras = const [], this.bullets = const []});
}

const List<_AboutSection> _aboutSections = [
  _AboutSection(
    'खिदमात',
    paras: [
      'अल्हम्दुलिल्लाह, अल्लाह तबारक व तआला का करोड़ो-हा शुक्र व इहसान है के उस ने अपने हबीब ﷺ के सदक़े हमें अहले सुन्नत वल जमाअत में पैदा किया और हमे दीन की खिदमत कि तौफ़ीक़ अता फ़रमाई।',
    ],
  ),
  _AboutSection(
    'मकतबे ताजुश्शरीअह का क़याम',
    paras: [
      'अल्हम्दुलिल्लाह इस पुर फितन दौर में मकतबे ताजुश्शरीअह का क़याम मेहकर कि अवाम के लिए बहोत मुफ़ीद साबित हुआ।',
      '5 May 2024 को मकतबे ताजुश्शरीअह का क़याम अमल में आया, ब फ़ज्लेही तआला मज़ीद इसकी शाखें (ब्रांचेज़) जैसे बाग़बान पूरा और ख्वाजा पिया व जामा मस्जिद के पास क़ाइम हुई। जिन में 280 तलबा व तालिबात इल्मे दीन से अपने आप को आरास्ता कर रहे है, जिन में तक़रीबन 80 तलबा (लड़के) और 200 तालिबात (लड़कियां) है।',
      'अल्हम्दुलिल्लाह, दर्से निज़ामी (आलिमा कोर्स) भी शुरू किया गया जिस में तक़रीबन 15 बच्चियों ने दाखला (एडमिशन) लिया और तक़रीबन 10 बच्चियाँ इब्तेदाई तालीम देने के क़ाबिल हो गयी और अल्हम्दुलिल्लाह वही बच्चियाँ मकतबे ताजुश्शरीअह के दूसरे शाखों में तालीम दे रही है।',
      'जिस उम्मीद के साथ हम ने मकतबे ताजुश्शरीअह कि बुन्याद रखी थी, अल्हम्दुलिल्लाह वो काफ़ी हद तक पूरी हुई। माशाअल्लाह तालिबात और उनके घरो में काफ़ी हद तक तब्दीली देखने को मिली जैसे, नमाज़ो कि पाबन्दी, परदे का एहतेमाम, बिला वजह घरो से बाहर निकलने से बचना, हुस्न ए अख़लाक़, सलाम में पहल करना और सब से अहेम, दीनी कामो में पढ़ने में और एक दूसरे पर सबक़त ले जाने का जज़्बा।',
    ],
  ),
  _AboutSection(
    'मकतबे ताजुश्शरीअह का निसाब व खुसूसियत',
    bullets: [
      'मरक़ज़े अहले सुन्नत से शाया करदा क़ाएदा मुअल्लेमुल क़ुरआन पढ़ाना',
      'क़ुरआन ए पाक सही तजवीद के साथ मुक़म्मल करना',
      'अक़ाइद ए अहले सुन्नत व मसाइले शरीअह',
      'क़ुरआन व सुन्नत की रौशनी में तरबियती दर्स',
      'दीनियत स्पेशल कोर्स',
      'इस्लामी अख़्लाख़ व आदाब ए ज़िंदगी',
      'हिफ़्ज़ सूरतें व अहादीस मा-तर्जुमा',
      'हफ़्तावारी इज्तेमा',
      'उर्दू ज़बान पर महारत',
    ],
  ),
  _AboutSection(
    'फैज़े रज़ा ग्रुप के ज़ेरे एहतेमाम किये हुए काम',
    bullets: [
      'मुख़्तलिफ़ मुहल्लों में मकातिब का क़याम',
      'इज्तेमाआत का इनेक़ाद',
      'बाद नमाज़े ईशा मुख़्तलिफ़ इलाक़ो में रोज़ाना दर्स का एहतेमाम',
      'तरबियत के लिए नौजवानो को शहर से बाहर ज़िम्मेदार उलमा के सेंटर पर भेजना',
      'नौजवानो में दीनी बेदारी व अक़ाइद के तहफ़्फ़ुज़ के लिए मौक़ूफ़ ए ताजुश्शरीअह पर चलने वाले पीराने इज़ाम के दामन से वाबस्ता करना',
      'मकतबे ताजुश्शरीअह की जुमला ज़रुरियात व अख़राजात पूरा करना',
    ],
  ),
  _AboutSection(
    'फैज़े रज़ा ग्रुप का मुस्तक़बिल प्लान',
    bullets: [
      'इंशाअल्लाह, मेहकर व इतराफ़ में मज़ीद मकतबे ताजुश्शरीअह का क़याम',
      'इंशाअल्लाह, सुच्ची लाइब्रेरी का क़याम',
      'हफ़्तावारी दीनी नशिश्त',
    ],
  ),
  _AboutSection(
    'मक़सद',
    paras: [
      'हुज़ूर ताजुश्शरीअह عليه الرحمة की तालीमात की रोशनी में मसलक ए आलाहज़रत की तरवीज व इशाअत और उस पर इस्तेक़ामत का पैग़ाम देना। मरकज़े अहले सुन्नत बरेली शरीफ़ से अवाम को रोशनज कराकर मौक़िफ़े मुफ़्तिए आज़म عليه الرحمة पर चलने वाले पीराने इज़ाम के दामन से वाबस्ता कराना।',
    ],
  ),
  _AboutSection(
    'दुआ',
    paras: [
      'अल्लाह तआला कि बारगाह में दुआ है हुज़ूर ए अकरम ﷺ के सदक़े व तुफ़ैल मकतबे ताजुश्शरीअह को ख़ूब तरक्क़ी, कामयाबी व कामरानी अता फ़रमाए और फैज़े रज़ा ग्रुप के तमाम मेम्बरान और मकतबे ताजुश्शरीअह के क़याम में हिस्सा लेने वाले तमाम अफ़राद को अल्लाह तआला दराज़िए उम्र बिल ख़ैर अता फ़रमाए। उनके इल्मो अमल और रिज़्क़ में बे पनाह बरकते अता फ़रमाए और इसी तरह सभी को दीनो सुन्नियत कि खिदमत करने के साथ हुज़ूर ﷺ कि नामूस के पहरेदारों में शामिल फ़रमाए। और ज़िंदगी कि आख़री साँस तक अहले सुन्नत वल जमात (मसलक ए आलाहज़रत) पर सख़्ती के साथ क़ाइम व दाएम रखे। आमीन।',
    ],
  ),
];

// Lightweight rich-text markup for About Us paragraphs/bullets: **bold**
// and {{color:#RRGGBB}}...{{/color}}, stored inline in the same plain
// String a paragraph/bullet already was - no schema change, and any text
// typed before this feature existed (with no markup in it) still renders
// exactly as before. The Super Admin's editor toolbar (in main.dart)
// inserts these markers around the selected text instead of exposing this
// syntax directly, but it still parses correctly if someone types it by
// hand. Color wraps are parsed first so a bold run can sit inside a
// colored one (applying both to the same selection nests correctly);
// a bold wrap can likewise contain a color run.
final RegExp _rxAboutUsColor = RegExp(r'\{\{color:(#[0-9A-Fa-f]{6})\}\}(.*?)\{\{/color\}\}', dotAll: true);
final RegExp _rxAboutUsBold = RegExp(r'\*\*(.*?)\*\*', dotAll: true);

List<InlineSpan> _parseAboutUsBold(String text, TextStyle base, Color? color) {
  final withColor = color == null ? base : base.copyWith(color: color);
  final spans = <InlineSpan>[];
  int last = 0;
  for (final m in _rxAboutUsBold.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start), style: withColor));
    spans.add(TextSpan(text: m.group(1) ?? '', style: withColor.copyWith(fontWeight: FontWeight.bold)));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last), style: withColor));
  if (spans.isEmpty) spans.add(TextSpan(text: text, style: withColor));
  return spans;
}

List<InlineSpan> parseAboutUsRichText(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  int last = 0;
  for (final m in _rxAboutUsColor.allMatches(text)) {
    if (m.start > last) spans.addAll(_parseAboutUsBold(text.substring(last, m.start), base, null));
    final color = Color(int.parse(m.group(1)!.substring(1), radix: 16) + 0xFF000000);
    spans.addAll(_parseAboutUsBold(m.group(2) ?? '', base, color));
    last = m.end;
  }
  if (last < text.length) spans.addAll(_parseAboutUsBold(text.substring(last), base, null));
  if (spans.isEmpty) spans.add(TextSpan(text: text, style: base));
  return spans;
}

// Shared renderer used both by this public/no-login screen and by the
// Super Admin's "About Us Management" Preview (in main.dart), so there is
// exactly one place that turns an AboutUsContent into widgets - editing
// never has to guess how the published page will actually look.
List<Widget> aboutUsBodyWidgets(AboutUsContent c) {
  return [
    Text(c.heading, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _kGreen), textAlign: TextAlign.center),
    if (c.subheading.isNotEmpty) ...[
      const SizedBox(height: 4),
      Text(c.subheading, style: const TextStyle(fontSize: 12, color: Colors.black54, fontStyle: FontStyle.italic), textAlign: TextAlign.center),
    ],
    const SizedBox(height: 18),
    for (final s in c.sections)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15.5, color: _kGreen)),
            const SizedBox(height: 8),
            for (final p in s.paras)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: RichText(text: TextSpan(children: parseAboutUsRichText(p, const TextStyle(fontSize: 13.5, height: 1.5, color: Colors.black87)))),
              ),
            // Each bullet is its own block, with the bullet glyph in a
            // fixed-width column so a wrapped second line of text lines up
            // under the first word (not under the dot), and real spacing
            // between bullets so they read as clearly separate lines
            // rather than running into each other.
            for (final b in s.bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SizedBox(width: 18, child: Text('•', style: TextStyle(color: _kGreen, fontWeight: FontWeight.bold, fontSize: 15))),
                  Expanded(child: RichText(text: TextSpan(children: parseAboutUsRichText(b, const TextStyle(fontSize: 13.5, height: 1.45, color: Colors.black87))))),
                ]),
              ),
          ]),
        ),
      ),
    if (c.contactLines.isNotEmpty)
      Card(
        color: const Color(0xFFEEF4E8),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final l in c.contactLines) Text(l, style: const TextStyle(fontWeight: FontWeight.bold))],
          ),
        ),
      ),
  ];
}

// Falls back to this bundled copy (the exact wording that used to be
// hardcoded here) only if the database can't be reached - a guest on a
// weak connection still sees the organization's information instead of a
// blank page, and it is updated live from public.about_us the moment a
// Super Admin edits it from Master Data > Super Admin Tools.
AboutUsContent _aboutUsFallback() => AboutUsContent(
      heading: 'फैज़े रज़ा ग्रुप की कारकर्दगी',
      subheading: 'जहाँ में आम पैग़ामे शहे अहमद रज़ा करदे, पलट कर पीछे देखे फिर से तज्दीदे वफ़ा करदे',
      sections: [for (final s in _aboutSections) AboutUsSection(title: s.title, paras: s.paras, bullets: s.bullets)],
      contactLines: const [
        'हमारा मरकज़ - बरेली शरीफ़',
        'हमारी तंज़ीम - जमाअत रज़ाए मुस्तफा',
        'हमारे क़ाइद - अल्लामा असजद रज़ा',
        'मिनजानिब: फैज़े रज़ा ग्रुप मेहकर, ज़िला बुलढाणा, महाराष्ट्र',
        '9595908313  /  7350827414  /  9975500521',
      ],
    );

class AboutUsScreen extends StatefulWidget {
  const AboutUsScreen({super.key});
  @override
  State<AboutUsScreen> createState() => _AboutUsScreenState();
}

class _AboutUsScreenState extends State<AboutUsScreen> {
  AboutUsContent? _remote;
  // True only once the fetch has actually failed (offline / unreachable) -
  // distinct from "still loading". Previously this screen rendered the
  // bundled, possibly-outdated _aboutUsFallback() text immediately and
  // then replaced it with the real database content once the fetch
  // resolved a moment later, so every open visibly flashed old content
  // before "refreshing" to the current one. Now the bundled copy is only
  // ever shown for a genuine failure; otherwise the screen waits for the
  // live content so what's shown is always up to date on the first paint.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Fetches directly from Supabase rather than through the app's main
  // AppState, because this screen is reachable before login (the login
  // screen's "No login needed for these tools" row) where that state
  // hasn't been populated yet - the anon key can still read about_us
  // since its RLS policy allows anon + authenticated select.
  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client.from('about_us').select().eq('id', 1).maybeSingle();
      if (!mounted) return;
      if (row == null) {
        setState(() => _failed = true);
        return;
      }
      setState(() {
        _remote = AboutUsContent(
          heading: (row['heading'] as String?) ?? '',
          subheading: (row['subheading'] as String?) ?? '',
          sections: ((row['sections'] as List?) ?? const []).map((e) => AboutUsSection.fromJson(e as Map<String, dynamic>)).toList(),
          contactLines: ((row['contact_lines'] as List?) ?? const []).map((e) => e.toString()).toList(),
        );
      });
    } catch (_) {
      // Offline or not reachable - the fallback below is shown instead.
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: guestAppBar(context, 'About Us'),
      // SafeArea + generous bottom padding: without it, the last card (the
      // contact numbers) sat right at the very edge of the screen, under a
      // phone's gesture bar on some devices - this leaves real breathing
      // room below it instead.
      body: SafeArea(
        child: _remote == null && !_failed
            ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  ...aboutUsBodyWidgets(_remote ?? _aboutUsFallback()),
                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }
}

// ---------------- Maktab Timing (Guest Tools) ----------------
// Read-only, no-login view of which Morning/Afternoon/Evening batch each
// class actually runs in, per active Maktab branch. Reuses exactly the
// existing Maktab/class/student data the authenticated "Working Committee >
// Maktab Timings" screen already computes (lib/main.dart,
// CommitteeMaktabTimings) - no separate timing table. Since a guest has no
// session, this calls the public.guest_maktab_timings() RPC instead of
// reading st.students directly: that function runs with elevated rights on
// the server and only ever returns an aggregated (Maktab, class, most
// common batch) triple - never an individual student row, phone number, or
// teacher name - so nothing private reaches an unauthenticated device.

IconData _categoryIcon(String? category) {
  switch (category) {
    case 'Boys':
      return Icons.boy;
    case 'Girls':
      return Icons.girl;
    case 'Children':
      return Icons.child_care;
    default:
      return Icons.apartment;
  }
}

class _GuestTimingClassRow {
  final int classNo;
  final String className;
  final String? timing; // null => "Timing Not Set"
  _GuestTimingClassRow({required this.classNo, required this.className, this.timing});
}

class _GuestTimingBranch {
  final String maktabName;
  final String? category;
  final List<_GuestTimingClassRow> classes;
  _GuestTimingBranch({required this.maktabName, this.category, required this.classes});
}

class GuestMaktabTimingScreen extends StatefulWidget {
  const GuestMaktabTimingScreen({super.key});
  @override
  State<GuestMaktabTimingScreen> createState() => _GuestMaktabTimingScreenState();
}

class _GuestMaktabTimingScreenState extends State<GuestMaktabTimingScreen> {
  bool _loading = true;
  String? _error;
  List<_GuestTimingBranch> _branches = [];
  final TextEditingController _search = TextEditingController();
  String? _category; // null = All

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await Supabase.instance.client.rpc('guest_maktab_timings') as List<dynamic>;
      final byBranch = <String, _GuestTimingBranch>{};
      for (final r in rows) {
        final m = r as Map<String, dynamic>;
        final name = (m['madrasa_name'] as String?) ?? '';
        if (name.isEmpty) continue;
        final category = m['category'] as String?;
        final key = '$name|${category ?? ''}';
        final classRow = _GuestTimingClassRow(
          classNo: (m['class_no'] as num?)?.toInt() ?? 0,
          className: (m['class_name'] as String?) ?? 'Class',
          timing: m['timing'] as String?,
        );
        final existing = byBranch[key];
        if (existing == null) {
          byBranch[key] = _GuestTimingBranch(maktabName: name, category: category, classes: [classRow]);
        } else {
          existing.classes.add(classRow);
        }
      }
      final list = byBranch.values.toList()..sort((a, b) => a.maktabName.compareTo(b.maktabName));
      for (final b in list) {
        b.classes.sort((a, c) => a.classNo.compareTo(c.classNo));
      }
      if (!mounted) return;
      setState(() {
        _branches = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load Maktab Timing right now. Check your internet connection and try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final filtered = _branches.where((b) {
      if (_category != null && b.category != _category) return false;
      if (q.isEmpty) return true;
      return b.maktabName.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: guestAppBar(context, 'Maktab Timing'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.wifi_off, size: 40, color: Colors.black38),
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Retry')),
                    ]),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    const Text(
                      'Existing Morning / Afternoon / Evening class timing by Maktab branch - view only.',
                      style: TextStyle(color: Colors.black54, fontSize: 12.5),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _search,
                      decoration: const InputDecoration(
                        labelText: 'Search Maktab or branch name',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      ChoiceChip(label: const Text('All'), selected: _category == null, onSelected: (_) => setState(() => _category = null)),
                      for (final c in kMadrasaCategories)
                        ChoiceChip(label: Text(c), selected: _category == c, onSelected: (_) => setState(() => _category = c)),
                    ]),
                    const SizedBox(height: 14),
                    if (filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Column(children: [
                          const Icon(Icons.search_off, size: 36, color: Colors.black26),
                          const SizedBox(height: 10),
                          Text(
                            _branches.isEmpty ? 'No Maktab branches are available to show right now.' : 'No branch matches this search or filter.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.black54),
                          ),
                        ]),
                      )
                    else
                      for (final b in filtered)
                        Card(
                          child: ListTile(
                            leading: CircleAvatar(backgroundColor: const Color(0xFFEEF4E8), child: Icon(_categoryIcon(b.category), color: _kGreen)),
                            title: Text(b.maktabName, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text('Category: ${b.category ?? 'Not set'} - ${b.classes.length} class(es)'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => GuestMaktabTimingDetail(branch: b))),
                          ),
                        ),
                  ]),
                ),
    );
  }
}

class GuestMaktabTimingDetail extends StatelessWidget {
  final _GuestTimingBranch branch;
  const GuestMaktabTimingDetail({super.key, required this.branch});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: guestAppBar(context, branch.maktabName),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: const Color(0xFFEEF4E8),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(_categoryIcon(branch.category), color: _kGreen, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(branch.maktabName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('Category: ${branch.category ?? 'Not set'}', style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        const Text('Class-wise timing', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        const SizedBox(height: 6),
        if (branch.classes.isEmpty) const Text('No classes are set up for this branch yet.', style: TextStyle(color: Colors.black54)),
        for (final c in branch.classes)
          Card(
            child: ListTile(
              dense: true,
              title: Text(c.className, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
              trailing: Text(
                c.timing ?? 'Timing Not Set',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: c.timing == null ? Colors.orange.shade800 : _kGreen,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
