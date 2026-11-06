// ============================================================
// Prayer Times - "celestial dial" view.
// A round clock with a gold crescent travelling the day's loop (noon at
// the top, midnight at the bottom), live time and next-prayer countdown,
// a draggable timeline ruler to preview any time of day, and a glass
// sheet listing the prayers with alarm switches and Makruh (forbidden)
// time warnings. The prayer alarm (notification) switch is kept.
// ============================================================
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;
import 'package:flutter/material.dart';
import 'prayer_notifications.dart' show kMaghribOffsetMinutes;

const Color _kGold = Color(0xFFD4AF37);
const Color _kAmber = Color(0xFFF39C12);
const Color _kBrightGold = Color(0xFFF1C40F);
const Color _kSage = Color(0xFF7F8C8D);
const Color _kCrimson = Color(0xFFE74C3C);
const Color _kSlate = Color(0xFF0B0F17);
const Color _kEmerald = Color(0xFF041C16);

Color _a(Color c, double o) => c.withAlpha((o * 255).round().clamp(0, 255));

double? _mins(String? hhmm) {
  if (hhmm == null) return null;
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(hhmm.trim());
  if (m == null) return null;
  return int.parse(m.group(1)!) * 60.0 + int.parse(m.group(2)!);
}

String _fmt12(double minutes) {
  final t = minutes.round() % 1440;
  var h = t ~/ 60;
  final mm = t % 60;
  final suffix = h >= 12 ? 'PM' : 'AM';
  h %= 12;
  if (h == 0) h = 12;
  return '$h:${mm.toString().padLeft(2, '0')} $suffix';
}

class _Ev {
  final String name; // display label
  final String key; // Aladhan key for real prayers, '' otherwise
  final double at;
  final IconData icon;
  const _Ev(this.name, this.key, this.at, this.icon);
  bool get isPrayer => key.isNotEmpty;
}

class PrayerDialView extends StatefulWidget {
  const PrayerDialView({
    super.key,
    required this.timings,
    required this.placeLabel,
    required this.notifEnabled,
    required this.notifBusy,
    required this.notifSummary,
    required this.muted,
    required this.onToggleNotif,
    required this.onToggleMute,
    required this.onUpdateLocation,
    required this.onTest,
    required this.updating,
  });
  final Map<String, String> timings;
  final String placeLabel;
  final bool notifEnabled;
  final bool notifBusy;
  final String notifSummary;
  final Set<String> muted;
  final ValueChanged<bool> onToggleNotif;
  final ValueChanged<String> onToggleMute;
  final VoidCallback onUpdateLocation;
  final VoidCallback onTest;
  final bool updating;
  @override
  State<PrayerDialView> createState() => _PrayerDialViewState();
}

