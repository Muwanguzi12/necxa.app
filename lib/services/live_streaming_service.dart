import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_state.dart';

class _LiveBackendException implements Exception {
  final int statusCode;
  final String message;

  const _LiveBackendException(this.statusCode, this.message);

  bool get isPermanent =>
      statusCode >= 400 &&
      statusCode < 500 &&
      statusCode != 408 &&
      statusCode != 429;

  @override
  String toString() => message;
}

@immutable
class LiveSessionCredentials {
  final String token;
  final String url;
  final String streamId;
  final String channelId;

  const LiveSessionCredentials({
    required this.token,
    required this.url,
    required this.streamId,
    required this.channelId,
  });

  factory LiveSessionCredentials.fromBackend(
    Map<String, dynamic> data, {
    required String requestedChannelId,
    required bool requireServerChannel,
  }) {
    final token = (data['token'] ?? '').toString().trim();
    final url = (data['url'] ?? LiveStreamingService.liveKitUrl)
        .toString()
        .trim();
    final streamId = (data['streamId'] ?? '').toString().trim();
    final serverChannelId = (data['channelId'] ?? data['roomName'] ?? '')
        .toString()
        .trim();
    final channelId = serverChannelId.isNotEmpty
        ? serverChannelId
        : (requireServerChannel ? '' : requestedChannelId.trim());

    if (token.isEmpty) {
      throw const FormatException('Live token was not returned by the server.');
    }
    if (channelId.isEmpty) {
      throw const FormatException(
        'The live server did not allocate a session room.',
      );
    }
    return LiveSessionCredentials(
      token: token,
      url: url,
      streamId: streamId,
      channelId: channelId,
    );
  }
}

/// Necxa Live Studio: Core Streaming Engine
/// Handles video/audio via LiveKit and real-time metadata via MongoDB.
class LiveStreamingService {
  final AppState state;
  Room? _room;
  EventsListener<RoomEvent>? _roomEventsListener;
  String? _activeChannelName;
  String? _activeStreamId;
  bool _hostingActiveChannel = false;
  String _currentRole = 'viewer';
  final Set<String> _commentSyncChannels = <String>{};
  final Random _requestRandom = Random.secure();
  final StreamController<Map<String, dynamic>> _controlEvents =
      StreamController<Map<String, dynamic>>.broadcast();

  static const Duration _permissionTimeout = Duration(seconds: 15);
  static const Duration _backendTimeout = Duration(seconds: 20);
  static const Duration _roomTimeout = Duration(seconds: 25);
  static const Duration _trackTimeout = Duration(seconds: 12);
  static const String _controlTopic = 'necxa.live.control.v1';

  static const String liveKitUrl = 'wss://necxa-live-dtb2j623.livekit.cloud';
  static const String liveBackendUrl = String.fromEnvironment(
    'NECXA_LIVE_SUPABASE_URL',
    defaultValue: 'https://lzdtrmjcwzalckszdzpt.supabase.co',
  );
  static const String liveBackendPublishableKey = String.fromEnvironment(
    'NECXA_LIVE_SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_lLcn4V9uIIgs3B59cHVXWg_1-PNsUfR',
  );

  LiveStreamingService(this.state);

  Room? get room => _room;
  String? get activeStreamId => _activeStreamId;
  bool get isCoHostPublishing => _currentRole == 'publisher';

  Map<String, dynamic> _identityMetadata({String fallbackName = 'Viewer'}) {
    return {
      'name': state.myDisplayName ?? fallbackName,
      'username': state.myUsername ?? '',
      'avatar': state.myAvatarUrl ?? '',
    };
  }

  Stream<Map<String, dynamic>> controlEventsForChannel(String channelId) {
    return _controlEvents.stream.where(
      (event) => event['channelId']?.toString() == channelId,
    );
  }

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

