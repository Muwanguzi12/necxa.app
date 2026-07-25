import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import '../app_state.dart';

/// Necxa Live Studio: Core Streaming Engine
/// Handles video/audio via LiveKit and real-time metadata via MongoDB.
class LiveStreamingService {
  final AppState state;
  Room? _room;
  String? _activeChannelName;
  bool _hostingActiveChannel = false;

  static const Duration _permissionTimeout = Duration(seconds: 15);
  static const Duration _backendTimeout = Duration(seconds: 20);
  static const Duration _roomTimeout = Duration(seconds: 25);
  static const Duration _trackTimeout = Duration(seconds: 12);

  static const String liveKitUrl = 'wss://necxa-live-dtb2j623.livekit.cloud';
  static const String liveBackendUrl = String.fromEnvironment(
    'NECXA_LIVE_SUPABASE_URL',
    defaultValue: 'https://ayvescksetiuekoyfqar.supabase.co',
  );
  static const String liveBackendPublishableKey = String.fromEnvironment(
    'NECXA_LIVE_SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_Bc_CXsA3BiuP36E4KxgkYQ_QmvyV7HT',
  );

  LiveStreamingService(this.state);

  Room? get room => _room;

  Future<void> init() async {}

  Future<void> _ensurePublishingPermissions() async {
    final statuses = await [Permission.camera, Permission.microphone]
        .request()
        .timeout(
          _permissionTimeout,
          onTimeout: () => throw TimeoutException(
            'Camera and microphone permission request timed out.',
          ),
        );
    final cameraGranted = statuses[Permission.camera]?.isGranted ?? false;
    final microphoneGranted =
        statuses[Permission.microphone]?.isGranted ?? false;
    if (!cameraGranted || !microphoneGranted) {
      throw 'Camera and microphone permissions are required to go live.';
    }
  }

  Future<Map<String, String>> _fetchCredentials({
    required String action,
    required String channelName,
    String? role,
  }) async {
    final response = await _invokeLiveBackend({
      'action': action,
      'channelId': channelName,
      'userId': state.user?.id,
      if (role != null) 'role': role,
      if (action == 'start')
        'metadata': {
          'hostName': state.myProfile?['full_name'] ?? 'Necxa Creator',
          'avatar': state.myProfile?['avatar_url'] ?? '',
          'title': 'Live Studio Session',
        },
      if (action == 'start')
        'location': {
          'lat': state.currentGps?.latitude ?? 0.0,
          'lng': state.currentGps?.longitude ?? 0.0,
        },
    });

    final data = Map<String, dynamic>.from(response as Map? ?? const {});
    final token = (data['token'] ?? '').toString();
    final url = (data['url'] ?? liveKitUrl).toString();
    if (token.isEmpty) {
      throw 'Live token was not returned by the server.';
    }
    return {'token': token, 'url': url};
  }

  Future<dynamic> _invokeLiveBackend(Map<String, dynamic> body) async {
    final response = await http
        .post(
          Uri.parse('$liveBackendUrl/functions/v1/live-studio-engine'),
          headers: {
            'apikey': liveBackendPublishableKey,
            'Authorization': 'Bearer $liveBackendPublishableKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(
          _backendTimeout,
          onTimeout: () => throw TimeoutException(
            'The live authentication server did not respond.',
          ),
        );

    dynamic data;
    try {
      data = response.body.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on FormatException {
      throw 'The live server returned an unreadable response.';
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _functionError(data, fallback: 'Live authentication failed');
    }
    return data;
  }

  Future<void> _connect({
    required String channelName,
    required String url,
    required String token,
    required bool publish,
  }) async {
    final previousRoom = _room;
    if (previousRoom != null) {
      try {
        await previousRoom.disconnect().timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('Necxa Live: Previous room cleanup failed: $e');
      }
    }

    final nextRoom = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: CameraCaptureOptions(maxFrameRate: 30),
      ),
    );
    _room = nextRoom;

    try {
      await nextRoom
          .connect(url, token)
          .timeout(
            _roomTimeout,
            onTimeout: () =>
                throw TimeoutException('The live video room did not connect.'),
          );
      if (publish) {
        await nextRoom.localParticipant
            ?.setCameraEnabled(true)
            .timeout(
              _trackTimeout,
              onTimeout: () =>
                  throw TimeoutException('The camera did not start.'),
            );
        await nextRoom.localParticipant
            ?.setMicrophoneEnabled(true)
            .timeout(
              _trackTimeout,
              onTimeout: () =>
                  throw TimeoutException('The microphone did not start.'),
            );
      }
      _activeChannelName = channelName;
    } catch (_) {
      try {
        await nextRoom.disconnect().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Preserve the original startup error.
      }
      if (identical(_room, nextRoom)) _room = null;
      rethrow;
    }
  }

  Future<void> startStreaming(String channelName) async {
    // Check permissions before the backend creates an active stream record.
    await _ensurePublishingPermissions();
    final creds = await _fetchCredentials(
      action: 'start',
      channelName: channelName,
    );
    await _connect(
      channelName: channelName,
      url: creds['url']!,
      token: creds['token']!,
      publish: true,
    );
    _hostingActiveChannel = true;
  }

