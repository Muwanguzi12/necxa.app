import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_io/io.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../../models/edit_models.dart';
import '../../../services/timeline_playback_controller.dart';
import '../../../services/editor_media_service.dart';
import 'editor_state.dart';

/// State notifier for managing editor state with proper async handling
class EditorNotifier extends StateNotifier<EditorState> {
  final EditorProjectController _projectController;
  final EditorMediaService _mediaService;
  
  // Video loading states to prevent race conditions
  final Map<String, VideoLoadingState> _videoStates = {};
  final Map<String, AudioLoadingState> _audioStates = {};
  int _videoLoadGeneration = 0;
  
  // Dispose tracking
  bool _disposed = false;

  EditorNotifier({
    required EditorProjectController projectController,
    required EditorMediaService mediaService,
  })  : _projectController = projectController,
        _mediaService = mediaService,
        super(const EditorState()) {
    _initialize();
  }

  void _initialize() {
    // Initialize with project tracks
    state = state.copyWith(
      tracks: _projectController.tracks,
      playbackState: _projectController.playback.state,
    );
    
    // Listen to playback changes
    _projectController.playback.addListener(_onPlaybackStateChanged);
  }

  void _onPlaybackStateChanged() {
    if (_disposed) return;
    state = state.copyWith(
      playbackState: _projectController.playback.state,
    );
  }

  // ── Track Selection ────────────────────────────────────────────────
  
  void selectTrack(TimelineTrack track, int index) {
    if (_disposed) return;
    state = state.copyWith(
      selectedTrackId: track.id,
      selectedTrackIndex: index,
    );
  }

  void selectClip(TimelineTrack track, TimelineClip clip) {
    if (_disposed) return;
    
    if (state.isMultiSelectMode) {
      final newSelectedIds = Set<String>.from(state.selectedClipIds);
      if (newSelectedIds.contains(clip.id)) {
        newSelectedIds.remove(clip.id);
      } else {
        newSelectedIds.add(clip.id);
      }
      
      state = state.copyWith(
        selectedClipIds: newSelectedIds,
        selectedClip: newSelectedIds.isEmpty ? null : clip,
        isMultiSelectMode: newSelectedIds.isNotEmpty,
      );
    } else {
      state = state.copyWith(
        selectedClipIds: {clip.id},
        selectedClip: clip,
        selectedTrackId: track.id,
        selectedTrackIndex: _projectController.tracks.indexWhere(
          (t) => t.id == track.id,
        ),
      );
    }
  }

  void enterMultiSelectMode(TimelineTrack track, TimelineClip clip) {
    if (_disposed) return;
    state = state.copyWith(
      isMultiSelectMode: true,
      selectedClipIds: {clip.id},
      selectedClip: clip,
      selectedTrackId: track.id,
      selectedTrackIndex: _projectController.tracks.indexWhere(
        (t) => t.id == track.id,
      ),
    );
  }

  void clearSelection() {
    if (_disposed) return;
    state = state.copyWith(
      selectedClip: null,
      selectedClipIds: {},
      isMultiSelectMode: false,
    );
  }

  // ── Timeline Controls ────────────────────────────────────────────────
  
  void setTimelineZoom(double zoom) {
    if (_disposed) return;
    state = state.copyWith(timelineZoom: zoom.clamp(0.5, 3.0));
  }

  void setPlayheadPosition(double position) {
    if (_disposed) return;
    state = state.copyWith(playheadPosition: position);
  }

  void toggleRippleMode() {
    if (_disposed) return;
    state = state.copyWith(isRippleMode: !state.isRippleMode);
  }

  void toggleStretchMode() {
    if (_disposed) return;
    state = state.copyWith(isStretchMode: !state.isStretchMode);
  }

  void toggleSnapping() {
    if (_disposed) return;
    state = state.copyWith(isSnappingEnabled: !state.isSnappingEnabled);
  }

  // ── Canvas Controls ──────────────────────────────────────────────────
  
  void setCanvasScale(double scale) {
    if (_disposed) return;
    state = state.copyWith(canvasScale: scale.clamp(0.1, 5.0));
  }

  void setCanvasRotation(double rotation) {
    if (_disposed) return;
    state = state.copyWith(canvasRotation: rotation);
  }

  void setCanvasOffset(Offset offset) {
    if (_disposed) return;
    state = state.copyWith(canvasOffset: offset);
  }

  // ── UI Controls ──────────────────────────────────────────────────────
  
  void setActiveToolPanel(int panel) {
    if (_disposed) return;
    state = state.copyWith(activeToolPanel: panel.clamp(0, 7));
  }

