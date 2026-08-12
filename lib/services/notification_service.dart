import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/notification_model.dart';
import 'local_db_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final LocalDbService _localDb = LocalDbService();
  final ValueNotifier<Map<String, dynamic>?> tappedNotification = ValueNotifier(
    null,
  );

  Future<void> init() async {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (response) {
        tappedNotification.value = _decodePayload(response.payload);
      },
    );

    const channel = AndroidNotificationChannel(
      'necxa_main_channel',
      'Necxa Notifications',
      description: 'Likes, comments, follows, and account alerts',
      importance: Importance.max,
    );
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
  }

  Future<void> requestPermissions() async {
    final androidImplementation = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImplementation?.requestNotificationsPermission();
  }

  Future<void> clearDisplayedNotifications() async {
    await flutterLocalNotificationsPlugin.cancelAll();
  }

  Future<void> showNotification(
    AppNotification notification, {
    required String recipientUserId,
    bool showSystem = true,
  }) async {
    if (notification.userId != recipientUserId) {
      debugPrint(
        'Ignored notification ${notification.id}: recipient does not match the active account.',
      );
      return;
    }
    final alreadySaved = await _localDb.hasNotification(
      notification.id,
      recipientUserId,
    );
    await _localDb.saveNotification(notification.toMap(), recipientUserId);
    if (!showSystem || alreadySaved) return;

    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'necxa_main_channel',
        'Necxa Notifications',
        channelDescription: 'Likes, comments, follows, and account alerts',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true),
    );

    await flutterLocalNotificationsPlugin.show(
      notification.id.hashCode,
      notification.title,
      notification.body,
      notificationDetails,
      payload: notification.payload,
    );
  }

  Map<String, dynamic>? _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      debugPrint('Notification payload used the legacy target-only format.');
    }
    return {'target_id': payload};
  }
}
