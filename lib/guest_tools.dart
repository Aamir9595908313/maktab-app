import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color _kGreen = Color(0xFF054D00);
const Color _kGold = Color(0xFFD4A72C);

const double _sampleLat = 18.5204; 
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

// Fixed AppBar Widget Structure
class GuestAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  const GuestAppBar({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      backgroundColor: _kGreen,
      foregroundColor: Colors.white,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

// ---------------- Qibla ----------------
class QiblaScreen extends StatelessWidget {
  const QiblaScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final bearing = _qiblaBearing();
    return Scaffold(
      appBar: GuestAppBar(title: 'Qibla Direction'),
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
                'This works fully offline once the location is known, and no login is needed.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- Calendar ----------------
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  bool urdu = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GuestAppBar(title: urdu ? 'کیلنڈر' : 'Calendar'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ToggleButtons(
            isSelected: [!urdu, urdu],
            onPressed: (i) => setState(() => urdu = i == 1),
            borderRadius: BorderRadius.circular(8),
            children: const [
              Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('English')), 
              Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('اردو'))
            ],
          ),
          const SizedBox(height: 14),
          const Card(
            color: Color(0xFFEEF4E8),
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('Calendar View Loaded Successfully.', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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

  void _tap() {
    HapticFeedback.lightImpact();
    setState(() => count++);
  }

  void _reset() {
    setState(() => count = 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const GuestAppBar(title: 'Tasbeeh Counter'),
      body: Column(children: [
        const SizedBox(height: 20),
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: _tap,
              child: Container(
                width: 220,
                height: 220,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: _kGreen),
                alignment: Alignment.center,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$count', style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.bold)),
                  Text('of $target', style: const TextStyle(color: Color(0xFFF0D98A), fontSize: 16)),
                ]),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(onPressed: _reset, icon: const Icon(Icons.refresh), label: const Text('Reset')),
        ),
      ]),
    );
  }
}
