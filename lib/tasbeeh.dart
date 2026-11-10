// Tasbeeh Counter - dark digital counter with multiple dhikr counters,
// rounds, target progress arc, session timer, auto-count, statistics and
// settings. Everything is stored on the phone (SharedPreferences); no login.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bg = Color(0xFF0A3D14);
const _bgDark = Color(0xFF052A0C);
const _panel = Color(0xFF07300F);
const _gold = Color(0xFFF5B82E);

class _Dhikr {
  String id;
  String name;
  int target;
  int count; // inside the current round
  int rounds;
  int total;
  _Dhikr({required this.id, required this.name, required this.target, this.count = 0, this.rounds = 0, this.total = 0});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'target': target, 'count': count, 'rounds': rounds, 'total': total};
  factory _Dhikr.fromJson(Map<String, dynamic> j) => _Dhikr(
        id: '${j['id']}',
        name: '${j['name']}',
        target: (j['target'] as num?)?.toInt() ?? 33,
        count: (j['count'] as num?)?.toInt() ?? 0,
        rounds: (j['rounds'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
      );
}

const List<List<Object>> _presets = [
  ['SubhanAllah', 33],
  ['Alhamdulillah', 33],
  ['Allahu Akbar', 34],
  ['La ilaha illallah', 100],
  ['Astaghfirullah', 100],
  ['Darood Sharif', 100],
  ['Ya Allah', 99],
  ['Hasbunallahu wa ni\'mal wakeel', 450],
  ['Durood-e-Taj', 11],
  ['Gaos-e-Azam', 11],
];

String _dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class TasbeehCounterScreen extends StatefulWidget {
  const TasbeehCounterScreen({super.key});
  @override
  State<TasbeehCounterScreen> createState() => _TasbeehCounterScreenState();
}

class _TasbeehCounterScreenState extends State<TasbeehCounterScreen> {
  List<_Dhikr> dhikrs = [];
  int cur = 0;
  Map<String, int> daily = {};
  bool loaded = false;

  // settings
  bool sound = true;
  bool vibrate = true;
  bool celebrate = true;
  int autoMs = 1000;

  // timer
  bool timerRunning = false;
  int elapsed = 0;
  Timer? _ticker;

  // auto count
  bool auto = false;
  Timer? _autoTimer;

  final AudioPlayer _clickPlayer = AudioPlayer();
  final AudioPlayer _donePlayer = AudioPlayer();

  Future<void> _buzz(int ms, {int amp = 128}) async {
    try {
      if (await Vibration.hasVibrator() == true) {
        Vibration.vibrate(duration: ms, amplitude: amp);
        return;
      }
    } catch (_) {}
    HapticFeedback.mediumImpact();
  }

  Future<void> _playClick() async {
    try {
      await _clickPlayer.stop();
      await _clickPlayer.play(AssetSource('sounds/click.wav'));
    } catch (_) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  Future<void> _playDone() async {
    try {
      await _donePlayer.stop();
      await _donePlayer.play(AssetSource('sounds/done.wav'));
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
    }
  }

  _Dhikr get d => dhikrs[cur];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _autoTimer?.cancel();
    _clickPlayer.dispose();
    _donePlayer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('tasbeeh_dhikrs');
      if (raw != null) {
        dhikrs = [for (final x in (jsonDecode(raw) as List)) _Dhikr.fromJson(Map<String, dynamic>.from(x as Map))];
      }
      cur = p.getInt('tasbeeh_cur') ?? 0;
      final dr = p.getString('tasbeeh_daily');
      if (dr != null) daily = {for (final e in (jsonDecode(dr) as Map).entries) '${e.key}': (e.value as num).toInt()};
      sound = p.getBool('tasbeeh_sound') ?? true;
      vibrate = p.getBool('tasbeeh_vibrate') ?? true;
      celebrate = p.getBool('tasbeeh_celebrate') ?? true;
      autoMs = p.getInt('tasbeeh_auto_ms') ?? 1000;
      elapsed = p.getInt('tasbeeh_elapsed') ?? 0;
      // Older single counter from the previous version.
      if (dhikrs.isEmpty) {
        final oldCount = p.getInt('tasbeeh_count') ?? 0;
        final oldTarget = p.getInt('tasbeeh_target') ?? 33;
        dhikrs = [_Dhikr(id: 'd1', name: 'Tasbeeh', target: oldTarget, count: oldCount % oldTarget, total: oldCount, rounds: oldCount ~/ oldTarget)];
      }
    } catch (_) {}
    if (dhikrs.isEmpty) dhikrs = [_Dhikr(id: 'd1', name: 'SubhanAllah', target: 33)];
    if (cur < 0 || cur >= dhikrs.length) cur = 0;
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('tasbeeh_dhikrs', jsonEncode([for (final x in dhikrs) x.toJson()]));
      await p.setInt('tasbeeh_cur', cur);
      await p.setString('tasbeeh_daily', jsonEncode(daily));
      await p.setBool('tasbeeh_sound', sound);
      await p.setBool('tasbeeh_vibrate', vibrate);
      await p.setBool('tasbeeh_celebrate', celebrate);
      await p.setInt('tasbeeh_auto_ms', autoMs);
      await p.setInt('tasbeeh_elapsed', elapsed);
    } catch (_) {}
  }

  // ---- counting ----
  void _inc({bool fromAuto = false}) {
    if (!loaded) return;
    final todayKey = _dayKey(DateTime.now());
    setState(() {
      d.count++;
      d.total++;
      daily[todayKey] = (daily[todayKey] ?? 0) + 1;
      if (d.count >= d.target) {
        d.count = 0;
        d.rounds++;
        if (celebrate) {
          if (vibrate) _buzz(400, amp: 255);
          if (sound) _playDone();
        } else {
          if (vibrate) _buzz(40);
          if (sound) _playClick();
        }
      } else {
        if (vibrate) _buzz(40);
        if (sound) _playClick();
      }
    });
    _save();
  }

  void _dec() {
    final todayKey = _dayKey(DateTime.now());
    setState(() {
      if (d.count > 0) {
        d.count--;
      } else if (d.rounds > 0) {
        d.rounds--;
        d.count = d.target - 1;
      } else {
        return;
      }
      if (d.total > 0) d.total--;
      final t = daily[todayKey] ?? 0;
      if (t > 0) daily[todayKey] = t - 1;
    });
    if (vibrate) _buzz(25, amp: 80);
    _save();
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset counter?'),
        content: Text('"${d.name}" will go back to 0 (count, rounds and total).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      d.count = 0;
      d.rounds = 0;
      d.total = 0;
    });
    _save();
  }

  void _toggleAuto() {
    setState(() => auto = !auto);
    _autoTimer?.cancel();
    if (auto) {
      _autoTimer = Timer.periodic(Duration(milliseconds: autoMs), (_) => _inc(fromAuto: true));
    }
  }

  void _toggleTimer() {
    setState(() => timerRunning = !timerRunning);
    _ticker?.cancel();
    if (timerRunning) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => elapsed++);
        if (elapsed % 10 == 0) _save();
      });
    } else {
      _save();
    }
  }

  void _resetTimer() {
    setState(() => elapsed = 0);
    _save();
  }

  String get _timeText {
    final h = elapsed ~/ 3600, m = (elapsed % 3600) ~/ 60, s = elapsed % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  void _go(int delta) {
    if (dhikrs.length < 2) return;
    setState(() => cur = (cur + delta + dhikrs.length) % dhikrs.length);
    _save();
  }

  // ---- dialogs ----
  Future<void> _editDhikr({_Dhikr? existing, String? presetName, int? presetTarget}) async {
    final name = TextEditingController(text: existing?.name ?? presetName ?? '');
    final target = TextEditingController(text: '${existing?.target ?? presetTarget ?? 33}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New counter' : 'Edit counter'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (dhikr / wazifa)')),
          const SizedBox(height: 8),
          TextField(controller: target, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Target per round')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final n = name.text.trim();
    final t = int.tryParse(target.text.trim()) ?? 0;
    if (n.isEmpty || t < 1 || t > 100000) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a name and a target between 1 and 100000.')));
      return;
    }
    setState(() {
      if (existing != null) {
        existing.name = n;
        existing.target = t;
        if (existing.count >= t) existing.count = 0;
      } else {
        dhikrs.add(_Dhikr(id: 'd${DateTime.now().microsecondsSinceEpoch}', name: n, target: t));
        cur = dhikrs.length - 1;
      }
    });
    _save();
  }

  Future<void> _openCounters() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          builder: (ctx, scroll) => ListView(controller: scroll, padding: const EdgeInsets.all(12), children: [
            const Padding(padding: EdgeInsets.all(8), child: Text('My counters', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
            for (var i = 0; i < dhikrs.length; i++)
              Card(
                color: i == cur ? const Color(0xFF1B6A2A) : const Color(0xFF0C4A19),
                child: ListTile(
                  title: Text(dhikrs[i].name, style: const TextStyle(color: Colors.white)),
                  subtitle: Text('Target ${dhikrs[i].target} - Rounds ${dhikrs[i].rounds} - Total ${dhikrs[i].total}', style: const TextStyle(color: Colors.white70)),
                  onTap: () {
                    setState(() => cur = i);
                    _save();
                    Navigator.pop(ctx);
                  },
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      icon: const Icon(Icons.edit, color: Colors.white70),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _editDhikr(existing: dhikrs[i]);
                      },
                    ),
                    if (dhikrs.length > 1)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.white70),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: ctx,
                            builder: (c2) => AlertDialog(
                              title: Text('Delete "${dhikrs[i].name}"?'),
                              content: const Text('Its count and rounds will be lost.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('Cancel')),
                                ElevatedButton(onPressed: () => Navigator.pop(c2, true), child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          setState(() {
                            dhikrs.removeAt(i);
                            if (cur >= dhikrs.length) cur = dhikrs.length - 1;
                          });
                          _save();
                          setS(() {});
                        },
                      ),
                  ]),
                ),
              ),
            const Padding(padding: EdgeInsets.fromLTRB(8, 16, 8, 4), child: Text('Add from common dhikr', style: TextStyle(color: Colors.white70))),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final p in _presets)
                ActionChip(
                  label: Text('${p[0]} (${p[1]})'),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _editDhikr(presetName: p[0] as String, presetTarget: p[1] as int);
                  },
                ),
            ]),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('New custom counter'),
              onPressed: () async {
                Navigator.pop(ctx);
                await _editDhikr();
              },
            ),
          ]),
        ),
      ),
    );
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panel,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(padding: EdgeInsets.all(12), child: Text('Settings', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
            SwitchListTile(
              title: const Text('Sound', style: TextStyle(color: Colors.white)),
              value: sound,
              onChanged: (v) {
                setState(() => sound = v);
                setS(() {});
                _save();
              },
            ),
            SwitchListTile(
              title: const Text('Vibration', style: TextStyle(color: Colors.white)),
              value: vibrate,
              onChanged: (v) {
                setState(() => vibrate = v);
                setS(() {});
                _save();
              },
            ),
            SwitchListTile(
              title: const Text('Alert when a round completes', style: TextStyle(color: Colors.white)),
              value: celebrate,
              onChanged: (v) {
                setState(() => celebrate = v);
                setS(() {});
                _save();
              },
            ),
            ListTile(
              title: const Text('Auto-count speed', style: TextStyle(color: Colors.white)),
              subtitle: Text('One count every ${(autoMs / 1000).toStringAsFixed(1)} s', style: const TextStyle(color: Colors.white70)),
              trailing: DropdownButton<int>(
                dropdownColor: _panel,
                value: autoMs,
                style: const TextStyle(color: Colors.white),
                items: const [
                  DropdownMenuItem(value: 500, child: Text('0.5 s')),
                  DropdownMenuItem(value: 1000, child: Text('1 s')),
                  DropdownMenuItem(value: 1500, child: Text('1.5 s')),
                  DropdownMenuItem(value: 2000, child: Text('2 s')),
                  DropdownMenuItem(value: 3000, child: Text('3 s')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => autoMs = v);
                  setS(() {});
                  if (auto) {
                    _autoTimer?.cancel();
                    _autoTimer = Timer.periodic(Duration(milliseconds: autoMs), (_) => _inc(fromAuto: true));
                  }
                  _save();
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _resetAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset all counters?'),
        content: const Text('Every counter goes back to 0 and the daily statistics are cleared.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset all')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      for (final x in dhikrs) {
        x.count = 0;
        x.rounds = 0;
        x.total = 0;
      }
      daily.clear();
    });
    _save();
  }

  void _openStats() {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _TasbeehStats(daily: Map.of(daily), dhikrs: [for (final x in dhikrs) _Dhikr.fromJson(x.toJson())])));
  }

  // ---- UI ----
  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Scaffold(backgroundColor: _bg, body: Center(child: CircularProgressIndicator()));
    final pct = d.target == 0 ? 0 : ((d.count * 100) ~/ d.target);
    return Scaffold(
      backgroundColor: _bg,
      body: Container(
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_bg, _bgDark])),
        child: SafeArea(
          child: Column(children: [
            // top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Row(children: [
                IconButton(icon: const Icon(Icons.edit_outlined, color: Colors.white), tooltip: 'Edit counter', onPressed: () => _editDhikr(existing: d)),
                Expanded(
                  child: Container(
                    height: 46,
                    decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(12)),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      IconButton(icon: Icon(timerRunning ? Icons.pause : Icons.play_arrow, color: Colors.white), onPressed: _toggleTimer),
                      Text(_timeText, style: const TextStyle(color: Colors.white, fontSize: 18)),
                      IconButton(icon: const Icon(Icons.refresh, color: Colors.white), onPressed: _resetTimer),
                    ]),
                  ),
                ),
                IconButton(icon: const Icon(Icons.show_chart, color: Colors.white), tooltip: 'Statistics', onPressed: _openStats),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white),
                  onSelected: (v) {
                    switch (v) {
                      case 'add':
                        _editDhikr();
                        break;
                      case 'list':
                        _openCounters();
                        break;
                      case 'resetall':
                        _resetAll();
                        break;
                      case 'close':
                        Navigator.maybePop(context);
                        break;
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'add', child: Text('New counter')),
                    PopupMenuItem(value: 'list', child: Text('My counters')),
                    PopupMenuItem(value: 'resetall', child: Text('Reset all')),
                    PopupMenuItem(value: 'close', child: Text('Close')),
                  ],
                ),
              ]),
            ),
            // dhikr name
            SizedBox(
              height: 120,
              child: Row(children: [
                IconButton(icon: Icon(Icons.chevron_left, color: dhikrs.length > 1 ? Colors.white : Colors.white24, size: 30), onPressed: () => _go(-1)),
                Expanded(
                  child: GestureDetector(
                    onTap: _openCounters,
                    child: Center(child: Text(d.name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 24))),
                  ),
                ),
                IconButton(icon: Icon(Icons.chevron_right, color: dhikrs.length > 1 ? Colors.white : Colors.white24, size: 30), onPressed: () => _go(1)),
              ]),
            ),
            // toggles
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                GestureDetector(
                  onTap: _toggleAuto,
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: auto ? _gold : const Color(0xFF2F7A3B)),
                    child: Text('A', style: TextStyle(color: auto ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                  ),
                ),
                Row(children: [
                  IconButton(
                    icon: Icon(sound ? Icons.volume_up : Icons.volume_off, color: sound ? Colors.white : Colors.deepOrangeAccent),
                    onPressed: () {
                      setState(() => sound = !sound);
                      _save();
                    },
                  ),
                  IconButton(
                    icon: Icon(vibrate ? Icons.vibration : Icons.mobile_off, color: vibrate ? Colors.white : Colors.deepOrangeAccent),
                    onPressed: () {
                      setState(() => vibrate = !vibrate);
                      _save();
                    },
                  ),
                  IconButton(
                    icon: Icon(celebrate ? Icons.thumb_up : Icons.thumb_up_outlined, color: Colors.white),
                    tooltip: 'Alert when a round completes',
                    onPressed: () {
                      setState(() => celebrate = !celebrate);
                      _save();
                    },
                  ),
                ]),
              ]),
            ),
            // counter circle
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(builder: (context, c) {
                  final size = math.min(c.maxWidth, c.maxHeight);
                  return Center(
                    child: SizedBox(
                      width: size,
                      height: size,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _inc,
                        child: CustomPaint(
                          painter: _RingPainter(progress: d.target == 0 ? 0 : d.count / d.target, pct: pct),
                          child: Center(child: SevenSegmentNumber(value: d.total, maxWidth: size * 0.78, maxHeight: size * 0.34, color: _gold)),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text.rich(TextSpan(text: 'Rounds: ', style: const TextStyle(color: Colors.white70, fontSize: 16), children: [TextSpan(text: '${d.rounds}', style: const TextStyle(color: _gold, fontWeight: FontWeight.bold))])),
                Text.rich(TextSpan(text: 'Count: ', style: const TextStyle(color: Colors.white70, fontSize: 16), children: [
                  TextSpan(text: '${d.count}', style: const TextStyle(color: _gold, fontWeight: FontWeight.bold)),
                  TextSpan(text: ' / ${d.target}', style: const TextStyle(color: _gold, fontWeight: FontWeight.bold)),
                ])),
              ]),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(14, 6, 14, 14),
              height: 56,
              decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(28)),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(icon: const Icon(Icons.refresh, color: Colors.white), tooltip: 'Reset', onPressed: _reset),
                IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.white), tooltip: 'Undo one', onPressed: _dec),
                GestureDetector(
                  onTap: _inc,
                  child: Container(width: 44, height: 44, decoration: const BoxDecoration(shape: BoxShape.circle, color: _gold), child: const Icon(Icons.add, color: Colors.black87, size: 28)),
                ),
                IconButton(icon: const Icon(Icons.list_alt, color: Colors.white), tooltip: 'My counters', onPressed: _openCounters),
                IconButton(icon: const Icon(Icons.settings_outlined, color: Colors.white), tooltip: 'Settings', onPressed: _openSettings),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---- ring with progress arc and percentage badge ----
