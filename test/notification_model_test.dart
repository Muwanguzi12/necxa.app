import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/models/notification_model.dart';

void main() {
  test('notification preserves its recipient through cache and tap payloads', () {
    final notification = AppNotification.fromMap({
      'id': 'notification-1',
      'user_id': 'recipient-1',
      'type': 'comment',
      'title': 'New comment',
      'body': 'A relevant reply',
      'is_read': false,
      'created_at': '2026-08-13T00:00:00.000Z',
    });

    expect(notification.userId, 'recipient-1');
    expect(notification.toMap()['user_id'], 'recipient-1');
    expect(jsonDecode(notification.payload)['user_id'], 'recipient-1');
  });
}
