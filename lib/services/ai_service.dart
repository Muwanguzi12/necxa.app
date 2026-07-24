import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

// ─── Live Safety Scan Result ──────────────────────────────────────────────────
class LiveSafetyResult {
  final bool safe;
  final Map<String, bool>
  flags; // e.g. {'pornographic': true, 'drug_abuse': false}
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
  // ── USING PRIMARY SUPABASE CLIENT FOR DECOUPLED AI SERVICES ──

  static Map<String, dynamic> buildIdentityShardPayload({
    required String action,
    required String primaryBase64,
    String? secondaryBase64,
    String? userId,
  }) {
    final payload = <String, dynamic>{
      'action': action,
      'payload': {'imageBase64': primaryBase64, 'userId': userId},
    };

    if (secondaryBase64 != null) {
      payload['payload']['idImageBase64'] = secondaryBase64;
    }

    return payload;
  }

  // ── CLOUDFLARE WORKER DIRECT REST CLIENT ──
  // necxa-ai v2: Runs on Cloudflare Workers at api.necxa.uk
  // Endpoints: /api/verify/photo, /api/verify/video, /api/verify/audio,
  //            /api/verify/listing, /api/verify/live-frame,
  //            /api/assistant/chat/sync
  static const String _workerBase = 'https://api.necxa.uk';
  static const Duration _imageVerificationTimeout = Duration(seconds: 45);
  static const Duration _videoVerificationTimeout = Duration(seconds: 90);
  static const Duration _audioVerificationTimeout = Duration(seconds: 90);

  static String _verificationRequestError(
    Object error,
    String mediaLabel,
  ) {
    if (error is TimeoutException) {
      return '$mediaLabel verification took longer than expected. Check your connection and try again.';
    }
    return '$mediaLabel verification could not connect. Check your connection and try again.';
  }

  /// Returns auth headers that forward the logged-in user's primary JWT to
  /// the Cloudflare Worker for cross-service identity resolution.
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