  Future<LiveSessionCredentials> _fetchCredentials({
    required String action,
    required String channelName,
    String? role,
  }) async {
    final identity = _identityMetadata(
      fallbackName: action == 'start' ? 'Necxa Creator' : 'Viewer',
    );
    final response = await _invokeLiveBackend({
      'action': action,
      'channelId': channelName,
      if (_activeStreamId != null) 'streamId': _activeStreamId,
      'userId': state.user?.id,
      if (role != null) 'role': role,
      'metadata': {
        ...identity,
        'hostName': identity['name'],
        if (action == 'start') 'title': 'Live Studio Session',
      },
      if (action == 'start')
        'location': {
          'lat': state.currentGps?.latitude ?? 0.0,
          'lng': state.currentGps?.longitude ?? 0.0,
        },
    });

    final data = Map<String, dynamic>.from(response as Map? ?? const {});
    try {
      return LiveSessionCredentials.fromBackend(
        data,
        requestedChannelId: channelName,
        requireServerChannel: action == 'start',
      );
    } on FormatException catch (error) {
      throw error.message;
    }
  }

  Future<dynamic> _invokeLiveBackend(Map<String, dynamic> body) async {
    final accessToken =
        Supabase.instance.client.auth.currentSession?.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw 'Sign in to use live streaming.';
    }