class _RingPainter extends CustomPainter {
  final double progress;
  final int pct;
  _RingPainter({required this.progress, required this.pct});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 14;
    canvas.drawCircle(center, radius, Paint()..color = _panel);
    canvas.drawCircle(center, radius, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = const Color(0xFF3F8A4A));
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep > 0) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, sweep, false, Paint()..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round..color = _gold);
    }
    // badge at the end of the arc
    final ang = -math.pi / 2 + sweep;
    final bc = Offset(center.dx + radius * math.cos(ang), center.dy + radius * math.sin(ang));
    canvas.drawCircle(bc, 15, Paint()..color = _gold);
    final tp = TextPainter(text: TextSpan(text: '$pct%', style: const TextStyle(color: Colors.black87, fontSize: 11, fontWeight: FontWeight.bold)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, bc - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.progress != progress || old.pct != pct;
}

// ---- seven segment digits ----
class SevenSegmentNumber extends StatelessWidget {
  final int value;
  final double maxWidth;
  final double maxHeight;
  final Color color;
  const SevenSegmentNumber({super.key, required this.value, required this.maxWidth, required this.maxHeight, required this.color});

  @override
  Widget build(BuildContext context) {
    final s = '$value';
    // each digit is 0.58 as wide as tall, with a gap of 0.16 of its width
    final hByWidth = maxWidth / (s.length * 0.58 + (s.length - 1) * 0.1);
    final h = math.min(maxHeight, hByWidth);
    final w = h * 0.58;
    final gap = h * 0.1;
    final total = s.length * w + (s.length - 1) * gap;
    return CustomPaint(size: Size(total, h), painter: _SegPainter(s, w, h, gap, color));
  }
}

class _SegPainter extends CustomPainter {
  final String s;
  final double w, h, gap;
  final Color color;
  _SegPainter(this.s, this.w, this.h, this.gap, this.color);

  static const _masks = {
    '0': 'abcdef',
    '1': 'bc',
    '2': 'abdeg',
    '3': 'abcdg',
    '4': 'bcfg',
    '5': 'acdfg',
    '6': 'acdefg',
    '7': 'abc',
    '8': 'abcdefg',
    '9': 'abcdfg',
  };

  Path _hSeg(double x0, double x1, double y, double t) => Path()
    ..moveTo(x0, y)
    ..lineTo(x0 + t / 2, y - t / 2)
    ..lineTo(x1 - t / 2, y - t / 2)
    ..lineTo(x1, y)
    ..lineTo(x1 - t / 2, y + t / 2)
    ..lineTo(x0 + t / 2, y + t / 2)
    ..close();

  Path _vSeg(double x, double y0, double y1, double t) => Path()
    ..moveTo(x, y0)
    ..lineTo(x + t / 2, y0 + t / 2)
    ..lineTo(x + t / 2, y1 - t / 2)
    ..lineTo(x, y1)
    ..lineTo(x - t / 2, y1 - t / 2)
    ..lineTo(x - t / 2, y0 + t / 2)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final t = w * 0.2;
    final g = t * 0.12;
    for (var i = 0; i < s.length; i++) {
      final mask = _masks[s[i]] ?? '';
      final L = i * (w + gap);
      final T = 0.0;
      void seg(String k, Path p) {
        if (mask.contains(k)) canvas.drawPath(p, paint);
      }

      seg('a', _hSeg(L + t / 2 + g, L + w - t / 2 - g, T + t / 2, t));
      seg('g', _hSeg(L + t / 2 + g, L + w - t / 2 - g, T + h / 2, t));
      seg('d', _hSeg(L + t / 2 + g, L + w - t / 2 - g, T + h - t / 2, t));
      seg('f', _vSeg(L + t / 2, T + t / 2 + g, T + h / 2 - g, t));
      seg('b', _vSeg(L + w - t / 2, T + t / 2 + g, T + h / 2 - g, t));
      seg('e', _vSeg(L + t / 2, T + h / 2 + g, T + h - t / 2 - g, t));
      seg('c', _vSeg(L + w - t / 2, T + h / 2 + g, T + h - t / 2 - g, t));
    }
  }

  @override
  bool shouldRepaint(covariant _SegPainter old) => old.s != s || old.w != w || old.h != h || old.color != color;
}

