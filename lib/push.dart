// Push notifications (Firebase Cloud Messaging): registers this phone so the
// server can send e.g. a parent an absence alert. Does nothing unless this
// build has Firebase configured (see firebase_config.dart / phone_login.dart).
// Every call is wrapped so a push problem can never affect login or the app.
import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'phone_login.dart';

const String _absenceChannelId = 'absence_alerts';

class PushService {
  PushService._();
  static final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  static bool _listening = false;
  static String? _token;

  // Call after a successful login.
  static Future<void> registerForCurrentUser() async {
    if (!FirebasePhoneLogin.ready) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      await _local.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      await _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            _absenceChannelId,
            'Absence alerts',
            description: 'Tells parents when their child is marked absent.',
            importance: Importance.max,
          ));

      final token = await messaging.getToken();
      if (token != null) await _save(token);

      if (!_listening) {
        _listening = true;
        messaging.onTokenRefresh.listen((t) => unawaited(_save(t)));
        // While the app is open Android does not show FCM notifications by
        // itself, so show one ourselves.
        FirebaseMessaging.onMessage.listen((RemoteMessage m) {
          final n = m.notification;
          if (n == null) return;
          unawaited(_local.show(
            m.hashCode,
            n.title,
            n.body,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                _absenceChannelId,
                'Absence alerts',
                importance: Importance.max,
                priority: Priority.high,
              ),
            ),
          ));
        });
      }
    } catch (_) {}
  }

  static Future<void> _save(String token) async {
    _token = token;
    try {
      await Supabase.instance.client.rpc('register_device_token', params: {'p_token': token, 'p_platform': 'android'});
    } catch (_) {}
  }

  // Call before signing out so this phone stops getting the previous user's alerts.
  static Future<void> unregister() async {
    final t = _token;
    if (t == null) return;
    try {
      await Supabase.instance.client.rpc('unregister_device_token', params: {'p_token': t});
    } catch (_) {}
  }

  // Asks the server to push the absence alert for one student/date to their
  // parent. Only call after the one-time absence claim succeeded.
  static Future<void> notifyAbsence(String studentId, String date) async {
    try {
      await Supabase.instance.client.functions.invoke('notify-absence', body: {'student_id': studentId, 'date': date});
    } catch (_) {}
  }
}
