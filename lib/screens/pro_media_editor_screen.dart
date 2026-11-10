import 'package:universal_io/io.dart';
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/finance_backend.dart';
import '../services/ffmpeg_stub.dart'
    if (dart.library.io) 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:video_player/video_player.dart';
import '../services/video_enhancement_service.dart';
import '../services/image_enhancement_service.dart';
import '../models/music_models.dart';
import '../models/edit_models.dart';
import '../screens/music_library_screen.dart';
import '../services/music_library_service.dart';
import '../services/editor_media_service.dart';
import '../theme.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import '../app_state.dart';
import '../services/editor_voiceover_service.dart';
import '../services/timeline_playback_controller.dart';
import '../services/editor_export_service.dart';
import '../services/ai_service.dart';
import '../services/editor_subscription_service.dart';
import '../face_engine/core/face_engine_controller.dart';
import '../face_engine/widgets/face_preset_sheet.dart';
import 'dart:math' as math;

enum ImageFilter {
  normal,
  warm,
  cool,
  vivid,
  cinematic,
  vintage,
  blackAndWhite,
  noir,
  softGlow,
}

class VideoClip {
  /// Stable project identity; survives preview adapter recreation and reordering.
  final String id;
  final File file;
  File? proxyFile; // Lightweight version for editing
  File? reversePreviewFile;
  bool isProxyReady = false;

  double start; // seconds
  double end; // seconds
  double duration; // total source duration
  double speed;
  double volume;
  bool hasAudio;
  bool isReversed;
  double scale;
  double rotation;
  double offsetX;
  double offsetY;
  double opacity;
  ImageFilter? filter;
  double brightness;
  double contrast;
  double saturation;
  double hue;
  double vignette;
  double grain;
  double blur;

  VideoClip({
    String? id,
    required this.file,
    this.proxyFile,
    this.reversePreviewFile,
    this.isProxyReady = false,
    this.start = 0,
    this.end = 0.1,
    this.duration = 0,
    this.speed = 1.0,
    this.volume = 1.0,
    this.hasAudio = true,
    this.isReversed = false,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.opacity = 1.0,
    this.filter,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.hue = 0.0,
    this.vignette = 0.0,
    this.grain = 0.0,
    this.blur = 0.0,
  }) : id = id ?? 'editor-${file.path.hashCode}-${DateTime.now().microsecondsSinceEpoch}';

  VideoClip copy() => VideoClip(
    id: id,
    file: file,
    proxyFile: proxyFile,
    reversePreviewFile: reversePreviewFile,
    isProxyReady: isProxyReady,
    start: start,
    end: end,
    duration: duration,
    speed: speed,
    volume: volume,
    hasAudio: hasAudio,
    isReversed: isReversed,
    scale: scale,
    rotation: rotation,
    offsetX: offsetX,
    offsetY: offsetY,
    opacity: opacity,
    filter: filter,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
    hue: hue,
    vignette: vignette,
    grain: grain,
    blur: blur,
  );

  bool get isVideo =>
      file.path.toLowerCase().endsWith('.mp4') ||
      file.path.toLowerCase().endsWith('.mov');
}

class ProMediaEditorScreen extends StatefulWidget {
  final File? initialImage;
  final File? initialVideo;
  final MusicTrack? initialTrack;
  final List<File>? multiFiles;
  final bool isFastSync;
  final AppState state;
  final EditorProjectController? projectController;

  ProMediaEditorScreen({
    super.key,
    this.initialImage,
    this.initialVideo,
    this.initialTrack,
    this.multiFiles,
    this.isFastSync = false,
    required this.state,
    this.projectController,
  });

  @override
  State<ProMediaEditorScreen> createState() => _ProMediaEditorScreenState();
}

class _ProMediaEditorScreenState extends State<ProMediaEditorScreen> {
  late final EditorProjectController _project;
  late final bool _ownsProjectController;
  final EditorMediaService _mediaService = EditorMediaService();
  final ImageEnhancementService _enhancementService = ImageEnhancementService();
  final VideoEnhancementService _videoService = VideoEnhancementService();
  final FaceEngineController _faceEngine = FaceEngineController();
  bool _isProEnabled = false;

  VideoPlayerController? _videoController;

  // Real-time Editing State
  ImageFilter? _selectedFilter;
  bool _isProcessing = false;
  MusicTrack? _selectedTrack;
  final AudioPlayer _musicPlayer = AudioPlayer();
  final AudioPlayer _voicePlayer = AudioPlayer();
  final Map<String, AudioPlayer> _timelineAudioPlayers = <String, AudioPlayer>{};
  final Map<String, String> _timelineAudioSources = <String, String>{};
  final Map<String, double> _timelineAudioSpeeds = <String, double>{};
  final Map<String, File> _timelineReversedAudioCache = <String, File>{};
  bool _syncingTimelineAudio = false;
  Duration _lastTimelineAudioSync = Duration.zero;
  final MusicLibraryService _musicService = MusicLibraryService();

  // Shader State
  ui.FragmentProgram? _shaderProgram;
  double _brightness = 0.0;
  double _contrast = 1.0;
  double _saturation = 1.0;
  double _hue = 0.0;

  // Advanced Tools State
  // Audio mixer values are read from the authoritative project clips.
  double _originalVolume = 1.0;
  final bool _isMuted = false;
  bool _isPlaying = false;
  bool _syncingPlayback = false;
  String _selectedAspectRatio = '9:16';

  // Voice Over State
  bool _isRecordingVoice = false;
  final EditorVoiceoverService _voiceoverService = EditorVoiceoverService();

  // Mask Mode
  bool _isMaskMode = false;
  double _effectVignette = 0.0;
  double _effectGrain = 0.0;
  double _effectBlur = 0.0;

  // Multi-track Sequencer State
  late List<VideoClip> _sequence;
  int _activeClipIndex = 0;
  final Set<VideoClip> _selectedClips = <VideoClip>{};
  bool _multiSelectMode = false;
  bool _groupMoveMode = false;
  List<VideoClip>? _groupDragOriginalSequence;
  double _groupDragOriginX = 0;
  double _groupDragPixelsPerSecond = 48;
  VideoClip? _groupDragAnchorClip;
  int? _timelineDragIndex;
  String? _timelineDragMode;
  double _timelineDragOriginX = 0;
  double _timelineDragDeltaX = 0;
  double _timelineDragAppliedX = 0;
  double _timelineDragThresholdX = 0;
  double _timelineOriginalStart = 0;
  double _timelineOriginalEnd = 0;
  int? _timelineOverlaySelected;
  int? _timelineOverlayDragIndex;
  double _timelineOverlayDragOriginX = 0;
  double _timelineOverlayDragStart = 0;
  double _timelineOverlayDragEnd = 0;
  double _timelineLastPaintedSecond = -1;

  // Professional Metadata
  final Map<int, TransitionOperation> _transitions = {};
  // Estimated renderer metadata
  final double _frameRate = 30.0;
  final int _bitrateKbps = 8000; // assumed default bitrate for size estimate

  // Live project-backed view: overlays are never stored in a second list.
  List<OverlayOperation> get _overlays => _project.tracks
      .where((track) => track.type == TrackType.overlay)
      .expand((track) => track.clips)
      .map((clip) => clip.operation)
      .whereType<OverlayOperation>()
      .toList();

  void _addProjectOverlay(OverlayOperation overlay) {
    final start = Duration(milliseconds: (overlay.start * _totalDuration * 1000).round());
    final end = Duration(milliseconds: (overlay.end * _totalDuration * 1000).round());
    _project.upsertClip(
      TrackType.overlay,
      TimelineClip(
        id: 'overlay-${DateTime.now().microsecondsSinceEpoch}',
        start: start,
        duration: end > start ? end - start : const Duration(seconds: 1),
        operation: overlay,
      ),
    );
  }

  void _removeProjectOverlayAt(int index) {
    final overlays = _overlays;
    if (index < 0 || index >= overlays.length) return;
    final target = overlays[index];
    for (final track in _project.tracks.where((item) => item.type == TrackType.overlay)) {
      for (final clip in track.clips) {
        if (identical(clip.operation, target)) {
          _project.removeClip(clip.id);
          return;
        }
      }
    }
  }

  // Track selection for focused editing
  int _activeNavIndex =
      0; // 0: Timeline, 1: Audio, 2: Text, 3: Trans, 4: Settings
  bool _videoTrackVisible = true;
  bool _musicTrackVisible = true;
  bool _voiceTrackVisible = true;
  bool _textTrackVisible = true;
  bool _videoTrackLocked = false;
  bool _musicTrackLocked = false;
  bool _voiceTrackLocked = false;
  bool _textTrackLocked = false;

  bool _transitionsUnlocked =
      false; // In a real app, fetch this from user state

  // Audio timeline values are stored on their TimelineClip/AudioClipOperation.
  TimelineClip? get _musicClip {
    for (final track in _project.tracks) {
      if (track.type != TrackType.music) continue;
      for (final clip in track.clips) {
        final operation = clip.operation;
        if (operation is AudioClipOperation && operation.sourceType == 'music') {
          return clip;
        }
      }
    }
    return null;
  }

  TimelineClip? get _voiceClip {
    for (final track in _project.tracks) {
      if (track.type != TrackType.voiceOver) continue;
      for (final clip in track.clips) {
        final operation = clip.operation;
        if (operation is AudioClipOperation && operation.sourceType == 'voiceOver') {
          return clip;
        }
      }
    }
    return null;
  }

  AudioClipOperation? get _musicOperation => _musicClip?.operation as AudioClipOperation?;
  AudioClipOperation? get _voiceOperation => _voiceClip?.operation as AudioClipOperation?;
  File? get _voiceOverFile => _voiceClip?.file;
  double get _bgmVolume => _musicOperation?.volume ?? 0.5;
  double get _voiceVolume => _voiceOperation?.volume ?? 0.8;
  double get _audioStart => _musicOperation?.startOffset ?? 0.0;
  double get _audioEnd => _musicOperation?.endOffset ?? 30.0;
  double get _audioOffset => (_musicClip?.start.inMilliseconds ?? 0) / 1000.0;

  void _setTrackVisibility(TrackType type, bool visible) {
    _project.transact((tracks) {
      for (final track in tracks.where((item) => item.type == type)) {
        track.isVisible = visible;
      }
    });
    final playback = _project.playback.state;
    unawaited(
      _syncTimelineAudio(
        playback.currentTime,
        playing: playback.isPlaying,
        force: true,
      ),
    );
  }

  void _setOriginalVolume(double value) {
    _project.transact((tracks) {
      for (final track in tracks.where(
        (item) => item.type == TrackType.video,
      )) {
        for (var index = 0; index < track.clips.length; index++) {
          track.clips[index] = track.clips[index].copyWith(volume: value);
        }
      }
    });
    _originalVolume = value;
    _videoController?.setVolume(value);
  }

  void _setMusicVolume(double value) {
    final clip = _musicClip;
    final operation = _musicOperation;
    if (clip == null || operation == null) return;
    _project.upsertClip(TrackType.music, TimelineClip(
      id: clip.id, start: clip.start, duration: clip.duration, file: clip.file,
      volume: value,
      operation: AudioClipOperation(sourceType: operation.sourceType,
        sourceUrl: operation.sourceUrl, label: operation.label, volume: value,
        speed: operation.speed, reverse: operation.reverse, fadeIn: operation.fadeIn,
        fadeOut: operation.fadeOut, startOffset: operation.startOffset,
        endOffset: operation.endOffset),
    ), recordHistory: false);
  }

  void _setVoiceVolume(double value) {
    final clip = _voiceClip;
    final operation = _voiceOperation;
    if (clip == null || operation == null) return;
    _project.upsertClip(TrackType.voiceOver, TimelineClip(
      id: clip.id, start: clip.start, duration: clip.duration, file: clip.file,
      volume: value,
      operation: AudioClipOperation(sourceType: operation.sourceType,
        sourceUrl: operation.sourceUrl, label: operation.label, volume: value,
        speed: operation.speed, reverse: operation.reverse, fadeIn: operation.fadeIn,
        fadeOut: operation.fadeOut, startOffset: operation.startOffset,
        endOffset: operation.endOffset),
    ), recordHistory: false);
  }

  void _restoreAudioSelectionFromProject() {
    final music = _musicOperation;
    _selectedTrack = null;
    if (music != null && music.sourceUrl != null) {
      _selectedTrack = MusicTrack(id: 'project-' + music.sourceUrl.hashCode.toString(),
        title: music.label ?? 'Project music', artistName: 'Project audio',
        audioUrl: music.sourceUrl!, duration: (_musicClip!.duration.inMilliseconds / 1000).round(),
        licenseType: 'project');
      _musicPlayer.setReleaseMode(ReleaseMode.loop);
    }
  }

