import 'dart:async';
import 'dart:convert';
import 'package:universal_io/io.dart';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'listing_sync_service.dart';

class LiveSafetyResult {
  final bool safe;
  final Map<String, bool> flags;
  final String severity;
  final String? reason;
  final double confidence;

  const LiveSafetyResult({
    required this.safe,
    required this.flags,
    required this.severity,
    this.reason,
    required this.confidence,
  });

  factory LiveSafetyResult.safe() => const LiveSafetyResult(safe: true, flags: {}, severity: 'none', confidence: 1.0);
  factory LiveSafetyResult.fromJson(Map<String, dynamic> json) => LiveSafetyResult(
    safe: json['safe'] ?? true,
    flags: Map<String, bool>.from(json['flags'] ?? {}),
    severity: json['severity'] ?? 'none',
    reason: json['reason'],
    confidence: (json['confidence'] ?? 0.0).toDouble(),
  );
}

class NecxaAI {
  static const String _workerBase = 'https://necxa-ai-engine.knestars.workers.dev';
  static const String _identityVerificationPublishableKey = 'sb_publishable_Bc_CXsA3BiuP36E4KxgkYQ_QmvyV7HT';

  static Map<String, dynamic> buildIdentityShardPayload({
    required String action,
    required String primaryBase64,
    String? secondaryBase64,
    String? userId,
    String? countryCode,
    String? documentType,
  }) {
    final payload = <String, dynamic>{
      'action': action,
      'payload': {'imageBase64': primaryBase64, 'userId': userId},
    };
    if (secondaryBase64 != null) payload['payload']['idImageBase64'] = secondaryBase64;
    if (countryCode != null) payload['payload']['countryCode'] = countryCode;
    if (documentType != null) payload['payload']['documentType'] = documentType;
    return payload;
  }

  static Map<String, String> _aiHeaders() {
    final session = Supabase.instance.client.auth.currentSession;
    return {
      'x-primary-jwt': session?.accessToken ?? '',
      'apikey': _identityVerificationPublishableKey,
    };
  }

  static Future<Map<String, dynamic>> _invokeIdentityVerification(Map<String, dynamic> payload) async {
    final res = await Supabase.instance.client.functions.invoke(
      'verify-identity-shard',
      headers: _aiHeaders(),
      body: payload,
    ).timeout(const Duration(seconds: 45));
    return Map<String, dynamic>.from(res.data ?? {});
  }

  static Map<String, dynamic> _sanitizeVerificationResult(Map<String, dynamic> data, {required String fallback}) {
    final verified = data['verified'] == true || data['faceMatch'] == true;
    String extractId(dynamic val) {
      if (val is Map) return (val['id'] ?? val['sessionId'] ?? val.toString()).toString();
      return val?.toString() ?? '';
    }
    final sessionId = extractId(data['verificationSessionId'] ?? data['sessionId']);
    return {
      ...data,
      'verified': verified,
      'faceMatch': verified,
      'sessionId': sessionId,
      'feedback': data['feedback']?.toString() ?? data['error']?.toString() ?? fallback,
      'score': (data['score'] is num) ? (data['score'] as num).toDouble() : 0.0,
    };
  }

  static Future<Map<String, dynamic>> verifyID(File imageFile, {String? userId, String action = 'verify-id'}) async {
    try {
      final base64 = await fileToBase64(imageFile);
      final data = await _invokeIdentityVerification(buildIdentityShardPayload(
        action: action, primaryBase64: base64, userId: userId, countryCode: 'UG', documentType: 'national_id',
      ));
      return _sanitizeVerificationResult(data, fallback: 'ID verification failed');
    } catch (e) { return {'verified': false, 'feedback': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifyFaceOnly(File selfieFile, {String? userId}) async {
    try {
      final base64 = await fileToBase64(selfieFile);
      final data = await _invokeIdentityVerification(buildIdentityShardPayload(
        action: 'verify-face-only', primaryBase64: base64, userId: userId,
      ));
      return _sanitizeVerificationResult(data, fallback: 'Face verification failed');
    } catch (e) { return {'verified': false, 'feedback': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifySelfie(File selfieFile, File idReferenceFile, {String? userId}) async {
    try {
      final primaryBase64 = await fileToBase64(selfieFile);
      final secondaryBase64 = await fileToBase64(idReferenceFile);
      final data = await _invokeIdentityVerification(buildIdentityShardPayload(
        action: 'verify-selfie', primaryBase64: primaryBase64, secondaryBase64: secondaryBase64, userId: userId,
      ));
      return _sanitizeVerificationResult(data, fallback: 'Biometric match failed');
    } catch (e) { return {'verified': false, 'feedback': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifyLivenessPanorama(String panoramaBase64, {String? userId}) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'verify-liveness-panorama',
        headers: _aiHeaders(),
        body: {'action': 'verify-liveness-panorama', 'panoramaBase64': panoramaBase64, 'userId': userId},
      ).timeout(const Duration(seconds: 45));
      return _sanitizeVerificationResult(Map<String, dynamic>.from(res.data ?? {}), fallback: 'Liveness failed');
    } catch (e) { return {'verified': false, 'feedback': e.toString()}; }
  }

  static Future<String> fileToBase64(File file) async {
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

  static Future<String> askNexca(String userPrompt, {Map<String, dynamic>? context, List<Map<String, String>> conversation = const [], String language = 'English'}) async {
    final session = Supabase.instance.client.auth.currentSession;
    final res = await http.post(
      Uri.parse('https://ayvescksetiuekoyfqar.supabase.co/functions/v1/necxa-chat'),
      headers: {'Authorization': 'Bearer ${session?.accessToken}', 'Content-Type': 'application/json'},
      body: jsonEncode({'message': userPrompt, 'context': context, 'language': language}),
    ).timeout(const Duration(seconds: 20));
    return (jsonDecode(res.body) as Map)['content'] ?? 'No response';
  }
}
