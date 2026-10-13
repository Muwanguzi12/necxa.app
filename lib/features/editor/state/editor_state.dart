import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_io/io.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../../models/edit_models.dart';
import '../../../services/timeline_playback_controller.dart';

/// Loading states for media assets
enum MediaLoadingState {
  idle,
  loading,
  ready,
  error,
}

/// Editor state class containing all editor-related state
@immutable
class EditorState {
  final List<TimelineTrack> tracks;
  final TimelinePlaybackState playbackState;
  final String? selectedTrackId;
  final int? selectedTrackIndex;
  final TimelineClip? selectedClip;
  final Set<String> selectedClipIds;
  final bool isMultiSelectMode;
  
  // Timeline state
  final double timelineZoom;
  final double playheadPosition;
  final bool isRippleMode;
  final bool isStretchMode;
  final bool isSnappingEnabled;
  
  // Canvas state
  final double canvasScale;
  final double canvasRotation;
  final Offset canvasOffset;
  
  // UI state
  final int activeToolPanel;
  final bool showFullscreenPreview;
  final String selectedAspectRatio;
  final String selectedResolution;
  final String selectedFps;
  
  // Media loading state
  final Map<String, MediaLoadingState> mediaLoadingStates;
  final Map<String, String> mediaErrorMessages;
  
  // Audio state
  final double audioVolume;
  final bool isPreviewingMusic;
  final File? voiceOverFile;
  final bool isRecordingVoice;
  
  // Effects state
  final String? selectedEffectId;
  final String? selectedTransitionId;
  
  const EditorState({
    this.tracks = const [],
    this.playbackState = const TimelinePlaybackState(),
    this.selectedTrackId,
    this.selectedTrackIndex,
    this.selectedClip,
    this.selectedClipIds = const {},
    this.isMultiSelectMode = false,
    this.timelineZoom = 1.0,
    this.playheadPosition = 0.0,
    this.isRippleMode = false,
    this.isStretchMode = false,
    this.isSnappingEnabled = true,
    this.canvasScale = 1.0,
    this.canvasRotation = 0.0,
    this.canvasOffset = Offset.zero,
    this.activeToolPanel = 0,
    this.showFullscreenPreview = false,
    this.selectedAspectRatio = '9:16',
    this.selectedResolution = '1080p',
    this.selectedFps = '30fps',
    this.mediaLoadingStates = const {},
    this.mediaErrorMessages = const {},
    this.audioVolume = 0.8,
    this.isPreviewingMusic = false,
    this.voiceOverFile,
    this.isRecordingVoice = false,
    this.selectedEffectId,
    this.selectedTransitionId,
  });

  EditorState copyWith({
    List<TimelineTrack>? tracks,
    TimelinePlaybackState? playbackState,
    String? selectedTrackId,
    int? selectedTrackIndex,
    TimelineClip? selectedClip,
    Set<String>? selectedClipIds,
    bool? isMultiSelectMode,
    double? timelineZoom,
    double? playheadPosition,
    bool? isRippleMode,
    bool? isStretchMode,
    bool? isSnappingEnabled,
    double? canvasScale,
    double? canvasRotation,
    Offset? canvasOffset,
    int? activeToolPanel,
    bool? showFullscreenPreview,
    String? selectedAspectRatio,
    String? selectedResolution,
    String? selectedFps,
    Map<String, MediaLoadingState>? mediaLoadingStates,
    Map<String, String>? mediaErrorMessages,
    double? audioVolume,
    bool? isPreviewingMusic,
    File? voiceOverFile,
    bool? isRecordingVoice,
    String? selectedEffectId,
    String? selectedTransitionId,
  }) {
    return EditorState(
      tracks: tracks ?? this.tracks,
      playbackState: playbackState ?? this.playbackState,
      selectedTrackId: selectedTrackId ?? this.selectedTrackId,
      selectedTrackIndex: selectedTrackIndex ?? this.selectedTrackIndex,
      selectedClip: selectedClip ?? this.selectedClip,
      selectedClipIds: selectedClipIds ?? this.selectedClipIds,
      isMultiSelectMode: isMultiSelectMode ?? this.isMultiSelectMode,
      timelineZoom: timelineZoom ?? this.timelineZoom,
      playheadPosition: playheadPosition ?? this.playheadPosition,
      isRippleMode: isRippleMode ?? this.isRippleMode,
      isStretchMode: isStretchMode ?? this.isStretchMode,
      isSnappingEnabled: isSnappingEnabled ?? this.isSnappingEnabled,
      canvasScale: canvasScale ?? this.canvasScale,
      canvasRotation: canvasRotation ?? this.canvasRotation,
      canvasOffset: canvasOffset ?? this.canvasOffset,
      activeToolPanel: activeToolPanel ?? this.activeToolPanel,
      showFullscreenPreview: showFullscreenPreview ?? this.showFullscreenPreview,
      selectedAspectRatio: selectedAspectRatio ?? this.selectedAspectRatio,
      selectedResolution: selectedResolution ?? this.selectedResolution,
      selectedFps: selectedFps ?? this.selectedFps,
      mediaLoadingStates: mediaLoadingStates ?? this.mediaLoadingStates,
      mediaErrorMessages: mediaErrorMessages ?? this.mediaErrorMessages,
      audioVolume: audioVolume ?? this.audioVolume,
      isPreviewingMusic: isPreviewingMusic ?? this.isPreviewingMusic,
      voiceOverFile: voiceOverFile ?? this.voiceOverFile,
      isRecordingVoice: isRecordingVoice ?? this.isRecordingVoice,
      selectedEffectId: selectedEffectId ?? this.selectedEffectId,
      selectedTransitionId: selectedTransitionId ?? this.selectedTransitionId,
    );
  }
}

/// Video loading state with controller reference
@immutable
class VideoLoadingState {
  final MediaLoadingState status;
  final VideoPlayerController? controller;
  final String? errorMessage;
  final Duration? discoveredDuration;
  final int loadGeneration;

  const VideoLoadingState({
    this.status = MediaLoadingState.idle,
    this.controller,
    this.errorMessage,
    this.discoveredDuration,
    this.loadGeneration = 0,
  });

  VideoLoadingState copyWith({
    MediaLoadingState? status,
    VideoPlayerController? controller,
    String? errorMessage,
    Duration? discoveredDuration,
    int? loadGeneration,
  }) {
    return VideoLoadingState(
      status: status ?? this.status,
      controller: controller ?? this.controller,
      errorMessage: errorMessage ?? this.errorMessage,
      discoveredDuration: discoveredDuration ?? this.discoveredDuration,
      loadGeneration: loadGeneration ?? this.loadGeneration,
    );
  }
}

/// Audio loading state with player reference
@immutable
class AudioLoadingState {
  final MediaLoadingState status;
  final AudioPlayer? player;
  final String? errorMessage;
  final double volume;

  const AudioLoadingState({
    this.status = MediaLoadingState.idle,
    this.player,
    this.errorMessage,
    this.volume = 1.0,
  });

  AudioLoadingState copyWith({
    MediaLoadingState? status,
    AudioPlayer? player,
    String? errorMessage,
    double? volume,
  }) {
    return AudioLoadingState(
      status: status ?? this.status,
      player: player ?? this.player,
      errorMessage: errorMessage ?? this.errorMessage,
      volume: volume ?? this.volume,
    );
  }
}