class _PrayerDialViewState extends State<PrayerDialView> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
  Timer? _tick;
  DateTime _now = DateTime.now();
  double? _scrub; // minutes of day while previewing; null = live

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  double get _liveMinutes => _now.hour * 60.0 + _now.minute + _now.second / 60.0;
  double get _t => _scrub ?? _liveMinutes;

  List<_Ev> get _events {
    final tm = widget.timings;
    final fajr = _mins(tm['Fajr']) ?? 300;
    final sunrise = _mins(tm['Sunrise']) ?? 390;
    final dhuhr = _mins(tm['Dhuhr']) ?? 730;
    final asr = _mins(tm['Asr']) ?? 990;
    final maghrib = _mins(tm['Maghrib']) ?? 1070;
    final sunset = _mins(tm['Sunset']) ?? (maghrib - kMaghribOffsetMinutes);
    final isha = _mins(tm['Isha']) ?? 1150;
    final dk = (fajr + sunset) / 2; // Dahwa-Kubra: midpoint of Fajr and sunset (Hanafi)
    return [
      _Ev('Fajr', 'Fajr', fajr, Icons.auto_awesome),
      _Ev('Sunrise', '', sunrise, Icons.wb_twilight),
      _Ev('Dahwa-Kubra', '', dk, Icons.error_outline),
      _Ev('Zuhr', 'Dhuhr', dhuhr, Icons.wb_sunny_outlined),
      _Ev('Asr', 'Asr', asr, Icons.light_mode_outlined),
      _Ev('Makruh Time', '', maghrib - 20, Icons.block),
      _Ev('Maghrib', 'Maghrib', maghrib, Icons.wb_twilight),
      _Ev('Isha', 'Isha', isha, Icons.nightlight_round),
    ];
  }

  // Makruh (forbidden for salah) windows: sunrise (+20 min), zawal (from
  // Dahwa-Kubra until Zuhr) and sunset (the 20 minutes before sunset).
  String? _forbiddenRow(double t, List<_Ev> ev) {
    final sunrise = ev[1].at, dk = ev[2].at, dhuhr = ev[3].at, maghrib = ev[6].at;
    if (t >= sunrise && t < sunrise + 20) return 'Sunrise';
    if (t >= dk && t < dhuhr) return 'Dahwa-Kubra';
    if (t >= maghrib - 20 && t < maghrib) return 'Makruh Time';
    return null;
  }

  _Ev _active(double t, List<_Ev> ev) {
    _Ev cur = ev.last;
    for (final e in ev) {
      if (e.at <= t) cur = e;
    }
    return cur;
  }

  ({String name, double diff}) _next(double t, List<_Ev> ev) {
    for (final e in ev.where((e) => e.isPrayer)) {
      if (e.at > t) return (name: e.name, diff: e.at - t);
    }
    final f = ev.first;
    return (name: f.name, diff: f.at + 1440 - t);
  }

  String _dur(double m) {
    final total = m.ceil();
    final h = total ~/ 60, mm = total % 60;
    return h > 0 ? '${h}h ${mm}m' : '${mm}m';
  }

  Color _tint(double t) {
    // Amber around Zuhr, deep teal at night, neutral otherwise.
    final dayS = (1 - ((t - 780).abs() / 240)).clamp(0.0, 1.0);
    final nightDist = t < 300 ? 300 - t : (t > 1140 ? t - 1140 : 0.0);
    final nightS = (nightDist / 180).clamp(0.0, 1.0);
    if (dayS > 0) return Color.lerp(Colors.transparent, _a(_kAmber, 0.22), dayS)!;
    return Color.lerp(Colors.transparent, _a(const Color(0xFF0E7C7B), 0.22), nightS)!;
  }

  @override
  Widget build(BuildContext context) {
    final ev = _events;
    final t = _t;
    final act = _active(t, ev);
    final nxt = _next(t, ev);
    final forbidden = _forbiddenRow(t, ev);
    final tint = _tint(t);
    final live = _scrub == null;
    final secs = live ? _now.second : 0;
    final tm = t.floor() % 1440;
    var h12 = (tm ~/ 60) % 12;
    if (h12 == 0) h12 = 12;
    final clock = '$h12:${(tm % 60).toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    final ampm = (tm ~/ 60) >= 12 ? 'PM' : 'AM';
    final glyph = act.name == 'Isha' ? Icons.nightlight_round : (act.name == 'Fajr' || act.name == 'Sunrise' || act.name == 'Maghrib') ? Icons.wb_twilight : Icons.wb_sunny;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.alphaBlend(tint, _kSlate), Color.alphaBlend(_a(tint, 0.4), _kEmerald)],
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
        children: [
          Center(child: _locationPill()),
          const SizedBox(height: 14),
          SizedBox(
            height: 300,
            child: Stack(alignment: Alignment.center, children: [
              Positioned.fill(child: CustomPaint(painter: _DialPainter(events: ev, t: t, activeName: act.name))),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(glyph, color: _kGold, size: 22),
                const SizedBox(height: 6),
                Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(clock, style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w800, letterSpacing: 0.5, fontFeatures: [FontFeature.tabularFigures()])),
                  const SizedBox(width: 4),
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(ampm, style: TextStyle(color: _a(Colors.white, 0.7), fontSize: 12, fontWeight: FontWeight.w600))),
                ]),
                const SizedBox(height: 4),
                Text(act.name.toUpperCase().split('').join(' '), style: const TextStyle(color: _kGold, fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 2)),
                const SizedBox(height: 6),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.circle, size: 7, color: _kAmber),
                  const SizedBox(width: 6),
                  Text('Next Prayer: ${nxt.name} in ${_dur(nxt.diff)}', style: const TextStyle(color: _kAmber, fontSize: 12.5)),
                ]),
              ]),
            ]),
          ),
          const SizedBox(height: 6),
          _ruler(ev),
          if (!live)
            Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _scrub = null),
                icon: const Icon(Icons.my_location, size: 16, color: _kAmber),
                label: const Text('Back to now', style: TextStyle(color: _kAmber, fontSize: 12.5)),
              ),
            ),
          const SizedBox(height: 10),
          _sheet(ev, act, forbidden),
        ],
      ),
    );
  }

  Widget _locationPill() => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: _a(Colors.black, 0.35), borderRadius: BorderRadius.circular(22), border: Border.all(color: _a(Colors.white, 0.12))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.location_on, size: 15, color: Colors.white),
                const SizedBox(width: 6),
                Text(widget.placeLabel, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600, letterSpacing: 1.2)),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 6),
        widget.updating
            ? const Padding(padding: EdgeInsets.all(10), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: _kGold)))
            : IconButton(tooltip: 'Update current location', onPressed: widget.onUpdateLocation, icon: const Icon(Icons.my_location, size: 20, color: _kGold)),
      ]);

  Widget _ruler(List<_Ev> ev) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth - 32;
      void setFrom(double dx) => setState(() => _scrub = ((dx - 16) / w * 1440).clamp(0.0, 1439.0));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => setFrom(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => setFrom(d.localPosition.dx),
        onTapDown: (d) => setFrom(d.localPosition.dx),
        child: SizedBox(height: 64, width: double.infinity, child: CustomPaint(painter: _RulerPainter(t: _t, events: ev))),
      );
    });
  }

  Widget _sheet(List<_Ev> ev, _Ev act, String? forbidden) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          decoration: BoxDecoration(color: _a(Colors.white, 0.07), border: Border(top: BorderSide(color: _a(Colors.white, 0.14)))),
          child: Column(children: [
            Row(children: [
              Icon(Icons.notifications_active_outlined, size: 20, color: widget.notifEnabled ? _kBrightGold : _kSage),
              const SizedBox(width: 10),
              const Expanded(child: Text('Prayer alarm', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14.5))),
              Switch(value: widget.notifEnabled, activeColor: _kBrightGold, onChanged: widget.notifBusy ? null : widget.onToggleNotif),
            ]),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  widget.notifEnabled
                      ? (widget.notifSummary.isEmpty ? 'A notification arrives at each prayer time, even when the app is closed.' : widget.notifSummary)
                      : 'Turn on to get a notification at every prayer time.',
                  style: TextStyle(color: _a(Colors.white, 0.55), fontSize: 11.5),
                ),
              ),
            ),
            for (final e in ev) _row(e, e.name == act.name, forbidden == e.name),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: widget.notifBusy ? null : widget.onTest,
                icon: const Icon(Icons.notifications_none, size: 16, color: _kSage),
                label: const Text('Send test notification', style: TextStyle(color: _kSage, fontSize: 12)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Asr uses the Hanafi method. Maghrib includes +$kMaghribOffsetMinutes minutes. Makruh Time is the 20 minutes before Maghrib (no salah). Dahwa-Kubra is the midpoint between Fajr and sunset; no salah from then until Zuhr begins. Times are for your GPS location and may differ a few minutes from the local timetable.",
              style: TextStyle(color: _a(Colors.white, 0.45), fontSize: 11),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _row(_Ev e, bool active, bool forbidden) {
    final muted = widget.muted.contains(e.key);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final p = _pulse.value;
        final timeColor = forbidden ? Color.lerp(_a(_kCrimson, 0.45), _kCrimson, p)! : (active ? _kBrightGold : _a(Colors.white, 0.8));
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: active
              ? BoxDecoration(color: _a(_kGold, 0.14), borderRadius: BorderRadius.circular(16), border: Border.all(color: _a(_kGold, 0.65)), boxShadow: [BoxShadow(color: _a(_kGold, 0.15 + 0.1 * p), blurRadius: 12)])
              : null,
          child: Row(children: [
            Icon(e.icon, size: 19, color: forbidden ? _kCrimson : (active ? _kBrightGold : _kSage)),
            const SizedBox(width: 12),
            Expanded(
              child: Row(children: [
                Text(e.name.toUpperCase(), style: TextStyle(color: active ? Colors.white : _a(Colors.white, 0.75), fontWeight: active ? FontWeight.w800 : FontWeight.w600, letterSpacing: 1.1, fontSize: 13.5)),
                if (active) ...[
                  const SizedBox(width: 8),
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: const Color(0xFF2ECC71), shape: BoxShape.circle, boxShadow: [BoxShadow(color: _a(const Color(0xFF2ECC71), 0.4 + 0.5 * p), blurRadius: 4 + 6 * p)])),
                ],
              ]),
            ),
            Text(_fmt12(e.at), style: TextStyle(color: timeColor, fontWeight: FontWeight.w700, fontSize: 14.5)),
            SizedBox(
              width: 40,
              child: e.isPrayer
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      tooltip: muted ? 'Alarm off' : 'Alarm on',
                      icon: Icon(muted || !widget.notifEnabled ? Icons.volume_off : Icons.volume_up, size: 19, color: muted || !widget.notifEnabled ? _kSage : _kBrightGold),
                      onPressed: () => widget.onToggleMute(e.key),
                    )
                  : null,
            ),
          ]),
        );
      },
    );
  }
}

