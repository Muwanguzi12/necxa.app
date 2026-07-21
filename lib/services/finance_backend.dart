import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Client transport for the isolated Necxa Finance Supabase project.
/// Financial writes are routed through authenticated Edge Functions only.
class FinanceBackend {
  FinanceBackend._();

  static final FinanceBackend instance = FinanceBackend._();

  static const String projectUrl = String.fromEnvironment(
    'NECXA_FINANCE_SUPABASE_URL',
    defaultValue: 'https://ayvescksetiuekoyfqar.supabase.co',
  );

  static const String publishableKey = String.fromEnvironment(
    'NECXA_FINANCE_SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_Bc_CXsA3BiuP36E4KxgkYQ_QmvyV7HT',
  );

  Uri get _endpoint => Uri.parse('$projectUrl/functions/v1/finance-engine');

  Future<Map<String, dynamic>> invoke(
    String action, {
    Map<String, dynamic> body = const {},
  }) async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      throw const FinanceBackendException(
        code: 'unauthenticated',
        message: 'Sign in before using Necxa Finance.',
      );
    }

    final response = await http
        .post(
          _endpoint,
          headers: {
            'apikey': publishableKey,
            'Authorization': 'Bearer ${session.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'action': action, ...body}),
        )
        .timeout(const Duration(seconds: 30));

    final decoded = _decode(response.body);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded['success'] == false) {
      throw FinanceBackendException(
        code:
            decoded['code']?.toString() ??
            'finance_http_${response.statusCode}',
        message:
            decoded['message']?.toString() ??
            decoded['error']?.toString() ??
            'Finance request failed.',
        statusCode: response.statusCode,
        details: decoded,
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decode(String value) {
    if (value.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(value);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  }
}

class FinanceBackendException implements Exception {
  const FinanceBackendException({
    required this.code,
    required this.message,
    this.statusCode,
    this.details = const {},
  });

  final String code;
  final String message;
  final int? statusCode;
  final Map<String, dynamic> details;

  @override
  String toString() => message;
}
