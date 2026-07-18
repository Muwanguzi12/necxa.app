import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:mongo_dart/mongo_dart.dart' as mongo;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_state.dart';

/// Necxa Live Studio: Core Streaming Engine
/// Handles video/audio via LiveKit and real-time metadata via MongoDB.
class LiveStreamingService {
  final AppState state;
  Room? _room;
  String? _activeChannelName;
  bool _hostingActiveChannel = false;

  static const String liveKitUrl = 'wss://necxa-live-dtb2j623.livekit.cloud';

  mongo.Db? _db;
  static const String mongoUri =
      'mongodb+srv://knestars_db_user:2x54uLtyObmQ9TKm@necxa-cluster.7dgpjye.mongodb.net/necxalive?appName=necxa-Cluster';

  LiveStreamingService(this.state);

  Room? get room => _room;

  Future<void> init() async {
    await [Permission.camera, Permission.microphone].request();

    try {
      _db = await mongo.Db.create(mongoUri);
      await _db!.open();
      debugPrint('Necxa Live: MongoDB Connected');
    } catch (e) {
      debugPrint('Necxa Live: MongoDB Connection Failed: $e');
    }
  }

  Future<Map<String, String>> _fetchCredentials({
    required String action,
    required String channelName,
    String? role,
  }) async {
    final response = await Supabase.instance.client.functions.invoke('live-studio-engine', body: {
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

    if (response.status != 200) {
      throw _functionError(response.data, fallback: 'Live authentication failed');
    }

    final data = Map<String, dynamic>.from(response.data ?? {});
    final token = (data['token'] ?? '').toString();
    final url = (data['url'] ?? liveKitUrl).toString();
    if (token.isEmpty) {
      throw 'Live token was not returned by the server.';
    }
    return {'token': token, 'url': url};
  }

  Future<void> _connect({
    required String channelName,
    required String url,
    required String token,
    required bool publish,
  }) async {
    await _room?.disconnect();
    _room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        defaultCameraCaptureOptions: CameraCaptureOptions(
          maxFrameRate: 30,
        ),
      ),
    );

    await _room!.connect(url, token);
    if (publish) {
      await _room!.localParticipant?.setCameraEnabled(true);
      await _room!.localParticipant?.setMicrophoneEnabled(true);
    }
    _activeChannelName = channelName;
  }

  Future<void> startStreaming(String channelName) async {
    final creds = await _fetchCredentials(action: 'start', channelName: channelName);
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
      final response = await Supabase.instance.client.functions.invoke('live-studio-engine', body: {
        'action': 'list_active',
      });
      if (response.status == 200) {
        return List<Map<String, dynamic>>.from(response.data);
      }
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
      await Supabase.instance.client.functions.invoke('live-studio-engine', body: {
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

  Future<void> pinProduct(String channelId, Map<String, dynamic> product) async {
    if (_db == null) return;
    final coll = _db!.collection('stream_metadata');
    await coll.update(
      mongo.where.eq('channelId', channelId),
      mongo.modify.set('pinnedProduct', product),
      upsert: true,
    );
  }

  Future<void> sendCoHostRequest(String channelId, String userId, Map<String, dynamic> metadata) async {
    if (_db == null) throw 'Live event service is unavailable. Please try again.';
    final coll = _db!.collection('stream_events');
    await coll.insert({
      'channelId': channelId,
      'userId': userId,
      'type': 'cohost_request',
      'data': metadata,
      'timestamp': DateTime.now().toIso8601String(),
    });
    debugPrint('Necxa Live: Co-Host Request Sent to MongoDB');
  }

  Future<void> sendCoHostDecision(String channelId, String guestId, bool accepted) async {
    if (_db == null) throw 'Live event service is unavailable. Please try again.';
    final coll = _db!.collection('stream_events');
    await coll.insert({
      'channelId': channelId,
      'userId': guestId,
      'type': 'cohost_decision',
      'data': {'accepted': accepted},
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<void> sendLiveComment(String channelName, String userName, String text) async {
    if (_db == null) return;
    try {
      final coll = _db!.collection('stream_chat');
      await coll.insert({
        'channelName': channelName,
        'userName': userName,
        'text': text,
        'timestamp': DateTime.now().toIso8601String(),
      });
      debugPrint('Necxa Live: Comment Pushed to MongoDB');
    } catch (e) {
      debugPrint('Necxa Live: Failed to push comment: $e');
    }
  }

  Future<List<Map<String, dynamic>>> fetchLiveComments(String channelName) async {
    if (_db == null) return [];
    try {
      final coll = _db!.collection('stream_chat');
      final results = await coll
          .find(mongo.where.eq('channelName', channelName).sortBy('timestamp', descending: true).limit(20))
          .toList();
      return results.map((c) => {
        'user': c['userName'] ?? 'User',
        'text': c['text'] ?? '',
      }).toList();
    } catch (e) {
      debugPrint('Necxa Live: Failed to fetch comments: $e');
      return [];
    }
  }

  Stream<Map<String, dynamic>> listenToEvents(String channelId) {
    if (_db == null) return const Stream.empty();
    final coll = _db!.collection('stream_events');
    return Stream.periodic(const Duration(seconds: 1)).asyncMap((_) async {
      final lastEvent = await coll.findOne(
        mongo.where.eq('channelId', channelId).sortBy('timestamp', descending: true),
      );
      return lastEvent ?? {};
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
    await _db?.close();
  }
}
