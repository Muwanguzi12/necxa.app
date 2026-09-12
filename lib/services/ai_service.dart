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

// ─── Live Safety Scan Result ──────────────────────────────────────────────────
class LiveSafetyResult {
  final bool safe;
  final Map<String, bool> flags; // e.g. {'pornographic': true, 'drug_abuse': false}
  final String severity; // 'none' | 'low' | 'medium' | 'high' | 'critical'
  final String? reason;
  final double confidence;

  const LiveSafetyResult({
    required this.safe,
    required this.flags,
    required this.severity,
    this.reason,
    required this.confidence,
  });

  bool get isCritical => severity == 'critical';
  bool get isHigh => severity == 'high' || isCritical;
  bool get hasChildSafety => flags['child_safety'] == true;
  bool get hasPornographic => flags['pornographic'] == true;
  bool get hasDrugAbuse => flags['drug_abuse'] == true;
  bool get hasDangerous => flags['dangerous_content'] == true;

  factory LiveSafetyResult.safe() => const LiveSafetyResult(
    safe: true,
    flags: {},
    severity: 'none',
    confidence: 1.0,
  );

  factory LiveSafetyResult.fromJson(Map<String, dynamic> json) =>
      LiveSafetyResult(
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
  static const Duration _imageVerificationTimeout = Duration(seconds: 45);
  static const Duration _videoVerificationTimeout = Duration(seconds: 90);
  static const Duration _audioVerificationTimeout = Duration(seconds: 90);

  static Map<String, String> _aiHeaders() {
    final session = Supabase.instance.client.auth.currentSession;
    return {
      'x-primary-jwt': session?.accessToken ?? '',
      'apikey': _identityVerificationPublishableKey,
    };
  }

  static Map<String, String> _workerHeaders() {
    final headers = <String, String>{};
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        headers['x-primary-jwt'] = session.accessToken;
      }
    } catch (_) {}
    return headers;
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