  static Map<String, dynamic> _decodeWorkerResponse({
    required String body,
    required int statusCode,
    required String operation,
  }) {
    Map<String, dynamic>? decoded;
    try {
      final value = jsonDecode(body);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } on FormatException {
      // Cloudflare can return a plain-text or HTML error page instead of JSON.
    }

    if (statusCode >= 200 && statusCode < 300 && decoded != null) {
      return decoded;
    }

    final workerError = decoded?['error']?.toString().trim();
    final cloudflareCode = RegExp(
      r'error\s+code:\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(body)?.group(1);
    final serviceMessage = cloudflareCode == '1101'
        ? 'AI verification is temporarily unavailable. Please try again.'
        : '$operation failed. Please try again.';

    return {
      'success': false,
      'error': workerError?.isNotEmpty == true ? workerError : serviceMessage,
      'statusCode': statusCode,
      if (cloudflareCode != null) 'providerErrorCode': cloudflareCode,
    };
  }

  // ── WORKER: PHOTO MODERATION ──────────────────────────────────────────────
  /// Submits a photo to the Cloudflare Worker's universal content moderation
  /// engine (`/api/verify/photo`). Falls back to Supabase on network error.
  static Future<Map<String, dynamic>> verifyPhotoWorker(File photoFile) async {
    try {
      final req =
          http.MultipartRequest(
              'POST',
              Uri.parse('$_workerBase/api/verify/photo'),
            )
            ..headers.addAll(_workerHeaders())
            ..files.add(
              await http.MultipartFile.fromPath('photo', photoFile.path),
            );
      final streamed = await req.send().timeout(_imageVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      return _decodeWorkerResponse(
        body: body,
        statusCode: streamed.statusCode,
        operation: 'Photo verification',
      );
    } catch (e) {
      debugPrint('⚡ Worker photo verify failed: $e');
      return {
        'success': false,
        'error': _verificationRequestError(e, 'Photo'),
      };
    }
  }

  // ── WORKER: VIDEO MODERATION (multi-frame) ────────────────────────────────
  /// Submits up to 5 extracted video frames to `/api/verify/video`.
  static Future<Map<String, dynamic>> verifyVideoWorker(
    List<File> frames,
  ) async {
    try {
      if (frames.isEmpty) {
        return {'success': false, 'error': 'No video frames were extracted'};
      }
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_workerBase/api/verify/video'),
      )..headers.addAll(_workerHeaders());
      for (int i = 0; i < frames.length && i < 5; i++) {
        req.files.add(
          await http.MultipartFile.fromPath('frame$i', frames[i].path),
        );
      }
      final streamed = await req.send().timeout(_videoVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      final decoded = _decodeWorkerResponse(
        body: body,
        statusCode: streamed.statusCode,
        operation: 'Video verification',
      );
      if (decoded['success'] == false) return decoded;
      return normalizeModerationResponse(decoded);
    } catch (e) {
      debugPrint('⚡ Worker video verify failed: $e');
      return {
        'success': false,
        'error': _verificationRequestError(e, 'Video'),
      };
    }
  }

  /// Produces deterministic JPEG samples across the complete video. The caller
  /// owns [directory] and is responsible for deleting it after verification.
  static Future<List<File>> extractVideoFrameFiles(
    File videoFile, {
    Directory? directory,
    int frameCount = 5,
  }) async {
    final outputDirectory =
        directory ?? await Directory.systemTemp.createTemp('necxa_frames_');
    final controller = VideoPlayerController.file(videoFile);
    try {
      await controller.initialize();
      final durationMs = controller.value.duration.inMilliseconds;
      if (durationMs <= 0) return [];
      final count = frameCount.clamp(1, 5);
      final frames = <File>[];
      for (var index = 0; index < count; index++) {
        final fraction = count == 1 ? 0.0 : index / (count - 1);
        final timestamp = (durationMs * fraction).round().clamp(
          0,
          durationMs - 1,
        );
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

  static Map<String, dynamic> normalizeModerationResponse(
    Map<String, dynamic> response,
  ) {
    final rawResult = response['result'];
    final result = rawResult is Map
        ? Map<String, dynamic>.from(rawResult)
        : <String, dynamic>{};
    final verified = result['verified'] == true;
    return {
      ...response,
      'success': response['success'] == true,
      'result': {
        ...result,
        'verified': verified,
        'flags': List<String>.from(result['flags'] as List? ?? const []),
      },
    };
  }

  static bool moderationVerified(Map<String, dynamic> response) =>
      response['success'] == true &&
      response['result'] is Map &&
      (response['result'] as Map)['verified'] == true;

  // ── WORKER: AUDIO MODERATION (Whisper + Llama) ────────────────────────────
  /// Transcribes audio via Whisper then moderates the transcript.
  /// Endpoint: `/api/verify/audio`.
  static Future<Map<String, dynamic>> verifyAudioWorker(File audioFile) async {
    try {
      final req =
          http.MultipartRequest(
              'POST',
              Uri.parse('$_workerBase/api/verify/audio'),
            )
            ..headers.addAll(_workerHeaders())
            ..files.add(
              await http.MultipartFile.fromPath('audio', audioFile.path),
            );
      final streamed = await req.send().timeout(_audioVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      return _decodeWorkerResponse(
        body: body,
        statusCode: streamed.statusCode,
        operation: 'Audio verification',
      );
    } catch (e) {
      debugPrint('⚡ Worker audio verify failed: $e');
      return {
        'success': false,
        'error': _verificationRequestError(e, 'Audio'),
      };
    }
  }

  // ── WORKER: LISTING PHOTO VERIFICATION ───────────────────────────────────
  /// Verifies a property listing photo is a legitimate real estate image.
  /// Endpoint: `/api/verify/listing`.
  static Future<Map<String, dynamic>> verifyListingPhotoWorker({
    required File photo,
    String title = 'Property',
  }) async {
    try {
      final req =
          http.MultipartRequest(
              'POST',
              Uri.parse('$_workerBase/api/verify/listing'),
            )
            ..headers.addAll(_workerHeaders())
            ..fields['title'] = title
            ..files.add(await http.MultipartFile.fromPath('photo', photo.path));
      final streamed = await req.send().timeout(_imageVerificationTimeout);
      final body = await streamed.stream.bytesToString();
      return _decodeWorkerResponse(
        body: body,
        statusCode: streamed.statusCode,
        operation: 'Listing verification',
      );
    } catch (e) {
      debugPrint('⚡ Worker listing verify failed: $e');
      return {
        'success': false,
        'verified': false,
        'score': 0,
        'error': _verificationRequestError(e, 'Listing'),
      };
    }
  }

  // ── WORKER: LIVE FRAME SAFETY SCAN ────────────────────────────────────────
  /// Submits a live-stream frame directly to the Worker's safety scanner.
  /// Endpoint: `/api/verify/live-frame`. Falls back to safe() on error.
  static Future<LiveSafetyResult> scanLiveFrameWorker(File frameFile) async {
    try {
      final req =
          http.MultipartRequest(
              'POST',
              Uri.parse('$_workerBase/api/verify/live-frame'),
            )
            ..headers.addAll(_workerHeaders())
            ..files.add(
              await http.MultipartFile.fromPath('frame', frameFile.path),
            );
      final streamed = await req.send().timeout(const Duration(seconds: 15));
      final body = await streamed.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      // Worker returns flags as List<String>; convert to Map<String,bool>
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
      debugPrint('⚡ Worker live-frame scan (non-fatal): $e');
      return LiveSafetyResult.safe();
    }
  }

  // ── WORKER: SYNC CHAT (non-streaming, for mobile) ─────────────────────────
  /// Calls `/api/assistant/chat/sync` — multilingual Workers AI chat.
  /// The [language] parameter locks the AI response to the user's preferred language.
  /// Falls back to the Supabase necxa-chat function if the worker is down.
  static Future<String> askNecxaWorker(
    String userPrompt, {
    String language = 'English',
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_workerBase/api/assistant/chat/sync'),
            headers: {"Content-Type": "application/json", ..._workerHeaders()},
            body: jsonEncode({'message': userPrompt, 'language': language}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['response'] as String? ?? 'No response';
      }
      throw Exception('Worker returned ${res.statusCode}');
    } catch (e) {
      debugPrint('⚡ Worker chat failed, falling back to Supabase: $e');
      // Fallback to existing Supabase necxa-chat function
      return askNexca(userPrompt);
    }
  }

  // ── HELPERS ──
  static Future<String> fileToBase64(File file) async {
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

  // Generate headers attaching the active primary user session token dynamically
  static Map<String, String> _aiHeaders({Map<String, String>? extra}) {
    final Map<String, String> headers = {};
    if (extra != null) {
      headers.addAll(extra);
    }
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        headers['x-primary-jwt'] = session.accessToken;
      }
    } catch (_) {}
    return headers;
  }

  // ── IDENTITY VERIFICATION ──
  static Future<Map<String, dynamic>> verifyID(
    File imageFile, {
    String? userId,
    String action = 'verify-id',
  }) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null)
        throw Exception("User must be logged in to verify ID natively.");

      final primaryBase64 = await fileToBase64(imageFile);
      final res = await Supabase.instance.client.functions.invoke(
        'verify-identity-shard',
        headers: _aiHeaders(),
        body: buildIdentityShardPayload(
          action: action,
          primaryBase64: primaryBase64,
          userId: userId ?? session.user.id,
        ),
      );

      final data = Map<String, dynamic>.from(res.data ?? {});
      final verified = data['verified'] == true;
      final feedback =
          data['feedback']?.toString() ??
          data['error']?.toString() ??
          'ID verification failed';
      final score = data['score'] is num
          ? data['score']
          : num.tryParse(data['score']?.toString() ?? '');

      return {
        ...data,
        'verified': verified,
        'feedback': feedback,
        'score': score ?? 0,
      };
    } catch (e) {
      return {
        'verified': false,
        'feedback': 'Verification failed: $e',
        'score': 0,
      };
    }
  }

  static Future<Map<String, dynamic>> verifyFaceOnly(
    File selfieFile, {
    String? userId,
  }) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null)
        throw Exception(
          "User must be logged in to verify biometrics natively.",
        );

      final primaryBase64 = await fileToBase64(selfieFile);
      final res = await Supabase.instance.client.functions.invoke(
        'verify-identity-shard',
        headers: _aiHeaders(),
        body: buildIdentityShardPayload(
          action: 'verify-face-only',
          primaryBase64: primaryBase64,
          userId: userId ?? session.user.id,
        ),
      );

      final data = Map<String, dynamic>.from(res.data ?? {});
      final faceMatch = data['faceMatch'] == true || data['verified'] == true;
      final feedback =
          data['feedback']?.toString() ??
          data['error']?.toString() ??
          'Face-only verification failed';
      final score = data['score'] is num
          ? data['score']
          : num.tryParse(data['score']?.toString() ?? '');

      return {
        ...data,
        'faceMatch': faceMatch,
        'feedback': feedback,
        'score': score ?? 0,
      };
    } catch (e) {
      return {
        'faceMatch': false,
        'feedback': 'Verification failed: $e',
        'score': 0,
      };
    }
  }

  // ── LIVE STREAM SAFETY SCAN ──────────────────────────────────────────────────
  /// Scans a single captured live frame for policy violations.
  /// Detects: pornographic content, drug abuse, child safety, dangerous acts, hate symbols.
  /// Falls back to [LiveSafetyResult.safe()] on network errors to avoid false stream kills.
  static Future<LiveSafetyResult> scanLiveFrame(
    File frameFile, {
    String? channelId,
    String? streamerId,
  }) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) return LiveSafetyResult.safe();

      final base64 = await fileToBase64(frameFile);

      final res = await Supabase.instance.client.functions.invoke(
        'verify-content',
        headers: _aiHeaders(),
        body: {
          'action': 'live_safety_scan',
          'mediaBase64': base64,
          'mimeType': 'image/jpeg',
          'channelId': channelId,
          'streamerId': streamerId ?? session.user.id,
        },
      );

      if (res.data == null) return LiveSafetyResult.safe();
      return LiveSafetyResult.fromJson(Map<String, dynamic>.from(res.data));
    } catch (e) {
      // Non-fatal: never kill a stream on a network error — log and continue.
      debugPrint('🛡️ scanLiveFrame (non-fatal): $e');
      return LiveSafetyResult.safe();
    }
  }

  static Future<Map<String, dynamic>> verifySelfie(
    File selfieFile,
    File idReferenceFile, {
    String? userId,
  }) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null)
        throw Exception(
          "User must be logged in to verify biometrics natively.",
        );

      final primaryBase64 = await fileToBase64(selfieFile);
      final secondaryBase64 = await fileToBase64(idReferenceFile);
      final res = await Supabase.instance.client.functions.invoke(
        'verify-identity-shard',
        headers: _aiHeaders(),
        body: buildIdentityShardPayload(
          action: 'verify-selfie',
          primaryBase64: primaryBase64,
          secondaryBase64: secondaryBase64,
          userId: userId ?? session.user.id,
        ),
      );

      final data = Map<String, dynamic>.from(res.data ?? {});
      final faceMatch = data['faceMatch'] == true || data['verified'] == true;
      final feedback =
          data['feedback']?.toString() ??
          data['error']?.toString() ??
          'Biometric verification failed';
      final score = data['score'] is num
          ? data['score']
          : num.tryParse(data['score']?.toString() ?? '');

      return {
        ...data,
        'faceMatch': faceMatch,
        'feedback': feedback,
        'score': score ?? 0,
      };
    } catch (e) {
      return {
        'faceMatch': false,
        'feedback': 'Verification failed: $e',
        'score': 0,
      };
    }
  }

  // Legacy compatibility check
  static Future<Map<String, dynamic>> verifyIdentity(
    String idBase64,
    String selfieBase64, {
    String? userId,
  }) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final res = await Supabase.instance.client.functions.invoke(
        'verify-identity-shard',
        headers: _aiHeaders(),
        body: {
          'action': 'verify-selfie',
          'payload': {
            'imageBase64': selfieBase64,
            'idImageBase64': idBase64,
            'userId': userId ?? session?.user.id ?? 'flutter_user',
          },
        },
      );

      final result = Map<String, dynamic>.from(res.data);
      // Compatibility with previous snippets
      result['match'] = result['match'] ?? result['verified'] ?? false;
      return result;
    } catch (e) {
      return {'match': false, 'reason': 'Connection error: $e'};
    }
  }

  // ── CHAT MISSION CONTROL ──
  static Future<String> askNexca(
    String userPrompt, {
    Map<String, dynamic>? context,
  }) async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return 'Login required for Necxa Chat';

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'necxa-chat',
        headers: _aiHeaders(
          extra: {'X-Shield-Signature': 'SHIELD_VERIFIED_772'},
        ),
        body: {
          'messages': [
            {'role': 'user', 'content': userPrompt},
          ],
          'context': context,
          'userId': session.user.id,
        },
      );
      final data = Map<String, dynamic>.from(res.data);
      return data['content'] ?? 'No response';
    } catch (e) {
      return 'Error connecting to Necxa AI: $e';
    }
  }

  // ── MARKETPLACE VERIFICATION ──
  static Future<Map<String, dynamic>> createVerifiedListing({
    required String title,
    required String description,
    required double price,
    required String type,
    required String imageBase64,
    String? userId,
  }) async {
    final session = Supabase.instance.client.auth.currentSession;
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'listing-create',
        headers: {'X-Shield-Signature': 'SHIELD_VERIFIED_772'},
        body: {
          'title': title,
          'description': description,
          'price': price,
          'type': type,
          'imageBase64': imageBase64,
          'userId': session?.user.id ?? userId,
        },
      );
      return Map<String, dynamic>.from(res.data);
    } catch (e) {
      return {'status': 'error', 'description': e.toString()};
    }
  }

  // ── TRANSPORT DRIVER VERIFICATION ──
  static Future<Map<String, dynamic>> verifyTransportDriver({
    required File driverSelfie,
    required File permitImage,
    required File vehicleImage,
    String? userId,
  }) async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null)
      throw Exception("User must be logged in to verify as a driver.");

    try {
      final driverBase64 = await fileToBase64(driverSelfie);
      final permitBase64 = await fileToBase64(permitImage);
      final vehicleBase64 = await fileToBase64(vehicleImage);

      final res = await Supabase.instance.client.functions.invoke(
        'verify-transport',
        headers: _aiHeaders(
          extra: {'X-Shield-Signature': 'SHIELD_VERIFIED_772'},
        ),
        body: {
          'action': 'verify_transport',
          'payload': {
            'driverImageBase64': driverBase64,
            'permitImageBase64': permitBase64,
            'vehicleImageBase64': vehicleBase64,
            'userId': userId ?? session.user.id,
          },
        },
      );

      if (res.status != 200) {
        final data = res.data;
        if (data is Map && data['error'] != null) {
          throw Exception(data['error']);
        }
        throw Exception('Transport AI verification failed.');
      }

      return Map<String, dynamic>.from(res.data);
    } catch (e) {
      return {'verified': false, 'error': e.toString()};
    }
  }

  // ── CONTENT VERIFICATION (Generic) ──
  static Future<Map<String, dynamic>> verifyContent({
    required String type,
    required String mediaBase64,
    required String mimeType,
    String? textContent,
    String? userId,
    List<String>? videoFrames,
  }) async {
    final session = Supabase.instance.client.auth.currentSession;
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'verify-content',
        headers: _aiHeaders(),
        body: {
          'type': type,
          'mediaBase64': mediaBase64,
          'mimeType': mimeType,
          if (textContent != null) 'textContent': textContent,
          'userId': session?.user.id ?? userId ?? 'flutter_user',
          if (videoFrames != null) 'videoFrames': videoFrames,
        },
      );
      return Map<String, dynamic>.from(res.data);
    } catch (e) {
      return {'status': 'error', 'description': e.toString()};
    }
  }

  // Extract 5 random video frames as JPEG thumbnails to moderator API
  static Future<List<String>> extractVideoFrames(File videoFile) async {
    final List<String> base64Frames = [];
    try {
      final controller = VideoPlayerController.file(videoFile);
      await controller.initialize();
      final durationMs = controller.value.duration.inMilliseconds;
      await controller.dispose();

      final random = math.Random();
      for (int i = 0; i < 5; i++) {
        // Pick random timestamps, leaving 100ms padding
        final timeMs = durationMs > 1000
            ? random.nextInt(durationMs - 500) + 100
            : 0;
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
      debugPrint("Error extracting video frames: $e");
    }
    return base64Frames;
  }

  // ── UNIVERSAL MEDIA FILE MODERATION ──
  static Future<Map<String, dynamic>> verifyMediaFile({
    required File file,
    required String type, // 'photo', 'video', 'audio'
    String? textContent,
    String? userId,
  }) async {
    if (type == 'video') {
      final frames = await extractVideoFrames(file);
      return verifyContent(
        type: 'video',
        mediaBase64: '',
        mimeType: 'video/mp4',
        textContent: textContent,
        userId: userId,
        videoFrames: frames,
      );
    } else if (type == 'audio' || type == 'music') {
      final b64 = await fileToBase64(file);
      return verifyContent(
        type: 'audio',
        mediaBase64: b64,
        mimeType: 'audio/mpeg',
        textContent: textContent,
        userId: userId,
      );
    } else {
      final b64 = await fileToBase64(file);
      return verifyContent(
        type: 'photo',
        mediaBase64: b64,
        mimeType: 'image/jpeg',
        textContent: textContent,
        userId: userId,
      );
    }
  }

  // ── SPECIFIC CONTENT METHODS ──
  static Future<Map<String, dynamic>> verifyPhoto(String photoBase64) =>
      verifyContent(
        type: 'photo',
        mediaBase64: photoBase64,
        mimeType: 'image/jpeg',
      );

  static Future<Map<String, dynamic>> verifyMusic(String audioBase64) =>
      verifyContent(
        type: 'music',
        mediaBase64: audioBase64,
        mimeType: 'audio/mpeg',
      );

  static Future<Map<String, dynamic>> verifyVideo(String videoBase64) =>
      verifyContent(
        type: 'video',
        mediaBase64: videoBase64,
        mimeType: 'video/mp4',
      );

  // ── PROPERTY UTILITY VERIFICATION ──
  static Future<Map<String, dynamic>> verifyUtilityBill(
    String billBase64,
    String type, {
    String? userId,
  }) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'utility-verify',
        headers: _aiHeaders(),
        body: {
          'action': 'verify-utility',
          'payload': {'type': type, 'imageBase64': billBase64},
        },
      );
      return Map<String, dynamic>.from(res.data);
    } catch (e) {
      return {'status': 'error', 'description': e.toString()};
    }
  }

  // ── NATIVE PROPERTY VERIFICATION ──
  static Future<Map<String, dynamic>> verifyProperty(String propertyId) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'verify-property',
        headers: _aiHeaders(),
        body: {'property_id': propertyId},
      );
      return Map<String, dynamic>.from(res.data);
    } catch (e) {
      return {'verified': false, 'score': 0, 'feedback': e.toString()};
    }
  }
}
