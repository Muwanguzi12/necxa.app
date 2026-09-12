import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;

/// Android Keystore-backed SP2 liveness proof. Other platforms fail explicitly
/// so callers can retain their existing (non-cryptographic) flow.
class LivenessCaptureService {
  static const _channel = MethodChannel('com.necxa/liveness_keystore');
  static final _client = Supabase.instance.client;
  static const _sp2Url = 'https://ayvescksetiuekoyfqar.supabase.co';
  static const _sp2Key = 'sb_publishable_Bc_CXsA3BiuP36E4KxgkYQ_QmvyV7HT';

  static Future<Map<String, dynamic>> _call(
    String action,
    String token,
    Map<String, dynamic> body,
  ) async {
    final response = await http.post(
      Uri.parse('$_sp2Url/functions/v1/liveness-challenge'),
      headers: {
        'apikey': _sp2Key,
        'Authorization': 'Bearer $token',
        'x-primary-jwt': token,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'action': action, ...body}),
    );
    final decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Liveness challenge failed: ${decoded['error'] ?? response.statusCode}');
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  static Future<Map<String, dynamic>> createManifest({
    required List<File> frames,
    required List<int> captureTimestampsMs,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Cryptographic liveness capture is currently Android-only');
    }
    if (frames.isEmpty || frames.length != captureTimestampsMs.length) {
      throw ArgumentError('Each liveness frame must have a capture timestamp');
    }
    final info = Map<String, dynamic>.from(await _channel.invokeMethod('getKeyInfo') as Map);
    final keyId = info['keyId'] as String;
    final token = _client.auth.currentSession?.accessToken;
    if (token == null) throw StateError('Authenticated SP1 session required');
    await _call('register', token, {
      'keyId': keyId,
      'publicKeyJwk': info['publicKeyJwk'],
      'attestationCertificates': info['attestationCertificates'],
    });
    final data = await _call('issue', token, {
      'keyId': keyId,
    });
    final frameProofs = <Map<String, dynamic>>[];
    for (var i = 0; i < frames.length; i++) {
      final digest = sha256.convert(await frames[i].readAsBytes()).toString();
      frameProofs.add({'sha256': digest, 'timestampMs': captureTimestampsMs[i], 'index': i});
    }
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final unsigned = <String, dynamic>{
      'nonce': data['nonce'],
      'frames': frameProofs,
      'createdAt': createdAt,
    };
    final canonical = utf8.encode(jsonEncode(unsigned));
    final payload = base64UrlEncode(canonical).replaceAll('=', '');
    final signature = await _channel.invokeMethod<String>('sign', {'payload': payload});
    if (signature == null || signature.isEmpty) throw StateError('Keystore signing returned no signature');
    final manifest = {...unsigned, 'keyId': keyId, 'signature': signature};
    final consumed = await _call('consume', token, {
      'keyId': keyId,
      'manifest': manifest,
    });
    if (consumed['accepted'] != true) {
      throw StateError('Liveness manifest was not accepted');
    }
    return manifest;
  }
}
