import 'dart:convert';
import 'package:universal_io/io.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class ListingSyncService {
  // SP2 owns encrypted identity-verification evidence. SP1 remains the
  // application/session and listing project.
  static const _verificationProjectUrl =
      'https://ayvescksetiuekoyfqar.supabase.co';
  static const _verificationPublishableKey =
      'sb_publishable_Bc_CXsA3BiuP36E4KxgkYQ_QmvyV7HT';
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
      'apikey': apikey,
      'X-Shield-Signature': 'SHIELD_VERIFIED_772',
    };
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
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_identityFuncUrl));
    final headers = await _getHeaders();
    headers['apikey'] = _verificationPublishableKey;
    req.headers.addAll(headers);
    
    req.fields['country'] = country;
    req.fields['doc_type'] = docType;
    req.fields['doc_number'] = docNumber;
    
    req.files.add(await http.MultipartFile.fromPath('id_front', idFront.path));
    req.files.add(await http.MultipartFile.fromPath('id_back', idBack.path));
    req.files.add(await http.MultipartFile.fromPath('id_holding', idHolding.path));
    req.files.add(await http.MultipartFile.fromPath('face_photo', facePhoto.path));

    final res = await req.send();
    final resBody = await res.stream.bytesToString();
    if (res.statusCode >= 400) {
      throw Exception('Identity Shard Error: $resBody');
    }
    return jsonDecode(resBody);
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
      headers: {
        ...await _getHeaders(),
        'Content-Type': 'application/json',
      },
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
    req.files.add(await http.MultipartFile.fromPath('selfie', selfie.path));
 
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
    String? propertyId,
    String? propertyType,
    File? lc1StampPhoto,
    File? landTitlePhoto,
    File? businessLicensePhoto,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_utilityFuncUrl));
    req.headers.addAll(await _getHeaders());

    req.fields['country'] = country;
    if (propertyId != null)   req.fields['property_id'] = propertyId;
    if (propertyType != null) req.fields['property_type'] = propertyType;
    if (umemeMeter != null)   req.fields['umeme_meter'] = umemeMeter;
    if (nwscAccount != null)  req.fields['nwsc_account'] = nwscAccount;
    if (kplcMeter != null)    req.fields['kplc_meter'] = kplcMeter;
    if (tanescoMeter != null) req.fields['tanesco_meter'] = tanescoMeter;
    if (landBlock != null)    req.fields['land_block'] = landBlock;
    if (landPlot != null)     req.fields['land_plot'] = landPlot;

    if (lc1StampPhoto != null) {
      req.files.add(await http.MultipartFile.fromPath('lc1_stamp_photo', lc1StampPhoto.path));
    }
    if (landTitlePhoto != null) {
      req.files.add(await http.MultipartFile.fromPath('land_title_photo', landTitlePhoto.path));
    }
    if (businessLicensePhoto != null) {
      req.files.add(await http.MultipartFile.fromPath('business_license_photo', businessLicensePhoto.path));
    }

    final res = await req.send();
    final resBody = await res.stream.bytesToString();
    if (res.statusCode >= 400) {
      throw Exception('Utility Shard Error ${res.statusCode}: $resBody');
    }
    return jsonDecode(resBody);
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
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_edgeFuncUrl));
    req.headers.addAll(await _getHeaders());

    req.fields['stage'] = 'gps_lock';
    req.fields['latitude'] = lat.toString();
    req.fields['longitude'] = lng.toString();
    req.fields['accuracy'] = accuracy.toString();
    req.fields['reported_address'] = reportedAddress;
    req.fields['reported_district'] = reportedDistrict;

    final res = await req.send();
    final resBody = await res.stream.bytesToString();
    if (res.statusCode >= 400) {
      throw Exception('GPS Lock Error: $resBody');
    }
    return jsonDecode(resBody);
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
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse(_edgeFuncUrl));
    req.headers.addAll(await _getHeaders());

    req.fields['stage'] = 'neural_synthesis';
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
    if (agentGoogleMeet != null) req.fields['agent_google_meet'] = agentGoogleMeet;
    if (livePingLat != null)     req.fields['live_ping_lat'] = livePingLat.toString();
    if (livePingLng != null)     req.fields['live_ping_lng'] = livePingLng.toString();
    if (musicTrackId != null)    req.fields['music_track_id'] = musicTrackId;
    if (audioUrl != null)        req.fields['audio_url'] = audioUrl;

    if (securityMetadata != null) {
      req.fields['security_metadata'] = jsonEncode(securityMetadata);
    }

    for (int i = 0; i < photos.length; i++) {
      req.files.add(await http.MultipartFile.fromPath('photo_$i', photos[i].path));
    }
    
    for (int i = 0; i < bathroomPhotos.length; i++) {
      req.files.add(await http.MultipartFile.fromPath('bathroom_$i', bathroomPhotos[i].path));
    }

    final res = await req.send();
    final resBody = await res.stream.bytesToString();
    if (res.statusCode >= 400) {
      throw Exception('Neural Synthesis Error: $resBody');
    }
    return jsonDecode(resBody);
  }
}
