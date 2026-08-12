// ─── Chat Models — aligned to production schema (direct_chat_rooms / direct_messages)

class ChatRoom {
  final String id;
  final String? propertyId;
  final String? escrowId;
  final String? agentId;
  final String? sellerId;
  final String? buyerId;
  final String? clientId;
  final String status;
  final String? lastMessage;
  final DateTime? lastMessageAt;
  final DateTime createdAt;

  // Display info for the other party
  final String? otherName;
  final String? otherAvatar;
  final bool otherIsAgent;
  final int otherTrustScore;
  final int myUnread;
  final Map<String, dynamic>? metadata;

  // Convenience getter: the "other" party in the conversation
  String get otherPartyId => agentId ?? sellerId ?? buyerId ?? clientId ?? '';
  bool get isSupport => metadata?['interaction_context'] == 'support';
  String get displayName {
    if (isSupport) {
      final label = metadata?['conversation_label']?.toString().trim();
      return label == null || label.isEmpty ? 'Necxa Support' : label;
    }
    final name = otherName?.trim();
    return name == null || name.isEmpty ? 'Unknown User' : name;
  }

  ChatRoom({
    required this.id,
    this.propertyId,
    this.escrowId,
    this.agentId,
    this.sellerId,
    this.buyerId,
    this.clientId,
    this.status = 'active',
    this.lastMessage,
    this.lastMessageAt,
    required this.createdAt,
    this.otherName,
    this.otherAvatar,
    this.otherIsAgent = false,
    this.otherTrustScore = 50,
    this.myUnread = 0,
    this.metadata,
  });

  factory ChatRoom.fromJson(Map<String, dynamic> json) {
    // v_my_chats view returns 'room_id' alias, fallback to 'id' for direct table queries
    final roomId = (json['room_id'] ?? json['id'] ?? '') as String;
    return ChatRoom(
      id:             roomId,
      propertyId:     json['property_id'] as String?,
      escrowId:       json['escrow_id'] as String?,
      // v_my_chats_v2 returns 'other_user_id', legacy v1 uses 'other_id', legacy views may use 'agent_id'
      agentId:        (json['agent_id'] ?? json['other_user_id'] ?? json['other_id']) as String?,
      sellerId:       json['seller_id'] as String?,
      buyerId:        json['buyer_id'] as String?,
      clientId:       json['client_id'] as String?,
      status:         json['status'] as String? ?? 'active',
      lastMessage:    (json['last_message'] ?? json['latest_message']) as String?,
      lastMessageAt:  _parseDate(json['last_message_at'] ?? json['latest_message_at']),
      createdAt:      _parseDate(json['created_at']) ?? DateTime.now(),
      otherName:      (json['other_name'] ?? json['other_display_name']) as String?,
      otherAvatar:    (json['other_avatar'] ?? json['other_photo_url']) as String?,
      otherIsAgent:   json['other_is_agent'] as bool? ?? false,
      otherTrustScore: json['other_trust_score'] as int? ?? 50,
      myUnread:       json['my_unread'] as int? ?? 0,
      metadata:       json['metadata'] as Map<String, dynamic>?,
    );
  }

  static DateTime? _parseDate(dynamic val) {
    if (val == null) return null;
    return DateTime.tryParse(val.toString());
  }

  /// Returns a copy of this room with the unread count set to [count].
  /// Used by markRoomAsRead to clear the badge locally without a network round-trip.
  ChatRoom copyWithUnread(int count) => ChatRoom(
    id: id, propertyId: propertyId, escrowId: escrowId,
    agentId: agentId, sellerId: sellerId, buyerId: buyerId, clientId: clientId,
    status: status, lastMessage: lastMessage, lastMessageAt: lastMessageAt,
    createdAt: createdAt, otherName: otherName, otherAvatar: otherAvatar,
    otherIsAgent: otherIsAgent, otherTrustScore: otherTrustScore,
    myUnread: count, metadata: metadata,
  );
}

class ChatMessage {
  final String id;
  final String conversationId;   // maps to room_id
  final String senderId;
  final String? receiverId;
  final String messageType;
  final String? content;         // primary text content
  final String? mediaUrl;
  final String? localMediaPath;
  final Map<String, dynamic>? metadata;
  final bool isRead;
  List<String>? reactions;
  final int durationSeconds; // for voice notes
  final DateTime createdAt;

  String get text => content ?? '';

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    this.receiverId,
    this.messageType = 'text',
    this.content,
    this.mediaUrl,
    this.localMediaPath,
    this.metadata,
    this.isRead = false,
    this.reactions,
    this.durationSeconds = 0,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id:             json['id'] as String,
      conversationId: (json['room_id'] ?? json['conversation_id'] ?? '') as String,
      senderId:       json['sender_id'] as String,
      receiverId:     json['receiver_id'] as String?,
      messageType:    json['message_type'] as String? ?? 'text',
      content:        (json['content'] ?? json['message'] ?? '') as String?,
      mediaUrl:       json['media_url'] as String?,
      localMediaPath: json['local_media_path'] as String?,
      metadata:       json['metadata'] as Map<String, dynamic>?,
      isRead:         json['is_read'] as bool? ?? false,
      reactions:      json['reactions'] != null ? List<String>.from(json['reactions']) : null,
      createdAt:      DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}