  // ── IDENTITY VERIFICATION ──
  static Future<Map<String, dynamic>> verifyID(File imageFile, {String? userId, String action = 'verify-id'}) async {
    try {
      final base64 = await fileToBase64(imageFile);
      final data = await _invokeIdentityVerification({
        'action': action,
        'payload': {
          'imageBase64': base64,
          'userId': userId,
          'countryCode': 'UG',
          'documentType': 'national_id',
        },
      });
      return _sanitizeVerificationResult(data, fallback: 'ID verification failed');
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

  static Future<Map<String, dynamic>> verifyFaceOnly(File selfieFile, {String? userId}) async {
    try {
      final base64 = await fileToBase64(selfieFile);
      final data = await _invokeIdentityVerification({
        'action': 'verify-face-only',
        'payload': {'imageBase64': base64, 'userId': userId},
      });
      return _sanitizeVerificationResult(data, fallback: 'Face verification failed');
    } catch (e) { return {'verified': false, 'feedback': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifySelfie(File selfieFile, File idReferenceFile, {String? userId}) async {
    try {
      final primaryBase64 = await fileToBase64(selfieFile);
      final secondaryBase64 = await fileToBase64(idReferenceFile);
      final data = await _invokeIdentityVerification({
        'action': 'verify-selfie',
        'payload': {
          'imageBase64': primaryBase64,
          'idImageBase64': secondaryBase64,
          'userId': userId,
        },
      });
      return _sanitizeVerificationResult(data, fallback: 'Biometric match failed');
    } catch (e) { return {'verified': false, 'feedback': e.toString()}; }
  }

  // ── CONTENT VERIFICATION & MODERATION ──
  static Future<Map<String, dynamic>> verifyPhotoWorker(File photoFile) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_workerBase/api/verify/photo'))
        ..headers.addAll(_workerHeaders())
        ..files.add(await http.MultipartFile.fromPath('photo', photoFile.path));
      final streamed = await req.send().timeout(_imageVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      return Map<String, dynamic>.from(jsonDecode(body));
    } catch (e) { return {'success': false, 'error': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifyVideoWorker(List<File> frames) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_workerBase/api/verify/video'))
        ..headers.addAll(_workerHeaders());
      for (int i = 0; i < frames.length && i < 5; i++) {
        req.files.add(await http.MultipartFile.fromPath('frame$i', frames[i].path));
      }
      final streamed = await req.send().timeout(_videoVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      return Map<String, dynamic>.from(jsonDecode(body));
    } catch (e) { return {'success': false, 'error': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifyAudioWorker(File audioFile) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_workerBase/api/verify/audio'))
        ..headers.addAll(_workerHeaders())
        ..files.add(await http.MultipartFile.fromPath('audio', audioFile.path));
      final streamed = await req.send().timeout(_audioVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      return Map<String, dynamic>.from(jsonDecode(body));
    } catch (e) { return {'success': false, 'error': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifyListingPhotoWorker({required File photo, String title = 'Property'}) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_workerBase/api/verify/listing'))
        ..headers.addAll(_workerHeaders())
        ..fields['title'] = title
        ..files.add(await http.MultipartFile.fromPath('photo', photo.path));
      final streamed = await req.send().timeout(_imageVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      return Map<String, dynamic>.from(jsonDecode(body));
    } catch (e) { return {'success': false, 'error': e.toString()}; }
  }

  static Future<Map<String, dynamic>> verifyContent({
    required String type,
    required String mediaBase64,
    required String mimeType,
    String? textContent,
    String? userId,
    List<String>? videoFrames,
  }) async {
    try {
      final res = await Supabase.instance.client.functions.invoke('verify-content', headers: _aiHeaders(), body: {
        'type': type,
        'mediaBase64': mediaBase64,
        'mimeType': mimeType,
        if (textContent != null) 'textContent': textContent,
        'userId': userId,
        if (videoFrames != null) 'videoFrames': videoFrames,
      });
      return Map<String, dynamic>.from(res.data ?? {});
    } catch (e) { return {'success': false, 'error': e.toString()}; }
  }

  static Future<Map<String, dynamic>> createVerifiedListing({required String title, required String description, required double price, required String type, required String imageBase64, String? userId}) async {
    try {
      final res = await Supabase.instance.client.functions.invoke('listing-create', headers: {'X-Shield-Signature': 'SHIELD_VERIFIED_772'}, body: {
        'title': title,
        'description': description,
        'price': price,
        'type': type,
        'imageBase64': imageBase64,
        'userId': userId,
      });
      return Map<String, dynamic>.from(res.data ?? {});
    } catch (e) { return {'status': 'error', 'description': e.toString()}; }
  }

  static bool moderationVerified(Map<String, dynamic> response) => response['success'] == true || response['verified'] == true;

  // ── TRANSPORT DRIVER VERIFICATION ──
  static Future<Map<String, dynamic>> verifyTransportDriver({
    required File driverSelfie,
    required File permitImage,
    required File vehicleImage,
    required String issuingCountryCode,
    required bool aiProcessingConsent,
  }) async {
    try {
      final driverBase64 = await fileToBase64(driverSelfie);
      final permitBase64 = await fileToBase64(permitImage);
      final vehicleBase64 = await fileToBase64(vehicleImage);

      final res = await Supabase.instance.client.functions.invoke(
        'verify-transport',
        headers: _aiHeaders(),
        body: {
          'action': 'verify_transport',
          'payload': {
            'driverImageBase64': driverBase64,
            'permitImageBase64': permitBase64,
            'vehicleImageBase64': vehicleBase64,
            'issuingCountryCode': issuingCountryCode.trim().toUpperCase(),
            'aiProcessingConsent': aiProcessingConsent,
          },
        },
      );
      return Map<String, dynamic>.from(res.data ?? {});
    } catch (e) {
      return {'verified': false, 'error': e.toString()};
    }
  }

  // ── LIVE FRAME SAFETY ──
  static Future<LiveSafetyResult> scanLiveFrameWorker(File frameFile) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_workerBase/api/verify/live-frame'))
        ..headers.addAll(_workerHeaders())
        ..files.add(await http.MultipartFile.fromPath('frame', frameFile.path));
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      final body = await streamed.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final flagList = (data['flags'] as List?)?.cast<String>() ?? [];
      final flagMap = {for (final f in flagList) f: true};
      return LiveSafetyResult(
        safe: data['safe'] ?? true,
        flags: flagMap,
        severity: data['severity'] ?? 'none',
        reason: data['reason'],
        confidence: (data['confidence'] ?? 0.0).toDouble(),
      );
    } catch (e) {
      return LiveSafetyResult.safe();
    }
  }

  // ── UTILS ──
  static Future<String> fileToBase64(File file) async {
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

  static Future<List<String>> extractVideoFrames(File videoFile) async {
    final List<String> base64Frames = [];
    final controller = VideoPlayerController.file(videoFile);
    try {
      await controller.initialize();
      final durationMs = controller.value.duration.inMilliseconds;
      final random = math.Random();
      for (int i = 0; i < 5; i++) {
        final timeMs = durationMs > 1000 ? random.nextInt(durationMs - 500) + 100 : 0;
        final uint8list = await VideoThumbnail.thumbnailData(
          video: videoFile.path,
          imageFormat: ImageFormat.JPEG,
          timeMs: timeMs,
          quality: 45,
          maxWidth: 400,
        );
        if (uint8list != null) {
          base64Frames.add(base64Encode(uint8list));
        }
      }
    } catch (e) {
      debugPrint(\"Error extracting video frames: $e\");
    } finally {
      await controller.dispose();
    }
    return base64Frames;
  }

  static Future<List<File>> extractVideoFrameFiles(
    File videoFile, {
    Directory? directory,
    int frameCount = 5,
  }) async {
    final outputDirectory = directory ?? await Directory.systemTemp.createTemp('necxa_frames_');
    final controller = VideoPlayerController.file(videoFile);
    try {
      await controller.initialize();
      final durationMs = controller.value.duration.inMilliseconds;
      if (durationMs <= 0) return [];
      final count = frameCount.clamp(1, 5);
      final frames = <File>[];
      for (var index = 0; index < count; index++) {
        final fraction = count == 1 ? 0.0 : index / (count - 1);
        final timestamp = (durationMs * fraction).round().clamp(0, durationMs - 1);
        final bytes = await VideoThumbnail.thumbnailData(
          video: videoFile.path,
          imageFormat: ImageFormat.JPEG,
          timeMs: timestamp,
          quality: 70,
          maxWidth: 720,
        );
        if (bytes == null || bytes.isEmpty) continue;
        final frame = File('${outputDirectory.path}/frame_$index.jpg');
        await frame.writeAsBytes(bytes, flush: true);
        frames.add(frame);
      }
      return frames;
    } finally {
      await controller.dispose();
    }
  }

  static Future<String> askNecxaWorker(
    String userPrompt, {
    String language = 'English',
    List<Map<String, dynamic>> conversation = const [],
    Map<String, dynamic>? context,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('$_workerBase/api/assistant/chat/sync'),
        headers: {\"Content-Type\": \"application/json\", ..._workerHeaders()},
        body: jsonEncode({
          'message': userPrompt,
          'language': language,
          'messages': conversation,
          'context': context,
        }),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['response'] as String? ?? 'No response';
      }
      throw Exception('Worker returned ${res.statusCode}');
    } catch (e) {
      debugPrint('Worker chat failed: $e');
      return 'AI verification is temporarily unavailable. Please try again.';
    }
  }
}
