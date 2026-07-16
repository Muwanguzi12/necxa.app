import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
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
  final File file;
  File? proxyFile; // Lightweight version for editing
  bool isProxyReady = false;

  double start; // seconds
  double end; // seconds
  double duration; // total source duration
  double speed;
  double volume;
  bool hasAudio;
  double scale;
  double rotation;
  double offsetX;
  double offsetY;
  double opacity;

  VideoClip({
    required this.file,
    this.proxyFile,
    this.isProxyReady = false,
    this.start = 0,
    this.end = 0.1,
    this.duration = 0,
    this.speed = 1.0,
    this.volume = 1.0,
    this.hasAudio = true,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.opacity = 1.0,
  });

  VideoClip copy() => VideoClip(
    file: file,
    proxyFile: proxyFile,
    isProxyReady: isProxyReady,
    start: start,
    end: end,
    duration: duration,
    speed: speed,
    volume: volume,
    hasAudio: hasAudio,
    scale: scale,
    rotation: rotation,
    offsetX: offsetX,
    offsetY: offsetY,
    opacity: opacity,
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

  const ProMediaEditorScreen({
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
  final EditorMediaService _mediaService = EditorMediaService();
  final ImageEnhancementService _enhancementService = ImageEnhancementService();
  final VideoEnhancementService _videoService = VideoEnhancementService();

  VideoPlayerController? _videoController;

  // Real-time Editing State
  ImageFilter? _selectedFilter;
  final double _beautyLevel = 0.5;
  bool _isProcessing = false;
  MusicTrack? _selectedTrack;
  final AudioPlayer _musicPlayer = AudioPlayer();
  final AudioPlayer _voicePlayer = AudioPlayer();
  final MusicLibraryService _musicService = MusicLibraryService();

  // Shader State
  ui.FragmentProgram? _shaderProgram;
  double _brightness = 0.0;
  double _contrast = 1.0;
  double _saturation = 1.0;
  double _hue = 0.0;

  // Advanced Tools State
  // Audio Mixer State
  double _bgmVolume = 0.5;
  double _voiceVolume = 0.8;
  double _originalVolume = 1.0;
  final bool _isMuted = false;
  bool _isPlaying = false;
  bool _syncingPlayback = false;
  String _selectedAspectRatio = '9:16';

  // Voice Over State
  bool _isRecordingVoice = false;
  File? _voiceOverFile;
  final EditorVoiceoverService _voiceoverService = EditorVoiceoverService();

  // Mask Mode
  bool _isMaskMode = false;
  double _effectVignette = 0.0;
  double _effectGrain = 0.0;
  double _effectBlur = 0.0;

  // Multi-track Sequencer State
  late List<VideoClip> _sequence;
  int _activeClipIndex = 0;

  // Professional Metadata
  final Map<int, TransitionOperation> _transitions = {};
  // Estimated renderer metadata
  final double _frameRate = 30.0;
  final int _bitrateKbps = 8000; // assumed default bitrate for size estimate

  // Overlay & Metadata State
  final List<OverlayOperation> _overlays = [];

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

  // Audio Timeline State
  double _audioStart = 0;
  double _audioEnd = 30; // 30s default
  final double _audioOffset = 0; // Where it starts in the global timeline

  @override
  void initState() {
    super.initState();
    final sharedFiles =
        widget.projectController?.tracks
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
    if (sharedFiles.isNotEmpty) {
      final sharedClips = widget.projectController!.tracks
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
            ),
          )
          .toList();
    }
    final sharedProject = widget.projectController;
    if (sharedProject != null) {
      for (final timelineClip in sharedProject.tracks.expand(
        (track) => track.clips,
      )) {
        final operation = timelineClip.operation;
        if (operation is OverlayOperation) {
          _overlays.add(operation.copy());
        } else if (operation is TransitionOperation &&
            timelineClip.id.startsWith('desktop-transition-')) {
          final index = int.tryParse(
            timelineClip.id.substring('desktop-transition-'.length),
          );
          if (index != null) _transitions[index] = operation;
        }
      }
    }

    if (widget.initialTrack != null) {
      _selectedTrack = widget.initialTrack;
      _musicPlayer.setReleaseMode(ReleaseMode.loop);
      _musicPlayer.play(UrlSource(_selectedTrack!.audioUrl));
    }

    _loadClip(_activeClipIndex);
    widget.projectController?.playback.addListener(_followSharedPlaybackClock);
    _probeDurations();
    _loadShaders();

    // Trigger proxy generation for initial clips
    for (var clip in _sequence) {
      if (clip.isVideo) _generateProxyForClip(clip);
    }
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
      final mediaFile = clip.isProxyReady ? clip.proxyFile! : clip.file;

      if (!mediaFile.existsSync() || mediaFile.lengthSync() == 0) {
        debugPrint(
          '❌ MediaEditor: Clip file is empty or missing! ${mediaFile.path}',
        );
        _feedback("Error: Footage is empty or corrupt");
        return;
      }

      _videoController?.dispose();
      _videoController = VideoPlayerController.file(mediaFile)
        ..initialize().then((_) {
          if (clip.duration <= 0) {
            clip.duration =
                _videoController!.value.duration.inMilliseconds / 1000.0;
            clip.end = clip.duration;
          }

          _videoController!.setVolume(_isMuted ? 0.0 : _originalVolume);
          _videoController!.setPlaybackSpeed(clip.speed);

          final startTime = seekTo ?? clip.start;
          _videoController!.seekTo(
            Duration(milliseconds: (startTime * 1000).toInt()),
          );

          if (_isPlaying) _syncPlay();
          if (mounted) setState(() {});
        })
        ..addListener(() {
          if (_videoController == null ||
              !_videoController!.value.isInitialized)
            return;
          if (clip.end <= 0.1) return;

          final pos = _videoController!.value.position.inMilliseconds / 1000.0;
          if (widget.projectController == null && pos >= clip.end) {
            if (_activeClipIndex < _sequence.length - 1) {
              setState(() => _activeClipIndex++);
              _loadClip(_activeClipIndex);
            } else {
              // Loop sequence
              setState(() => _activeClipIndex = 0);
              _loadClip(_activeClipIndex);
            }
          }
          if (mounted) setState(() {});
        });
    } else {
      _videoController?.dispose();
      _videoController = null;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    widget.projectController?.playback.removeListener(
      _followSharedPlaybackClock,
    );
    _videoController?.dispose();
    _musicPlayer.dispose();
    _voicePlayer.dispose();
    _voiceoverService.dispose();
    _enhancementService.dispose();
    super.dispose();
  }

  Future<void> _followSharedPlaybackClock() async {
    final project = widget.projectController;
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
        final expected = _sequence[index].start + remaining;
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
      if (_isPlaying != state.isPlaying && mounted) {
        setState(() => _isPlaying = state.isPlaying);
      }
    } finally {
      _syncingPlayback = false;
    }
  }

  void _saveHistory() {
    final project = widget.projectController;
    if (project != null) project.history.capture(project.tracks);
  }

  void _undo() {
    final project = widget.projectController;
    if (project == null) return;
    final restored = project.history.undo(project.tracks);
    if (restored == null) return;
    HapticFeedback.lightImpact();
    project.replaceTracks(restored);
    _restoreDesktopViewFromProject();
  }

  void _redo() {
    final project = widget.projectController;
    if (project == null) return;
    final restored = project.history.redo(project.tracks);
    if (restored == null) return;
    HapticFeedback.lightImpact();
    project.replaceTracks(restored);
    _restoreDesktopViewFromProject();
  }

  void _restoreDesktopViewFromProject() {
    final project = widget.projectController;
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
            ),
          )
          .toList();
      _activeClipIndex = _sequence.isEmpty
          ? 0
          : _activeClipIndex.clamp(0, _sequence.length - 1);
      if (_sequence.isNotEmpty) _loadClip(_activeClipIndex);
    });
  }

  void _syncSharedProjectFromSequence() {
    final project = widget.projectController;
    if (project == null) return;
    project.tracks.removeWhere(
      (track) =>
          track.type == TrackType.video || track.type == TrackType.images,
    );
    for (final track in project.tracks) {
      track.clips.removeWhere(
        (clip) =>
            clip.id.startsWith('desktop-overlay-') ||
            clip.id.startsWith('desktop-transition-'),
      );
    }
    var timelineStart = Duration.zero;
    for (var index = 0; index < _sequence.length; index++) {
      final clip = _sequence[index];
      final sourceStart = Duration(milliseconds: (clip.start * 1000).round());
      final sourceEnd = Duration(milliseconds: (clip.end * 1000).round());
      final timelineDuration = Duration(
        milliseconds: (((clip.end - clip.start) / clip.speed) * 1000).round(),
      );
      TimelineModelUtils.insertClip(
        project.tracks,
        TimelineClip(
          id: 'desktop-${index}-${clip.file.path.hashCode}',
          start: timelineStart,
          duration: timelineDuration,
          file: clip.file,
          sourceStart: sourceStart,
          sourceEnd: sourceEnd,
          speed: clip.speed,
          volume: clip.volume,
          operation: TrimOperation(
            start: sourceStart,
            end: sourceEnd,
            maxDuration: Duration(milliseconds: (clip.duration * 1000).round()),
          ),
          transform: TransformOperation(
            scale: clip.scale,
            rotation: clip.rotation,
            position: Offset(clip.offsetX, clip.offsetY),
            opacity: clip.opacity,
          ),
          filter: _selectedFilter == null
              ? null
              : FilterOperation(filterName: _selectedFilter!.name),
        ),
        clip.isVideo ? TrackType.video : TrackType.images,
      );
      timelineStart += timelineDuration;
    }
    for (var index = 0; index < _overlays.length; index++) {
      final overlay = _overlays[index];
      final start = Duration(
        milliseconds: (overlay.start * _totalDuration * 1000).round(),
      );
      final end = Duration(
        milliseconds: (overlay.end * _totalDuration * 1000).round(),
      );
      TimelineModelUtils.insertClip(
        project.tracks,
        TimelineClip(
          id: 'desktop-overlay-$index',
          start: start,
          duration: end > start ? end - start : const Duration(seconds: 1),
          operation: overlay,
        ),
        TrackType.overlay,
      );
    }
    _transitions.forEach((clipIndex, transition) {
      var start = Duration.zero;
      for (
        var index = 0;
        index <= clipIndex && index < _sequence.length;
        index++
      ) {
        final clip = _sequence[index];
        start += Duration(
          milliseconds: (((clip.end - clip.start) / clip.speed) * 1000).round(),
        );
      }
      final transitionStart =
          start - Duration(milliseconds: (transition.duration * 500).round());
      TimelineModelUtils.insertClip(
        project.tracks,
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
    project.playback.updateProject(project.tracks);
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'COLOR GRADING (GPU)',
                style: syne(sz: 14, w: FontWeight.w900, ls: 2),
              ),
              const SizedBox(height: 24),
              _adjustSlider('Brightness', _brightness, -0.5, 0.5, (v) {
                setModalState(() => _brightness = v);
                setState(() {});
              }),
              _adjustSlider('Contrast', _contrast, 0.5, 1.5, (v) {
                setModalState(() => _contrast = v);
                setState(() {});
              }),
              _adjustSlider('Saturation', _saturation, 0.0, 2.0, (v) {
                setModalState(() => _saturation = v);
                setState(() {});
              }),
              _adjustSlider('Hue', _hue, -3.14, 3.14, (v) {
                setModalState(() => _hue = v);
                setState(() {});
              }),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setModalState(() {
                    _brightness = 0.0;
                    _contrast = 1.0;
                    _saturation = 1.0;
                    _hue = 0.0;
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
            Text(label, style: dm(sz: 10, c: Colors.white70)),
            Text(value.toStringAsFixed(2), style: dm(sz: 10, c: C.brand)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          activeColor: C.brand,
          inactiveColor: Colors.white10,
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
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'CHOOSE EXPORT PATH',
              style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 2),
            ),
            const SizedBox(height: 24),
            _exportOption(
              'FAST SYNC ✨',
              'Instant posting. Music is synced on-the-fly.',
              Icons.bolt,
              () {
                Navigator.pop(context);
                _finish(false);
              },
            ),
            const SizedBox(height: 12),
            _exportOption(
              'HIGH-QUALITY FLATTEN 🎬',
              'Permanent video file. Best for sharing elsewhere.',
              Icons.video_library,
              () {
                Navigator.pop(context);
                _finish(true);
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _finish(bool flatten) async {
    if (_sequence.isEmpty) return;

    File? combinedFile;
    if (flatten) {
      setState(() => _isProcessing = true);
      try {
        _feedback("Synthesizing Mult-Media Studio...");
        _syncDesktopAudioToProject();
        final project = widget.projectController;
        combinedFile = project == null
            ? null
            : await EditorExportService.renderTimeline(
                tracks: project.tracks,
                aspectRatio: _selectedAspectRatio,
              );

        if (combinedFile == null) {
          _feedback("Failed to generate master file.");
        } else {
          _feedback("Master File Ready! ✨");
        }
      } catch (e) {
        _feedback("Error combining video: $e");
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }

    Navigator.pop(context, {
      'sequence': _sequence,
      'track': _selectedTrack,
      'flatten': flatten,
      'combined_file': combinedFile,
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
      'beauty': _beautyLevel,
      'total_duration': _totalDuration,
      'clip_count': _sequence.length,
    });
  }

  void _syncDesktopAudioToProject() {
    final project = widget.projectController;
    if (project == null) return;
    for (final track in project.tracks) {
      track.clips.removeWhere((clip) => clip.id.startsWith('desktop-audio-'));
    }
    final duration = Duration(milliseconds: (_totalDuration * 1000).round());
    if (_selectedTrack != null) {
      TimelineModelUtils.insertClip(
        project.tracks,
        TimelineClip(
          id: 'desktop-audio-music',
          start: Duration(milliseconds: (_audioOffset * 1000).round()),
          duration: duration,
          volume: _bgmVolume,
          operation: AudioClipOperation(
            sourceType: 'music',
            sourceUrl: _selectedTrack!.audioUrl,
            label: _selectedTrack!.title,
            volume: _bgmVolume,
            startOffset: _audioStart,
            endOffset: _audioEnd,
          ),
        ),
        TrackType.music,
      );
    }
    if (_voiceOverFile != null) {
      TimelineModelUtils.insertClip(
        project.tracks,
        TimelineClip(
          id: 'desktop-audio-voice',
          start: Duration.zero,
          duration: duration,
          file: _voiceOverFile,
          volume: _voiceVolume,
          operation: AudioClipOperation(
            sourceType: 'voiceOver',
            label: 'Voiceover',
            volume: _voiceVolume,
          ),
        ),
        TrackType.voiceOver,
      );
    }
    project.playback.updateProject(project.tracks);
  }

  void _togglePlayback() {
    setState(() => _isPlaying = !_isPlaying);
    final project = widget.projectController;
    if (_isPlaying) {
      if (project != null) project.playback.play(project.tracks);
      _syncPlay();
    } else {
      project?.playback.pause();
      _syncPause();
    }
  }

  void _syncPlay() async {
    if (_videoController == null) return;

    // 1. Calculate global time
    final globalTime = _getGlobalTime(
      _activeClipIndex,
      (_videoController!.value.position.inMilliseconds) / 1000.0,
    );

    // 2. Start Video
    _videoController!.play();

    // 3. Start Music
    if (_selectedTrack != null) {
      double musicPos = (globalTime - _audioOffset).clamp(
        0.0,
        _audioEnd - _audioStart,
      );
      if (globalTime >= _audioOffset &&
          globalTime < (_audioOffset + (_audioEnd - _audioStart))) {
        await _musicPlayer.seek(
          Duration(milliseconds: (musicPos * 1000).toInt()),
        );
        await _musicPlayer.resume();
      } else {
        await _musicPlayer.pause();
      }
    }

    // 4. Start Voiceover
    if (_voiceOverFile != null) {
      await _voicePlayer.seek(
        Duration(milliseconds: (globalTime * 1000).toInt()),
      );
      await _voicePlayer.resume();
    }
  }

  void _syncPause() {
    _videoController?.pause();
    _musicPlayer.pause();
    _voicePlayer.pause();
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
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.brand.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(icon, color: C.brand, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: syne(sz: 13, w: FontWeight.w800, c: Colors.white),
                  ),
                  Text(sub, style: dm(sz: 10, c: Colors.white38)),
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
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.95),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'AUDIO MIXER',
                style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 2),
              ),
              const SizedBox(height: 32),
              _volSlider('Original Video', _originalVolume, (v) {
                setModalState(() => _originalVolume = v);
                setState(() => _originalVolume = v);
                _videoController?.setVolume(v);
              }),
              const SizedBox(height: 16),
              _volSlider('Background Music', _bgmVolume, (v) {
                setModalState(() => _bgmVolume = v);
                setState(() => _bgmVolume = v);
                _musicPlayer.setVolume(v);
              }),
              const SizedBox(height: 16),
              _volSlider('Voiceover', _voiceVolume, (v) {
                setModalState(() => _voiceVolume = v);
                setState(() => _voiceVolume = v);
                _voicePlayer.setVolume(v);
              }),
              const SizedBox(height: 20),
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
        Text(label, style: dm(sz: 11, c: Colors.white70)),
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
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                            : Colors.white38,
                      ),
                      Text(
                        r,
                        style: syne(
                          sz: 10,
                          c: _selectedAspectRatio == r
                              ? C.brand
                              : Colors.white38,
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
      await Future.delayed(const Duration(milliseconds: 500));
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
          style: syne(sz: 12, c: Colors.white, w: FontWeight.bold),
        ),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
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
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        _circleBtn(Icons.close, () => Navigator.pop(context)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Fullscreen Preview',
                            style: syne(
                              sz: 12,
                              w: FontWeight.w700,
                              c: Colors.white,
                            ),
                          ),
                        ),
                        const Spacer(),
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
      backgroundColor: const Color(0xFF070A10),
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
                  const SizedBox(height: 12),
                  Expanded(child: _buildStudioWorkspace()),
                  const SizedBox(height: 12),
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
      constraints: const BoxConstraints(minHeight: 74),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0E121B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.22),
            blurRadius: 24,
            offset: const Offset(0, 10),
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
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Necxa Studio',
                    style: syne(sz: 17, w: FontWeight.w900, c: Colors.white),
                  ),
                  Text(
                    'Professional layer editor',
                    style: dm(sz: 11, c: Colors.white38),
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
                  padding: const EdgeInsets.symmetric(
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
                    style: syne(sz: 12, w: FontWeight.w900, c: Colors.white),
                  ),
                ),
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [title, const Spacer(), actions]),
                const SizedBox(height: 10),
                meta,
              ],
            );
          }

          return Row(
            children: [
              title,
              const SizedBox(width: 18),
              Expanded(child: meta),
              const SizedBox(width: 12),
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
          final panelHeight = (constraints.maxHeight * 0.30)
              .clamp(180.0, 240.0)
              .toDouble();
          return Column(
            children: [
              _buildCategoryPanel(horizontal: true),
              const SizedBox(height: 12),
              Expanded(child: _buildPreviewStage()),
              const SizedBox(height: 12),
              SizedBox(
                height: panelHeight,
                child: Row(
                  children: [
                    Expanded(child: _buildAssetsPanel()),
                    const SizedBox(width: 12),
                    Expanded(child: _buildInspectorPanel()),
                  ],
                ),
              ),
            ],
          );
        }

        final assetWidth = constraints.maxWidth < 1180 ? 220.0 : 260.0;
        final inspectorWidth = constraints.maxWidth < 1180 ? 280.0 : 320.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 98, child: _buildCategoryPanel()),
            const SizedBox(width: 12),
            SizedBox(width: assetWidth, child: _buildAssetsPanel()),
            const SizedBox(width: 12),
            Expanded(child: _buildPreviewStage()),
            const SizedBox(width: 12),
            SizedBox(width: inspectorWidth, child: _buildInspectorPanel()),
          ],
        );
      },
    );
  }

  Widget _buildPreviewStage() {
    final ratio = _selectedAspectRatio == '1:1'
        ? 1.0
        : (_selectedAspectRatio == '4:5' ? 4 / 5 : 9 / 16);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF06080D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 30,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Text(
                  'Preview',
                  style: syne(sz: 12, w: FontWeight.w900, c: Colors.white70),
                ),
                const Spacer(),
                _buildTransportBar(showLabels: false),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                child: AspectRatio(
                  aspectRatio: ratio,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white.withOpacity(0.08)),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: _buildTransportBar(showLabels: true),
          ),
        ],
      ),
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
          color: const Color(0xFF0E121B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 22,
              offset: const Offset(0, -10),
            ),
          ],
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
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
                          c: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Bottom workspace for tools, quick actions, and tab navigation',
                        style: dm(sz: 10, c: Colors.white38),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                  const Spacer(),
                  _circleBtn(Icons.save_outlined, _onSaveDraft),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _onNext,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: C.blue,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: C.blue.withOpacity(0.25),
                            blurRadius: 18,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        'Export',
                        style: syne(
                          sz: 11,
                          w: FontWeight.w900,
                          c: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _buildBottomNav(),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPrimaryToolbar(),
                    const SizedBox(height: 12),
                    _buildQuickToolbar(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
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
            const CircularProgressIndicator(color: C.brand, strokeWidth: 2),
            const SizedBox(height: 20),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 12),
          const SizedBox(width: 6),
          Text(
            label,
            style: syne(sz: 10, w: FontWeight.w700, c: Colors.white70),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: C.brand, size: 14),
            const SizedBox(width: 6),
            Text(
              label,
              style: syne(sz: 10, w: FontWeight.w700, c: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssetsPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1018),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Assets',
                style: syne(sz: 12, w: FontWeight.w900, c: Colors.white),
              ),
              const Spacer(),
              Tooltip(
                message: 'Add media',
                child: GestureDetector(
                  onTap: _addClip,
                  child: const Icon(
                    Icons.add_box_outlined,
                    color: Colors.white38,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${_sequence.length} source item${_sequence.length == 1 ? '' : 's'}',
            style: dm(sz: 10, c: Colors.white.withOpacity(0.35)),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _sequence.isEmpty
                ? Center(
                    child: Text(
                      'No clips',
                      style: dm(sz: 12, c: Colors.white24),
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
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 8,
                          ),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: i == _activeClipIndex
                                ? C.brand.withOpacity(0.14)
                                : Colors.white.withOpacity(0.045),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: i == _activeClipIndex
                                  ? C.brand
                                  : Colors.white.withOpacity(0.04),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                c.isVideo ? Icons.movie : Icons.image,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  name,
                                  style: syne(
                                    sz: 11,
                                    w: FontWeight.w700,
                                    c: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${((c.duration <= 0 ? 0 : c.duration)).toStringAsFixed(1)}s',
                                style: dm(sz: 10, c: Colors.white38),
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1018),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Inspector',
              style: syne(sz: 12, w: FontWeight.w900, c: Colors.white),
            ),
            const SizedBox(height: 12),
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
            const SizedBox(height: 14),
            _inspectorSectionTitle('Playback Controls'),
            const SizedBox(height: 8),
            _buildTransportBar(showLabels: true),
            const SizedBox(height: 14),
            _inspectorSectionTitle('Asset Tracks'),
            _trackControlRow(
              icon: Icons.movie_outlined,
              label: 'Video',
              sub:
                  '${_sequence.length} clip${_sequence.length == 1 ? '' : 's'}',
              color: const Color(0xFF60A5FA),
              visible: _videoTrackVisible,
              locked: _videoTrackLocked,
              onVisibility: () =>
                  setState(() => _videoTrackVisible = !_videoTrackVisible),
              onLock: () =>
                  setState(() => _videoTrackLocked = !_videoTrackLocked),
            ),
            _trackControlRow(
              icon: Icons.music_note,
              label: 'Music',
              sub: _selectedTrack?.title ?? 'No track selected',
              color: const Color(0xFFA78BFA),
              visible: _musicTrackVisible,
              locked: _musicTrackLocked,
              onVisibility: () =>
                  setState(() => _musicTrackVisible = !_musicTrackVisible),
              onLock: () =>
                  setState(() => _musicTrackLocked = !_musicTrackLocked),
            ),
            _trackControlRow(
              icon: Icons.mic,
              label: 'Voice',
              sub: _voiceOverFile == null ? 'No voiceover' : 'Voiceover ready',
              color: const Color(0xFF34D399),
              visible: _voiceTrackVisible,
              locked: _voiceTrackLocked,
              onVisibility: () =>
                  setState(() => _voiceTrackVisible = !_voiceTrackVisible),
              onLock: () =>
                  setState(() => _voiceTrackLocked = !_voiceTrackLocked),
            ),
            _trackControlRow(
              icon: Icons.text_fields,
              label: 'Text',
              sub:
                  '${_overlays.length} overlay${_overlays.length == 1 ? '' : 's'}',
              color: const Color(0xFF38BDF8),
              visible: _textTrackVisible,
              locked: _textTrackLocked,
              onVisibility: () =>
                  setState(() => _textTrackVisible = !_textTrackVisible),
              onLock: () =>
                  setState(() => _textTrackLocked = !_textTrackLocked),
            ),
            const SizedBox(height: 12),
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
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0D14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        children: items
            .map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
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
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: syne(sz: 10, w: FontWeight.w700, c: Colors.white),
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
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: syne(sz: 10, w: FontWeight.w900, c: Colors.white38, ls: 1.1),
      ),
    );
  }

  Widget _projectInfoRow(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, color: C.brand, size: 15),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: dm(sz: 11, c: Colors.white.withOpacity(0.45)),
            ),
          ),
          Text(
            value,
            style: syne(sz: 11, w: FontWeight.w800, c: Colors.white),
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
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: syne(sz: 11, w: FontWeight.w900, c: Colors.white),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: dm(sz: 9, c: Colors.white.withOpacity(0.35)),
                ),
              ],
            ),
          ),
          IconButton(
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            onPressed: onVisibility,
            icon: Icon(
              visible
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: visible ? color : Colors.white24,
              size: 16,
            ),
          ),
          IconButton(
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            onPressed: onLock,
            icon: Icon(
              locked ? Icons.lock_outlined : Icons.lock_open_outlined,
              color: locked ? color : Colors.white24,
              size: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryToolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(
                  'Core tools',
                  style: syne(
                    sz: 10,
                    w: FontWeight.w800,
                    c: Colors.white38,
                    ls: 1.2,
                  ),
                ),
                const Spacer(),
                Text(
                  'Organized by workflow',
                  style: syne(sz: 9, w: FontWeight.w600, c: Colors.white24),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
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
                    'Beauty',
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
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.fromLTRB(8, 7, 2, 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.035),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              title,
              style: syne(sz: 9, w: FontWeight.w800, c: Colors.white30),
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
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: syne(sz: 9, w: FontWeight.bold, c: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickToolbar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'Quick actions',
              style: syne(
                sz: 10,
                w: FontWeight.w800,
                c: Colors.white38,
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
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 15),
            const SizedBox(width: 6),
            Text(
              label,
              style: syne(sz: 8, w: FontWeight.bold, c: Colors.white38),
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
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1018),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
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
                        color: active ? C.brand : Colors.white24,
                        size: 20,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tabs[i]['label'] as String,
                        textAlign: TextAlign.center,
                        style: syne(
                          sz: 10,
                          w: FontWeight.w700,
                          c: active ? Colors.white : Colors.white38,
                        ),
                      ),
                      const SizedBox(height: 6),
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
          const SizedBox(height: 12),
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
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white70, size: 16),
              const SizedBox(width: 8),
              Text(
                label,
                style: syne(sz: 10, w: FontWeight.bold, c: Colors.white70),
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
          color: Colors.white.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, color: Colors.white, size: 16),
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
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(height: 4),
          Text(
            label,
            style: syne(sz: 9, w: FontWeight.bold, c: Colors.white),
          ),
        ],
      ),
    );
  }

  void _handleSplit() {
    _saveHistory();
    final currentPos = _videoController!.value.position.inMilliseconds / 1000.0;
    final activeClip = _sequence[_activeClipIndex];

    // Safety check: ensure split isn't at the very start or end
    if (currentPos <= 0.5 || currentPos >= (activeClip.duration - 0.5)) {
      _feedback("Too close to edge to split");
      return;
    }

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
      _feedback("Clip Split! ✂️");
    });
    _syncSharedProjectFromSequence();
  }

  void _handleDeleteClip() {
    _saveHistory();
    setState(() {
      _sequence.removeAt(_activeClipIndex);
      if (_activeClipIndex >= _sequence.length)
        _activeClipIndex = _sequence.length - 1;
      if (_sequence.isNotEmpty) _loadClip(_activeClipIndex);
    });
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
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.94),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'FADE STYLE',
              style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 2),
            ),
            const SizedBox(height: 16),
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
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: selected ? C.brand : Colors.white10,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? C.brand : Colors.white12,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          option,
                          style: syne(
                            sz: 11,
                            w: FontWeight.w900,
                            c: selected ? Colors.black : Colors.white70,
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
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.94),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'STICKERS',
              style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 2),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: stickers
                  .map(
                    (sticker) => GestureDetector(
                      onTap: () {
                        setState(
                          () => _overlays.add(
                            OverlayOperation.fromLegacy({
                              'type': 'sticker',
                              'text': sticker,
                              'start': 0.0,
                              'end': 1.0,
                              'color': sticker.length > 1
                                  ? Colors.black
                                  : Colors.white,
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
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Center(
                          child: Text(
                            sticker,
                            style: syne(
                              sz: sticker.length > 1 ? 14 : 24,
                              w: FontWeight.w900,
                              c: Colors.white,
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
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('TRIM CLIP', style: syne(sz: 14, w: FontWeight.w900, ls: 2)),
              const SizedBox(height: 32),
              RangeSlider(
                values: RangeValues(clip.start, clip.end),
                min: 0,
                max: clip.duration,
                activeColor: C.brand,
                inactiveColor: Colors.white10,
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
                    style: dm(sz: 10, c: Colors.white54),
                  ),
                  Text(
                    'End: ${clip.end.toStringAsFixed(1)}s',
                    style: dm(sz: 10, c: Colors.white54),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: C.brand,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(16),
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
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: C.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'PLAYBACK SPEED',
              style: syne(sz: 14, w: FontWeight.w900, ls: 2),
            ),
            const SizedBox(height: 24),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: clip.speed == s
                              ? C.brand
                              : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${s}x',
                          style: syne(
                            sz: 14,
                            w: FontWeight.bold,
                            c: clip.speed == s ? Colors.black : Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 24),
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
    setState(() {
      _audioStart = 0.0;
      _audioEnd = totalVideoDuration.clamp(1.0, 60.0);
    });
    _feedback("Audio Synced to ${totalVideoDuration.toStringAsFixed(1)}s");
  }

  void _showSoundPicker() async {
    _videoController?.pause();
    await _musicPlayer.stop();

    if (!mounted) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const MusicLibraryScreen()),
    );

    if (result is MusicTrack) {
      setState(() {
        _selectedTrack = result;
      });

      _syncAudioToVideo();

      _musicPlayer.setReleaseMode(ReleaseMode.loop);
      await _musicPlayer.play(UrlSource(result.audioUrl));
      _videoController?.play();
      _feedback("Sound synced: ${result.title}");
    } else {
      _videoController?.play();
    }
  }

  void _showTransformEditor() {
    if (_sequence.isEmpty) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          final clip = _sequence[_activeClipIndex];
          return Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.94),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'TRANSFORM CLIP',
                  style: syne(
                    sz: 14,
                    w: FontWeight.w900,
                    c: Colors.white,
                    ls: 2,
                  ),
                ),
                const SizedBox(height: 18),
                _adjustSlider('Scale', clip.scale, 0.5, 2.4, (v) {
                  setModalState(() => clip.scale = v);
                  setState(() {});
                }),
                _adjustSlider('Rotation', clip.rotation, -0.8, 0.8, (v) {
                  setModalState(() => clip.rotation = v);
                  setState(() {});
                }),
                _adjustSlider('Position X', clip.offsetX, -160, 160, (v) {
                  setModalState(() => clip.offsetX = v);
                  setState(() {});
                }),
                _adjustSlider('Position Y', clip.offsetY, -220, 220, (v) {
                  setModalState(() => clip.offsetY = v);
                  setState(() {});
                }),
                _adjustSlider('Opacity', clip.opacity, 0.05, 1.0, (v) {
                  setModalState(() => clip.opacity = v);
                  setState(() {});
                }),
                const SizedBox(height: 10),
                _actionRow(Icons.restart_alt, 'Reset Transform', () {
                  setModalState(() {
                    clip.scale = 1.0;
                    clip.rotation = 0.0;
                    clip.offsetX = 0.0;
                    clip.offsetY = 0.0;
                    clip.opacity = 1.0;
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.94),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'EFFECTS EDITOR',
                style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 2),
              ),
              const SizedBox(height: 18),
              _adjustSlider('Vignette', _effectVignette, 0.0, 1.0, (v) {
                setModalState(() => _effectVignette = v);
                setState(() {});
              }),
              _adjustSlider('Film grain', _effectGrain, 0.0, 1.0, (v) {
                setModalState(() => _effectGrain = v);
                setState(() {});
              }),
              _adjustSlider('Soft blur', _effectBlur, 0.0, 8.0, (v) {
                setModalState(() => _effectBlur = v);
                setState(() {});
              }),
              const SizedBox(height: 10),
              _actionRow(Icons.restart_alt, 'Reset Effects', () {
                setModalState(() {
                  _effectVignette = 0.0;
                  _effectGrain = 0.0;
                  _effectBlur = 0.0;
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
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          height: 174,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.92),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                child: Text(
                  'FILTER PRESETS',
                  style: syne(
                    sz: 12,
                    w: FontWeight.w900,
                    c: Colors.white,
                    ls: 2,
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(16),
                  children: ImageFilter.values
                      .map(
                        (f) => GestureDetector(
                          onTap: () {
                            setModalState(() => _applyFilterPreset(f));
                            setState(() {});
                          },
                          child: Container(
                            width: 92,
                            margin: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              color: _selectedFilter == f
                                  ? C.brand
                                  : Colors.white10,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _selectedFilter == f
                                    ? C.brand
                                    : Colors.white24,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.filter,
                                  color: _selectedFilter == f
                                      ? Colors.black
                                      : Colors.white,
                                  size: 20,
                                ),
                                const SizedBox(height: 7),
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
                                        : Colors.white,
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
            const CircularProgressIndicator(color: C.brand),
            const SizedBox(height: 16),
            Text(
              "Applying Beauty Filter (FFmpeg)...",
              style: syne(sz: 14, w: FontWeight.bold, c: Colors.white),
            ),
          ],
        ),
      ),
    );

    try {
      final enhancedFile = await _videoService.enhanceVideo(
        inputVideo: clip.file,
        options: const VideoEnhancementOptions(applyBeautyFilter: true),
      );

      if (mounted) {
        setState(() {
          _saveHistory();
          _sequence[_activeClipIndex] = VideoClip(
            file: enhancedFile,
            start: clip.start,
            end: clip.end,
            duration: clip.duration,
            speed: clip.speed,
            volume: clip.volume,
          );
        });
        _feedback("Beauty Filter Applied! ✨");
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
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        height: 220,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          children: [
            Text(
              'FACE BEAUTY (POST-PROCESS)',
              style: syne(sz: 14, w: FontWeight.w900, c: Colors.white, ls: 2),
            ),
            const SizedBox(height: 12),
            Text(
              'Uses our custom FFmpeg min-gpl engine to apply skin smoothing (smartblur) and color equalization.',
              style: dm(sz: 12, c: Colors.white54),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_awesome, color: Colors.black),
              label: Text(
                "Apply Beauty Filter",
                style: syne(sz: 14, w: FontWeight.bold, c: Colors.black),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: C.brand,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              onPressed: () => _applyBeautyFilterToClip(),
            ),
          ],
        ),
      ),
    );
  }

  // ── CORE UI UTILITIES ───────────────────────────────────────
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
            brightness: _brightness,
            contrast: _contrast,
            saturation: _saturation,
            hue: _hue,
          ),
          child: player,
        );
      }

      if (_effectBlur > 0) {
        player = ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: _effectBlur,
            sigmaY: _effectBlur,
          ),
          child: player,
        );
      }

      return Stack(
        fit: StackFit.expand,
        children: [
          player,
          if (_effectVignette > 0)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.72 * _effectVignette),
                    ],
                    stops: const [0.55, 1.0],
                  ),
                ),
              ),
            ),
          if (_effectGrain > 0)
            IgnorePointer(
              child: CustomPaint(
                painter: GrainPainter(intensity: _effectGrain),
              ),
            ),
        ],
      );
    }
    return const Center(child: CircularProgressIndicator(color: C.brand));
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
          return Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final x = o.position.dx * constraints.maxWidth;
                final y = o.position.dy * constraints.maxHeight;

                Widget child;
                if (o.kind == 'sticker') {
                  child = Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: o.background.withOpacity(o.backgroundOpacity),
                      borderRadius: BorderRadius.circular(8),
                      border: o.stroke
                          ? Border.all(color: Colors.white, width: 2)
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
                  child = Text(
                    o.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: o.fontSize,
                      color: o.color.withOpacity(o.opacity),
                      fontWeight: FontWeight.bold,
                      shadows: o.shadow
                          ? [const Shadow(blurRadius: 8, color: Colors.black54)]
                          : null,
                    ),
                  );
                }

                return Positioned(
                  left: x,
                  top: y,
                  child: Transform.translate(
                    offset: const Offset(-150, -50), // Center approximation
                    child: Transform.rotate(
                      angle: o.rotation,
                      child: Transform.scale(
                        scale: o.scale,
                        child: SizedBox(
                          width: 300,
                          height: 100,
                          child: Center(child: child),
                        ),
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

  void _showTextOverlaySheet() {
    setState(() {
      _saveHistory();
      _overlays.add(
        OverlayOperation.fromLegacy({
          'type': 'text',
          'text': 'Enter Text',
          'start': 0.0,
          'end': 1.0,
          'x': 0.5,
          'y': 0.5,
          'scale': 1.0,
          'rotation': 0.0,
          'opacity': 1.0,
          'fontSize': 28.0,
          'color': Colors.white,
          'background': Colors.black,
          'backgroundOpacity': 0.0,
          'shadow': true,
        }),
      );
      _syncSharedProjectFromSequence();
    });
    _feedback("Text overlay added");
  }

  void _showFrameOverlayPicker() {
    _feedback("Frame picker not implemented yet.");
  }

  void _toggleVoiceOver() async {
    if (_isRecordingVoice) {
      // Stop recording
      final recording = await _voiceoverService.stop();
      if (recording != null) {
        setState(() {
          _voiceOverFile = recording.file;
          _isRecordingVoice = false;
        });
        _feedback("Voiceover recorded!");
      }
    } else {
      // Start recording
      if (await _voiceoverService.start()) {
        setState(() => _isRecordingVoice = true);
        _feedback("Recording voice... 🎤");
      } else {
        _feedback("Microphone permission denied.");
      }
    }
  }

  void _showCaptionSheet() {
    _feedback("Auto-captioning not implemented yet.");
  }

  void _showTransitionSheet() {
    if (_transitionsUnlocked) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF1A1D23),
        builder: (sheetContext) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose Transition',
                    style: syne(sz: 15, w: FontWeight.w800, c: Colors.white),
                  ),
                  const SizedBox(height: 10),
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.12),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                preset.icon,
                                style: const TextStyle(fontSize: 18),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                preset.name,
                                style: dm(
                                  sz: 12,
                                  w: FontWeight.w600,
                                  c: Colors.white,
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
        backgroundColor: const Color(0xFF1A1D23),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Unlock Pro Feature',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Unlock Pro Transitions for all your projects for just 50 NCX.',
          style: dm(c: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Maybe Later'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: C.brand),
            onPressed: () async {
              Navigator.pop(dialogContext);
              setState(() => _isProcessing = true);
              try {
                final unlockFunction = FirebaseFunctions.instanceFor(
                  region: 'us-central1',
                ).httpsCallable('unlockFeature');
                final result = await unlockFunction.call({
                  'featureId': 'pro_transitions',
                  'ncxCost': 50,
                });
                if (result.data['success'] == true) {
                  setState(() => _transitionsUnlocked = true);
                  _feedback('Pro Transitions Unlocked! 🚀');
                  _showTransitionSheet();
                }
              } on FirebaseFunctionsException catch (e) {
                _feedback(
                  "Error: ${e.message ?? 'Could not complete purchase.'}",
                );
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: c ?? Colors.white70, size: 16),
            const SizedBox(width: 8),
            Text(
              label,
              style: syne(sz: 10, w: FontWeight.bold, c: c ?? Colors.white70),
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

  const MaskingPreview({
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
                    color: Colors.white,
                    size: 14,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isMasked ? 'Masked' : 'Visible',
                    style: dm(sz: 10, c: Colors.white),
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
    final paint = Paint()..color = Colors.white.withOpacity(0.12 * intensity);
    for (int i = 0; i < 1500 * intensity; i++) {
      final x = _rand.nextDouble() * size.width;
      final y = _rand.nextDouble() * size.height;
      canvas.drawCircle(Offset(x, y), _rand.nextDouble() * 0.8, paint);
    }
  }

  @override
  bool shouldRepaint(covariant GrainPainter oldDelegate) => false;
}
