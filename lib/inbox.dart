// In-app Alerts inbox + phone notifications for: absence, course completed,
// Sadqa Peti and monthly-member payments (public.app_notifications).
//
// How it reaches the person:
//  1. The database writes a row for each recipient when the event happens.
//  2. Firebase push (send-push function) delivers it even when the app is closed.
//  3. While the app is open, a realtime subscription shows it straight away, and
//     on every app start any unread alert not yet shown is shown as a phone
//     notification - so alerts are never lost even if push is not set up.
// Phone notifications use the same system channel style as the prayer reminders.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const Map<String, String> kAlertChannelNames = {
  'absence_alerts': 'Absence alerts',
  'course_alerts': 'Course completed',
  'sadqa_alerts': 'Sadqa Peti',
  'monthly_alerts': 'Monthly members',
  'general_alerts': 'General alerts',
};

String alertChannelForKind(String? kind) {
  switch (kind) {
    case 'absence':
      return 'absence_alerts';
    case 'course':
      return 'course_alerts';
    case 'sadqa':
      return 'sadqa_alerts';
    case 'monthly':
      return 'monthly_alerts';
    default:
      return 'general_alerts';
  }
}

IconData alertIconForKind(String kind) {
  switch (kind) {
    case 'absence':
      return Icons.person_off;
    case 'course':
      return Icons.workspace_premium;
    case 'sadqa':
      return Icons.volunteer_activism;
    case 'monthly':
      return Icons.payments;
    default:
      return Icons.notifications;
  }
}

class AppAlert {
  final String id;
  final String kind;
  final String title;
  final String body;
  final DateTime createdAt;
  bool read;
  AppAlert({required this.id, required this.kind, required this.title, required this.body, required this.createdAt, required this.read});
  factory AppAlert.fromRow(Map<String, dynamic> r) => AppAlert(
        id: r['id'] as String,
        kind: (r['kind'] as String?) ?? 'general',
        title: (r['title'] as String?) ?? '',
        body: (r['body'] as String?) ?? '',
        createdAt: DateTime.tryParse((r['created_at'] as String?) ?? '')?.toLocal() ?? DateTime.now(),
        read: r['read_at'] != null,
      );
}

class AppAlerts {
  AppAlerts._();
  static final ValueNotifier<int> unread = ValueNotifier<int>(0);
  static final ValueNotifier<List<AppAlert>> items = ValueNotifier<List<AppAlert>>(const []);
  static final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  static RealtimeChannel? _channel;
  static String? _uid;
  static bool _ready = false;
  static const _shownKey = 'alerts_shown_ids';

  static SupabaseClient get _sb => Supabase.instance.client;

