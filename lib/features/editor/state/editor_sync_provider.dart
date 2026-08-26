import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/timeline_playback_controller.dart';
import '../../../models/edit_models.dart';

/// Synchronization state for desktop/mobile view sharing
@immutable
class EditorSyncState {
  final bool isSyncing;
  final String? activeView; // 'mobile' or 'desktop'
  final DateTime lastSyncTime;
  final Map<String, dynamic> sharedData;

  const EditorSyncState({
    this.isSyncing = false,
    this.activeView,
    required this.lastSyncTime,
    this.sharedData = const {},
  });

  EditorSyncState copyWith({
    bool? isSyncing,
    String? activeView,
    DateTime? lastSyncTime,
    Map<String, dynamic>? sharedData,
  }) {
    return EditorSyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      activeView: activeView ?? this.activeView,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      sharedData: sharedData ?? this.sharedData,
    );
  }
}

/// Notifier for managing synchronization between desktop and mobile views
class EditorSyncNotifier extends StateNotifier<EditorSyncState> {
  EditorSyncNotifier() : super(EditorSyncState(
    lastSyncTime: DateTime.now(),
  ));

  /// Sync timeline state from mobile to desktop or vice versa
  void syncTimeline(List<TimelineTrack> tracks, TimelinePlaybackState playbackState) {
    state = state.copyWith(
      isSyncing: true,
      lastSyncTime: DateTime.now(),
      sharedData: {
        'tracks': _serializeTracks(tracks),
        'playbackState': {
          'currentTime': playbackState.currentTime.inMilliseconds,
          'duration': playbackState.duration.inMilliseconds,
          'isPlaying': playbackState.isPlaying,
          'playbackRate': playbackState.playbackRate,
        },
      },
    );

    // Simulate sync completion
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        state = state.copyWith(isSyncing: false);
      }
    });
  }

  /// Sync selected clip state
  void syncSelectedClip(TimelineClip? clip, String? trackId) {
    final currentData = Map<String, dynamic>.from(state.sharedData);
    currentData['selectedClip'] = clip != null ? _serializeClip(clip) : null;
    currentData['selectedTrackId'] = trackId;

    state = state.copyWith(
      isSyncing: true,
      lastSyncTime: DateTime.now(),
      sharedData: currentData,
    );

    Future.delayed(const Duration(milliseconds: 50), () {
      if (mounted) {
        state = state.copyWith(isSyncing: false);
      }
    });
  }

  /// Sync canvas transform state
  void syncCanvasTransform({
    required double scale,
    required double rotation,
    required Offset offset,
  }) {
    final currentData = Map<String, dynamic>.from(state.sharedData);
    currentData['canvasTransform'] = {
      'scale': scale,
      'rotation': rotation,
      'offsetX': offset.dx,
      'offsetY': offset.dy,
    };

    state = state.copyWith(
      lastSyncTime: DateTime.now(),
      sharedData: currentData,
    );
  }

  /// Set the active view (mobile or desktop)
  void setActiveView(String view) {
    state = state.copyWith(
      activeView: view,
      lastSyncTime: DateTime.now(),
    );
  }

  /// Get shared timeline tracks
  List<TimelineTrack>? getSharedTracks() {
    final tracksData = state.sharedData['tracks'];
    if (tracksData == null) return null;
    return _deserializeTracks(tracksData as List);
  }

  /// Get shared playback state
  TimelinePlaybackState? getSharedPlaybackState() {
    final playbackData = state.sharedData['playbackState'];
    if (playbackData == null) return null;

    return TimelinePlaybackState(
      currentTime: Duration(milliseconds: playbackData['currentTime'] as int),
      duration: Duration(milliseconds: playbackData['duration'] as int),
      isPlaying: playbackData['isPlaying'] as bool,
      playbackRate: (playbackData['playbackRate'] as num).toDouble(),
    );
  }

  /// Helper method to serialize tracks for sync
  List<Map<String, dynamic>> _serializeTracks(List<TimelineTrack> tracks) {
    return tracks.map((track) => {
      'id': track.id,
      'type': track.type.name,
      'label': track.label,
      'isLocked': track.isLocked,
      'isVisible': track.isVisible,
      'clips': track.clips.map(_serializeClip).toList(),
    }).toList();
  }

  /// Helper method to deserialize tracks from sync
  List<TimelineTrack> _deserializeTracks(List<dynamic> data) {
    return data.map((trackData) {
      final trackMap = trackData as Map<String, dynamic>;
      return TimelineTrack(
        id: trackMap['id'] as String,
        type: TrackType.values.firstWhere(
          (t) => t.name == trackMap['type'],
          orElse: () => TrackType.video,
        ),
        label: trackMap['label'] as String,
        icon: TrackType.video.defaultIcon, // Simplified
        isLocked: trackMap['isLocked'] as bool,
        isVisible: trackMap['isVisible'] as bool,
        clips: (trackMap['clips'] as List)
            .map((clipData) => _deserializeClip(clipData as Map<String, dynamic>))
            .toList(),
      );
    }).toList();
  }

  /// Helper method to serialize a clip
  Map<String, dynamic> _serializeClip(TimelineClip clip) {
    return {
      'id': clip.id,
      'start': clip.start.inMilliseconds,
      'duration': clip.duration.inMilliseconds,
      'sourceStart': clip.sourceStart.inMilliseconds,
      'sourceEnd': clip.sourceEnd?.inMilliseconds,
      'speed': clip.speed,
      'volume': clip.volume,
      'isHidden': clip.isHidden,
      'transform': {
        'scale': clip.transform.scale,
        'rotation': clip.transform.rotation,
        'offsetX': clip.transform.position.dx,
        'offsetY': clip.transform.position.dy,
        'opacity': clip.transform.opacity,
      },
    };
  }

  /// Helper method to deserialize a clip
  TimelineClip _deserializeClip(Map<String, dynamic> data) {
    return TimelineClip(
      id: data['id'] as String,
      start: Duration(milliseconds: data['start'] as int),
      duration: Duration(milliseconds: data['duration'] as int),
      sourceStart: Duration(milliseconds: data['sourceStart'] as int),
      sourceEnd: data['sourceEnd'] != null 
          ? Duration(milliseconds: data['sourceEnd'] as int)
          : null,
      speed: (data['speed'] as num).toDouble(),
      volume: (data['volume'] as num).toDouble(),
      isHidden: data['isHidden'] as bool,
      operation: TrimOperation( // Simplified - would need full operation deserialization
        start: Duration.zero,
        end: Duration(milliseconds: data['duration'] as int),
        maxDuration: Duration(milliseconds: data['duration'] as int),
      ),
      transform: TransformOperation(
        scale: (data['transform']['scale'] as num).toDouble(),
        rotation: (data['transform']['rotation'] as num).toDouble(),
        position: Offset(
          (data['transform']['offsetX'] as num).toDouble(),
          (data['transform']['offsetY'] as num).toDouble(),
        ),
        opacity: (data['transform']['opacity'] as num).toDouble(),
      ),
    );
  }

  @override
  bool get mounted => true; // Simplified for state notifier
}

/// Provider for editor synchronization
final editorSyncProvider = StateNotifierProvider<EditorSyncNotifier, EditorSyncState>((ref) {
  return EditorSyncNotifier();
});

/// Provider for accessing sync actions
final editorSyncActionsProvider = Provider<EditorSyncNotifier>((ref) {
  return ref.watch(editorSyncProvider.notifier);
});
