import 'dart:convert';
import 'package:universal_io/io.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
class ListingSyncService {
  static const _verificationTimeout = Duration(seconds: 90);
  static const _listingTimeout = Duration(minutes: 2);
  // SP2 owns encrypted identity-verification evidence. SP1 remains the
  // application/session and listing project.
  static const _verificationProjectUrl =
      'https://ayvescksetiuekoyfqar.supabase.co';
  static const _verificationPublishableKey =
      'sb_publishable_Bc_CXsA3BiuP36E4KxgkYQ_QmvyV7HT';

  static Future<File> compressImage(File file) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final targetPath = p.join(
        tempDir.path,
        'compressed_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final result = await FlutterImageCompress.compressAndGetFile(
        file.absolute.path,
        targetPath,
        quality: 75,
        minWidth: 1024,
        minHeight: 1024,
        format: CompressFormat.jpeg,
      );

      if (result != null) {
        return File(result.path);
      }
    } catch (e) {
      print('Error compressing image: $e');
    }
    return file; // Fallback to original
  }
  static String get _edgeFuncUrl {
    final restUrl = Supabase.instance.client.rest.url;
    final baseUrl = restUrl.split('/rest/v1')[0];
    return '$baseUrl/functions/v1/listing-create';
  }

  static String get _utilityFuncUrl {
    final restUrl = Supabase.instance.client.rest.url;
    final baseUrl = restUrl.split('/rest/v1')[0];
    return '$baseUrl/functions/v1/utility-verify';
  }

  static String get _identityFuncUrl =>
      '$_verificationProjectUrl/functions/v1/identity-verify';

  static String get _faceCacheFuncUrl =>
      '$_verificationProjectUrl/functions/v1/face-session-cache';

  static Future<Map<String, String>> _getHeaders() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) throw Exception("Not logged in");

    final apikey = Supabase.instance.client.rest.headers['apikey'] ?? '';

    return {
      'Authorization': 'Bearer ${session.accessToken}',
      // SP2 and federated functions validate the primary project JWT through
      // this explicit bridge header.
      'x-primary-jwt': session.accessToken,
      'apikey': apikey,
      'X-Shield-Signature': 'SHIELD_VERIFIED_772',
    };
  }

  static Map<String, dynamic> _decodeResponse(
    String body,
    int statusCode,
    String operation,
  ) {
    Map<String, dynamic>? decoded;
    try {
      final value = jsonDecode(body);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    } on FormatException {
      // A proxy can return HTML/plain text. Keep the user-facing error safe.
    }
    if (statusCode >= 200 && statusCode < 300 && decoded != null) {
      return decoded;
    }
    final message = decoded?['message']?.toString().trim();
    final error = decoded?['error']?.toString().trim();
    throw Exception(
      (message?.isNotEmpty ?? false)
          ? message
          : (error?.isNotEmpty ?? false)
          ? error
          : '$operation failed (${statusCode == 0 ? 'network error' : statusCode}). Please try again.',
    );
  }

  // ============================================
  // STAGE 1: IDENTITY SHARD
  // ============================================
  static Future<Map<String, dynamic>> submitIdentityShard({
    required String country,
    required String docType,
    required String docNumber,
    required File idFront,
    required File idBack,
    required File idHolding,
    required File facePhoto,
    required String frontVerificationId,
    required String backVerificationId,
    required String holdingVerificationId,
    required String biometricVerificationId,
    String? idempotencyKey,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_identityFuncUrl));
    final headers = await _getHeaders();
    headers['apikey'] = _verificationPublishableKey;
    req.headers.addAll(headers);
    if (idempotencyKey != null) {
      req.headers['Idempotency-Key'] = idempotencyKey;
    }

    req.fields['country'] = country;
    req.fields['doc_type'] = docType;
    req.fields['doc_number'] = docNumber;
    req.fields['front_verification_id'] = frontVerificationId;
    req.fields['back_verification_id'] = backVerificationId;
    req.fields['holding_verification_id'] = holdingVerificationId;
    req.fields['biometric_verification_id'] = biometricVerificationId;

    req.files.add(await http.MultipartFile.fromPath('id_front', (await compressImage(idFront)).path));
    req.files.add(await http.MultipartFile.fromPath('id_back', (await compressImage(idBack)).path));
    req.files.add(
      await http.MultipartFile.fromPath('id_holding', (await compressImage(idHolding)).path),
    );
    req.files.add(
      await http.MultipartFile.fromPath('face_photo', (await compressImage(facePhoto)).path),
    );

    final res = await req.send().timeout(_verificationTimeout);
    final resBody = await res.stream.bytesToString();
    return _decodeResponse(resBody, res.statusCode, 'Identity verification');
  }

  static Future<Map<String, dynamic>> cacheFaceSession({
    required String sessionId,
    required String identityShardId,
    required bool faceMatch,
    required double score,
    bool verified = true,
  }) async {
    final res = await http.post(
      Uri.parse('$_faceCacheFuncUrl/cache'),
      headers: {...await _getHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode({
        'sessionId': sessionId,
        'identityShardId': identityShardId,
        'faceMatch': faceMatch,
        'score': score,
        'verified': verified,
      }),
    );
    final body = res.body;
    if (res.statusCode >= 400) {
      throw Exception('Face cache error (${res.statusCode}): $body');
    }
    return jsonDecode(body);
  }

  static Future<Map<String, dynamic>> compareFaceSession({
    required String sessionId,
    required File selfie,
  }) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_faceCacheFuncUrl/compare?sessionId=$sessionId'),
    );
    req.headers.addAll(await _getHeaders());
    req.files.add(await http.MultipartFile.fromPath('selfie', (await compressImage(selfie)).path));

    final res = await req.send();
    final resBody = await res.stream.bytesToString();
    if (res.statusCode >= 400) {
      throw Exception('Face compare error (${res.statusCode}): $resBody');
    }
    return jsonDecode(resBody);
  }

  // ============================================
  // STAGE 2: UTILITY SHARD  →  utility-verify function
  // ============================================
  static Future<Map<String, dynamic>> submitUtilityShard({
    required String country,
    String? umemeMeter,
    String? nwscAccount,
    String? kplcMeter,
    String? tanescoMeter,
    String? landBlock,
    String? landPlot,
    String? lc1Officer,
    String? propertyId,
    String? propertyType,
    File? utilityBillPhoto,
    File? lc1StampPhoto,
    File? landTitlePhoto,
    File? businessLicensePhoto,
    String? role,
    String? idempotencyKey,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_utilityFuncUrl));
    req.headers.addAll(await _getHeaders());
    if (idempotencyKey != null) {
      req.headers['Idempotency-Key'] = idempotencyKey;
    }

    req.fields['country'] = country;
    if (role != null) req.fields['role'] = role;
    if (propertyId != null) req.fields['property_id'] = propertyId;
    if (propertyType != null) req.fields['property_type'] = propertyType;
    if (umemeMeter != null) req.fields['umeme_meter'] = umemeMeter;
    if (nwscAccount != null) req.fields['nwsc_account'] = nwscAccount;
    if (kplcMeter != null) req.fields['kplc_meter'] = kplcMeter;
    if (tanescoMeter != null) req.fields['tanesco_meter'] = tanescoMeter;
    if (landBlock != null) req.fields['land_block'] = landBlock;
    if (landPlot != null) req.fields['land_plot'] = landPlot;
    if (lc1Officer != null) req.fields['lc1_officer'] = lc1Officer;

    if (utilityBillPhoto != null) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'utility_bill_photo',
          (await compressImage(utilityBillPhoto)).path,
        ),
      );
    }
    if (lc1StampPhoto != null) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'lc1_stamp_photo',
          (await compressImage(lc1StampPhoto)).path,
        ),
      );
    }
    if (landTitlePhoto != null) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'land_title_photo',
          (await compressImage(landTitlePhoto)).path,
        ),
      );
    }
    if (businessLicensePhoto != null) {
      req.files.add(
        await http.MultipartFile.fromPath(
          'business_license_photo',
          (await compressImage(businessLicensePhoto)).path,
        ),
      );
    }

    final res = await req.send().timeout(_verificationTimeout);
    final resBody = await res.stream.bytesToString();
    return _decodeResponse(resBody, res.statusCode, 'Utility verification');
  }

  // ============================================
  // STAGE 3: GPS LOCK
  // ============================================
  static Future<Map<String, dynamic>> submitGpsLock({
    required double lat,
    required double lng,
    required double accuracy,
    required String reportedAddress,
    required String reportedDistrict,
    String? idempotencyKey,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_edgeFuncUrl));
    req.headers.addAll(await _getHeaders());
    if (idempotencyKey != null) {
      req.headers['Idempotency-Key'] = idempotencyKey;
    }

    req.fields['stage'] = 'gps_lock';
    req.fields['latitude'] = lat.toString();
    req.fields['longitude'] = lng.toString();
    req.fields['accuracy'] = accuracy.toString();
    req.fields['reported_address'] = reportedAddress;
    req.fields['reported_district'] = reportedDistrict;

    final res = await req.send().timeout(_verificationTimeout);
    final resBody = await res.stream.bytesToString();
    return _decodeResponse(resBody, res.statusCode, 'GPS verification');
  }

  // ============================================
  // STAGE 4: NEURAL SYNTHESIS
  // ============================================
  static Future<Map<String, dynamic>> submitNeuralSynthesis({
    required String identityShardId,
    required String utilityShardId,
    required String gpsNodeId,
    required String title,
    required String description,
    required String propertyType,
    required String purpose,
    required String country,
    required String district,
    required String address,
    required int priceUgx,
    required String pricePeriod,
    required int bedrooms,
    required int bathrooms,
    required int sqft,
    required List<String> amenities,
    String? agentPhone,
    String? agentWhatsapp,
    String? agentGoogleMeet,
    double? livePingLat,
    double? livePingLng,
    Map<String, dynamic>? securityMetadata,
    required List<File> photos,
    required List<File> bathroomPhotos,
    String? musicTrackId,
    String? audioUrl,
    String? idempotencyKey,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_edgeFuncUrl));
    final session = Supabase.instance.client.auth.currentSession;
    final effectiveIdempotencyKey =
        idempotencyKey ??
        'listing-${session?.user.id ?? 'anonymous'}-${DateTime.now().microsecondsSinceEpoch}';
    req.headers.addAll(await _getHeaders());
    req.headers['Idempotency-Key'] = effectiveIdempotencyKey;

    req.fields['stage'] = 'neural_synthesis';
    req.fields['idempotency_key'] = effectiveIdempotencyKey;
    req.fields['identity_shard_id'] = identityShardId;
    req.fields['utility_shard_id'] = utilityShardId;
    req.fields['gps_node_id'] = gpsNodeId;

    req.fields['title'] = title;
    req.fields['description'] = description;
    req.fields['property_type'] = propertyType;
    req.fields['purpose'] = purpose;
    req.fields['country'] = country;
    req.fields['district'] = district;
    req.fields['address'] = address;
    req.fields['price_ugx'] = priceUgx.toString();
    req.fields['price_period'] = pricePeriod;
    req.fields['bedrooms'] = bedrooms.toString();
    req.fields['bathrooms'] = bathrooms.toString();
    req.fields['sqft'] = sqft.toString();
    req.fields['amenities'] = jsonEncode(amenities);

    if (agentPhone != null) req.fields['agent_phone'] = agentPhone;
    if (agentWhatsapp != null) req.fields['agent_whatsapp'] = agentWhatsapp;
    if (agentGoogleMeet != null)
      req.fields['agent_google_meet'] = agentGoogleMeet;
    if (livePingLat != null)
      req.fields['live_ping_lat'] = livePingLat.toString();
    if (livePingLng != null)
      req.fields['live_ping_lng'] = livePingLng.toString();
    if (musicTrackId != null) req.fields['music_track_id'] = musicTrackId;
    if (audioUrl != null) req.fields['audio_url'] = audioUrl;

    if (securityMetadata != null) {
      req.fields['security_metadata'] = jsonEncode(securityMetadata);
    }

    for (int i = 0; i < photos.length; i++) {
      final compressedPhoto = await compressImage(photos[i]);
      req.files.add(
        await http.MultipartFile.fromPath('photo_$i', compressedPhoto.path),
      );
    }

    for (int i = 0; i < bathroomPhotos.length; i++) {
      final compressedBath = await compressImage(bathroomPhotos[i]);
      req.files.add(
        await http.MultipartFile.fromPath(
          'bathroom_$i',
          compressedBath.path,
        ),
      );
    }

    final res = await req.send().timeout(_listingTimeout);
    final resBody = await res.stream.bytesToString();
    return _decodeResponse(resBody, res.statusCode, 'Listing submission');
  }
}