  @override
  void initState() {
    super.initState();
    _project = widget.projectController ?? EditorProjectController();
    _ownsProjectController = widget.projectController == null;
    _loadProState();
    _restoreAudioSelectionFromProject();
    final sharedFiles =
        _project.tracks
            .where(
              (track) =>
                  track.type == TrackType.video ||
                  track.type == TrackType.images,
            )
            .expand((track) => track.clips)
            .where((clip) => clip.file != null)
            .map((clip) => clip.file!)
            .toList() ??
        const <File>[];
    final files = sharedFiles.isNotEmpty
        ? sharedFiles
        : widget.multiFiles ??
              (widget.initialVideo != null
                  ? [widget.initialVideo!]
                  : (widget.initialImage != null
                        ? [widget.initialImage!]
                        : []));
    _sequence = files.map((f) => VideoClip(file: f)).toList();
    if (_sequence.isNotEmpty) _selectedClips.add(_sequence.first);
    if (sharedFiles.isNotEmpty) {
      final sharedClips = _project.tracks
          .where(
            (track) =>
                track.type == TrackType.video || track.type == TrackType.images,
          )
          .expand((track) => track.clips)
          .where((clip) => clip.file != null)
          .toList();
      _sequence = sharedClips
          .map(
            (clip) => VideoClip(
              id: clip.id,
              file: clip.file!,
              start: clip.sourceStart.inMilliseconds / 1000,
              end:
                  (clip.sourceEnd ?? clip.sourceStart + clip.sourceDuration)
                      .inMilliseconds /
                  1000,
              duration: clip.sourceDuration.inMilliseconds / 1000,
              speed: clip.speed,
              volume: clip.volume,
              scale: clip.transform.scale,
              rotation: clip.transform.rotation,
              offsetX: clip.transform.position.dx,
              offsetY: clip.transform.position.dy,
              opacity: clip.transform.opacity,
              filter: clip.filter == null ? null : ImageFilter.values.firstWhere(
                (value) => value.name == clip.filter!.filterName,
                orElse: () => ImageFilter.normal,
              ),
              brightness: clip.brightness,
              contrast: clip.contrast,
              saturation: clip.saturation,
              hue: clip.hue,
              vignette: clip.vignette,
              grain: clip.grain,
              blur: clip.blur,
              isReversed: clip.isReversed,
            ),
          )
          .toList();
    }
    final sharedProject = _project;
    for (final timelineClip in sharedProject.tracks.expand(
      (track) => track.clips,
    )) {
      final operation = timelineClip.operation;
      if (operation is TransitionOperation &&
          timelineClip.id.startsWith('desktop-transition-')) {
        final index = int.tryParse(
          timelineClip.id.substring('desktop-transition-'.length),
        );
        if (index != null) _transitions[index] = operation;
      }
    }

    if (widget.initialTrack != null && _musicClip == null) {
      final track = widget.initialTrack!;
      _project.upsertClip(TrackType.music, TimelineClip(
        id: 'desktop-audio-music',
        start: Duration.zero,
        duration: track.timelineDuration,
        volume: 0.5,
        operation: AudioClipOperation(
          sourceType: 'music',
          sourceUrl: track.audioUrl,
          label: track.title,
          volume: 0.5,
          startOffset: 0,
          endOffset: track.duration.toDouble(),
        ),
      ));
      _selectedTrack = track;
      _musicPlayer.setReleaseMode(ReleaseMode.loop);
      _musicPlayer.play(UrlSource(track.audioUrl));
    }

    _loadClip(_activeClipIndex);
    _project.playback.addListener(_followSharedPlaybackClock);
    _probeDurations();
    _loadShaders();

    // Trigger proxy generation for initial clips
    for (var clip in _sequence) {
      if (clip.isVideo) _generateProxyForClip(clip);
    }
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
      setState(() => _shaderProgram = program);
    } catch (e) {
      debugPrint("Error loading shaders: $e");
    }
  }

  double get _totalDuration {
    return _sequence.fold(
      0.0,
      (sum, clip) => sum + (clip.end - clip.start) / clip.speed,
    );
  }

  double _getGlobalTime(int clipIndex, double relativeTime) {
    double total = 0;
    for (int i = 0; i < clipIndex; i++) {
      total += (_sequence[i].end - _sequence[i].start) / _sequence[i].speed;
    }
    return total +
        (relativeTime - _sequence[clipIndex].start) /
            _sequence[clipIndex].speed;
  }

  Future<void> _probeDurations() async {
    for (var clip in _sequence) {
      if (clip.duration == 0) {
        if (clip.isVideo) {
          // Use FFprobe to get accurate metadata including audio stream presence
          try {
            final session = await FFprobeKit.getMediaInformation(
              clip.file.path,
            );
            final info = session.getMediaInformation();
            if (info != null) {
              final durationStr = info.getDuration();
              if (durationStr != null) {
                clip.duration = double.tryParse(durationStr) ?? 0.0;
              }

              // Check for audio streams
              final streams = info.getStreams();
              clip.hasAudio = streams.any((s) => s.getType() == 'audio');

              if (clip.end <= 0.1) clip.end = clip.duration;
            }
          } catch (e) {
            debugPrint("Error probing with FFprobe: $e");
            // Fallback to VideoPlayer if FFprobe fails
            final controller = VideoPlayerController.file(clip.file);
            try {
              await controller.initialize();
              clip.duration = controller.value.duration.inMilliseconds / 1000.0;
              if (clip.end <= 0.1) clip.end = clip.duration;
              await controller.dispose();
            } catch (e2) {
              clip.duration = 3.0;
              if (clip.end <= 0.1) clip.end = 3.0;
            }
          }
        } else {
          // It's an image
          clip.duration = 3.0;
          clip.hasAudio = false;
          if (clip.end <= 0.1) clip.end = 3.0;
        }
      }
    }
    if (mounted) setState(() {});
    _syncSharedProjectFromSequence();
  }

  void _loadClip(int index, {double? seekTo}) {
    if (_sequence.isEmpty) return;
    final clip = _sequence[index];

    if (clip.isVideo) {
      final mediaFile = clip.isReversed && clip.reversePreviewFile != null
          ? clip.reversePreviewFile!
          : (clip.isProxyReady ? clip.proxyFile! : clip.file);

      if (!mediaFile.existsSync() || mediaFile.lengthSync() == 0) {
        debugPrint(
          '❌ MediaEditor: Clip file is empty or missing! ${mediaFile.path}',
        );
        _feedback("Error: Footage is empty or corrupt");
        return;
      }

      _videoController?.dispose();
      final controller = VideoPlayerController.file(mediaFile);
      _videoController = controller;

      controller.initialize().then((_) async {
        // A newer clip may have replaced this controller while initialization
        // was in flight. Never let a stale callback touch the active player.
        if (!mounted || !identical(_videoController, controller)) return;

        if (clip.duration <= 0) {
          clip.duration = controller.value.duration.inMilliseconds / 1000.0;
          clip.end = clip.duration;
        }

        await controller.setVolume(_isMuted ? 0.0 : _originalVolume);
        if (!mounted || !identical(_videoController, controller)) return;
        await controller.setPlaybackSpeed(clip.speed);
        final sourceTime = seekTo ?? (clip.isReversed ? clip.end : clip.start);
        final playbackTime = clip.isReversed
            ? (clip.duration - sourceTime).clamp(0.0, clip.duration)
            : sourceTime;
        await controller.seekTo(
          Duration(milliseconds: (playbackTime * 1000).toInt()),
        );

        if (!mounted || !identical(_videoController, controller)) return;
        if (_isPlaying) _syncPlay();
        setState(() {});
      }).catchError((Object error, StackTrace stack) {
        debugPrint('MediaEditor: clip initialization failed: $error');
        if (identical(_videoController, controller)) {
          if (mounted) {
            setState(() => _videoController = null);
            _feedback('Unable to load this clip');
          } else {
            _videoController = null;
          }
          unawaited(controller.dispose());
        }
      });

      controller.addListener(() {
        if (!mounted ||
            !identical(_videoController, controller) ||
            !controller.value.isInitialized) {
          return;
        }
        if (clip.end <= 0.1) return;

        final pos = controller.value.position.inMilliseconds / 1000.0;
        final reachedClipEnd = clip.isReversed
            ? pos >= clip.duration - clip.start
            : pos >= clip.end;
        if (_ownsProjectController && reachedClipEnd) {
          if (_activeClipIndex < _sequence.length - 1) {
            setState(() => _activeClipIndex++);
            _loadClip(_activeClipIndex);
          } else {
            // Loop sequence
            setState(() => _activeClipIndex = 0);
            _loadClip(_activeClipIndex);
          }
        }
        if (mounted && identical(_videoController, controller)) {
          setState(() {});
        }
      });
    } else {
      _videoController?.dispose();
      _videoController = null;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _project.playback.removeListener(_followSharedPlaybackClock);
    _videoController?.dispose();
    _musicPlayer.dispose();
    _voicePlayer.dispose();
    for (final player in _timelineAudioPlayers.values) {
      player.dispose();
    }
    _timelineAudioPlayers.clear();
    _timelineAudioSources.clear();
    _voiceoverService.dispose();
    _enhancementService.dispose();
    if (_ownsProjectController) _project.dispose();
    super.dispose();
  }

  Future<void> _followSharedPlaybackClock() async {
    final project = _project;
    if (!mounted || project == null || _sequence.isEmpty || _syncingPlayback) {
      return;
    }
    _syncingPlayback = true;
    try {
      final state = project.playback.state;
      var remaining = state.currentTime.inMicroseconds / 1000000.0;
      var index = 0;
      for (; index < _sequence.length - 1; index++) {
        final duration =
            (_sequence[index].end - _sequence[index].start) /
            _sequence[index].speed;
        if (remaining < duration) break;
        remaining -= duration;
      }
      if (index != _activeClipIndex) {
        _activeClipIndex = index;
        _loadClip(index, seekTo: _sequence[index].start + remaining);
      }
      final controller = _videoController;
      if (controller != null && controller.value.isInitialized) {
        final sourceExpected = _sequence[index].start + remaining;
        final expected = _sequence[index].isReversed
            ? _sequence[index].duration - sourceExpected
            : sourceExpected;
        final actual = controller.value.position.inMilliseconds / 1000.0;
        if ((actual - expected).abs() > 0.15) {
          await controller.seekTo(
            Duration(milliseconds: (expected * 1000).round()),
          );
        }
        if (state.isPlaying && !controller.value.isPlaying) {
          await controller.play();
        } else if (!state.isPlaying && controller.value.isPlaying) {
          await controller.pause();
        }
      }
      await _syncTimelineAudio(state.currentTime, playing: state.isPlaying);
      final timelineSecond = state.currentTime.inMilliseconds / 1000.0;
      if (mounted &&
          ((_isPlaying != state.isPlaying) ||
           (timelineSecond - _timelineLastPaintedSecond).abs() >= 0.1)) {
        setState(() {
          _isPlaying = state.isPlaying;
          _timelineLastPaintedSecond = timelineSecond;
        });
      }
    } finally {
      _syncingPlayback = false;
    }
  }

  void _saveHistory() {
    final project = _project;
    if (project != null) project.history.capture(project.tracks);
  }

  void _undo() {
    final project = _project;
    if (project == null) return;
    final restored = project.history.undo(project.tracks);
    if (restored == null) return;
    HapticFeedback.lightImpact();
    project.replaceTracks(restored);
    _restoreDesktopViewFromProject();
  }

  void _redo() {
    final project = _project;
    if (project == null) return;
    final restored = project.history.redo(project.tracks);
    if (restored == null) return;
    HapticFeedback.lightImpact();
    project.replaceTracks(restored);
    _restoreDesktopViewFromProject();
  }

  void _restoreDesktopViewFromProject() {
    _restoreAudioSelectionFromProject();
    final project = _project;
    if (project == null) return;
    final visual =
        project.tracks
            .where(
              (track) =>
                  track.type == TrackType.video ||
                  track.type == TrackType.images,
            )
            .expand((track) => track.clips)
            .where((clip) => clip.file != null)
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    setState(() {
      _sequence = visual
          .map(
            (clip) => VideoClip(
              file: clip.file!,
              start: clip.sourceStart.inMilliseconds / 1000,
              end:
                  (clip.sourceEnd ?? clip.sourceStart + clip.sourceDuration)
                      .inMilliseconds /
                  1000,
              duration: clip.sourceDuration.inMilliseconds / 1000,
              speed: clip.speed,
              volume: clip.volume,
              scale: clip.transform.scale,
              rotation: clip.transform.rotation,
              offsetX: clip.transform.position.dx,
              offsetY: clip.transform.position.dy,
              opacity: clip.transform.opacity,
              filter: clip.filter == null ? null : ImageFilter.values.firstWhere(
                (value) => value.name == clip.filter!.filterName,
                orElse: () => ImageFilter.normal,
              ),
              brightness: clip.brightness,
              contrast: clip.contrast,
              saturation: clip.saturation,
              hue: clip.hue,
              vignette: clip.vignette,
              grain: clip.grain,
              blur: clip.blur,
            ),
          )
          .toList();
      _activeClipIndex = _sequence.isEmpty
          ? 0
          : _activeClipIndex.clamp(0, _sequence.length - 1);
      _selectedClips
        ..clear()
        ..addAll(_sequence.isEmpty ? <VideoClip>[] : <VideoClip>[_sequence[_activeClipIndex]]);
      _multiSelectMode = false;
      if (_sequence.isNotEmpty) _loadClip(_activeClipIndex);
    });
  }

  /// Reconciles the legacy preview adapters with the shared project without
  /// destroying and recreating every visual track. Existing TimelineClip
  /// identities and track metadata are retained; only changed visual clips and
  /// desktop transition records are replaced inside one project transaction.
  ///
  /// This is a compatibility bridge while the remaining editor commands are
  /// being moved to direct TimelineClip mutations. Do not add new editing
  /// commands that mutate _sequence.
  void _syncSharedProjectFromSequence() {
    final project = _project;
    if (project == null) return;

    project.transact((tracks) {
      final visualTypes = <TrackType>{TrackType.video, TrackType.images};
      final existingById = <String, TimelineClip>{
        for (final track in tracks.where((item) => visualTypes.contains(item.type)))
          for (final clip in track.clips) clip.id: clip,
      };
      final retainedIds = <String>{};
      var timelineStart = Duration.zero;

      for (final previewClip in _sequence) {
        final sourceStart = Duration(
          milliseconds: (previewClip.start * 1000).round(),
        );
        final sourceEnd = Duration(
          milliseconds: (previewClip.end * 1000).round(),
        );
        final timelineDuration = Duration(
          milliseconds: (((previewClip.end - previewClip.start) /
                    previewClip.speed) *
                1000)
              .round(),
        );
        final type = previewClip.isVideo ? TrackType.video : TrackType.images;
        final existing = existingById[previewClip.id];
        final transform = existing?.transform ?? TransformOperation();
        transform
          ..scale = previewClip.scale
          ..rotation = previewClip.rotation
          ..position = Offset(previewClip.offsetX, previewClip.offsetY)
          ..opacity = previewClip.opacity;

        final nextClip = TimelineClip(
          id: previewClip.id,
          start: timelineStart,
          duration: timelineDuration,
          file: previewClip.file,
          proxyFile: previewClip.proxyFile,
          isProxyReady: previewClip.isProxyReady,
          sourceStart: sourceStart,
          sourceEnd: sourceEnd,
          speed: previewClip.speed,
          volume: previewClip.volume,
          isReversed: previewClip.isReversed,
          operation: TrimOperation(
            start: sourceStart,
            end: sourceEnd,
            maxDuration: Duration(
              milliseconds: (previewClip.duration * 1000).round(),
            ),
          ),
          transform: transform,
          brightness: previewClip.brightness,
          contrast: previewClip.contrast,
          saturation: previewClip.saturation,
          hue: previewClip.hue,
          vignette: previewClip.vignette,
          grain: previewClip.grain,
          blur: previewClip.blur,
          filter: previewClip.filter == null
              ? null
              : FilterOperation(filterName: previewClip.filter!.name),
        );
        TimelineModelUtils.insertClip(tracks, nextClip, type);
        retainedIds.add(previewClip.id);
        timelineStart += timelineDuration;
      }

      for (final track in tracks.where((item) => visualTypes.contains(item.type))) {
        track.clips.removeWhere((clip) => !retainedIds.contains(clip.id));
      }
      tracks.removeWhere(
        (track) => visualTypes.contains(track.type) && track.clips.isEmpty,
      );

      for (final track in tracks) {
        track.clips.removeWhere(
          (clip) => clip.id.startsWith('desktop-transition-'),
        );
      }
      tracks.removeWhere((track) => track.clips.isEmpty);

      _transitions.forEach((clipIndex, transition) {
        var start = Duration.zero;
        for (var index = 0;
            index <= clipIndex && index < _sequence.length;
            index++) {
          final clip = _sequence[index];
          start += Duration(
            milliseconds: (((clip.end - clip.start) / clip.speed) * 1000)
                .round(),
          );
        }
        final transitionStart = start -
            Duration(milliseconds: (transition.duration * 500).round());
        TimelineModelUtils.insertClip(
          tracks,
          TimelineClip(
            id: 'desktop-transition-$clipIndex',
            start: transitionStart.isNegative ? Duration.zero : transitionStart,
            duration: Duration(
              milliseconds: (transition.duration * 1000).round(),
            ),
            operation: transition,
          ),
          TrackType.effects,
        );
      });
    }, recordHistory: false);
  }

  Future<void> _addClip() async {
    final picked = await _mediaService.pickMedia();
    if (picked.isNotEmpty) {
      _saveHistory();
      final newClips = picked
          .map((asset) => VideoClip(file: asset.file))
          .toList();

      setState(() {
        _sequence.addAll(newClips);
      });

      await _probeDurations();
      _syncSharedProjectFromSequence();

      // Start background proxy generation for video clips
      for (var clip in newClips) {
        if (clip.isVideo) {
          _generateProxyForClip(clip);
        }
      }

      _feedback("Clips Added!");
    }
  }

  Future<void> _generateProxyForClip(VideoClip clip) async {
    // Don't proxy small files (e.g. < 5MB) to save time/space
    try {
      final size = await clip.file.length();
      if (size < 5 * 1024 * 1024) {
        debugPrint("Skipping proxy for small clip: ${clip.file.path}");
        return;
      }
    } catch (_) {}

    final proxy = await _videoService.generateProxy(clip.file);
    if (proxy.path != clip.file.path) {
      setState(() {
        clip.proxyFile = proxy;
        clip.isProxyReady = true;
      });
      debugPrint("Proxy Ready for clip: ${clip.file.path}");

      // If this is the active clip, reload the player to use proxy
      if (_sequence.indexOf(clip) == _activeClipIndex) {
        _loadClip(_activeClipIndex);
      }
    }
  }

  double _estimateSizeBytes({int bitrateKbps = -1}) {
    final kbps = bitrateKbps <= 0 ? _bitrateKbps : bitrateKbps;
    final bits =
        _totalDuration * kbps * 1000.0; // kilobits -> bits/sec * seconds
    return bits / 8.0; // bytes
  }

  String _formatBytes(double bytes) {
    if (bytes <= 0) return '0 B';
    final mb = bytes / (1024 * 1024);
    if (mb < 1) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  void _showAdjustSheet() {
    if (_sequence.isEmpty) return;
    final targets = _effectTargets;
    _syncLookControlsFromClip(targets.first);
    _saveHistory();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: C.dim),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'COLOR GRADING (GPU)',
                style: syne(sz: 14, w: FontWeight.w900, ls: 2),
              ),
              SizedBox(height: 24),
              _adjustSlider('Brightness', _brightness, -0.5, 0.5, (v) {
                setModalState(() => _brightness = v);
                for (final target in targets) { target.brightness = v; }
                setState(() => _syncSharedProjectFromSequence());
              }),
              _adjustSlider('Contrast', _contrast, 0.5, 1.5, (v) {
                setModalState(() => _contrast = v);
                for (final target in targets) { target.contrast = v; }
                setState(() => _syncSharedProjectFromSequence());
              }),
              _adjustSlider('Saturation', _saturation, 0.0, 2.0, (v) {
                setModalState(() => _saturation = v);
                for (final target in targets) { target.saturation = v; }
                setState(() => _syncSharedProjectFromSequence());
              }),
              _adjustSlider('Hue', _hue, -3.14, 3.14, (v) {
                setModalState(() => _hue = v);
                for (final target in targets) { target.hue = v; }
                setState(() => _syncSharedProjectFromSequence());
              }),
              SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setModalState(() {
                    _brightness = 0.0;
                    _contrast = 1.0;
                    _saturation = 1.0;
                    _hue = 0.0;
                    for (final target in targets) {
                      target.brightness = 0.0;
                      target.contrast = 1.0;
                      target.saturation = 1.0;
                      target.hue = 0.0;
                    }
                  });
                  setState(() {});
                },
                child: Text(
                  'RESET ALL',
                  style: syne(sz: 10, w: FontWeight.w900, c: C.brand),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _adjustSlider(
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
            Text(label, style: dm(sz: 10, c: C.sub)),
            Text(value.toStringAsFixed(2), style: dm(sz: 10, c: C.brand)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          activeColor: C.brand,
          inactiveColor: C.dim,
          onChanged: onChanged,
        ),
      ],
    );
  }

  void _onNext() async {
    HapticFeedback.heavyImpact();
    _videoController?.pause();
    await _musicPlayer.stop();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.95),
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'CHOOSE EXPORT PATH',
              style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
            ),
            SizedBox(height: 24),
            _exportOption(
              'FINAL MP4 MASTER',
              'One validated video with original sound, music and voiceover embedded for Feed and Shop.',
              Icons.video_library,
              () {
                Navigator.pop(context);
                _finish();
              },
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _finish() async {
    if (_sequence.isEmpty) return;

    File? combinedFile;
    var audioExpected = false;
    setState(() => _isProcessing = true);
      try {
        _feedback("Rendering final video and audio...");
        final snapshot = _project.createSnapshot();
        audioExpected = await EditorExportService.projectHasAudio(snapshot);
        combinedFile = await EditorExportService.renderTimeline(
          tracks: snapshot,
          aspectRatio: _selectedAspectRatio,
        );

        if (combinedFile == null) {
          _feedback("The final video could not be rendered. Your timeline is unchanged.");
        } else {
          final validation = await EditorExportService.inspectFinalMp4(
            combinedFile,
            requireAudio: audioExpected,
          );
          if (validation['valid'] != true) {
            combinedFile = null;
            _feedback(
              audioExpected
                  ? "Export validation failed: the MP4 is missing expected audio or video."
                  : "Export validation failed: the MP4 is missing its video stream.",
            );
          } else {
            _feedback("Final MP4 validated and ready.");
          }
        }
      } catch (e) {
        combinedFile = null;
        _feedback("Error rendering final media: $e");
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
      // Never fall back to publishing the first source clip when flattening
      // fails; that would silently discard timeline edits and audio.
    if (combinedFile == null) return;

    Navigator.pop(context, {
      'sequence': _sequence,
      'track': _selectedTrack,
      'flatten': true,
      'combined_file': combinedFile,
      'audio_expected': audioExpected,
      'music_vol': _bgmVolume,
      'voice_vol': _voiceVolume,
      'original_vol': _originalVolume,
      'aspect_ratio': _selectedAspectRatio,
      'voice_over': _voiceOverFile,
      'overlays': _overlays.map((overlay) => overlay.toJson()).toList(),
      'transitions': _transitions.map(
        (index, transition) => MapEntry(index, transition.toJson()),
      ),
      'filter': _selectedFilter,
      'color_grade': {
        'brightness': _brightness,
        'contrast': _contrast,
        'saturation': _saturation,
        'hue': _hue,
      },
      'effects': {
        'vignette': _effectVignette,
        'grain': _effectGrain,
        'blur': _effectBlur,
      },
      'clip_transforms': _sequence
          .map(
            (c) => {
              'scale': c.scale,
              'rotation': c.rotation,
              'offsetX': c.offsetX,
              'offsetY': c.offsetY,
              'opacity': c.opacity,
            },
          )
          .toList(),
      'beauty': _faceEngine.intensity,
      'facePreset': _faceEngine.selectedPreset.id,
      'total_duration': _totalDuration,
      'clip_count': _sequence.length,
    });
  }

  void _togglePlayback() {
    setState(() => _isPlaying = !_isPlaying);
    final project = _project;
    if (_isPlaying) {
      if (project != null) project.playback.play(project.tracks);
      _syncPlay();
    } else {
      project?.playback.pause();
      _syncPause();
    }
  }

  void _syncPlay() async {
    await _musicPlayer.stop();
    await _voicePlayer.stop();
    final controller = _videoController;
    if (controller != null && controller.value.isInitialized) {
      await controller.play();
    }
    await _syncTimelineAudio(
      _project.playback.state.currentTime,
      playing: true,
      force: true,
    );
  }

  Future<void> _syncTimelineAudio(
    Duration playhead, {
    required bool playing,
    bool force = false,
  }) async {
    if (_syncingTimelineAudio) return;
    final syncDelta = playhead >= _lastTimelineAudioSync
        ? playhead - _lastTimelineAudioSync
        : _lastTimelineAudioSync - playhead;
    if (!force && syncDelta < const Duration(milliseconds: 100)) return;
    _syncingTimelineAudio = true;
    _lastTimelineAudioSync = playhead;
    try {
      final activeIds = <String>{};
      for (final track in _project.tracks.where((item) => item.isVisible)) {
        for (final clip in track.clips.where((item) => !item.isHidden)) {
          final operation = clip.operation;
          if (operation is! AudioClipOperation) continue;
          final clipEnd = clip.start + clip.duration;
          if (playhead < clip.start || playhead >= clipEnd) continue;
          final source = clip.file?.path ?? operation.sourceUrl;
          if (source == null || source.isEmpty) continue;
          final elapsed =
              (playhead - clip.start).inMicroseconds /
              Duration.microsecondsPerSecond;
          final speed = clip.speed == 1.0 ? operation.speed : clip.speed;
          final sourceStart =
              operation.startOffset ?? clip.sourceStart.inMilliseconds / 1000.0;
          final reversed = clip.isReversed || operation.reverse;
          var previewSource = source;
          var targetSeconds = sourceStart + elapsed * speed;
          if (reversed) {
            final sourceEnd = operation.endOffset ??
                (clip.sourceEnd?.inMilliseconds ?? 0) / 1000.0;
            final resolvedEnd = sourceEnd > sourceStart
                ? sourceEnd
                : sourceStart +
                    (clip.duration.inMilliseconds / 1000.0) * speed;
            final cacheKey = '$source|$sourceStart|$resolvedEnd';
            var reversedFile = _timelineReversedAudioCache[cacheKey];
            if (reversedFile == null || !await reversedFile.exists()) {
              reversedFile = await _videoService.createReversedAudioPreview(
                source: source,
                sourceStart: sourceStart,
                sourceEnd: resolvedEnd,
              );
              if (reversedFile == null) continue;
              _timelineReversedAudioCache[cacheKey] = reversedFile;
            }
            previewSource = reversedFile.path;
            targetSeconds = elapsed * speed;
          }

          activeIds.add(clip.id);
          final player = _timelineAudioPlayers.putIfAbsent(
            clip.id,
            AudioPlayer.new,
          );
          final sourceChanged =
              _timelineAudioSources[clip.id] != previewSource;
          if (sourceChanged) {
            await player.stop();
            await player.setReleaseMode(ReleaseMode.stop);
            await player.setSource(DeviceFileSource(previewSource));
            _timelineAudioSources[clip.id] = previewSource;
          }
          final currentPosition = await player.getCurrentPosition();
          if (sourceChanged ||
              currentPosition == null ||
              (currentPosition.inMilliseconds / 1000.0 - targetSeconds).abs() >
                  0.22) {
            await player.seek(
              Duration(milliseconds: (targetSeconds * 1000).round()),
            );
          }

          final durationSeconds = clip.duration.inMilliseconds / 1000.0;
          final fadeWindow = durationSeconds / 2;
          final fadeIn = operation.fadeIn.clamp(0.0, fadeWindow).toDouble();
          final fadeOut = operation.fadeOut.clamp(0.0, fadeWindow).toDouble();
          var fade = 1.0;
          if (fadeIn > 0 && elapsed < fadeIn) {
            fade = (elapsed / fadeIn).clamp(0.0, 1.0);
          }
          final remaining = durationSeconds - elapsed;
          if (fadeOut > 0 && remaining < fadeOut) {
            fade = math.min(fade, (remaining / fadeOut).clamp(0.0, 1.0));
          }
          final baseVolume = clip.volume == 1.0
              ? operation.volume
              : clip.volume;
          var duckingFactor = 1.0;
          if (operation.sourceType == 'music') {
            final voiceoverActive = _project.tracks.any(
              (track) =>
                  track.type == TrackType.voiceOver &&
                  track.isVisible &&
                  track.clips.any((voiceClip) {
                    final voiceOperation = voiceClip.operation;
                    final voiceVolume =
                        voiceOperation is AudioClipOperation &&
                            voiceClip.volume == 1.0
                        ? voiceOperation.volume
                        : voiceClip.volume;
                    return !voiceClip.isHidden &&
                        voiceVolume > 0 &&
                        voiceClip.start <= playhead &&
                        voiceClip.start + voiceClip.duration > playhead;
                  }),
            );
            if (voiceoverActive) duckingFactor = 0.30;
          }
          await player.setVolume(
            (baseVolume * fade * duckingFactor)
                .clamp(0.0, 1.0)
                .toDouble(),
          );
          if (sourceChanged || _timelineAudioSpeeds[clip.id] != speed) {
            try {
              await player.setPlaybackRate(speed.clamp(0.5, 2.0).toDouble());
              _timelineAudioSpeeds[clip.id] = speed;
            } catch (_) {}
          }
          if (playing) {
            await player.resume();
          } else {
            await player.pause();
          }
        }
      }

      for (final entry in _timelineAudioPlayers.entries) {
        if (!activeIds.contains(entry.key)) {
          await entry.value.pause();
        }
      }
    } catch (error) {
      debugPrint('Timeline audio preview sync failed: $error');
    } finally {
      _syncingTimelineAudio = false;
    }
  }

  void _syncPause() {
    _videoController?.pause();
    _musicPlayer.pause();
    _voicePlayer.pause();
    for (final player in _timelineAudioPlayers.values) {
      player.pause();
    }
  }

  Widget _exportOption(
    String title,
    String sub,
    IconData icon,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: C.dim,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.brand.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(icon, color: C.brand, size: 28),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: syne(sz: 13, w: FontWeight.w800, c: C.text),
                  ),
                  Text(sub, style: dm(sz: 10, c: C.dim)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showVolumeSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.95),
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'AUDIO MIXER',
                style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
              ),
              SizedBox(height: 32),
              _volSlider('Original Video', _originalVolume, (v) {
                setModalState(() => _originalVolume = v);
                setState(() => _setOriginalVolume(v));
              }),
              SizedBox(height: 16),
              _volSlider('Background Music', _bgmVolume, (v) {
                setModalState(() {});
                _setMusicVolume(v);
                _musicPlayer.setVolume(v);
              }),
              SizedBox(height: 16),
              _volSlider('Voiceover', _voiceVolume, (v) {
                setModalState(() {});
                _setVoiceVolume(v);
                _voicePlayer.setVolume(v);
              }),
              SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _volSlider(String label, double val, Function(double) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: dm(sz: 11, c: C.sub)),
        Slider(value: val, onChanged: onChanged, activeColor: C.brand),
      ],
    );
  }

  // - [x] **Phase 1: Restore Missing Tool Sheets**
  //   - [x] `_showTrimSheet` (Range selection for VideoClip)
  //   - [x] `_showSpeedSheet` (Playback velocity selector)
  //   - [x] `_showSoundPicker` (Music library integration)
  //   - [x] `_showFilterSheet` (Horizontal filter selector)
  //   - [x] `_showBeautySheet` (Slider-based enhancement)

  void _showCropSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        height: 140,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.95),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: ['9:16', '1:1', '4:5']
              .map(
                (r) => GestureDetector(
                  onTap: () {
                    setState(() => _selectedAspectRatio = r);
                    Navigator.pop(context);
                  },
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.crop_square,
                        color: _selectedAspectRatio == r
                            ? C.brand
                            : C.dim,
                      ),
                      Text(
                        r,
                        style: syne(
                          sz: 10,
                          c: _selectedAspectRatio == r
                              ? C.brand
                              : C.dim,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Future<void> _onSaveDraft() async {
    HapticFeedback.mediumImpact();
    setState(() => _isProcessing = true);
    try {
      final file = widget.initialVideo ?? widget.initialImage;
      if (file == null) {
        _feedback("Nothing to save!");
        return;
      }

      await widget.state.drafts.saveDraft(
        mediaFile: file,
        trackId: _selectedTrack?.id,
        caption: "",
      );
      _feedback("Saved to Drafts!");
      await Future.delayed(Duration(milliseconds: 500));
      if (mounted) widget.state.go('upload');
    } catch (e) {
      _feedback("Saving failed: $e");
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _feedback(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: syne(sz: 12, c: C.text, w: FontWeight.bold),
        ),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _jumpToPreviousClip() {
    if (_sequence.isEmpty) return;
    final nextIndex = (_activeClipIndex - 1).clamp(0, _sequence.length - 1);
    if (nextIndex != _activeClipIndex) {
      setState(() => _activeClipIndex = nextIndex);
      _loadClip(nextIndex);
    }
  }

  void _jumpToNextClip() {
    if (_sequence.isEmpty) return;
    final nextIndex = (_activeClipIndex + 1).clamp(0, _sequence.length - 1);
    if (nextIndex != _activeClipIndex) {
      setState(() => _activeClipIndex = nextIndex);
      _loadClip(nextIndex);
    }
  }

  void _showFullscreenPreview() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(child: Container(color: Colors.black)),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      children: [
                        _circleBtn(Icons.close, () => Navigator.pop(context)),
                        Spacer(),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: C.text.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Fullscreen Preview',
                            style: syne(
                              sz: 12,
                              w: FontWeight.w700,
                              c: C.text,
                            ),
                          ),
                        ),
                        Spacer(),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 9 / 16,
                        child: MaskingPreview(
                          isMasked: _isMaskMode,
                          onToggle: () =>
                              setState(() => _isMaskMode = !_isMaskMode),
                          overlays: _buildVisibleOverlays(),
                          child: _buildPreviewLayer(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final horizontalPadding = width < 720 ? 10.0 : 14.0;
    return Scaffold(
      backgroundColor: Color(0xFF070A10),
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                10,
                horizontalPadding,
                14,
              ),
              child: Column(
                children: [
                  _buildStudioHeader(),
                  SizedBox(height: 12),
                  Expanded(child: _buildStudioWorkspace()),
                  SizedBox(height: 12),
                  _buildEditorDock(),
                ],
              ),
            ),
          ),
          if (_isProcessing) _buildProcessingOverlay(),
        ],
      ),
    );
  }

  Widget _buildStudioHeader() {
    return Container(
      constraints: BoxConstraints(minHeight: 74),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Color(0xFF0E121B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.22),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 860;
          final title = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _circleBtn(
                Icons.arrow_back_ios_new,
                () => Navigator.pop(context),
              ),
              SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Necxa Studio',
                    style: syne(sz: 17, w: FontWeight.w900, c: C.text),
                  ),
                  Text(
                    'Professional layer editor',
                    style: dm(sz: 11, c: C.dim),
                  ),
                ],
              ),
            ],
          );

          final meta = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMetaPill(Icons.aspect_ratio_outlined, _selectedAspectRatio),
              _buildMetaPill(
                Icons.high_quality_outlined,
                _projectResolutionLabel(),
              ),
              _buildMetaPill(
                Icons.speed_outlined,
                '${_frameRate.toStringAsFixed(0)} fps',
              ),
              _buildMetaPill(
                Icons.timer_outlined,
                _formatDuration(_totalDuration),
              ),
              _buildMetaPill(
                Icons.save_alt_outlined,
                _formatBytes(_estimateSizeBytes()),
              ),
            ],
          );

          final actions = Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _iconTextBtn(Icons.undo, 'Undo', _undo),
              _iconTextBtn(Icons.redo, 'Redo', _redo),
              _iconTextBtn(Icons.save_outlined, 'Draft', _onSaveDraft),
              GestureDetector(
                onTap: _onNext,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: C.blue,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: C.blue.withOpacity(0.25),
                        blurRadius: 18,
                      ),
                    ],
                  ),
                  child: Text(
                    'Export',
                    style: syne(sz: 12, w: FontWeight.w900, c: C.text),
                  ),
                ),
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [title, Spacer()]),
                SizedBox(height: 9),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: actions,
                ),
                SizedBox(height: 9),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: meta,
                ),
              ],
            );
          }

          return Row(
            children: [
              title,
              SizedBox(width: 18),
              Expanded(child: meta),
              SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _buildStudioWorkspace() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 920) {
          return Column(
            children: [
              Expanded(child: _buildPreviewStage()),
              SizedBox(height: 10),
              SizedBox(height: 78, child: _buildMobileClipStrip()),
            ],
          );
        }

        final assetWidth = constraints.maxWidth < 1180 ? 220.0 : 260.0;
        final inspectorWidth = constraints.maxWidth < 1180 ? 280.0 : 320.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 98, child: _buildCategoryPanel()),
            SizedBox(width: 12),
            SizedBox(width: assetWidth, child: _buildAssetsPanel()),
            SizedBox(width: 12),
            Expanded(child: _buildPreviewStage()),
            SizedBox(width: 12),
            SizedBox(width: inspectorWidth, child: _buildInspectorPanel()),
          ],
        );
      },
    );
  }

  Widget _buildMobileClipStrip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1018),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Tooltip(
            message: 'Add media',
            child: IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: _addClip,
              icon: Icon(Icons.add_circle_outline, color: C.brand, size: 22),
            ),
          ),
          Expanded(
            child: _sequence.isEmpty
                ? Center(
                    child: Text(
                      'Add a video or photo to begin',
                      style: dm(sz: 11, c: C.dim),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _sequence.length,
                    separatorBuilder: (_, __) => SizedBox(width: 7),
                    itemBuilder: (context, index) {
                      final clip = _sequence[index];
                      final selected = _selectedClips.contains(clip);
                      final active = index == _activeClipIndex;
                      final fileName = clip.file.path
                          .split(RegExp(r'[\\/]+'))
                          .last;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            if (_multiSelectMode) {
                              if (!_selectedClips.add(clip)) {
                                _selectedClips.remove(clip);
                              }
                            } else {
                              _selectedClips
                                ..clear()
                                ..add(clip);
                            }
                            _activeClipIndex = index;
                          });
                          _loadClip(index);
                        },
                        child: Container(
                          constraints: BoxConstraints(maxWidth: 148, minWidth: 104),
                          padding: EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                          decoration: BoxDecoration(
                            color: selected
                                ? C.brand.withOpacity(0.13)
                                : C.text.withOpacity(0.045),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: active
                                  ? C.brand
                                  : C.text.withOpacity(0.08),
                              width: active ? 1.4 : 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                clip.isVideo ? Icons.movie_outlined : Icons.image_outlined,
                                color: selected ? C.brand : C.sub,
                                size: 16,
                              ),
                              SizedBox(width: 6),
                              Flexible(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      fileName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: syne(
                                        sz: 9,
                                        w: FontWeight.w700,
                                        c: C.text,
                                      ),
                                    ),
                                    Text(
                                      '\${((clip.end - clip.start) / clip.speed).toStringAsFixed(1)}s',
                                      style: dm(sz: 8, c: C.dim),
                                    ),
                                  ],
                                ),
                              ),
                              if (_multiSelectMode && selected) ...[
                                SizedBox(width: 4),
                                Icon(Icons.check_circle, color: C.brand, size: 13),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewStage() {
    final ratio = _selectedAspectRatio == '1:1'
        ? 1.0
        : (_selectedAspectRatio == '4:5' ? 4 / 5 : 9 / 16);
    return Container(
      decoration: BoxDecoration(
        color: Color(0xFF06080D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 30,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Text(
                  'Preview',
                  style: syne(sz: 12, w: FontWeight.w900, c: C.sub),
                ),
                Spacer(),
                _buildTransportBar(showLabels: false),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.fromLTRB(18, 4, 18, 18),
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: C.text.withOpacity(0.08)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(7),
                      child: MaskingPreview(
                        isMasked: _isMaskMode,
                        onToggle: () =>
                            setState(() => _isMaskMode = !_isMaskMode),
                        overlays: _buildVisibleOverlays(),
                        child: _buildPreviewLayer(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: _buildTransportBar(showLabels: true),
          ),
        ],
      ),
    );
  }

  Widget _buildSequenceTimeline() {
    const pixelsPerSecond = 48.0;
    final duration = _totalDuration > 0 ? _totalDuration : 1.0;
    final double totalWidth = math.max(320.0, duration * pixelsPerSecond).toDouble();
    final viewportWidth = MediaQuery.of(context).size.width - 32;
    final playheadSeconds =
        _project.playback.state.currentTime.inMilliseconds / 1000.0;
    final playheadX = (playheadSeconds * pixelsPerSecond)
        .clamp(0.0, totalWidth).toDouble();

    Widget trackLabel(IconData icon, String label) => SizedBox(
      width: 68,
      child: Row(children: [
        Icon(icon, size: 12, color: C.sub),
        const SizedBox(width: 5),
        Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: syne(sz: 8, w: FontWeight.w800, c: C.sub))),
      ]),
    );

    Widget timeRuler() => SizedBox(
      height: 22,
      child: Stack(children: [
        Positioned.fill(child: CustomPaint(
          painter: _EditorTimelineRulerPainter(
            pixelsPerSecond: pixelsPerSecond, duration: duration,
            color: C.text.withOpacity(0.22),
          ),
        )),
        Positioned(left: playheadX - 1, top: 0, bottom: 0,
          child: Container(width: 2, color: C.brand)),
      ]),
    );

    Widget videoLane() => SizedBox(
      height: 48,
      child: Row(children: [
        trackLabel(Icons.movie_outlined, 'VIDEO'),
        Expanded(child: SizedBox(
          height: 42,
          child: Stack(children: [
            for (var index = 0; index < _sequence.length; index++)
              Builder(builder: (context) {
                final clip = _sequence[index];
                final seconds = ((clip.end - clip.start) / clip.speed)
                    .clamp(0.05, double.infinity).toDouble();
                var offset = 0.0;
                for (var i = 0; i < index; i++) {
                  final prior = _sequence[i];
                  offset += (prior.end - prior.start) / prior.speed;
                }
                final selected = _selectedClips.contains(clip);
                return Positioned(
                  left: offset * pixelsPerSecond,
                  width: math.max(4.0, seconds * pixelsPerSecond - 2).toDouble(),
                  top: 2, bottom: 2,
                  child: GestureDetector(
                    onTap: () {
                      if (_multiSelectMode) {
                        setState(() {
                          if (!_selectedClips.add(clip)) _selectedClips.remove(clip);
                          _activeClipIndex = index;
                        });
                        _loadClip(index);
                      } else {
                        setState(() {
                          _activeClipIndex = index;
                          _selectedClips..clear()..add(clip);
                        });
                        _loadClip(index);
                      }
                    },
                    onPanStart: (details) {
                      if (_videoTrackLocked) return;
                      if (_multiSelectMode) {
                        if (!_groupMoveMode ||
                            !_selectedClips.contains(clip) ||
                            _selectedClips.length < 2) return;
                        _saveHistory();
                        setState(() {
                          _groupDragOriginalSequence = List<VideoClip>.from(_sequence);
                          _groupDragOriginX = details.globalPosition.dx;
                          _groupDragPixelsPerSecond = pixelsPerSecond;
                          _groupDragAnchorClip = clip;
                        });
                        HapticFeedback.selectionClick();
                        return;
                      }
                      final clipWidth = math.max(4.0,
                        seconds * pixelsPerSecond - 2).toDouble();
                      final mode = details.localPosition.dx <= 9
                          ? 'trim-start'
                          : details.localPosition.dx >= clipWidth - 9
                              ? 'trim-end' : 'move';
                      if (mode != 'move' && clip.duration <= 0) {
                        _feedback('Media duration is still loading');
                        return;
                      }
                      _saveHistory();
                      setState(() {
                        _timelineDragIndex = index;
                        _timelineDragMode = mode;
                        _timelineDragOriginX = details.globalPosition.dx;
                        _timelineDragThresholdX = 0;
                        _timelineDragAppliedX = 0;
                        _timelineDragDeltaX = 0;
                        _timelineOriginalStart = clip.start;
                        _timelineOriginalEnd = clip.end;
                      });
                    },
                    onPanUpdate: (details) {
                      if (_groupDragOriginalSequence != null) {
                        _updateSelectedGroupDrag(
                          details.globalPosition.dx - _groupDragOriginX,
                        );
                        return;
                      }
                      if (_multiSelectMode) return;
                      if (_timelineDragIndex == null ||
                          _timelineDragMode == null) return;
                      final dx = details.globalPosition.dx - _timelineDragOriginX;
                      if (_timelineDragMode == 'move') {
                        setState(() {
                          var remaining = dx - _timelineDragThresholdX;
                          while (remaining > 0 &&
                              _timelineDragIndex! < _sequence.length - 1) {
                            final next = _sequence[_timelineDragIndex! + 1];
                            final nextWidth = math.max(4.0,
                              ((next.end - next.start) / next.speed) *
                                pixelsPerSecond).toDouble();
                            final threshold = nextWidth / 2;
                            if (remaining < threshold) break;
                            final from = _timelineDragIndex!;
                            final moved = _sequence.removeAt(from);
                            _sequence.insert(from + 1, moved);
                            _timelineDragIndex = from + 1;
                            _timelineDragThresholdX += threshold;
                            remaining = dx - _timelineDragThresholdX;
                            HapticFeedback.selectionClick();
                          }
                          while (remaining < 0 && _timelineDragIndex! > 0) {
                            final previous = _sequence[_timelineDragIndex! - 1];
                            final previousWidth = math.max(4.0,
                              ((previous.end - previous.start) / previous.speed) *
                                pixelsPerSecond).toDouble();
                            final threshold = previousWidth / 2;
                            if (remaining > -threshold) break;
                            final from = _timelineDragIndex!;
                            final moved = _sequence.removeAt(from);
                            _sequence.insert(from - 1, moved);
                            _timelineDragIndex = from - 1;
                            _timelineDragThresholdX -= threshold;
                            remaining = dx - _timelineDragThresholdX;
                            HapticFeedback.selectionClick();
                          }
                          _activeClipIndex = _timelineDragIndex!;
                        });
                        return;
                      }
                      if (_timelineDragIndex != index) return;
                      final delta = dx / pixelsPerSecond * clip.speed;
                      setState(() {
                        if (_timelineDragMode == 'trim-start') {
                          clip.start = (_timelineOriginalStart + delta)
                            .clamp(0.0, math.max(0.0,
                              _timelineOriginalEnd - 0.1)).toDouble();
                        } else {
                          final maxEnd = clip.duration > 0
                              ? clip.duration : _timelineOriginalEnd;
                          clip.end = (_timelineOriginalEnd + delta)
                            .clamp(math.min(maxEnd, clip.start + 0.1),
                              maxEnd).toDouble();
                        }
                      });
                    },
                    onPanEnd: (_) {
                      if (_groupDragOriginalSequence != null) {
                        _finishSelectedGroupDrag();
                      } else {
                        _finishTimelineDrag(clip);
                      }
                    },
                    onPanCancel: () {
                      if (_groupDragOriginalSequence != null) {
                        _finishSelectedGroupDrag();
                      } else {
                        _finishTimelineDrag(clip);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                      decoration: BoxDecoration(
                        color: selected ? C.brand.withOpacity(0.38) : const Color(0xFF26364C),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: selected ? C.brand : C.text.withOpacity(0.12), width: selected ? 2 : 1),
                      ),
                      child: Row(children: [
                        Icon(clip.isVideo ? Icons.movie_outlined : Icons.image_outlined,
                          size: 11, color: C.text),
                        const SizedBox(width: 3),
                        Expanded(child: Text('Clip ${index + 1}',
                          maxLines: 1, overflow: TextOverflow.clip,
                          style: dm(sz: 8, c: C.text))),
                      ]),
                    ),
                  ),
                );
              }),
            Positioned(left: playheadX - 1, top: 0, bottom: 0,
              child: Container(width: 2, color: C.brand)),
          ]),
        )),
      ]),
    );

    Widget overlayLane(
      String label,
      IconData icon,
      bool Function(OverlayOperation) accepts,
    ) {
      final overlays = _overlays.asMap().entries
          .where((entry) => accepts(entry.value))
          .toList();
      if (overlays.isEmpty) return const SizedBox.shrink();
      return SizedBox(
        height: math.max(42.0, overlays.length * 34.0).toDouble(),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          trackLabel(icon, label),
          Expanded(child: SizedBox(
            height: math.max(40.0, overlays.length * 34.0).toDouble(),
            child: Stack(children: [
              for (var laneIndex = 0; laneIndex < overlays.length; laneIndex++)
                Builder(builder: (context) {
                  final entry = overlays[laneIndex];
                  final overlayIndex = entry.key;
                  final overlay = entry.value;
                  final startSeconds = overlay.start.clamp(0.0, 1.0) * duration;
                  final endSeconds = overlay.end.clamp(0.0, 1.0) * duration;
                  final left = startSeconds * pixelsPerSecond;
                  final width = math.max(18.0,
                    (endSeconds - startSeconds) * pixelsPerSecond).toDouble();
                  final top = laneIndex * 34.0 + 2;
                  final selected = _timelineOverlaySelected == overlayIndex;
                  return Positioned(
                    left: left, top: top, width: width, height: 28,
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _timelineOverlaySelected = overlayIndex);
                        _showEditTextLayerSheet(overlayIndex);
                      },
                      onPanStart: (details) {
                        _saveHistory();
                        _timelineOverlayDragIndex = overlayIndex;
                        _timelineOverlayDragOriginX = details.globalPosition.dx;
                        _timelineOverlayDragStart = overlay.start;
                        _timelineOverlayDragEnd = overlay.end;
                      },
                      onPanUpdate: (details) {
                        if (_timelineOverlayDragIndex != overlayIndex) return;
                        final delta = (details.globalPosition.dx -
                          _timelineOverlayDragOriginX) /
                          (pixelsPerSecond * duration);
                        final span = _timelineOverlayDragEnd -
                          _timelineOverlayDragStart;
                        final nextStart = (_timelineOverlayDragStart + delta)
                          .clamp(0.0, math.max(0.0, 1.0 - span)).toDouble();
                        setState(() {
                          overlay.start = nextStart;
                          overlay.end = (nextStart + span).clamp(
                            nextStart + 0.001, 1.0).toDouble();
                        });
                      },
                      onPanEnd: (_) {
                        _timelineOverlayDragIndex = null;
                        _syncSharedProjectFromSequence();
                      },
                      onPanCancel: () {
                        _timelineOverlayDragIndex = null;
                      },
                      child: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: selected ? C.brand.withOpacity(0.48) :
                            const Color(0xFF6A4B86),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: selected ? C.brand :
                            Colors.white.withOpacity(0.16)),
                        ),
                        child: Text(overlay.text,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: dm(sz: 8, c: Colors.white, w: FontWeight.w700)),
                      ),
                    ),
                  );
                }),
              Positioned(left: playheadX - 1, top: 0, bottom: 0,
                child: Container(width: 2, color: C.brand)),
            ]),
          )),
        ]),
      );
    }

    Widget audioLane({
      required String label,
      required IconData icon,
      required String? title,
      required double start,
      required double end,
      required Color color,
      required VoidCallback onTap,
    }) {
      if (title == null || title.isEmpty) return const SizedBox.shrink();
      final laneStart = start.clamp(0.0, duration);
      final laneEnd = end.clamp(laneStart, duration);
      final laneWidth = math.max(18.0,
        (laneEnd - laneStart) * pixelsPerSecond).toDouble();
      return SizedBox(
        height: 42,
        child: Row(children: [
          trackLabel(icon, label),
          Expanded(child: SizedBox(
            height: 36,
            child: Stack(children: [
              Positioned(
                left: laneStart * pixelsPerSecond,
                width: laneWidth,
                top: 3,
                bottom: 3,
                child: GestureDetector(
                  onTap: onTap,
                  child: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.28),
                      border: Border.all(color: color.withOpacity(0.8)),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Row(children: [
                      Icon(icon, size: 11, color: C.text),
                      const SizedBox(width: 4),
                      Expanded(child: Text(title,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: dm(sz: 8, c: C.text, w: FontWeight.w700))),
                    ]),
                  ),
                ),
              ),
              Positioned(left: playheadX - 1, top: 0, bottom: 0,
                child: Container(width: 2, color: C.brand)),
            ]),
          )),
        ]),
      );
    }

    final musicTitle = _selectedTrack?.title;
    final voiceTitle = _voiceOverFile == null
        ? null
        : _voiceOverFile!.path.split(Platform.pathSeparator).last;
    final captionLane = overlayLane(
      'CAPTIONS',
      Icons.closed_caption_outlined,
      (overlay) => overlay.kind.toLowerCase().contains('caption'),
    );
    final lyricLane = overlayLane(
      'LYRICS',
      Icons.lyrics_outlined,
      (overlay) => overlay.kind.toLowerCase().contains('lyric'),
    );
    final otherTextLane = overlayLane(
      'TEXT',
      Icons.text_fields,
      (overlay) {
        final kind = overlay.kind.toLowerCase();
        return !kind.contains('caption') && !kind.contains('lyric');
      },
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 7),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.025),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.07)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('TIMELINE', style: syne(sz: 9, w: FontWeight.w900, c: C.dim, ls: 1)),
          const Spacer(),
          if (_multiSelectMode)
            Text(_groupMoveMode
                ? 'Drag any selected clip to move the group'
                : 'Tap clips to add or remove',
              style: dm(sz: 8, c: C.dim))
          else
            Text('${duration.toStringAsFixed(1)}s · Drag clips to reorder',
              style: dm(sz: 8, c: C.dim)),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () => setState(() {
              if (_multiSelectMode) {
                _multiSelectMode = false;
                _groupMoveMode = false;
                _selectedClips.clear();
                if (_sequence.isNotEmpty) {
                  _selectedClips.add(
                    _sequence[_activeClipIndex.clamp(0, _sequence.length - 1)],
                  );
                }
              } else {
                _multiSelectMode = true;
                if (_sequence.isNotEmpty) {
                  _selectedClips
                    ..clear()
                    ..add(_sequence[_activeClipIndex.clamp(0, _sequence.length - 1)]);
                }
              }
            }),
            child: Text(_multiSelectMode ? 'DONE' : 'SELECT',
              style: syne(sz: 8, w: FontWeight.w900, c: C.brand)),
          ),
        ]),
        if (_multiSelectMode)
          Row(children: [
            Text('${_selectedClips.length} SELECTED', style: syne(sz: 8, w: FontWeight.w800, c: C.brand)),
            const Spacer(),
            if (_selectedClips.length > 1)
              TextButton(
                onPressed: () => setState(() => _groupMoveMode = !_groupMoveMode),
                child: Text(_groupMoveMode ? 'CANCEL MOVE' : 'MOVE GROUP',
                  style: syne(sz: 8, w: FontWeight.w900, c: C.brand)),
              ),
            TextButton(onPressed: () => setState(() { _selectedClips..clear()..addAll(_sequence); _groupMoveMode = false; }), child: Text('ALL', style: syne(sz: 8, w: FontWeight.w800, c: C.text))),
            TextButton(onPressed: () => setState(() { _selectedClips.clear(); _groupMoveMode = false; }), child: Text('CLEAR', style: syne(sz: 8, w: FontWeight.w800, c: C.sub))),
          ]),
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(viewportWidth, totalWidth + 68).toDouble(),
            child: Column(children: [
              Row(children: [
                const SizedBox(width: 68),
                SizedBox(width: totalWidth, child: timeRuler()),
              ]),
              videoLane(),
              const SizedBox(height: 3),
              audioLane(
                label: 'MUSIC',
                icon: Icons.music_note,
                title: musicTitle,
                start: _audioOffset,
                end: _audioOffset + (_audioEnd - _audioStart),
                color: const Color(0xFFA78BFA),
                onTap: _showSoundPicker,
              ),
              audioLane(
                label: 'VOICE',
                icon: Icons.mic,
                title: voiceTitle,
                start: 0,
                end: duration,
                color: const Color(0xFF34D399),
                onTap: _showVolumeSheet,
              ),
              captionLane,
              lyricLane,
              otherTextLane,
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildEditorDock() {
    final dockHeight = (MediaQuery.of(context).size.height * 0.38)
        .clamp(318.0, 382.0)
        .toDouble();
    return SizedBox(
      height: dockHeight,
      child: Container(
        decoration: BoxDecoration(
          color: Color(0xFF0E121B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: C.text.withOpacity(0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 22,
              offset: Offset(0, -10),
            ),
          ],
        ),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Creative Dock',
                        style: syne(
                          sz: 13,
                          w: FontWeight.w900,
                          c: C.text,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Bottom workspace for tools, quick actions, and tab navigation',
                        style: dm(sz: 10, c: C.dim),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                  Spacer(),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: C.text.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: C.text.withOpacity(0.08)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.layers_outlined, size: 13, color: C.brand),
                        SizedBox(width: 6),
                        Text(
                          _multiSelectMode
                              ? '${_selectedClips.length} selected'
                              : (_sequence.isEmpty ? 'No media' : 'Editing clip ${_activeClipIndex + 1}'),
                          style: dm(sz: 10, c: C.text),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 8),
            _buildBottomNav(),
            SizedBox(height: 8),
            _buildSequenceTimeline(),
            SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPrimaryToolbar(),
                    SizedBox(height: 12),
                    _buildQuickToolbar(),
                  ],
                ),
              ),
            ),
            SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: C.brand, strokeWidth: 2),
            SizedBox(height: 20),
            Text(
              "ENGINEERING MEDIA...",
              style: syne(sz: 10, w: FontWeight.w900, ls: 4, c: C.brand),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toInt();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _projectResolutionLabel() {
    if (_videoController != null && _videoController!.value.isInitialized) {
      final size = _videoController!.value.size;
      if (size.width > 0 && size.height > 0) {
        return '${size.width.toInt()}x${size.height.toInt()}';
      }
    }
    switch (_selectedAspectRatio) {
      case '1:1':
        return '1080x1080';
      case '4:5':
        return '1080x1350';
      default:
        return '1080x1920';
    }
  }

  Widget _buildMetaPill(IconData icon, String label) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: C.text.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: C.sub, size: 12),
          SizedBox(width: 6),
          Text(
            label,
            style: syne(sz: 10, w: FontWeight.w700, c: C.sub),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportButton(
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: C.text.withOpacity(0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: C.text.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: C.brand, size: 14),
            SizedBox(width: 6),
            Text(
              label,
              style: syne(sz: 10, w: FontWeight.w700, c: C.sub),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssetsPanel() {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Color(0xFF0C1018),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.dim),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Assets',
                style: syne(sz: 12, w: FontWeight.w900, c: C.text),
              ),
              Spacer(),
              Tooltip(
                message: 'Add media',
                child: GestureDetector(
                  onTap: _addClip,
                  child: Icon(
                    Icons.add_box_outlined,
                    color: C.dim,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 3),
          Text(
            '${_sequence.length} source item${_sequence.length == 1 ? '' : 's'}',
            style: dm(sz: 10, c: C.text.withOpacity(0.35)),
          ),
          SizedBox(height: 8),
          Expanded(
            child: _sequence.isEmpty
                ? Center(
                    child: Text(
                      'No clips',
                      style: dm(sz: 12, c: C.dim),
                    ),
                  )
                : ListView.builder(
                    itemCount: _sequence.length,
                    itemBuilder: (ctx, i) {
                      final c = _sequence[i];
                      final name = c.file.path.split(RegExp(r'[\\/]+')).last;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _activeClipIndex = i;
                            _loadClip(i);
                          });
                        },
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 8,
                          ),
                          margin: EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: i == _activeClipIndex
                                ? C.brand.withOpacity(0.14)
                                : C.text.withOpacity(0.045),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: i == _activeClipIndex
                                  ? C.brand
                                  : C.text.withOpacity(0.04),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                c.isVideo ? Icons.movie : Icons.image,
                                color: C.sub,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  name,
                                  style: syne(
                                    sz: 11,
                                    w: FontWeight.w700,
                                    c: C.text,
                                  ),
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                '${((c.duration <= 0 ? 0 : c.duration)).toStringAsFixed(1)}s',
                                style: dm(sz: 10, c: C.dim),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildInspectorPanel() {
    final resolution = _projectResolutionLabel();
    final duration = _totalDuration;
    final estBytes = _estimateSizeBytes();

    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Color(0xFF0C1018),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.dim),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Inspector',
              style: syne(sz: 12, w: FontWeight.w900, c: C.text),
            ),
            SizedBox(height: 12),
            _inspectorSectionTitle('Project Information'),
            _projectInfoRow(Icons.aspect_ratio, 'Resolution', resolution),
            _projectInfoRow(
              Icons.speed,
              'Frame rate',
              '${_frameRate.toStringAsFixed(0)} fps',
            ),
            _projectInfoRow(Icons.timer, 'Duration', _formatDuration(duration)),
            _projectInfoRow(
              Icons.sd_storage_outlined,
              'Estimated size',
              _formatBytes(estBytes),
            ),
            SizedBox(height: 14),
            _inspectorSectionTitle('Playback Controls'),
            SizedBox(height: 8),
            _buildTransportBar(showLabels: true),
            SizedBox(height: 14),
            _inspectorSectionTitle('Asset Tracks'),
            _trackControlRow(
              icon: Icons.movie_outlined,
              label: 'Video',
              sub:
                  '${_sequence.length} clip${_sequence.length == 1 ? '' : 's'}',
              color: Color(0xFF60A5FA),
              visible: _videoTrackVisible,
              locked: _videoTrackLocked,
              onVisibility: () {
                final visible = !_videoTrackVisible;
                setState(() => _videoTrackVisible = visible);
                _setTrackVisibility(TrackType.video, visible);
                _setTrackVisibility(TrackType.images, visible);
              },
              onLock: () =>
                  setState(() => _videoTrackLocked = !_videoTrackLocked),
            ),
            _trackControlRow(
              icon: Icons.music_note,
              label: 'Music',
              sub: _selectedTrack?.title ?? 'No track selected',
              color: Color(0xFFA78BFA),
              visible: _musicTrackVisible,
              locked: _musicTrackLocked,
              onVisibility: () {
                final visible = !_musicTrackVisible;
                setState(() => _musicTrackVisible = visible);
                _setTrackVisibility(TrackType.music, visible);
              },
              onLock: () =>
                  setState(() => _musicTrackLocked = !_musicTrackLocked),
            ),
            _trackControlRow(
              icon: Icons.mic,
              label: 'Voice',
              sub: _voiceOverFile == null ? 'No voiceover' : 'Voiceover ready',
              color: Color(0xFF34D399),
              visible: _voiceTrackVisible,
              locked: _voiceTrackLocked,
              onVisibility: () {
                final visible = !_voiceTrackVisible;
                setState(() => _voiceTrackVisible = visible);
                _setTrackVisibility(TrackType.voiceOver, visible);
              },
              onLock: () =>
                  setState(() => _voiceTrackLocked = !_voiceTrackLocked),
            ),
            _trackControlRow(
              icon: Icons.text_fields,
              label: 'Text',
              sub:
                  '${_overlays.length} overlay${_overlays.length == 1 ? '' : 's'}',
              color: Color(0xFF38BDF8),
              visible: _textTrackVisible,
              locked: _textTrackLocked,
              onVisibility: () {
                final visible = !_textTrackVisible;
                setState(() => _textTrackVisible = visible);
                _setTrackVisibility(TrackType.overlay, visible);
              },
              onLock: () =>
                  setState(() => _textTrackLocked = !_textTrackLocked),
            ),
            SizedBox(height: 12),
            _actionRow(Icons.upload_file, 'Export', _onNext, c: C.brand),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryPanel({bool horizontal = false}) {
    final items = [
      _categoryAction(Icons.image_outlined, 'Media', _addClip),
      _categoryAction(Icons.music_note, 'Audio', _showSoundPicker),
      _categoryAction(Icons.text_fields, 'Text', _showTextOverlaySheet),
      _categoryAction(
        Icons.emoji_emotions_outlined,
        'Sticker',
        _showStickerSheet,
      ),
      _categoryAction(
        Icons.auto_awesome_motion_outlined,
        'Effects',
        _showEffectsEditor,
      ),
      _categoryAction(Icons.compare_arrows, 'Transition', _showTransitionSheet),
      _categoryAction(Icons.filter_alt_outlined, 'Filter', _showFilterSheet),
      _categoryAction(Icons.tune, 'Adjust', _showAdjustSheet),
    ];

    if (horizontal) {
      return SizedBox(
        height: 62,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: items),
        ),
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: Color(0xFF0A0D14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.text.withOpacity(0.08)),
      ),
      child: Column(
        children: items
            .map(
              (item) => Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: item,
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _categoryAction(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(right: 8),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: C.text.withOpacity(0.04),
          border: Border.all(color: C.text.withOpacity(0.06)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: C.sub, size: 18),
            SizedBox(width: 8),
            Text(
              label,
              style: syne(sz: 10, w: FontWeight.w700, c: C.text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransportBar({required bool showLabels}) {
    final playIcon = _isPlaying
        ? Icons.pause_circle_filled_rounded
        : Icons.play_circle_fill_rounded;
    final playLabel = _isPlaying ? 'Pause' : 'Play';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: showLabels ? WrapAlignment.center : WrapAlignment.end,
      children: [
        showLabels
            ? _buildTransportButton(
                Icons.skip_previous_outlined,
                'Previous',
                _jumpToPreviousClip,
              )
            : _transportIconButton(
                Icons.skip_previous_outlined,
                'Previous',
                _jumpToPreviousClip,
              ),
        showLabels
            ? _buildTransportButton(playIcon, playLabel, _togglePlayback)
            : _transportIconButton(playIcon, playLabel, _togglePlayback),
        showLabels
            ? _buildTransportButton(
                Icons.skip_next_outlined,
                'Next',
                _jumpToNextClip,
              )
            : _transportIconButton(
                Icons.skip_next_outlined,
                'Next',
                _jumpToNextClip,
              ),
        showLabels
            ? _buildTransportButton(
                Icons.fullscreen_outlined,
                'Fullscreen',
                _showFullscreenPreview,
              )
            : _transportIconButton(
                Icons.fullscreen_outlined,
                'Fullscreen',
                _showFullscreenPreview,
              ),
      ],
    );
  }

  Widget _transportIconButton(
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: C.text.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: C.text.withOpacity(0.08)),
          ),
          child: Icon(
            icon,
            color: C.brand,
            size:
                icon == Icons.play_circle_fill_rounded ||
                    icon == Icons.pause_circle_filled_rounded
                ? 20
                : 16,
          ),
        ),
      ),
    );
  }

  Widget _inspectorSectionTitle(String label) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: syne(sz: 10, w: FontWeight.w900, c: C.dim, ls: 1.1),
      ),
    );
  }

  Widget _projectInfoRow(IconData icon, String label, String value) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, color: C.brand, size: 15),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: dm(sz: 11, c: C.text.withOpacity(0.45)),
            ),
          ),
          Text(
            value,
            style: syne(sz: 11, w: FontWeight.w800, c: C.text),
          ),
        ],
      ),
    );
  }

  Widget _trackControlRow({
    required IconData icon,
    required String label,
    required String sub,
    required Color color,
    required bool visible,
    required bool locked,
    required VoidCallback onVisibility,
    required VoidCallback onLock,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: syne(sz: 11, w: FontWeight.w900, c: C.text),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: dm(sz: 9, c: C.text.withOpacity(0.35)),
                ),
              ],
            ),
          ),
          IconButton(
            constraints: BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            onPressed: onVisibility,
            icon: Icon(
              visible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: visible ? color : C.dim,
              size: 16,
            ),
          ),
          IconButton(
            constraints: BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            onPressed: onLock,
            icon: Icon(
              locked ? Icons.lock_outlined : Icons.lock_open_outlined,
              color: locked ? color : C.dim,
              size: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryToolbar() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(
                  'Core tools',
                  style: syne(
                    sz: 10,
                    w: FontWeight.w800,
                    c: C.dim,
                    ls: 1.2,
                  ),
                ),
                Spacer(),
                Text(
                  'Organized by workflow',
                  style: syne(sz: 9, w: FontWeight.w600, c: C.dim),
                ),
              ],
            ),
          ),
          SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _toolGroup('Import', [
                  _primaryAction(Icons.image_outlined, 'Media', _addClip),
                  _primaryAction(
                    Icons.filter_frames_outlined,
                    'Frames',
                    _showFrameOverlayPicker,
                  ),
                ]),
                _toolGroup('Audio', [
                  _primaryAction(Icons.music_note, 'Music', _showSoundPicker),
                  _primaryAction(
                    Icons.mic_none_outlined,
                    'Voice',
                    _toggleVoiceOver,
                  ),
                  _primaryAction(
                    Icons.volume_up_outlined,
                    'Mixer',
                    _showVolumeSheet,
                  ),
                ]),
                _toolGroup('Layers', [
                  _primaryAction(
                    Icons.text_fields,
                    'Text',
                    _showTextOverlaySheet,
                  ),
                  _primaryAction(
                    Icons.closed_caption_outlined,
                    'Caption',
                    _showCaptionSheet,
                  ),
                  _primaryAction(
                    Icons.emoji_emotions_outlined,
                    'Sticker',
                    _showStickerSheet,
                  ),
                  _primaryAction(
                    Icons.auto_awesome_motion_outlined,
                    'Effects',
                    _showEffectsEditor,
                  ),
                ]),
                _toolGroup('Color', [
                  _primaryAction(
                    Icons.filter_b_and_w,
                    'Filter',
                    _showFilterSheet,
                  ),
                  _primaryAction(Icons.tune, 'Adjust', _showAdjustSheet),
                  _primaryAction(
                    Icons.face_retouching_natural,
                    'Face AI',
                    _showBeautySheet,
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolGroup(String title, List<Widget> children) {
    return Container(
      margin: EdgeInsets.only(right: 10),
      padding: EdgeInsets.fromLTRB(8, 7, 2, 8),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.035),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(right: 8),
            child: Text(
              title,
              style: syne(sz: 9, w: FontWeight.w800, c: C.dim),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _primaryAction(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(right: 6),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: C.text.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: C.text, size: 18),
            SizedBox(width: 8),
            Text(
              label,
              style: syne(sz: 9, w: FontWeight.bold, c: C.text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickToolbar() {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12),
      padding: EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: C.text.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.text.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'Quick actions',
              style: syne(
                sz: 10,
                w: FontWeight.w800,
                c: C.dim,
                ls: 1.2,
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _quickAction(Icons.content_cut, 'Split', _handleSplit),
                _quickAction(Icons.crop_rotate, 'Trim', _showTrimSheet),
                _quickAction(Icons.crop, 'Crop', _showCropSheet),
                _quickAction(
                  Icons.open_with,
                  'Transform',
                  _showTransformEditor,
                ),
                _quickAction(Icons.speed, 'Speed', _showSpeedSheet),
                _quickAction(Icons.flip, 'Reverse', _toggleReverse),
                _quickAction(Icons.blur_on, 'Fade', _showFadeSheet),
                _quickAction(
                  Icons.compare_arrows,
                  'Transition',
                  _showTransitionSheet,
                ),
                _quickAction(Icons.delete_outline, 'Delete', _handleDeleteClip),
                _quickAction(Icons.copy, 'Duplicate', _handleDuplicateClip),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _quickAction(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: EdgeInsets.only(right: 8),
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: C.text.withOpacity(0.06)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: C.sub, size: 15),
            SizedBox(width: 6),
            Text(
              label,
              style: syne(sz: 8, w: FontWeight.bold, c: C.dim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    final tabs = [
      {'icon': Icons.folder_open, 'label': 'Project'},
      {'icon': Icons.perm_media_outlined, 'label': 'Media'},
      {'icon': Icons.auto_awesome, 'label': 'Effects'},
      {'icon': Icons.music_note, 'label': 'Audio'},
      {'icon': Icons.timeline, 'label': 'Timeline'},
    ];

    final actions = [
      [
        _bottomAction(Icons.save_outlined, 'Save', _onSaveDraft),
        _bottomAction(Icons.arrow_forward_ios, 'Export', _onNext),
        _bottomAction(Icons.undo, 'Undo', _undo),
        _bottomAction(Icons.redo, 'Redo', _redo),
      ],
      [
        _bottomAction(Icons.add_box_outlined, 'Add', _addClip),
        _bottomAction(Icons.text_fields, 'Text', _showTextOverlaySheet),
        _bottomAction(
          Icons.emoji_emotions_outlined,
          'Sticker',
          _showStickerSheet,
        ),
        _bottomAction(
          Icons.filter_frames_outlined,
          'Frame',
          _showFrameOverlayPicker,
        ),
      ],
      [
        _bottomAction(Icons.filter_alt_outlined, 'Filter', _showFilterSheet),
        _bottomAction(Icons.tune, 'Adjust', _showAdjustSheet),
        _bottomAction(
          Icons.auto_awesome_motion,
          'Transition',
          _showTransitionSheet,
        ),
        _bottomAction(Icons.blur_on, 'Fade', _showFadeSheet),
      ],
      [
        _bottomAction(Icons.music_note, 'Music', _showSoundPicker),
        _bottomAction(Icons.volume_up, 'Mixer', _showVolumeSheet),
        _bottomAction(Icons.mic, 'Voice', _toggleVoiceOver),
        _bottomAction(Icons.speed, 'Speed', _showSpeedSheet),
      ],
      [
        _bottomAction(Icons.play_circle_fill, 'Play', _togglePlayback),
        _bottomAction(Icons.skip_previous, 'Prev', _jumpToPreviousClip),
        _bottomAction(Icons.skip_next, 'Next', _jumpToNextClip),
        _bottomAction(Icons.fullscreen, 'Full', _showFullscreenPreview),
      ],
    ];

    return Container(
      margin: EdgeInsets.symmetric(horizontal: 12),
      padding: EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: BoxDecoration(
        color: Color(0xFF0C1018),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.text.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: List.generate(tabs.length, (i) {
              final active = _activeNavIndex == i;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _activeNavIndex = i),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        tabs[i]['icon'] as IconData,
                        color: active ? C.brand : C.dim,
                        size: 20,
                      ),
                      SizedBox(height: 4),
                      Text(
                        tabs[i]['label'] as String,
                        textAlign: TextAlign.center,
                        style: syne(
                          sz: 10,
                          w: FontWeight.w700,
                          c: active ? C.text : C.dim,
                        ),
                      ),
                      SizedBox(height: 6),
                      Container(
                        height: 4,
                        width: 32,
                        decoration: BoxDecoration(
                          color: active ? C.brand : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
          SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: actions[_activeNavIndex]),
          ),
        ],
      ),
    );
  }

  Widget _bottomAction(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: C.text.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.text.withOpacity(0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: C.sub, size: 16),
              SizedBox(width: 8),
              Text(
                label,
                style: syne(sz: 10, w: FontWeight.bold, c: C.sub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Small circle icon button used in the project header
  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: C.text.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(color: C.dim),
        ),
        child: Icon(icon, color: C.text, size: 16),
      ),
    );
  }

  /// Icon with text label underneath
  Widget _iconTextBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: C.text, size: 18),
          SizedBox(height: 4),
          Text(
            label,
            style: syne(sz: 9, w: FontWeight.bold, c: C.text),
          ),
        ],
      ),
    );
  }

  void _updateSelectedGroupDrag(double deltaX) {
    final original = _groupDragOriginalSequence;
    final anchor = _groupDragAnchorClip;
    if (original == null || anchor == null || _groupDragPixelsPerSecond <= 0) {
      return;
    }

    final selected = original.where(_selectedClips.contains).toList();
    if (selected.length < 2) return;
    final firstSelectedIndex = original.indexWhere(_selectedClips.contains);
    if (firstSelectedIndex < 0) return;

    double originalGroupStart = 0;
    for (var i = 0; i < firstSelectedIndex; i++) {
      final item = original[i];
      originalGroupStart += (item.end - item.start) / item.speed;
    }
    final groupDuration = selected.fold<double>(
      0,
      (sum, item) => sum + (item.end - item.start) / item.speed,
    );
    final targetGroupCenter = originalGroupStart +
        (deltaX / _groupDragPixelsPerSecond) + groupDuration / 2;

    final remaining = original.where((item) => !_selectedClips.contains(item)).toList();
    var insertionIndex = 0;
    var cursor = 0.0;
    for (final item in remaining) {
      final itemDuration = (item.end - item.start) / item.speed;
      final itemCenter = cursor + itemDuration / 2;
      if (itemCenter < targetGroupCenter) {
        insertionIndex++;
      } else {
        break;
      }
      cursor += itemDuration;
    }
    insertionIndex = insertionIndex.clamp(0, remaining.length);

    final reordered = <VideoClip>[
      ...remaining.take(insertionIndex),
      ...selected,
      ...remaining.skip(insertionIndex),
    ];
    if (reordered.length != _sequence.length) return;

    setState(() {
      _sequence = reordered;
      _activeClipIndex = _sequence.indexOf(anchor).clamp(0, _sequence.length - 1).toInt();
    });
  }

  void _finishSelectedGroupDrag() {
    final original = _groupDragOriginalSequence;
    if (original == null) return;
    final changed = _sequence.length != original.length ||
        List.generate(
          _sequence.length,
          (i) => !identical(_sequence[i], original[i]),
        ).any((different) => different);
    setState(() {
      _groupDragOriginalSequence = null;
      _groupDragAnchorClip = null;
      _groupMoveMode = false;
      if (_sequence.isNotEmpty) {
        _activeClipIndex = _activeClipIndex.clamp(0, _sequence.length - 1).toInt();
      }
    });
    if (changed) {
      _syncSharedProjectFromSequence();
      HapticFeedback.mediumImpact();
      _feedback('Selected clips moved together');
    }
  }

  void _finishTimelineDrag(VideoClip clip) {
    final mode = _timelineDragMode;
    final finalIndex = _sequence.indexOf(clip);
    if (_timelineDragIndex == null || mode == null) return;

    if (mounted) {
      setState(() {
        if (mode == 'move' && finalIndex >= 0) {
          _activeClipIndex = finalIndex;
        }
        _timelineDragIndex = null;
        _timelineDragMode = null;
        _timelineDragDeltaX = 0;
        _timelineDragAppliedX = 0;
        _timelineDragThresholdX = 0;
      });
    }
    _syncSharedProjectFromSequence();
    if (_videoController != null && mode != 'move' && finalIndex >= 0) {
      _videoController!.seekTo(
        Duration(milliseconds: (clip.start * 1000).round()),
      );
    } else if (mode == 'move' && finalIndex >= 0) {
      _loadClip(finalIndex);
    }
  }

  Future<void> _toggleReverse() async {
    if (_sequence.isEmpty || _activeNavIndex == 1) {
      TimelineClip? audioClip;
      for (final track in _project.tracks) {
        for (final candidate in track.clips) {
          if (candidate.operation is AudioClipOperation) {
            audioClip = candidate;
            break;
          }
        }
        if (audioClip != null) break;
      }
      if (audioClip == null) {
        _feedback('No audio clip is available on the selected track');
        return;
      }
      _saveHistory();
      final operation = audioClip.operation as AudioClipOperation;
      setState(() {
        operation.reverse = !operation.reverse;
        audioClip!.isReversed = operation.reverse;
      });
      _feedback(operation.reverse ? 'Audio reversed for export' : 'Audio reverse removed');
      return;
    }
    if (_activeClipIndex < 0 || _activeClipIndex >= _sequence.length) return;
    final clip = _sequence[_activeClipIndex];
    final nextReverse = !clip.isReversed;
    if (clip.isVideo && nextReverse && clip.reversePreviewFile == null) {
      setState(() => _isProcessing = true);
      final reversed = await _videoService.createReversedPreview(
        inputVideo: clip.file,
        hasAudio: clip.hasAudio,
      );
      if (!mounted) return;
      setState(() => _isProcessing = false);
      if (reversed == null || !reversed.existsSync()) {
        _feedback('Could not prepare reverse preview; original clip is unchanged');
        return;
      }
      clip.reversePreviewFile = reversed;
    }
    _saveHistory();
    setState(() => clip.isReversed = nextReverse);
    _loadClip(_activeClipIndex);
    _syncSharedProjectFromSequence();
    _feedback(clip.isVideo
        ? (clip.isReversed ? 'Video and original audio reversed' : 'Video reverse removed')
        : (clip.isReversed ? 'Photo mirrored horizontally' : 'Photo mirror removed'));
  }

  void _handleSplit() {
    if (_sequence.isEmpty || _videoController == null ||
        !_videoController!.value.isInitialized ||
        _activeClipIndex < 0 || _activeClipIndex >= _sequence.length) {
      _feedback("Select a video clip before splitting");
      return;
    }
    final activeClip = _sequence[_activeClipIndex];
    final playbackPos = _videoController!.value.position.inMilliseconds / 1000.0;
    final currentPos = activeClip.isReversed
        ? activeClip.duration - playbackPos
        : playbackPos;


    // Player position is source-media time: split within the trimmed range.
    if (currentPos <= activeClip.start + 0.05 ||
        currentPos >= activeClip.end - 0.05) {
      _feedback("Too close to edge to split");
      return;
    }

    _saveHistory();
    setState(() {
      // 1. Create a copy of the current clip
      final newClip = activeClip.copy();

      // 2. Adjust Out-point of current clip
      activeClip.end = currentPos;

      // 3. Adjust In-point of new clip
      newClip.start = currentPos;

      // 4. Insert into sequence
      _sequence.insert(_activeClipIndex + 1, newClip);

      HapticFeedback.mediumImpact();
      _feedback("Clip split");
    });
    _syncSharedProjectFromSequence();
  }

  void _handleDeleteClip() {
    if (_sequence.isEmpty ||
        _activeClipIndex < 0 ||
        _activeClipIndex >= _sequence.length) {
      return;
    }
    _saveHistory();
    VideoPlayerController? controllerToDispose;
    setState(() {
      _sequence.removeAt(_activeClipIndex);
      if (_sequence.isEmpty) {
        controllerToDispose = _videoController;
        _videoController = null;
        _activeClipIndex = 0;
        _isPlaying = false;
        _timelineDragIndex = null;
        _timelineDragMode = null;
        _timelineDragDeltaX = 0;
        _timelineDragAppliedX = 0;
        _timelineDragThresholdX = 0;
      } else {
        if (_activeClipIndex >= _sequence.length) {
          _activeClipIndex = _sequence.length - 1;
        }
        _loadClip(_activeClipIndex);
      }
    });
    controllerToDispose?.dispose();
    if (_sequence.isEmpty) {
      _project.playback.pause();
      unawaited(_musicPlayer.pause());
      unawaited(_voicePlayer.pause());
    }
    _syncSharedProjectFromSequence();
  }

  void _handleDuplicateClip() {
    if (_sequence.isEmpty) return;
    _saveHistory();
    setState(() {
      _sequence.insert(
        _activeClipIndex + 1,
        _sequence[_activeClipIndex].copy(),
      );
      _activeClipIndex++;
      _loadClip(_activeClipIndex);
    });
    _syncSharedProjectFromSequence();
    _feedback("Clip duplicated");
  }

  void _showFadeSheet() {
    final current = _transitions[_activeClipIndex]?.presetName ?? 'None';
    final options = ['None', 'Fade', 'Dissolve'];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.94),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: C.dim),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'FADE STYLE',
              style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
            ),
            SizedBox(height: 16),
            Row(
              children: options.map((option) {
                final selected = current == option;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        if (option == 'None') {
                          _transitions.remove(_activeClipIndex);
                        } else {
                          _transitions[_activeClipIndex] = TransitionOperation(
                            presetId: option.toLowerCase(),
                            presetName: option,
                            category: 'Fade',
                            icon: '',
                          );
                        }
                        _syncSharedProjectFromSequence();
                      });
                      Navigator.pop(context);
                      _feedback("$option fade applied");
                    },
                    child: Container(
                      margin: EdgeInsets.only(right: 8),
                      padding: EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: selected ? C.brand : C.dim,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? C.brand : C.dim,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          option,
                          style: syne(
                            sz: 11,
                            w: FontWeight.w900,
                            c: selected ? Colors.black : C.sub,
                          ),
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

  void _showStickerSheet() {
    final stickers = ['STAR', 'SALE', 'NEW', 'LIVE', 'HOT', 'CHECK'];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.94),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
            SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: stickers
                  .map(
                    (sticker) => GestureDetector(
                      onTap: () {
                        setState(
                          () => _addProjectOverlay(
                            OverlayOperation.fromLegacy({
                              'type': 'sticker',
                              'text': sticker,
                              'start': 0.0,
                              'end': 1.0,
                              'color': sticker.length > 1
                                  ? Colors.black
                                  : C.text,
                              'background': sticker.length > 1
                                  ? C.brand
                                  : Colors.transparent,
                              'backgroundOpacity': sticker.length > 1
                                  ? 1.0
                                  : 0.0,
                              'fontSize': sticker.length > 1 ? 22.0 : 42.0,
                              'x': 0.5,
                              'y': 0.5,
                              'scale': 1.0,
                              'rotation': 0.0,
                              'opacity': 1.0,
                              'stroke': sticker.length == 1,
                              'shadow': true,
                              'align': 'center',
                            }),
                          ),
                        );
                        Navigator.pop(context);
                        _feedback("Sticker added");
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
                              sz: sticker.length > 1 ? 14 : 24,
                              w: FontWeight.w900,
                              c: C.text,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  void _showTrimSheet() {
    final clip = _sequence[_activeClipIndex];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: C.dim),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('TRIM CLIP', style: syne(sz: 14, w: FontWeight.w900, ls: 2)),
              SizedBox(height: 32),
              RangeSlider(
                values: RangeValues(clip.start, clip.end),
                min: 0,
                max: clip.duration,
                activeColor: C.brand,
                inactiveColor: C.dim,
                onChanged: (values) {
                  _saveHistory();
                  setModalState(() {
                    clip.start = values.start;
                    clip.end = values.end;
                  });
                  setState(() {});
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Start: ${clip.start.toStringAsFixed(1)}s',
                    style: dm(sz: 10, c: C.dim),
                  ),
                  Text(
                    'End: ${clip.end.toStringAsFixed(1)}s',
                    style: dm(sz: 10, c: C.dim),
                  ),
                ],
              ),
              SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: C.brand,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: EdgeInsets.all(16),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: Text('DONE', style: syne(sz: 14, w: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedSheet() {
    final clip = _sequence[_activeClipIndex];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: C.dim),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'PLAYBACK SPEED',
              style: syne(sz: 14, w: FontWeight.w900, ls: 2),
            ),
            SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [0.5, 1.0, 1.5, 2.0]
                  .map(
                    (s) => GestureDetector(
                      onTap: () {
                        _saveHistory();
                        setState(() {
                          clip.speed = s;
                          _videoController?.setPlaybackSpeed(s);
                        });
                        Navigator.pop(context);
                        _feedback("Speed: ${s}x");
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: clip.speed == s
                              ? C.brand
                              : C.text.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${s}x',
                          style: syne(
                            sz: 14,
                            w: FontWeight.bold,
                            c: clip.speed == s ? Colors.black : C.sub,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _syncAudioToVideo() {
    if (_sequence.isEmpty || _selectedTrack == null) return;
    double totalVideoDuration = _sequence.fold(
      0.0,
      (sum, clip) => sum + (clip.end - clip.start),
    );
    final end = totalVideoDuration.clamp(1.0, 60.0);
    final current = _musicClip;
    final operation = _musicOperation;
    if (current != null && operation != null) {
      _project.upsertClip(TrackType.music, TimelineClip(
        id: current.id, start: current.start, duration: Duration(milliseconds: (end * 1000).round()),
        file: current.file, volume: current.volume,
        operation: AudioClipOperation(sourceType: operation.sourceType, sourceUrl: operation.sourceUrl,
          label: operation.label, volume: operation.volume, speed: operation.speed,
          reverse: operation.reverse, fadeIn: operation.fadeIn, fadeOut: operation.fadeOut,
          startOffset: 0, endOffset: end),
      ));
    }
    _feedback("Audio Synced to ${totalVideoDuration.toStringAsFixed(1)}s");
  }

  void _showSoundPicker() async {
    _videoController?.pause();
    await _musicPlayer.stop();

    if (!mounted) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MusicLibraryScreen()),
    );

    if (result is MusicTrack) {
      final durationSeconds = _totalDuration.clamp(1.0, 60.0);
      _project.transact((tracks) {
        final musicTrack = TimelineModelUtils.ensureTrackForType(tracks, TrackType.music);
        musicTrack.clips.removeWhere((clip) => clip.operation is AudioClipOperation &&
            (clip.operation as AudioClipOperation).sourceType == 'music');
        TimelineModelUtils.insertClip(tracks, TimelineClip(
          id: 'desktop-audio-music', start: Duration.zero,
          duration: Duration(milliseconds: (durationSeconds * 1000).round()),
          volume: 0.5,
          operation: AudioClipOperation(sourceType: 'music', sourceUrl: result.audioUrl,
            label: result.title, volume: 0.5, startOffset: 0, endOffset: durationSeconds),
        ), TrackType.music);
      });
      setState(() => _selectedTrack = result);

      _musicPlayer.setReleaseMode(ReleaseMode.loop);
      await _musicPlayer.play(UrlSource(result.audioUrl));
      _videoController?.play();
      _feedback("Sound synced: ${result.title}");
    } else {
      _videoController?.play();
    }
  }

  List<VideoClip> get _effectTargets {
    if (_selectedClips.isNotEmpty) return _selectedClips.toList();
    if (_sequence.isEmpty) return <VideoClip>[];
    return <VideoClip>[_sequence[_activeClipIndex.clamp(0, _sequence.length - 1).toInt()]];
  }

  void _syncLookControlsFromClip(VideoClip clip) {
    _selectedFilter = clip.filter;
    _brightness = clip.brightness;
    _contrast = clip.contrast;
    _saturation = clip.saturation;
    _hue = clip.hue;
    _effectVignette = clip.vignette;
    _effectGrain = clip.grain;
    _effectBlur = clip.blur;
  }

  void _applyLookControlsToTargets() {
    for (final clip in _effectTargets) {
      clip.filter = _selectedFilter;
      clip.brightness = _brightness;
      clip.contrast = _contrast;
      clip.saturation = _saturation;
      clip.hue = _hue;
      clip.vignette = _effectVignette;
      clip.grain = _effectGrain;
      clip.blur = _effectBlur;
    }
    _syncSharedProjectFromSequence();
  }

  void _showTransformEditor() {
    if (_sequence.isEmpty) return;
    final targets = _effectTargets;
    if (targets.isEmpty) return;
    _saveHistory();
    final clip = targets.first;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            padding: EdgeInsets.fromLTRB(24, 20, 24, 28),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.94),
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border.all(color: C.dim),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'TRANSFORM CLIP',
                  style: syne(
                    sz: 14,
                    w: FontWeight.w900,
                    c: C.text,
                    ls: 2,
                  ),
                ),
                SizedBox(height: 18),
                _adjustSlider('Scale', clip.scale, 0.5, 2.4, (v) {
                  setModalState(() { for (final target in targets) { target.scale = v; } });
                  setState(() => _syncSharedProjectFromSequence());
                }),
                _adjustSlider('Rotation', clip.rotation, -0.8, 0.8, (v) {
                  setModalState(() { for (final target in targets) { target.rotation = v; } });
                  setState(() => _syncSharedProjectFromSequence());
                }),
                _adjustSlider('Position X', clip.offsetX, -160, 160, (v) {
                  setModalState(() { for (final target in targets) { target.offsetX = v; } });
                  setState(() => _syncSharedProjectFromSequence());
                }),
                _adjustSlider('Position Y', clip.offsetY, -220, 220, (v) {
                  setModalState(() { for (final target in targets) { target.offsetY = v; } });
                  setState(() => _syncSharedProjectFromSequence());
                }),
                _adjustSlider('Opacity', clip.opacity, 0.05, 1.0, (v) {
                  setModalState(() { for (final target in targets) { target.opacity = v; } });
                  setState(() => _syncSharedProjectFromSequence());
                }),
                SizedBox(height: 10),
                _actionRow(Icons.restart_alt, 'Reset Transform', () {
                  setModalState(() {
                    for (final target in targets) {
                      target.scale = 1.0;
                      target.rotation = 0.0;
                      target.offsetX = 0.0;
                      target.offsetY = 0.0;
                      target.opacity = 1.0;
                    }
                  });
                  setState(() {});
                }, c: C.brand),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showEffectsEditor() {
    if (_sequence.isEmpty) return;
    final targets = _effectTargets;
    _syncLookControlsFromClip(targets.first);
    _saveHistory();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 28),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.94),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: C.dim),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'EFFECTS EDITOR',
                style: syne(sz: 14, w: FontWeight.w900, c: C.text, ls: 2),
              ),
              SizedBox(height: 18),
              _adjustSlider('Vignette', _effectVignette, 0.0, 1.0, (v) {
                setModalState(() => _effectVignette = v);
                for (final target in targets) { target.vignette = v; }
                setState(() => _syncSharedProjectFromSequence());
              }),
              _adjustSlider('Film grain', _effectGrain, 0.0, 1.0, (v) {
                setModalState(() => _effectGrain = v);
                for (final target in targets) { target.grain = v; }
                setState(() => _syncSharedProjectFromSequence());
              }),
              _adjustSlider('Soft blur', _effectBlur, 0.0, 8.0, (v) {
                setModalState(() => _effectBlur = v);
                for (final target in targets) { target.blur = v; }
                setState(() => _syncSharedProjectFromSequence());
              }),
              SizedBox(height: 10),
              _actionRow(Icons.restart_alt, 'Reset Effects', () {
                setModalState(() {
                  _effectVignette = 0.0;
                  _effectGrain = 0.0;
                  _effectBlur = 0.0;
                  for (final target in targets) {
                    target.vignette = 0.0;
                    target.grain = 0.0;
                    target.blur = 0.0;
                  }
                });
                setState(() {});
              }, c: C.brand),
            ],
          ),
        ),
      ),
    );
  }

  void _applyFilterPreset(ImageFilter filter) {
    _selectedFilter = filter;
    switch (filter) {
      case ImageFilter.normal:
        _brightness = 0.0;
        _contrast = 1.0;
        _saturation = 1.0;
        _hue = 0.0;
        break;
      case ImageFilter.warm:
        _brightness = 0.04;
        _contrast = 1.08;
        _saturation = 1.16;
        _hue = 0.08;
        break;
      case ImageFilter.cool:
        _brightness = 0.01;
        _contrast = 1.05;
        _saturation = 0.92;
        _hue = -0.12;
        break;
      case ImageFilter.vivid:
        _brightness = 0.03;
        _contrast = 1.22;
        _saturation = 1.42;
        _hue = 0.0;
        break;
      case ImageFilter.cinematic:
        _brightness = -0.04;
        _contrast = 1.28;
        _saturation = 0.86;
        _hue = -0.05;
        _effectVignette = 0.28;
        break;
      case ImageFilter.vintage:
        _brightness = 0.06;
        _contrast = 0.92;
        _saturation = 0.78;
        _hue = 0.18;
        _effectGrain = 0.32;
        break;
      case ImageFilter.blackAndWhite:
        _brightness = 0.0;
        _contrast = 1.18;
        _saturation = 0.0;
        _hue = 0.0;
        break;
      case ImageFilter.noir:
        _brightness = -0.08;
        _contrast = 1.45;
        _saturation = 0.0;
        _hue = 0.0;
        _effectVignette = 0.45;
        break;
      case ImageFilter.softGlow:
        _brightness = 0.08;
        _contrast = 0.9;
        _saturation = 1.1;
        _hue = 0.03;
        _effectBlur = 1.2;
        break;
    }
    _applyLookControlsToTargets();
  }

  void _showFilterSheet() {
    if (_sequence.isEmpty) return;
    final targets = _effectTargets;
    _syncLookControlsFromClip(targets.first);
    _saveHistory();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          height: 174,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.92),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: Text(
                  'FILTER PRESETS',
                  style: syne(
                    sz: 12,
                    w: FontWeight.w900,
                    c: C.text,
                    ls: 2,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.all(16),
                  children: ImageFilter.values
                      .map(
                        (f) => GestureDetector(
                          onTap: () {
                            setModalState(() => _applyFilterPreset(f));
                            setState(() {});
                          },
                          child: Container(
                            width: 92,
                            margin: EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              color: _selectedFilter == f
                                  ? C.brand
                                  : C.dim,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _selectedFilter == f
                                    ? C.brand
                                    : C.dim,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.filter,
                                  color: _selectedFilter == f
                                      ? Colors.black
                                      : C.text,
                                  size: 20,
                                ),
                                SizedBox(height: 7),
                                Text(
                                  f.name
                                      .replaceAllMapped(
                                        RegExp(r'([A-Z])'),
                                        (m) => ' ${m[1]}',
                                      )
                                      .toUpperCase(),
                                  textAlign: TextAlign.center,
                                  style: syne(
                                    sz: 8,
                                    w: FontWeight.bold,
                                    c: _selectedFilter == f
                                        ? Colors.black
                                        : C.text,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _applyBeautyFilterToClip() async {
    final clip = _sequence[_activeClipIndex];
    if (!clip.isVideo) {
      _feedback("Select a video clip first.");
      return;
    }

    if (!_faceEngine.parameters.isEnabled) {
      Navigator.pop(context);
      _feedback("Original clip kept unchanged.");
      return;
    }

    _videoController?.pause();
    _musicPlayer.pause();
    Navigator.pop(context); // close sheet

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: C.brand),
            SizedBox(height: 16),
            Text(
              "Applying ${_faceEngine.selectedPreset.name}...",
              style: syne(sz: 14, w: FontWeight.bold, c: C.text),
            ),
          ],
        ),
      ),
    );

    try {
      final enhancedFile = await _videoService.enhanceVideo(
        inputVideo: clip.file,
        options: VideoEnhancementOptions(
          faceParameters: _faceEngine.parameters,
        ),
      );

      if (mounted) {
        if (enhancedFile.path == clip.file.path) {
          _feedback("Face preset could not be applied.");
          return;
        }
        setState(() {
          _saveHistory();
          _sequence[_activeClipIndex] = VideoClip(
            file: enhancedFile,
            start: clip.start,
            end: clip.end,
            duration: clip.duration,
            speed: clip.speed,
            volume: clip.volume,
            hasAudio: clip.hasAudio,
            scale: clip.scale,
            rotation: clip.rotation,
            offsetX: clip.offsetX,
            offsetY: clip.offsetY,
            opacity: clip.opacity,
          );
        });
        _feedback("${_faceEngine.selectedPreset.name} preset applied.");
      }
    } catch (e) {
      if (mounted) _feedback("Failed to apply filter: $e");
    } finally {
      if (mounted) {
        Navigator.pop(context); // close dialog
        _loadClip(_activeClipIndex); // Reload the new video
      }
    }
  }

  void _showBeautySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.card,
      builder: (_) => FacePresetSheet(
        controller: _faceEngine,
        isPro: _isProEnabled,
        onApply: _applyBeautyFilterToClip,
        onLockedPreset: (preset) {
          _feedback('${preset.name} is available with NECXA Pro.');
        },
      ),
    );
  }

  // -- CORE UI UTILITIES ---------------------------------------
  Widget _buildPreviewLayer() {
    double ratio = 9 / 16;
    if (_selectedAspectRatio == '1:1') {
      ratio = 1.0;
    } else if (_selectedAspectRatio == '4:5')
      ratio = 4 / 5;

    if (_videoController != null && _videoController!.value.isInitialized) {
      final clip = _sequence.isNotEmpty ? _sequence[_activeClipIndex] : null;
      Widget player = Center(
        child: AspectRatio(
          aspectRatio: ratio,
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
        ),
      );

      if (clip != null) {
        player = Opacity(
          opacity: clip.opacity.clamp(0.05, 1.0),
          child: Transform.translate(
            offset: Offset(clip.offsetX, clip.offsetY),
            child: Transform.rotate(
              angle: clip.rotation,
              child: Transform.scale(scale: clip.scale, child: player),
            ),
          ),
        );
      }

      // Apply Shader if loaded
      if (_shaderProgram != null) {
        player = CustomPaint(
          painter: ShaderPainter(
            shader: _shaderProgram!.fragmentShader(),
            brightness: clip?.brightness ?? 0.0,
            contrast: clip?.contrast ?? 1.0,
            saturation: clip?.saturation ?? 1.0,
            hue: clip?.hue ?? 0.0,
          ),
          child: player,
        );
      }

      if ((clip?.blur ?? 0.0) > 0) {
        player = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: clip!.blur,
            sigmaY: clip.blur,
          ),
          child: player,
        );
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          player,
          if ((clip?.vignette ?? 0.0) > 0)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.72 * clip!.vignette),
                    ],
                    stops: const [0.55, 1.0],
                  ),
                ),
              ),
            ),
          if ((clip?.grain ?? 0.0) > 0)
            IgnorePointer(
              child: CustomPaint(
                painter: GrainPainter(intensity: clip!.grain),
              ),
            ),
        ],
      );
    }
    if (_sequence.isNotEmpty &&
        _activeClipIndex >= 0 &&
        _activeClipIndex < _sequence.length &&
        !_sequence[_activeClipIndex].isVideo) {
      final clip = _sequence[_activeClipIndex];
      Widget photo = Image.file(clip.file, fit: BoxFit.contain);
      photo = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()..scale(clip.isReversed ? -clip.scale : clip.scale, clip.scale),
        child: Transform.translate(
          offset: Offset(clip.offsetX, clip.offsetY),
          child: Transform.rotate(angle: clip.rotation, child: photo),
        ),
      );
      return Center(
        child: AspectRatio(
          aspectRatio: ratio,
          child: ClipRect(child: Opacity(opacity: clip.opacity.clamp(0.05, 1.0), child: photo)),
        ),
      );
    }
    return Center(child: CircularProgressIndicator(color: C.brand));
  }

  List<Widget> _buildVisibleOverlays() {
    if (_overlays.isEmpty) return [];

    final globalTime =
        _videoController != null && _videoController!.value.isInitialized
        ? _getGlobalTime(
            _activeClipIndex,
            _videoController!.value.position.inMilliseconds / 1000.0,
          )
        : 0.0;

    final totalDuration = _totalDuration;
    if (totalDuration <= 0) return [];

    return _overlays
        .where((o) {
          final start = o.start * totalDuration;
          final end = o.end * totalDuration;
          return globalTime >= start && globalTime <= end;
        })
        .map((o) {
          final overlayStart = o.start * totalDuration;
          final overlayEnd = o.end * totalDuration;
          const animationDuration = 0.35;
          final enterProgress = ((globalTime - overlayStart) / animationDuration).clamp(0.0, 1.0);
          final exitProgress = ((overlayEnd - globalTime) / animationDuration).clamp(0.0, 1.0);
          var animationOpacity = 1.0;
          var animationOffset = Offset.zero;
          var animationScale = 1.0;
          switch (o.animationIn) {
            case 'fade':
              animationOpacity *= enterProgress;
              break;
            case 'slide_up':
              animationOffset += Offset(0, 36 * (1 - enterProgress));
              break;
            case 'slide_left':
              animationOffset += Offset(48 * (1 - enterProgress), 0);
              break;
            case 'pop':
              animationScale = 0.88 + (0.12 * enterProgress);
              animationOpacity *= enterProgress;
              break;
          }
          switch (o.animationOut) {
            case 'fade':
              animationOpacity *= exitProgress;
              break;
            case 'slide_up':
              animationOffset += Offset(0, -36 * (1 - exitProgress));
              break;
            case 'slide_left':
              animationOffset += Offset(-48 * (1 - exitProgress), 0);
              break;
            case 'pop':
              animationScale *= 0.82 + (0.18 * exitProgress);
              animationOpacity *= exitProgress;
              break;
          }
          return Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final x = o.position.dx * constraints.maxWidth;
                final y = o.position.dy * constraints.maxHeight;

                Widget child;
                if (o.kind == 'sticker') {
                  child = Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: o.background.withOpacity(o.backgroundOpacity),
                      borderRadius: BorderRadius.circular(8),
                      border: o.stroke
                          ? Border.all(color: C.text, width: 2)
                          : null,
                    ),
                    child: Text(
                      o.text,
                      style: syne(
                        sz: o.fontSize,
                        w: FontWeight.w900,
                        c: o.color,
                      ),
                    ),
                  );
                } else {
                  final textAlign = o.align == 'left'
                      ? TextAlign.left
                      : o.align == 'right'
                          ? TextAlign.right
                          : TextAlign.center;
                  final fontFamily = o.fontFamily.toLowerCase() == 'syne'
                      ? 'Roboto'
                      : o.fontFamily;
                  final themeShadowColor = switch (o.themeId) {
                    'neon' => const Color(0xFF16E8F2),
                    'karaoke' => const Color(0xFFFFD166),
                    'afro' => const Color(0xFFFF8A3D),
                    _ => Colors.black54,
                  };
                  final themeShadow = o.themeId != 'minimal' &&
                      (o.shadow || const {'cinematic', 'neon', 'karaoke', 'afro'}.contains(o.themeId));
                  final themeStroke = o.stroke || o.themeId == 'bold';
                  final themeFontWeight = o.themeId == 'bold' || o.themeId == 'afro'
                      ? FontWeight.w900
                      : FontWeight.bold;
                  final fillStyle = TextStyle(
                    fontSize: o.fontSize,
                    fontFamily: o.themeId == 'afro' ? 'serif' : fontFamily,
                    color: o.color.withOpacity(o.opacity),
                    fontWeight: themeFontWeight,
                    letterSpacing: o.themeId == 'cinematic' ? 1.1 : 0,
                    shadows: themeShadow
                        ? [
                            Shadow(
                              blurRadius: o.themeId == 'neon' ? 18 : 8,
                              color: themeShadowColor,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  );
                  child = Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: o.background.withOpacity(o.backgroundOpacity),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (themeStroke)
                          Text(
                            o.text,
                            textAlign: textAlign,
                            style: TextStyle(
                              fontSize: o.fontSize,
                              fontFamily: fontFamily,
                              fontWeight: FontWeight.bold,
                              foreground: ui.Paint()
                                ..style = ui.PaintingStyle.stroke
                                ..strokeWidth = 2
                                ..color = Colors.black,
                            ),
                          ),
                        Text(o.text, textAlign: textAlign, style: fillStyle),
                      ],
                    ),
                  );
                }

                child = Opacity(
                  opacity: animationOpacity.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: animationOffset,
                    child: child,
                  ),
                );
                final left = o.align == 'left'
                    ? x
                    : o.align == 'right'
                        ? x - 300
                        : x - 150;
                return Positioned(
                  left: left,
                  top: y - 50,
                  child: Transform.rotate(
                    angle: o.rotation,
                    child: Transform.scale(
                      scale: o.scale * animationScale,
                      child: SizedBox(
                        width: 300,
                        height: 100,
                        child: Center(child: child),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        })
        .toList();
  }

  void _showTextOverlaySheet({String initialMode = 'single'}) {
    final textController = TextEditingController();
    var contentMode = initialMode;
    var start = 0.0;
    var end = 1.0;
    var fontSize = initialMode == 'captions' ? 22.0 : 30.0;
    var selectedTheme = initialMode == 'captions' ? 'minimal' : 'cinematic';
    var animationIn = 'fade';
    var animationOut = 'fade';
    var selectedColor = const Color(0xFFF7F4ED);
    var fontFamily = 'Roboto';
    var align = 'center';
    var isTranscribing = false;
    List<Map<String, dynamic>>? aiCaptionSegments;
    final duration = _totalDuration > 0 ? _totalDuration : 30.0;
    final themes = <String, Map<String, dynamic>>{
      'cinematic': {'label': 'Cinematic', 'color': const Color(0xFFF7F4ED), 'size': 30.0, 'shadow': true},
      'neon': {'label': 'Neon', 'color': const Color(0xFF7DF9FF), 'size': 34.0, 'shadow': true},
      'karaoke': {'label': 'Karaoke', 'color': const Color(0xFFFFD166), 'size': 32.0, 'shadow': true},
      'minimal': {'label': 'Minimal', 'color': const Color(0xFFFFFFFF), 'size': 26.0, 'shadow': false},
      'bold': {'label': 'Bold', 'color': const Color(0xFFFFFFFF), 'size': 38.0, 'shadow': true},
      'afro': {'label': 'Afro glow', 'color': const Color(0xFFFFB45C), 'size': 32.0, 'shadow': true},
    };
    const animations = ['none', 'fade', 'slide_up', 'slide_left', 'pop'];
    const fontFamilies = ['Roboto', 'serif', 'monospace', 'cursive'];

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111722),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) {
          Widget sectionTitle(String label) => Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(label.toUpperCase(), style: syne(sz: 10, w: FontWeight.w800, c: C.sub, ls: 1.2)),
            ),
          );
          final isMultiLine = contentMode != 'single';
          final layers = _overlays.asMap().entries.toList();
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 16, 18, MediaQuery.of(context).viewInsets.bottom + 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text('TEXT STUDIO', style: syne(sz: 16, w: FontWeight.w900, c: C.text, ls: 1))),
                      IconButton(onPressed: isTranscribing ? null : () => Navigator.pop(sheetContext), icon: Icon(Icons.close, color: C.sub)),
                    ]),
                    Text('Build captions, lyrics videos and animated titles.', style: dm(sz: 11, c: C.sub)),
                    const SizedBox(height: 14),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'single', label: Text('Title'), icon: Icon(Icons.title)),
                        ButtonSegment(value: 'captions', label: Text('Captions'), icon: Icon(Icons.closed_caption_outlined)),
                        ButtonSegment(value: 'lyrics', label: Text('Lyrics'), icon: Icon(Icons.music_note)),
                      ],
                      selected: {contentMode},
                      onSelectionChanged: (value) => refresh(() {
                        contentMode = value.first;
                        if (contentMode == 'captions') {
                          fontSize = 22;
                          selectedTheme = 'minimal';
                          selectedColor = const Color(0xFFFFFFFF);
                        } else if (contentMode == 'lyrics') {
                          fontSize = 30;
                        }
                      }),
                      showSelectedIcon: false,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: textController,
                      minLines: isMultiLine ? 4 : 2,
                      maxLines: 10,
                      style: dm(sz: 14, c: C.text),
                      decoration: InputDecoration(
                        hintText: contentMode == 'lyrics'
                            ? 'Enter one lyric line per row…'
                            : contentMode == 'captions'
                                ? 'Paste or type captions, one caption per row…'
                                : 'Type your title or caption…',
                        hintStyle: dm(sz: 12, c: C.dim),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.045),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                    if (contentMode == 'captions' || contentMode == 'lyrics') ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: isTranscribing ? null : () async {
                            if (_sequence.isEmpty || _activeClipIndex >= _sequence.length) {
                              _feedback('Add and select a video clip first.');
                              return;
                            }
                            final clip = _sequence[_activeClipIndex];
                            if (!clip.isVideo || !clip.hasAudio) {
                              _feedback('Select a video clip that contains audio.');
                              return;
                            }
                            refresh(() => isTranscribing = true);
                            File? extractedAudio;
                            try {
                              extractedAudio = await VideoEnhancementService()
                                  .extractAudioForTranscription(
                                    clip.file,
                                    start: clip.start,
                                    end: clip.end,
                                    reverse: clip.isReversed,
                                  );
                              if (extractedAudio == null) {
                                _feedback('Could not extract audio from this clip.');
                                return;
                              }
                              final result = await NecxaAI.transcribeMedia(extractedAudio);
                              if (result['success'] != true) {
                                _feedback(result['error']?.toString() ?? 'AI transcription failed.');
                                return;
                              }
                              final transcript = (result['transcript'] ?? '').toString().trim();
                              if (transcript.isEmpty) {
                                _feedback('No speech was detected in the selected clip.');
                                return;
                              }

                              double clipOffset = 0;
                              for (var i = 0; i < _activeClipIndex; i++) {
                                final prior = _sequence[i];
                                clipOffset += (prior.end - prior.start) / prior.speed;
                              }
                              final clipDuration = ((clip.end - clip.start) / clip.speed)
                                  .clamp(0.1, double.infinity).toDouble();
                              final rawSegments = result['segments'] is List
                                  ? result['segments'] as List
                                  : (result['words'] is List ? result['words'] as List : <dynamic>[]);
                              final timed = <Map<String, dynamic>>[];
                              var lineText = '';
                              var lineStart = 0.0;
                              var lineEnd = 0.0;
                              void flushLine() {
                                if (lineText.trim().isEmpty) return;
                                timed.add({'text': lineText.trim(), 'start': lineStart, 'end': lineEnd});
                                lineText = '';
                              }

                              for (final item in rawSegments) {
                                if (item is! Map) continue;
                                final word = (item['text'] ?? item['word'] ?? '').toString().trim();
                                final sourceStart = (item['start'] as num?)?.toDouble();
                                final sourceEnd = (item['end'] as num?)?.toDouble();
                                if (word.isEmpty || sourceStart == null || sourceEnd == null || sourceEnd <= sourceStart) continue;
                                // The audio extractor returns only the selected
                                // source trim, so ASR timestamps start at zero.
                                // Convert source-time offsets to the clip playback clock.
                                final wordStart = (sourceStart / clip.speed)
                                    .clamp(0.0, clipDuration).toDouble();
                                final wordEnd = (sourceEnd / clip.speed)
                                    .clamp(0.0, clipDuration).toDouble();
                                if (wordEnd <= wordStart) continue;
                                if (lineText.isNotEmpty &&
                                    (lineText.length + word.length + 1 > 42 ||
                                     wordStart - lineStart > 4.2)) {
                                  flushLine();
                                }
                                if (lineText.isEmpty) lineStart = wordStart;
                                lineText = lineText.isEmpty ? word : '$lineText $word';
                                lineEnd = wordEnd;
                              }
                              flushLine();

                              if (timed.isEmpty) {
                                final words = transcript.split(RegExp(r'\s+'));
                                final lines = <String>[];
                                var current = '';
                                for (final word in words) {
                                  final candidate = current.isEmpty ? word : '$current $word';
                                  if (candidate.length > 42 && current.isNotEmpty) {
                                    lines.add(current);
                                    current = word;
                                  } else {
                                    current = candidate;
                                  }
                                }
                                if (current.isNotEmpty) lines.add(current);
                                final weights = lines.map((line) => line.split(RegExp(r'\s+')).length).toList();
                                final totalWeight = weights.fold<int>(0, (sum, weight) => sum + weight);
                                var cursor = 0.0;
                                for (var i = 0; i < lines.length; i++) {
                                  final span = totalWeight == 0 ? 0.0 : clipDuration * weights[i] / totalWeight;
                                  timed.add({
                                    'text': lines[i],
                                    'start': cursor,
                                    'end': i == lines.length - 1 ? clipDuration : cursor + span,
                                  });
                                  cursor += span;
                                }
                              }

                              aiCaptionSegments = timed;
                              textController.text = timed.map((segment) => segment['text']).join('\n');
                              refresh(() => isTranscribing = false);
                              final readyLabel = contentMode == 'lyrics' ? 'timed lyrics' : 'captions';
                              _feedback(result['persisted'] == true
                                  ? 'AI transcript ready and saved to Supabase 2. Review it, then add the $readyLabel.'
                                  : 'AI transcript ready. Review it, then add the $readyLabel.');
                            } catch (error) {
                              _feedback('Caption generation failed. Please try again.');
                              debugPrint('Text Studio caption generation error: $error');
                            } finally {
                              if (extractedAudio != null) {
                                try { await extractedAudio.delete(); } catch (_) {}
                              }
                              refresh(() => isTranscribing = false);
                            }
                          },
                          icon: isTranscribing
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.auto_awesome),
                          label: Text(isTranscribing
                              ? 'TRANSCRIBING AUDIO…'
                              : contentMode == 'lyrics'
                                  ? 'SYNC LYRICS WITH AI'
                                  : 'GENERATE CAPTIONS WITH AI'),
                        ),
                      ),
                      Text('Uses the selected clip audio. It is sent securely through Supabase 2 to Necxa AI Engine for transcription.', style: dm(sz: 10, c: C.dim)),
                    ],
                    sectionTitle('Display timer'),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('Start  ${(start * duration).toStringAsFixed(1)}s', style: dm(sz: 11, c: C.text)),
                      Text('End  ${(end * duration).toStringAsFixed(1)}s', style: dm(sz: 11, c: C.text)),
                    ]),
                    RangeSlider(
                      values: RangeValues(start, end),
                      min: 0,
                      max: 1,
                      divisions: 100,
                      activeColor: C.brand,
                      onChanged: (value) => refresh(() { start = value.start; end = value.end; }),
                    ),
                    if (isMultiLine)
                      Text('Each non-empty row becomes its own editable timeline layer, initially spaced evenly across this range. Adjust individual timings below.', style: dm(sz: 10, c: C.dim)),
                    sectionTitle('Themes'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: themes.entries.map((entry) {
                        final active = selectedTheme == entry.key;
                        return ChoiceChip(
                          label: Text(entry.value['label'] as String),
                          selected: active,
                          onSelected: (_) => refresh(() {
                            selectedTheme = entry.key;
                            selectedColor = entry.value['color'] as Color;
                            fontSize = entry.value['size'] as double;
                          }),
                          labelStyle: dm(sz: 11, c: active ? Colors.black : C.text, w: FontWeight.w700),
                          selectedColor: entry.value['color'] as Color,
                          backgroundColor: Colors.white.withOpacity(0.06),
                        );
                      }).toList(),
                    ),
                    sectionTitle('Typography'),
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: fontFamily,
                          dropdownColor: const Color(0xFF202938),
                          style: dm(sz: 12, c: C.text),
                          decoration: const InputDecoration(labelText: 'Font', isDense: true, filled: true, fillColor: Color(0xFF1B2431), border: OutlineInputBorder()),
                          items: fontFamilies.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
                          onChanged: (value) => refresh(() => fontFamily = value ?? 'Roboto'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: align,
                          dropdownColor: const Color(0xFF202938),
                          style: dm(sz: 12, c: C.text),
                          decoration: const InputDecoration(labelText: 'Alignment', isDense: true, filled: true, fillColor: Color(0xFF1B2431), border: OutlineInputBorder()),
                          items: const [
                            DropdownMenuItem(value: 'left', child: Text('Left')),
                            DropdownMenuItem(value: 'center', child: Text('Center')),
                            DropdownMenuItem(value: 'right', child: Text('Right')),
                          ],
                          onChanged: (value) => refresh(() => align = value ?? 'center'),
                        ),
                      ),
                    ]),
                    sectionTitle('Text size'),
                    Slider(
                      value: fontSize.clamp(16.0, 64.0).toDouble(),
                      min: 16,
                      max: 64,
                      divisions: 24,
                      activeColor: C.brand,
                      label: fontSize.round().toString(),
                      onChanged: (value) => refresh(() => fontSize = value),
                    ),
                    sectionTitle('Entrance animation'),
                    DropdownButtonFormField<String>(
                      value: animationIn,
                      dropdownColor: const Color(0xFF202938),
                      style: dm(sz: 12, c: C.text),
                      decoration: const InputDecoration(isDense: true, filled: true, fillColor: Color(0xFF1B2431), border: OutlineInputBorder()),
                      items: animations.map((value) => DropdownMenuItem(value: value, child: Text(value.replaceAll('_', ' ').toUpperCase()))).toList(),
                      onChanged: (value) => refresh(() => animationIn = value ?? 'fade'),
                    ),
                    sectionTitle('Exit animation'),
                    DropdownButtonFormField<String>(
                      value: animationOut,
                      dropdownColor: const Color(0xFF202938),
                      style: dm(sz: 12, c: C.text),
                      decoration: const InputDecoration(isDense: true, filled: true, fillColor: Color(0xFF1B2431), border: OutlineInputBorder()),
                      items: animations.map((value) => DropdownMenuItem(value: value, child: Text(value.replaceAll('_', ' ').toUpperCase()))).toList(),
                      onChanged: (value) => refresh(() => animationOut = value ?? 'fade'),
                    ),
                    if (layers.isNotEmpty) ...[
                      sectionTitle('Existing text layers · ${layers.length}'),
                      ...layers.map((entry) {
                        final overlay = entry.value;
                        final from = (overlay.start * duration).toStringAsFixed(1);
                        final to = (overlay.end * duration).toStringAsFixed(1);
                        return Container(
                          margin: const EdgeInsets.only(bottom: 7),
                          decoration: BoxDecoration(color: Colors.white.withOpacity(0.045), borderRadius: BorderRadius.circular(10)),
                          child: ListTile(
                            dense: true,
                            title: Text(overlay.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: dm(sz: 12, c: C.text, w: FontWeight.w700)),
                            subtitle: Text('${from} s – ${to} s · ${overlay.themeId}', style: dm(sz: 10, c: C.dim)),
                            trailing: IconButton(
                              tooltip: 'Edit layer',
                              icon: Icon(Icons.tune, color: C.brand, size: 18),
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                _showEditTextLayerSheet(entry.key);
                              },
                            ),
                          ),
                        );
                      }),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: C.brand, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 14)),
                        icon: const Icon(Icons.add),
                        label: Text(contentMode == 'lyrics' ? 'ADD LYRIC LINES' : contentMode == 'captions' ? 'ADD CAPTION LAYERS' : 'ADD TEXT LAYER', style: syne(sz: 11, w: FontWeight.w900, c: Colors.black)),
                        onPressed: () {
                          final value = textController.text.trim();
                          if (value.isEmpty || end <= start) return;
                          final lines = isMultiLine
                              ? value.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => line.isNotEmpty).toList()
                              : [value];
                          if (lines.isEmpty) return;
                          _saveHistory();
                          final interval = (end - start) / lines.length;
                          double clipOffset = 0;
                          double clipDuration = 0;
                          if ((contentMode == 'captions' || contentMode == 'lyrics') &&
                              aiCaptionSegments != null &&
                              aiCaptionSegments!.length == lines.length &&
                              _activeClipIndex < _sequence.length) {
                            for (var i = 0; i < _activeClipIndex; i++) {
                              final prior = _sequence[i];
                              clipOffset += (prior.end - prior.start) / prior.speed;
                            }
                            final clip = _sequence[_activeClipIndex];
                            clipDuration = ((clip.end - clip.start) / clip.speed)
                                .clamp(0.1, double.infinity).toDouble();
                          }
                          setState(() {
                            for (var index = 0; index < lines.length; index++) {
                              final hasAiTiming = (contentMode == 'captions' || contentMode == 'lyrics') &&
                                  aiCaptionSegments != null &&
                                  aiCaptionSegments!.length == lines.length &&
                                  clipDuration > 0;
                              final segment = hasAiTiming ? aiCaptionSegments![index] : null;
                              final layerStart = hasAiTiming
                                  ? ((clipOffset + (segment!['start'] as num).toDouble()) / duration).clamp(0.0, 0.999).toDouble()
                                  : start + interval * index;
                              final layerEnd = hasAiTiming
                                  ? ((clipOffset + (segment!['end'] as num).toDouble()) / duration).clamp(layerStart + 0.001, 1.0).toDouble()
                                  : (index == lines.length - 1 ? end : start + interval * (index + 1));
                              _addProjectOverlay(OverlayOperation(
                                kind: 'text',
                                text: lines[index],
                                start: layerStart,
                                end: layerEnd,
                                position: Offset(0.5, contentMode == 'captions' ? 0.86 : 0.72),
                                fontSize: fontSize,
                                color: selectedColor,
                                shadow: themes[selectedTheme]!['shadow'] as bool,
                                align: align,
                                fontFamily: fontFamily,
                                animationIn: animationIn,
                                animationOut: animationOut,
                                themeId: selectedTheme,
                              ));
                            }
                            _syncSharedProjectFromSequence();
                          });
                          Navigator.pop(sheetContext);
                          _feedback(contentMode == 'lyrics' ? '${lines.length} timed lyric lines added' : contentMode == 'captions' ? '${lines.length} caption layers added' : 'Text layer added');
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).whenComplete(textController.dispose);
  }

  void _showEditTextLayerSheet(int index) {
    if (index < 0 || index >= _overlays.length) return;
    final overlay = _overlays[index];
    final controller = TextEditingController(text: overlay.text);
    var start = overlay.start.clamp(0.0, 1.0).toDouble();
    var end = overlay.end.clamp(start + 0.001, 1.0).toDouble();
    var fontSize = overlay.fontSize.clamp(16.0, 64.0).toDouble();
    var fontFamily = overlay.fontFamily.toLowerCase() == 'syne' ? 'Roboto' : overlay.fontFamily;
    var selectedColor = overlay.color;
    var animationIn = overlay.animationIn;
    var animationOut = overlay.animationOut;
    var depthLayer = overlay.depthLayer;
    const fontFamilies = ['Roboto', 'serif', 'monospace', 'cursive'];
    const animations = ['none', 'fade', 'slide_up', 'slide_left', 'pop'];
    final duration = _totalDuration > 0 ? _totalDuration : 30.0;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111722),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, MediaQuery.of(context).viewInsets.bottom + 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text('EDIT TEXT LAYER', style: syne(sz: 15, w: FontWeight.w900, c: C.text))),
                    IconButton(onPressed: () => Navigator.pop(sheetContext), icon: Icon(Icons.close, color: C.sub)),
                  ]),
                  TextField(controller: controller, maxLines: 4, style: dm(sz: 14, c: C.text), decoration: const InputDecoration(labelText: 'Text')),
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('Start ${(start * duration).toStringAsFixed(1)}s', style: dm(sz: 11, c: C.text)),
                    Text('End ${(end * duration).toStringAsFixed(1)}s', style: dm(sz: 11, c: C.text)),
                  ]),
                  RangeSlider(
                    values: RangeValues(start, end),
                    min: 0,
                    max: 1,
                    divisions: 100,
                    activeColor: C.brand,
                    onChanged: (value) => refresh(() { start = value.start; end = value.end; }),
                  ),
                  Text('Font size', style: dm(sz: 11, c: C.sub)),
                  Slider(value: fontSize, min: 16, max: 64, divisions: 24, activeColor: C.brand, onChanged: (value) => refresh(() => fontSize = value)),
                  DropdownButtonFormField<String>(
                    value: fontFamily,
                    dropdownColor: const Color(0xFF202938),
                    style: dm(sz: 12, c: C.text),
                    decoration: const InputDecoration(labelText: 'Font', isDense: true),
                    items: fontFamilies.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
                    onChanged: (value) => refresh(() => fontFamily = value ?? 'Roboto'),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 10, children: [
                    for (final color in const [Color(0xFFFFFFFF), Color(0xFFFFD166), Color(0xFF7DF9FF), Color(0xFFFFB45C), Color(0xFFFF6B8A)])
                      GestureDetector(
                        onTap: () => refresh(() => selectedColor = color),
                        child: CircleAvatar(radius: 14, backgroundColor: color, child: selectedColor == color ? const Icon(Icons.check, size: 14, color: Colors.black) : null),
                      ),
                  ]),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: animationIn,
                    dropdownColor: const Color(0xFF202938),
                    style: dm(sz: 12, c: C.text),
                    decoration: const InputDecoration(labelText: 'Entrance', isDense: true),
                    items: animations.map((value) => DropdownMenuItem(value: value, child: Text(value.replaceAll('_', ' ')))).toList(),
                    onChanged: (value) => refresh(() => animationIn = value ?? 'none'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: animationOut,
                    dropdownColor: const Color(0xFF202938),
                    style: dm(sz: 12, c: C.text),
                    decoration: const InputDecoration(labelText: 'Exit', isDense: true),
                    items: animations.map((value) => DropdownMenuItem(value: value, child: Text(value.replaceAll('_', ' ')))).toList(),
                    onChanged: (value) => refresh(() => animationOut = value ?? 'none'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: depthLayer,
                    dropdownColor: const Color(0xFF202938),
                    style: dm(sz: 12, c: C.text),
                    decoration: const InputDecoration(labelText: 'Performer depth', isDense: true),
                    items: const [
                      DropdownMenuItem(value: 'background', child: Text('Behind performer')),
                      DropdownMenuItem(value: 'foreground', child: Text('In front of performer')),
                    ],
                    onChanged: (value) => refresh(() => depthLayer = value ?? 'foreground'),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      onPressed: () {
                        _saveHistory();
                        setState(() {
                          final duplicate = overlay.copy();
                          final shift = (overlay.end - overlay.start).clamp(0.01, 1.0).toDouble() * 0.1;
                          duplicate.start = (overlay.start + shift).clamp(0.0, 0.99).toDouble();
                          duplicate.end = (overlay.end + shift).clamp(duplicate.start + 0.01, 1.0).toDouble();
                          _addProjectOverlay(duplicate);
                        });
                        Navigator.pop(sheetContext);
                        _feedback('Text layer duplicated');
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Duplicate'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: OutlinedButton.icon(
                      onPressed: () {
                        _saveHistory();
                        setState(() {
                          _removeProjectOverlayAt(index);
                        });
                        Navigator.pop(sheetContext);
                        _feedback('Text layer deleted');
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    )),
                  ]),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: C.brand, foregroundColor: Colors.black),
                      onPressed: () {
                        if (controller.text.trim().isEmpty || end <= start) return;
                        _saveHistory();
                        setState(() {
                          overlay.text = controller.text.trim();
                          overlay.start = start;
                          overlay.end = end;
                          overlay.fontSize = fontSize;
                          overlay.fontFamily = fontFamily;
                          overlay.color = selectedColor;
                          overlay.animationIn = animationIn;
                          overlay.animationOut = animationOut;
                          overlay.depthLayer = depthLayer;
                          _syncSharedProjectFromSequence();
                        });
                        Navigator.pop(sheetContext);
                        _feedback('Text layer updated');
                      },
                      child: Text('SAVE CHANGES', style: syne(sz: 11, w: FontWeight.w900, c: Colors.black)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  void _showFrameOverlayPicker() {
    _feedback("Frame picker not implemented yet.");
  }

  void _toggleVoiceOver() async {
    if (_isRecordingVoice) {
      // Stop recording
      final recording = await _voiceoverService.stop();
      if (recording != null) {
        final duration = recording.duration > Duration.zero
            ? recording.duration
            : const Duration(milliseconds: 100);
        _project.upsertClip(TrackType.voiceOver, TimelineClip(
          id: 'desktop-audio-voice',
          start: Duration.zero,
          duration: duration,
          file: recording.file,
          volume: 0.8,
          operation: AudioClipOperation(
            sourceType: 'voiceOver',
            label: 'Voiceover',
            volume: 0.8,
          ),
        ));
        setState(() => _isRecordingVoice = false);
        _feedback("Voiceover recorded!");
      }
    } else {
      // Start recording
      if (await _voiceoverService.start()) {
        setState(() => _isRecordingVoice = true);
        _feedback("Recording voice... ??");
      } else {
        _feedback("Microphone permission denied.");
      }
    }
  }

  void _showCaptionSheet() {
    _showTextOverlaySheet(initialMode: 'captions');
  }

  void _showTransitionSheet() {
    if (_transitionsUnlocked) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Color(0xFF1A1D23),
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose Transition',
                    style: syne(sz: 15, w: FontWeight.w800, c: C.text),
                  ),
                  SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: TransitionPreset.presets.map((preset) {
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _transitions[_activeClipIndex] =
                                TransitionOperation(
                                  presetId: preset.id,
                                  presetName: preset.name,
                                  category: preset.category,
                                  icon: preset.icon,
                                  duration: preset.defaultDuration,
                                  intensity: preset.defaultIntensity,
                                  reverse: preset.defaultReverse,
                                );
                            _syncSharedProjectFromSequence();
                          });
                          Navigator.pop(sheetContext);
                          _feedback('${preset.name} transition selected');
                        },
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: C.text.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: C.text.withOpacity(0.12),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                preset.icon,
                                style: TextStyle(fontSize: 18),
                              ),
                              SizedBox(width: 8),
                              Text(
                                preset.name,
                                style: dm(
                                  sz: 12,
                                  w: FontWeight.w600,
                                  c: C.text,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          );
        },
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Color(0xFF1A1D23),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Unlock Pro Feature',
          style: TextStyle(color: C.text),
        ),
        content: Text(
          'Unlock Pro Transitions for all your projects for just 50 NCX.',
          style: dm(c: C.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Maybe Later'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: C.brand),
            onPressed: () async {
              Navigator.pop(dialogContext);
              setState(() => _isProcessing = true);
              try {
                final result = await FinanceBackend.instance.invoke(
                  'unlock_feature',
                  body: {
                    'featureId': 'pro_transitions',
                    'costNcx': 50,
                    'idempotencyKey':
                        'feature-pro_transitions-${widget.state.user?.id}',
                  },
                );
                if (result['success'] == true) {
                  setState(() => _transitionsUnlocked = true);
                  _feedback('Pro Transitions Unlocked! ??');
                  _showTransitionSheet();
                }
              } catch (e) {
                _feedback('Error: $e');
              } finally {
                if (mounted) setState(() => _isProcessing = false);
              }
            },
            child: Text(
              'Unlock (50 NCX)',
              style: syne(w: FontWeight.bold, c: Colors.black),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? c,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: C.text.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: C.text.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: c ?? C.sub, size: 16),
            SizedBox(width: 8),
            Text(
              label,
              style: syne(sz: 10, w: FontWeight.bold, c: c ?? C.sub),
            ),
          ],
        ),
      ),
    );
  }
}