// ---------------- Dial painter ----------------
class _DialPainter extends CustomPainter {
  _DialPainter({required this.events, required this.t, required this.activeName});
  final List<_Ev> events;
  final double t;
  final String activeName;

  Offset _pt(Offset c, double r, double minutes) {
    final phi = (minutes - 720) / 1440 * 2 * math.pi;
    return Offset(c.dx + r * math.sin(phi), c.dy - r * math.cos(phi));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) * 0.36;

    // faint stars inside the ring
    final rnd = math.Random(7);
    final star = Paint()..color = _a(Colors.white, 0.35);
    for (var i = 0; i < 70; i++) {
      final ang = rnd.nextDouble() * 2 * math.pi;
      final rad = math.sqrt(rnd.nextDouble()) * (r - 6);
      canvas.drawCircle(Offset(c.dx + rad * math.cos(ang), c.dy + rad * math.sin(ang)), rnd.nextDouble() * 0.9 + 0.2, star);
    }

    // celestial path: soft ring + star-lattice pattern
    canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.4..color = _a(_kGold, 0.15));
    final lattice = Paint()..color = _a(_kGold, 0.22)..strokeWidth = 1;
    for (var i = 0; i < 96; i++) {
      final a = i / 96 * 2 * math.pi;
      final big = i % 4 == 0;
      final r1 = r - (big ? 5 : 3), r2 = r + (big ? 5 : 3);
      canvas.drawLine(Offset(c.dx + r1 * math.sin(a), c.dy - r1 * math.cos(a)), Offset(c.dx + r2 * math.sin(a), c.dy - r2 * math.cos(a)), lattice);
    }

    // Makruh window before Maghrib: red arc on the ring
    for (final e in events) {
      if (e.name != 'Makruh Time') continue;
      final start = (e.at - 720) / 1440 * 2 * math.pi - math.pi / 2;
      final sweep = 20 / 1440 * 2 * math.pi;
      final rect = Rect.fromCircle(center: c, radius: r);
      canvas.drawArc(rect, start, sweep, false, Paint()..style = PaintingStyle.stroke..strokeWidth = 7..strokeCap = StrokeCap.round..color = _a(_kCrimson, 0.35)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawArc(rect, start, sweep, false, Paint()..style = PaintingStyle.stroke..strokeWidth = 3.2..strokeCap = StrokeCap.round..color = _kCrimson);
    }

    // trail behind the node
    for (var i = 1; i <= 24; i++) {
      final back = t - i * 4.0;
      canvas.drawCircle(_pt(c, r, back), 1.6, Paint()..color = _a(_kGold, 0.30 * (1 - i / 24)));
    }

    // prayer markers + time labels (labels that would collide are pushed outward)
    final placed = <Rect>[];
    for (final e in events) {
      if (e.name == 'Makruh Time') continue;
      final p = _pt(c, r, e.at);
      final isAct = e.name == activeName;
      canvas.drawCircle(p, isAct ? 3.2 : 2.2, Paint()..color = isAct ? _kBrightGold : _a(Colors.white, 0.5));
      final tp = TextPainter(
        text: TextSpan(text: _fmt12(e.at).toLowerCase(), style: TextStyle(color: isAct ? Colors.white : _a(Colors.white, 0.6), fontSize: 9.5, fontWeight: isAct ? FontWeight.w700 : FontWeight.w400)),
        textDirection: TextDirection.ltr,
      )..layout();
      var rr = r + 24;
      Rect box = Rect.zero;
      for (var k = 0; k < 4; k++) {
        final lp = _pt(c, rr, e.at);
        box = Rect.fromCenter(center: lp, width: tp.width + 6, height: tp.height + 2);
        if (!placed.any((o) => o.overlaps(box))) break;
        rr += tp.height + 3;
      }
      placed.add(box);
      tp.paint(canvas, Offset(box.center.dx - tp.width / 2, box.center.dy - tp.height / 2));
    }

    // crescent moon node with glow
    final n = _pt(c, r, t);
    canvas.drawCircle(n, 16, Paint()..color = _a(_kGold, 0.55)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    final moon = Path.combine(PathOperation.difference, Path()..addOval(Rect.fromCircle(center: n, radius: 10)), Path()..addOval(Rect.fromCircle(center: n.translate(4.5, -3.5), radius: 8.5)));
    canvas.drawPath(moon, Paint()..color = _kGold);
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) => old.t != t || old.activeName != activeName;
}

