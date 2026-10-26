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

  @override
  void initState() {
    super.initState();
    _loadOffset();
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
                  // same pairing a printed Razvi calendar box shows.
                  final hDay = _gregorianToHijri(date.add(Duration(days: hijriOffset)))[2];
                  return Container(
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
                    ]),
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
                    ? 'جمعہ کا دن نمایاں ہے۔ لاگ ان کرنے کے بعد آپ کے مدرسے کی تعطیلات اور تقریبات بھی یہاں نظر آئیں گی۔'
                    : "Fridays are highlighted. Once you log in, your madrasa's holidays and events also appear here.",
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

  Widget _ready() {
    final rows = [
      ['Fajr', timings['Fajr']],
      ['Sunrise', timings['Sunrise']],
      ['Dhuhr', timings['Dhuhr']],
      ['Asr', timings['Asr']],
      ['Maghrib', timings['Maghrib']],
      ['Isha', timings['Isha']],
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
                            IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'Previous page', onPressed: _page > 0 ? () => _goTo(_page - 1) : null),
                            TextButton(onPressed: _pickPage, child: Text('Page ${_page + 1} of ${pages.length}')),
                            IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'Next page', onPressed: _page < pages.length - 1 ? () => _goTo(_page + 1) : null),
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
            for (final p in s.paras) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(p, style: const TextStyle(fontSize: 13.5, height: 1.5))),
            for (final b in s.bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('•  ', style: TextStyle(color: _kGreen, fontWeight: FontWeight.bold)),
                  Expanded(child: Text(b, style: const TextStyle(fontSize: 13.5, height: 1.4))),
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
      if (row == null || !mounted) return;
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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: guestAppBar(context, 'About Us'),
      body: ListView(padding: const EdgeInsets.all(16), children: aboutUsBodyWidgets(_remote ?? _aboutUsFallback())),
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