  void toggleFullscreenPreview() {
    if (_disposed) return;
    state = state.copyWith(showFullscreenPreview: !state.showFullscreenPreview);
  }

  void setAspectRatio(String ratio) {
    if (_disposed) return;
    state = state.copyWith(selectedAspectRatio: ratio);
  }

  void setResolution(String resolution) {
    if (_disposed) return;
    state = state.copyWith(selectedResolution: resolution);
  }

  void setFps(String fps) {
    if (_disposed) return;
    state = state.copyWith(selectedFps: fps);
  }

  // ── Video Loading with Race Condition Prevention ────────────────────
  
  Future<void> loadVideoClip(TimelineClip clip) async {
    if (_disposed || clip.file == null || !clip.file!.existsSync()) return;

    final clipId = clip.id;
    final loadGeneration = ++_videoLoadGeneration;
    
    // Set loading state
    _videoStates[clipId] = VideoLoadingState(
      status: MediaLoadingState.loading,
      loadGeneration: loadGeneration,
    );
    
    final newMediaStates = Map<String, MediaLoadingState>.from(state.mediaLoadingStates);
    newMediaStates[clipId] = MediaLoadingState.loading;
    state = state.copyWith(mediaLoadingStates: newMediaStates);

    try {
      // Dispose previous controller if exists
      final previousState = _videoStates[clipId];
      if (previousState?.controller != null) {
        await previousState!.controller!.pause();
        await previousState.controller!.dispose();
      }

      // Initialize new controller with timeout
      final controller = VideoPlayerController.file(clip.file!);
      await controller.initialize().timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw TimeoutException('Video initialization timeout');
        },
      );

      // Check if this load is still valid (prevents race conditions)
      if (_disposed || loadGeneration != _videoLoadGeneration) {
        await controller.dispose();
        return;
      }

      // Update state with discovered duration
      final discoveredDuration = controller.value.duration;
      _updateClipDuration(clip, discoveredDuration);

      // Store controller and update state
      _videoStates[clipId] = VideoLoadingState(
        status: MediaLoadingState.ready,
        controller: controller,
        discoveredDuration: discoveredDuration,
        loadGeneration: loadGeneration,
      );

      final updatedMediaStates = Map<String, MediaLoadingState>.from(state.mediaLoadingStates);
      updatedMediaStates[clipId] = MediaLoadingState.ready;
      final updatedErrors = Map<String, String>.from(state.mediaErrorMessages);
      updatedErrors.remove(clipId);
      
