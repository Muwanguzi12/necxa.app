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

  /// Fetches the user's active Goobox support tickets and response status
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
