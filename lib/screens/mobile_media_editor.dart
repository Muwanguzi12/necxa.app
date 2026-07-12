import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../theme.dart';
import '../app_state.dart';
import '../widgets/media_editor_tools.dart';
import '../widgets/mobile_editor_panels.dart';
import 'pro_media_editor_screen.dart';

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
  EditorObject? _selectedObject;
  
  // ── Timeline ─────────────────────────────────────────────────
  final List<EditorTrack> _tracks = [];
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
  
  @override
  void initState() {
    super.initState();
    _bottomNavController = TabController(length: 8, vsync: this);
    _initializeEditor();
  }
  
  void _initializeEditor() {
    final videoTrack = EditorTrack(id: 'video-1', name: 'Video', type: TrackType.video);
    videoTrack.clips.add(EditorObject(
      id: 'video-clip-1',
      name: 'Main Clip',
      type: 'video',
      startTime: Duration.zero,
      duration: const Duration(seconds: 12),
    ));

    final audioTrack = EditorTrack(id: 'audio-1', name: 'Audio', type: TrackType.audio);
    audioTrack.clips.add(EditorObject(
      id: 'audio-clip-1',
      name: 'Voiceover',
      type: 'audio',
      startTime: Duration.zero,
      duration: const Duration(seconds: 12),
    ));

    final textTrack = EditorTrack(id: 'text-1', name: 'Text', type: TrackType.text);
    textTrack.clips.add(EditorObject(
      id: 'text-clip-1',
      name: 'Caption',
      type: 'text',
      startTime: const Duration(seconds: 2),
      duration: const Duration(seconds: 4),
    ));

    final effectsTrack = EditorTrack(id: 'effects-1', name: 'Effects', type: TrackType.effects);
    effectsTrack.clips.add(EditorObject(
      id: 'effect-clip-1',
      name: 'Glow',
      type: 'effects',
      startTime: const Duration(seconds: 4),
      duration: const Duration(seconds: 3),
    ));

    _tracks.addAll([videoTrack, audioTrack, textTrack, effectsTrack]);

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
                        child: _buildTimelineWorkspace(screenSize),
                      ),
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
      floatingActionButton: _buildFloatingActions(),
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
    final headerHeight = screenSize.height * 0.09;
    
    return Container(
      height: headerHeight,
      decoration: BoxDecoration(
        color: C.card,
        border: Border(bottom: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          // Logo & Project Name
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NECXA EDITOR',
                  style: syne(sz: 11, w: FontWeight.w800, c: C.brand),
                ),
                Text(
                  'Project 1',
                  style: dm(sz: 8.5, w: FontWeight.w500, c: C.dim),
                ),
              ],
            ),
          ),
          
          // Quick Settings
          Row(
            children: [
              _buildSettingsChip(_selectedAspectRatio, () => _showSelectionSheet('Aspect ratio', ['9:16', '16:9', '1:1', '4:5'], (value) => setState(() => _selectedAspectRatio = value))),
              const SizedBox(width: 4),
              _buildSettingsChip(_selectedResolution, () => _showSelectionSheet('Resolution', ['480p', '720p', '1080p', '4K'], (value) => setState(() => _selectedResolution = value))),
              const SizedBox(width: 4),
              _buildSettingsChip(_selectedFps, () => _showSelectionSheet('FPS', ['24fps', '30fps', '60fps'], (value) => setState(() => _selectedFps = value))),
            ],
          ),
          
          const SizedBox(width: 6),
          
          // Undo/Redo
          _buildIconButton(Icons.undo, () => _undo(), size: 16),
          const SizedBox(width: 2),
          _buildIconButton(Icons.redo, () => _redo(), size: 16),
          
          const SizedBox(width: 6),
          
          // Export
          _buildIconButton(Icons.download, () => _export(), size: 16),
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
              _selectedObject = EditorObject(
                id: 'preview-clip',
                name: 'Preview',
                type: 'video',
                startTime: _currentTime,
                duration: const Duration(seconds: 1),
              );
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
  Widget _buildTimelineWorkspace(Size screenSize) {
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: C.brand.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('4 Tracks', style: dm(sz: 9, c: C.brand, w: FontWeight.w700)),
                ),
              ],
            ),
          ),
          _buildTimelineRuler(screenSize),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: _tracks.length,
              itemBuilder: (context, index) {
                return _buildTrackRow(_tracks[index], index, screenSize);
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
  
  Widget _buildTrackRow(EditorTrack track, int index, Size screenSize) {
    final isSelected = _selectedTrackIndex == index;
    
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
            onTap: () => setState(() => _selectedTrackIndex = index),
            child: Container(
              width: 48,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(_getTrackIcon(track.type), style: const TextStyle(fontSize: 16)),
                  Text(
                    track.name.substring(0, min(3, track.name.length)),
                    style: dm(sz: 7, c: C.dim),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: track.clips.map((clip) {
                    final clipWidth = (clip.duration.inMilliseconds / 140).clamp(70.0, 220.0).toDouble();
                    return GestureDetector(
                      onTap: () => setState(() {
                        _selectedObject = clip;
                        _selectedTrackId = track.id;
                      }),
                      child: Container(
                        width: clipWidth,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: clip == _selectedObject ? C.brand : _trackColorForType(track.type),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: clip == _selectedObject ? C.brand : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              clip.name,
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
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTrackButton(Icons.visibility, () => _toggleTrackVisibility(index), size: 18),
                const SizedBox(width: 2),
                _buildTrackButton(Icons.lock, () => _toggleTrackLock(index), size: 18),
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
      case TrackType.effects:
        return const Color(0xFFEC4899);
      default:
        return C.dim.withOpacity(0.8);
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
  
  String _getTrackIcon(TrackType type) {
    switch (type) {
      case TrackType.video: return '🎬';
      case TrackType.audio: return '🎵';
      case TrackType.text: return '📝';
      case TrackType.effects: return '✨';
      case TrackType.stickers: return '⭐';
      case TrackType.voiceOver: return '🎙️';
      case TrackType.captions: return '📄';
      default: return '📌';
    }
  }
  
  // ═══════════════════════════════════════════════════════════
  // E. CONTEXT TOOLBAR
  // ═══════════════════════════════════════════════════════════
  Widget _buildContextToolbar(Size screenSize) {
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
    if (_selectedObject == null) {
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
        children: _buildToolsForObject(_selectedObject!),
      ),
    );
  }
  
  List<Widget> _buildToolsForSelection() {
    switch (_activeToolPanel) {
      case 1:
        return [
          _buildToolButton('Media', () => _showToolPanel('Media')),
          _buildToolButton('Trim', () => _trimClip()),
          _buildToolButton('Crop', () => _showSnack('Crop frame')), 
          _buildToolButton('Speed', () => _adjustSpeed()),
        ];
      case 2:
        return [
          _buildToolButton('Volume', () => _adjustVolume()),
          _buildToolButton('Fade', () => _addFade()),
          _buildToolButton('EQ', () => _showSnack('EQ presets')), 
          _buildToolButton('Noise', () => _showSnack('Noise removal')),
        ];
      case 3:
        return [
          _buildToolButton('Font', () => _changeFont()),
          _buildToolButton('Size', () => _changeFontSize()),
          _buildToolButton('Color', () => _changeTextColor()),
          _buildToolButton('Shadow', () => _addShadow()),
        ];
      case 4:
        return [
          _buildToolButton('Filter', () => _applyFilter()),
          _buildToolButton('Blur', () => _showSnack('Blur effect')), 
          _buildToolButton('Glow', () => _showSnack('Glow effect')), 
          _buildToolButton('Overlay', () => _showSnack('Overlay layer')),
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
  
  List<Widget> _buildToolsForObject(EditorObject obj) {
    final tools = <Widget>[];
    
    if (obj.type == 'video') {
      tools.addAll([
        _buildToolButton('Split', () => _splitClip()),
        _buildToolButton('Trim', () => _trimClip()),
        _buildToolButton('Speed', () => _adjustSpeed()),
        _buildToolButton('Opacity', () => _adjustOpacity()),
        _buildToolButton('Filter', () => _applyFilter()),
        _buildToolButton('Delete', () => _deleteClip()),
      ]);
    } else if (obj.type == 'text') {
      tools.addAll([
        _buildToolButton('Font', () => _changeFont()),
        _buildToolButton('Size', () => _changeFontSize()),
        _buildToolButton('Color', () => _changeTextColor()),
        _buildToolButton('Shadow', () => _addShadow()),
        _buildToolButton('Delete', () => _deleteClip()),
      ]);
    } else if (obj.type == 'audio') {
      tools.addAll([
        _buildToolButton('Volume', () => _adjustVolume()),
        _buildToolButton('Fade', () => _addFade()),
        _buildToolButton('Delete', () => _deleteClip()),
      ]);
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
      ('🎬', 'Timeline'),
      ('📁', 'Media'),
      ('🎵', 'Audio'),
      ('📝', 'Text'),
      ('✨', 'Effects'),
      ('→', 'Transitions'),
      ('🎨', 'Assets'),
      ('⚙️', 'Settings'),
    ];
    
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(
          navItems.length,
          (index) => GestureDetector(
            onTap: () => setState(() {
              _activeToolPanel = index;
              _bottomNavController.index = index;
            }),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  navItems[index].$1,
                  style: TextStyle(fontSize: 16, color: index == _activeToolPanel ? C.brand : C.dim),
                ),
                Text(
                  navItems[index].$2,
                  style: dm(sz: 6.5, c: index == _activeToolPanel ? C.brand : C.dim),
                ),
              ],
            ),
          ),
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
  
  void _undo() => _showSnack('Undo');
  void _redo() => _showSnack('Redo');
  void _export() => _showSnack('Export');
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
  void _toggleTrackVisibility(int index) => _showSnack('Toggle visibility: ${_tracks[index].name}');
  void _toggleTrackLock(int index) => _showSnack('Toggle lock: ${_tracks[index].name}');
  void _splitClip() => _showSnack('Split clip');
  void _trimClip() => _showSnack('Trim clip');
  void _adjustSpeed() => _showSnack('Adjust speed');
  void _adjustOpacity() => _showSnack('Adjust opacity');
  void _applyFilter() => _showSnack('Apply filter');
  void _deleteClip() => _showSnack('Delete clip');
  void _changeFont() => _showSnack('Change font');
  void _changeFontSize() => _showSnack('Change font size');
  void _changeTextColor() => _showSnack('Change text color');
  void _addShadow() => _showSnack('Add shadow');
  void _adjustVolume() => _showSnack('Adjust volume');
  void _addFade() => _showSnack('Add fade');
  void _saveDraft() => _showSnack('Draft saved');
  void _showPreview() => _showSnack('Playing preview');

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

enum TrackType {
  video,
  audio,
  text,
  effects,
  stickers,
  voiceOver,
  captions,
}

class EditorTrack {
  final String id;
  final String name;
  final TrackType type;
  final List<EditorObject> clips = [];
  bool isVisible = true;
  bool isLocked = false;
  
  EditorTrack({
    required this.id,
    required this.name,
    required this.type,
  });
}

class EditorObject {
  final String id;
  final String name;
  final String type; // 'video', 'audio', 'text', etc.
  final Duration startTime;
  final Duration duration;
  
  EditorObject({
    required this.id,
    required this.name,
    required this.type,
    required this.startTime,
    required this.duration,
  });
}

int min(int a, int b) => a < b ? a : b;