  Future<List<Map<String, dynamic>>> getActiveStreams() async {
    try {
      final response = await _invokeLiveBackend({'action': 'list_active'});
      if (response is List) return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('Necxa Live: Failed to list active streams: $e');
    }
    return [];
  }

  Future<void> joinAsViewer(String channelName) async {
    final creds = await _fetchCredentials(
      action: 'join',
      channelName: channelName,
      role: 'audience',
    );
    await _connect(
      channelName: channelName,
      url: creds['url']!,
      token: creds['token']!,
      publish: false,
    );
    _hostingActiveChannel = false;
  }

  Future<void> leaveChannel() async {
    final channelName = _activeChannelName;
    final shouldStop = _hostingActiveChannel && channelName != null;
    if (shouldStop) {
      await stopStreaming(channelName);
    }
    await _room?.disconnect();
    _room = null;
    _activeChannelName = null;
    _hostingActiveChannel = false;
  }

  Future<void> stopStreaming(String channelName) async {
    try {
      await _invokeLiveBackend({
        'action': 'stop',
        'channelId': channelName,
        'userId': state.user?.id,
      });
    } catch (e) {
      debugPrint('Necxa Live: Stop sync failed: $e');
    }
  }

  Future<void> switchRoleToBroadcaster() async {
    final channelName = _activeChannelName;
    if (channelName == null) throw 'No active live channel.';

    await _ensurePublishingPermissions();
    final creds = await _fetchCredentials(
      action: 'join',
      channelName: channelName,
      role: 'publisher',
    );
    await _connect(
      channelName: channelName,
      url: creds['url']!,
      token: creds['token']!,
      publish: true,
    );
  }

  Future<void> switchRoleToAudience() async {
    await _room?.localParticipant?.setCameraEnabled(false);
    await _room?.localParticipant?.setMicrophoneEnabled(false);
  }

  Future<void> setAVEnabled(bool enabled) async {
    await _room?.localParticipant?.setCameraEnabled(enabled);
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
  }

  Future<void> pinProduct(
    String channelId,
    Map<String, dynamic> product,
  ) async {
    await _invokeLiveBackend({
      'action': 'pin_product',
      'channelId': channelId,
      'userId': state.user?.id,
      'product': product,
    });
  }

  Future<Map<String, dynamic>?> fetchPinnedProduct(String channelId) async {
    final response = await _invokeLiveBackend({
      'action': 'fetch_stream_state',
      'channelId': channelId,
    });
    final data = response is Map ? response['data'] : null;
    final product = data is Map ? data['pinnedProduct'] : null;
    return product is Map ? Map<String, dynamic>.from(product) : null;
  }

  Future<void> sendCoHostRequest(
    String channelId,
    String userId,
    Map<String, dynamic> metadata,
  ) async {
    await _invokeLiveBackend({
      'action': 'cohost_request',
      'channelId': channelId,
      'userId': userId,
      'metadata': metadata,
    });
  }

  Future<void> sendCoHostDecision(
    String channelId,
    String guestId,
    bool accepted,
  ) async {
    await _invokeLiveBackend({
      'action': 'cohost_decision',
      'channelId': channelId,
      'userId': state.user?.id,
      'guestId': guestId,
      'metadata': {'accepted': accepted},
    });
  }

  Future<void> sendLiveComment(
    String channelName,
    String userName,
    String text,
  ) async {
    try {
      await _invokeLiveBackend({
        'action': 'send_comment',
        'channelId': channelName,
        'userId': state.user?.id,
        'userName': userName,
        'text': text,
      });
    } catch (e) {
      debugPrint('Necxa Live: Failed to push comment: $e');
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> fetchLiveComments(
    String channelName,
  ) async {
    try {
      final response = await _invokeLiveBackend({
        'action': 'fetch_comments',
        'channelId': channelName,
      });
      final data = response is Map ? response['data'] : null;
      if (data is! List) return [];
      return data
          .whereType<Map>()
          .map(
            (comment) => <String, dynamic>{
              'user': comment['userName'] ?? 'User',
              'text': comment['text'] ?? '',
            },
          )
          .toList();
    } catch (e) {
      debugPrint('Necxa Live: Failed to fetch comments: $e');
      return [];
    }
  }

  Stream<Map<String, dynamic>> listenToEvents(String channelId) {
    return Stream.periodic(const Duration(seconds: 1)).asyncMap((_) async {
      try {
        final response = await _invokeLiveBackend({
          'action': 'poll_event',
          'channelId': channelId,
        });
        final data = response is Map ? response['data'] : null;
        return data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};
      } catch (e) {
        debugPrint('Necxa Live: Failed to poll events: $e');
        return <String, dynamic>{};
      }
    });
  }

  String _functionError(dynamic data, {required String fallback}) {
    if (data is Map && data['error'] != null) return data['error'].toString();
    if (data is String && data.trim().isNotEmpty) return data;
    return fallback;
  }

  Future<void> dispose() async {
    await _room?.disconnect();
    _room = null;
  }
}
