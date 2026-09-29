import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================
// SMOOTH ACTION SERVICE
// Single-endpoint API for all Necxa operations
// ============================================

class SmoothAction {
  static final _client = Supabase.instance.client;

  static Future<Map<String, dynamic>> _call({
    required String name,
    String action = 'get',
    Map<String, dynamic>? payload,
  }) async {
    final res = await _client.functions.invoke(
      'smooth-action',
      body: {
        'name': name,
        'action': action,
        if (payload != null) 'payload': payload,
      },
    );
    final data = res.data as Map<String, dynamic>;
    if (data['error'] != null) throw Exception(data['error']);
    return data;
  }

  // ── PROFILE ──────────────────────────────────
  static Future<Map<String, dynamic>> getProfile() => _call(name: 'profile');

  // ── PROPERTIES ───────────────────────────────
  static Future<List<dynamic>> listProperties({
    String filter = 'all',
    int limit = 20,
  }) async {
    final res = await _call(
      name: 'property',
      action: 'list',
      payload: {'limit': limit, 'filter': filter},
    );
    return res['data'] as List<dynamic>;
  }

  static Future<Map<String, dynamic>> getProperty(String propertyId) async {
    final res = await _call(
      name: 'property',
      action: 'get',
      payload: {'property_id': propertyId},
    );
    return res['data'] as Map<String, dynamic>;
  }

  static Future<List<dynamic>> myListings() async {
    final res = await _call(name: 'property', action: 'mylistings');
    return res['data'] as List<dynamic>;
  }

  // ── UNLOCK ───────────────────────────────────
  static Future<Map<String, dynamic>> unlockProperty(String propertyId) async {
    return _call(name: 'unlock', payload: {'property_id': propertyId});
  }

  // ── ESCROW ───────────────────────────────────
  static Future<Map<String, dynamic>> createEscrow(String propertyId) async {
    return _call(name: 'escrow', payload: {'property_id': propertyId});
  }

  // ── WALLET ───────────────────────────────────
  static Future<Map<String, dynamic>> getWalletBalance() async {
    final res = await _call(name: 'wallet', action: 'balance');
    return res['data'] as Map<String, dynamic>;
  }

  // ── SECONDARY SUPABASE CLIENT FOR CHAT & AI ──
  static final _aiClient = SupabaseClient(
    'https://ayvescksetiuekoyfqar.supabase.co',
    'sb_publishable_Bc_CXsA3BiuP36E4KxgkYQ_QmvyV7HT',
  );

  static Map<String, String> _aiHeaders() {
    final Map<String, String> headers = {};
    try {
      final session = _client.auth.currentSession;
      if (session != null) {
        headers['x-primary-jwt'] = session.accessToken;
      }
    } catch (_) {}
    return headers;
  }

  // ── CHAT (Powered by High-Performance Necxa-Chat Orchestrator) ────────
  static Future<Map<String, dynamic>> getConversations() async {
    final res = await _aiClient.functions.invoke(
      'necxa-chat',
      headers: _aiHeaders(),
      body: {'action': 'FETCH_ROOMS'},
    );
    final data = res.data as Map<String, dynamic>;
    if (data['error'] != null) throw Exception(data['error']);
    return data; // Returns the full map with 'data' and 'profiles'
  }

  static Future<Map<String, dynamic>> getMessages(String roomId) async {
    final res = await _aiClient.functions.invoke(
      'necxa-chat',
      headers: _aiHeaders(),
      body: {
        'action': 'FETCH_MESSAGES',
        'payload': {'room_id': roomId},
      },
    );
    final data = res.data as Map<String, dynamic>;
    if (data['error'] != null) throw Exception(data['error']);
    return data; // Returns the full map with 'data' and 'profiles'
  }

  static Future<Map<String, dynamic>> sendMessage({
    required String toUserId,
    required String content,
    String? roomId,
    String? messageType,
    String? messageId,
    String? mediaUrl,
    String? voiceData,      // base64 audio bytes (voice notes only — zero Storage egress)
    int? durationSeconds,
  }) async {
    final res = await _aiClient.functions.invoke(
      'necxa-chat',
      headers: _aiHeaders(),
      body: {
        'action': 'SEND_MESSAGE',
        'payload': {
          if (messageId != null) 'id': messageId,
          'to_user_id': toUserId,
          'content': content,
          'room_id': roomId,
          'message_type': messageType ?? 'text',
          'media_url': mediaUrl,
          if (voiceData != null) 'voice_data': voiceData,
          if (durationSeconds != null) 'duration_seconds': durationSeconds,
        },
      },
    );
    final data = res.data as Map<String, dynamic>;
    if (data['error'] != null) throw Exception(data['error']);
    return data;
  }


  // ── UTILITY ──────────────────────────────────
  static Future<Map<String, dynamic>> verifyUtility({
    required String country,
    String? propertyId,
    String? umemeMeter,
    String? nwscAccount,
    String? kplcMeter,
    String? tanescoMeter,
    String? landBlock,
    String? landPlot,
  }) async {
    return _call(
      name: 'utility',
      payload: {
        'country': country,
        if (propertyId != null) 'property_id': propertyId,
        if (umemeMeter != null) 'umeme_meter': umemeMeter,
        if (nwscAccount != null) 'nwsc_account': nwscAccount,
        if (kplcMeter != null) 'kplc_meter': kplcMeter,
        if (tanescoMeter != null) 'tanesco_meter': tanescoMeter,
        if (landBlock != null) 'land_block': landBlock,
        if (landPlot != null) 'land_plot': landPlot,
      },
    );
  }

  // ── DISCOVERY (POSTGIS & ZONING) ─────────────
  
  static Future<List<dynamic>> searchByRadius({
    required double lat,
    required double lng,
    required double radiusMetres,
  }) async {
    final res = await _client.rpc('listings_within_radius', params: {
      'lat': lat,
      'lng': lng,
      'radius': radiusMetres,
    });
    return res as List<dynamic>;
  }

  static Future<List<dynamic>> getMapListings() async {
    final res = await _client.from('v_map_listings').select();
    return res as List<dynamic>;
  }

  static Future<Map<String, dynamic>?> classifyDistrict(String district) async {
    final res = await _client.rpc('classify_zone_by_district', params: {
      'p_district': district,
    });
    if (res == null || res is! List || res.isEmpty) return null;
    return res.first as Map<String, dynamic>;
  }

  // ── NOTIFICATIONS ─────────────────────────────
  static Future<List<dynamic>> getNotifications() async {
    final res = await _call(name: 'notifications', action: 'list');
    return res['data'] as List<dynamic>;
  }
}
