import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

const String necxaSupportBaseUrl = 'https://goobox.necxa.uk';
const String _gooboxFunctionsUrl = 'https://anregykcgolpgxecfxej.supabase.co/functions/v1';
const String _gooboxRestUrl = 'https://anregykcgolpgxecfxej.supabase.co/rest/v1';
const String _gooboxAnonKey = 'sb_publishable_KzEAI6a7Xvw-Jz-BqPQRRA_mn4iKnou';

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
    final user = _client.auth.currentUser;
    if (user == null) {
      return {'success': false, 'error': 'Not authenticated'};
    }

    // 1. Primary path: clever-processor support bridge
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
      if (raw is Map && raw['success'] == true) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {
      // If clever-processor returns 400 (e.g. unknown action), fall through to Goobox direct fallback
    }

    // 2. Direct Goobox Fallback:
    // Submits directly to Goobox's verified create-support-ticket Edge Function
    try {
      String? supportToken;
      try {
        final tokenRes = await _client.functions.invoke(
          'create-support-token',
          body: const <String, dynamic>{},
        );
        final rawToken = tokenRes.data;
        if (rawToken is Map) {
          supportToken = rawToken['token']?.toString().trim();
        }
      } catch (_) {}

      final email = user.email ?? '${user.id}@users.necxa.uk';
      final name = (user.userMetadata?['full_name'] as String?)?.trim() ?? email.split('@').first;

      final gooboxRes = await http.post(
        Uri.parse('$_gooboxFunctionsUrl/create-support-ticket'),
        headers: {
          'Content-Type': 'application/json',
          'apikey': _gooboxAnonKey,
          'Authorization': 'Bearer $_gooboxAnonKey',
        },
        body: jsonEncode({
          'email': email,
          'name': name,
          'subject': subject,
          'message': message,
          'category': category,
          'priority': priority,
          if (supportToken != null && supportToken.isNotEmpty) 'token': supportToken,
        }),
      );

      if (gooboxRes.statusCode == 200) {
        final data = jsonDecode(gooboxRes.body);
        final ticket = data['ticket'] as Map<String, dynamic>?;
        final ticketId = ticket?['id']?.toString();

        // Establish support chat room in Necxa
        if (ticketId != null) {
          try {
            const supportBotId = '709c2cae-4be0-42db-9f28-37f172c32749';
            final roomId = await _client.rpc(
              'get_or_create_direct_room',
              params: {
                'p_user_a': supportBotId,
                'p_user_b': user.id,
              },
            );
            if (roomId != null) {
              await _client.from('direct_chat_rooms').update({
                'metadata': {
                  'interaction_context': 'support',
                  'conversation_label': 'Necxa Support',
                  'ticket_id': ticketId,
                },
              }).eq('id', roomId);
            }
          } catch (_) {}
        }

        return {
          'success': true,
          'ticket': ticket,
          'ticket_id': ticketId,
          'message': 'Ticket submitted to support team.',
        };
      }
    } catch (fallbackError) {
      return {'success': false, 'error': fallbackError.toString()};
    }

    return {'success': false, 'error': 'Failed to create support ticket. Please try again.'};
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
    } catch (_) {
      try {
        final user = _client.auth.currentUser;
        final email = user?.email ?? 'user@necxa.uk';
        final name = (user?.userMetadata?['full_name'] as String?)?.trim() ?? email.split('@').first;
        await http.post(
          Uri.parse('$_gooboxRestUrl/ticket_messages'),
          headers: {
            'Content-Type': 'application/json',
            'apikey': _gooboxAnonKey,
            'Authorization': 'Bearer $_gooboxAnonKey',
          },
          body: jsonEncode({
            'ticket_id': ticketId,
            'sender_type': 'customer',
            'sender': '$name <$email>',
            'body': message,
            'direction': 'inbound',
          }),
        );
      } catch (_) {}
    }
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