      state = state.copyWith(
        mediaLoadingStates: updatedMediaStates,
        mediaErrorMessages: updatedErrors,
      );

    } on TimeoutException catch (e) {
      if (_disposed) return;
      
      _videoStates[clipId] = VideoLoadingState(
        status: MediaLoadingState.error,
        errorMessage: 'Large video detected; using fallback preview',
        loadGeneration: loadGeneration,
      );

      final updatedMediaStates = Map<String, MediaLoadingState>.from(state.mediaLoadingStates);
      updatedMediaStates[clipId] = MediaLoadingState.error;
      final updatedErrors = Map<String, String>.from(state.mediaErrorMessages);
      updatedErrors[clipId] = 'Video loading timeout - using fallback';
      
      state = state.copyWith(
        mediaLoadingStates: updatedMediaStates,
        mediaErrorMessages: updatedErrors,
      );
      
      debugPrint('Video loading timeout for ${clip.file?.path}: $e');
      
    } catch (e) {
      if (_disposed) return;
      
      _videoStates[clipId] = VideoLoadingState(
        status: MediaLoadingState.error,
        errorMessage: e.toString(),
        loadGeneration: loadGeneration,
      );

      final updatedMediaStates = Map<String, MediaLoadingState>.from(state.mediaLoadingStates);
      updatedMediaStates[clipId] = MediaLoadingState.error;
      final updatedErrors = Map<String, String>.from(state.mediaErrorMessages);
      updatedErrors[clipId] = e.toString();
      
      state = state.copyWith(
        mediaLoadingStates: updatedMediaStates,
        mediaErrorMessages: updatedErrors,
      );
      
      debugPrint('Video loading error for ${clip.file?.path}: $e');
    }
  }

  void _updateClipDuration(TimelineClip clip, Duration discoveredDuration) {
    final changed = TimelineModelUtils.applyDiscoveredSourceDuration(
      clip,
      discoveredDuration,
    );
    if (changed) {
      TimelineModelUtils.reflowInitialVisualClips(_projectController.tracks);
      _projectController.playback.updateProject(_projectController.tracks);
      state = state.copyWith(tracks: _projectController.tracks);
    }
  }

  VideoPlayerController? getVideoController(String clipId) {
    return _videoStates[clipId]?.controller;
  }

  MediaLoadingState getVideoLoadingState(String clipId) {
    return _videoStates[clipId]?.status ?? MediaLoadingState.idle;
  }

  // ── Audio Loading with Race Condition Prevention ────────────────────
  
  Future<void> loadAudioClip(String audioUrl, String clipId) async {
    if (_disposed) return;

    // Set loading state
    _audioStates[clipId] = AudioLoadingState(
      status: MediaLoadingState.loading,
    );
    
    final newMediaStates = Map<String, MediaLoadingState>.from(state.mediaLoadingStates);
    newMediaStates[clipId] = MediaLoadingState.loading;
    state = state.copyWith(mediaLoadingStates: newMediaStates);

    try {
      // Dispose previous player if exists
      final previousState = _audioStates[clipId];
      if (previousState?.player != null) {
        await previousState!.player!.stop();
        await previousState.player!.dispose();
      }

      // Initialize new player
      final player = AudioPlayer();
      await player.setSourceUrl(audioUrl);

      // Store player and update state
      _audioStates[clipId] = AudioLoadingState(
        status: MediaLoadingState.ready,
        player: player,
      );

      final updatedMediaStates = Map<String, MediaLoadingState>.from(state.mediaLoadingStates);
      updatedMediaStates[clipId] = MediaLoadingState.ready;
      final updatedErrors = Map<String, String>.from(state.mediaErrorMessages);
      updatedErrors.remove(clipId);
      
      state = state.copyWith(
        mediaLoadingStates: updatedMediaStates,
        mediaErrorMessages: updatedErrors,
      );

    } catch (e) {
      if (_disposed) return;
      
      _audioStates[clipId] = AudioLoadingState(
        status: MediaLoadingState.error,
        errorMessage: e.toString(),
      );

      final updatedMediaStates = Map<String, MediaLoadingState>.from(state.mediaLoadingStates);
      updatedMediaStates[clipId] = MediaLoadingState.error;
      final updatedErrors = Map<String, String>.from(state.mediaErrorMessages);
      updatedErrors[clipId] = e.toString();
      
      state = state.copyWith(
        mediaLoadingStates: updatedMediaStates,
        mediaErrorMessages: updatedErrors,
      );
      
      debugPrint('Audio loading error for $audioUrl: $e');
    }
  }

  AudioPlayer? getAudioPlayer(String clipId) {
    return _audioStates[clipId]?.player;
  }

  MediaLoadingState getAudioLoadingState(String clipId) {
    return _audioStates[clipId]?.status ?? MediaLoadingState.idle;
  }

  // ── Audio Controls ───────────────────────────────────────────────────
  
  void setAudioVolume(double volume) {
    if (_disposed) return;
    state = state.copyWith(audioVolume: volume.clamp(0.0, 1.0));
    
    // Update all audio players
    for (final audioState in _audioStates.values) {
      if (audioState.player != null) {
        audioState.player!.setVolume(volume);
      }
    }
  }

  void setVoiceOverFile(File? file) {
    if (_disposed) return;
    state = state.copyWith(voiceOverFile: file);
  }

  void setRecordingVoice(bool isRecording) {
    if (_disposed) return;
    state = state.copyWith(isRecordingVoice: isRecording);
  }

  // ── Effects Controls ────────────────────────────────────────────────
  
  void setSelectedEffect(String? effectId) {
    if (_disposed) return;
    state = state.copyWith(selectedEffectId: effectId);
  }

  void setSelectedTransition(String? transitionId) {
    if (_disposed) return;
    state = state.copyWith(selectedTransitionId: transitionId);
  }

  // ── Track Updates ────────────────────────────────────────────────────
  
  void updateTracks(List<TimelineTrack> newTracks) {
    if (_disposed) return;
    _projectController.replaceTracks(newTracks);
    state = state.copyWith(tracks: newTracks);
  }

  // ── Cleanup ─────────────────────────────────────────────────────────
  
  @override
  void dispose() {
    _disposed = true;
    _projectController.playback.removeListener(_onPlaybackStateChanged);
    
    // Dispose all video controllers
    for (final videoState in _videoStates.values) {
      videoState.controller?.dispose();
    }
    _videoStates.clear();
    
    // Dispose all audio players
    for (final audioState in _audioStates.values) {
      audioState.player?.dispose();
    }
    _audioStates.clear();
    
    super.dispose();
  }
}