  static Future<void> _init() async {
    if (_ready) return;
    await _local.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final e in kAlertChannelNames.entries) {
      await android?.createNotificationChannel(AndroidNotificationChannel(e.key, e.value, importance: Importance.max, playSound: true));
    }
    try {
      await android?.requestNotificationsPermission();
    } catch (_) {}
    _ready = true;
  }

  /// Phone notification, same id for the same alert so push + realtime never duplicate.
  static Future<void> showPhoneNotification({required String notificationId, required String? kind, required String title, required String body}) async {
    try {
      await _init();
      final channel = alertChannelForKind(kind);
      await _local.show(
        notificationId.hashCode & 0x7fffffff,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channel,
            kAlertChannelNames[channel] ?? 'Alerts',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
      );
    } catch (_) {}
  }

  static Future<void> start() async {
    final u = _sb.auth.currentUser;
    if (u == null) return;
    if (_uid == u.id && _channel != null) {
      unawaited(refresh(showNew: true));
      return;
    }
    await stop();
    _uid = u.id;
    try {
      await _init();
    } catch (_) {}
    await refresh(showNew: true);
    try {
      _channel = _sb
          .channel('app_alerts_${u.id}')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'app_notifications',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: u.id),
            callback: (payload) {
              final a = AppAlert.fromRow(payload.newRecord);
              items.value = [a, ...items.value];
              unread.value = items.value.where((x) => !x.read).length;
              unawaited(_markShown(a.id));
              unawaited(showPhoneNotification(notificationId: a.id, kind: a.kind, title: a.title, body: a.body));
            },
          )
          .subscribe();
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      if (_channel != null) await _sb.removeChannel(_channel!);
    } catch (_) {}
    _channel = null;
    _uid = null;
    items.value = const [];
    unread.value = 0;
  }

  static Future<Set<String>> _shown() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getStringList(_shownKey) ?? const []).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _markShown(String id) async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = (p.getStringList(_shownKey) ?? <String>[])..add(id);
      await p.setStringList(_shownKey, l.length > 300 ? l.sublist(l.length - 300) : l);
    } catch (_) {}
  }

  static Future<void> refresh({bool showNew = false}) async {
    try {
      final rows = await _sb.from('app_notifications').select().order('created_at', ascending: false).limit(100);
      final list = [for (final r in (rows as List)) AppAlert.fromRow(Map<String, dynamic>.from(r as Map))];
      items.value = list;
      unread.value = list.where((a) => !a.read).length;
      if (showNew) {
        final shown = await _shown();
        final cutoff = DateTime.now().subtract(const Duration(days: 3));
        for (final a in list.reversed) {
          if (a.read || shown.contains(a.id) || a.createdAt.isBefore(cutoff)) continue;
          await _markShown(a.id);
          await showPhoneNotification(notificationId: a.id, kind: a.kind, title: a.title, body: a.body);
        }
      }
    } catch (_) {}
  }

  static Future<void> markRead(AppAlert a) async {
    if (a.read) return;
    a.read = true;
    items.value = List<AppAlert>.of(items.value);
    unread.value = items.value.where((x) => !x.read).length;
    try {
      await _sb.from('app_notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', a.id);
    } catch (_) {}
  }

  static Future<void> markAllRead() async {
    for (final a in items.value) {
      a.read = true;
    }
    items.value = List<AppAlert>.of(items.value);
    unread.value = 0;
    try {
      await _sb.from('app_notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).isFilter('read_at', null);
    } catch (_) {}
  }
}

class AlertsBell extends StatelessWidget {
  const AlertsBell({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: AppAlerts.unread,
        builder: (context, n, _) => IconButton(
          icon: Badge(label: Text('$n'), isLabelVisible: n > 0, child: const Icon(Icons.mark_email_unread_outlined)),
          tooltip: 'Alerts',
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AlertsInboxScreen())),
        ),
      );
}

class AlertsInboxScreen extends StatefulWidget {
  const AlertsInboxScreen({super.key});
  @override
  State<AlertsInboxScreen> createState() => _AlertsInboxScreenState();
}

class _AlertsInboxScreenState extends State<AlertsInboxScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(AppAlerts.refresh());
  }

  String _when(DateTime d) {
    const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${mon[d.month - 1]}, $h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        backgroundColor: const Color(0xFF054D00),
        foregroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: AppAlerts.markAllRead,
            child: const Text('Mark all read', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<AppAlert>>(
        valueListenable: AppAlerts.items,
        builder: (context, list, _) {
          return RefreshIndicator(
            onRefresh: AppAlerts.refresh,
            child: list.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 120),
                    Center(child: Text('No alerts yet.', style: TextStyle(color: Colors.black54))),
                  ])
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final a = list[i];
                      return ListTile(
                        tileColor: a.read ? null : const Color(0xFFEFF6EA),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF054D00),
                          child: Icon(alertIconForKind(a.kind), color: Colors.white, size: 20),
                        ),
                        title: Text(a.title, style: TextStyle(fontWeight: a.read ? FontWeight.w500 : FontWeight.bold)),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(a.body),
                          const SizedBox(height: 2),
                          Text(_when(a.createdAt), style: const TextStyle(fontSize: 11.5, color: Colors.black45)),
                        ]),
                        isThreeLine: true,
                        onTap: () => AppAlerts.markRead(a),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}
