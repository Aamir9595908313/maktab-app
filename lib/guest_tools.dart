import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color _kGreen = Color(0xFF054D00);
const Color _kGold = Color(0xFFD4A72C);

// A sample fixed location, since this demo has no GPS/compass plugin wired up.
// A production build reads the phone's real GPS location and live compass
// heading (e.g. with the geolocator and flutter_compass packages) instead.
const double _sampleLat = 18.5204; // Pune, India (sample location)
const double _sampleLng = 73.8567;
const String _sampleCity = 'Pune, India (sample location)';
const double _kaabaLat = 21.4225;
const double _kaabaLng = 39.8262;

double _qiblaBearing() {
  final phi1 = _sampleLat * math.pi / 180;
  final phi2 = _kaabaLat * math.pi / 180;
  final dLambda = (_kaabaLng - _sampleLng) * math.pi / 180;
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
class QiblaScreen extends StatelessWidget {
  const QiblaScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final bearing = _qiblaBearing();
    return Scaffold(
      appBar: guestAppBar(context, 'Qibla Direction'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Detected location', style: TextStyle(color: Colors.black54, fontSize: 12)),
          Text(_sampleCity, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                Transform.rotate(
                  angle: bearing * math.pi / 180,
                  child: const Icon(Icons.navigation, size: 90, color: _kGold),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: Column(children: [
              Text('${bearing.toStringAsFixed(0)} deg (${_compassPoint(bearing)}) from North', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _kGreen)),
              const SizedBox(height: 4),
              const Text('Direction to the Kaaba, Makkah', style: TextStyle(color: Colors.black54)),
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
                'This works fully offline once the location is known, and no login is needed. '
                'This demo uses a fixed sample location; the finished app reads the phone\'s live GPS and compass heading so the arrow rotates as you turn the phone.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ),
          ),
        ],
      ),
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
  DateTime shown = DateTime.parse('2026-09-19');
  final DateTime today = DateTime.parse('2026-09-19');

  @override
  Widget build(BuildContext context) {
    final hToday = _gregorianToHijri(today);
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
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(onPressed: () => setState(() => shown = DateTime(shown.year, shown.month - 1, 1)), icon: const Icon(Icons.chevron_left)),
            Text('${urdu ? _gMonthsUr[shown.month - 1] : _gMonthsEn[shown.month - 1]} ${shown.year}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            IconButton(onPressed: () => setState(() => shown = DateTime(shown.year, shown.month + 1, 1)), icon: const Icon(Icons.chevron_right)),
          ]),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final w in (urdu ? _wdUr : _wdEn)) Center(child: Text(w, style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.bold))),
              for (var i = 0; i < leading; i++) const SizedBox(),
              for (var d = 1; d <= daysInMonth; d++)
                Builder(builder: (context) {
                  final date = DateTime(shown.year, shown.month, d);
                  final isFriday = date.weekday == DateTime.friday;
                  final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
                  return Container(
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: isToday ? _kGreen : (isFriday ? const Color(0xFFFFF3CF) : null),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text('$d', style: TextStyle(color: isToday ? Colors.white : Colors.black87, fontWeight: isFriday || isToday ? FontWeight.bold : FontWeight.normal, fontSize: 12)),
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
