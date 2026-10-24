// Prayer-time local notifications.
//
// Scope and an honest limitation: there is no server/push backend for this
// (the user explicitly asked for an in-app popup, not WhatsApp/SMS), so
// reminders are scheduled on-device as exact Android alarms
// (flutter_local_notifications + AlarmManager under the hood) for today
// plus the next 6 days every time this is (re)triggered - on opening the
// Prayer Times screen, and on toggling the setting on. The
// flutter_local_notifications plugin persists each scheduled alarm and
// re-arms it after a phone reboot on its own (that's why
// RECEIVE_BOOT_COMPLETED is requested in the manifest), so a reboot does
// not silently cancel reminders. What this CANNOT do without a server or a
// recurring background job (neither of which exists here) is refresh the
// schedule automatically forever if the app is never reopened: the 7-day
// window means a phone that genuinely never reopens the app for over a
// week will stop getting new reminders until it's opened again. That is
// the honest ceiling of a pure on-device, no-backend design.
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const String _prefKeyEnabled = 'prayer_notifications_enabled';
const String _channelId = 'prayer_times_channel';
const String _channelName = 'Prayer Time Reminders';
const String _channelDesc = 'Notifies you when each prayer time starts.';

class _PrayerDef {
  final String label;
  final String apiKey;
  const _PrayerDef(this.label, this.apiKey);
}

// Sunrise is deliberately excluded - it is not a prayer time, it is only
// shown on the Prayer Times screen as a reference point (end of Fajr).
const List<_PrayerDef> _prayers = [
  _PrayerDef('Fajr', 'Fajr'),
  _PrayerDef('Dhuhr', 'Dhuhr'),
  _PrayerDef('Asr', 'Asr'),
  _PrayerDef('Maghrib', 'Maghrib'),
  _PrayerDef('Isha', 'Isha'),
];

class PrayerNotificationService {
  PrayerNotificationService._();
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // Couldn't detect the device's IANA timezone name - fall back to UTC
      // rather than crash; schedule accuracy may be off by the device's
      // offset until this succeeds on a later call.
      tz.setLocalLocation(tz.UTC);
    }
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await _plugin.initialize(const InitializationSettings(android: androidInit, iOS: iosInit));
    const channel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.max,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    _initialized = true;
  }

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyEnabled) ?? false;
  }

  // Turns the user's choice on/off. Does not itself fetch prayer times or
  // schedule anything when turning on - the caller (Prayer Times screen)
  // does that right after, since it already has (or can fetch) the user's
  // live location.
  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyEnabled, value);
    if (!value) {
      await initialize();
      await _plugin.cancelAll();
    }
  }

  // Returns false if the user declined a permission the OS actually asked
  // for (so the caller can tell them notifications won't fire). A null
  // result from the plugin (nothing to ask - e.g. already granted, or
  // platform doesn't require it) is treated as granted.
  static Future<bool> requestPermissions() async {
    await initialize();
    bool granted = true;
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      final notifOk = await androidImpl.requestNotificationsPermission();
      if (notifOk == false) granted = false;
      final exactOk = await androidImpl.requestExactAlarmsPermission();
      if (exactOk == false) granted = false;
    }
    final iosImpl = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (iosImpl != null) {
      final iosOk = await iosImpl.requestPermissions(alert: true, badge: true, sound: true);
      if (iosOk == false) granted = false;
    }
    return granted;
  }

  // Fetches this month's (and next month's, if the 7-day window crosses a
  // month boundary) prayer-time calendar for (latitude, longitude) from the
  // same Aladhan API the Prayer Times screen itself uses (method=1
  // Karachi, school=1 Hanafi, so the reminder fires at the same time the
  // screen shows), then exact-schedules a notification for every remaining
  // prayer in the next 7 days. Safe to call repeatedly - it clears any
  // previously scheduled prayer notifications first so times never
  // double-fire or go stale after the user moves to a new location.
  static Future<void> scheduleUpcoming({required double latitude, required double longitude}) async {
    if (!await isEnabled()) return;
    await initialize();
    await _plugin.cancelAll();

    final today = DateTime.now();
    final days = [for (int i = 0; i < 7; i++) DateTime(today.year, today.month, today.day).add(Duration(days: i))];
    final months = <String>{for (final d in days) '${d.year}-${d.month}'};

    final Map<String, Map<String, String>> timingsByDate = {}; // 'dd-MM-yyyy' -> timings
    for (final key in months) {
      final parts = key.split('-');
      final year = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      try {
        final uri = Uri.parse(
            'https://api.aladhan.com/v1/calendar/$year/$month?latitude=$latitude&longitude=$longitude&method=1&school=1');
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) continue;
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final data = body['data'] as List<dynamic>;
        for (final entry in data) {
          final e = entry as Map<String, dynamic>;
          final gregorian = (e['date'] as Map<String, dynamic>)['gregorian'] as Map<String, dynamic>;
          final dateStr = gregorian['date'] as String; // dd-MM-yyyy
          final t = (e['timings'] as Map<String, dynamic>).map((k, v) => MapEntry(k, v.toString()));
          timingsByDate[dateStr] = t;
        }
      } catch (_) {
        // This month's calendar couldn't be fetched (offline, API hiccup) -
        // the days in it are simply left unscheduled; other months already
        // fetched still get scheduled.
      }
    }

    int id = 1000;
    final now = tz.TZDateTime.now(tz.local);
    for (final d in days) {
      final key = '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
      final t = timingsByDate[key];
      if (t == null) continue;
      for (final p in _prayers) {
        final raw = t[p.apiKey];
        if (raw == null) continue;
        final cleaned = raw.split(' ').first; // API sometimes appends " (TZ)"
        final parts = cleaned.split(':');
        if (parts.length < 2) continue;
        final hour = int.tryParse(parts[0]);
        final minute = int.tryParse(parts[1]);
        if (hour == null || minute == null) continue;
        final scheduled = tz.TZDateTime(tz.local, d.year, d.month, d.day, hour, minute);
        if (!scheduled.isAfter(now)) continue; // never schedule a time already past
        await _plugin.zonedSchedule(
          id++,
          '${p.label} time',
          "It's time for ${p.label} prayer.",
          scheduled,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDesc,
              importance: Importance.max,
              priority: Priority.high,
            ),
            iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
          ),
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    }
  }
}
