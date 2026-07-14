import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../theme.dart';
import '../app_state.dart';
import '../models/edit_models.dart';
import '../widgets/media_editor_tools.dart';
import '../widgets/mobile_editor_panels.dart';
import '../services/music_library_service.dart';
import '../models/music_models.dart';
import '../services/editor_subscription_service.dart';
import '../services/editor_export_service.dart';
import 'pro_media_editor_screen.dart';
import 'music_library_screen.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

// ══════════════════════════════════════════════════════════════
// MOBILE MEDIA EDITOR - Responsive adaptation of desktop editor
// ══════════════════════════════════════════════════════════════

class MobileMediaEditor extends StatefulWidget {
  final AppState state;
  final File? initialMedia;
  
  const MobileMediaEditor({
    super.key,
    required this.state,
    this.initialMedia,
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
  
  // ── Timeline ─────────────────────────────────────────────────
  final List<TimelineTrack> _tracks = [];
  double _playheadPosition = 0.0;
  double _timelineZoom = 1.0;
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
  
  // ── UI State ─────────────────────────────────────────────────
  int _activeToolPanel = 0; // 0: Timeline, 1: Media, 2: Audio, 3: Text, 4: Effects
  bool _showFullscreenPreview = false;
  String _selectedAspectRatio = '9:16';
  String _selectedResolution = '1080p';
  String _selectedFps = '30fps';
  
  // ── Controllers ──────────────────────────────────────────────
  late TabController _bottomNavController;

  // ── Audio State ─────────────────────────────────────────────
  final MusicLibraryService _musicService = MusicLibraryService();
  final AudioRecorder _voiceRecorder = AudioRecorder();
  final AudioPlayer _audioPreviewPlayer = AudioPlayer();
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
    _bottomNavController = TabController(length: 8, vsync: this);
    _initializeEditor();
    _loadProState();
  }

  Future<void> _loadProState() async {
    final isPro = await EditorSubscriptionService.isProEnabled();
    if (!mounted) return;
    setState(() => _isProEnabled = isPro);
  }
  
  void _initializeEditor() {
    final videoTrack = TimelineModelUtils.ensureTrackForType(
      _tracks,
      TrackType.video,
      id: 'video-1',
      label: 'Video',
    );
    videoTrack.clips.add(TimelineClip(
      id: 'video-clip-1',
      start: Duration.zero,
      duration: const Duration(seconds: 12),
      operation: TrimOperation(
        start: Duration.zero,
        end: const Duration(seconds: 12),
        maxDuration: const Duration(seconds: 12),
      ),
    ));

    TimelineModelUtils.pruneEmptyTracks(_tracks);

    if (widget.initialMedia != null && widget.initialMedia!.existsSync()) {
      _videoController = VideoPlayerController.file(widget.initialMedia!)
        ..initialize().then((_) {
          if (!mounted) return;
          setState(() {
            _isVideoReady = true;
            _totalDuration = _videoController!.value.duration;
          });
          _videoController!.setLooping(true);
          _videoController!.addListener(_syncVideoState);
          _videoController!.play();
        });
    }
  }
  
  @override
  void dispose() {
    _videoController?.removeListener(_syncVideoState);
    _videoController?.dispose();
    _bottomNavController.dispose();
    _musicService.dispose();
    _audioPreviewPlayer.dispose();
    _voiceRecorder.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isPortrait = screenSize.height > screenSize.width;
    
    if (!isPortrait) {
      // Landscape: use desktop editor
      return ProMediaEditorScreen(state: widget.state);
    }
    
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
                      Expanded(
                        child: _buildEditorPanel(screenSize),
                      ),
                    ],
                  ),
                ),
                _buildContextToolbar(screenSize),
                _buildBottomNavigation(screenSize),
              ],
            ),
            if (_showFullscreenPreview) _buildFullscreenPreviewOverlay(),
            // Right-side canvas toolbar (Expand / Save / Preview)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12.0),
                  child: _buildCanvasToolbar(),
                ),
              ),
            ),
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
                      onPressed: () => setState(() => _showFullscreenPreview = false),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                        Text(_formatDuration(_currentTime), style: dm(sz: 12, c: Colors.white, w: FontWeight.w700)),
                        Text(_formatDuration(_totalDuration), style: dm(sz: 12, c: Colors.white70)),
                      ],
                    ),
                    Slider(
                      value: _totalDuration.inMilliseconds > 0
                          ? _currentTime.inMilliseconds / _totalDuration.inMilliseconds
                          : 0.0,
                      onChanged: (value) {
                        if (_videoController != null && _totalDuration.inMilliseconds > 0) {
                          final target = Duration(milliseconds: (value * _totalDuration.inMilliseconds).round());
                          _videoController!.seekTo(target);
                        }
                      },
                      activeColor: C.brand,
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildFullscreenControl(Icons.skip_previous, () => _previousFrame()),
                        const SizedBox(width: 12),
                        _buildFullscreenControl(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          () => _togglePlayback(),
                          isLarge: true,
                        ),
                        const SizedBox(width: 12),
                        _buildFullscreenControl(Icons.skip_next, () => _nextFrame()),
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

  Widget _buildCanvasToolbar() {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCanvasToolButton(Icons.fullscreen, 'Expand', () => setState(() => _showFullscreenPreview = true)),
                const SizedBox(height: 10),
                _buildCanvasToolButton(Icons.save, 'Save', _saveDraft, color: C.green),
                const SizedBox(height: 10),
                _buildCanvasToolButton(Icons.play_arrow, 'Preview', _showPreview),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvasToolButton(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 78,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 6)],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color ?? Colors.white, size: 18),
              const SizedBox(height: 4),
              Text(label.toUpperCase(), style: dm(sz: 9, c: Colors.white, w: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenControl(IconData icon, VoidCallback onTap, {bool isLarge = false}) {
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
              Text('NECXA', style: syne(sz: 15, w: FontWeight.w900, c: C.brand)),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  children: [
                    Text('New Project', style: dm(sz: 13, c: C.text, w: FontWeight.w700)),
                    const SizedBox(width: 4),
                    const Icon(Icons.keyboard_arrow_down, size: 18, color: Colors.white70),
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
              _buildSettingsChip(_selectedAspectRatio, () => _showSelectionSheet('Aspect ratio', ['9:16', '16:9', '1:1', '4:5'], (value) => setState(() => _selectedAspectRatio = value))),
              const SizedBox(width: 6),
              _buildSettingsChip(_selectedResolution, () => _showSelectionSheet('Resolution', ['480p', '720p', '1080p', '4K'], (value) => setState(() => _selectedResolution = value))),
              const SizedBox(width: 6),
              _buildSettingsChip(_selectedFps, () => _showSelectionSheet('FPS', ['24fps', '30fps', '60fps'], (value) => setState(() => _selectedFps = value))),
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

  Widget _buildIconButton(IconData icon, VoidCallback onTap, {double size = 24}) {
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
        boxShadow: _isProEnabled ? [BoxShadow(color: C.brand.withOpacity(0.18), blurRadius: 6, offset: const Offset(0,2))] : null,
        border: Border.all(color: _isProEnabled ? Colors.transparent : C.border),
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
                Text('Pro', style: dm(sz: 11, w: FontWeight.w800, c: fg)),
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
          onTap: enabled ? _export : null,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(enabled ? Icons.upload : Icons.hourglass_top, size: 14, color: Colors.white),
                const SizedBox(width: 8),
                Text(enabled ? 'Export' : 'Working', style: dm(sz: 11, w: FontWeight.w800, c: Colors.white)),
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
            onTap: () => setState(() {
              _selectedClip = TimelineClip(
                id: 'preview-clip',
                start: _currentTime,
                duration: const Duration(seconds: 1),
                operation: TrimOperation(
                  start: _currentTime,
                  end: _currentTime + const Duration(seconds: 1),
                  maxDuration: _totalDuration,
                ),
              );
              _selectedTrackId = 'video-1';
              _selectedTrackIndex = _tracks.indexWhere((track) => track.id == _selectedTrackId);
            }),
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
                  border: Border.all(
                    color: C.brand.withAlpha(26),
                    width: 2,
                  ),
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
    if (_isVideoReady && _videoController != null) {
      return Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            ),
          ),
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
          Text(
            'Preview',
            style: dm(sz: 14, c: C.dim.withAlpha(128)),
          ),
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
        if (clip.start > currentTime || clip.start + clip.duration < currentTime) {
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
                        filter: ui.ImageFilter.blur(sigmaX: renderEffects.blur * 8.0, sigmaY: renderEffects.blur * 8.0),
                        child: Container(color: Colors.transparent),
                      ),
                    if (renderEffects.vignette > 0.01)
                      Container(color: Colors.black.withOpacity(renderEffects.vignette * 0.32)),
                    if (renderEffects.grain > 0.01)
                      Container(color: Colors.white.withOpacity(renderEffects.grain * 0.08)),
                    if (renderEffects.brightness.abs() > 0.001 || renderEffects.contrast > 1.001 || renderEffects.saturation != 1.0)
                      ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          Colors.white.withOpacity((scale * 0.16).clamp(0.0, 0.16)),
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
      if (track.type != TrackType.text && track.type != TrackType.captions && track.type != TrackType.overlay) {
        continue;
      }

      for (final clip in track.clips) {
        if (clip.start > currentTime || clip.start + clip.duration < currentTime) {
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
            ],
          ),
          Text(
            _formatDuration(_totalDuration),
            style: dm(sz: 12, c: C.dim),
          ),
        ],
      ),
    );
  }
  
  Widget _buildPlaybackButton(IconData icon, VoidCallback onTap, {bool isLarge = false}) {
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
    if (_activeToolPanel == 2) {
      return _buildAudioPanel(screenSize);
    }
    return _buildTimelineWorkspace(screenSize);
  }

  Widget _buildTimelineWorkspace(Size screenSize) {
    final visibleTracks = TimelineModelUtils.visibleTracks(_tracks);

    return Container(
      color: C.bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              children: [
                Text('Timeline', style: syne(sz: 12, w: FontWeight.w800, c: C.text)),
                const Spacer(),
                Material(
                  color: C.brand.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: _pickMediaFromLibrary,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.add, size: 14, color: Colors.white),
                          const SizedBox(width: 4),
                          Text('Add', style: dm(sz: 9, c: C.brand, w: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: C.brand.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${visibleTracks.length} Tracks', style: dm(sz: 9, c: C.brand, w: FontWeight.w700)),
                ),
              ],
            ),
          ),
          _buildTimelineRuler(screenSize),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: visibleTracks.length,
              itemBuilder: (context, index) {
                return _buildTrackRow(visibleTracks[index], index, screenSize);
              },
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildTimelineRuler(Size screenSize) {
    const rulerHeight = 28.0;
    final timelineWidth = (screenSize.width - 96).clamp(0.0, double.infinity);
    final playheadOffset = _totalDuration.inMilliseconds > 0
        ? ((screenSize.width - 96) * (_currentTime.inMilliseconds / _totalDuration.inMilliseconds)).clamp(0.0, timelineWidth)
        : 0.0;
    
    return Container(
      height: rulerHeight,
      color: C.card,
      padding: const EdgeInsets.only(left: 48),
      child: GestureDetector(
        onTapDown: (details) {
          if (_totalDuration.inMilliseconds > 0) {
            final localX = details.localPosition.dx.clamp(0.0, timelineWidth);
            final targetMs = ((localX / timelineWidth) * _totalDuration.inMilliseconds).round();
            _videoController?.seekTo(Duration(milliseconds: targetMs));
          }
        },
        child: Stack(
          children: [
            Row(
              children: List.generate(
                (_totalDuration.inSeconds / 5).ceil(),
                (i) => Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 1,
                        height: 4,
                        color: C.dim.withAlpha(128),
                      ),
                      Expanded(
                        child: Center(
                          child: Text(
                            '${i * 5}s',
                            style: dm(sz: 7, c: C.dim),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: playheadOffset,
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: C.brand),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildTrackRow(TimelineTrack track, int index, Size screenSize) {
    final isSelected = _selectedTrackId == track.id;
    
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      decoration: BoxDecoration(
        color: isSelected ? C.brand.withOpacity(0.12) : C.surface,
        border: Border.all(
          color: isSelected ? C.brand : C.border,
          width: isSelected ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() {
              _selectedTrackId = track.id;
              _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == track.id);
            }),
            child: Container(
              width: 48,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(_getTrackIcon(track.type), style: const TextStyle(fontSize: 16)),
                  Text(
                    track.label.substring(0, math.min(3, track.label.length)),
                    style: dm(sz: 7, c: C.dim),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: GestureDetector(
                onScaleStart: (_) {},
                onScaleUpdate: (details) {
                  if (details.scale != 1.0) {
                    setState(() => _timelineZoom = (_timelineZoom * details.scale).clamp(0.7, 2.2));
                  }
                },
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: track.clips.map((clip) {
                      final clipWidth = (clip.duration.inMilliseconds / (140 / _timelineZoom)).clamp(70.0, 220.0).toDouble();
                      return GestureDetector(
                        onTap: () => setState(() {
                          _selectedClip = clip;
                          _selectedTrackId = track.id;
                          _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == track.id);
                          if (_videoController != null && _totalDuration.inMilliseconds > 0) {
                            _videoController!.seekTo(clip.start);
                          }
                        }),
                        onLongPress: () => _showClipActions(track, clip),
                        child: Container(
                        width: clipWidth,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: clip == _selectedClip ? C.brand : _trackColorForType(track.type),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: clip == _selectedClip ? C.brand : Colors.transparent,
                            width: 2,
                          ),
                        ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _clipLabelForTrack(track.type),
                                style: dm(sz: 8, c: Colors.white, w: FontWeight.w700),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                              Text(
                                _formatDuration(clip.duration),
                                style: dm(sz: 7, c: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTrackButton(Icons.visibility, () => _toggleTrackVisibility(track), size: 18),
                const SizedBox(width: 2),
                _buildTrackButton(Icons.lock, () => _toggleTrackLock(track), size: 18),
              ],
            ),
          ),
        ],
      ),
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
  
  Widget _buildTrackButton(IconData icon, VoidCallback onTap, {double size = 20}) {
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
      return track.type == TrackType.music || track.type == TrackType.voiceOver || track.type == TrackType.soundEffects;
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
                      Text('Audio Studio', style: syne(sz: 16, w: FontWeight.w800, c: C.text)),
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
            child: Row(
              children: [
                _buildActionChip('Music', Icons.music_note, _showAudioPicker),
                const SizedBox(width: 8),
                _buildActionChip(_isRecordingVoice ? 'Stop' : 'Voice', Icons.mic, _toggleVoiceOver),
                const SizedBox(width: 8),
                _buildActionChip('SFX', Icons.speaker, _addSoundEffect),
              ],
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
    return Expanded(
      child: Material(
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
                Text(label, style: dm(sz: 12, c: C.text, w: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAudioTrackCard(TimelineTrack track) {
    final totalDuration = track.clips.fold<Duration>(Duration.zero, (sum, clip) => sum + clip.duration);
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
                child: Text(track.label, style: syne(sz: 14, w: FontWeight.w800, c: C.text)),
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
              children: track.clips.map((clip) => _buildAudioClipRow(track, clip)).toList(),
            ),
          const SizedBox(height: 12),
          Text('Total ${_formatDuration(totalDuration)}', style: dm(sz: 11, c: C.dim)),
        ],
      ),
    );
  }

  Widget _buildAudioClipRow(TimelineTrack track, TimelineClip clip) {
    final operation = clip.operation;
    final label = operation is AudioClipOperation ? (operation.label ?? _clipLabelForTrack(track.type)) : _clipLabelForTrack(track.type);
    final source = operation is AudioClipOperation ? operation.sourceUrl : null;
    final isPlaying = _activeAudioPreviewUrl != null && source != null && _activeAudioPreviewUrl == source;

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
                    Text(label, style: dm(sz: 12, c: Colors.white, w: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(_formatDuration(clip.duration), style: dm(sz: 11, c: C.dim)),
                  ],
                ),
              ),
              if (source != null && source != 'builtin://sfx')
                Material(
                  color: C.surface,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => isPlaying ? _stopAudioPreview() : _previewAudioSource(source),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      child: Icon(isPlaying ? Icons.stop : Icons.play_arrow, size: 18, color: C.brand),
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
                    child: Icon(Icons.delete, size: 18, color: Colors.redAccent),
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

  Future<void> _previewAudioSource(String sourceUrl) async {
    await _musicService.stopPreview();
    await _audioPreviewPlayer.stop();

    if (sourceUrl.startsWith('http')) {
      await _musicService.previewMusic(sourceUrl);
    } else {
      await _audioPreviewPlayer.play(DeviceFileSource(sourceUrl));
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
    setState(() {
      track.clips.remove(clip);
      if (_selectedClip == clip) {
        _selectedClip = null;
        _selectedTrackId = null;
        _selectedTrackIndex = null;
      }
      TimelineModelUtils.pruneEmptyTracks(_tracks);
    });
  }

  String _getTrackIcon(TrackType type) {
    switch (type) {
      case TrackType.video: return '🎬';
      case TrackType.audio: return '🎵';
      case TrackType.text: return '📝';
      case TrackType.images: return '🖼️';
      case TrackType.captions: return '📄';
      case TrackType.overlay: return '🪟';
      case TrackType.effects: return '✨';
      case TrackType.music: return '🎼';
      case TrackType.voiceOver: return '🎙️';
      case TrackType.soundEffects: return '🔊';
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
    if (_selectedClip == null) {
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
    if (_selectedClip == null) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _buildToolsForSelection(),
        ),
      );
    }
    
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _buildToolsForClip(_selectedClip!),
      ),
    );
  }
  
  List<Widget> _buildToolsForSelection() {
    switch (_activeToolPanel) {
      case 1:
        return [
          _buildToolButton('Media', () => _pickMediaFromLibrary()),
          _buildToolButton('Trim', () => _trimClip()),
          _buildToolButton('Crop', () => _showSnack('Crop frame')), 
          _buildToolButton('Speed', () => _adjustSpeed()),
        ];
      case 2:
        return [
          _buildToolButton('Music', () => _showAudioPicker()),
          _buildToolButton('Voice', () => _toggleVoiceOver()),
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
          _buildToolButton('Preview', () => _showEffectLibrarySheet()),
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
      } else if (selectedTrack.type == TrackType.text || selectedTrack.type == TrackType.captions) {
        tools.addAll([
          _buildToolButton('Edit', () => _showTextEditorSheet()),
          _buildToolButton('Font', () => _showTextEditorSheet()),
          _buildToolButton('Size', () => _showTextEditorSheet()),
          _buildToolButton('Color', () => _showTextEditorSheet()),
          _buildToolButton('Delete', () => _deleteClip()),
        ]);
      } else if (selectedTrack.type == TrackType.audio) {
        tools.addAll([
          _buildToolButton('Volume', () => _adjustVolume()),
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
        children: List.generate(
          navItems.length,
          (index) {
            final item = navItems[index];
            final active = index == _activeToolPanel;
            return GestureDetector(
              onTap: () {
                setState(() {
                  _activeToolPanel = index;
                  _bottomNavController.index = index;
                });
                if (index == 3) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _showTextHubSheet());
                } else if (index == 4) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _showEffectLibrarySheet());
                } else if (index == 5) {
                  WidgetsBinding.instance.addPostFrameCallback((_) => _showTransitionLibrarySheet());
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
          },
        ),
      ),
    );
  }
  
  // ═══════════════════════════════════════════════════════════
  // FLOATING ACTION BUTTONS
  // ═══════════════════════════════════════════════════════════
  Widget _buildFloatingActions() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FloatingActionButton(
          heroTag: 'fullscreen',
          mini: true,
          onPressed: () => setState(() => _showFullscreenPreview = true),
          backgroundColor: C.brand,
          child: const Icon(Icons.fullscreen, color: Colors.white),
        ),
        const SizedBox(height: 8),
        FloatingActionButton(
          heroTag: 'save',
          mini: true,
          onPressed: () => _saveDraft(),
          backgroundColor: C.green,
          child: const Icon(Icons.save, color: Colors.white),
        ),
        const SizedBox(height: 8),
        FloatingActionButton(
          heroTag: 'preview',
          mini: true,
          onPressed: () => _showPreview(),
          backgroundColor: C.brand,
          child: const Icon(Icons.play_arrow, color: Colors.white),
        ),
      ],
    );
  }
  
  // ═══════════════════════════════════════════════════════════
  // ACTION HANDLERS
  // ═══════════════════════════════════════════════════════════
  
  void _showAspectRatioMenu() {
    _showSelectionSheet('Aspect ratio', ['9:16', '16:9', '1:1', '4:5'], (value) => setState(() => _selectedAspectRatio = value));
  }

  void _showSelectionSheet(String title, List<String> values, ValueChanged<String> onSelect) {
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
              Text(title, style: syne(sz: 14, w: FontWeight.w800, c: C.text)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: values.map((value) => GestureDetector(
                  onTap: () {
                    onSelect(value);
                    Navigator.pop(context);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: C.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: C.border),
                    ),
                    child: Text(value, style: dm(sz: 11, w: FontWeight.w600)),
                  ),
                )).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Future<void> _pickMediaFromLibrary() async {
    try {
      final picked = await ImagePicker().pickMultipleMedia();
      if (picked.isEmpty) return;

      final insertedClips = <TimelineClip>[];
      // Track per-track next insertion start time so multiple selected items
      // are chained sequentially per target track instead of overlapping.
      final Map<TrackType, Duration> nextStart = {};

      for (final media in picked) {
        final path = media.path.toLowerCase();
        final isVideo = path.endsWith('.mp4') || path.endsWith('.mov') || path.endsWith('.mkv') || path.endsWith('.avi');
        final trackType = isVideo ? TrackType.video : TrackType.images;
        final targetTrack = TimelineModelUtils.ensureTrackForType(_tracks, trackType);

        // Compute the next available start for this track
        if (!nextStart.containsKey(trackType)) {
          final lastEnd = targetTrack.clips.isEmpty
              ? Duration.zero
              : targetTrack.clips.map((c) => c.start + c.duration).reduce((a, b) => a > b ? a : b);
          nextStart[trackType] = lastEnd > _currentTime ? lastEnd : _currentTime;
        }

        final startAt = nextStart[trackType]!;

        final clip = TimelineClip(
          id: '${trackType.name}-${DateTime.now().millisecondsSinceEpoch}-${insertedClips.length}',
          start: startAt,
          duration: const Duration(seconds: 4),
          operation: TrimOperation(
            start: startAt,
            end: startAt + const Duration(seconds: 4),
            maxDuration: _totalDuration,
          ),
        );

        TimelineModelUtils.insertClip(_tracks, clip, trackType);
        insertedClips.add(clip);

        // Advance next start time for this track so subsequent items chain
        nextStart[trackType] = startAt + clip.duration;

        _selectedTrackId = targetTrack.id;
        _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == targetTrack.id);
      }

      if (insertedClips.isNotEmpty) {
        setState(() {
          _selectedClip = insertedClips.last;
          _selectedTrackId = _tracks.firstWhere((track) => track.clips.contains(insertedClips.last)).id;
          _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == _selectedTrackId);
        });
      }

      if (mounted) {
        _showSnack('${insertedClips.length} item${insertedClips.length == 1 ? '' : 's'} added to timeline');
      }
    } catch (_) {
      if (mounted) {
        _showSnack('Unable to load media right now');
      }
    }
  }

  void _undo() => _showSnack('Undo');
  void _redo() => _showSnack('Redo');

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
                  Text('NECXA Pro', style: syne(sz: 16, w: FontWeight.w800, c: C.text)),
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
              Text('Unlock premium capabilities across the NECXA ecosystem.', style: dm(sz: 12, c: C.dim)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: features.map((feature) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: C.surface,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(feature, style: dm(sz: 10.5, w: FontWeight.w600, c: C.brand)),
                )).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export() async {
    if (_isExporting) return;
    setState(() {
      _isExporting = true;
      _exportStatus = 'Saving Project';
    });

    final sourcePath = _videoController?.dataSource;
    if (sourcePath is String) {
      final source = File(sourcePath);
      if (await source.exists()) {
        setState(() => _exportStatus = 'Finalizing Timeline');
        setState(() => _exportStatus = 'Compressing Video');
        final result = await EditorExportService.exportProject(
          sourceVideo: source,
          projectName: 'Project 1',
          description: 'Published from NECXA Editor',
          creatorName: widget.state.currentProfile?['full_name']?.toString() ?? 'Creator',
        );
        if (!mounted) return;
        setState(() {
          _isExporting = false;
          _exportStatus = result.success ? 'Export Complete' : 'Export Failed';
        });
        if (result.success) {
          _showSnack(result.verificationSummary ?? 'Export complete');
        } else {
          _showSnack(result.issues.join(', '));
        }
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isExporting = false;
      _exportStatus = 'Export Failed';
    });
    _showSnack('Unable to export without a source video');
  }
  void _togglePlayback() {
    if (_videoController == null) {
      setState(() => _isPlaying = !_isPlaying);
      return;
    }

    if (_videoController!.value.isPlaying) {
      _videoController!.pause();
    } else {
      _videoController!.play();
    }
  }

  void _previousFrame() {
    if (_videoController == null) return;
    final target = _videoController!.value.position - const Duration(milliseconds: 100);
    _videoController!.seekTo(target < Duration.zero ? Duration.zero : target);
  }

  void _nextFrame() {
    if (_videoController == null) return;
    final target = _videoController!.value.position + const Duration(milliseconds: 100);
    final maxDuration = _videoController!.value.duration;
    _videoController!.seekTo(target > maxDuration ? maxDuration : target);
  }
  void _toggleTrackVisibility(TimelineTrack track) {
    track.isVisible = !track.isVisible;
    if (!track.isVisible) {
      TimelineModelUtils.pruneEmptyTracks(_tracks);
    }
    setState(() {});
  }

  void _toggleTrackLock(TimelineTrack track) {
    track.isLocked = !track.isLocked;
    setState(() {});
  }
  void _splitClip() => _showSnack('Split clip');
  void _trimClip() => _showSnack('Trim clip');
  void _adjustSpeed() => _showSnack('Adjust speed');
  void _adjustOpacity() => _showSnack('Adjust opacity');
  void _applyFilter() => _showEffectLibrarySheet();
  void _deleteClip() {
    if (_selectedClip == null) return;
    setState(() {
      for (final track in _tracks) {
        track.clips.remove(_selectedClip);
      }
      _selectedClip = null;
      _selectedTrackId = null;
      _selectedTrackIndex = null;
      TimelineModelUtils.pruneEmptyTracks(_tracks);
    });
  }
  void _changeFont() => _showSnack('Change font');
  void _changeFontSize() => _showSnack('Change font size');
  void _changeTextColor() => _showSnack('Change text color');
  void _addShadow() => _showSnack('Add shadow');
  void _adjustVolume() => _showSnack('Adjust volume');
  void _addFade() => _showSnack('Add fade');
  void _saveDraft() => _showSnack('Draft saved');
  void _showPreview() => _showSnack('Playing preview');

  TimelineClip _insertTextLayer(String text, {TextStyle? style, Offset? position}) {
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
      _selectedTrackId = _tracks.firstWhere((track) => track.clips.contains(clip)).id;
      _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == _selectedTrackId);
    });

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
              Text('Text Studio', style: syne(sz: 16, w: FontWeight.w800, c: C.text)),
              const SizedBox(height: 12),
              Text('Add text', style: dm(sz: 12, w: FontWeight.w700, c: C.dim)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTextHubChip('Heading', () {
                    Navigator.pop(context);
                    _insertTextLayer('Heading', style: const TextStyle(fontSize: 34, color: Colors.white, fontWeight: FontWeight.w800));
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Subheading', () {
                    Navigator.pop(context);
                    _insertTextLayer('Subheading', style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.w700));
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Body', () {
                    Navigator.pop(context);
                    _insertTextLayer('Body text', style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.w500));
                    _showTextEditorSheet();
                  }),
                ],
              ),
              const SizedBox(height: 16),
              Text('Templates', style: dm(sz: 12, w: FontWeight.w700, c: C.dim)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTextHubChip('Intro Title', () {
                    Navigator.pop(context);
                    _insertTextLayer('Intro Title', style: const TextStyle(fontSize: 30, color: Color(0xFF8B5CF6), fontWeight: FontWeight.w900));
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Lower Third', () {
                    Navigator.pop(context);
                    _insertTextLayer('Lower Third', style: const TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.w700));
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Quote', () {
                    Navigator.pop(context);
                    _insertTextLayer('Quote', style: const TextStyle(fontSize: 22, color: Color(0xFF22C55E), fontWeight: FontWeight.w700));
                    _showTextEditorSheet();
                  }),
                ],
              ),
              const SizedBox(height: 16),
              Text('Captions & Stickers', style: dm(sz: 12, w: FontWeight.w700, c: C.dim)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildTextHubChip('Caption', () {
                    Navigator.pop(context);
                    _insertTextLayer('Caption', style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.w600));
                    _showTextEditorSheet();
                  }),
                  _buildTextHubChip('Sticker', () {
                    Navigator.pop(context);
                    _insertTextLayer('✨', style: const TextStyle(fontSize: 32, color: Colors.white));
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
                  Text('Text Editor', style: syne(sz: 15, w: FontWeight.w800, c: C.text)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: TextEditingController(text: overlay.text)
                      ..selection = TextSelection.collapsed(offset: overlay.text.length),
                    onChanged: (value) {
                      overlay.text = value;
                      setState(() {});
                      setModalState(() {});
                    },
                    decoration: InputDecoration(
                      hintText: 'Enter text',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Typography', style: dm(sz: 12, w: FontWeight.w700, c: C.dim)),
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
                        overlay.style = overlay.style.copyWith(fontWeight: FontWeight.w800);
                        setState(() {});
                        setModalState(() {});
                      }),
                      _buildTextHubChip('Italic', () {
                        overlay.style = overlay.style.copyWith(fontStyle: FontStyle.italic);
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
                        final duplicated = _insertTextLayer(overlay.text, style: overlay.style, position: overlay.position);
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
          child: Text(label, style: dm(sz: 11, w: FontWeight.w600, c: C.brand)),
        ),
      ),
    );
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
        duration: Duration(seconds: (result.duration / 1000).ceil()),
        operation: AudioClipOperation(
          sourceType: 'music',
          sourceUrl: result.audioUrl,
          label: result.title,
          volume: _audioVolume,
        ),
      );

      TimelineModelUtils.insertClip(_tracks, clip, TrackType.music);
      setState(() {
        _selectedClip = clip;
        _selectedTrackId = _tracks.firstWhere((track) => track.clips.contains(clip)).id;
        _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == _selectedTrackId);
        _isPreviewingMusic = true;
      });
      await _musicService.previewMusic(result.audioUrl);
      _showSnack('Music synced to timeline');
    }
  }

  Future<void> _toggleVoiceOver() async {
    if (_isRecordingVoice) {
      final path = await _voiceRecorder.stop();
      if (path != null) {
        final file = File(path);
        final clip = TimelineClip(
          id: 'voice-${DateTime.now().millisecondsSinceEpoch}',
          start: _currentTime,
          duration: const Duration(seconds: 8),
          operation: AudioClipOperation(
            sourceType: 'voiceover',
            sourceUrl: file.path,
            label: 'Voiceover',
            volume: _audioVolume,
          ),
        );

        TimelineModelUtils.insertClip(_tracks, clip, TrackType.voiceOver);
        setState(() {
          _voiceOverFile = file;
          _selectedClip = clip;
          _selectedTrackId = _tracks.firstWhere((track) => track.clips.contains(clip)).id;
          _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == _selectedTrackId);
          _isRecordingVoice = false;
        });
        _showSnack('Voiceover added to timeline');
      }
      return;
    }

    if (await _voiceRecorder.hasPermission()) {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/voiceover_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _voiceRecorder.start(const RecordConfig(), path: path);
      setState(() => _isRecordingVoice = true);
      _showSnack('Recording voiceover…');
    } else {
      _showSnack('Microphone permission denied');
    }
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

    TimelineModelUtils.insertClip(_tracks, clip, TrackType.soundEffects);
    setState(() {
      _selectedClip = clip;
      _selectedTrackId = _tracks.firstWhere((track) => track.clips.contains(clip)).id;
      _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == _selectedTrackId);
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

    final preset = _effectPresets.firstWhere((candidate) => candidate.id == _selectedEffectId, orElse: () => _effectPresets.first);
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

    TimelineModelUtils.insertClip(_tracks, clip, TrackType.effects);
    _recentEffectIds.remove(preset.id);
    _recentEffectIds.insert(0, preset.id);
    setState(() {
      _selectedClip = clip;
      _selectedTrackId = _tracks.firstWhere((track) => track.clips.contains(clip)).id;
      _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == _selectedTrackId);
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
            final matchesQuery = _effectsSearchQuery.isEmpty || [preset.name, preset.category, preset.description, ...preset.tags]
                .join(' ')
                .toLowerCase()
                .contains(_effectsSearchQuery.toLowerCase());
            final matchesFilter = _effectsFilter == 'All' || preset.category == _effectsFilter;
            return matchesQuery && matchesFilter;
          }).toList();

          visiblePresets.sort((a, b) {
            switch (_effectsSort) {
              case 'Name':
                return a.name.compareTo(b.name);
              case 'Recent':
                return _recentEffectIds.indexOf(b.id).compareTo(_recentEffectIds.indexOf(a.id));
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
                      Text('Effects Library', style: syne(sz: 16, w: FontWeight.w800, c: C.text)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    onChanged: (value) => setModalState(() => _effectsSearchQuery = value),
                    decoration: InputDecoration(
                      hintText: 'Search effects',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <String>['All', 'Cinematic', 'Glitch', 'VHS', 'Blur', 'Retro', 'Film', 'Neon', 'Light']
                          .map((category) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(category),
                                  selected: _effectsFilter == category,
                                  onSelected: (_) => setModalState(() => _effectsFilter = category),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <String>['Featured', 'Recent', 'Favorites', 'Name'].map((sort) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(sort),
                          selected: _effectsSort == sort,
                          onSelected: (_) => setModalState(() => _effectsSort = sort),
                        ),
                      )).toList(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: visiblePresets.length,
                      itemBuilder: (context, index) {
                        final preset = visiblePresets[index];
                        final isFavorite = _favoriteEffectIds.contains(preset.id);
                        final isSelected = _selectedEffectId == preset.id;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? C.brand.withOpacity(0.14) : C.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: isSelected ? C.brand : C.border),
                          ),
                          child: ListTile(
                            leading: Text(preset.icon, style: const TextStyle(fontSize: 24)),
                            title: Text(preset.name, style: dm(sz: 12, w: FontWeight.w700, c: C.text)),
                            subtitle: Text(preset.description, style: dm(sz: 10.5, c: C.dim)),
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
                                  icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_outline, color: C.brand),
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
                          Text('Live Preview', style: dm(sz: 12, w: FontWeight.w700, c: C.text)),
                          const SizedBox(height: 6),
                          Text('Previewing ${_previewEffect!.name} on the selected clip before applying it.', style: dm(sz: 11, c: C.dim)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              TextButton(onPressed: () => setState(() => _previewEffect = null), child: const Text('Clear Preview')),
                              const SizedBox(width: 8),
                              ElevatedButton(onPressed: _applySelectedEffect, child: const Text('Apply')),
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
                  Text('Effect Editor', style: syne(sz: 15, w: FontWeight.w800, c: C.text)),
                  const SizedBox(height: 12),
                  Text(operation.presetName, style: dm(sz: 13, w: FontWeight.w700, c: C.text)),
                  const SizedBox(height: 8),
                  _buildEffectSlider('Intensity', operation.intensity, 0.0, 1.0, (value) => setModalState(() => operation.intensity = value)),
                  _buildEffectSlider('Opacity', operation.opacity, 0.0, 1.0, (value) => setModalState(() => operation.opacity = value)),
                  _buildEffectSlider('Start Offset', operation.startOffset, 0.0, 2.0, (value) => setModalState(() => operation.startOffset = value)),
                  _buildEffectSlider('End Offset', operation.endOffset, 0.0, 2.0, (value) => setModalState(() => operation.endOffset = value)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildEffectChip('Keyframes', () => _showSnack('Keyframes added')), 
                      _buildEffectChip('Copy', () => _showSnack('Attributes copied')), 
                      _buildEffectChip('Paste', () => _showSnack('Attributes pasted')), 
                      _buildEffectChip('Duplicate', () => _showSnack('Effect duplicated')), 
                      _buildEffectChip('Replace', () => _showEffectLibrarySheet()),
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

  Widget _buildEffectSlider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: dm(sz: 11, w: FontWeight.w600, c: C.dim)),
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
          child: Text(label, style: dm(sz: 10.5, w: FontWeight.w600, c: C.brand)),
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

    final preset = _transitionPresets.firstWhere((candidate) => candidate.id == _selectedTransitionId, orElse: () => _transitionPresets.first);
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

    TimelineModelUtils.insertClip(_tracks, transition, TrackType.effects);
    _recentTransitionIds.remove(preset.id);
    _recentTransitionIds.insert(0, preset.id);
    setState(() {
      _selectedClip = transition;
      _selectedTrackId = _tracks.firstWhere((track) => track.clips.contains(transition)).id;
      _selectedTrackIndex = _tracks.indexWhere((candidate) => candidate.id == _selectedTrackId);
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
            final matchesQuery = _transitionSearchQuery.isEmpty || [preset.name, preset.category, preset.description, ...preset.tags]
                .join(' ')
                .toLowerCase()
                .contains(_transitionSearchQuery.toLowerCase());
            final matchesFilter = _transitionFilter == 'All' || preset.category == _transitionFilter;
            return matchesQuery && matchesFilter;
          }).toList();

          visibleTransitions.sort((a, b) {
            switch (_transitionSort) {
              case 'Name':
                return a.name.compareTo(b.name);
              case 'Recent':
                return _recentTransitionIds.indexOf(b.id).compareTo(_recentTransitionIds.indexOf(a.id));
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
                      Text('Transitions Library', style: syne(sz: 16, w: FontWeight.w800, c: C.text)),
                      const Spacer(),
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    onChanged: (value) => setModalState(() => _transitionSearchQuery = value),
                    decoration: InputDecoration(
                      hintText: 'Search transitions',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <String>['All', 'Crossfade', 'Fade', 'Dissolve', 'Slide', 'Wipe', 'Zoom', 'Spin', 'Blur', 'Glitch']
                          .map((category) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(category),
                                  selected: _transitionFilter == category,
                                  onSelected: (_) => setModalState(() => _transitionFilter = category),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <String>['Featured', 'Recent', 'Favorites', 'Name'].map((sort) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(sort),
                          selected: _transitionSort == sort,
                          onSelected: (_) => setModalState(() => _transitionSort = sort),
                        ),
                      )).toList(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: visibleTransitions.length,
                      itemBuilder: (context, index) {
                        final preset = visibleTransitions[index];
                        final isFavorite = _favoriteTransitionIds.contains(preset.id);
                        final isSelected = _selectedTransitionId == preset.id;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? C.brand.withOpacity(0.14) : C.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: isSelected ? C.brand : C.border),
                          ),
                          child: ListTile(
                            leading: Text(preset.icon, style: const TextStyle(fontSize: 24)),
                            title: Text(preset.name, style: dm(sz: 12, w: FontWeight.w700, c: C.text)),
                            subtitle: Text(preset.description, style: dm(sz: 10.5, c: C.dim)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () {
                                    setState(() {
                                      if (isFavorite) {
                                        _favoriteTransitionIds.remove(preset.id);
                                      } else {
                                        _favoriteTransitionIds.add(preset.id);
                                      }
                                    });
                                    setModalState(() {});
                                  },
                                  icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_outline, color: C.brand),
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
    if (_selectedClip == null || _selectedClip!.operation is! TransitionOperation) {
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
                  Text('Transition Editor', style: syne(sz: 15, w: FontWeight.w800, c: C.text)),
                  const SizedBox(height: 10),
                  Text(transition.presetName, style: dm(sz: 13, w: FontWeight.w700, c: C.text)),
                  const SizedBox(height: 8),
                  _buildEffectSlider('Duration', transition.duration, 0.1, 2.0, (value) => setModalState(() => transition.duration = value)),
                  _buildEffectSlider('Intensity', transition.intensity, 0.0, 1.0, (value) => setModalState(() => transition.intensity = value)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildEffectChip('Preview', () => _showSnack('Previewing transition')),
                      _buildEffectChip('Replace', () => _showTransitionLibrarySheet()),
                      _buildEffectChip('Duplicate', () => _showSnack('Transition duplicated')),
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
              Text('Clip actions', style: syne(sz: 14, w: FontWeight.w800, c: C.text)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildClipActionChip('Split', () { Navigator.pop(context); _splitClip(); }),
                  _buildClipActionChip('Trim', () { Navigator.pop(context); _trimClip(); }),
                  _buildClipActionChip('Duplicate', () { Navigator.pop(context); _showSnack('Clip duplicated'); }),
                  _buildClipActionChip('Delete', () { Navigator.pop(context); _deleteClip(); }),
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
          child: Text(label, style: dm(sz: 11, w: FontWeight.w600, c: C.brand)),
        ),
      ),
    );
  }

  void _showToolPanel(String toolName) => _showSnack('$toolName panel opened');

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _syncVideoState() {
    if (!mounted || _videoController == null) return;
    setState(() {
      _currentTime = _videoController!.value.position;
      _totalDuration = _videoController!.value.duration;
      _isPlaying = _videoController!.value.isPlaying;
      if (_totalDuration.inMilliseconds > 0) {
        _playheadPosition = (_currentTime.inMilliseconds / _totalDuration.inMilliseconds) * 200;
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
