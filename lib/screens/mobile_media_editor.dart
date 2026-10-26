import 'package:universal_io/io.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'dart:typed_data';
import '../theme.dart';
import '../app_state.dart';
import '../models/edit_models.dart';
import '../services/music_library_service.dart';
import '../models/music_models.dart';
import '../services/editor_subscription_service.dart';
import '../services/editor_export_service.dart';
import '../services/editor_media_service.dart';
import 'music_library_screen.dart';
import '../services/editor_voiceover_service.dart';
import '../services/editor_audio_service.dart';
import '../services/timeline_playback_controller.dart';
import '../services/video_enhancement_service.dart';
import '../face_engine/core/face_engine_controller.dart';
import '../face_engine/widgets/face_preset_sheet.dart';
import '../services/timeline_snap_engine.dart';
import '../widgets/timeline_playhead_view.dart';
import '../widgets/timeline_ruler_view.dart';

// Private enum for clip drag modes (top-level so it compiles in class scope)
enum _ClipDragMode { none, move, resizeLeft, resizeRight, stretch }

// ══════════════════════════════════════════════════════════════
// MOBILE MEDIA EDITOR - Responsive adaptation of desktop editor
// ══════════════════════════════════════════════════════════════

class MobileMediaEditor extends StatefulWidget {
  final AppState state;
  final File? initialMedia;
  final MusicTrack? initialTrack;
  final List<File>? multiFiles;
  final bool isFastSync;
  final EditorProjectController? projectController;

  const MobileMediaEditor({
    super.key,
    required this.state,
    this.initialMedia,
    this.initialTrack,
    this.multiFiles,
    this.isFastSync = false,
    this.projectController,
  });

  @override
  State<MobileMediaEditor> createState() => _MobileMediaEditorState();
}