    final response = await http
        .post(
          Uri.parse('$liveBackendUrl/functions/v1/live-studio-engine'),
          headers: {
            'apikey': liveBackendPublishableKey,
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({...body, 'protocolVersion': 2}),
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
      final error = _functionError(
        data,
        fallback: 'Live authentication failed',
      );
      debugPrint('Necxa Live backend error (${response.statusCode}): $error');
      throw _LiveBackendException(
        response.statusCode,
        _publicFunctionError(error),
      );
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
    final previousListener = _roomEventsListener;
    _roomEventsListener = null;
    if (previousListener != null) {
      await previousListener.dispose();
    }
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
      _listenForControlEvents(nextRoom, channelName);
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

  void _listenForControlEvents(Room room, String channelName) {
    final listener = room.createListener();
    _roomEventsListener = listener;
    listener.on<DataReceivedEvent>((received) {
      if (received.topic != _controlTopic) return;
      try {
        final decoded = jsonDecode(utf8.decode(received.data));
        if (decoded is! Map) return;
        final message = Map<String, dynamic>.from(decoded);
        if (message['channelId']?.toString() != channelName) return;
        final rawEvent = message['event'];
        if (rawEvent is! Map) return;
        final event = Map<String, dynamic>.from(rawEvent);
        final senderId = received.participant?.identity;
        final type = event['type']?.toString();
        final eventUserId = event['userId']?.toString();
        final data = Map<String, dynamic>.from(
          event['data'] as Map? ?? const {},
        );
        final hostId = data['hostId']?.toString();
        final validSender = switch (type) {
          'cohost_request' || 'cohost_cancelled' => senderId == eventUserId,
          'cohost_invite' => hostId != null && senderId == hostId,
          'cohost_invite_decision' || 'cohost_left' => senderId == eventUserId,
          'cohost_decision' => hostId != null && senderId == hostId,
          _ => false,
        };
        if (!validSender) return;
        _controlEvents.add({
          ...event,
          'channelId': channelName,
          'transport': 'livekit',
        });
      } catch (error) {
        debugPrint('Necxa Live: Ignored malformed room control data: $error');
      }
    });
  }

  Future<void> _publishControlEvent(
    Map<String, dynamic>? event, {
    String? destinationIdentity,
  }) async {
    if (event == null || event.isEmpty) return;
    final participant = _room?.localParticipant;
    final channelName = _activeChannelName;
    if (participant == null || channelName == null) return;
    try {
      await participant.publishData(
        utf8.encode(jsonEncode({'channelId': channelName, 'event': event})),
        reliable: true,
        destinationIdentities:
            destinationIdentity == null || destinationIdentity.isEmpty
            ? null
            : [destinationIdentity],
        topic: _controlTopic,
      );
    } catch (error) {
      debugPrint(
        'Necxa Live: Immediate control delivery failed; polling will recover: $error',
      );
    }
  }

  Future<void> _invokeLifecycleBackend(
    Map<String, dynamic> body, {
    int attempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        await _invokeLiveBackend(body);
        return;
      } catch (error) {
        lastError = error;
        final permanent = error is _LiveBackendException && error.isPermanent;
        if (permanent || attempt == attempts) break;
        await Future<void>.delayed(
          Duration(milliseconds: attempt == 1 ? 350 : 900),
        );
      }
    }
    throw lastError ?? 'Live lifecycle synchronization failed.';
  }

  Future<void> _confirmJoin(String channelName, {required String role}) async {
    await _invokeLifecycleBackend({
      'action': 'confirm_join',
      'channelId': channelName,
      if (_activeStreamId != null) 'streamId': _activeStreamId,
      'userId': state.user?.id,
      'role': role,
      'metadata': _identityMetadata(),
    });
  }

  Future<void> _disconnectRoom() async {
    final room = _room;
    _room = null;
    final listener = _roomEventsListener;
    _roomEventsListener = null;
    _activeChannelName = null;
    _activeStreamId = null;
    _hostingActiveChannel = false;
    _currentRole = 'viewer';
    if (listener != null) await listener.dispose();
    if (room == null) return;
    try {
      await room.disconnect().timeout(const Duration(seconds: 5));
    } catch (error) {
      debugPrint('Necxa Live: Room disconnect cleanup failed: $error');
    }
  }

  Future<String> startStreaming(String channelName) async {
    await _ensurePublishingPermissions();
    final creds = await _fetchCredentials(
      action: 'start',
      channelName: channelName,
    );
    final canonicalChannelId = creds.channelId;
    _activeStreamId = creds.streamId.isEmpty ? null : creds.streamId;
    try {
      await _connect(
        channelName: canonicalChannelId,
        url: creds.url,
        token: creds.token,
        publish: true,
      );
      await _invokeLifecycleBackend({
        'action': 'confirm_start',
        'channelId': canonicalChannelId,
        'userId': state.user?.id,
        if (creds.streamId.isNotEmpty) 'streamId': creds.streamId,
        'metadata': _identityMetadata(fallbackName: 'Necxa Creator'),
      });
      _hostingActiveChannel = true;
      _currentRole = 'host';
      return canonicalChannelId;
    } catch (error) {
      try {
        await _invokeLifecycleBackend({
          'action': 'abort_start',
          'channelId': canonicalChannelId,
          'userId': state.user?.id,
          if (creds.streamId.isNotEmpty) 'streamId': creds.streamId,
        }, attempts: 2);
      } catch (abortError) {
        debugPrint(
          'Necxa Live: Start rollback will expire automatically: $abortError',
        );
      }
      await _disconnectRoom();
      rethrow;
    }
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
    final canonicalChannelId = creds.channelId;
    _activeStreamId = creds.streamId.isEmpty ? null : creds.streamId;
    try {
      await _connect(
        channelName: canonicalChannelId,
        url: creds.url,
        token: creds.token,
        publish: false,
      );
      await _confirmJoin(canonicalChannelId, role: 'audience');
      _hostingActiveChannel = false;
      _currentRole = 'viewer';
    } catch (_) {
      try {
        await _invokeLifecycleBackend({
          'action': 'leave',
          'channelId': canonicalChannelId,
          if (_activeStreamId != null) 'streamId': _activeStreamId,
          'userId': state.user?.id,
        }, attempts: 2);
      } catch (leaveError) {
        debugPrint(
          'Necxa Live: Failed join presence will expire automatically: '
          '$leaveError',
        );
      }
      await _disconnectRoom();
      rethrow;
    }
  }

  Future<void> leaveChannel() async {
    final channelName = _activeChannelName;
    final shouldStop = _hostingActiveChannel && channelName != null;
    Object? lifecycleError;
    try {
      if (shouldStop) {
        await stopStreaming(channelName);
      } else if (channelName != null) {
        await _invokeLifecycleBackend({
          'action': 'leave',
          'channelId': channelName,
          if (_activeStreamId != null) 'streamId': _activeStreamId,
          'userId': state.user?.id,
        });
      }
    } catch (error) {
      lifecycleError = error;
    } finally {
      await _disconnectRoom();
    }
    if (lifecycleError != null) throw lifecycleError;
  }

  Future<void> stopStreaming(String channelName) async {
    await _invokeLifecycleBackend({
      'action': 'stop',
      'channelId': channelName,
      if (_activeStreamId != null) 'streamId': _activeStreamId,
      'userId': state.user?.id,
    });
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
    final canonicalChannelId = creds.channelId;
    _activeStreamId = creds.streamId.isEmpty ? null : creds.streamId;
    try {
      await _connect(
        channelName: canonicalChannelId,
        url: creds.url,
        token: creds.token,
        publish: true,
      );
      await _confirmJoin(canonicalChannelId, role: 'publisher');
      _currentRole = 'publisher';
    } catch (_) {
      try {
        await _invokeLifecycleBackend({
          'action': 'leave',
          'channelId': canonicalChannelId,
          if (_activeStreamId != null) 'streamId': _activeStreamId,
          'userId': state.user?.id,
        }, attempts: 2);
      } catch (_) {
        // Presence expires automatically if cleanup cannot reach the backend.
      }
      await _disconnectRoom();
      rethrow;
    }
  }

  Future<void> switchRoleToAudience() async {
    await _room?.localParticipant?.setCameraEnabled(false);
    await _room?.localParticipant?.setMicrophoneEnabled(false);
    _currentRole = 'viewer';
  }

  Future<void> setAVEnabled(bool enabled) async {
    await _room?.localParticipant?.setCameraEnabled(enabled);
    await _room?.localParticipant?.setMicrophoneEnabled(enabled);
  }

  Future<Map<String, dynamic>> pinProduct(
    String channelId,
    Map<String, dynamic> product,
  ) async {
    final response = await _invokeLiveBackend({
      'action': 'pin_product',
      'channelId': channelId,
      'userId': state.user?.id,
      'product': {'id': product['id']},
    });
    final data = response is Map ? response['data'] : null;
    final canonicalProduct = data is Map ? data['product'] : null;
    if (canonicalProduct is! Map) {
      throw 'The pinned product could not be verified.';
    }
    return Map<String, dynamic>.from(canonicalProduct);
  }

  Future<void> unpinProduct(String channelId) async {
    await _invokeLiveBackend({
      'action': 'unpin_product',
      'channelId': channelId,
      'userId': state.user?.id,
    });
  }

  Future<Map<String, dynamic>?> fetchPinnedProduct(String channelId) async {
    final state = await fetchLiveState(channelId);
    final product = state['pinnedProduct'];
    return product is Map ? Map<String, dynamic>.from(product) : null;
  }

  Future<Map<String, dynamic>> fetchLiveState(String channelId) async {
    final response = await _invokeLiveBackend({
      'action': 'fetch_stream_state',
      'channelId': channelId,
      if (_activeStreamId != null) 'streamId': _activeStreamId,
    });
    final data = response is Map ? response['data'] : null;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> sendCoHostRequest(
    String channelId,
    String userId,
    Map<String, dynamic> metadata,
  ) async {
    final response = await _invokeLiveBackend({
      'action': 'cohost_request',
      'channelId': channelId,
      'userId': userId,
      'metadata': metadata,
    });
    final data = Map<String, dynamic>.from(
      response is Map && response['data'] is Map
          ? response['data'] as Map
          : const {},
    );
    final request = Map<String, dynamic>.from(
      data['request'] as Map? ?? const {},
    );
    await _publishControlEvent(
      data['event'] is Map
          ? Map<String, dynamic>.from(data['event'] as Map)
          : null,
      destinationIdentity: request['hostId']?.toString(),
    );
    return request;
  }

  Future<Map<String, dynamic>> cancelCoHostRequest(String channelId) async {
    final response = await _invokeLiveBackend({
      'action': 'cohost_cancel',
      'channelId': channelId,
      'userId': state.user?.id,
    });
    final data = Map<String, dynamic>.from(
      response is Map && response['data'] is Map
          ? response['data'] as Map
          : const {},
    );
    final request = Map<String, dynamic>.from(
      data['request'] as Map? ?? const {},
    );
    await _publishControlEvent(
      data['event'] is Map
          ? Map<String, dynamic>.from(data['event'] as Map)
          : null,
      destinationIdentity: request['hostId']?.toString(),
    );
    return request;
  }

  Future<Map<String, dynamic>> sendCoHostDecision(
    String channelId,
    String guestId,
    bool accepted,
  ) async {
    final response = await _invokeLiveBackend({
      'action': 'cohost_decision',
      'channelId': channelId,
      'userId': state.user?.id,
      'guestId': guestId,
      'metadata': {'accepted': accepted},
    });
    final data = Map<String, dynamic>.from(
      response is Map && response['data'] is Map
          ? response['data'] as Map
          : const {},
    );
    await _publishControlEvent(
      data['event'] is Map
          ? Map<String, dynamic>.from(data['event'] as Map)
          : null,
      destinationIdentity: guestId,
    );
    return Map<String, dynamic>.from(data['request'] as Map? ?? const {});
  }

  Future<Map<String, dynamic>> inviteCoHostByUsername(
    String channelId,
    String userName,
  ) async {
    final response = await _invokeLiveBackend({
      'action': 'cohost_invite',
      'channelId': channelId,
      'userId': state.user?.id,
      'userName': userName,
    });
    final data = Map<String, dynamic>.from(
      response is Map && response['data'] is Map
          ? response['data'] as Map
          : const {},
    );
    final request = Map<String, dynamic>.from(
      data['request'] as Map? ?? const {},
    );
    await _publishControlEvent(
      data['event'] is Map
          ? Map<String, dynamic>.from(data['event'] as Map)
          : null,
      destinationIdentity: request['guestId']?.toString(),
    );
    return request;
  }

  Future<Map<String, dynamic>> respondToCoHostInvite(
    String channelId,
    bool accepted,
  ) async {
    final response = await _invokeLiveBackend({
      'action': 'cohost_invite_response',
      'channelId': channelId,
      'userId': state.user?.id,
      'metadata': {'accepted': accepted},
    });
    final data = Map<String, dynamic>.from(
      response is Map && response['data'] is Map
          ? response['data'] as Map
          : const {},
    );
    final request = Map<String, dynamic>.from(
      data['request'] as Map? ?? const {},
    );
    await _publishControlEvent(
      data['event'] is Map
          ? Map<String, dynamic>.from(data['event'] as Map)
          : null,
      destinationIdentity: request['hostId']?.toString(),
    );
    return request;
  }

  Future<Map<String, dynamic>> leaveCoHosting(String channelId) async {
    final response = await _invokeLiveBackend({
      'action': 'cohost_leave',
      'channelId': channelId,
      'userId': state.user?.id,
    });
    final data = Map<String, dynamic>.from(
      response is Map && response['data'] is Map
          ? response['data'] as Map
          : const {},
    );
    final request = Map<String, dynamic>.from(
      data['request'] as Map? ?? const {},
    );
    await _publishControlEvent(
      data['event'] is Map
          ? Map<String, dynamic>.from(data['event'] as Map)
          : null,
      destinationIdentity: request['hostId']?.toString(),
    );
    return request;
  }

  String _newCommentRequestId(String prefix) {
    final userId = state.user?.id ?? 'anonymous';
    return '${prefix}_${userId}_${DateTime.now().microsecondsSinceEpoch}_'
        '${_requestRandom.nextInt(1 << 32)}';
  }

  Future<List<Map<String, dynamic>>> loadCachedLiveComments(
    String channelName,
  ) {
    return state.localDb.getCachedLiveComments(channelName);
  }

  Future<Map<String, dynamic>> sendLiveComment(
    String channelName,
    String userName,
    String text,
  ) async {
    final userId = state.user?.id;
    if (userId == null || userId.isEmpty) {
      throw 'Sign in to comment.';
    }
    final requestId = _newCommentRequestId('live_comment');
    final pending = await state.localDb.savePendingLiveComment(
      id: 'local_$requestId',
      channelId: channelName,
      userId: userId,
      userName: userName,
      userAvatar: state.myAvatarUrl ?? '',
      text: text,
      clientRequestId: requestId,
    );
    unawaited(syncPendingLiveComments(channelName));
    return pending;
  }

  bool _commentRetryDue(Map<String, dynamic> mutation) {
    final lastAttempt = DateTime.tryParse(
      mutation['lastAttemptAt']?.toString() ?? '',
    );
    if (lastAttempt == null) return true;
    final retries = (mutation['retryCount'] as num?)?.toInt() ?? 0;
    final delaySeconds = min(30, 2 << min(retries, 3));
    return DateTime.now().toUtc().difference(lastAttempt).inSeconds >=
        delaySeconds;
  }

  Future<void> syncPendingLiveComments(String channelName) async {
    if (!_commentSyncChannels.add(channelName)) return;
    try {
      final mutations = await state.localDb.getPendingLiveCommentMutations(
        channelName,
      );
      for (final mutation in mutations) {
        if (!_commentRetryDue(mutation)) continue;
        final localId = mutation['id']?.toString() ?? '';
        final pendingAction = mutation['pendingAction']?.toString() ?? 'send';
        try {
          late final dynamic response;
          if (pendingAction == 'edit') {
            response = await _invokeLiveBackend({
              'action': 'edit_comment',
              'channelId': channelName,
              'commentId': localId,
              'text': mutation['text'],
            });
          } else if (pendingAction == 'delete') {
            response = await _invokeLiveBackend({
              'action': 'delete_comment',
              'channelId': channelName,
              'commentId': localId,
            });
          } else {
            response = await _invokeLiveBackend({
              'action': 'send_comment',
              'channelId': channelName,
              'userId': state.user?.id,
              'userName': mutation['userName'] ?? mutation['user'],
              'text': mutation['text'],
              'clientRequestId': mutation['clientRequestId'],
              'metadata': {'avatar': mutation['avatar'] ?? ''},
            });
          }
          final data = response is Map ? response['data'] : null;
          await state.localDb.reconcileLiveCommentMutation(
            localId,
            channelName,
            data is Map ? Map<String, dynamic>.from(data) : null,
          );
        } catch (error) {
          await state.localDb.markLiveCommentMutationAttempt(
            localId,
            error: error.toString(),
            failed: error is _LiveBackendException && error.isPermanent,
          );
        }
      }

      final actions = await state.localDb.getPendingLiveCommentActions(
        channelName,
      );
      for (final queued in actions) {
        if (!_commentRetryDue({
          'lastAttemptAt': queued['last_attempt_at'],
          'retryCount': queued['retry_count'],
        })) {
          continue;
        }
        final actionId = queued['id']?.toString() ?? '';
        final payload = Map<String, dynamic>.from(
          queued['payload'] as Map? ?? const {},
        );
        try {
          await _invokeLiveBackend({
            'action': queued['action_type'],
            'channelId': channelName,
            'commentId': queued['comment_id'],
            ...payload,
          });
          await state.localDb.completeLiveCommentAction(actionId);
        } catch (error) {
          await state.localDb.markLiveCommentActionAttempt(
            actionId,
            error: error.toString(),
            failed: error is _LiveBackendException && error.isPermanent,
          );
        }
      }
    } finally {
      _commentSyncChannels.remove(channelName);
    }
  }

  Future<void> syncAllPendingLiveComments() async {
    final channels = await state.localDb.getPendingLiveCommentChannels();
    for (final channelId in channels) {
      await syncPendingLiveComments(channelId);
    }
  }

  Future<Map<String, dynamic>> fetchLiveCommentPage(
    String channelName, {
    String? before,
    String? after,
    int limit = 50,
  }) async {
    final response = await _invokeLiveBackend({
      'action': 'fetch_comments',
      'channelId': channelName,
      if (before != null) 'before': before,
      if (after != null) 'after': after,
      'limit': limit,
    });
    final data = response is Map ? response['data'] : null;
    if (data is! Map) {
      throw 'Live comments returned an invalid response.';
    }
    final comments = (data['comments'] as List? ?? const [])
        .whereType<Map>()
        .map((comment) => Map<String, dynamic>.from(comment))
        .toList();
    await state.localDb.saveLiveComments(channelName, comments);
    return <String, dynamic>{
      'comments': comments,
      'hasMore': data['hasMore'] == true,
      'nextCursor': data['nextCursor']?.toString(),
      'syncCursor': data['syncCursor']?.toString(),
    };
  }

  Future<List<Map<String, dynamic>>> fetchLiveComments(String channelName) {
    return loadCachedLiveComments(channelName);
  }

  Future<void> editLiveComment(
    String channelName,
    String commentId,
    String text,
  ) async {
    await state.localDb.queueLiveCommentEdit(commentId, text);
    unawaited(syncPendingLiveComments(channelName));
  }

  Future<void> deleteLiveComment(String channelName, String commentId) async {
    await state.localDb.queueLiveCommentDelete(commentId);
    unawaited(syncPendingLiveComments(channelName));
  }

  Future<void> retryLiveComment(String channelName, String commentId) async {
    await state.localDb.resetLiveCommentMutation(commentId);
    unawaited(syncPendingLiveComments(channelName));
  }

  Future<void> reportLiveComment(
    String channelName,
    String commentId, {
    String reason = 'inappropriate',
  }) async {
    await state.localDb.enqueueLiveCommentAction(
      id: _newCommentRequestId('live_report'),
      channelId: channelName,
      commentId: commentId,
      actionType: 'report_comment',
      payload: {'reason': reason},
    );
    unawaited(syncPendingLiveComments(channelName));
  }

  Future<void> moderateLiveComment(
    String channelName,
    String commentId, {
    required String moderationAction,
    String reason = 'host_action',
  }) async {
    await state.localDb.enqueueLiveCommentAction(
      id: _newCommentRequestId('live_moderation'),
      channelId: channelName,
      commentId: commentId,
      actionType: 'moderate_comment',
      payload: {'moderationAction': moderationAction, 'reason': reason},
    );
    unawaited(syncPendingLiveComments(channelName));
  }

  Future<Map<String, dynamic>> sendReaction(
    String channelId,
    String reactionType,
  ) async {
    final response = await _invokeLiveBackend({
      'action': 'send_reaction',
      'channelId': channelId,
      if (_activeStreamId != null) 'streamId': _activeStreamId,
      'userId': state.user?.id,
      'userName': state.myDisplayName ?? 'Viewer',
      'reactionType': reactionType,
      'clientRequestId': _newCommentRequestId('live_reaction'),
      'metadata': {'avatar': state.myAvatarUrl ?? ''},
    });
    final data = response is Map ? response['data'] : null;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> recordShare(String channelId) async {
    final response = await _invokeLiveBackend({
      'action': 'record_share',
      'channelId': channelId,
      'userId': state.user?.id,
    });
    final data = response is Map ? response['data'] : null;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Stream<Map<String, dynamic>> listenToEvents(
    String channelId, {
    String? initialCursor,
  }) async* {
    var cursor = initialCursor;
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        final response = await _invokeLiveBackend({
          'action': 'poll_event',
          'channelId': channelId,
          if (_activeStreamId != null) 'streamId': _activeStreamId,
          'role': _currentRole,
          if (cursor != null) 'eventCursor': cursor,
        });
        final data = response is Map ? response['data'] : null;
        if (data is! Map) {
          yield <String, dynamic>{};
          continue;
        }
        final envelope = Map<String, dynamic>.from(data);
        final events = envelope['events'];
        if (events is List && events.isNotEmpty) {
          for (final rawEvent in events.whereType<Map>()) {
            final event = Map<String, dynamic>.from(rawEvent);
            final eventCursor = event['cursor']?.toString();
            if (eventCursor != null && eventCursor.isNotEmpty) {
              cursor = eventCursor;
            }
            yield <String, dynamic>{
              ...event,
              'pinnedProduct': envelope['pinnedProduct'],
              'summary': envelope['summary'],
              'eventCursor': cursor,
            };
          }
        } else {
          final nextCursor = envelope['eventCursor']?.toString();
          if (nextCursor != null && nextCursor.isNotEmpty) cursor = nextCursor;
          yield envelope;
        }
      } catch (e) {
        debugPrint('Necxa Live: Failed to poll events: $e');
        if (e is _LiveBackendException && e.statusCode == 410) {
          yield <String, dynamic>{
            'streamEnded': true,
            'summary': <String, dynamic>{
              'streamId': _activeStreamId ?? '',
              'viewerCount': 0,
              'likes': 0,
              'shares': 0,
              'reactionCounts': <String, int>{},
              'viewers': <Map<String, dynamic>>[],
            },
          };
          break;
        }
        yield <String, dynamic>{};
      }
    }
  }

  String _functionError(dynamic data, {required String fallback}) {
    if (data is Map && data['error'] != null) return data['error'].toString();
    if (data is String && data.trim().isNotEmpty) return data;
    return fallback;
  }

  String _publicFunctionError(String error) {
    final normalized = error.toLowerCase();
    if (normalized.contains('querysrv') ||
        normalized.contains('enotfound') ||
        normalized.contains('mongodb') ||
        normalized.contains('mongo_uri')) {
      return 'Live product sync is temporarily unavailable. Please try again.';
    }
    return error;
  }

  Future<void> dispose() async {
    await _room?.disconnect();
    _room = null;
  }
}
