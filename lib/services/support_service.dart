import 'package:supabase_flutter/supabase_flutter.dart';

const String necxaSupportBaseUrl = 'https://goobox.necxa.uk';

class SupportService {
  SupportService({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Creates a short-lived, signed handoff for logged-in Necxa users.
  /// If the handoff cannot be created, Goobox still opens in email-only mode.
  Future<Uri> createGooboxUri() async {
    final fallback = Uri.parse(necxaSupportBaseUrl);
    if (_client.auth.currentSession == null) return fallback;

    try {
      final response = await _client.functions.invoke(
        'create-support-token',
        body: const <String, dynamic>{},
      );
      final raw = response.data;
      if (raw is! Map) return fallback;
      final token = raw['token']?.toString().trim();
      if (token == null || token.isEmpty) return fallback;
      return fallback.replace(queryParameters: {'token': token});
    } catch (_) {
      return fallback;
    }
  }

  /// Creates an in-app support ticket directly in Goobox and opens the
  /// support chat room in Necxa. Returns the ticket ID if created.
  Future<Map<String, dynamic>> submitSupportTicket({
    required String subject,
    required String message,
    String category = 'general',
    String priority = 'medium',
  }) async {
    if (_client.auth.currentSession == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }
    try {
      final res = await _client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'create-support-ticket',
          'payload': {
            'subject': subject,
            'message': message,
            'category': category,
            'priority': priority,
          },
        },
      );
      final raw = res.data;
      if (raw is Map) return Map<String, dynamic>.from(raw);
      return {'success': false, 'error': 'Unexpected response'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Forwards a user's support chat message to the Goobox ticket thread.
  /// Call this from sendChatMessage when activeConversation.isSupport == true.
  Future<void> forwardSupportMessage({
    required String message,
    String? ticketId,
    String? roomId,
  }) async {
    if (_client.auth.currentSession == null || ticketId == null) return;
    try {
      await _client.functions.invoke(
        'clever-processor',
        body: {
          'action': 'forward-support-message',
          'payload': {
            'message': message,
            'ticket_id': ticketId,
            if (roomId != null) 'room_id': roomId,
          },
        },
      );
    } catch (_) {}
  }

  /// Fetches the user's active Goobox support tickets and response status.
  /// Also auto-syncs any pending agent replies into the user's chat.
  Future<List<Map<String, dynamic>>> fetchUserSupportTickets() async {
    if (_client.auth.currentSession == null) return [];
    try {
      final res = await _client.functions.invoke(
        'clever-processor',
        body: const {'action': 'fetch-user-support'},
      );
      final raw = res.data;
      if (raw is Map && raw['success'] == true && raw['tickets'] is List) {
        return List<Map<String, dynamic>>.from(raw['tickets']);
      }
      return [];
    } catch (_) {
      return [];
    }
  }
}