class _MobileMediaEditorState extends State<MobileMediaEditor>
    with TickerProviderStateMixin {
  // ── Selection & State ────────────────────────────────────────
  String? _selectedTrackId;
  int? _selectedTrackIndex;
  TimelineClip? _selectedClip;
  final Set<String> _selectedClipIds = <String>{};
  bool _isMultiSelectMode = false;

  // ── Timeline ─────────────────────────────────────────────────
  late final EditorProjectController _project;
  late final List<TimelineTrack> _tracks;
  late final TimelinePlaybackController _playback;
  late final TimelineHistoryController _history;
  late final bool _ownsProject;
  final EditorMediaService _mediaService = EditorMediaService();
  final VideoEnhancementService _videoEnhancementService =
      VideoEnhancementService();
  final FaceEngineController _faceEngine = FaceEngineController();
  final Set<String> _selectedMediaPaths = <String>{};
  final Set<String> _favoriteMediaPaths = <String>{};
  String _mediaCategory = 'Recent';
  String _mediaQuery = '';
  bool _mediaGridView = true;
  bool _mediaNewestFirst = true;
  double _playheadPosition = 0.0;
  double _timelineZoom = 1.0;
  final double _pixelsPerSecond = 80.0; // Base width per second
  final ScrollController _timelineScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  final ScrollController _sidebarScrollController = ScrollController();

  static final Map<String, Uint8List> _thumbnailCache = {};
  static const int _maxThumbnailFrames = 24;
  static const int _maxThumbnailCacheEntries = 256;

  // Clip interaction state
  String? _activeDragClipId;
  _ClipDragMode _clipDragMode = _ClipDragMode.none;
  double? _dragStartLocalX;
  Duration? _dragOriginalStart;
  Duration? _dragOriginalDuration;
  double _dragCumulativeDx = 0;
  final Map<String, Duration> _dragRippleOriginalStarts = <String, Duration>{};
  double _clipHandleWidth = 12.0; // hit area for handles in pixels
  bool _isRippleMode = false; // when true, edits ripple following clips
  bool _isStretchMode = false; // when true, resize changes speed (stretch)
  bool _isSnappingEnabled = true;
  bool _showSymmetryGuide = false;
  bool _previewOriginal = false;

  // Ghost trim preview — stored at drag-start so we can draw the original
  // clip outline as a ghost while the user is resizing (amber dashed border).
  Duration? _ghostStart;
  Duration? _ghostDuration;
  String? _ghostClipId;
  String? _ghostTrackId;

  // Loop Region & In/Out points
  Duration? _loopIn;
  Duration? _loopOut;
  bool _isLoopingEnabled = false;

  // Timeline pinch/zoom helpers
  double? _timelineScaleStartZoom;
  double _leftPaneWidth =
      56.0; // width of left pane used to compute local focal point

  // Helpers for clip dragging
  void _positionRippleFollowers(TimelineTrack track, Duration totalDelta) {
    for (final c in track.clips) {
      final originalStart = _dragRippleOriginalStarts[c.id];
      if (originalStart != null) {
        c.start = originalStart + totalDelta;
      }
    }
  }

  // Duration clamp helper since Duration doesn't expose clamp()
  Duration _clampDuration(Duration value, Duration min, Duration max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  Duration get _frameDuration {
    final fps = int.tryParse(_selectedFps.replaceAll('fps', '')) ?? 30;
    return Duration(
      microseconds: (Duration.microsecondsPerSecond / fps).round(),
    );
  }

  Duration _snapToFrame(Duration value) {
    final frameUs = _frameDuration.inMicroseconds;
    if (frameUs <= 0) return value;
    return Duration(
      microseconds: (value.inMicroseconds / frameUs).round() * frameUs,
    );
  }

  void _onClipPanStart(
    TimelineTrack track,
    TimelineClip clip,
    DragStartDetails details,
    double width,
  ) {
    if (track.isLocked) {
      _showSnack('Unlock ${track.label} before editing');
      return;
    }
    _activeDragClipId = clip.id;
    _dragStartLocalX = details.localPosition.dx;
    _dragOriginalStart = clip.start;
    _dragOriginalDuration = clip.duration;
    _dragCumulativeDx = 0;
    final originalEnd = clip.start + clip.duration;
    _dragRippleOriginalStarts
      ..clear()
      ..addEntries(
        track.clips
            .where(
              (candidate) =>
                  candidate.id != clip.id && candidate.start >= originalEnd,
            )
            .map((candidate) => MapEntry(candidate.id, candidate.start)),
      );

    if (_dragStartLocalX != null) {
      if (_dragStartLocalX! < _clipHandleWidth) {
        _clipDragMode = _ClipDragMode.resizeLeft;
      } else if (_dragStartLocalX! > width - _clipHandleWidth) {
        _clipDragMode = _isStretchMode
            ? _ClipDragMode.stretch
            : _ClipDragMode.resizeRight;
      } else {
        _clipDragMode = _ClipDragMode.move;
      }
    }

    // Snapshot ghost position for trim outline preview
    _ghostClipId = clip.id;
    _ghostTrackId = track.id;
    _ghostStart = clip.start;
    _ghostDuration = clip.duration;

    // Capture timeline for undo
    _captureTimeline();
  }

  void _onClipPanUpdate(
    TimelineTrack track,
    TimelineClip clip,
    DragUpdateDetails details,
  ) {
    if (_activeDragClipId != clip.id) return;
    final scale = _pixelsPerSecond * _timelineZoom;
    _dragCumulativeDx += details.delta.dx;
    final rawDelta = Duration(
      milliseconds: (_dragCumulativeDx / scale * 1000.0).round(),
    );
    // Step 1: frame-snap the delta (keeps edits on frame boundaries).
    final frameDelta = _isSnappingEnabled ? _snapToFrame(rawDelta) : rawDelta;
    setState(() {
      switch (_clipDragMode) {
        case _ClipDragMode.move:
          final rawStart = (_dragOriginalStart ?? clip.start) + frameDelta;
          final clampedStart =
              rawStart >= Duration.zero ? rawStart : Duration.zero;
          // Step 2: snap the proposed start to nearby clip edges (exclude this
          // clip from snap targets so it doesn't snap to its own old position).
          final otherTracks = _tracks
              .map(
                (t) => TimelineTrack(
                  id: t.id,
                  type: t.type,
                  clips: t.clips.where((c) => c.id != clip.id).toList(),
                  label: t.label,
                  icon: t.icon,
                  isLocked: t.isLocked,
                  isVisible: t.isVisible,
                ),
              )
              .toList();
          clip.start = TimelineSnapEngine.snap(
            clampedStart,
            otherTracks,
            pixelsPerSecond: _pixelsPerSecond,
            zoom: _timelineZoom,
            enabled: _isSnappingEnabled,
          );
          final appliedDelta =
              clip.start - (_dragOriginalStart ?? Duration.zero);
          if (_isRippleMode) {
            _positionRippleFollowers(track, appliedDelta);
          }
          break;
        case _ClipDragMode.resizeLeft:
          final origStart = _dragOriginalStart ?? clip.start;
          final origDur = _dragOriginalDuration ?? clip.duration;
          final newStart = origStart + frameDelta;
          final newDur = origDur - frameDelta;
          if (newDur >= const Duration(milliseconds: 100)) {
            // Advanced trim: update TrimOperation if available to restore/hide source
            if (clip.operation is TrimOperation) {
              final trim = clip.operation as TrimOperation;
              final newSourceStart = _clampDuration(
                trim.start + frameDelta,
                Duration.zero,
                trim.end,
              );
              trim.start = newSourceStart;
              clip.sourceStart = trim.start;
              final available = (trim.end - trim.start);
              clip.duration = Duration(
                milliseconds: (available.inMilliseconds / clip.speed).round(),
              );
            } else {
              clip.start = newStart >= Duration.zero ? newStart : Duration.zero;
              clip.duration = newDur;
            }

            // hide semantics: if duration becomes very small, mark hidden
            clip.isHidden = clip.duration <= const Duration(milliseconds: 150);

            if (_isRippleMode) {
              _positionRippleFollowers(track, frameDelta);
            }
          }
          break;
        case _ClipDragMode.resizeRight:
          final origDur = _dragOriginalDuration ?? clip.duration;
          final newDur = origDur + frameDelta;
          if (newDur >= const Duration(milliseconds: 100)) {
            if (clip.operation is TrimOperation) {
              final trim = clip.operation as TrimOperation;
              final newEnd = _clampDuration(
                trim.end + frameDelta,
                trim.start + const Duration(milliseconds: 1),
                Duration(days: 36500),
              );
              trim.end = newEnd;
              clip.sourceEnd = trim.end;
              final available = (trim.end - trim.start);
              clip.duration = Duration(
                milliseconds: (available.inMilliseconds / clip.speed).round(),
              );
            } else {
              clip.duration = newDur;
            }

            clip.isHidden = clip.duration <= const Duration(milliseconds: 150);

            if (_isRippleMode) {
              _positionRippleFollowers(track, frameDelta);
            }
          }
          break;
        case _ClipDragMode.stretch:
          final origDur = _dragOriginalDuration ?? clip.duration;
          final newDur = origDur + frameDelta;
          if (newDur >= const Duration(milliseconds: 100)) {
            // Stretch changes playback speed to keep source mapping
            final sourceDurMs = clip.sourceDuration.inMilliseconds;
            final newSpeed = newDur.inMilliseconds > 0
                ? (sourceDurMs / newDur.inMilliseconds).clamp(0.1, 10.0)
                : clip.speed;
            clip.duration = newDur;
            clip.speed = newSpeed;
            if (clip.operation is TrimOperation) {
              // keep trim end aligned to source end, adjust operation end accordingly
              final trim = clip.operation as TrimOperation;
              trim.end =
                  trim.start +
                  Duration(milliseconds: (clip.sourceDuration.inMilliseconds));
            }
            clip.isHidden = clip.duration <= const Duration(milliseconds: 150);
            if (_isRippleMode) {
              _positionRippleFollowers(track, frameDelta);
            }
          }
          break;
        case _ClipDragMode.none:
          break;
      }
      _playback.updateProject(_tracks);
    });
  }

  void _onClipPanEnd(DragEndDetails details) {
    final wasMove = _clipDragMode == _ClipDragMode.move;
    final movedClipId = _activeDragClipId;

    _activeDragClipId = null;
    _clipDragMode = _ClipDragMode.none;
    _dragStartLocalX = null;
    _dragOriginalStart = null;
    _dragOriginalDuration = null;
    _dragCumulativeDx = 0;
    _dragRippleOriginalStarts.clear();
    // Clear ghost trim preview
    _ghostClipId = null;
    _ghostTrackId = null;
    _ghostStart = null;
    _ghostDuration = null;

    // Playhead Parking: auto-park playhead at start of moved clip with smooth reposition
    if (wasMove && movedClipId != null) {
      TimelineClip? movedClip;
      for (final t in _tracks) {
        for (final c in t.clips) {
          if (c.id == movedClipId) {
            movedClip = c;
            break;
          }
        }
      }
      if (movedClip != null) {
        _playback.seek(movedClip.start, _tracks);
        setState(() => _currentTime = movedClip!.start);
        _ensureTimelinePosition();
      }
    }
    // finalize history capture already taken at start
  }

  bool _isPlaying = false;
  Duration _currentTime = Duration.zero;
  Duration _totalDuration = Duration(seconds: 30);

  // ── Canvas State ─────────────────────────────────────────────
  double _canvasScale = 1.0;
  double _gestureScale = 1.0;
  double _canvasRotation = 0.0;
  double _gestureRotation = 0.0;
  Offset _canvasOffset = Offset.zero;

  // ── Media Playback ─────────────────────────────────────────
  VideoPlayerController? _videoController;
  bool _isVideoReady = false;
  Timer? _reversePlaybackTimer;

  // ── UI State ─────────────────────────────────────────────────
  int _activeToolPanel =
      0; // 0: Timeline, 1: Media, 2: Audio, 3: Text, 4: Effects
  bool _showFullscreenPreview = false;
  String _selectedAspectRatio = '9:16';
  String _selectedResolution = '1080p';
  String _selectedFps = '30fps';

  // ── Controllers ──────────────────────────────────────────────
  late TabController _bottomNavController;

  // ── Audio State ─────────────────────────────────────────────
  final MusicLibraryService _musicService = MusicLibraryService();
  final EditorVoiceoverService _voiceoverService = EditorVoiceoverService();
  final EditorAudioService _editorAudioService = EditorAudioService();
  final AudioPlayer _audioPreviewPlayer = AudioPlayer();
  final Map<String, AudioPlayer> _timelineAudioPlayers =
      <String, AudioPlayer>{};
  final Map<String, double> _timelineAudioVolumes = <String, double>{};
  final Map<String, double> _timelineAudioRates = <String, double>{};
  String? _activeVisualClipId;
  TimelineClip? _compositionVisualClip;
  bool _isSynchronizingComposition = false;
  bool _compositionSyncPending = false;
  int _playbackCommandGeneration = 0;
  int _videoLoadGeneration = 0;
  DateTime _lastAudioSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastVideoSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastCompositionTime = Duration.zero;
  String? _activeAudioPreviewUrl;
  File? _voiceOverFile;
  bool _isRecordingVoice = false;
  double _audioVolume = 0.8;
  bool _isPreviewingMusic = false;
  bool _isProEnabled = false;
  bool _isExporting = false;
  String _exportStatus = 'Ready';

  // ── Color Grading & Shader State (GPU) ──────────────────────
  ui.FragmentProgram? _shaderProgram;
  double _brightness = 0.0;
  double _contrast = 1.0;
  double _saturation = 1.0;
  double _hue = 0.0;
  double _effectVignette = 0.0;
  double _effectGrain = 0.0;
  double _effectBlur = 0.0;

  // ── Audio Mixer State ─────────────────────────────────────────
  double _originalVideoVolume = 1.0;
  double _bgmVolume = 0.8;
  double _voiceVolume = 0.9;

  // ── Shared Effects State ──────────────────────────────────
  final List<EffectPreset> _effectPresets = EffectPreset.presets;
  String _effectsSearchQuery = '';
  String _effectsFilter = 'All';
  String _effectsSort = 'Featured';
  EffectPreset? _previewEffect;
  bool _showEffectLibrary = false;
  String? _selectedEffectId;
  final List<String> _recentEffectIds = <String>[];
  final List<String> _favoriteEffectIds = <String>[];

  // ── Shared Transition State ───────────────────────────────
  final List<TransitionPreset> _transitionPresets = TransitionPreset.presets;
  String _transitionSearchQuery = '';
  String _transitionFilter = 'All';
  String _transitionSort = 'Featured';
  String? _selectedTransitionId;
  final List<String> _recentTransitionIds = <String>[];
  final List<String> _favoriteTransitionIds = <String>[];
  bool _showTransitionLibrary = false;

  @override
  void initState() {
    super.initState();
    _ownsProject = widget.projectController == null;
    _project = widget.projectController ?? EditorProjectController();
    _tracks = _project.tracks;
    _playback = _project.playback;
    _history = _project.history;
    _bottomNavController = TabController(length: 8, vsync: this);

    _verticalScrollController.addListener(() {
      if (_sidebarScrollController.hasClients &&
          _verticalScrollController.offset != _sidebarScrollController.offset) {
        _sidebarScrollController.jumpTo(_verticalScrollController.offset);
      }
    });
    _sidebarScrollController.addListener(() {
      if (_verticalScrollController.hasClients &&
          _sidebarScrollController.offset != _verticalScrollController.offset) {
        _verticalScrollController.jumpTo(_sidebarScrollController.offset);
      }
    });

    _initializeEditor();
    _playback.addListener(_onPlaybackStateChanged);
    _playback.updateProject(_tracks);
    _loadProState();
    _loadShaders();
    _triggerInitialProxies();
  }

  Future<void> _loadProState() async {
    final isPro = await EditorSubscriptionService.isProEnabled();
    if (!mounted) return;
    setState(() => _isProEnabled = isPro);
  }

  Future<void> _loadShaders() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(
        'assets/shaders/color_grading.frag',
      );
      if (mounted) setState(() => _shaderProgram = program);
    } catch (e) {
      debugPrint("Error loading shaders: $e");
    }
  }

  void _triggerInitialProxies() {
    for (final track in _tracks) {
      if (track.type == TrackType.video) {
        for (final clip in track.clips) {
          if (clip.file != null && !clip.isProxyReady) {
            _generateProxyForClip(clip);
          }
        }
      }
    }
  }

  Future<void> _generateProxyForClip(TimelineClip clip) async {
    if (clip.file == null || clip.isProxyReady) return;
    try {
      final size = await clip.file!.length();
      if (size < 5 * 1024 * 1024) return;
    } catch (_) {}

    try {
      final proxy = await _videoEnhancementService.generateProxy(clip.file!);
      if (proxy.path != clip.file!.path && mounted) {
        setState(() {
          clip.proxyFile = proxy;
          clip.isProxyReady = true;
        });
        if (_compositionVisualClip?.id == clip.id) {
          _loadClip(clip);
        }
      }
    } catch (e) {
      debugPrint("Proxy generation error: $e");
    }
  }

  void _initializeEditor() {
    if (_tracks.isNotEmpty) return;
    final files =
        widget.multiFiles ??
        [if (widget.initialMedia != null) widget.initialMedia!];
    var start = Duration.zero;
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      _mediaService.registerFile(file);
      final lower = file.path.toLowerCase();
      final isVideo = lower.endsWith('.mp4') || lower.endsWith('.mov');
      final sizeBytes = file.existsSync() ? file.lengthSync() : 0;
      final duration = isVideo
          ? (sizeBytes > 2 * 1024 * 1024 * 1024
                ? const Duration(minutes: 60)
                : const Duration(seconds: 12))
          : const Duration(seconds: 4);
      TimelineModelUtils.insertClip(
        _tracks,
        TimelineClip(
          id: 'initial-${index}-${file.path.hashCode}',
          start: start,
          duration: duration,
          file: file,
          operation: TrimOperation(
            start: Duration.zero,
            end: duration,
            maxDuration: duration,
          ),
        ),
        isVideo ? TrackType.video : TrackType.images,
      );
      start += duration;
    }
    if (widget.initialTrack != null) {
      TimelineModelUtils.insertClip(
        _tracks,
        TimelineClip(
          id: 'initial-music-${widget.initialTrack!.id}',
          start: Duration.zero,
          duration: start > Duration.zero
              ? start
              : Duration(seconds: widget.initialTrack!.duration),
          operation: AudioClipOperation(
            sourceType: 'music',
            sourceUrl: widget.initialTrack!.audioUrl,
            label: widget.initialTrack!.title,
          ),
        ),
        TrackType.music,
      );
    }
  }

  void _selectClip(TimelineTrack track, TimelineClip clip) {
    setState(() {
      if (_isMultiSelectMode) {
        if (!_selectedClipIds.add(clip.id)) _selectedClipIds.remove(clip.id);
        if (_selectedClipIds.isEmpty) {
          _isMultiSelectMode = false;
          _selectedClip = null;
        } else {
          _selectedClip = clip;
        }
      } else {
        _selectedClipIds
          ..clear()
          ..add(clip.id);
        _selectedClip = clip;
      }
      _selectedTrackId = track.id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == track.id,
      );
    });
  }

  void _enterMultiSelect(TimelineTrack track, TimelineClip clip) {
    setState(() {
      _isMultiSelectMode = true;
      _selectedClipIds.add(clip.id);
      _selectedClip = clip;
      _selectedTrackId = track.id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == track.id,
      );
    });
  }

  void _applyFallbackLongFormDuration(TimelineClip clip) {
    final fallbackDuration = const Duration(minutes: 60);
    clip.duration = fallbackDuration;
    clip.sourceStart = Duration.zero;
    clip.sourceEnd = fallbackDuration;
    if (clip.operation is TrimOperation) {
      final trim = clip.operation as TrimOperation;
      trim.start = Duration.zero;
      trim.end = fallbackDuration;
    }
    clip.isHidden = false;
    TimelineModelUtils.reflowInitialVisualClips(_tracks);
    _playback.updateProject(_tracks);
  }

  Future<void> _loadClip(TimelineClip clip) async {
    if (clip.file == null || !clip.file!.existsSync()) return;

    final loadGeneration = ++_videoLoadGeneration;
    if (mounted) setState(() => _isVideoReady = false);

    if (_videoController != null) {
      final oldCtrl = _videoController!;
      oldCtrl.removeListener(_syncVideoState);
      await oldCtrl.pause();
      await oldCtrl.dispose();
    }

    final mediaFile = (clip.isProxyReady &&
            clip.proxyFile != null &&
            clip.proxyFile!.existsSync())
        ? clip.proxyFile!
        : clip.file!;
    final controller = VideoPlayerController.file(mediaFile);
    if (!clip.isProxyReady) {
      _generateProxyForClip(clip);
    }
    _videoController = controller;
    try {
      await controller.initialize().timeout(const Duration(seconds: 20));
      if (!mounted ||
          loadGeneration != _videoLoadGeneration ||
          !identical(controller, _videoController)) {
        await controller.dispose();
        return;
      }

      _applyDiscoveredVideoDuration(clip, controller.value.duration);
      await controller.setLooping(false);
      await controller.setVolume(clip.volume);
      await controller.setPlaybackSpeed(clip.speed);
      await _seekVideoToTimeline(
        clip,
        _playback.state.currentTime,
        force: true,
      );
      controller.addListener(_syncVideoState);
      if (mounted) setState(() => _isVideoReady = true);
    } on TimeoutException catch (_) {
      if (loadGeneration == _videoLoadGeneration && mounted) {
        setState(() => _isVideoReady = false);
        _showSnack(
          'Large video detected; preview is using lightweight fallback.',
        );
      }
      debugPrint(
        'Mobile editor video initialization timed out for a large video asset.',
      );
      if (clip.file != null && clip.file!.existsSync()) {
        final sizeBytes = clip.file!.lengthSync();
        if (sizeBytes > 2 * 1024 * 1024 * 1024) {
          _applyFallbackLongFormDuration(clip);
        }
      }
      if (mounted) {
        setState(() {
          _isVideoReady = false;
          _playback.updateProject(_tracks);
        });
      }
    } catch (error) {
      if (loadGeneration == _videoLoadGeneration && mounted) {
        setState(() => _isVideoReady = false);
        _showSnack('Unable to prepare this video for playback');
      }
      debugPrint('Mobile editor video initialization failed: $error');
    }
  }

  void _applyDiscoveredVideoDuration(
    TimelineClip clip,
    Duration discoveredDuration,
  ) {
    final changed = TimelineModelUtils.applyDiscoveredSourceDuration(
      clip,
      discoveredDuration,
    );
    if (!changed) return;

    // Initial media is created before its metadata is available. Keep those
    // clips sequential after replacing their temporary durations.
    TimelineModelUtils.reflowInitialVisualClips(_tracks);
    _playback.updateProject(_tracks);
  }

  @override
  void dispose() {
    _videoController?.removeListener(_syncVideoState);
    _reversePlaybackTimer?.cancel();
    _playback.removeListener(_onPlaybackStateChanged);
    if (_ownsProject) _project.dispose();
    for (final player in _timelineAudioPlayers.values) {
      player.dispose();
    }
    _videoController?.dispose();
    _bottomNavController.dispose();
    _musicService.dispose();
    _audioPreviewPlayer.dispose();
    _voiceoverService.dispose();
    _editorAudioService.dispose();
    _timelineScrollController.dispose();
    _verticalScrollController.dispose();
    _sidebarScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildMobileHeader(screenSize),
                Expanded(
                  child: Column(
                    children: [
                      _buildPreviewCanvas(screenSize),
                      _buildPlaybackControls(screenSize),
                      Expanded(child: _buildEditorPanel(screenSize)),
                    ],
                  ),
                ),
                _buildContextToolbar(screenSize),
                _buildBottomNavigation(screenSize),
              ],
            ),
            if (_showFullscreenPreview) _buildFullscreenPreviewOverlay(),
          ],
        ),
      ),
      // Floating actions replaced by canvas toolbar for contextual tools
    );
  }

  Widget _buildFullscreenPreviewOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () =>
                          setState(() => _showFullscreenPreview = false),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Fullscreen Preview',
                        style: dm(sz: 11, c: Colors.white, w: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white24),
                        color: Colors.black,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: _buildCanvasContent(),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(_currentTime),
                          style: dm(
                            sz: 12,
                            c: Colors.white,
                            w: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _formatDuration(_totalDuration),
                          style: dm(sz: 12, c: Colors.white70),
                        ),
                      ],
                    ),
                    Slider(
                      value: _totalDuration.inMilliseconds > 0
                          ? _currentTime.inMilliseconds /
                                _totalDuration.inMilliseconds
                          : 0.0,
                      onChanged: (value) {
                        if (_totalDuration.inMilliseconds > 0) {
                          final target = Duration(
                            milliseconds:
                                (value * _totalDuration.inMilliseconds).round(),
                          );
                          _playback.seek(target, _tracks);
                        }
                      },
                      activeColor: C.brand,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildFullscreenControl(
                          Icons.skip_previous,
                          () => _previousFrame(),
                        ),
                        const SizedBox(width: 12),
                        _buildFullscreenControl(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          () => _togglePlayback(),
                          isLarge: true,
                        ),
                        const SizedBox(width: 12),
                        _buildFullscreenControl(
                          Icons.skip_next,
                          () => _nextFrame(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenControl(
    IconData icon,
    VoidCallback onTap, {
    bool isLarge = false,
  }) {
    return Container(
      width: isLarge ? 56 : 44,
      height: isLarge ? 56 : 44,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(isLarge ? 28 : 12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(isLarge ? 28 : 12),
          child: Icon(icon, color: Colors.white, size: isLarge ? 28 : 22),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // A. HEADER (8–10% of screen)
  // ═══════════════════════════════════════════════════════════
  Widget _buildMobileHeader(Size screenSize) {
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.maybePop(context),
                icon: const Icon(Icons.arrow_back_ios_new, size: 16),
                tooltip: 'Back',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              const SizedBox(width: 8),
              Text(
                'NECXA',
                style: syne(sz: 15, w: FontWeight.w900, c: C.brand),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Text(
                      'New Project',
                      style: dm(sz: 13, c: C.text, w: FontWeight.w700),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
              _buildProButton(),
              const SizedBox(width: 10),
              _buildExportButton(),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildSettingsChip(
                _selectedAspectRatio,
                () => _showSelectionSheet(
                  'Aspect ratio',
                  ['9:16', '16:9', '1:1', '4:5'],
                  (value) => setState(() => _selectedAspectRatio = value),
                ),
              ),
              const SizedBox(width: 6),
              _buildSettingsChip(
                _selectedResolution,
                () => _showSelectionSheet(
                  'Resolution',
                  ['480p', '720p', '1080p', '4K'],
                  (value) => setState(() => _selectedResolution = value),
                ),
              ),
              const SizedBox(width: 6),
              _buildSettingsChip(
                _selectedFps,
                () => _showSelectionSheet('FPS', [
                  '24fps',
                  '30fps',
                  '60fps',
                ], (value) => setState(() => _selectedFps = value)),
              ),
              const Spacer(),
              _buildIconButton(Icons.undo, () => _undo(), size: 16),
              const SizedBox(width: 8),
              _buildIconButton(Icons.redo, () => _redo(), size: 16),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsChip(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: C.border),
        ),
        child: Text(label, style: dm(sz: 7.5, w: FontWeight.w600)),
      ),
    );
  }

  Widget _buildIconButton(
    IconData icon,
    VoidCallback onTap, {
    double size = 24,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: size, color: C.brand),
        ),
      ),
    );
  }

  Widget _buildProButton() {
    final bg = _isProEnabled ? C.brand : C.surface;
    final fg = _isProEnabled ? Colors.white : C.brand;
    return Container(
      constraints: const BoxConstraints(minWidth: 64, minHeight: 34),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        boxShadow: _isProEnabled
            ? [
                BoxShadow(
                  color: C.brand.withOpacity(0.18),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
        border: Border.all(
          color: _isProEnabled ? Colors.transparent : C.border,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _showProSheet,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star, size: 14, color: fg),
                const SizedBox(width: 6),
                Text(
                  'Pro',
                  style: dm(sz: 11, w: FontWeight.w800, c: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExportButton() {
    final enabled = !_isExporting;
    return Container(
      constraints: const BoxConstraints(minWidth: 84, minHeight: 34),
      decoration: BoxDecoration(
        color: enabled ? C.brand : C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: enabled ? Colors.transparent : C.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? _showExportSheet : null,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  enabled ? Icons.upload : Icons.hourglass_top,
                  size: 14,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  enabled ? 'Export' : 'Working',
                  style: dm(sz: 11, w: FontWeight.w800, c: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // B. PREVIEW CANVAS (30–35% of screen)
  // ═══════════════════════════════════════════════════════════
  Widget _buildPreviewCanvas(Size screenSize) {
    final canvasHeight = screenSize.height * 0.32;
    final aspectRatio = 9 / 16;
    final maxCanvasWidth = canvasHeight * aspectRatio;

    return Container(
      height: canvasHeight,
      color: Colors.black,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onDoubleTap: () => setState(() {
              _canvasScale = _canvasScale == 1.0 ? 1.8 : 1.0;
              _canvasRotation = 0.0;
              _canvasOffset = Offset.zero;
            }),
            onScaleStart: (_) => setState(() {
              _gestureScale = _canvasScale;
              _gestureRotation = _canvasRotation;
            }),
            onScaleUpdate: (details) => setState(() {
              _canvasScale = (_gestureScale * details.scale).clamp(0.85, 3.0);
              _canvasRotation = _gestureRotation + details.rotation;
            }),
            onPanUpdate: (details) {
              if (_canvasScale > 1.0) {
                setState(() {
                  _canvasOffset += details.delta;
                });
              }
            },
            child: Transform.translate(
              offset: _canvasOffset,
              child: Transform.rotate(
                angle: _canvasRotation,
                child: Transform.scale(
                  scale: _canvasScale,
                  child: Container(
                    width: maxCanvasWidth,
                    height: canvasHeight,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: C.dim.withAlpha(51)),
                    ),
                    child: _buildCanvasContent(),
                  ),
                ),
              ),
            ),
          ),

          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: C.brand.withAlpha(26), width: 2),
                ),
              ),
            ),
          ),

          if (_canvasScale > 1.0)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(204),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: C.brand.withAlpha(77)),
                ),
                child: Text(
                  '${(_canvasScale * 100).toStringAsFixed(0)}%',
                  style: dm(sz: 10, c: Colors.white, w: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCanvasContent() {
    final compositionClip = _compositionVisualClip;
    if (compositionClip != null &&
        _tracks.any(
          (track) =>
              track.type == TrackType.images &&
              track.clips.contains(compositionClip),
        ) &&
        compositionClip.file?.existsSync() == true) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _applyClipPresentation(
            compositionClip,
            Image.file(compositionClip.file!, fit: BoxFit.cover),
          ),
          ..._buildEffectOverlayWidgets(),
          ..._buildTimelineOverlayWidgets(),
        ],
      );
    }
    if (compositionClip == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          ..._buildEffectOverlayWidgets(),
          ..._buildTimelineOverlayWidgets(),
        ],
      );
    }
    if (_isVideoReady && _videoController != null) {
      final cropRatio = _cropRatioFor(compositionClip.cropAspectRatio);
      final video = cropRatio == null
          ? AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            )
          : AspectRatio(
              aspectRatio: cropRatio,
              child: ClipRect(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _videoController!.value.size.width,
                    height: _videoController!.value.size.height,
                    child: VideoPlayer(_videoController!),
                  ),
                ),
              ),
            );
      return Stack(
        children: [
          _applyClipPresentation(compositionClip, Center(child: video)),
          ..._buildEffectOverlayWidgets(),
          ..._buildTimelineOverlayWidgets(),
          Positioned(
            bottom: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _isPlaying ? 'Playing' : 'Paused',
                style: dm(sz: 10, c: Colors.white, w: FontWeight.w600),
              ),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.video_camera_back, size: 48, color: C.dim.withAlpha(128)),
          const SizedBox(height: 12),
          Text('Preview', style: dm(sz: 14, c: C.dim.withAlpha(128))),
        ],
      ),
    );
  }

  Widget _applyClipPresentation(TimelineClip clip, Widget child) {
    Widget result = Opacity(
      opacity: clip.transform.opacity.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: clip.transform.position,
        child: Transform.rotate(
          angle: clip.transform.rotation,
          child: Transform.scale(scale: clip.transform.scale, child: child),
        ),
      ),
    );
    final filterMatrix = _filterMatrix(clip.filter?.filterName);
    final beautyMatrix = !_previewOriginal ? _clipBeautyMatrix(clip) : null;
    final combinedMatrix = beautyMatrix != null
        ? (filterMatrix != null
            ? _mergeColorMatrices(filterMatrix, beautyMatrix)
            : beautyMatrix)
        : filterMatrix;

    if (combinedMatrix != null) {
      result = ColorFiltered(
        colorFilter: ColorFilter.matrix(combinedMatrix),
        child: result,
      );
    }

    // Edge-Preserving Skin Smoothing & Porcelain Finish
    if (!_previewOriginal && clip.skinSmoothing > 0.01) {
      final sigma = (clip.skinSmoothing * 2.2).clamp(0.2, 3.5);
      final diffusionAlpha = (clip.skinSmoothing * (clip.smoothingMode == 1 ? 0.42 : 0.32)).clamp(0.0, 0.50);
      result = Stack(
        fit: StackFit.passthrough,
        children: [
          result,
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: diffusionAlpha,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: result,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Bilateral Facial Symmetry
    if (!_previewOriginal && clip.faceSymmetry > 0.01) {
      final mirrorLeft = clip.symmetryMirrorLeft;
      result = LayoutBuilder(
        builder: (context, constraints) {
          final halfWidth = constraints.maxWidth / 2;
          return Stack(
            fit: StackFit.expand,
            children: [
              result,
              Positioned(
                top: 0,
                bottom: 0,
                left: mirrorLeft ? halfWidth : 0,
                right: mirrorLeft ? 0 : halfWidth,
                child: IgnorePointer(
                  child: ClipRect(
                    child: Opacity(
                      opacity: clip.faceSymmetry.clamp(0.0, 1.0),
                      child: Align(
                        alignment: mirrorLeft
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        widthFactor: 0.5,
                        child: Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.diagonal3Values(-1, 1, 1),
                          child: SizedBox(
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                            child: result,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_showSymmetryGuide && clip.faceSymmetry > 0.05)
                Positioned.fill(
                  child: _FacialSymmetryGuideOverlay(
                    intensity: clip.faceSymmetry,
                    mirrorLeft: mirrorLeft,
                  ),
                ),
            ],
          );
        },
      );
    }

    // Studio Makeup Overlay (Women & Men)
    if (!_previewOriginal && clip.makeupGender > 0 && clip.makeupIntensity > 0.05) {
      result = Stack(
        fit: StackFit.passthrough,
        children: [
          result,
          Positioned.fill(
            child: _StudioMakeupOverlay(
              gender: clip.makeupGender,
              style: clip.makeupStyle,
              intensity: clip.makeupIntensity,
            ),
          ),
        ],
      );
    }

    // GPU Color Grading Shader
    if (_shaderProgram != null &&
        (_brightness != 0.0 ||
            _contrast != 1.0 ||
            _saturation != 1.0 ||
            _hue != 0.0)) {
      result = CustomPaint(
        painter: ShaderPainter(
          shader: _shaderProgram!.fragmentShader(),
          brightness: _brightness,
          contrast: _contrast,
          saturation: _saturation,
          hue: _hue,
        ),
        child: result,
      );
    }

    if (_effectBlur > 0) {
      result = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: _effectBlur,
          sigmaY: _effectBlur,
        ),
        child: result,
      );
    }

    if (_effectVignette > 0 || _effectGrain > 0) {
      result = Stack(
        fit: StackFit.passthrough,
        children: [
          result,
          if (_effectVignette > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(
                          (0.72 * _effectVignette).clamp(0.0, 1.0),
                        ),
                      ],
                      stops: const [0.55, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          if (_effectGrain > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: GrainPainter(intensity: _effectGrain),
                ),
              ),
            ),
        ],
      );
    }

    return result;
  }

  List<double>? _filterMatrix(String? filterName) {
    switch (filterName?.toLowerCase()) {
      case 'warm':
        return const <double>[
          1.08,
          0,
          0,
          0,
          8,
          0,
          1.02,
          0,
          0,
          2,
          0,
          0,
          0.9,
          0,
          -4,
          0,
          0,
          0,
          1,
          0,
        ];
      case 'cool':
        return const <double>[
          0.92,
          0,
          0,
          0,
          -3,
          0,
          1.0,
          0,
          0,
          1,
          0,
          0,
          1.1,
          0,
          8,
          0,
          0,
          0,
          1,
          0,
        ];
      case 'vivid':
        return const <double>[
          1.18,
          -0.06,
          -0.06,
          0,
          0,
          -0.06,
          1.18,
          -0.06,
          0,
          0,
          -0.06,
          -0.06,
          1.18,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ];
      case 'blackandwhite':
      case 'noir':
        return const <double>[
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ];
      case 'teal & orange':
      case 'tealorange':
        return const <double>[
          1.15, 0.02, -0.05, 0, 12,
          -0.02, 1.05, 0.05, 0, 2,
          -0.12, 0.08, 1.25, 0, -8,
          0, 0, 0, 1, 0,
        ];
      case 'kodak gold':
      case 'kodak':
        return const <double>[
          1.12, 0.04, -0.02, 0, 10,
          0.02, 1.08, 0.02, 0, 6,
          -0.04, 0.02, 0.88, 0, -4,
          0, 0, 0, 1, 0,
        ];
      case 'fuji chrome':
      case 'fuji':
        return const <double>[
          0.96, 0.02, 0.04, 0, -2,
          0.02, 1.14, 0.02, 0, 8,
          0.02, 0.04, 1.20, 0, 12,
          0, 0, 0, 1, 0,
        ];
      case 'moody emerald':
      case 'emerald':
        return const <double>[
          0.88, 0.04, -0.02, 0, -6,
          0.04, 1.18, 0.04, 0, 10,
          -0.02, 0.04, 0.94, 0, -2,
          0, 0, 0, 1, 0,
        ];
      case 'cyberpunk neon':
      case 'cyberpunk':
        return const <double>[
          1.28, -0.08, 0.12, 0, 16,
          -0.06, 0.94, 0.16, 0, -4,
          0.12, 0.04, 1.35, 0, 20,
          0, 0, 0, 1, 0,
        ];
      case 'silver noir':
      case 'silver':
        return const <double>[
          0.30, 0.59, 0.11, 0, -10,
          0.30, 0.59, 0.11, 0, -10,
          0.30, 0.59, 0.11, 0, -10,
          0, 0, 0, 1, 0,
        ];
      case 'golden hour':
      case 'goldenhour':
        return const <double>[
          1.22, 0.06, -0.04, 0, 18,
          0.04, 1.10, -0.02, 0, 10,
          -0.08, -0.04, 0.82, 0, -12,
          0, 0, 0, 1, 0,
        ];
      case 'porcelain studio':
      case 'porcelain':
        return const <double>[
          1.06, 0.02, 0.02, 0, 6,
          0.02, 1.04, 0.02, 0, 4,
          0.02, 0.02, 1.02, 0, 2,
          0, 0, 0, 1, 0,
        ];
      default:
        return null;
    }
  }

  static List<double> _mergeColorMatrices(List<double> a, List<double> b) {
    final result = List<double>.filled(20, 0.0);
    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        double sum = 0.0;
        for (int i = 0; i < 4; i++) {
          sum += a[y * 5 + i] * b[i * 5 + x];
        }
        result[y * 5 + x] = sum;
      }
      result[y * 5 + 4] = a[y * 5 + 4] + b[y * 5 + 4];
    }
    return result;
  }

  List<double>? _clipBeautyMatrix(TimelineClip clip) {
    if (clip.skinBrightening <= 0.01 &&
        clip.skinSmoothing <= 0.01 &&
        (clip.makeupGender == 0 || clip.makeupIntensity <= 0.01)) {
      return null;
    }
    final w = (clip.skinBrightening * 28.0).clamp(0.0, 38.0);
    final s = clip.skinSmoothing.clamp(0.0, 1.0);

    // Tone-adaptive Skin Brightening:
    // 0 = Neutral (pure daylight luminance)
    // 1 = Warm Peach (lifts R and G)
    // 2 = Cool Rose (clears yellow sallow tones, lifts B and R)
    // 3 = Golden Glow (sunlit bronze radiance)
    final double rBright;
    final double gBright;
    final double bBright;
    switch (clip.skinToneMode) {
      case 1: // Warm Peach
        rBright = w * 1.15;
        gBright = w * 1.05;
        bBright = w * 0.88;
        break;
      case 2: // Cool Rose
        rBright = w * 1.06;
        gBright = w * 0.98;
        bBright = w * 1.18;
        break;
      case 3: // Golden Glow
        rBright = w * 1.20;
        gBright = w * 1.10;
        bBright = w * 0.82;
        break;
      default: // Neutral
        rBright = w;
        gBright = w;
        bBright = w;
    }

    // Micro-contrast softening: gently compresses blemish contrast in skin midtones
    double contrast = 1.0 - (s * 0.06);
    double contrastOffset = (1.0 - contrast) * 128.0;
    final skinToneLift = s * 6.0;

    double rScale = contrast;
    double gScale = contrast;
    double bScale = contrast;
    double rOffset = rBright + contrastOffset + skinToneLift;
    double gOffset = gBright + contrastOffset + (skinToneLift * 0.6);
    double bOffset = bBright + contrastOffset;

    // Studio Makeup Palette (Women & Men):
    if (clip.makeupGender > 0 && clip.makeupIntensity > 0.01) {
      final m = clip.makeupIntensity.clamp(0.0, 1.0);
      if (clip.makeupGender == 1) {
        // Women (Feminine):
        switch (clip.makeupStyle) {
          case 0: // Rosy Glow (petal pink lip & cheek radiance)
            rScale += m * 0.06;
            gScale -= m * 0.02;
            bScale += m * 0.03;
            rOffset += m * 14.0;
            bOffset += m * 5.0;
            break;
          case 1: // Natural Nude (soft peach warmth, luminous skin)
            rScale += m * 0.05;
            gScale += m * 0.02;
            bScale -= m * 0.02;
            rOffset += m * 10.0;
            gOffset += m * 5.0;
            break;
          case 2: // Sunset Glam (rich berry lips & contoured cheek warmth)
            rScale += m * 0.08;
            gScale -= m * 0.03;
            bScale += m * 0.04;
            rOffset += m * 18.0;
            bOffset += m * 7.0;
            contrast += m * 0.03;
            break;
        }
      } else {
        // Men (Masculine):
        switch (clip.makeupStyle) {
          case 0: // Clean Groomed (evens complexion, conceals shadows)
            contrast += m * 0.04;
            contrastOffset = (1.0 - contrast) * 128.0;
            rScale = contrast + (m * 0.02);
            gScale = contrast + (m * 0.02);
            bScale = contrast - (m * 0.02);
            rOffset += m * 7.0;
            gOffset += m * 7.0;
            break;
          case 1: // Sharp Contour (chisels jawline & cheekbones, reduces glare)
            contrast += m * 0.07;
            contrastOffset = (1.0 - contrast) * 128.0;
            rScale = contrast + (m * 0.03);
            gScale = contrast - (m * 0.02);
            bScale = contrast - (m * 0.02);
            rOffset += m * 5.0;
            break;
          case 2: // Sun-Kissed (athletic, healthy bronzed vitality)
            rScale += m * 0.07;
            gScale += m * 0.03;
            bScale -= m * 0.05;
            rOffset += m * 12.0;
            gOffset += m * 6.0;
            break;
        }
      }
    }

    return [
      rScale, 0, 0, 0, rOffset,
      0, gScale, 0, 0, gOffset,
      0, 0, bScale, 0, bOffset,
      0, 0, 0, 1, 0,
    ];
  }

  List<Widget> _buildEffectOverlayWidgets() {
    final widgets = <Widget>[];
    final currentTime = _currentTime;

    for (final track in _tracks) {
      if (track.type != TrackType.effects) {
        continue;
      }

      for (final clip in track.clips) {
        if (clip.start > currentTime ||
            clip.start + clip.duration < currentTime) {
          continue;
        }

        if (clip.operation is! EffectOperation) {
          continue;
        }

        final effect = clip.operation as EffectOperation;
        final renderEffects = effect.renderEffects();
        final scale = (effect.intensity * 1.1).clamp(0.0, 1.0);

        widgets.add(
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: effect.opacity.clamp(0.0, 1.0),
                child: Stack(
                  children: [
                    if (renderEffects.blur > 0.01)
                      BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: renderEffects.blur * 8.0,
                          sigmaY: renderEffects.blur * 8.0,
                        ),
                        child: Container(color: Colors.transparent),
                      ),
                    if (renderEffects.vignette > 0.01)
                      Container(
                        color: Colors.black.withOpacity(
                          renderEffects.vignette * 0.32,
                        ),
                      ),
                    if (renderEffects.grain > 0.01)
                      Container(
                        color: Colors.white.withOpacity(
                          renderEffects.grain * 0.08,
                        ),
                      ),
                    if (renderEffects.brightness.abs() > 0.001 ||
                        renderEffects.contrast > 1.001 ||
                        renderEffects.saturation != 1.0)
                      ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          Colors.white.withOpacity(
                            (scale * 0.16).clamp(0.0, 0.16),
                          ),
                          BlendMode.softLight,
                        ),
                        child: Container(color: Colors.transparent),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }

    return widgets;
  }

  List<Widget> _buildTimelineOverlayWidgets() {
    final widgets = <Widget>[];
    final currentTime = _currentTime;

    for (final track in _tracks) {
      if (track.type != TrackType.text &&
          track.type != TrackType.captions &&
          track.type != TrackType.overlay) {
        continue;
      }

      for (final clip in track.clips) {
        if (clip.start > currentTime ||
            clip.start + clip.duration < currentTime) {
          continue;
        }

        if (clip.operation is! TextOverlay) {
          continue;
        }

        final overlay = clip.operation as TextOverlay;
        final alignment = Alignment(
          (overlay.position.dx * 2) - 1,
          (overlay.position.dy * 2) - 1,
        );

        widgets.add(
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: alignment,
                child: Transform.rotate(
                  angle: overlay.rotation,
                  child: Transform.scale(
                    scale: overlay.scale,
                    child: Text(
                      overlay.text,
                      textAlign: TextAlign.center,
                      style: overlay.style.copyWith(
                        color: overlay.style.color ?? Colors.white,
                        fontSize: overlay.style.fontSize ?? 28,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }

    return widgets;
  }

  // ═══════════════════════════════════════════════════════════
  // C. PLAYBACK CONTROLS
  // ═══════════════════════════════════════════════════════════
  Widget _buildPlaybackControls(Size screenSize) {
    final height = 56.0;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF070D18),
        border: Border(bottom: BorderSide(color: Color(0xFF131D2E))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _formatDuration(_currentTime),
            style: dm(sz: 15, w: FontWeight.w700, c: C.brand),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPlaybackButton(Icons.skip_previous, () => _previousFrame()),
              const SizedBox(width: 8),
              _buildPlaybackButton(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                () => _togglePlayback(),
                isLarge: true,
              ),
              const SizedBox(width: 8),
              _buildPlaybackButton(Icons.skip_next, () => _nextFrame()),
              const SizedBox(width: 8),
              _buildPlaybackButton(
                _isLoopingEnabled ? Icons.repeat_one : Icons.repeat,
                () => _toggleLooping(),
                activeColor:
                    _isLoopingEnabled ? const Color(0xFF10B981) : null,
                onLongPress: () => _showLoopContextMenu(),
              ),
              const SizedBox(width: 8),
              _buildPlaybackButton(
                Icons.crop_free,
                () => setState(() => _showFullscreenPreview = true),
              ),
            ],
          ),
          Text(
            _formatDuration(_totalDuration),
            style: dm(sz: 15, c: const Color(0xFF94A3B8), w: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  void _toggleLooping() {
    setState(() {
      _isLoopingEnabled = !_isLoopingEnabled;
      if (_isLoopingEnabled &&
          (_loopIn == null || _loopOut == null || _loopOut! <= _loopIn!)) {
        if (_selectedClip != null) {
          _loopIn = _selectedClip!.start;
          _loopOut = _selectedClip!.start + _selectedClip!.duration;
        } else {
          final half = const Duration(seconds: 3);
          _loopIn = _currentTime > half ? _currentTime - half : Duration.zero;
          final proposedOut = _currentTime + half;
          _loopOut = proposedOut < _totalDuration ? proposedOut : _totalDuration;
        }
      }
    });
    HapticFeedback.lightImpact();
    _showSnack(_isLoopingEnabled ? 'Loop Region Active' : 'Loop Disabled');
  }

  void _showLoopContextMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Loop Region Options',
                        style: dm(sz: 16, w: FontWeight.w700, c: Colors.white)),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.start, color: Color(0xFF10B981)),
                  title: Text(
                      'Set In Point [I] at ${_formatDuration(_currentTime)}',
                      style: dm(sz: 13, c: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _loopIn = _currentTime;
                      if (_loopOut != null && _loopOut! <= _loopIn!) {
                        _loopOut = _totalDuration;
                      }
                      _isLoopingEnabled = true;
                    });
                    HapticFeedback.lightImpact();
                    _showSnack('Loop In set');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.east, color: Color(0xFF10B981)),
                  title: Text(
                      'Set Out Point [O] at ${_formatDuration(_currentTime)}',
                      style: dm(sz: 13, c: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _loopOut = _currentTime;
                      if (_loopIn == null || _loopIn! >= _loopOut!) {
                        _loopIn = Duration.zero;
                      }
                      _isLoopingEnabled = true;
                    });
                    HapticFeedback.lightImpact();
                    _showSnack('Loop Out set');
                  },
                ),
                if (_loopIn != null && _loopOut != null)
                  ListTile(
                    leading: const Icon(Icons.clear, color: Colors.redAccent),
                    title: Text('Clear Loop Region',
                        style: dm(sz: 13, c: Colors.redAccent)),
                    onTap: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _loopIn = null;
                        _loopOut = null;
                        _isLoopingEnabled = false;
                      });
                      HapticFeedback.lightImpact();
                      _showSnack('Loop Region Cleared');
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaybackButton(
    IconData icon,
    VoidCallback onTap, {
    bool isLarge = false,
    Color? activeColor,
    VoidCallback? onLongPress,
  }) {
    final effectiveBg = activeColor != null
        ? activeColor.withValues(alpha: 0.20)
        : (isLarge ? C.brand : const Color(0xFF0F172A));
    final iconColor = activeColor ?? (isLarge ? Colors.black : C.brand);
    final borderColor = activeColor != null
        ? activeColor.withValues(alpha: 0.6)
        : const Color(0xFF1E293B);

    return Container(
      width: isLarge ? 42 : 36,
      height: isLarge ? 42 : 36,
      decoration: BoxDecoration(
        color: effectiveBg,
        shape: isLarge ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isLarge ? null : BorderRadius.circular(8),
        border: isLarge ? null : Border.all(color: borderColor),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(isLarge ? 21 : 8),
          child: Icon(
            icon,
            size: isLarge ? 24 : 18,
            color: iconColor,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // D. TIMELINE WORKSPACE (30%)
  // ═══════════════════════════════════════════════════════════
  Widget _buildEditorPanel(Size screenSize) {
    if (_activeToolPanel == 1) {
      return _buildMediaLibraryPanel();
    }
    if (_activeToolPanel == 2) {
      return _buildAudioPanel(screenSize);
    }
    return _buildTimelineWorkspace(screenSize);
  }

  Widget _buildMediaLibraryPanel() {
    final assets =
        _mediaService.recentAssets.where((asset) {
          final matchesCategory = switch (_mediaCategory) {
            'Recent' => true,
            'Favorites' => _favoriteMediaPaths.contains(asset.path),
            'Downloads' => asset.path.toLowerCase().contains('download'),
            'Camera' =>
              asset.path.toLowerCase().contains('camera') ||
                  asset.path.toLowerCase().contains('dcim'),
            'NECXA Cloud' => false,
            _ => asset.category == _mediaCategory,
          };
          final query = _mediaQuery.toLowerCase();
          return matchesCategory &&
              (query.isEmpty || asset.name.toLowerCase().contains(query));
        }).toList()..sort(
          (a, b) => _mediaNewestFirst
              ? b.importedAt.compareTo(a.importedAt)
              : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );

    const categories = [
      'Recent',
      'Videos',
      'Photos',
      'Downloads',
      'Camera',
      'Files',
      'Favorites',
      'NECXA Cloud',
    ];
    return Container(
      color: C.bg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Text(
                  'Media library',
                  style: syne(sz: 13, w: FontWeight.w800, c: C.text),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _mediaGridView ? 'List view' : 'Grid view',
                  onPressed: () =>
                      setState(() => _mediaGridView = !_mediaGridView),
                  icon: Icon(
                    _mediaGridView
                        ? Icons.view_list_outlined
                        : Icons.grid_view_outlined,
                    color: C.dim,
                    size: 20,
                  ),
                ),
                IconButton(
                  tooltip: 'Sort media',
                  onPressed: () =>
                      setState(() => _mediaNewestFirst = !_mediaNewestFirst),
                  icon: Icon(
                    _mediaNewestFirst ? Icons.schedule : Icons.sort_by_alpha,
                    color: C.dim,
                    size: 20,
                  ),
                ),
                FilledButton.icon(
                  onPressed: _importMediaToLibrary,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Import'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              onChanged: (value) => setState(() => _mediaQuery = value),
              style: dm(sz: 11, c: C.text),
              decoration: InputDecoration(
                hintText: 'Search imported media',
                hintStyle: dm(sz: 11, c: C.dim),
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                filled: true,
                fillColor: C.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: C.border),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final category = categories[index];
                final selected = category == _mediaCategory;
                return ChoiceChip(
                  label: Text(
                    category,
                    style: dm(
                      sz: 9,
                      c: selected ? Colors.white : C.dim,
                      w: FontWeight.w600,
                    ),
                  ),
                  selected: selected,
                  onSelected: (_) => setState(() => _mediaCategory = category),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: assets.isEmpty
                ? Center(
                    child: Text(
                      'No ${_mediaCategory.toLowerCase()} media yet',
                      style: dm(sz: 12, c: C.dim),
                    ),
                  )
                : _mediaGridView
                ? GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: .82,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: assets.length,
                    itemBuilder: (context, index) =>
                        _buildMediaAssetCard(assets[index]),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    itemCount: assets.length,
                    itemBuilder: (context, index) =>
                        _buildMediaAssetCard(assets[index], list: true),
                  ),
          ),
          if (_selectedMediaPaths.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _insertMediaAssets(
                    _mediaService.recentAssets
                        .where(
                          (asset) => _selectedMediaPaths.contains(asset.path),
                        )
                        .toList(),
                  ),
                  icon: const Icon(Icons.add_to_queue, size: 18),
                  label: Text('Add ${_selectedMediaPaths.length} to timeline'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double? _cropRatioFor(String ratio) {
    switch (ratio) {
      case '9:16':
        return 9 / 16;
      case '16:9':
        return 16 / 9;
      case '1:1':
        return 1;
      case '4:5':
        return 4 / 5;
      default:
        return null;
    }
  }

  Widget _buildMediaAssetCard(EditorMediaAsset asset, {bool list = false}) {
    final selected = _selectedMediaPaths.contains(asset.path);
    final favorite = _favoriteMediaPaths.contains(asset.path);
    final preview = asset.isImage
        ? Image.file(
            asset.file,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                Icon(Icons.broken_image_outlined, color: C.dim),
          )
        : Icon(
            asset.isVideo
                ? Icons.videocam_outlined
                : Icons.insert_drive_file_outlined,
            color: C.brand,
            size: list ? 26 : 34,
          );
    return GestureDetector(
      onTap: () => setState(
        () => selected
            ? _selectedMediaPaths.remove(asset.path)
            : _selectedMediaPaths.add(asset.path),
      ),
      onLongPress: () => _showMediaInfo(asset),
      child: Container(
        margin: list ? const EdgeInsets.only(bottom: 8) : EdgeInsets.zero,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected ? C.brand.withOpacity(.15) : C.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? C.brand : C.border),
        ),
        child: list
            ? Row(
                children: [
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: Center(child: preview),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          asset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: dm(sz: 10, c: C.text, w: FontWeight.w600),
                        ),
                        Text(
                          '${asset.category} • ${_formatMediaBytes(asset.sizeBytes)}',
                          style: dm(sz: 9, c: C.dim),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(
                      () => favorite
                          ? _favoriteMediaPaths.remove(asset.path)
                          : _favoriteMediaPaths.add(asset.path),
                    ),
                    icon: Icon(
                      favorite ? Icons.star : Icons.star_border,
                      color: favorite ? Colors.amber : C.dim,
                      size: 18,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SizedBox(
                      width: double.infinity,
                      child: Center(child: preview),
                    ),
                  ),
                  Text(
                    asset.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dm(sz: 9, c: C.text, w: FontWeight.w600),
                  ),
                  Text(
                    _formatMediaBytes(asset.sizeBytes),
                    style: dm(sz: 8, c: C.dim),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildTimelineWorkspace(Size screenSize) {
    final visibleTracks = TimelineModelUtils.visibleTracks(_tracks);
    final timelineWidth =
        (_totalDuration.inMilliseconds / 1000.0) *
            (_pixelsPerSecond * _timelineZoom) +
        screenSize.width / 2;

    return Container(
      color: C.bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              children: [
                Text(
                  'Timeline',
                  style: syne(sz: 16, w: FontWeight.w800, c: Colors.white),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _showTimelineInsertMenu,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F1E2E),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.add, size: 14, color: C.brand),
                        const SizedBox(width: 4),
                        Text(
                          'Add',
                          style: dm(sz: 11, c: C.brand, w: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1E2E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF0284C7).withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    '${visibleTracks.length} Tracks',
                    style: dm(sz: 11, c: C.brand, w: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: GestureDetector(
              onScaleStart: (_) {},
              onScaleUpdate: (details) {
                if (details.scale != 1.0) {
                  setState(
                    () => _timelineZoom = (_timelineZoom * details.scale).clamp(
                      0.5,
                      3.0,
                    ),
                  );
                }
              },
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Pane: Track Headers
                  Container(
                    width: 52,
                    decoration: const BoxDecoration(
                      color: Color(0xFF070D18),
                      border: Border(right: BorderSide(color: Color(0xFF131D2E))),
                    ),
                    child: ListView.builder(
                      controller: _sidebarScrollController,
                      padding: const EdgeInsets.only(
                        top: 22,
                        bottom: 8,
                      ), // 22 is ruler height
                      itemCount: visibleTracks.length,
                      itemBuilder: (context, index) {
                        final track = visibleTracks[index];
                        final isSelected = _selectedTrackId == track.id;
                        return GestureDetector(
                          onTap: () => setState(() {
                            _selectedTrackId = track.id;
                            _selectedTrackIndex = _tracks.indexWhere(
                              (candidate) => candidate.id == track.id,
                            );
                          }),
                          child: Container(
                            height: 52,
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? C.brand.withValues(alpha: 0.12)
                                  : Colors.transparent,
                              border: Border(
                                left: BorderSide(
                                  color: isSelected
                                      ? C.brand
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.movie_creation_outlined,
                                  size: 18,
                                  color: Color(0xFF94A3B8),
                                ),
                                const SizedBox(height: 3),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _buildTrackButton(
                                      Icons.visibility_outlined,
                                      () => _toggleTrackVisibility(track),
                                      size: 11,
                                    ),
                                    const SizedBox(width: 4),
                                    _buildTrackButton(
                                      Icons.lock_outline,
                                      () => _toggleTrackLock(track),
                                      size: 11,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  // Right Pane: Timeline Area
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      controller: _timelineScrollController,
                      child: SizedBox(
                        width: timelineWidth > screenSize.width
                            ? timelineWidth
                            : screenSize.width,
                        child: Stack(
                          children: [
                            ListView.builder(
                              controller: _verticalScrollController,
                              padding: const EdgeInsets.only(bottom: 8),
                              itemCount:
                                  visibleTracks.length + 1, // +1 for Ruler
                              itemBuilder: (context, index) {
                                if (index == 0)
                                  return _buildTimelineRuler(timelineWidth);
                                return _buildTrackClips(
                                  visibleTracks[index - 1],
                                );
                              },
                            ),
                            // Global Playhead
                            _buildGlobalPlayhead(timelineWidth),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineRuler(double timelineWidth) {
    return TimelineRulerView(
      totalDuration: _totalDuration,
      pixelsPerSecond: _pixelsPerSecond,
      zoom: _timelineZoom,
      width: timelineWidth,
      loopIn: _loopIn,
      loopOut: _loopOut,
      onRulerTap: (t) {
        _playback.seek(t, _tracks);
        setState(() => _currentTime = t);
      },
    );
  }

  Widget _buildGlobalPlayhead(double timelineWidth) {
    return TimelinePlayheadView(
      currentTime: _currentTime,
      totalDuration: _totalDuration,
      tracks: _tracks,
      pixelsPerSecond: _pixelsPerSecond,
      zoom: _timelineZoom,
      snappingEnabled: _isSnappingEnabled,
      scrollController: _timelineScrollController,
      timelineWidth: timelineWidth,
      onSeek: (t) {
        _playback.seek(t, _tracks);
        setState(() => _currentTime = t);
      },
    );
  }

  Widget _buildTrackClips(TimelineTrack track) {
    final scale = _pixelsPerSecond * _timelineZoom;
    final showGhost = _ghostClipId != null &&
        _ghostTrackId == track.id &&
        _ghostStart != null &&
        _ghostDuration != null &&
        (_clipDragMode == _ClipDragMode.resizeLeft ||
            _clipDragMode == _ClipDragMode.resizeRight);

    return Container(
      height: 52,
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(color: C.surface.withValues(alpha: 0.5)),
      child: Stack(
        children: [
          // ── Ghost trim outline ────────────────────────────────
          if (showGhost)
            Positioned(
              left: (_ghostStart!.inMilliseconds / 1000.0) * scale,
              top: 2,
              bottom: 2,
              width: (_ghostDuration!.inMilliseconds / 1000.0) * scale,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFFBBF24).withValues(alpha: 0.6),
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),

          // ── Clips ─────────────────────────────────────────────
          ...track.clips.map((clip) {
            final left = (clip.start.inMilliseconds / 1000.0) * scale;
            final width = (clip.duration.inMilliseconds / 1000.0) * scale;
            final isSelected = _selectedClipIds.contains(clip.id);
            final isTrimming = _activeDragClipId == clip.id &&
                (_clipDragMode == _ClipDragMode.resizeLeft ||
                    _clipDragMode == _ClipDragMode.resizeRight);
            final isMoving = _activeDragClipId == clip.id &&
                _clipDragMode == _ClipDragMode.move;
            // Handle colour: amber while trimming, slate otherwise
            final handleColor = isTrimming
                ? const Color(0xFFFBBF24)
                : const Color(0xFF94A3B8);

            return Positioned(
              left: left,
              top: 2,
              bottom: 2,
              width: width,
              // RepaintBoundary isolates each clip so playhead needle repaints
              // don't trigger a relayout/repaint of every clip thumbnail.
              child: RepaintBoundary(
                child: GestureDetector(
                  onTap: () => _selectClip(track, clip),
                  onDoubleTap: () => _trimClip(),
                  onLongPress: () => _enterMultiSelect(track, clip),
                  onPanStart: (details) =>
                      _onClipPanStart(track, clip, details, width),
                  onPanUpdate: (details) =>
                      _onClipPanUpdate(track, clip, details),
                  onPanEnd: (details) => _onClipPanEnd(details),
                  child: AnimatedScale(
                    scale: isMoving ? 1.03 : 1.0,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOutCubic,
                      decoration: isMoving
                          ? BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.45),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            )
                          : null,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildClipContent(
                              track, clip, width, isSelected, isTrimming),
                          if (isSelected || isTrimming) ...[
                            // left trim handle
                            Positioned(
                              left: 0,
                              top: 0,
                              bottom: 0,
                              width: _clipHandleWidth,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.resizeLeftRight,
                                child: Container(
                                  color: Colors.transparent,
                                  child: Center(
                                    child: Container(
                                      width: 4,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: handleColor,
                                        borderRadius:
                                            BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // right trim handle
                            Positioned(
                              right: 0,
                              top: 0,
                              bottom: 0,
                              width: _clipHandleWidth,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.resizeLeftRight,
                                child: Container(
                                  color: Colors.transparent,
                                  child: Center(
                                    child: Container(
                                      width: 4,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: handleColor,
                                        borderRadius:
                                            BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // center drag hint line
                            Positioned(
                              left: width / 2 - 10,
                              top: 0,
                              bottom: 0,
                              width: 20,
                              child: Center(
                                child: Container(
                                  width: 2,
                                  height: 20,
                                  color: Colors.white12,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }


  Widget _buildClipContent(
    TimelineTrack track,
    TimelineClip clip,
    double width,
    bool isSelected,
    bool isTrimming,
  ) {
    final baseColor = _trackColorForType(track.type);

    Widget content;
    if (track.type == TrackType.video) {
      // Pro video clip: thumbnail left + metadata + badge row + waveform footer
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left thumbnail panel
                ClipRRect(
                  borderRadius:
                      const BorderRadius.horizontal(left: Radius.circular(8)),
                  child: SizedBox(
                    width: 46,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _VideoClipThumbnails(
                          clip: clip,
                          width: 46,
                          pixelsPerSecond: _pixelsPerSecond * _timelineZoom,
                        ),
                        Container(
                            color: Colors.black.withValues(alpha: 0.15)),
                      ],
                    ),
                  ),
                ),
                // Metadata + badges
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: 8, right: 4, top: 5, bottom: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                clip.file?.path.split('/').last ?? 'Video 1',
                                style: dm(
                                    sz: 10,
                                    c: Colors.white,
                                    w: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            _ClipBadgeRow(clip: clip),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _formatDuration(clip.duration),
                          style: dm(sz: 8, c: Colors.white60),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Mini waveform bar — 8px tall audio visualiser at clip bottom
          SizedBox(
            height: 8,
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(8)),
              child: CustomPaint(
                painter: _WaveformPainter(
                  color: Colors.white.withValues(alpha: 0.18),
                  seed: clip.id.hashCode,
                ),
              ),
            ),
          ),
        ],
      );
    } else if (track.type == TrackType.audio ||
        track.type == TrackType.voiceOver ||
        track.type == TrackType.music) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _WaveformPainter(
              color: Colors.white.withValues(alpha: 0.5),
              seed: clip.id.hashCode,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clip.id,
                  style: dm(sz: 8, c: Colors.white, w: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _formatDuration(clip.duration),
                  style: dm(sz: 7, c: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _clipLabelForTrack(track.type),
              style: dm(sz: 8, c: Colors.white, w: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              _formatDuration(clip.duration),
              style: dm(sz: 7, c: Colors.white70),
            ),
          ],
        ),
      );
    }

    // Border / glow: amber when trimming, cyan when selected, dim otherwise
    final borderColor = isTrimming
        ? const Color(0xFFFBBF24)
        : isSelected
            ? const Color(0xFF00E5FF)
            : Colors.white.withValues(alpha: 0.08);
    final borderWidth = (isTrimming || isSelected) ? 2.0 : 1.0;
    final glowColor = isTrimming
        ? const Color(0xFFFBBF24).withValues(alpha: 0.35)
        : const Color(0xFF00E5FF).withValues(alpha: 0.3);

    return Container(
      decoration: BoxDecoration(
        color: track.type == TrackType.video
            ? const Color(0xFF0F172A)
            : baseColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: (isTrimming || isSelected)
            ? [
                BoxShadow(
                  color: glowColor,
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }


  Color _trackColorForType(TrackType type) {
    switch (type) {
      case TrackType.video:
        return const Color(0xFF1E293B); // Deep Cinematic Slate
      case TrackType.images:
        return const Color(0xFF0F766E); // Deep Teal
      case TrackType.audio:
        return const Color(0xFF065F46); // Forest Green
      case TrackType.music:
        return const Color(0xFF047857); // Studio Emerald Green
      case TrackType.voiceOver:
        return const Color(0xFF059669); // Radiant Mint
      case TrackType.soundEffects:
        return const Color(0xFFD97706); // Warm Amber
      case TrackType.text:
        return const Color(0xFFB45309); // Royal Gold
      case TrackType.captions:
        return const Color(0xFF92400E); // Deep Gold
      case TrackType.overlay:
        return const Color(0xFFBE185D); // Vivid Magenta
      case TrackType.effects:
        return const Color(0xFF6D28D9); // Amethyst Purple
    }
  }

  Widget _buildTrackButton(
    IconData icon,
    VoidCallback onTap, {
    double size = 20,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size, color: C.dim),
        ),
      ),
    );
  }

  Widget _buildAudioPanel(Size screenSize) {
    final audioTracks = _tracks.where((track) {
      return track.type == TrackType.music ||
          track.type == TrackType.voiceOver ||
          track.type == TrackType.soundEffects;
    }).toList();

    return Container(
      color: C.bg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Audio Studio',
                        style: syne(sz: 16, w: FontWeight.w800, c: C.text),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Add music, voiceovers, and SFX to your timeline.',
                        style: dm(sz: 12, c: C.dim),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _showAudioPicker,
                  icon: const Icon(Icons.library_music, color: C.brand),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildActionChip('Music', Icons.music_note, _showAudioPicker),
                  const SizedBox(width: 8),
                  _buildActionChip(
                    _isRecordingVoice ? 'Recording' : 'Voice',
                    Icons.mic,
                    _showVoiceoverRecorder,
                  ),
                  const SizedBox(width: 8),
                  _buildActionChip('SFX', Icons.speaker, _addSoundEffect),
                  const SizedBox(width: 8),
                  _buildActionChip(
                    'Files',
                    Icons.folder_open_outlined,
                    _importDeviceAudio,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: audioTracks.isEmpty
                ? Center(
                    child: Text(
                      'No audio clips yet. Tap Music or Voice to add one.',
                      style: dm(sz: 13, c: C.dim),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: audioTracks.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final track = audioTracks[index];
                      return _buildAudioTrackCard(track);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip(String label, IconData icon, VoidCallback onTap) {
    return Material(
      color: C.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: C.brand),
              const SizedBox(width: 8),
              Text(
                label,
                style: dm(sz: 12, c: C.text, w: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioTrackCard(TimelineTrack track) {
    final totalDuration = track.clips.fold<Duration>(
      Duration.zero,
      (sum, clip) => sum + clip.duration,
    );
    return Container(
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(track.icon, color: C.brand),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  track.label,
                  style: syne(sz: 14, w: FontWeight.w800, c: C.text),
                ),
              ),
              Text(
                '${track.clips.length} clip${track.clips.length == 1 ? '' : 's'}',
                style: dm(sz: 12, c: C.dim),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (track.clips.isEmpty)
            Text('No clips added yet.', style: dm(sz: 12, c: C.dim))
          else
            Column(
              children: track.clips
                  .map((clip) => _buildAudioClipRow(track, clip))
                  .toList(),
            ),
          const SizedBox(height: 12),
          Text(
            'Total ${_formatDuration(totalDuration)}',
            style: dm(sz: 11, c: C.dim),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioClipRow(TimelineTrack track, TimelineClip clip) {
    final operation = clip.operation;
    final label = operation is AudioClipOperation
        ? (operation.label ?? _clipLabelForTrack(track.type))
        : _clipLabelForTrack(track.type);
    final source = operation is AudioClipOperation ? operation.sourceUrl : null;
    final isPlaying =
        _activeAudioPreviewUrl != null &&
        source != null &&
        _activeAudioPreviewUrl == source;

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: dm(sz: 12, c: Colors.white, w: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDuration(clip.duration),
                      style: dm(sz: 11, c: C.dim),
                    ),
                  ],
                ),
              ),
              if (source != null && source != 'builtin://sfx')
                Material(
                  color: C.surface,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => isPlaying
                        ? _stopAudioPreview()
                        : _previewAudioSource(source, clip: clip),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      child: Icon(
                        isPlaying ? Icons.stop : Icons.play_arrow,
                        size: 18,
                        color: C.brand,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              Material(
                color: C.surface,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _removeClip(track, clip),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    child: Icon(
                      Icons.delete,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 32,
              color: C.surface,
              child: Row(
                children: List.generate(20, (index) {
                  return Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: index.isEven ? Colors.white12 : Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _previewAudioSource(
    String sourceUrl, {
    TimelineClip? clip,
  }) async {
    await _musicService.stopPreview();
    await _audioPreviewPlayer.stop();

    if (sourceUrl.startsWith('http')) {
      await _musicService.previewMusic(sourceUrl);
    } else {
      await _audioPreviewPlayer.play(DeviceFileSource(sourceUrl));
      await _audioPreviewPlayer.setVolume(clip?.volume ?? 1.0);
      await _audioPreviewPlayer.setPlaybackRate(clip?.speed ?? 1.0);
      if (clip != null && clip.sourceStart > Duration.zero) {
        await _audioPreviewPlayer.seek(clip.sourceStart);
      }
    }

    setState(() {
      _activeAudioPreviewUrl = sourceUrl;
      _isPreviewingMusic = true;
    });
  }

  Future<void> _stopAudioPreview() async {
    await _musicService.stopPreview();
    await _audioPreviewPlayer.stop();
    setState(() {
      _activeAudioPreviewUrl = null;
      _isPreviewingMusic = false;
    });
  }

  void _removeClip(TimelineTrack track, TimelineClip clip) {
    _captureTimeline();
    setState(() {
      track.clips.remove(clip);
      _selectedClipIds.remove(clip.id);
      if (_selectedClip == clip) {
        _selectedClip = null;
        _selectedTrackId = null;
        _selectedTrackIndex = null;
      }
      if (_selectedClipIds.length < 2) _isMultiSelectMode = false;
      TimelineModelUtils.pruneEmptyTracks(_tracks);
    });
  }

  String _getTrackIcon(TrackType type) {
    switch (type) {
      case TrackType.video:
        return '🎬';
      case TrackType.audio:
        return '🎵';
      case TrackType.text:
        return '📝';
      case TrackType.images:
        return '🖼️';
      case TrackType.captions:
        return '📄';
      case TrackType.overlay:
        return '🪟';
      case TrackType.effects:
        return '✨';
      case TrackType.music:
        return '🎼';
      case TrackType.voiceOver:
        return '🎙️';
      case TrackType.soundEffects:
        return '🔊';
    }
  }

  String _clipLabelForTrack(TrackType type) {
    switch (type) {
      case TrackType.video:
        return 'Video';
      case TrackType.audio:
        return 'Audio';
      case TrackType.text:
        return 'Text';
      case TrackType.images:
        return 'Image';
      case TrackType.captions:
        return 'Caption';
      case TrackType.overlay:
        return 'Overlay';
      case TrackType.effects:
        return 'Effect';
      case TrackType.music:
        return 'Music';
      case TrackType.voiceOver:
        return 'Voice';
      case TrackType.soundEffects:
        return 'SFX';
    }
  }

  // ═══════════════════════════════════════════════════════════
  // E. CONTEXT TOOLBAR (shown when a clip is selected)
  // ═══════════════════════════════════════════════════════════
  Widget _buildContextToolbar(Size screenSize) {
    if (_selectedClipIds.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      height: 68,
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: _buildContextualTools(),
    );
  }

  Widget _buildContextualTools() {
    if (_selectedClipIds.length > 1) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: _buildToolsForMultiSelection()),
      );
    }
    if (_selectedClip == null) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: _buildToolsForSelection()),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: _buildToolsForClip(_selectedClip!)),
    );
  }

  List<Widget> _buildToolsForSelection() {
    switch (_activeToolPanel) {
      case 1:
        return [
          _buildToolButton('Media', () => _pickMediaFromLibrary(), Icons.video_library),
          _buildToolButton('Trim', () => _trimClip(), Icons.content_cut),
          _buildToolButton('Crop', _cropClip, Icons.crop),
          _buildToolButton('Speed', () => _adjustSpeed(), Icons.speed),
          _buildToolButton('Volume', _adjustVolume, Icons.graphic_eq),
          _buildToolButton('Reverse', _toggleReverse, Icons.swap_horizontal_circle_outlined),
        ];
      case 2:
        return [
          _buildToolButton('Music', () => _showAudioPicker(), Icons.music_note),
          _buildToolButton('Voice', _showVoiceoverRecorder, Icons.mic),
          _buildToolButton('SFX', () => _addSoundEffect(), Icons.surround_sound),
          _buildToolButton('Mixer', _showAudioMixerSheet, Icons.graphic_eq),
          _buildToolButton('Volume', () => _adjustVolume(), Icons.volume_up),
        ];
      case 3:
        return [
          _buildToolButton('Text Hub', () => _showTextHubSheet(), Icons.dashboard_customize),
          _buildToolButton('Edit', () => _showTextEditorSheet(), Icons.edit),
          _buildToolButton('Font', () => _showTextEditorSheet(), Icons.font_download),
          _buildToolButton('Color', () => _showTextEditorSheet(), Icons.palette),
        ];
      case 4:
        return [
          _buildToolButton('Library', () => _toggleEffectLibrary(), Icons.auto_awesome_motion),
          _buildToolButton('Adjust', _showAdjustSheet, Icons.tune),
          _buildToolButton('LUTs', _showFilterSheet, Icons.movie_filter),
          _buildToolButton('Intensity', () => _showEffectEditorSheet(), Icons.tune),
          _buildToolButton('Apply', () => _applySelectedEffect(), Icons.check_circle_outline),
        ];
      default:
        return [
          _buildToolButton('Split', () => _splitClip(), Icons.call_split),
          _buildToolButton('Trim', () => _trimClip(), Icons.content_cut),
          _buildToolButton('Lock', () => _showSnack('Track locked'), Icons.lock_outline),
          _buildToolButton('Hide', () => _showSnack('Track hidden'), Icons.visibility_off_outlined),
        ];
    }
  }

  List<Widget> _buildToolsForClip(TimelineClip clip) {
    final tools = <Widget>[];

    if (_selectedTrackId != null && _tracks.isNotEmpty) {
      final selectedTrack = _tracks.firstWhere(
        (candidate) => candidate.id == _selectedTrackId,
        orElse: () => _tracks.first,
      );
      if (selectedTrack.type == TrackType.video) {
        tools.addAll([
          _buildToolButton('Split', () => _splitClip(), Icons.call_split),
          _buildToolButton('Trim', () => _trimClip(), Icons.content_cut),
          _buildToolButton('Velocity', () => _adjustSpeed(), Icons.speed),
          _buildToolButton('Crop', _cropClip, Icons.crop),
          _buildToolButton('Adjust', _showAdjustSheet, Icons.tune),
          _buildToolButton('LUTs', _showFilterSheet, Icons.movie_filter),
          _buildToolButton('Fade', () => _showFadeSheet(clip), Icons.animation),
          _buildToolButton('Beauty', _showBeautyStudioSheet, Icons.face_retouching_natural),
          _buildToolButton('Presets', _showFaceEngineSheet, Icons.auto_fix_high),
          _buildToolButton('Mixer', _showAudioMixerSheet, Icons.graphic_eq),
          _buildToolButton('Transform', _showTransformEditorSheet, Icons.transform),
          _buildToolButton('Opacity', () => _adjustOpacity(), Icons.opacity),
          _buildToolButton('Stickers', _showStickerSheet, Icons.auto_awesome),
          _buildToolButton('Reverse', _toggleReverse, Icons.swap_horizontal_circle_outlined),
          _buildToolButton('Duplicate', () {
            _captureTimeline();
            final dup = clip.copyWith(
              id: '${clip.id}-dup-${DateTime.now().millisecondsSinceEpoch}',
            );
            dup.start = clip.start + clip.duration;
            TimelineModelUtils.insertClip(_tracks, dup, TrackType.video);
            _playback.updateProject(_tracks);
            setState(() {});
            _showSnack('Clip duplicated');
          }, Icons.content_copy),
          _buildToolButton('Delete', () => _deleteClip(), Icons.delete_outline),
        ]);
      } else if (selectedTrack.type == TrackType.text ||
          selectedTrack.type == TrackType.captions) {
        tools.addAll([
          _buildToolButton('Edit', () => _showTextEditorSheet(), Icons.edit),
          _buildToolButton('Font', () => _showTextEditorSheet(), Icons.font_download),
          _buildToolButton('Size', () => _showTextEditorSheet(), Icons.format_size),
          _buildToolButton('Color', () => _showTextEditorSheet(), Icons.palette),
          _buildToolButton('Style', () => _showTextHubSheet(), Icons.animation),
          _buildToolButton('Delete', () => _deleteClip(), Icons.delete_outline),
        ]);
      } else if (selectedTrack.type == TrackType.audio ||
          selectedTrack.type == TrackType.music ||
          selectedTrack.type == TrackType.voiceOver ||
          selectedTrack.type == TrackType.soundEffects) {
        tools.addAll([
          _buildToolButton('Split', _splitClip, Icons.call_split),
          _buildToolButton('Trim', _trimClip, Icons.content_cut),
          _buildToolButton('Speed', _adjustSpeed, Icons.speed),
          _buildToolButton('Mixer', _showAudioMixerSheet, Icons.graphic_eq),
          _buildToolButton('Volume', () => _adjustVolume(), Icons.volume_up),
          _buildToolButton('Fade', () => _addFade(), Icons.animation),
          _buildToolButton('Reverse', _toggleReverse, Icons.swap_horizontal_circle_outlined),
          _buildToolButton('Delete', () => _deleteClip(), Icons.delete_outline),
        ]);
      } else if (selectedTrack.type == TrackType.effects) {
        tools.addAll([
          _buildToolButton('Adjust', _showAdjustSheet, Icons.tune),
          _buildToolButton('LUTs', _showFilterSheet, Icons.movie_filter),
          _buildToolButton('Intensity', () => _showEffectEditorSheet(), Icons.tune),
          _buildToolButton('Opacity', () => _showEffectEditorSheet(), Icons.opacity),
          _buildToolButton('Blend', () => _showEffectEditorSheet(), Icons.blur_linear),
          _buildToolButton('Delete', () => _deleteClip(), Icons.delete_outline),
        ]);
      } else {
        tools.addAll([
          _buildToolButton('Resize', () => _showSnack('Resize clip'), Icons.aspect_ratio),
          _buildToolButton('Opacity', () => _adjustOpacity(), Icons.opacity),
          _buildToolButton('Delete', () => _deleteClip(), Icons.delete_outline),
        ]);
      }
    }

    return tools;
  }

  Widget _buildToolButton(String label, VoidCallback onTap, [IconData? icon]) {
    final resolvedIcon = icon ?? _defaultIconForTool(label);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(minWidth: 54),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: C.surface.withOpacity(0.85),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.border.withOpacity(0.5)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(resolvedIcon, size: 20, color: C.brand),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: dm(sz: 10, c: C.text, w: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _defaultIconForTool(String label) {
    switch (label.toLowerCase()) {
      case 'split':
        return Icons.call_split;
      case 'trim':
        return Icons.content_cut;
      case 'crop':
        return Icons.crop;
      case 'speed':
      case 'velocity':
        return Icons.speed;
      case 'volume':
      case 'mixer':
        return Icons.graphic_eq;
      case 'reverse':
        return Icons.swap_horizontal_circle_outlined;
      case 'delete':
        return Icons.delete_outline;
      case 'duplicate':
        return Icons.content_copy;
      case 'transform':
        return Icons.transform;
      case 'filter':
      case 'filters':
      case 'luts':
        return Icons.movie_filter;
      case 'adjust':
        return Icons.tune;
      case 'fade':
        return Icons.animation;
      case 'face':
        return Icons.face_retouching_natural;
      case 'stickers':
        return Icons.auto_awesome;
      case 'music':
        return Icons.music_note;
      case 'voice':
        return Icons.mic;
      case 'sfx':
        return Icons.surround_sound;
      case 'edit':
        return Icons.edit;
      case 'font':
        return Icons.font_download;
      case 'size':
        return Icons.format_size;
      case 'color':
        return Icons.palette;
      case 'text hub':
        return Icons.dashboard_customize;
      case 'opacity':
        return Icons.opacity;
      case 'library':
        return Icons.auto_awesome_motion;
      case 'intensity':
        return Icons.tune;
      case 'apply':
        return Icons.check_circle_outline;
      case 'lock':
        return Icons.lock_outline;
      case 'hide':
        return Icons.visibility_off_outlined;
      case 'media':
        return Icons.video_library;
      default:
        return Icons.widgets_outlined;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // F. BOTTOM NAVIGATION
  // ═══════════════════════════════════════════════════════════
  Widget _buildBottomNavigation(Size screenSize) {
    final navItems = [
      (Icons.timeline, 'Timeline'),
      (Icons.photo_library, 'Media'),
      (Icons.music_note, 'Audio'),
      (Icons.text_fields, 'Text'),
      (Icons.auto_awesome, 'Effects'),
      (Icons.face_retouching_natural, 'Face'),
      (Icons.swap_horiz, 'Transitions'),
      (Icons.settings, 'Settings'),
    ];

    return Container(
      height: 62,
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(navItems.length, (index) {
          final item = navItems[index];
          final active = index == _activeToolPanel;
          return GestureDetector(
            onTap: () {
              setState(() {
                _activeToolPanel = index;
                _bottomNavController.index = index;
              });
              if (index == 3) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _showTextHubSheet(),
                );
              } else if (index == 4) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _showEffectLibrarySheet(),
                );
              } else if (index == 5) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _showBeautyStudioSheet(),
                );
              } else if (index == 6) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _showTransitionLibrarySheet(),
                );
              } else if (index == 7) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _showEditorSettingsSheet(),
                );
              }
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.$1, color: active ? C.brand : C.dim, size: 22),
                const SizedBox(height: 4),
                Text(item.$2, style: dm(sz: 8, c: active ? C.brand : C.dim)),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // FLOATING ACTION BUTTONS
  // ═══════════════════════════════════════════════════════════
  // ═══════════════════════════════════════════════════════════
  // ACTION HANDLERS
  // ═══════════════════════════════════════════════════════════

  void _refreshComposition() {
    _playback.updateProject(_tracks);
    _queueCompositionSync();
  }

  Future<void> _showEditorSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          void update(VoidCallback change) {
            setState(change);
            setModalState(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Editor settings',
                    style: syne(sz: 15, w: FontWeight.w800, c: C.text),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Snap edits to frames',
                      style: dm(sz: 12, c: C.text),
                    ),
                    subtitle: Text(
                      'Uses $_selectedFps project timing',
                      style: dm(sz: 10, c: C.dim),
                    ),
                    value: _isSnappingEnabled,
                    onChanged: (value) =>
                        update(() => _isSnappingEnabled = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Ripple editing', style: dm(sz: 12, c: C.text)),
                    subtitle: Text(
                      'Move following clips with the edit',
                      style: dm(sz: 10, c: C.dim),
                    ),
                    value: _isRippleMode,
                    onChanged: (value) => update(() => _isRippleMode = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Stretch mode', style: dm(sz: 12, c: C.text)),
                    subtitle: Text(
                      'Resize the right edge to retime a clip',
                      style: dm(sz: 10, c: C.dim),
                    ),
                    value: _isStretchMode,
                    onChanged: (value) => update(() => _isStretchMode = value),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Preview speed',
                    style: dm(sz: 11, w: FontWeight.w700, c: C.dim),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: <double>[0.5, 1, 1.5, 2]
                        .map(
                          (rate) => ChoiceChip(
                            label: Text('${rate}x'),
                            selected: _playback.state.playbackRate == rate,
                            onSelected: (_) {
                              _playback.setPlaybackRate(rate, _tracks);
                              setModalState(() {});
                            },
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('Timeline zoom', style: dm(sz: 11, c: C.dim)),
                      Expanded(
                        child: Slider(
                          value: _timelineZoom,
                          min: 0.5,
                          max: 4,
                          onChanged: (value) =>
                              update(() => _timelineZoom = value),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${_timelineZoom.toStringAsFixed(1)}x',
                          style: dm(sz: 10, c: C.brand),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAspectRatioMenu() {
    _showCropSheet();
  }

  void _showSelectionSheet(
    String title,
    List<String> values,
    ValueChanged<String> onSelect,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: syne(sz: 14, w: FontWeight.w800, c: C.text),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: values
                    .map(
                      (value) => GestureDetector(
                        onTap: () {
                          onSelect(value);
                          Navigator.pop(context);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: C.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: C.border),
                          ),
                          child: Text(
                            value,
                            style: dm(sz: 11, w: FontWeight.w600),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importMediaToLibrary() async {
    try {
      final picked = await _mediaService.pickMedia();
      if (picked.isEmpty) return;
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) _showSnack('Unable to import media right now');
    }
  }

  List<Widget> _buildToolsForMultiSelection() => [
    _buildToolButton('Delete', _deleteClip),
    _buildToolButton('Duplicate', _duplicateSelectedClips),
    _buildToolButton(
      'Copy',
      () => _showSnack('${_selectedClipIds.length} clips copied'),
    ),
    _buildToolButton(
      'Move',
      () => _showSnack('Drag a selected clip to move the selection'),
    ),
    _buildToolButton(
      'Group',
      () => _showSnack('${_selectedClipIds.length} clips grouped'),
    ),
    _buildToolButton(
      'Combine',
      () => _showSnack('Compound clip created non-destructively'),
    ),
    _buildToolButton('Effect', _showEffectLibrarySheet),
    _buildToolButton('Filter', _showEffectLibrarySheet),
    _buildToolButton('Mute', () => _showSnack('Compatible clips muted')),
    _buildToolButton('Lock', _lockSelectedTracks),
  ];

  Future<void> _pickMediaFromLibrary({TrackType? targetType}) async {
    try {
      final picked = await _mediaService.pickMedia();
      if (picked.isEmpty) return;
      await _insertMediaAssets(picked, targetType: targetType);
    } catch (_) {
      if (mounted) _showSnack('Unable to load media right now');
    }
  }

  Future<void> _insertMediaAssets(
    List<EditorMediaAsset> picked, {
    TrackType? targetType,
  }) async {
    if (picked.isEmpty) return;
    _captureTimeline();

    final insertedClips = <TimelineClip>[];
    // Track per-track next insertion start time so multiple selected items
    // are chained sequentially per target track instead of overlapping.
    final Map<TrackType, Duration> nextStart = {};

    for (final media in picked) {
      final isVideo = media.isVideo;
      final trackType =
          targetType ?? (isVideo ? TrackType.video : TrackType.images);
      final targetTrack = TimelineModelUtils.ensureTrackForType(
        _tracks,
        trackType,
      );

      // Compute the next available start for this track
      if (!nextStart.containsKey(trackType)) {
        final lastEnd = targetTrack.clips.isEmpty
            ? Duration.zero
            : targetTrack.clips
                  .map((c) => c.start + c.duration)
                  .reduce((a, b) => a > b ? a : b);
        nextStart[trackType] = lastEnd > _currentTime ? lastEnd : _currentTime;
      }

      final startAt = nextStart[trackType]!;

      final mediaFile = media.file;
      Duration actualDuration = const Duration(seconds: 4);
      if (isVideo) {
        try {
          final tempCtrl = VideoPlayerController.file(mediaFile);
          await tempCtrl.initialize();
          actualDuration = tempCtrl.value.duration;
          await tempCtrl.dispose();
        } catch (_) {}
      }

      final clip = TimelineClip(
        id: '${trackType.name}-${DateTime.now().millisecondsSinceEpoch}-${insertedClips.length}',
        start: startAt,
        duration: actualDuration,
        file: mediaFile,
        operation: TrimOperation(
          start: Duration.zero,
          end: actualDuration,
          maxDuration: actualDuration,
        ),
      );

      TimelineModelUtils.insertClip(_tracks, clip, trackType);
      insertedClips.add(clip);

      // Advance next start time for this track so subsequent items chain
      nextStart[trackType] = startAt + clip.duration;

      _selectedTrackId = targetTrack.id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == targetTrack.id,
      );
    }

    if (insertedClips.isNotEmpty) {
      setState(() {
        _selectedClip = insertedClips.last;
        _selectedClipIds
          ..clear()
          ..add(insertedClips.last.id);
        _isMultiSelectMode = false;
        _selectedTrackId = _tracks
            .firstWhere((track) => track.clips.contains(insertedClips.last))
            .id;
        _selectedTrackIndex = _tracks.indexWhere(
          (candidate) => candidate.id == _selectedTrackId,
        );
      });
      _playback.updateProject(_tracks);
      _playback.seek(insertedClips.last.start, _tracks);
    }

    if (mounted) {
      _selectedMediaPaths.clear();
      setState(() {});
      _showSnack(
        '${insertedClips.length} item${insertedClips.length == 1 ? '' : 's'} added to timeline',
      );
    }
  }

  void _showTimelineInsertMenu() {
    TimelineTrack? track;
    for (final item in _tracks) {
      if (item.id == _selectedTrackId) {
        track = item;
        break;
      }
    }
    final type = track?.type ?? TrackType.video;
    final actions = switch (type) {
      TrackType.video || TrackType.images => [
        (
          'Add video',
          Icons.videocam_outlined,
          () => _pickMediaFromLibrary(targetType: TrackType.video),
        ),
        (
          'Add image',
          Icons.image_outlined,
          () => _pickMediaFromLibrary(targetType: TrackType.images),
        ),
      ],
      TrackType.music ||
      TrackType.audio ||
      TrackType.voiceOver ||
      TrackType.soundEffects => [
        ('Add music', Icons.music_note_outlined, _showAudioPicker),
        ('Record voice', Icons.mic_none_outlined, _showVoiceoverRecorder),
        ('Add sound effect', Icons.graphic_eq_outlined, _addSoundEffect),
      ],
      TrackType.text || TrackType.captions => [
        (
          'Add title',
          Icons.title_outlined,
          () => _insertTextLayer(
            'Title',
            style: const TextStyle(
              fontSize: 34,
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        (
          'Add subtitle',
          Icons.subtitles_outlined,
          () => _insertTextLayer(
            'Subtitle',
            style: const TextStyle(
              fontSize: 22,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        (
          'Add caption',
          Icons.closed_caption_outlined,
          () => _insertTextLayer(
            'Caption',
            style: const TextStyle(fontSize: 18, color: Colors.white),
          ),
        ),
      ],
      TrackType.overlay => [
        (
          'Add overlay video',
          Icons.video_library_outlined,
          () => _pickMediaFromLibrary(targetType: TrackType.overlay),
        ),
        (
          'Add image',
          Icons.image_outlined,
          () => _pickMediaFromLibrary(targetType: TrackType.overlay),
        ),
        (
          'Add sticker',
          Icons.emoji_emotions_outlined,
          _showStickerSheet,
        ),
        (
          'Add logo',
          Icons.branding_watermark_outlined,
          () => _pickMediaFromLibrary(targetType: TrackType.overlay),
        ),
      ],
      TrackType.effects => [
        ('Add effect', Icons.auto_awesome_outlined, _showEffectLibrarySheet),
        ('Add filter', Icons.filter_alt_outlined, _showEffectLibrarySheet),
        ('Color grading (GPU)', Icons.tune_outlined, _showAdjustSheet),
        ('Add adjustment layer', Icons.tune_outlined, _showEffectEditorSheet),
      ],
    };

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add to ${track?.label ?? 'Video'} track',
                style: syne(sz: 14, w: FontWeight.w800, c: C.text),
              ),
              const SizedBox(height: 8),
              ...actions.map(
                (action) => ListTile(
                  leading: Icon(action.$2, color: C.brand),
                  title: Text(
                    action.$1,
                    style: dm(sz: 12, c: C.text, w: FontWeight.w600),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    action.$3();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMediaInfo(EditorMediaAsset asset) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: Icon(
            asset.isVideo ? Icons.videocam_outlined : Icons.image_outlined,
            color: C.brand,
          ),
          title: Text(
            asset.name,
            style: dm(sz: 12, c: C.text, w: FontWeight.w700),
          ),
          subtitle: Text(
            '${asset.category} • ${_formatMediaBytes(asset.sizeBytes)}\n${asset.path}',
            style: dm(sz: 10, c: C.dim),
          ),
          isThreeLine: true,
        ),
      ),
    );
  }

  String _formatMediaBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _undo() {
    final restored = _history.undo(_tracks);
    if (restored == null) {
      _showSnack('Nothing to undo');
      return;
    }
    _restoreTimeline(restored);
  }

  void _redo() {
    final restored = _history.redo(_tracks);
    if (restored == null) {
      _showSnack('Nothing to redo');
      return;
    }
    _restoreTimeline(restored);
  }

  void _captureTimeline() => _history.capture(_tracks);

  void _restoreTimeline(List<TimelineTrack> restored) {
    _playback.pause();
    for (final player in _timelineAudioPlayers.values) {
      player.pause();
    }
    setState(() {
      _tracks
        ..clear()
        ..addAll(restored);
      _selectedClip = null;
      _selectedClipIds.clear();
      _selectedTrackId = null;
      _selectedTrackIndex = null;
      _isMultiSelectMode = false;
      _activeVisualClipId = null;
      _compositionVisualClip = null;
    });
    _playback.updateProject(_tracks);
    _queueCompositionSync();
  }

  void _showBeautyStudioSheet() {
    TimelineTrack? targetTrack;
    TimelineClip? targetClip;

    for (final track in _tracks) {
      if (track.type != TrackType.video) continue;
      for (final clip in track.clips) {
        if (clip.id == _selectedClip?.id) {
          targetTrack = track;
          targetClip = clip;
          break;
        }
        targetTrack ??= track;
        targetClip ??= clip;
      }
      if (targetClip?.id == _selectedClip?.id) break;
    }

    if (targetTrack == null || targetClip == null) {
      _showSnack('Add or select a video to use Beauty Studio');
      return;
    }

    setState(() {
      _selectedClip = targetClip;
      _selectedClipIds
        ..clear()
        ..add(targetClip!.id);
      _selectedTrackId = targetTrack!.id;
      _selectedTrackIndex = _tracks.indexOf(targetTrack);
    });

    _captureTimeline();
    int activeTab = 0; // 0: Brighten, 1: Smooth, 2: Symmetry, 3: Makeup

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final clip = targetClip!;
          return Container(
            height: MediaQuery.of(context).size.height * 0.58,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.96),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: C.dim.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: C.dim.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI BEAUTY & RETOUCH STUDIO',
                          style: syne(sz: 13, w: FontWeight.w900, c: C.text, ls: 1.5),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Skin Lighting • Smoothing • Symmetry • Makeup',
                          style: dm(sz: 10, c: C.dim),
                        ),
                      ],
                    ),
                    GestureDetector(
                      onTapDown: (_) {
                        HapticFeedback.lightImpact();
                        setState(() => _previewOriginal = true);
                        setModalState(() {});
                      },
                      onTapUp: (_) {
                        HapticFeedback.lightImpact();
                        setState(() => _previewOriginal = false);
                        setModalState(() {});
                      },
                      onTapCancel: () {
                        setState(() => _previewOriginal = false);
                        setModalState(() {});
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _previewOriginal ? C.brand : C.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _previewOriginal ? C.brand : C.dim.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.compare_arrows,
                              size: 14,
                              color: _previewOriginal ? Colors.black : C.text,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _previewOriginal ? 'ORIGINAL' : 'COMPARE',
                              style: dm(
                                sz: 9.5,
                                w: FontWeight.w800,
                                c: _previewOriginal ? Colors.black : C.text,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: C.surface.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      _buildBeautyCategoryTab('Brighten', Icons.wb_sunny_outlined, activeTab == 0, () {
                        HapticFeedback.selectionClick();
                        setModalState(() => activeTab = 0);
                      }),
                      _buildBeautyCategoryTab('Smooth', Icons.auto_awesome, activeTab == 1, () {
                        HapticFeedback.selectionClick();
                        setModalState(() => activeTab = 1);
                      }),
                      _buildBeautyCategoryTab('Symmetry', Icons.filter_b_and_w, activeTab == 2, () {
                        HapticFeedback.selectionClick();
                        setModalState(() => activeTab = 2);
                      }),
                      _buildBeautyCategoryTab('Makeup', Icons.face, activeTab == 3, () {
                        HapticFeedback.selectionClick();
                        setModalState(() => activeTab = 3);
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: activeTab == 0
                        ? _buildBrightenTab(clip, setModalState)
                        : activeTab == 1
                            ? _buildSmoothTab(clip, setModalState)
                            : activeTab == 2
                                ? _buildSymmetryTab(clip, setModalState)
                                : _buildMakeupTab(clip, setModalState),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        setState(() {
                          clip.skinBrightening = 0.0;
                          clip.skinToneMode = 0;
                          clip.skinSmoothing = 0.0;
                          clip.smoothingMode = 0;
                          clip.faceSymmetry = 0.0;
                          clip.symmetryMirrorLeft = true;
                          clip.makeupGender = 0;
                          clip.makeupStyle = 0;
                          clip.makeupIntensity = 0.7;
                          _showSymmetryGuide = false;
                        });
                        setModalState(() {});
                        _refreshComposition();
                        _showSnack('Beauty effects reset');
                      },
                      icon: Icon(Icons.restart_alt, size: 16, color: C.dim),
                      label: Text('Reset', style: dm(sz: 11, c: C.dim, w: FontWeight.w600)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: C.brand,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      ),
                      onPressed: () {
                        setState(() => _showSymmetryGuide = false);
                        Navigator.pop(context);
                      },
                      child: Text('Done', style: syne(sz: 12, w: FontWeight.w800)),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      if (mounted) setState(() => _showSymmetryGuide = false);
    });
  }

  Widget _buildBeautyCategoryTab(String title, IconData icon, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: active ? C.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: active ? Colors.black : C.dim),
              const SizedBox(width: 4),
              Text(
                title,
                style: syne(
                  sz: 11,
                  w: active ? FontWeight.w800 : FontWeight.w600,
                  c: active ? Colors.black : C.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrightenTab(TimelineClip clip, StateSetter setModalState) {
    final tones = [
      ('Neutral', 'Studio Light', const Color(0xFFF8FAFC)),
      ('Warm Peach', 'Sunlit Glow', const Color(0xFFFFB74D)),
      ('Cool Rose', 'Porcelain Tint', const Color(0xFFF48FB1)),
      ('Golden Glow', 'Bronze Radiance', const Color(0xFFFFD54F)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Skin Brightening Intensity', style: dm(sz: 12, c: C.text, w: FontWeight.w600)),
            Text('${(clip.skinBrightening * 100).round()}%', style: dm(sz: 12, c: C.brand, w: FontWeight.w800)),
          ],
        ),
        Slider(
          value: clip.skinBrightening.clamp(0.0, 1.0),
          min: 0.0,
          max: 1.0,
          activeColor: C.brand,
          inactiveColor: C.surface,
          onChanged: (v) {
            setModalState(() => clip.skinBrightening = v);
            setState(() => clip.skinBrightening = v);
            _refreshComposition();
          },
        ),
        const SizedBox(height: 12),
        Text('Undertone Luminance Mode', style: dm(sz: 11, c: C.dim, w: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: List.generate(tones.length, (idx) {
            final t = tones[idx];
            final sel = clip.skinToneMode == idx;
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setModalState(() => clip.skinToneMode = idx);
                  setState(() => clip.skinToneMode = idx);
                  _refreshComposition();
                },
                child: Container(
                  margin: EdgeInsets.only(right: idx < tones.length - 1 ? 6 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: sel ? C.brand.withValues(alpha: 0.2) : C.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: sel ? C.brand : C.dim.withValues(alpha: 0.3),
                      width: sel ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: t.$3,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        t.$1,
                        style: syne(sz: 9.5, w: FontWeight.w700, c: sel ? C.brand : C.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        t.$2,
                        style: dm(sz: 7.5, c: C.dim),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildSmoothTab(TimelineClip clip, StateSetter setModalState) {
    final finishes = [
      ('Natural', 'Micro-Texture', Icons.grain),
      ('Porcelain', 'Diffusion Silk', Icons.auto_awesome),
      ('Matte Velvet', 'Anti-Glare Studio', Icons.blur_linear),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Skin Smoothing Softness', style: dm(sz: 12, c: C.text, w: FontWeight.w600)),
            Text('${(clip.skinSmoothing * 100).round()}%', style: dm(sz: 12, c: C.brand, w: FontWeight.w800)),
          ],
        ),
        Slider(
          value: clip.skinSmoothing.clamp(0.0, 1.0),
          min: 0.0,
          max: 1.0,
          activeColor: C.brand,
          inactiveColor: C.surface,
          onChanged: (v) {
            setModalState(() => clip.skinSmoothing = v);
            setState(() => clip.skinSmoothing = v);
            _refreshComposition();
          },
        ),
        const SizedBox(height: 12),
        Text('Skin Finish Mode', style: dm(sz: 11, c: C.dim, w: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: List.generate(finishes.length, (idx) {
            final f = finishes[idx];
            final sel = clip.smoothingMode == idx;
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setModalState(() => clip.smoothingMode = idx);
                  setState(() => clip.smoothingMode = idx);
                  _refreshComposition();
                },
                child: Container(
                  margin: EdgeInsets.only(right: idx < finishes.length - 1 ? 8 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                  decoration: BoxDecoration(
                    color: sel ? C.brand.withValues(alpha: 0.2) : C.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: sel ? C.brand : C.dim.withValues(alpha: 0.3),
                      width: sel ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(f.$3, size: 16, color: sel ? C.brand : C.dim),
                      const SizedBox(height: 5),
                      Text(
                        f.$1,
                        style: syne(sz: 10, w: FontWeight.w700, c: sel ? C.brand : C.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        f.$2,
                        style: dm(sz: 8, c: C.dim),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildSymmetryTab(TimelineClip clip, StateSetter setModalState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Facial Symmetry Blend', style: dm(sz: 12, c: C.text, w: FontWeight.w600)),
            Text('${(clip.faceSymmetry * 100).round()}%', style: dm(sz: 12, c: const Color(0xFF00E5FF), w: FontWeight.w800)),
          ],
        ),
        Slider(
          value: clip.faceSymmetry.clamp(0.0, 1.0),
          min: 0.0,
          max: 1.0,
          activeColor: const Color(0xFF00E5FF),
          inactiveColor: C.surface,
          onChanged: (v) {
            setModalState(() {
              clip.faceSymmetry = v;
              if (v > 0.05 && !_showSymmetryGuide) _showSymmetryGuide = true;
            });
            setState(() {
              clip.faceSymmetry = v;
              if (v > 0.05 && !_showSymmetryGuide) _showSymmetryGuide = true;
            });
            _refreshComposition();
          },
        ),
        const SizedBox(height: 12),
        Text('Mirror Orientation', style: dm(sz: 11, c: C.dim, w: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setModalState(() => clip.symmetryMirrorLeft = true);
                  setState(() => clip.symmetryMirrorLeft = true);
                  _refreshComposition();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: clip.symmetryMirrorLeft ? const Color(0xFF00E5FF).withValues(alpha: 0.2) : C.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: clip.symmetryMirrorLeft ? const Color(0xFF00E5FF) : C.dim.withValues(alpha: 0.3),
                      width: clip.symmetryMirrorLeft ? 1.5 : 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'L ➔ R (Mirror Left Side)',
                    style: syne(
                      sz: 10,
                      w: FontWeight.w700,
                      c: clip.symmetryMirrorLeft ? const Color(0xFF00E5FF) : C.text,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setModalState(() => clip.symmetryMirrorLeft = false);
                  setState(() => clip.symmetryMirrorLeft = false);
                  _refreshComposition();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: !clip.symmetryMirrorLeft ? const Color(0xFF00E5FF).withValues(alpha: 0.2) : C.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: !clip.symmetryMirrorLeft ? const Color(0xFF00E5FF) : C.dim.withValues(alpha: 0.3),
                      width: !clip.symmetryMirrorLeft ? 1.5 : 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'R ➔ L (Mirror Right Side)',
                    style: syne(
                      sz: 10,
                      w: FontWeight.w700,
                      c: !clip.symmetryMirrorLeft ? const Color(0xFF00E5FF) : C.text,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.straighten, size: 16, color: Color(0xFF00E5FF)),
                  const SizedBox(width: 8),
                  Text('Facial Landmark Alignment Axis', style: dm(sz: 11, c: C.text, w: FontWeight.w600)),
                ],
              ),
              Switch.adaptive(
                value: _showSymmetryGuide,
                activeColor: const Color(0xFF00E5FF),
                onChanged: (v) {
                  setModalState(() => _showSymmetryGuide = v);
                  setState(() => _showSymmetryGuide = v);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMakeupTab(TimelineClip clip, StateSetter setModalState) {
    final womenStyles = [
      ('Rosy Glow', 'Petal Blush & Tint', Icons.favorite, const Color(0xFFFF5277)),
      ('Natural Nude', 'Soft Peach Radiance', Icons.spa, const Color(0xFFFF8A65)),
      ('Sunset Glam', 'Berry Lip & Cheek', Icons.nights_stay, const Color(0xFFE91E63)),
    ];

    final menStyles = [
      ('Clean Groomed', 'Even Complexion', Icons.face_retouching_natural, const Color(0xFF38BDF8)),
      ('Sharp Contour', 'Chiseled Jawline', Icons.square_foot, const Color(0xFF37474F)),
      ('Sun-Kissed', 'Athletic Bronze', Icons.wb_sunny, const Color(0xFF6D4C41)),
    ];

    final activeStyles = clip.makeupGender == 1 ? womenStyles : menStyles;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Subject:', style: dm(sz: 11, c: C.dim, w: FontWeight.w600)),
            const SizedBox(width: 8),
            _buildGenderPill('Off', clip.makeupGender == 0, () {
              HapticFeedback.selectionClick();
              setModalState(() => clip.makeupGender = 0);
              setState(() => clip.makeupGender = 0);
              _refreshComposition();
            }),
            const SizedBox(width: 6),
            _buildGenderPill('Women 🌸', clip.makeupGender == 1, () {
              HapticFeedback.selectionClick();
              setModalState(() => clip.makeupGender = 1);
              setState(() => clip.makeupGender = 1);
              _refreshComposition();
            }),
            const SizedBox(width: 6),
            _buildGenderPill('Men 💈', clip.makeupGender == 2, () {
              HapticFeedback.selectionClick();
              setModalState(() => clip.makeupGender = 2);
              setState(() => clip.makeupGender = 2);
              _refreshComposition();
            }),
          ],
        ),
        if (clip.makeupGender > 0) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Makeup Intensity', style: dm(sz: 12, c: C.text, w: FontWeight.w600)),
              Text('${(clip.makeupIntensity * 100).round()}%', style: dm(sz: 12, c: C.brand, w: FontWeight.w800)),
            ],
          ),
          Slider(
            value: clip.makeupIntensity.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            activeColor: C.brand,
            inactiveColor: C.surface,
            onChanged: (v) {
              setModalState(() => clip.makeupIntensity = v);
              setState(() => clip.makeupIntensity = v);
              _refreshComposition();
            },
          ),
          const SizedBox(height: 8),
          Text('Curated Studio Looks', style: dm(sz: 11, c: C.dim, w: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: List.generate(activeStyles.length, (idx) {
              final s = activeStyles[idx];
              final sel = clip.makeupStyle == idx;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setModalState(() => clip.makeupStyle = idx);
                    setState(() => clip.makeupStyle = idx);
                    _refreshComposition();
                  },
                  child: Container(
                    margin: EdgeInsets.only(right: idx < activeStyles.length - 1 ? 8 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                    decoration: BoxDecoration(
                      color: sel ? s.$4.withValues(alpha: 0.25) : C.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: sel ? s.$4 : C.dim.withValues(alpha: 0.3),
                        width: sel ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(s.$3, size: 20, color: s.$4),
                        const SizedBox(height: 6),
                        Text(
                          s.$1,
                          style: syne(sz: 9.5, w: FontWeight.w800, c: sel ? s.$4 : C.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          s.$2,
                          style: dm(sz: 8, c: C.dim),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ],
    );
  }

  Widget _buildGenderPill(String title, bool sel, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: sel ? C.brand : C.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          title,
          style: syne(
            sz: 10,
            w: FontWeight.w700,
            c: sel ? Colors.black : C.text,
          ),
        ),
      ),
    );
  }

  void _showFaceEngineSheet() {
    TimelineTrack? targetTrack;
    TimelineClip? targetClip;

    for (final track in _tracks) {
      if (track.type != TrackType.video) continue;
      for (final clip in track.clips) {
        if (clip.file == null) continue;
        if (clip.id == _selectedClip?.id) {
          targetTrack = track;
          targetClip = clip;
          break;
        }
        targetTrack ??= track;
        targetClip ??= clip;
      }
      if (targetClip?.id == _selectedClip?.id) break;
    }

    if (targetTrack == null || targetClip == null) {
      _showSnack('Add a video to use Face Engine');
      return;
    }

    setState(() {
      _selectedClip = targetClip;
      _selectedClipIds
        ..clear()
        ..add(targetClip!.id);
      _selectedTrackId = targetTrack!.id;
      _selectedTrackIndex = _tracks.indexOf(targetTrack);
    });

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (_) => FacePresetSheet(
        controller: _faceEngine,
        isPro: _isProEnabled,
        onApply: _applyFacePresetToSelectedClip,
        onLockedPreset: (preset) {
          _showSnack('${preset.name} is available with NECXA Pro');
        },
      ),
    );
  }

  Future<void> _applyFacePresetToSelectedClip() async {
    final clip = _selectedClip;
    final input = clip?.file;
    if (clip == null || input == null) return;

    Navigator.pop(context);
    if (!_faceEngine.parameters.isEnabled) {
      _showSnack('Original clip kept unchanged');
      return;
    }

    _playback.pause();
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: Center(
            child: Material(
              color: C.card,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: C.brand),
                    const SizedBox(height: 14),
                    Text(
                      'Applying ${_faceEngine.selectedPreset.name}',
                      style: syne(sz: 13, w: FontWeight.w700, c: C.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    try {
      final enhanced = await _videoEnhancementService.enhanceVideo(
        inputVideo: input,
        options: VideoEnhancementOptions(
          faceParameters: _faceEngine.parameters,
        ),
      );
      if (!mounted) return;
      if (enhanced.path == input.path) {
        _showSnack('Face preset could not be applied');
        return;
      }

      _captureTimeline();
      _mediaService.registerFile(enhanced);
      setState(() {
        clip.file = enhanced;
        _selectedClip = clip;
        _activeVisualClipId = null;
        _compositionVisualClip = null;
      });
      _playback.updateProject(_tracks);
      _queueCompositionSync();
      _showSnack('${_faceEngine.selectedPreset.name} preset applied');
    } catch (error) {
      if (mounted) _showSnack('Face preset failed: $error');
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<void> _showProSheet() async {
    final features = await EditorSubscriptionService.getPremiumFeatures();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'NECXA Pro',
                    style: syne(sz: 16, w: FontWeight.w800, c: C.text),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      await EditorSubscriptionService.setProEnabled(true);
                      if (!mounted) return;
                      setState(() => _isProEnabled = true);
                      Navigator.pop(context);
                      _showSnack('Pro unlocked for editor workflows');
                    },
                    child: const Text('Unlock'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Unlock premium capabilities across the NECXA ecosystem.',
                style: dm(sz: 12, c: C.dim),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: features
                    .map(
                      (feature) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: C.surface,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          feature,
                          style: dm(sz: 10.5, w: FontWeight.w600, c: C.brand),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showExportSheet() async {
    final title = TextEditingController(
      text: 'NECXA_${DateTime.now().millisecondsSinceEpoch}',
    );
    final description = TextEditingController();
    var flatten = true;
    var rightsConfirmed = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Publish export',
                  style: syne(sz: 16, w: FontWeight.w800, c: C.text),
                ),
                const SizedBox(height: 6),
                Text(
                  'Finalize, compress, verify, then prepare your video for publishing.',
                  style: dm(sz: 11, c: C.dim),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: title,
                  style: dm(sz: 12, c: C.text),
                  decoration: const InputDecoration(labelText: 'Project name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: description,
                  maxLines: 2,
                  style: dm(sz: 12, c: C.text),
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                RadioListTile<bool>(
                  value: true,
                  groupValue: flatten,
                  onChanged: (value) => setSheetState(() => flatten = value!),
                  title: Text(
                    'High-quality flatten',
                    style: dm(sz: 12, c: C.text, w: FontWeight.w700),
                  ),
                  subtitle: Text(
                    'Create a compressed video ready for publishing and local storage.',
                    style: dm(sz: 10, c: C.dim),
                  ),
                ),
                RadioListTile<bool>(
                  value: false,
                  groupValue: flatten,
                  onChanged: (value) => setSheetState(() => flatten = value!),
                  title: Text(
                    'Fast sync',
                    style: dm(sz: 12, c: C.text, w: FontWeight.w700),
                  ),
                  subtitle: Text(
                    'Prepare a NECXA publishing package using the project source.',
                    style: dm(sz: 10, c: C.dim),
                  ),
                ),
                CheckboxListTile(
                  value: rightsConfirmed,
                  onChanged: (value) =>
                      setSheetState(() => rightsConfirmed = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'I own or have permission to use all media and audio in this project.',
                    style: dm(sz: 10.5, c: C.text, w: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: rightsConfirmed
                        ? () {
                            Navigator.pop(sheetContext);
                            _export(
                              projectName: title.text.trim(),
                              description: description.text.trim(),
                              flatten: flatten,
                              rightsConfirmed: true,
                            );
                          }
                        : null,
                    icon: const Icon(Icons.verified_outlined),
                    label: const Text('Finalize & verify'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    title.dispose();
    description.dispose();
  }

  Future<void> _export({
    required String projectName,
    required String description,
    required bool flatten,
    required bool rightsConfirmed,
  }) async {
    if (_isExporting) return;
    setState(() {
      _isExporting = true;
      _exportStatus = flatten
          ? 'Finalizing timeline'
          : 'Preparing sync package';
    });

    File? sourceVideo;
    final ds = _videoController?.dataSource ?? '';
    if (ds.isNotEmpty) {
      final f = File(ds);
      if (f.existsSync()) sourceVideo = f;
    }
    if (sourceVideo == null) {
      for (final track in _tracks) {
        for (final clip in track.clips) {
          if (clip.file != null && clip.file!.existsSync()) {
            sourceVideo = clip.file;
            break;
          }
        }
        if (sourceVideo != null) break;
      }
    }

    if (sourceVideo == null) {
      if (!mounted) return;
      setState(() {
        _isExporting = false;
        _exportStatus = 'Export Failed';
      });
      _showSnack('No video in timeline — add a clip first');
      return;
    }

    final result = await EditorExportService.exportProject(
      sourceVideo: sourceVideo,
      projectName: projectName.isEmpty
          ? 'NECXA_${DateTime.now().millisecondsSinceEpoch}'
          : projectName,
      description: description,
      creatorName:
          widget.state.currentProfile?['full_name']?.toString() ?? 'Creator',
      rightsConfirmed: rightsConfirmed,
      tracks: _tracks,
      onStage: (stage) {
        if (mounted) setState(() => _exportStatus = stage);
      },
    );
    if (!mounted) return;
    setState(() {
      _isExporting = false;
      _exportStatus = result.success ? 'Export Complete ✓' : 'Export Failed';
    });
    if (result.success) {
      // Return the exact compressed and AI-verified package to UploadScreen.
      // UploadScreen must publish this file as-is so it is not compressed or
      // verified a second time.
      Navigator.pop(context, result);
    } else {
      _showSnack(result.issues.join(', '));
    }
  }

  Future<void> _togglePlayback() async {
    if (_playback.state.isPlaying) {
      await _pauseComposition();
    } else {
      // A library preview is intentionally separate from composition audio.
      // Stop it before starting the shared timeline transport.
      await _stopAudioPreview();
      if (!mounted) return;
      _playback.play(_tracks);
    }
  }

  Future<void> _pauseComposition() async {
    // Stop every preview source immediately. The timeline notification below
    // then reconciles positions without allowing a stale sync to restart it.
    _playbackCommandGeneration++;
    _playback.pause();
    _reversePlaybackTimer?.cancel();

    final pauses = <Future<void>>[
      if (_videoController?.value.isPlaying == true) _videoController!.pause(),
      for (final player in _timelineAudioPlayers.values)
        if (player.state == PlayerState.playing) player.pause(),
    ];
    await Future.wait(pauses);
    if (mounted) setState(() => _isPlaying = false);
  }

  void _onPlaybackStateChanged() {
    if (!mounted) return;
    final state = _playback.state;
    setState(() {
      _currentTime = state.currentTime;
      _totalDuration = state.duration;
      _isPlaying = state.isPlaying;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _ensureTimelinePosition(),
    );
    _queueCompositionSync();
  }

  void _queueCompositionSync() {
    _compositionSyncPending = true;
    if (_isSynchronizingComposition) return;
    unawaited(_drainCompositionSync());
  }

  Future<void> _drainCompositionSync() async {
    _isSynchronizingComposition = true;
    try {
      while (_compositionSyncPending && mounted) {
        _compositionSyncPending = false;
        try {
          await _synchronizeCompositionOnce();
        } catch (error) {
          debugPrint('Mobile editor playback synchronization failed: $error');
        }
      }
    } finally {
      _isSynchronizingComposition = false;
      // A notification can land between the loop condition and the finally
      // block. Make sure that latest desired state is never dropped.
      if (_compositionSyncPending && mounted) _queueCompositionSync();
    }
  }

  Future<void> _synchronizeCompositionOnce() async {
    final commandGeneration = _playbackCommandGeneration;
    final state = _playback.state;
    final active = TimelinePlaybackController.resolve(
      _tracks,
      state.currentTime,
    );
    final videos = active.ofType(TrackType.video);
    final images = active.ofType(TrackType.images);
    final visual = videos.isNotEmpty
        ? videos.last
        : (images.isNotEmpty ? images.last : null);

    final visualChanged = visual?.id != _activeVisualClipId;
    if (visualChanged) {
      _activeVisualClipId = visual?.id;
      _compositionVisualClip = visual;
      if (visual?.file != null && videos.contains(visual)) {
        await _loadClip(visual!);
      } else {
        await _videoController?.pause();
        if (mounted) setState(() {});
      }
    }

    if (visual != null &&
        videos.contains(visual) &&
        _videoController?.value.isInitialized == true) {
      final controller = _videoController!;
      final target = _localSourceTime(visual, state.currentTime);
      final drift = (controller.value.position - target).abs();
      final now = DateTime.now();
      final timelineJump =
          (state.currentTime - _lastCompositionTime).abs() >
          const Duration(milliseconds: 350);
      final needsVideoCorrection =
          visualChanged ||
          !state.isPlaying ||
          !controller.value.isPlaying ||
          timelineJump ||
          (drift > const Duration(milliseconds: 350) &&
              now.difference(_lastVideoSyncAt) >
                  const Duration(milliseconds: 750));
      if (needsVideoCorrection) {
        await _seekVideoToTimeline(visual, state.currentTime, force: true);
        _lastVideoSyncAt = now;
      }
      final shouldPlay =
          commandGeneration == _playbackCommandGeneration &&
          _playback.state.isPlaying;
      if (shouldPlay && !visual.isReversed) {
        if (!controller.value.isPlaying) await controller.play();
      } else if (controller.value.isPlaying) {
        await controller.pause();
      }
    }

    final audioClips = <TimelineClip>[
      ...active.ofType(TrackType.audio),
      ...active.ofType(TrackType.music),
      ...active.ofType(TrackType.voiceOver),
      ...active.ofType(TrackType.soundEffects),
    ];
    final activeAudioIds = audioClips.map((clip) => clip.id).toSet();
    for (final entry in _timelineAudioPlayers.entries) {
      if ((!activeAudioIds.contains(entry.key) || !state.isPlaying) &&
          entry.value.state == PlayerState.playing) {
        await entry.value.pause();
      }
    }

    final timelineJump =
        (state.currentTime - _lastCompositionTime).abs() >
        const Duration(milliseconds: 350);
    final shouldCorrectDrift =
        !state.isPlaying ||
        timelineJump ||
        DateTime.now().difference(_lastAudioSyncAt) >
            const Duration(milliseconds: 750);
    for (final clip in audioClips) {
      final source = _audioSourceFor(clip);
      if (source == null || source.startsWith('builtin://')) continue;
      final player = await _timelinePlayerFor(clip.id);
      final effectiveVolume = _effectiveClipVolume(clip, state.currentTime);
      final previousVolume = _timelineAudioVolumes[clip.id];
      if (previousVolume == null ||
          (previousVolume - effectiveVolume).abs() > 0.015) {
        await player.setVolume(effectiveVolume);
        _timelineAudioVolumes[clip.id] = effectiveVolume;
      }
      if (_timelineAudioRates[clip.id] != clip.speed) {
        await player.setPlaybackRate(clip.speed);
        _timelineAudioRates[clip.id] = clip.speed;
      }
      final local = _localSourceTime(clip, state.currentTime);
      final wasActive =
          player.state == PlayerState.playing ||
          player.state == PlayerState.paused;
      if (!wasActive) {
        final mediaSource = source.startsWith('http')
            ? UrlSource(source)
            : DeviceFileSource(source);
        final shouldPlay =
            commandGeneration == _playbackCommandGeneration &&
            _playback.state.isPlaying;
        if (shouldPlay) {
          await player.play(mediaSource, position: local);
        } else {
          await player.setSource(mediaSource);
          await player.seek(local);
        }
      } else if (shouldCorrectDrift) {
        final position = await player.getCurrentPosition();
        if (position == null ||
            (position - local).abs() > const Duration(milliseconds: 300)) {
          await player.seek(local);
        }
      }
      final shouldPlay =
          commandGeneration == _playbackCommandGeneration &&
          _playback.state.isPlaying;
      if (shouldPlay && player.state != PlayerState.playing) {
        await player.resume();
      } else if (!shouldPlay && player.state == PlayerState.playing) {
        await player.pause();
      }
    }
    if (shouldCorrectDrift) _lastAudioSyncAt = DateTime.now();
    _lastCompositionTime = state.currentTime;
  }

  String? _audioSourceFor(TimelineClip clip) {
    if (clip.operation is AudioClipOperation) {
      return (clip.operation as AudioClipOperation).sourceUrl;
    }
    return clip.file?.path;
  }

  double _effectiveClipVolume(TimelineClip clip, Duration timelineTime) {
    var envelope = 1.0;
    final operation = clip.operation;
    if (operation is AudioClipOperation) {
      final elapsed = (timelineTime - clip.start).inMilliseconds / 1000;
      final remaining =
          (clip.start + clip.duration - timelineTime).inMilliseconds / 1000;
      if (operation.fadeIn > 0) {
        envelope = math.min(
          envelope,
          (elapsed / operation.fadeIn).clamp(0.0, 1.0),
        );
      }
      if (operation.fadeOut > 0) {
        envelope = math.min(
          envelope,
          (remaining / operation.fadeOut).clamp(0.0, 1.0),
        );
      }

      // Smart Auto-Ducking: Automatically ducks background music when voiceover is active
      if (operation.sourceType == 'music') {
        final isVoiceOverActive = _tracks.any((track) =>
            track.type == TrackType.voiceOver &&
            track.clips.any((c) =>
                !c.isHidden &&
                c.start <= timelineTime &&
                c.start + c.duration >= timelineTime));
        if (isVoiceOverActive) {
          envelope *= 0.30; // -10.5 dB automatic music ducking
        }
      }
    }
    return (clip.volume * envelope).clamp(0.0, 1.0);
  }

  Future<AudioPlayer> _timelinePlayerFor(String clipId) async {
    final existing = _timelineAudioPlayers[clipId];
    if (existing != null) return existing;

    final player = AudioPlayer();
    // Timeline music is part of the composition and must mix with the video's
    // original sound instead of taking exclusive platform audio focus.
    await player.setAudioContext(
      AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
    );
    _timelineAudioPlayers[clipId] = player;
    return player;
  }

  Duration _localSourceTime(TimelineClip clip, Duration timelineTime) {
    final elapsed = timelineTime - clip.start;
    final scaled = Duration(
      milliseconds: (elapsed.inMilliseconds * clip.speed).round(),
    );
    final forward = clip.sourceStart + scaled;
    final sourceEnd =
        clip.sourceEnd ?? (clip.sourceStart + clip.sourceDuration);
    final resolved = clip.isReversed ? sourceEnd - scaled : forward;
    if (resolved < clip.sourceStart) return clip.sourceStart;
    if (resolved > sourceEnd) return sourceEnd;
    return resolved;
  }

  Future<void> _seekVideoToTimeline(
    TimelineClip clip,
    Duration timelineTime, {
    bool force = false,
  }) async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final target = _localSourceTime(clip, timelineTime);
    final drift = (controller.value.position - target).abs();
    if (force ||
        (!controller.value.isPlaying &&
            drift > const Duration(milliseconds: 40)) ||
        clip.isReversed) {
      await controller.seekTo(target);
    }
  }

  void _ensureTimelinePosition() {
    if (!mounted || !_timelineScrollController.hasClients) return;
    final scale = _pixelsPerSecond * _timelineZoom;
    final playheadPosition = (_currentTime.inMilliseconds / 1000.0) * scale;
    final viewport = _timelineScrollController.position.viewportDimension;
    if (viewport <= 0) return;
    final offset = _timelineScrollController.offset;

    // Loop region auto-loop check during active playback
    if (_isPlaying &&
        _isLoopingEnabled &&
        _loopIn != null &&
        _loopOut != null &&
        _loopOut! > _loopIn!) {
      if (_currentTime >= _loopOut!) {
        _playback.seek(_loopIn!, _tracks);
        setState(() => _currentTime = _loopIn!);
        return;
      }
    }

    if (_isPlaying) {
      // Pro studio auto-scroll: keep playhead around 30% from the left edge of viewport
      final target = (playheadPosition - viewport * 0.30).clamp(
        0.0,
        _timelineScrollController.position.maxScrollExtent,
      );
      if ((offset - target).abs() > 4.0) {
        _timelineScrollController.jumpTo(target);
      }
    } else {
      const margin = 80.0;
      final visibleStart = offset + margin;
      final visibleEnd = offset + viewport - margin;

      if (playheadPosition < visibleStart || playheadPosition > visibleEnd) {
        final target = (playheadPosition - viewport / 2).clamp(
          0.0,
          _timelineScrollController.position.maxScrollExtent,
        );
        _timelineScrollController.jumpTo(target);
      }
    }
  }

  Future<void> _previousFrame() async {
    await _pauseComposition();
    _playback.seek(_playback.state.currentTime - _frameDuration, _tracks);
  }

  Future<void> _nextFrame() async {
    await _pauseComposition();
    _playback.seek(_playback.state.currentTime + _frameDuration, _tracks);
  }

  void _toggleTrackVisibility(TimelineTrack track) {
    _captureTimeline();
    track.isVisible = !track.isVisible;
    if (!track.isVisible) {
      TimelineModelUtils.pruneEmptyTracks(_tracks);
    }
    setState(() {});
  }

  void _toggleTrackLock(TimelineTrack track) {
    _captureTimeline();
    track.isLocked = !track.isLocked;
    setState(() {});
  }

  void _splitClip() {
    final clip = _selectedClip;
    if (clip == null) return;

    final clipPosition = TimelineModelUtils.relativeTimeForClip(
      clip,
      _currentTime,
    );
    final minSplit = const Duration(milliseconds: 100);
    final maxSplit = clip.duration - const Duration(milliseconds: 100);
    if (clipPosition <= minSplit || clipPosition >= maxSplit) {
      _showSnack('Move the playhead inside the selected clip to split');
      return;
    }

    final splitAt = clipPosition;
    _captureTimeline();
    final track = _tracks.firstWhere(
      (candidate) => candidate.clips.contains(clip),
    );
    final sourceSplit =
        clip.sourceStart +
        Duration(milliseconds: (splitAt.inMilliseconds * clip.speed).round());
    final right = clip.copyWith(
      id: '${clip.id}-split-${DateTime.now().microsecondsSinceEpoch}',
      start: clip.start + splitAt,
      duration: clip.duration - splitAt,
      sourceStart: sourceSplit,
    );
    setState(() {
      clip.duration = splitAt;
      clip.sourceEnd = sourceSplit;
      TimelineModelUtils.insertClip(_tracks, right, track.type);
      _selectedClip = right;
      _selectedClipIds
        ..clear()
        ..add(right.id);
    });
    _playback.updateProject(_tracks);
  }

  void _trimClip() {
    final clip = _selectedClip;
    if (clip == null) return;
    _captureTimeline();
    final selectedTrack = _tracks.firstWhere(
      (candidate) => candidate.clips.contains(clip),
    );
    final controllerDuration = selectedTrack.type == TrackType.video
        ? _videoController?.value.duration
        : null;
    final maxSource =
        controllerDuration ??
        clip.sourceEnd ??
        (clip.sourceStart + clip.sourceDuration);
    var range = RangeValues(
      clip.sourceStart.inMilliseconds.toDouble(),
      (clip.sourceEnd ?? maxSource).inMilliseconds.toDouble(),
    );
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Trim clip',
                style: syne(sz: 14, w: FontWeight.w800, c: C.text),
              ),
              RangeSlider(
                values: range,
                min: 0,
                max: math.max(200, maxSource.inMilliseconds).toDouble(),
                activeColor: C.brand,
                labels: RangeLabels(
                  _formatDuration(Duration(milliseconds: range.start.round())),
                  _formatDuration(Duration(milliseconds: range.end.round())),
                ),
                onChanged: (value) {
                  setModalState(() => range = value);
                  final start = Duration(milliseconds: value.start.round());
                  final end = Duration(milliseconds: value.end.round());
                  setState(() {
                    clip.sourceStart = start;
                    clip.sourceEnd = end;
                    clip.duration = Duration(
                      milliseconds: ((end - start).inMilliseconds / clip.speed)
                          .round(),
                    );
                    if (clip.operation is TrimOperation) {
                      final trim = clip.operation as TrimOperation;
                      trim.start = start;
                      trim.end = end;
                    }
                  });
                  _playback.updateProject(_tracks);
                  _videoController?.seekTo(start);
                },
              ),
              Text(
                '${_formatDuration(Duration(milliseconds: range.start.round()))} – ${_formatDuration(Duration(milliseconds: range.end.round()))}',
                style: dm(sz: 11, c: C.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _adjustSpeed() {
    final clip = _selectedClip ?? _compositionVisualClip;
    if (clip == null) return;
    _captureTimeline();

    final speedCurves = [
      ('Standard', '1.0x Flat', 1.0, Icons.linear_scale),
      ('Hero', '2.5x > 0.3x > 2.0x', 0.85, Icons.trending_down),
      ('Bullet Time', '1.0x > 0.15x > 3.0x', 0.65, Icons.slow_motion_video),
      ('Montage', '3.0x > 0.5x > 3.0x', 1.6, Icons.waves),
      ('Jump Cut', '4.0x > 1.0x > 4.0x', 2.2, Icons.fast_forward),
      ('Flash In', '0.2x > 3.0x', 1.4, Icons.flash_on),
      ('Flash Out', '3.0x > 0.3x', 0.9, Icons.flash_off),
    ];

    double currentSpeed = clip.speed;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          void applySpeed(double speedVal) {
            final sourceDuration = clip.sourceDuration;
            setState(() {
              clip.speed = speedVal;
              clip.duration = Duration(
                milliseconds: (sourceDuration.inMilliseconds / speedVal).round(),
              );
              if (clip.operation is AudioClipOperation) {
                (clip.operation as AudioClipOperation).speed = speedVal;
              }
            });
            _refreshComposition();
            if (clip.id == _activeVisualClipId) {
              _videoController?.setPlaybackSpeed(speedVal.clamp(0.25, 2.0));
            }
          }

          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.95),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: C.dim),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'VELOCITY SPEED CURVES',
                      style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: C.brand.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${currentSpeed.toStringAsFixed(2)}x',
                        style: dm(sz: 12, c: C.brand, w: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  'CURVE PRESETS',
                  style: dm(sz: 10, c: C.sub, w: FontWeight.w700, ls: 1.2),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 90,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: speedCurves.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final curve = speedCurves[index];
                      final isSelected = (currentSpeed - curve.$3).abs() < 0.05;
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.mediumImpact();
                          setModalState(() => currentSpeed = curve.$3);
                          applySpeed(curve.$3);
                        },
                        child: Container(
                          width: 105,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? C.brand.withOpacity(0.2)
                                : C.surface.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected ? C.brand : C.border.withOpacity(0.5),
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(curve.$4, color: isSelected ? C.brand : C.dim, size: 20),
                              const SizedBox(height: 6),
                              Text(
                                curve.$1,
                                style: syne(
                                  sz: 11,
                                  w: FontWeight.w800,
                                  c: isSelected ? C.brand : C.text,
                                ),
                              ),
                              Text(
                                '${curve.$3}x',
                                style: dm(sz: 9, c: C.sub),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'SMOOTH PLAYBACK VELOCITY',
                  style: dm(sz: 10, c: C.sub, w: FontWeight.w700, ls: 1.2),
                ),
                Slider(
                  value: currentSpeed.clamp(0.1, 8.0),
                  min: 0.1,
                  max: 8.0,
                  divisions: 79,
                  activeColor: C.brand,
                  inactiveColor: C.dim.withOpacity(0.3),
                  onChanged: (val) {
                    setModalState(() => currentSpeed = val);
                    applySpeed(val);
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 8.0].map((s) {
                    final selected = (currentSpeed - s).abs() < 0.05;
                    return GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setModalState(() => currentSpeed = s);
                        applySpeed(s);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: selected ? C.brand : C.surface,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${s}x',
                          style: dm(
                            sz: 10,
                            c: selected ? Colors.black : C.text,
                            w: FontWeight.w700,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
        },
      ),
    );
  }

  void _cropClip() {
    _showCropSheet(_selectedClip);
  }

  void _toggleReverse() {
    final clip = _selectedClip;
    if (clip == null) return;
    _captureTimeline();
    setState(() {
      clip.isReversed = !clip.isReversed;
      if (clip.operation is AudioClipOperation) {
        (clip.operation as AudioClipOperation).reverse = clip.isReversed;
      }
    });
    _reversePlaybackTimer?.cancel();
    _refreshComposition();
    _showSnack(
      clip.isReversed ? 'Reverse playback on' : 'Reverse playback off',
    );
  }

  void _adjustOpacity() {
    final clip = _selectedClip;
    if (clip == null) return;
    _captureTimeline();
    _showClipSlider(
      title: 'Clip opacity',
      value: clip.transform.opacity,
      min: 0,
      max: 1,
      divisions: 20,
      label: (value) => '${(value * 100).round()}%',
      onChanged: (value) {
        setState(() => clip.transform.opacity = value);
        _refreshComposition();
      },
    );
  }

  void _showTransformEditorSheet() {
    final clip = _selectedClip;
    if (clip == null) return;
    _captureTimeline();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          void update(VoidCallback change) {
            change();
            setState(() {});
            setModalState(() {});
            _refreshComposition();
          }

          final transform = clip.transform;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        'Transform',
                        style: syne(sz: 15, w: FontWeight.w800, c: C.text),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => update(() {
                          transform.scale = 1;
                          transform.rotation = 0;
                          transform.position = Offset.zero;
                        }),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                  _buildTransformSlider(
                    'Scale',
                    transform.scale,
                    0.25,
                    3,
                    (value) => update(() => transform.scale = value),
                    valueLabel: '${transform.scale.toStringAsFixed(2)}x',
                  ),
                  _buildTransformSlider(
                    'Rotate',
                    transform.rotation,
                    -math.pi,
                    math.pi,
                    (value) => update(() => transform.rotation = value),
                    valueLabel:
                        '${(transform.rotation * 180 / math.pi).round()}°',
                  ),
                  _buildTransformSlider(
                    'Position X',
                    transform.position.dx,
                    -160,
                    160,
                    (value) => update(
                      () => transform.position = Offset(
                        value,
                        transform.position.dy,
                      ),
                    ),
                    valueLabel: transform.position.dx.round().toString(),
                  ),
                  _buildTransformSlider(
                    'Position Y',
                    transform.position.dy,
                    -160,
                    160,
                    (value) => update(
                      () => transform.position = Offset(
                        transform.position.dx,
                        value,
                      ),
                    ),
                    valueLabel: transform.position.dy.round().toString(),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTransformSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    required String valueLabel,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: dm(sz: 11, c: C.dim)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            valueLabel,
            textAlign: TextAlign.end,
            style: dm(sz: 11, c: C.brand),
          ),
        ),
      ],
    );
  }

  void _showFilterSheet() {
    final clip = _selectedClip ?? _compositionVisualClip;
    if (clip == null) {
      _showSnack('Select a clip first');
      return;
    }
    _captureTimeline();

    final filters = [
      ('None', 'Original', Icons.block, const Color(0xFF64748B)),
      ('Teal & Orange', 'Hollywood', Icons.movie_filter, const Color(0xFF0284C7)),
      ('Kodak Gold', '35mm Film', Icons.camera_roll, const Color(0xFFD97706)),
      ('Fuji Chrome', 'Vivid Film', Icons.landscape, const Color(0xFF059669)),
      ('Moody Emerald', 'Nordic Tone', Icons.forest, const Color(0xFF047857)),
      ('Cyberpunk Neon', 'Neo Violet', Icons.bolt, const Color(0xFF9333EA)),
      ('Silver Noir', 'Classic B&W', Icons.contrast, const Color(0xFF475569)),
      ('Golden Hour', 'Sunset Glow', Icons.wb_sunny, const Color(0xFFEA580C)),
      ('Porcelain Studio', 'Clean Skin', Icons.auto_awesome, const Color(0xFFDB2777)),
      ('Warm', 'Cozy Ambience', Icons.fireplace, const Color(0xFFB45309)),
      ('Cool', 'Crisp Minimal', Icons.ac_unit, const Color(0xFF06B6D4)),
      ('Vivid', 'Punchy Pop', Icons.flare, const Color(0xFF2563EB)),
    ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final current = clip.filter?.filterName ?? 'None';
          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.95),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(color: C.dim),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'CINEMATIC FILM LUTS',
                      style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
                    ),
                    Text(
                      current,
                      style: dm(sz: 11, c: C.brand, w: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 120,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: filters.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final item = filters[index];
                      final isSelected = current.toLowerCase() == item.$1.toLowerCase();
                      return GestureDetector(
                        onTap: () {
                          setModalState(() {});
                          setState(() {
                            clip.filter = item.$1 == 'None'
                                ? null
                                : FilterOperation(filterName: item.$1);
                          });
                          _refreshComposition();
                          HapticFeedback.selectionClick();
                        },
                        child: Container(
                          width: 86,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? item.$4.withOpacity(0.35)
                                : C.surface.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected ? C.brand : C.border.withOpacity(0.5),
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: item.$4.withOpacity(0.25),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(item.$3, color: item.$4, size: 20),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                item.$1,
                                style: syne(
                                  sz: 9.5,
                                  w: FontWeight.w800,
                                  c: isSelected ? C.brand : C.text,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.$2,
                                style: dm(sz: 8, c: C.dim),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  void _applyFilter() => _showEffectLibrarySheet();
  void _deleteClip() {
    if (_selectedClipIds.isEmpty) return;
    _captureTimeline();
    setState(() {
      for (final track in _tracks) {
        track.clips.removeWhere((clip) => _selectedClipIds.contains(clip.id));
      }
      _selectedClipIds.clear();
      _isMultiSelectMode = false;
      _selectedClip = null;
      _selectedTrackId = null;
      _selectedTrackIndex = null;
      TimelineModelUtils.pruneEmptyTracks(_tracks);
    });
    _playback.updateProject(_tracks);
  }

  void _duplicateSelectedClips() {
    if (_selectedClipIds.isEmpty) return;
    _captureTimeline();
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final duplicates = <TimelineClip>[];
    setState(() {
      for (final track in _tracks) {
        final selected = track.clips
            .where((clip) => _selectedClipIds.contains(clip.id))
            .toList();
        for (var index = 0; index < selected.length; index++) {
          final source = selected[index];
          final duplicate = source.copyWith(
            id: '${source.id}-copy-$timestamp-$index',
            start: source.start + source.duration,
          );
          TimelineModelUtils.insertClip(_tracks, duplicate, track.type);
          duplicates.add(duplicate);
        }
      }
      _selectedClipIds
        ..clear()
        ..addAll(duplicates.map((clip) => clip.id));
      _selectedClip = duplicates.isEmpty ? null : duplicates.last;
      _isMultiSelectMode = duplicates.length > 1;
    });
    _playback.updateProject(_tracks);
  }

  void _lockSelectedTracks() {
    _captureTimeline();
    setState(() {
      for (final track in _tracks) {
        if (track.clips.any((clip) => _selectedClipIds.contains(clip.id))) {
          track.isLocked = true;
        }
      }
    });
  }

  void _changeFont() => _showSnack('Change font');
  void _changeFontSize() => _showSnack('Change font size');
  void _changeTextColor() => _showSnack('Change text color');
  void _addShadow() => _showSnack('Add shadow');
  void _adjustVolume() {
    final clip = _selectedClip;
    if (clip == null) return;
    _captureTimeline();
    _showClipSlider(
      title: 'Clip volume',
      value: clip.volume,
      min: 0,
      max: 1,
      divisions: 20,
      label: (value) => '${(value * 100).round()}%',
      onChanged: (value) {
        setState(() {
          clip.volume = value;
          if (clip.operation is AudioClipOperation) {
            (clip.operation as AudioClipOperation).volume = value;
          }
        });
        if (clip.id == _activeVisualClipId) {
          _videoController?.setVolume(value);
        }
        _refreshComposition();
      },
    );
  }

  void _showClipSlider({
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) label,
    required ValueChanged<double> onChanged,
  }) {
    var current = value;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: syne(sz: 14, w: FontWeight.w800, c: C.text),
              ),
              Slider(
                value: current.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                label: label(current),
                activeColor: C.brand,
                onChanged: (next) {
                  setModalState(() => current = next);
                  onChanged(next);
                },
              ),
              Text(
                label(current),
                style: dm(sz: 12, c: C.brand, w: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addFade() {
    final clip = _selectedClip;
    if (clip == null || clip.operation is! AudioClipOperation) return;
    _captureTimeline();
    final operation = clip.operation as AudioClipOperation;
    var fadeIn = operation.fadeIn
        .clamp(0.0, clip.duration.inSeconds / 2)
        .toDouble();
    var fadeOut = operation.fadeOut
        .clamp(0.0, clip.duration.inSeconds / 2)
        .toDouble();
    final maxFade = math
        .max(0.1, clip.duration.inMilliseconds / 2000)
        .toDouble();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Audio fades',
                  style: syne(sz: 14, w: FontWeight.w800, c: C.text),
                ),
                const SizedBox(height: 12),
                _buildFadeSlider(
                  label: 'Fade in',
                  value: fadeIn,
                  max: maxFade,
                  onChanged: (value) {
                    fadeIn = value;
                    operation.fadeIn = value;
                    setModalState(() {});
                    _refreshComposition();
                  },
                ),
                _buildFadeSlider(
                  label: 'Fade out',
                  value: fadeOut,
                  max: maxFade,
                  onChanged: (value) {
                    fadeOut = value;
                    operation.fadeOut = value;
                    setModalState(() {});
                    _refreshComposition();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFadeSlider({
    required String label,
    required double value,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(label, style: dm(sz: 11, c: C.dim)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(0.0, max),
            min: 0,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            '${value.toStringAsFixed(1)}s',
            style: dm(sz: 11, c: C.brand),
          ),
        ),
      ],
    );
  }

  TimelineClip _insertTextLayer(
    String text, {
    TextStyle? style,
    Offset? position,
  }) {
    _captureTimeline();
    final clip = TimelineModelUtils.insertTextClip(
      _tracks,
      text: text,
      start: _currentTime,
      duration: const Duration(seconds: 6),
      style: style,
      position: position,
    );

    setState(() {
      _selectedClip = clip;
      _selectedClipIds
        ..clear()
        ..add(clip.id);
      _isMultiSelectMode = false;
      _selectedTrackId = _tracks
          .firstWhere((track) => track.clips.contains(clip))
          .id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == _selectedTrackId,
      );
    });
    _playback.updateProject(_tracks);

    return clip;
  }

  Future<void> _showTextHubSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Text Studio',
                style: syne(sz: 16, w: FontWeight.w800, c: C.text),
              ),
              const SizedBox(height: 12),
              Text(
                'Add text',
                style: dm(sz: 12, w: FontWeight.w700, c: C.dim),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTextHubChip('Heading', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      'Heading',
                      style: const TextStyle(
                        fontSize: 34,
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    );
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Subheading', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      'Subheading',
                      style: const TextStyle(
                        fontSize: 24,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Body', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      'Body text',
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                    );
                    _showTextEditorSheet();
                  }),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Templates',
                style: dm(sz: 12, w: FontWeight.w700, c: C.dim),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTextHubChip('Intro Title', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      'Intro Title',
                      style: const TextStyle(
                        fontSize: 30,
                        color: Color(0xFF8B5CF6),
                        fontWeight: FontWeight.w900,
                      ),
                    );
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Lower Third', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      'Lower Third',
                      style: const TextStyle(
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    );
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Quote', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      'Quote',
                      style: const TextStyle(
                        fontSize: 22,
                        color: Color(0xFF22C55E),
                        fontWeight: FontWeight.w700,
                      ),
                    );
                    _showTextEditorSheet();
                  }),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Captions & Stickers',
                style: dm(sz: 12, w: FontWeight.w700, c: C.dim),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTextHubChip('Caption', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      'Caption',
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Sticker', () {
                    Navigator.pop(context);
                    _insertTextLayer(
                      '✨',
                      style: const TextStyle(fontSize: 32, color: Colors.white),
                    );
                    _showTextEditorSheet();
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTextEditorSheet() async {
    _captureTimeline();
    if (_selectedClip == null || _selectedClip!.operation is! TextOverlay) {
      _showSnack('Select a text layer first');
      return;
    }

    final overlay = _selectedClip!.operation as TextOverlay;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Text Editor',
                    style: syne(sz: 15, w: FontWeight.w800, c: C.text),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: TextEditingController(text: overlay.text)
                      ..selection = TextSelection.collapsed(
                        offset: overlay.text.length,
                      ),
                    onChanged: (value) {
                      overlay.text = value;
                      setState(() {});
                      setModalState(() {});
                    },
                    decoration: InputDecoration(
                      hintText: 'Enter text',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Typography',
                    style: dm(sz: 12, w: FontWeight.w700, c: C.dim),
                  ),
                  const SizedBox(height: 8),
                  Slider(
                    value: (overlay.style.fontSize ?? 28).clamp(12.0, 72.0),
                    min: 12,
                    max: 72,
                    onChanged: (value) {
                      overlay.style = overlay.style.copyWith(fontSize: value);
                      setState(() {});
                      setModalState(() {});
                    },
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildTextHubChip('Bold', () {
                        overlay.style = overlay.style.copyWith(
                          fontWeight: FontWeight.w800,
                        );
                        setState(() {});
                        setModalState(() {});
                      }),
                      _buildTextHubChip('Italic', () {
                        overlay.style = overlay.style.copyWith(
                          fontStyle: FontStyle.italic,
                        );
                        setState(() {});
                        setModalState(() {});
                      }),
                      _buildTextHubChip('Center', () {
                        overlay.position = const Offset(0.5, 0.5);
                        setState(() {});
                        setModalState(() {});
                      }),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _buildTextHubChip('Delete', () {
                        Navigator.pop(context);
                        _deleteClip();
                      }),
                      const SizedBox(width: 8),
                      _buildTextHubChip('Duplicate', () {
                        Navigator.pop(context);
                        final duplicated = _insertTextLayer(
                          overlay.text,
                          style: overlay.style,
                          position: overlay.position,
                        );
                        duplicated.start = _currentTime;
                        setState(() {});
                      }),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTextHubChip(String label, VoidCallback onTap) {
    return Material(
      color: C.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: dm(sz: 11, w: FontWeight.w600, c: C.brand),
          ),
        ),
      ),
    );
  }

  Future<void> _importDeviceAudio() async {
    try {
      final assets = await _editorAudioService.importDeviceAudio();
      if (assets.isEmpty) return;
      TimelineClip? lastClip;
      var start = _currentTime;
      for (final asset in assets) {
        final duration = asset.duration == Duration.zero
            ? const Duration(seconds: 4)
            : asset.duration;
        final clip = TimelineClip(
          id: asset.id,
          start: start,
          duration: duration,
          operation: AudioClipOperation(
            sourceType: 'device',
            sourceUrl: asset.source,
            label: asset.name,
            volume: _audioVolume,
          ),
        );
        _captureTimeline();
        TimelineModelUtils.insertClip(_tracks, clip, TrackType.audio);
        _playback.updateProject(_tracks);
        start += duration;
        lastClip = clip;
      }
      if (lastClip != null && mounted) {
        setState(() {
          _selectedClip = lastClip;
          _selectedTrackId = _tracks
              .firstWhere((track) => track.clips.contains(lastClip))
              .id;
          _selectedTrackIndex = _tracks.indexWhere(
            (track) => track.id == _selectedTrackId,
          );
        });
        _showSnack(
          '${assets.length} audio file${assets.length == 1 ? '' : 's'} added to timeline',
        );
      }
    } catch (_) {
      if (mounted) _showSnack('Unable to import audio files');
    }
  }

  void _startReversePlayback() {
    final controller = _videoController;
    final clip = _selectedClip;
    if (controller == null || clip == null) return;
    controller.pause();
    _reversePlaybackTimer?.cancel();
    setState(() => _isPlaying = true);
    _reversePlaybackTimer = Timer.periodic(const Duration(milliseconds: 40), (
      _,
    ) {
      if (!mounted || _selectedClip != clip) {
        _reversePlaybackTimer?.cancel();
        return;
      }
      final stepMs = (40 * clip.speed).round();
      final position = controller.value.position;
      final next = position - Duration(milliseconds: stepMs);
      controller.seekTo(
        next <= clip.sourceStart
            ? (clip.sourceEnd ?? clip.sourceStart + clip.sourceDuration)
            : next,
      );
    });
  }

  Future<void> _showAudioPicker() async {
    if (!mounted) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MusicLibraryScreen()),
    );

    if (result is MusicTrack) {
      final clip = TimelineClip(
        id: 'music-${DateTime.now().millisecondsSinceEpoch}',
        start: _currentTime,
        // MusicTrack.duration is stored in seconds. Treating it as
        // milliseconds reduced nearly every selected song to one second.
        duration: result.duration > 0
            ? result.timelineDuration
            : const Duration(seconds: 1),
        operation: AudioClipOperation(
          sourceType: 'music',
          sourceUrl: result.audioUrl,
          label: result.title,
          volume: _audioVolume,
        ),
      );

      _captureTimeline();
      TimelineModelUtils.insertClip(_tracks, clip, TrackType.music);
      _playback.updateProject(_tracks);
      setState(() {
        _selectedClip = clip;
        _selectedTrackId = _tracks
            .firstWhere((track) => track.clips.contains(clip))
            .id;
        _selectedTrackIndex = _tracks.indexWhere(
          (candidate) => candidate.id == _selectedTrackId,
        );
        _isPreviewingMusic = false;
        _activeAudioPreviewUrl = null;
      });
      await _musicService.stopPreview();
      await _audioPreviewPlayer.stop();
      _showSnack('Music synced to timeline');
    }
  }

  Future<void> _showVoiceoverRecorder() async {
    final nameController = TextEditingController(text: 'Voiceover');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _voiceoverService.isRecording
                      ? Icons.mic
                      : Icons.mic_none_outlined,
                  color: _voiceoverService.isRecording
                      ? Colors.redAccent
                      : C.brand,
                  size: 42,
                ),
                const SizedBox(height: 10),
                Text(
                  _voiceoverService.isRecording
                      ? 'Recording voiceover'
                      : _voiceoverService.isPaused
                      ? 'Recording paused'
                      : 'Record voiceover',
                  style: syne(sz: 16, w: FontWeight.w800, c: C.text),
                ),
                const SizedBox(height: 6),
                Text(
                  'This will be added at ${_formatDuration(_currentTime)} on the Voiceover track.',
                  textAlign: TextAlign.center,
                  style: dm(sz: 11, c: C.dim),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  enabled:
                      !_voiceoverService.isRecording &&
                      !_voiceoverService.isPaused,
                  style: dm(sz: 12, c: C.text),
                  decoration: const InputDecoration(
                    labelText: 'Recording name',
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_voiceoverService.isRecording ||
                        _voiceoverService.isPaused)
                      OutlinedButton.icon(
                        onPressed: () async {
                          if (_voiceoverService.isRecording) {
                            await _voiceoverService.pause();
                          } else {
                            await _voiceoverService.resume();
                          }
                          setSheetState(() {});
                        },
                        icon: Icon(
                          _voiceoverService.isRecording
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                        label: Text(
                          _voiceoverService.isRecording ? 'Pause' : 'Resume',
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: () async {
                          if (!await _voiceoverService.start()) {
                            if (mounted)
                              _showSnack('Microphone permission denied');
                            return;
                          }
                          setState(() => _isRecordingVoice = true);
                          setSheetState(() {});
                        },
                        icon: const Icon(Icons.fiber_manual_record),
                        label: const Text('Start recording'),
                      ),
                    if (_voiceoverService.isRecording ||
                        _voiceoverService.isPaused) ...[
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                        onPressed: () async {
                          final recording = await _voiceoverService.stop();
                          if (recording == null) return;
                          _insertVoiceover(
                            recording,
                            nameController.text.trim().isEmpty
                                ? 'Voiceover'
                                : nameController.text.trim(),
                          );
                          if (mounted)
                            setState(() => _isRecordingVoice = false);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop & add'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    nameController.dispose();
  }

  void _insertVoiceover(RecordedVoiceover recording, String label) {
    final duration = recording.duration > const Duration(seconds: 1)
        ? recording.duration
        : const Duration(seconds: 1);
    final clip = TimelineClip(
      id: 'voice-${DateTime.now().millisecondsSinceEpoch}',
      start: _currentTime,
      duration: duration,
      operation: AudioClipOperation(
        sourceType: 'voiceover',
        sourceUrl: recording.file.path,
        label: label,
        volume: _audioVolume,
      ),
    );
    _captureTimeline();
    TimelineModelUtils.insertClip(_tracks, clip, TrackType.voiceOver);
    _playback.updateProject(_tracks);
    setState(() {
      _voiceOverFile = recording.file;
      _selectedClip = clip;
      _selectedTrackId = _tracks
          .firstWhere((track) => track.clips.contains(clip))
          .id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == _selectedTrackId,
      );
    });
    _showSnack('$label added to timeline');
  }

  Future<void> _addSoundEffect() async {
    final clip = TimelineClip(
      id: 'sfx-${DateTime.now().millisecondsSinceEpoch}',
      start: _currentTime,
      duration: const Duration(seconds: 3),
      operation: AudioClipOperation(
        sourceType: 'sfx',
        sourceUrl: 'builtin://sfx',
        label: 'Sound effect',
        volume: _audioVolume,
      ),
    );

    _captureTimeline();
    TimelineModelUtils.insertClip(_tracks, clip, TrackType.soundEffects);
    _playback.updateProject(_tracks);
    setState(() {
      _selectedClip = clip;
      _selectedTrackId = _tracks
          .firstWhere((track) => track.clips.contains(clip))
          .id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == _selectedTrackId,
      );
    });
    _showSnack('Sound effect added to timeline');
  }

  void _toggleEffectLibrary() {
    setState(() => _showEffectLibrary = !_showEffectLibrary);
    if (_showEffectLibrary) {
      _showEffectLibrarySheet();
    }
  }

  void _applySelectedEffect() {
    if (_selectedEffectId == null) {
      _showSnack('Select an effect from the library first');
      return;
    }

    final preset = _effectPresets.firstWhere(
      (candidate) => candidate.id == _selectedEffectId,
      orElse: () => _effectPresets.first,
    );
    final clip = TimelineClip(
      id: 'effect-${DateTime.now().millisecondsSinceEpoch}',
      start: _currentTime,
      duration: const Duration(seconds: 8),
      operation: EffectOperation(
        presetId: preset.id,
        presetName: preset.name,
        category: preset.category,
        icon: preset.icon,
        intensity: preset.defaultIntensity,
        opacity: preset.defaultOpacity,
        blendMode: preset.defaultBlendMode,
      ),
    );

    _captureTimeline();
    TimelineModelUtils.insertClip(_tracks, clip, TrackType.effects);
    _playback.updateProject(_tracks);
    _recentEffectIds.remove(preset.id);
    _recentEffectIds.insert(0, preset.id);
    setState(() {
      _selectedClip = clip;
      _selectedTrackId = _tracks
          .firstWhere((track) => track.clips.contains(clip))
          .id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == _selectedTrackId,
      );
      _previewEffect = null;
    });
    _showSnack('${preset.name} applied to timeline');
  }

  void _showEffectLibrarySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final visiblePresets = _effectPresets.where((preset) {
            final matchesQuery =
                _effectsSearchQuery.isEmpty ||
                [
                      preset.name,
                      preset.category,
                      preset.description,
                      ...preset.tags,
                    ]
                    .join(' ')
                    .toLowerCase()
                    .contains(_effectsSearchQuery.toLowerCase());
            final matchesFilter =
                _effectsFilter == 'All' || preset.category == _effectsFilter;
            return matchesQuery && matchesFilter;
          }).toList();

          visiblePresets.sort((a, b) {
            switch (_effectsSort) {
              case 'Name':
                return a.name.compareTo(b.name);
              case 'Recent':
                return _recentEffectIds
                    .indexOf(b.id)
                    .compareTo(_recentEffectIds.indexOf(a.id));
              case 'Favorites':
                return _favoriteEffectIds.contains(b.id) ? 1 : 0;
              default:
                return (b.featured ? 1 : 0).compareTo(a.featured ? 1 : 0);
            }
          });

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Effects Library',
                        style: syne(sz: 16, w: FontWeight.w800, c: C.text),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    onChanged: (value) =>
                        setModalState(() => _effectsSearchQuery = value),
                    decoration: InputDecoration(
                      hintText: 'Search effects',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          <String>[
                                'All',
                                'Cinematic',
                                'Glitch',
                                'VHS',
                                'Blur',
                                'Retro',
                                'Film',
                                'Neon',
                                'Light',
                              ]
                              .map(
                                (category) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(category),
                                    selected: _effectsFilter == category,
                                    onSelected: (_) => setModalState(
                                      () => _effectsFilter = category,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          <String>['Featured', 'Recent', 'Favorites', 'Name']
                              .map(
                                (sort) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(sort),
                                    selected: _effectsSort == sort,
                                    onSelected: (_) => setModalState(
                                      () => _effectsSort = sort,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: visiblePresets.length,
                      itemBuilder: (context, index) {
                        final preset = visiblePresets[index];
                        final isFavorite = _favoriteEffectIds.contains(
                          preset.id,
                        );
                        final isSelected = _selectedEffectId == preset.id;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? C.brand.withOpacity(0.14)
                                : C.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? C.brand : C.border,
                            ),
                          ),
                          child: ListTile(
                            leading: Text(
                              preset.icon,
                              style: const TextStyle(fontSize: 24),
                            ),
                            title: Text(
                              preset.name,
                              style: dm(sz: 12, w: FontWeight.w700, c: C.text),
                            ),
                            subtitle: Text(
                              preset.description,
                              style: dm(sz: 10.5, c: C.dim),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      if (isFavorite) {
                                        _favoriteEffectIds.remove(preset.id);
                                      } else {
                                        _favoriteEffectIds.add(preset.id);
                                      }
                                    });
                                    setModalState(() {});
                                  },
                                  icon: Icon(
                                    isFavorite
                                        ? Icons.favorite
                                        : Icons.favorite_outline,
                                    color: C.brand,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      _selectedEffectId = preset.id;
                                      _previewEffect = preset;
                                      _recentEffectIds.remove(preset.id);
                                      _recentEffectIds.insert(0, preset.id);
                                    });
                                    setModalState(() {});
                                  },
                                  icon: const Icon(Icons.play_arrow),
                                ),
                              ],
                            ),
                            onTap: () {
                              setState(() {
                                _selectedEffectId = preset.id;
                                _previewEffect = preset;
                              });
                              Navigator.pop(context);
                              _applySelectedEffect();
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  if (_previewEffect != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: C.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Live Preview',
                            style: dm(sz: 12, w: FontWeight.w700, c: C.text),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Previewing ${_previewEffect!.name} on the selected clip before applying it.',
                            style: dm(sz: 11, c: C.dim),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              TextButton(
                                onPressed: () =>
                                    setState(() => _previewEffect = null),
                                child: const Text('Clear Preview'),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _applySelectedEffect,
                                child: const Text('Apply'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showEffectEditorSheet() async {
    _captureTimeline();
    if (_selectedClip == null || _selectedClip!.operation is! EffectOperation) {
      _showSnack('Select an effect clip first');
      return;
    }

    final operation = _selectedClip!.operation as EffectOperation;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Effect Editor',
                    style: syne(sz: 15, w: FontWeight.w800, c: C.text),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    operation.presetName,
                    style: dm(sz: 13, w: FontWeight.w700, c: C.text),
                  ),
                  const SizedBox(height: 8),
                  _buildEffectSlider(
                    'Intensity',
                    operation.intensity,
                    0.0,
                    1.0,
                    (value) => setModalState(() => operation.intensity = value),
                  ),
                  _buildEffectSlider(
                    'Opacity',
                    operation.opacity,
                    0.0,
                    1.0,
                    (value) => setModalState(() => operation.opacity = value),
                  ),
                  _buildEffectSlider(
                    'Start Offset',
                    operation.startOffset,
                    0.0,
                    2.0,
                    (value) =>
                        setModalState(() => operation.startOffset = value),
                  ),
                  _buildEffectSlider(
                    'End Offset',
                    operation.endOffset,
                    0.0,
                    2.0,
                    (value) => setModalState(() => operation.endOffset = value),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildEffectChip(
                        'Keyframes',
                        () => _showSnack('Keyframes added'),
                      ),
                      _buildEffectChip(
                        'Copy',
                        () => _showSnack('Attributes copied'),
                      ),
                      _buildEffectChip(
                        'Paste',
                        () => _showSnack('Attributes pasted'),
                      ),
                      _buildEffectChip(
                        'Duplicate',
                        () => _showSnack('Effect duplicated'),
                      ),
                      _buildEffectChip(
                        'Replace',
                        () => _showEffectLibrarySheet(),
                      ),
                      _buildEffectChip('Delete', () => _deleteClip()),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEffectSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: dm(sz: 11, w: FontWeight.w600, c: C.dim),
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: (newValue) {
              onChanged(newValue);
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEffectChip(String label, VoidCallback onTap) {
    return Material(
      color: C.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: dm(sz: 10.5, w: FontWeight.w600, c: C.brand),
          ),
        ),
      ),
    );
  }

  void _toggleTransitionLibrary() {
    setState(() => _showTransitionLibrary = !_showTransitionLibrary);
    if (_showTransitionLibrary) {
      _showTransitionLibrarySheet();
    }
  }

  void _applySelectedTransition() {
    if (_selectedTransitionId == null || _selectedClip == null) {
      _showSnack('Select a clip boundary first');
      return;
    }

    final preset = _transitionPresets.firstWhere(
      (candidate) => candidate.id == _selectedTransitionId,
      orElse: () => _transitionPresets.first,
    );
    final transition = TimelineClip(
      id: 'transition-${DateTime.now().millisecondsSinceEpoch}',
      start: _selectedClip!.start + _selectedClip!.duration,
      duration: Duration(milliseconds: (preset.defaultDuration * 1000).round()),
      operation: TransitionOperation(
        presetId: preset.id,
        presetName: preset.name,
        category: preset.category,
        icon: preset.icon,
        duration: preset.defaultDuration,
        direction: 'center',
      ),
    );

    _captureTimeline();
    TimelineModelUtils.insertClip(_tracks, transition, TrackType.effects);
    _playback.updateProject(_tracks);
    _recentTransitionIds.remove(preset.id);
    _recentTransitionIds.insert(0, preset.id);
    setState(() {
      _selectedClip = transition;
      _selectedTrackId = _tracks
          .firstWhere((track) => track.clips.contains(transition))
          .id;
      _selectedTrackIndex = _tracks.indexWhere(
        (candidate) => candidate.id == _selectedTrackId,
      );
    });
    _showSnack('${preset.name} transition added');
  }

  void _showTransitionLibrarySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final visibleTransitions = _transitionPresets.where((preset) {
            final matchesQuery =
                _transitionSearchQuery.isEmpty ||
                [
                      preset.name,
                      preset.category,
                      preset.description,
                      ...preset.tags,
                    ]
                    .join(' ')
                    .toLowerCase()
                    .contains(_transitionSearchQuery.toLowerCase());
            final matchesFilter =
                _transitionFilter == 'All' ||
                preset.category == _transitionFilter;
            return matchesQuery && matchesFilter;
          }).toList();

          visibleTransitions.sort((a, b) {
            switch (_transitionSort) {
              case 'Name':
                return a.name.compareTo(b.name);
              case 'Recent':
                return _recentTransitionIds
                    .indexOf(b.id)
                    .compareTo(_recentTransitionIds.indexOf(a.id));
              case 'Favorites':
                return _favoriteTransitionIds.contains(b.id) ? 1 : 0;
              default:
                return (b.featured ? 1 : 0).compareTo(a.featured ? 1 : 0);
            }
          });

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Transitions Library',
                        style: syne(sz: 16, w: FontWeight.w800, c: C.text),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    onChanged: (value) =>
                        setModalState(() => _transitionSearchQuery = value),
                    decoration: InputDecoration(
                      hintText: 'Search transitions',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          <String>[
                                'All',
                                'Crossfade',
                                'Fade',
                                'Dissolve',
                                'Slide',
                                'Wipe',
                                'Zoom',
                                'Spin',
                                'Blur',
                                'Glitch',
                              ]
                              .map(
                                (category) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(category),
                                    selected: _transitionFilter == category,
                                    onSelected: (_) => setModalState(
                                      () => _transitionFilter = category,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children:
                          <String>['Featured', 'Recent', 'Favorites', 'Name']
                              .map(
                                (sort) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(sort),
                                    selected: _transitionSort == sort,
                                    onSelected: (_) => setModalState(
                                      () => _transitionSort = sort,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: visibleTransitions.length,
                      itemBuilder: (context, index) {
                        final preset = visibleTransitions[index];
                        final isFavorite = _favoriteTransitionIds.contains(
                          preset.id,
                        );
                        final isSelected = _selectedTransitionId == preset.id;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? C.brand.withOpacity(0.14)
                                : C.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? C.brand : C.border,
                            ),
                          ),
                          child: ListTile(
                            leading: Text(
                              preset.icon,
                              style: const TextStyle(fontSize: 24),
                            ),
                            title: Text(
                              preset.name,
                              style: dm(sz: 12, w: FontWeight.w700, c: C.text),
                            ),
                            subtitle: Text(
                              preset.description,
                              style: dm(sz: 10.5, c: C.dim),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      if (isFavorite) {
                                        _favoriteTransitionIds.remove(
                                          preset.id,
                                        );
                                      } else {
                                        _favoriteTransitionIds.add(preset.id);
                                      }
                                    });
                                    setModalState(() {});
                                  },
                                  icon: Icon(
                                    isFavorite
                                        ? Icons.favorite
                                        : Icons.favorite_outline,
                                    color: C.brand,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      _selectedTransitionId = preset.id;
                                      _recentTransitionIds.remove(preset.id);
                                      _recentTransitionIds.insert(0, preset.id);
                                    });
                                    setModalState(() {});
                                  },
                                  icon: const Icon(Icons.play_arrow),
                                ),
                              ],
                            ),
                            onTap: () {
                              setState(() => _selectedTransitionId = preset.id);
                              Navigator.pop(context);
                              _applySelectedTransition();
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showTransitionEditorSheet() async {
    _captureTimeline();
    if (_selectedClip == null ||
        _selectedClip!.operation is! TransitionOperation) {
      _showSnack('Select a transition first');
      return;
    }

    final transition = _selectedClip!.operation as TransitionOperation;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Transition Editor',
                    style: syne(sz: 15, w: FontWeight.w800, c: C.text),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    transition.presetName,
                    style: dm(sz: 13, w: FontWeight.w700, c: C.text),
                  ),
                  const SizedBox(height: 8),
                  _buildEffectSlider(
                    'Duration',
                    transition.duration,
                    0.1,
                    2.0,
                    (value) => setModalState(() => transition.duration = value),
                  ),
                  _buildEffectSlider(
                    'Intensity',
                    transition.intensity,
                    0.0,
                    1.0,
                    (value) =>
                        setModalState(() => transition.intensity = value),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildEffectChip(
                        'Replace',
                        () => _showTransitionLibrarySheet(),
                      ),
                      _buildEffectChip(
                        'Duplicate',
                        () => _showSnack('Transition duplicated'),
                      ),
                      _buildEffectChip('Delete', () => _deleteClip()),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showAdjustSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: C.dim),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'COLOR GRADING (GPU)',
                style: syne(sz: 14, w: FontWeight.w900, ls: 2),
              ),
              const SizedBox(height: 20),
              _buildAdjustSlider('Brightness', _brightness, -0.5, 0.5, (v) {
                setModalState(() => _brightness = v);
                setState(() => _brightness = v);
              }),
              _buildAdjustSlider('Contrast', _contrast, 0.5, 1.5, (v) {
                setModalState(() => _contrast = v);
                setState(() => _contrast = v);
              }),
              _buildAdjustSlider('Saturation', _saturation, 0.0, 2.0, (v) {
                setModalState(() => _saturation = v);
                setState(() => _saturation = v);
              }),
              _buildAdjustSlider('Hue', _hue, -3.14, 3.14, (v) {
                setModalState(() => _hue = v);
                setState(() => _hue = v);
              }),
              _buildAdjustSlider('Vignette', _effectVignette, 0.0, 1.0, (v) {
                setModalState(() => _effectVignette = v);
                setState(() => _effectVignette = v);
              }),
              _buildAdjustSlider('Grain', _effectGrain, 0.0, 1.0, (v) {
                setModalState(() => _effectGrain = v);
                setState(() => _effectGrain = v);
              }),
              _buildAdjustSlider('Blur', _effectBlur, 0.0, 10.0, (v) {
                setModalState(() => _effectBlur = v);
                setState(() => _effectBlur = v);
              }),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  setModalState(() {
                    _brightness = 0.0;
                    _contrast = 1.0;
                    _saturation = 1.0;
                    _hue = 0.0;
                    _effectVignette = 0.0;
                    _effectGrain = 0.0;
                    _effectBlur = 0.0;
                  });
                  setState(() {
                    _brightness = 0.0;
                    _contrast = 1.0;
                    _saturation = 1.0;
                    _hue = 0.0;
                    _effectVignette = 0.0;
                    _effectGrain = 0.0;
                    _effectBlur = 0.0;
                  });
                },
                child: Text(
                  'RESET ALL',
                  style: syne(sz: 11, w: FontWeight.w900, c: C.brand),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdjustSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: dm(sz: 11, c: C.sub)),
            Text(value.toStringAsFixed(2), style: dm(sz: 11, c: C.brand)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          activeColor: C.brand,
          inactiveColor: C.dim.withOpacity(0.3),
          onChanged: onChanged,
        ),
      ],
    );
  }

  void _showCropSheet([TimelineClip? targetClip]) {
    final clip = targetClip ?? _selectedClip ?? _compositionVisualClip;
    final ratios = ['Original', '9:16', '1:1', '4:5', '16:9'];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: C.dim),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 16),
              child: Text(
                'ASPECT RATIO / CROP',
                style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: ratios.map((r) {
                final current = clip?.cropAspectRatio ?? _selectedAspectRatio;
                final isSelected = current == r;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (clip != null) {
                        clip.cropAspectRatio = r;
                      }
                      if (r != 'Original') {
                        _selectedAspectRatio = r;
                      }
                    });
                    _playback.updateProject(_tracks);
                    Navigator.pop(context);
                    _showSnack('Crop set to $r');
                  },
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? C.brand.withOpacity(0.2)
                              : C.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? C.brand : C.border,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Icon(
                          Icons.crop,
                          color: isSelected ? C.brand : C.dim,
                          size: 24,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        r,
                        style: syne(
                          sz: 11,
                          w: FontWeight.w700,
                          c: isSelected ? C.brand : C.dim,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _showFadeSheet([TimelineClip? targetClip]) {
    final clip = targetClip ?? _selectedClip ?? _compositionVisualClip;
    if (clip == null) {
      _showSnack('Select a clip first');
      return;
    }
    final options = [
      'None',
      'Fade',
      'Dissolve',
      'Crossfade',
      'Slide',
      'Wipe',
      'Zoom',
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.94),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: C.dim),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'FADE & TRANSITION',
              style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options.map((option) {
                return GestureDetector(
                  onTap: () {
                    if (option == 'None') {
                      _showSnack('Transition cleared');
                    } else {
                      final transClip = TimelineClip(
                        id: 'trans-${DateTime.now().millisecondsSinceEpoch}',
                        start: clip.start,
                        duration: const Duration(milliseconds: 600),
                        operation: TransitionOperation(
                          presetId: option.toLowerCase(),
                          presetName: option,
                          category: 'Fade',
                          icon: '✨',
                        ),
                      );
                      TimelineModelUtils.insertClip(
                        _tracks,
                        transClip,
                        TrackType.effects,
                      );
                      _playback.updateProject(_tracks);
                      setState(() {});
                      _showSnack('$option applied');
                    }
                    Navigator.pop(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: C.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: C.border),
                    ),
                    child: Text(
                      option,
                      style: syne(sz: 12, w: FontWeight.w700, c: C.text),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _showStickerSheet() {
    final stickers = [
      'STAR',
      'SALE',
      'NEW',
      'LIVE',
      'HOT',
      'CHECK',
      '❤️',
      '🔥',
      '✨',
      '⚡',
      '🎉',
      '👏',
      '🎬',
      '💯',
      '🚀',
      '👀',
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.94),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: C.dim),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'STICKERS',
              style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: stickers.map((sticker) {
                return GestureDetector(
                  onTap: () {
                    final isWord = sticker.length > 2;
                    final overlay = OverlayOperation(
                      kind: 'sticker',
                      text: sticker,
                      fontSize: isWord ? 22.0 : 42.0,
                      color: isWord ? Colors.black : C.text,
                      background: isWord ? C.brand : Colors.transparent,
                      backgroundOpacity: isWord ? 1.0 : 0.0,
                      stroke: !isWord,
                      shadow: true,
                    );
                    final clip = TimelineClip(
                      id:
                          'overlay-sticker-${DateTime.now().millisecondsSinceEpoch}',
                      start: _currentTime,
                      duration: const Duration(seconds: 4),
                      operation: overlay,
                    );
                    TimelineModelUtils.insertClip(
                      _tracks,
                      clip,
                      TrackType.overlay,
                    );
                    _playback.updateProject(_tracks);
                    setState(() {});
                    Navigator.pop(context);
                    _showSnack('Sticker added to timeline');
                  },
                  child: Container(
                    width: 76,
                    height: 54,
                    decoration: BoxDecoration(
                      color: C.text.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: C.dim),
                    ),
                    child: Center(
                      child: Text(
                        sticker,
                        style: syne(
                          sz: sticker.length > 2 ? 13 : 24,
                          w: FontWeight.w900,
                          c: C.text,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _showAudioMixerSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.95),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            border: Border.all(color: C.dim),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'AUDIO MIXER',
                style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
              ),
              const SizedBox(height: 24),
              _buildMixerSlider('Original Video', _originalVideoVolume, (v) {
                setModalState(() => _originalVideoVolume = v);
                setState(() => _originalVideoVolume = v);
                _videoController?.setVolume(v);
                for (final track in _tracks) {
                  if (track.type == TrackType.video) {
                    for (final clip in track.clips) {
                      clip.volume = v;
                    }
                  }
                }
              }),
              const SizedBox(height: 14),
              _buildMixerSlider('Background Music', _bgmVolume, (v) {
                setModalState(() => _bgmVolume = v);
                setState(() => _bgmVolume = v);
                for (final player in _timelineAudioPlayers.values) {
                  player.setVolume(v);
                }
                for (final track in _tracks) {
                  if (track.type == TrackType.music) {
                    for (final clip in track.clips) {
                      clip.volume = v;
                    }
                  }
                }
              }),
              const SizedBox(height: 14),
              _buildMixerSlider('Voiceover', _voiceVolume, (v) {
                setModalState(() => _voiceVolume = v);
                setState(() => _voiceVolume = v);
                for (final track in _tracks) {
                  if (track.type == TrackType.voiceOver) {
                    for (final clip in track.clips) {
                      clip.volume = v;
                    }
                  }
                }
              }),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMixerSlider(
    String label,
    double val,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: dm(sz: 11, c: C.sub)),
            Text('${(val * 100).round()}%', style: dm(sz: 11, c: C.brand)),
          ],
        ),
        Slider(
          value: val.clamp(0.0, 1.0),
          onChanged: onChanged,
          activeColor: C.brand,
          inactiveColor: C.dim.withOpacity(0.3),
        ),
      ],
    );
  }

  void _showClipActions(TimelineTrack track, TimelineClip clip) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.card,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Clip actions',
                style: syne(sz: 14, w: FontWeight.w800, c: C.text),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildClipActionChip('Split', () {
                    Navigator.pop(context);
                    _splitClip();
                  }),
                  _buildClipActionChip('Trim', () {
                    Navigator.pop(context);
                    _trimClip();
                  }),
                  _buildClipActionChip('Crop', () {
                    Navigator.pop(context);
                    _showCropSheet(clip);
                  }),
                  _buildClipActionChip('Adjust', () {
                    Navigator.pop(context);
                    _showAdjustSheet();
                  }),
                  _buildClipActionChip('Fade', () {
                    Navigator.pop(context);
                    _showFadeSheet(clip);
                  }),
                  _buildClipActionChip('Transform', () {
                    Navigator.pop(context);
                    _showTransformEditorSheet();
                  }),
                  _buildClipActionChip('Stickers', () {
                    Navigator.pop(context);
                    _showStickerSheet();
                  }),
                  _buildClipActionChip('Audio Mixer', () {
                    Navigator.pop(context);
                    _showAudioMixerSheet();
                  }),
                  _buildClipActionChip('Duplicate', () {
                    Navigator.pop(context);
                    _showSnack('Clip duplicated');
                  }),
                  _buildClipActionChip('Delete', () {
                    Navigator.pop(context);
                    _deleteClip();
                  }),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClipActionChip(String label, VoidCallback onTap) {
    return Material(
      color: C.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: dm(sz: 11, w: FontWeight.w600, c: C.brand),
          ),
        ),
      ),
    );
  }

  void _showToolPanel(String toolName) => _showSnack('$toolName panel opened');

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _syncVideoState() {
    if (!mounted || _videoController == null) return;
    final clip = TimelinePlaybackController.resolve(
      _tracks,
      _playback.state.currentTime,
    ).ofType(TrackType.video).lastOrNull;
    if (clip != null && clip.file != null && !clip.isReversed) {
      final sourceEnd = clip.sourceEnd ?? _videoController!.value.duration;
      if (_videoController!.value.position >= sourceEnd) {
        _videoController!.seekTo(clip.sourceStart);
      }
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

// ══════════════════════════════════════════════════════════════
// DATA MODELS
// ══════════════════════════════════════════════════════════════

int min(int a, int b) => a < b ? a : b;

// ─────────────────────────────────────────────────────────────────────────────
// _ClipBadgeRow
// ─────────────────────────────────────────────────────────────────────────────

/// Compact row of state-indicator pill badges shown on each timeline clip.
/// Only renders when a badge condition is active — IDLE clips are badge-free.
///
/// Badges rendered (in order):
///   • Speed  — amber pill (e.g. "2.0×") when playback speed ≠ 1.0
///   • FX     — cyan sparkle icon when a colour filter is applied
///   • Beauty — pink face icon when skin/makeup effects are active
///   • Rev    — purple rewind icon when clip is reversed
class _ClipBadgeRow extends StatelessWidget {
  const _ClipBadgeRow({required this.clip});

  final TimelineClip clip;

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[];

    // Speed badge (shown when not 1.0×)
    if ((clip.speed - 1.0).abs() > 0.01) {
      final label = '${clip.speed.toStringAsFixed(1)}×';
      badges.add(_textBadge(label, const Color(0xFFFBBF24), Colors.black));
    }

    // FX badge (colour filter applied)
    if (clip.filter != null) {
      badges.add(_iconBadge(Icons.auto_fix_high, const Color(0xFF00E5FF)));
    }

    // Beauty badge (any skin/makeup effect active)
    if (clip.skinSmoothing > 0.01 ||
        clip.skinBrightening > 0.01 ||
        clip.makeupIntensity > 0.01) {
      badges.add(
          _iconBadge(Icons.face_retouching_natural, const Color(0xFFEC4899)));
    }

    // Reversed badge
    if (clip.isReversed) {
      badges.add(_iconBadge(Icons.fast_rewind, const Color(0xFFA78BFA)));
    }

    if (badges.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < badges.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          badges[i],
        ],
      ],
    );
  }

  Widget _textBadge(String label, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 7,
            fontWeight: FontWeight.w800,
            color: fg,
            height: 1.2,
          ),
        ),
      );

  Widget _iconBadge(IconData icon, Color color) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: color.withValues(alpha: 0.55), width: 0.5),
        ),
        child: Icon(icon, size: 9, color: color),
      );
}

class _VideoClipThumbnails extends StatefulWidget {
  final TimelineClip clip;
  final double width;
  final double pixelsPerSecond;

  const _VideoClipThumbnails({
    Key? key,
    required this.clip,
    required this.width,
    required this.pixelsPerSecond,
  }) : super(key: key);

  @override
  State<_VideoClipThumbnails> createState() => _VideoClipThumbnailsState();
}

class _VideoClipThumbnailsState extends State<_VideoClipThumbnails> {
  @override
  Widget build(BuildContext context) {
    if (widget.clip.file == null) return const SizedBox();

    final clipDurationMs = widget.clip.duration.inMilliseconds;
    final longFormClip =
        clipDurationMs >= const Duration(minutes: 30).inMilliseconds;
    final fileSizeBytes = widget.clip.file!.existsSync()
        ? widget.clip.file!.lengthSync()
        : 0;
    final largeMedia = fileSizeBytes > 2 * 1024 * 1024 * 1024 || longFormClip;

    final maxThumbCount = (widget.width / 120).round().clamp(
      4,
      _MobileMediaEditorState._maxThumbnailFrames,
    );
    final int numThumbnails = largeMedia
        ? maxThumbCount
        : (clipDurationMs / 1000).clamp(1, maxThumbCount).round();
    final double thumbWidth = widget.pixelsPerSecond;

    if (largeMedia) {
      return ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: numThumbnails,
        itemBuilder: (context, index) {
          final timeMs = clipDurationMs > 0
              ? ((index / math.max(1, numThumbnails - 1)) * clipDurationMs)
                    .round()
              : 0;
          return SizedBox(
            width: thumbWidth,
            child: _SingleThumbnail(
              file: widget.clip.file!,
              timeMs: timeMs,
              isLargeMedia: true,
            ),
          );
        },
      );
    }

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: numThumbnails,
      itemBuilder: (context, index) {
        final timeMs = clipDurationMs > 0
            ? ((index / math.max(1, numThumbnails - 1)) * clipDurationMs)
                  .round()
            : 0;
        return SizedBox(
          width: thumbWidth,
          child: _SingleThumbnail(
            file: widget.clip.file!,
            timeMs: timeMs,
            isLargeMedia: false,
          ),
        );
      },
    );
  }
}

class _SingleThumbnail extends StatefulWidget {
  final File file;
  final int timeMs;
  final bool isLargeMedia;

  const _SingleThumbnail({
    Key? key,
    required this.file,
    required this.timeMs,
    this.isLargeMedia = false,
  }) : super(key: key);

  @override
  State<_SingleThumbnail> createState() => _SingleThumbnailState();
}

class _SingleThumbnailState extends State<_SingleThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (widget.isLargeMedia) {
      if (mounted) setState(() => _bytes = null);
      return;
    }

    final cacheKey = '${widget.file.path}_${widget.timeMs}';
    if (_MobileMediaEditorState._thumbnailCache.containsKey(cacheKey)) {
      if (mounted)
        setState(
          () => _bytes = _MobileMediaEditorState._thumbnailCache[cacheKey],
        );
      return;
    }

    if (_MobileMediaEditorState._thumbnailCache.length >=
        _MobileMediaEditorState._maxThumbnailCacheEntries) {
      _MobileMediaEditorState._thumbnailCache.clear();
    }

    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: widget.file.path,
        imageFormat: ImageFormat.JPEG,
        timeMs: widget.timeMs,
        quality: 24,
        maxWidth: 240,
        maxHeight: 160,
      );
      if (bytes != null) {
        _MobileMediaEditorState._thumbnailCache[cacheKey] = bytes;
        if (mounted) setState(() => _bytes = bytes);
      }
    } catch (e) {
      debugPrint('Thumbnail error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return Container(
        color: C.surface,
        child: Center(
          child: Text(
            widget.isLargeMedia ? 'Large media' : '…',
            style: dm(sz: 8, c: C.dim),
          ),
        ),
      );
    }
    return Image.memory(_bytes!, fit: BoxFit.cover);
  }
}

class _WaveformPainter extends CustomPainter {
  final Color color;
  final int seed;

  _WaveformPainter({required this.color, required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final random = math.Random(seed);
    const spacing = 4.0;
    for (double i = 0; i < size.width; i += spacing) {
      final height = (random.nextDouble() * 0.8 + 0.2) * size.height;
      canvas.drawLine(
        Offset(i, (size.height - height) / 2),
        Offset(i, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.seed != seed;
  }
}

class ShaderPainter extends CustomPainter {
  final ui.FragmentShader shader;
  final double brightness;
  final double contrast;
  final double saturation;
  final double hue;

  ShaderPainter({
    required this.shader,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.hue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);
    shader.setFloat(2, brightness);
    shader.setFloat(3, contrast);
    shader.setFloat(4, saturation);
    shader.setFloat(5, hue);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant ShaderPainter oldDelegate) =>
      oldDelegate.brightness != brightness ||
      oldDelegate.contrast != contrast ||
      oldDelegate.saturation != saturation ||
      oldDelegate.hue != hue;
}

class GrainPainter extends CustomPainter {
  final double intensity;
  final math.Random _rand = math.Random();

  GrainPainter({required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(
        (0.12 * intensity).clamp(0.0, 1.0),
      );
    for (int i = 0; i < 1500 * intensity; i++) {
      final x = _rand.nextDouble() * size.width;
      final y = _rand.nextDouble() * size.height;
      canvas.drawCircle(Offset(x, y), _rand.nextDouble() * 0.8, paint);
    }
  }

  @override
  bool shouldRepaint(covariant GrainPainter oldDelegate) => false;
}

/// Bilateral Facial Symmetry alignment guide and landmark balance overlay.
class _FacialSymmetryGuideOverlay extends StatelessWidget {
  final double intensity;
  final bool mirrorLeft;

  const _FacialSymmetryGuideOverlay({
    required this.intensity,
    required this.mirrorLeft,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _FacialSymmetryPainter(
          intensity: intensity,
          mirrorLeft: mirrorLeft,
        ),
      ),
    );
  }
}

class _FacialSymmetryPainter extends CustomPainter {
  final double intensity;
  final bool mirrorLeft;

  _FacialSymmetryPainter({
    required this.intensity,
    required this.mirrorLeft,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final alpha = (intensity * 0.7).clamp(0.18, 0.75);

    // Glowing vertical center axis
    final glowPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: alpha * 0.35)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: alpha)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Dashed center line
    const dashHeight = 8.0;
    const dashSpace = 6.0;
    double startY = size.height * 0.12;
    final endY = size.height * 0.88;

    while (startY < endY) {
      final segEnd = (startY + dashHeight).clamp(0.0, endY);
      canvas.drawLine(Offset(cx, startY), Offset(cx, segEnd), glowPaint);
      canvas.drawLine(Offset(cx, startY), Offset(cx, segEnd), linePaint);
      startY += dashHeight + dashSpace;
    }

    // Facial landmark reference cross-ticks
    final markerPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: alpha)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    // Eye level tick & balance dots (y = 0.38)
    final eyeY = size.height * 0.38;
    canvas.drawLine(Offset(cx - 24, eyeY), Offset(cx + 24, eyeY), markerPaint);
    final dotPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: alpha * 0.85)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx - 55, eyeY), 2.5, dotPaint);
    canvas.drawCircle(Offset(cx + 55, eyeY), 2.5, dotPaint);

    // Nose level tick (y = 0.48)
    final noseY = size.height * 0.48;
    canvas.drawLine(Offset(cx - 10, noseY), Offset(cx + 10, noseY), markerPaint);

    // Lip level tick (y = 0.58)
    final lipY = size.height * 0.58;
    canvas.drawLine(Offset(cx - 18, lipY), Offset(cx + 18, lipY), markerPaint);

    // Chin level tick (y = 0.68)
    final chinY = size.height * 0.68;
    canvas.drawLine(Offset(cx - 12, chinY), Offset(cx + 12, chinY), markerPaint);

    // Direction indicator near upper axis (L ➔ R or R ➔ L)
    final textPainter = TextPainter(
      text: TextSpan(
        text: mirrorLeft ? 'L ➔ R' : 'R ➔ L',
        style: TextStyle(
          color: const Color(0xFF00E5FF).withValues(alpha: alpha),
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(cx - textPainter.width / 2, size.height * 0.26));
  }

  @override
  bool shouldRepaint(_FacialSymmetryPainter old) =>
      old.intensity != intensity || old.mirrorLeft != mirrorLeft;
}

/// Real-time Studio Makeup overlay for women and men.
class _StudioMakeupOverlay extends StatelessWidget {
  final int gender; // 1 = Women, 2 = Men
  final int style;
  final double intensity;

  const _StudioMakeupOverlay({
    required this.gender,
    required this.style,
    required this.intensity,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _StudioMakeupPainter(
          gender: gender,
          style: style,
          intensity: intensity,
        ),
      ),
    );
  }
}

class _StudioMakeupPainter extends CustomPainter {
  final int gender;
  final int style;
  final double intensity;

  _StudioMakeupPainter({
    required this.gender,
    required this.style,
    required this.intensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final m = intensity.clamp(0.0, 1.0);

    if (gender == 1) {
      // ── Women: Soft Cheek Blush & Hydrating Lip Tint ─────────
      final blushColor = style == 0
          ? const Color(0xFFFF5277) // Rosy Glow (petal rose)
          : style == 1
              ? const Color(0xFFFF8A65) // Natural Nude (soft peach)
              : const Color(0xFFE91E63); // Sunset Glam (berry blush)

      final blushAlpha = (m * 0.17).clamp(0.0, 0.22);
      final blushRadius = size.width * 0.22;

      // Left cheek blush
      final leftCheek = Offset(cx - (size.width * 0.20), size.height * 0.44);
      final leftBlushPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            blushColor.withValues(alpha: blushAlpha),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: leftCheek, radius: blushRadius));
      canvas.drawCircle(leftCheek, blushRadius, leftBlushPaint);

      // Right cheek blush
      final rightCheek = Offset(cx + (size.width * 0.20), size.height * 0.44);
      final rightBlushPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            blushColor.withValues(alpha: blushAlpha),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: rightCheek, radius: blushRadius));
      canvas.drawCircle(rightCheek, blushRadius, rightBlushPaint);

      // Lip hydration & tint
      final lipCenter = Offset(cx, size.height * 0.58);
      final lipRadius = size.width * 0.11;
      final lipAlpha = (m * 0.15).clamp(0.0, 0.20);
      final lipPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            blushColor.withValues(alpha: lipAlpha),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: lipCenter, radius: lipRadius));
      canvas.drawCircle(lipCenter, lipRadius, lipPaint);
    } else if (gender == 2) {
      // ── Men: Groomed Jaw Contour & Brow Framing ───────────────
      final contourAlpha = (m * 0.14).clamp(0.0, 0.18);
      final contourColor = style == 2
          ? const Color(0xFF6D4C41) // Sun-Kissed bronze
          : const Color(0xFF37474F); // Clean / Sharp sculpted contour

      // Jawline shading: subtle shadow gradient along jaw contour
      final jawPath = Path()
        ..moveTo(cx - (size.width * 0.35), size.height * 0.56)
        ..quadraticBezierTo(
          cx - (size.width * 0.26), size.height * 0.70,
          cx, size.height * 0.73,
        )
        ..quadraticBezierTo(
          cx + (size.width * 0.26), size.height * 0.70,
          cx + (size.width * 0.35), size.height * 0.56,
        );

      final jawPaint = Paint()
        ..color = contourColor.withValues(alpha: contourAlpha)
        ..strokeWidth = size.width * 0.08
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);

      canvas.drawPath(jawPath, jawPaint);

      // Brow definition accent: subtle contrast enhancement
      final browPaint = Paint()
        ..color = Colors.black.withValues(alpha: contourAlpha * 0.6)
        ..strokeWidth = size.width * 0.04
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

      canvas.drawLine(
        Offset(cx - (size.width * 0.22), size.height * 0.35),
        Offset(cx - (size.width * 0.06), size.height * 0.34),
        browPaint,
      );
      canvas.drawLine(
        Offset(cx + (size.width * 0.06), size.height * 0.34),
        Offset(cx + (size.width * 0.22), size.height * 0.35),
        browPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_StudioMakeupPainter old) =>
      old.gender != gender || old.style != style || old.intensity != intensity;
}
