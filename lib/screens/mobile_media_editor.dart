import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
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

  // Clip interaction state
  String? _activeDragClipId;
  _ClipDragMode _clipDragMode = _ClipDragMode.none;
  double? _dragStartLocalX;
  Duration? _dragOriginalStart;
  Duration? _dragOriginalDuration;
  double _clipHandleWidth = 12.0; // hit area for handles in pixels
  bool _isRippleMode = false; // when true, edits ripple following clips
  bool _isStretchMode = false; // when true, resize changes speed (stretch)

  // Timeline pinch/zoom helpers
  double? _timelineScaleStartZoom;
  double _leftPaneWidth = 56.0; // width of left pane used to compute local focal point

  // Helpers for clip dragging
  void _shiftFollowingClips(TimelineTrack track, TimelineClip clip, Duration delta) {
    // shift any clips that start after this clip's end by delta
    final end = clip.start + clip.duration;
    for (final c in track.clips) {
      if (c.start >= end && c.id != clip.id) {
        c.start = c.start + delta;
      }
    }
  }

  // Duration clamp helper since Duration doesn't expose clamp()
  Duration _clampDuration(Duration value, Duration min, Duration max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  void _onClipPanStart(TimelineTrack track, TimelineClip clip, DragStartDetails details, double width) {
    _activeDragClipId = clip.id;
    _dragStartLocalX = details.localPosition.dx;
    _dragOriginalStart = clip.start;
    _dragOriginalDuration = clip.duration;

    if (_dragStartLocalX != null) {
      if (_dragStartLocalX! < _clipHandleWidth) {
        _clipDragMode = _ClipDragMode.resizeLeft;
      } else if (_dragStartLocalX! > width - _clipHandleWidth) {
        _clipDragMode = _isStretchMode ? _ClipDragMode.stretch : _ClipDragMode.resizeRight;
      } else {
        _clipDragMode = _ClipDragMode.move;
      }
    }

    // Capture timeline for undo
    _captureTimeline();
  }

  void _onClipPanUpdate(TimelineTrack track, TimelineClip clip, DragUpdateDetails details) {
    if (_activeDragClipId != clip.id) return;
    final scale = _pixelsPerSecond * _timelineZoom;
    final dx = details.delta.dx;
    final deltaMs = (dx / scale * 1000.0).round();
    final delta = Duration(milliseconds: deltaMs);

    setState(() {
      switch (_clipDragMode) {
        case _ClipDragMode.move:
          final newStart = (_dragOriginalStart ?? clip.start) + delta;
          clip.start = newStart >= Duration.zero ? newStart : Duration.zero;
          if (_isRippleMode) {
            // ripple: shift following clips by same delta
            _shiftFollowingClips(track, clip, delta);
          }
          break;
        case _ClipDragMode.resizeLeft:
          final origStart = _dragOriginalStart ?? clip.start;
          final origDur = _dragOriginalDuration ?? clip.duration;
          final newStart = origStart + delta;
          final newDur = origDur - delta;
          if (newDur >= const Duration(milliseconds: 100)) {
            // Advanced trim: update TrimOperation if available to restore/hide source
            if (clip.operation is TrimOperation) {
              final trim = clip.operation as TrimOperation;
              final newSourceStart = _clampDuration(trim.start + delta, Duration.zero, trim.end);
              trim.start = newSourceStart;
              clip.sourceStart = trim.start;
              final available = (trim.end - trim.start);
              clip.duration = Duration(milliseconds: (available.inMilliseconds / clip.speed).round());
            } else {
              clip.start = newStart >= Duration.zero ? newStart : Duration.zero;
              clip.duration = newDur;
            }

            // hide semantics: if duration becomes very small, mark hidden
            clip.isHidden = clip.duration <= const Duration(milliseconds: 150);

            if (_isRippleMode) {
              // maintain following clips' positions by shifting them
              _shiftFollowingClips(track, clip, delta);
            }
          }
          break;
        case _ClipDragMode.resizeRight:
          final origDur = _dragOriginalDuration ?? clip.duration;
          final newDur = origDur + delta;
          if (newDur >= const Duration(milliseconds: 100)) {
            if (clip.operation is TrimOperation) {
              final trim = clip.operation as TrimOperation;
              final newEnd = _clampDuration(trim.end + delta, trim.start + const Duration(milliseconds: 1), Duration(days: 36500));
              trim.end = newEnd;
              clip.sourceEnd = trim.end;
              final available = (trim.end - trim.start);
              clip.duration = Duration(milliseconds: (available.inMilliseconds / clip.speed).round());
            } else {
              clip.duration = newDur;
            }

            clip.isHidden = clip.duration <= const Duration(milliseconds: 150);

            if (_isRippleMode) {
              _shiftFollowingClips(track, clip, delta);
            }
          }
          break;
        case _ClipDragMode.stretch:
          final origDur = _dragOriginalDuration ?? clip.duration;
          final newDur = origDur + delta;
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
              trim.end = trim.start + Duration(milliseconds: (clip.sourceDuration.inMilliseconds));
            }
            clip.isHidden = clip.duration <= const Duration(milliseconds: 150);
            if (_isRippleMode) {
              _shiftFollowingClips(track, clip, delta);
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
    _activeDragClipId = null;
    _clipDragMode = _ClipDragMode.none;
    _dragStartLocalX = null;
    _dragOriginalStart = null;
    _dragOriginalDuration = null;
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
    _bottomNavController = TabController(length: 5, vsync: this);

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
  }

  Future<void> _loadProState() async {
    final isPro = await EditorSubscriptionService.isProEnabled();
    if (!mounted) return;
    setState(() => _isProEnabled = isPro);
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
      final duration = isVideo
          ? const Duration(seconds: 12)
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

    final controller = VideoPlayerController.file(clip.file!);
    _videoController = controller;
    try {
      await controller.initialize();
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
      if (mounted) setState(() => _isVideoReady = true);
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
          Image.file(compositionClip.file!, fit: BoxFit.cover),
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
      final cropRatio = _cropRatioFor(
        compositionClip?.cropAspectRatio ?? 'Original',
      );
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
          Center(child: video),
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
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _formatDuration(_currentTime),
            style: dm(sz: 12, w: FontWeight.w600, c: C.brand),
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
              // Expand belongs directly after the forward control.
              _buildPlaybackButton(
                Icons.fullscreen_outlined,
                () => setState(() => _showFullscreenPreview = true),
              ),
            ],
          ),
          Text(_formatDuration(_totalDuration), style: dm(sz: 12, c: C.dim)),
        ],
      ),
    );
  }

  Widget _buildPlaybackButton(
    IconData icon,
    VoidCallback onTap, {
    bool isLarge = false,
  }) {
    return Container(
      width: isLarge ? 48 : 40,
      height: isLarge ? 48 : 40,
      decoration: BoxDecoration(
        color: isLarge ? C.brand : C.surface,
        borderRadius: BorderRadius.circular(isLarge ? 24 : 8),
        border: Border.all(color: C.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(isLarge ? 24 : 8),
          child: Icon(
            icon,
            size: isLarge ? 24 : 20,
            color: isLarge ? Colors.white : C.brand,
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
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              children: [
                Text(
                  'Timeline',
                  style: syne(sz: 12, w: FontWeight.w800, c: C.text),
                ),
                const Spacer(),
                Material(
                  color: C.brand.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: _showTimelineInsertMenu,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.add, size: 14, color: Colors.white),
                          const SizedBox(width: 4),
                          Text(
                            'Add',
                            style: dm(sz: 9, c: C.brand, w: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: C.brand.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${visibleTracks.length} Tracks',
                    style: dm(sz: 9, c: C.brand, w: FontWeight.w700),
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
                    width: 56,
                    decoration: BoxDecoration(
                      color: C.surface,
                      border: Border(right: BorderSide(color: C.border)),
                    ),
                    child: ListView.builder(
                      controller: _sidebarScrollController,
                      padding: const EdgeInsets.only(
                        top: 28,
                        bottom: 8,
                      ), // 28 is ruler height
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
                            height: 72,
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? C.brand.withOpacity(0.1)
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
                                Text(
                                  _getTrackIcon(track.type),
                                  style: const TextStyle(fontSize: 18),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _buildTrackButton(
                                      Icons.visibility,
                                      () => _toggleTrackVisibility(track),
                                      size: 12,
                                    ),
                                    _buildTrackButton(
                                      Icons.lock,
                                      () => _toggleTrackLock(track),
                                      size: 12,
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
    const rulerHeight = 28.0;
    final scale = _pixelsPerSecond * _timelineZoom;

    return SizedBox(
      height: rulerHeight,
      width: timelineWidth,
      child: Stack(
        children: List.generate((_totalDuration.inSeconds).ceil() + 1, (i) {
          final x = i * scale;
          final isMajor = i % 5 == 0;
          return Positioned(
            left: x,
            top: isMajor ? 8 : 16,
            child: Column(
              children: [
                Container(
                  width: 1,
                  height: isMajor ? 6 : 4,
                  color: C.dim.withAlpha(128),
                ),
                if (isMajor)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('${i}s', style: dm(sz: 7, c: C.dim)),
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildGlobalPlayhead(double timelineWidth) {
    final scale = _pixelsPerSecond * _timelineZoom;
    final playheadOffset = (_currentTime.inMilliseconds / 1000.0) * scale;

    return Positioned(
      left: playheadOffset,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          width: 2,
          color: C.brand,
          child: Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: C.brand,
                  shape: BoxShape.circle,
                ),
                transform: Matrix4.translationValues(-4, 0, 0),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrackClips(TimelineTrack track) {
    final scale = _pixelsPerSecond * _timelineZoom;

    return Container(
      height: 72,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(color: C.surface.withAlpha(128)),
      child: Stack(
        children: track.clips.map((clip) {
          final left = (clip.start.inMilliseconds / 1000.0) * scale;
          final width = (clip.duration.inMilliseconds / 1000.0) * scale;
          final isSelected = _selectedClipIds.contains(clip.id);

          return Positioned(
            left: left,
            top: 4,
            bottom: 4,
            width: width,
            child: GestureDetector(
              onTap: () => _selectClip(track, clip),
              onDoubleTap: () => _trimClip(),
              onLongPress: () => _enterMultiSelect(track, clip),
              onPanStart: (details) => _onClipPanStart(track, clip, details, width),
              onPanUpdate: (details) => _onClipPanUpdate(track, clip, details),
              onPanEnd: (details) => _onClipPanEnd(details),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildClipContent(track, clip, width, isSelected),
                  if (isSelected) ...[
                    // left handle
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
                              width: 6,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // right handle
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
                              width: 6,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // center drag hint
                    Positioned(
                      left: width / 2 - 10,
                      top: 0,
                      bottom: 0,
                      width: 20,
                      child: Center(
                        child: Container(
                          width: 2,
                          height: 28,
                          color: Colors.white12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildClipContent(
    TimelineTrack track,
    TimelineClip clip,
    double width,
    bool isSelected,
  ) {
    final baseColor = _trackColorForType(track.type);

    Widget content;
    if (track.type == TrackType.video) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          _VideoClipThumbnails(
            clip: clip,
            width: width,
            pixelsPerSecond: _pixelsPerSecond * _timelineZoom,
          ),
          Container(color: Colors.black.withOpacity(0.3)),
          Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clip.file?.path.split('/').last ?? 'Video',
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
    } else if (track.type == TrackType.audio ||
        track.type == TrackType.voiceOver ||
        track.type == TrackType.music) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _WaveformPainter(
              color: Colors.white.withOpacity(0.5),
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

    return Container(
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isSelected ? C.brand : Colors.transparent,
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }

  Color _trackColorForType(TrackType type) {
    switch (type) {
      case TrackType.video:
        return const Color(0xFF4F46E5);
      case TrackType.audio:
        return const Color(0xFF0891B2);
      case TrackType.text:
        return const Color(0xFFF59E0B);
      case TrackType.images:
        return const Color(0xFF14B8A6);
      case TrackType.captions:
        return const Color(0xFF06B6D4);
      case TrackType.overlay:
        return const Color(0xFFF472B6);
      case TrackType.effects:
        return const Color(0xFFEC4899);
      case TrackType.music:
        return const Color(0xFF8B5CF6);
      case TrackType.voiceOver:
        return const Color(0xFF22C55E);
      case TrackType.soundEffects:
        return const Color(0xFFF59E0B);
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
      height: 64,
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
          _buildToolButton('Media', () => _pickMediaFromLibrary()),
          _buildToolButton('Trim', () => _trimClip()),
          _buildToolButton('Crop', _cropClip),
          _buildToolButton('Speed', () => _adjustSpeed()),
          _buildToolButton('Volume', _adjustVolume),
          _buildToolButton('Reverse', _toggleReverse),
        ];
      case 2:
        return [
          _buildToolButton('Music', () => _showAudioPicker()),
          _buildToolButton('Voice', _showVoiceoverRecorder),
          _buildToolButton('SFX', () => _addSoundEffect()),
          _buildToolButton('Volume', () => _adjustVolume()),
        ];
      case 3:
        return [
          _buildToolButton('Text Hub', () => _showTextHubSheet()),
          _buildToolButton('Edit', () => _showTextEditorSheet()),
          _buildToolButton('Font', () => _showTextEditorSheet()),
          _buildToolButton('Color', () => _showTextEditorSheet()),
        ];
      case 4:
        return [
          _buildToolButton('Library', () => _toggleEffectLibrary()),
          _buildToolButton('Intensity', () => _showEffectEditorSheet()),
          _buildToolButton('Apply', () => _applySelectedEffect()),
        ];
      default:
        return [
          _buildToolButton('Split', () => _splitClip()),
          _buildToolButton('Trim', () => _trimClip()),
          _buildToolButton('Lock', () => _showSnack('Track locked')),
          _buildToolButton('Hide', () => _showSnack('Track hidden')),
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
          _buildToolButton('Split', () => _splitClip()),
          _buildToolButton('Trim', () => _trimClip()),
          _buildToolButton('Crop', () => _showSnack('Crop frame')),
          _buildToolButton('Speed', () => _adjustSpeed()),
          _buildToolButton('Opacity', () => _adjustOpacity()),
          _buildToolButton('Delete', () => _deleteClip()),
        ]);
      } else if (selectedTrack.type == TrackType.text ||
          selectedTrack.type == TrackType.captions) {
        tools.addAll([
          _buildToolButton('Edit', () => _showTextEditorSheet()),
          _buildToolButton('Font', () => _showTextEditorSheet()),
          _buildToolButton('Size', () => _showTextEditorSheet()),
          _buildToolButton('Color', () => _showTextEditorSheet()),
          _buildToolButton('Delete', () => _deleteClip()),
        ]);
      } else if (selectedTrack.type == TrackType.audio ||
          selectedTrack.type == TrackType.music ||
          selectedTrack.type == TrackType.voiceOver ||
          selectedTrack.type == TrackType.soundEffects) {
        tools.addAll([
          _buildToolButton('Split', _splitClip),
          _buildToolButton('Trim', _trimClip),
          _buildToolButton('Speed', _adjustSpeed),
          _buildToolButton('Volume', () => _adjustVolume()),
          _buildToolButton('Reverse', _toggleReverse),
          _buildToolButton('Fade', () => _addFade()),
          _buildToolButton('Delete', () => _deleteClip()),
        ]);
      } else if (selectedTrack.type == TrackType.effects) {
        tools.addAll([
          _buildToolButton('Intensity', () => _showEffectEditorSheet()),
          _buildToolButton('Opacity', () => _showEffectEditorSheet()),
          _buildToolButton('Blend', () => _showEffectEditorSheet()),
          _buildToolButton('Delete', () => _deleteClip()),
        ]);
      } else {
        tools.addAll([
          _buildToolButton('Resize', () => _showSnack('Resize clip')),
          _buildToolButton('Opacity', () => _adjustOpacity()),
          _buildToolButton('Delete', () => _deleteClip()),
        ]);
      }
    }

    return tools;
  }

  Widget _buildToolButton(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: C.surface,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              label,
              style: dm(sz: 10, c: C.brand, w: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
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
                  (_) => _showTransitionLibrarySheet(),
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

  void _showAspectRatioMenu() {
    _showSelectionSheet('Aspect ratio', [
      '9:16',
      '16:9',
      '1:1',
      '4:5',
    ], (value) => setState(() => _selectedAspectRatio = value));
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
          () => _insertTextLayer('✨'),
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
      _playback.pause();
    } else {
      // A library preview is intentionally separate from composition audio.
      // Stop it before starting the shared timeline transport.
      await _stopAudioPreview();
      if (!mounted) return;
      _playback.play(_tracks);
    }
  }

  void _onPlaybackStateChanged() {
    if (!mounted) return;
    final state = _playback.state;
    setState(() {
      _currentTime = state.currentTime;
      _totalDuration = state.duration;
      _isPlaying = state.isPlaying;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureTimelinePosition());
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
      if (state.isPlaying && !visual.isReversed) {
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
      if (_timelineAudioVolumes[clip.id] != clip.volume) {
        await player.setVolume(clip.volume);
        _timelineAudioVolumes[clip.id] = clip.volume;
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
        if (state.isPlaying) {
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
      if (state.isPlaying && player.state != PlayerState.playing) {
        await player.resume();
      } else if (!state.isPlaying && player.state == PlayerState.playing) {
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
    const margin = 80.0;
    final visibleStart = offset + margin;
    final visibleEnd = offset + viewport - margin;

    if (playheadPosition < visibleStart || playheadPosition > visibleEnd) {
      final target = math.min(
        math.max(playheadPosition - viewport / 2, 0.0),
        _timelineScrollController.position.maxScrollExtent,
      );
      _timelineScrollController.jumpTo(target);
    }
  }

  void _previousFrame() {
    _playback.stepBackward(_tracks);
  }

  void _nextFrame() {
    _playback.stepForward(_tracks);
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
    final clip = _selectedClip;
    if (clip == null) return;
    _captureTimeline();
    _showClipSlider(
      title: 'Playback speed',
      value: clip.speed,
      min: 0.25,
      max: 4.0,
      divisions: 15,
      label: (value) => '${value.toStringAsFixed(2)}x',
      onChanged: (value) {
        final sourceDuration = clip.sourceDuration;
        setState(() {
          clip.speed = value;
          clip.duration = Duration(
            milliseconds: (sourceDuration.inMilliseconds / value).round(),
          );
          if (clip.operation is AudioClipOperation) {
            (clip.operation as AudioClipOperation).speed = value;
          }
        });
        _playback.updateProject(_tracks);
        _videoController?.setPlaybackSpeed(value);
        _audioPreviewPlayer.setPlaybackRate(value);
      },
    );
  }

  void _cropClip() {
    final clip = _selectedClip;
    if (clip == null) return;
    _captureTimeline();
    _showSelectionSheet('Crop', ['Original', '9:16', '16:9', '1:1', '4:5'], (
      value,
    ) {
      setState(() => clip.cropAspectRatio = value);
    });
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
    if (clip.file != null) {
      if (clip.isReversed) {
        _videoController?.seekTo(
          clip.sourceEnd ?? clip.sourceStart + clip.sourceDuration,
        );
        _startReversePlayback();
      } else {
        _reversePlaybackTimer?.cancel();
        _videoController?.seekTo(clip.sourceStart);
        _videoController?.play();
      }
    }
    _showSnack(
      clip.isReversed ? 'Reverse playback on' : 'Reverse playback off',
    );
  }

  void _adjustOpacity() => _showSnack('Adjust opacity');
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
        _videoController?.setVolume(value);
        _audioPreviewPlayer.setVolume(value);
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

  void _addFade() => _showSnack('Add fade');
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
    final clip = _selectedClip;
    if (clip != null && clip.file != null && !clip.isReversed) {
      final sourceEnd = clip.sourceEnd ?? _videoController!.value.duration;
      if (_videoController!.value.position >= sourceEnd) {
        _videoController!.seekTo(clip.sourceStart);
      }
    }
    setState(() {
      final sourcePosition = _videoController!.value.position;
      final sourceStart = clip?.sourceStart ?? Duration.zero;
      final elapsedMs = math.max(
        0,
        sourcePosition.inMilliseconds - sourceStart.inMilliseconds,
      );
      _currentTime = Duration(
        milliseconds: (elapsedMs / (clip?.speed ?? 1.0)).round(),
      );
      _totalDuration = clip?.duration ?? _videoController!.value.duration;
      _isPlaying = clip?.isReversed == true
          ? (_reversePlaybackTimer?.isActive ?? false)
          : _videoController!.value.isPlaying;
      if (_totalDuration.inMilliseconds > 0) {
        _playheadPosition =
            (_currentTime.inMilliseconds / _totalDuration.inMilliseconds) * 200;
      }
    });
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

    final int numThumbnails = (widget.clip.duration.inSeconds).clamp(1, 100);
    final double thumbWidth = widget.pixelsPerSecond;

    return ListView.builder(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: numThumbnails,
      itemBuilder: (context, index) {
        return SizedBox(
          width: thumbWidth,
          child: _SingleThumbnail(
            file: widget.clip.file!,
            timeMs: index * 1000,
          ),
        );
      },
    );
  }
}

class _SingleThumbnail extends StatefulWidget {
  final File file;
  final int timeMs;

  const _SingleThumbnail({Key? key, required this.file, required this.timeMs})
    : super(key: key);

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
    final cacheKey = '${widget.file.path}_${widget.timeMs}';
    if (_MobileMediaEditorState._thumbnailCache.containsKey(cacheKey)) {
      if (mounted)
        setState(
          () => _bytes = _MobileMediaEditorState._thumbnailCache[cacheKey],
        );
      return;
    }

    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: widget.file.path,
        imageFormat: ImageFormat.JPEG,
        timeMs: widget.timeMs,
        quality: 25,
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
      return Container(color: C.surface);
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