// ---------------- Timeline ruler ----------------
class _RulerPainter extends CustomPainter {
  _RulerPainter({required this.t, required this.events});
  final double t;
  final List<_Ev> events;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 16.0;
    final w = size.width - pad * 2;
    final tick = Paint()..strokeWidth = 1.2;
    final baseY = size.height / 2 + 4;
    for (var i = 0; i <= 144; i++) {
      final x = pad + w * i / 144;
      final hour = i % 6 == 0;
      tick.color = _a(Colors.white, hour ? 0.55 : 0.25);
      canvas.drawLine(Offset(x, baseY - (hour ? 12 : 6)), Offset(x, baseY + (hour ? 12 : 6)), tick);
    }
    for (final e in events) {
      canvas.drawCircle(Offset(pad + w * e.at / 1440, baseY + 24), 2, Paint()..color = _a(_kGold, 0.8));
    }
    // scrubber
    final x = pad + w * (t / 1440).clamp(0.0, 1.0);
    final pill = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, baseY), width: 12, height: 40), const Radius.circular(8));
    canvas.drawRRect(pill, Paint()..color = _a(Colors.white, 0.18));
    canvas.drawRRect(pill, Paint()..style = PaintingStyle.stroke..color = _a(Colors.white, 0.5)..strokeWidth = 1);
    canvas.drawCircle(Offset(x, baseY + 24), 7, Paint()..color = _a(_kAmber, 0.6)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(Offset(x, baseY + 24), 3.5, Paint()..color = _kAmber);
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) => old.t != t;
}
