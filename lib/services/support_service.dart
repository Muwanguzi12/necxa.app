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
}