class MaskingPreview extends StatelessWidget {
  final Widget child;
  final bool isMasked;
  final VoidCallback onToggle;
  final List<Widget> overlays;

  MaskingPreview({
    super.key,
    required this.child,
    required this.isMasked,
    required this.onToggle,
    required this.overlays,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        ...overlays,
        if (isMasked)
          Positioned.fill(
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: Container(color: Colors.black.withOpacity(0.6)),
            ),
          ),
        Positioned(
          top: 8,
          right: 8,
          child: GestureDetector(
            onTap: onToggle,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Row(
                children: [
                  Icon(
                    isMasked
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: C.text,
                    size: 14,
                  ),
                  SizedBox(width: 4),
                  Text(
                    isMasked ? 'Masked' : 'Visible',
                    style: dm(sz: 10, c: C.text),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
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
    final paint = Paint()..color = C.text.withOpacity(0.12 * intensity);
    for (int i = 0; i < 1500 * intensity; i++) {
      final x = _rand.nextDouble() * size.width;
      final y = _rand.nextDouble() * size.height;
      canvas.drawCircle(Offset(x, y), _rand.nextDouble() * 0.8, paint);
    }
  }

  @override
  bool shouldRepaint(covariant GrainPainter oldDelegate) => false;
}





class _EditorTimelineRulerPainter extends CustomPainter {
  final double pixelsPerSecond;
  final double duration;
  final Color color;

  const _EditorTimelineRulerPainter({
    required this.pixelsPerSecond,
    required this.duration,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 1;
    final labelStyle = TextStyle(
      color: color.withOpacity(0.9),
      fontSize: 8,
      fontWeight: FontWeight.w600,
    );
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    final step = duration > 90 ? 10 : duration > 35 ? 5 : 1;
    for (var second = 0; second <= duration.ceil(); second += step) {
      final x = second * pixelsPerSecond;
      if (x > size.width) break;
      canvas.drawLine(Offset(x, 11), Offset(x, size.height), line);
      textPainter.text = TextSpan(text: '${second}s', style: labelStyle);
      textPainter.layout();
      textPainter.paint(canvas, Offset(x + 3, 0));
    }
  }

  @override
  bool shouldRepaint(covariant _EditorTimelineRulerPainter oldDelegate) =>
      oldDelegate.pixelsPerSecond != pixelsPerSecond ||
      oldDelegate.duration != duration ||
      oldDelegate.color != color;
}

