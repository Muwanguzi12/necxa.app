import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/models/chat_models.dart';

void main() {
  test('verified support rooms use the server-owned Necxa Support label', () {
    final room = ChatRoom.fromJson({
      'room_id': 'room-1',
      'other_user_id': 'support-account',
      'other_name': 'Internal Agent Profile',
      'metadata': {
        'interaction_context': 'support',
        'conversation_label': 'Necxa Support',
        'initiated_via': 'necxa_support_link',
      },
    });

    expect(room.isSupport, isTrue);
    expect(room.displayName, 'Necxa Support');
    expect(room.otherPartyId, 'support-account');
  });

  test('support label cannot fall back to an unrelated account name', () {
    final room = ChatRoom(
      id: 'room-2',
      otherName: 'Another User',
      metadata: const {'interaction_context': 'support'},
      createdAt: DateTime.utc(2026, 8, 13),
    );

    expect(room.displayName, 'Necxa Support');
  });
}
