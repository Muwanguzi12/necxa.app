import 'dart:convert';

class AppNotification {
  final String id;
  final String userId;
  final String type;
  final String title;
  final String body;
  final String? actorId;
  final String? actorName;
  final String? actorAvatar;
  final String? targetId;
  final String targetType;
  final Map<String, dynamic> metadata;
  final bool isRead;
  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.userId,
    required this.type,
    required this.title,
    required this.body,
    this.actorId,
    this.actorName,
    this.actorAvatar,
    this.targetId,
    this.targetType = 'post',
    this.metadata = const {},
    this.isRead = false,
    required this.createdAt,
  });

  String get payload => jsonEncode({
    'notification_id': id,
    'user_id': userId,
    'type': type,
    'target_id': targetId,
    'target_type': targetType,
  });

  AppNotification copyWith({bool? isRead}) {
    return AppNotification(
      id: id,
      userId: userId,
      type: type,
      title: title,
      body: body,
      actorId: actorId,
      actorName: actorName,
      actorAvatar: actorAvatar,
      targetId: targetId,
      targetType: targetType,
      metadata: metadata,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'type': type,
      'title': title,
      'body': body,
      'payload': payload,
      'actor_id': actorId,
      'actor_name': actorName,
      'actor_avatar': actorAvatar,
      'target_id': targetId,
      'target_type': targetType,
      'metadata': jsonEncode(metadata),
      'is_read': isRead ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory AppNotification.fromMap(Map<String, dynamic> map) {
    final metadata = _mapValue(map['metadata']);
    final identity = _mapValue(metadata['identity']);
    final rawRead = map['is_read'] ?? map['read'];
    final createdAt = DateTime.tryParse(map['created_at']?.toString() ?? '');

    return AppNotification(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      type:
          map['type']?.toString() ??
          map['notification_type']?.toString() ??
          'system',
      title: map['title']?.toString() ?? 'Necxa',
      body: map['body']?.toString() ?? '',
      actorId: map['actor_id']?.toString() ?? identity['user_id']?.toString(),
      actorName:
          map['actor_name']?.toString() ??
          metadata['actor_name']?.toString() ??
          identity['user_name']?.toString(),
      actorAvatar:
          map['actor_avatar']?.toString() ??
          metadata['actor_avatar']?.toString() ??
          identity['user_avatar']?.toString(),
      targetId: map['target_id']?.toString(),
      targetType: map['target_type']?.toString() ?? 'post',
      metadata: metadata,
      isRead: rawRead == true || rawRead == 1 || rawRead == '1',
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  static Map<String, dynamic> _mapValue(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }
}
