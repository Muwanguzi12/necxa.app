import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:universal_io/io.dart';
import '../../../models/edit_models.dart';
import 'background_thumbnail_service.dart';
import 'progressive_video_loader.dart';

/// Lazy loading service for timeline clips
/// Only loads thumbnails and video controllers for visible or near-visible clips
class LazyClipLoader {
  static final LazyClipLoader _instance = LazyClipLoader._internal();
  factory LazyClipLoader() => _instance;
  LazyClipLoader._internal();

  final BackgroundThumbnailService _thumbnailService = BackgroundThumbnailService();
  final ProgressiveVideoLoaderManager _videoLoaderManager = ProgressiveVideoLoaderManager();
  
  final Map<String, _ClipLoadState> _clipStates = {};
  final Set<String> _visibleClipIds = {};
  final Set<String> _preloadClipIds = {};
  
  Timer? _visibilityCheckTimer;
  double _preloadDistanceSeconds = 10.0; // Preload clips 10 seconds before visible
  
  /// Initialize the service
  Future<void> initialize() async {
    await _thumbnailService.initialize();
    
    // Start periodic visibility checks
    _visibilityCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _updateClipVisibility();
    });
    
    debugPrint('LazyClipLoader initialized');
  }

  /// Update visible clip IDs based on timeline viewport
  void updateVisibleClips(List<TimelineClip> visibleClips, Duration playheadPosition) {
    _visibleClipIds.clear();
    
    for (final clip in visibleClips) {
      _visibleClipIds.add(clip.id);
      
      // Also preload clips that will be visible soon
      final clipStart = clip.start.inSeconds.toDouble();
      final playheadSec = playheadPosition.inSeconds.toDouble();
      
      if (clipStart > playheadSec && clipStart - playheadSec <= _preloadDistanceSeconds) {
        _preloadClipIds.add(clip.id);
      }
    }
    
    // Trigger visibility update
    _updateClipVisibility();
  }

  /// Update clip visibility and load/unload accordingly
  void _updateClipVisibility() {
    for (final clipId in _clipStates.keys) {
      final state = _clipStates[clipId]!;
      final isVisible = _visibleClipIds.contains(clipId);
      final shouldPreload = _preloadClipIds.contains(clipId);
      
      if (isVisible || shouldPreload) {
        // Load clip if not already loaded
        if (state.thumbnail == null && state.thumbnailLoading == false) {
          _loadThumbnail(state);
        }
        
        if (isVisible && state.videoController == null && state.videoLoading == false) {
          _loadVideo(state);
        }
      } else {
        // Unload clip if it's been invisible for a while
        if (state.lastVisibleTime != null) {
          final timeSinceVisible = DateTime.now().difference(state.lastVisibleTime!);
          if (timeSinceVisible.inSeconds > 30) {
            _unloadClip(state);
          }
        } else {
          state.lastVisibleTime = DateTime.now();
        }
      }
    }
  }

  /// Load thumbnail for a clip
  Future<void> _loadThumbnail(_ClipLoadState state) async {
    if (state.clip.file == null) return;
    
    state.thumbnailLoading = true;
    
    try {
      final thumbnail = await _thumbnailService.generateThumbnail(
        state.clip.file!,
        time: const Duration(seconds: 1),
        onProgress: (progress) {
          state.thumbnailProgress = progress;
        },
      );
      
      state.thumbnail = thumbnail;
      state.thumbnailLoading = false;
    } catch (e) {
      debugPrint('Error loading thumbnail for ${state.clip.id}: $e');
      state.thumbnailLoading = false;
    }
  }

  /// Load video for a clip
  Future<void> _loadVideo(_ClipLoadState state) async {
    if (state.clip.file == null) return;
    
    state.videoLoading = true;
    
    try {
      final loader = _videoLoaderManager.getLoader(
        state.clip.file!,
        onProgress: (stage, progress) {
          state.videoLoadStage = stage;
          state.videoProgress = progress;
        },
        onError: (error) {
          debugPrint('Video loading error for ${state.clip.id}: $error');
        },
      );
      
      final controller = await loader.load();
      state.videoController = controller;
      state.videoLoader = loader;
      state.videoLoading = false;
    } catch (e) {
      debugPrint('Error loading video for ${state.clip.id}: $e');
      state.videoLoading = false;
    }
  }

  /// Unload a clip's resources
  void _unloadClip(_ClipLoadState state) {
    state.videoLoader?.dispose();
    if (state.clip.file != null) {
      _videoLoaderManager.removeLoader(state.clip.file!);
    }
    state.videoController = null;
    state.videoLoader = null;
    state.thumbnail = null;
    state.lastVisibleTime = null;
    
    debugPrint('Unloaded clip ${state.clip.id}');
  }

  /// Register a clip for lazy loading
  void registerClip(TimelineClip clip) {
    if (!_clipStates.containsKey(clip.id)) {
      _clipStates[clip.id] = _ClipLoadState(clip: clip);
    }
  }

  /// Unregister a clip
  void unregisterClip(String clipId) {
    final state = _clipStates.remove(clipId);
    if (state != null) {
      _unloadClip(state);
    }
  }

  /// Get thumbnail for a clip
  Uint8List? getThumbnail(String clipId) {
    return _clipStates[clipId]?.thumbnail;
  }

  /// Get video controller for a clip
  dynamic getVideoController(String clipId) {
    return _clipStates[clipId]?.videoController;
  }

  /// Get loading state for a clip
  _ClipLoadState? getClipState(String clipId) {
    return _clipStates[clipId];
  }

  /// Preload thumbnails for a list of clips
  Future<void> preloadThumbnails(List<TimelineClip> clips) async {
    final futures = <Future>[];
    
    for (final clip in clips) {
      if (clip.file != null) {
        registerClip(clip);
        futures.add(_thumbnailService.generateThumbnail(clip.file!));
      }
    }
    
    await Future.wait(futures);
  }

  /// Clear all loaded clips
  void clearAll() {
    for (final state in _clipStates.values) {
      _unloadClip(state);
    }
    _clipStates.clear();
    _visibleClipIds.clear();
    _preloadClipIds.clear();
  }

  /// Get statistics
  Map<String, dynamic> getStats() {
    final loadedThumbnails = _clipStates.values.where((s) => s.thumbnail != null).length;
    final loadedVideos = _clipStates.values.where((s) => s.videoController != null).length;
    final loadingThumbnails = _clipStates.values.where((s) => s.thumbnailLoading).length;
    final loadingVideos = _clipStates.values.where((s) => s.videoLoading).length;
    
    return {
      'totalClips': _clipStates.length,
      'visibleClips': _visibleClipIds.length,
      'loadedThumbnails': loadedThumbnails,
      'loadedVideos': loadedVideos,
      'loadingThumbnails': loadingThumbnails,
      'loadingVideos': loadingVideos,
      'thumbnailServiceActiveJobs': _thumbnailService.activeJobCount,
      'thumbnailServiceQueuedJobs': _thumbnailService.queuedJobCount,
    };
  }

  /// Set preload distance
  void setPreloadDistance(double seconds) {
    _preloadDistanceSeconds = seconds;
  }

  /// Dispose resources
  void dispose() {
    _visibilityCheckTimer?.cancel();
    clearAll();
    _videoLoaderManager.clear();
    _thumbnailService.dispose();
  }
}

/// State for a single clip's loading
class _ClipLoadState {
  final TimelineClip clip;
  Uint8List? thumbnail;
  dynamic videoController;
  ProgressiveVideoLoader? videoLoader;
  
  bool thumbnailLoading = false;
  bool videoLoading = false;
  double thumbnailProgress = 0.0;
  double videoProgress = 0.0;
  VideoLoadStage videoLoadStage = VideoLoadStage.analyzing;
  
  DateTime? lastVisibleTime;
  
  _ClipLoadState({required this.clip});
}