// ---- statistics ----
class _TasbeehStats extends StatelessWidget {
  final Map<String, int> daily;
  final List<_Dhikr> dhikrs;
  const _TasbeehStats({required this.daily, required this.dhikrs});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = [for (var i = 6; i >= 0; i--) now.subtract(Duration(days: i))];
    final vals = [for (final dd in days) daily[_dayKey(dd)] ?? 0];
    final maxV = vals.fold<int>(1, (a, b) => b > a ? b : a);
    final today = daily[_dayKey(now)] ?? 0;
    final week = vals.fold<int>(0, (a, b) => a + b);
    final allTime = dhikrs.fold<int>(0, (a, b) => a + b.total);
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    Widget stat(String label, int v) => Expanded(
          child: Card(
            color: _panel,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Text('$v', style: const TextStyle(color: _gold, fontSize: 24, fontWeight: FontWeight.bold)),
                Text(label, style: const TextStyle(color: Colors.white70)),
              ]),
            ),
          ),
        );
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: _bgDark, foregroundColor: Colors.white, title: const Text('Statistics')),
      body: ListView(padding: const EdgeInsets.all(14), children: [
        Row(children: [stat('Today', today), stat('Last 7 days', week), stat('All time', allTime)]),
        const SizedBox(height: 14),
        const Text('Last 7 days', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        SizedBox(
          height: 170,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text('${vals[i]}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  const SizedBox(height: 3),
                  Container(height: 110 * vals[i] / maxV + 2, margin: const EdgeInsets.symmetric(horizontal: 6), decoration: BoxDecoration(color: _gold, borderRadius: BorderRadius.circular(4))),
                  const SizedBox(height: 4),
                  Text(wd[days[i].weekday - 1], style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        const Text('Counters', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        for (final x in dhikrs)
          Card(
            color: _panel,
            child: ListTile(
              title: Text(x.name, style: const TextStyle(color: Colors.white)),
              subtitle: Text('Rounds ${x.rounds} - Target ${x.target}', style: const TextStyle(color: Colors.white70)),
              trailing: Text('${x.total}', style: const TextStyle(color: _gold, fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
      ]),
    );
  }
}
