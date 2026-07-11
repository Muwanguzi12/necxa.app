import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
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
  Offset _canvasOffset = Offset.zero;
  
  // ── UI State ─────────────────────────────────────────────────
  int _activeToolPanel = 0; // 0: Timeline, 1: Media, 2: Audio, 3: Text, 4: Effects
  bool _showFullscreenPreview = false;
  
  // ── Controllers ──────────────────────────────────────────────
  late TabController _bottomNavController;
  
  @override
  void initState() {
    super.initState();
    _bottomNavController = TabController(length: 8, vsync: this);
    _initializeEditor();
  }
  
  void _initializeEditor() {
    // Create default tracks
    _tracks.addAll([
      EditorTrack(id: 'video-1', name: 'Video', type: TrackType.video),
      EditorTrack(id: 'audio-1', name: 'Audio', type: TrackType.audio),
    ]);
  }
  
  @override
  void dispose() {
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
    
    // Portrait: use mobile layout
    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
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
      floatingActionButton: _buildFloatingActions(),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  style: syne(sz: 12, w: FontWeight.w800, c: C.brand),
                ),
                Text(
                  'Project 1',
                  style: dm(sz: 9, w: FontWeight.w500, c: C.dim),
                ),
              ],
            ),
          ),
          
          // Quick Settings: Aspect Ratio
          GestureDetector(
            onTap: () => _showAspectRatioMenu(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: C.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: C.border),
              ),
              child: Text('9:16', style: dm(sz: 8, w: FontWeight.w600)),
            ),
          ),
          
          const SizedBox(width: 8),
          
          // Undo/Redo
          _buildIconButton(Icons.undo, () => _undo(), size: 18),
          const SizedBox(width: 4),
          _buildIconButton(Icons.redo, () => _redo(), size: 18),
          
          const SizedBox(width: 8),
          
          // Export
          _buildIconButton(Icons.download, () => _export(), size: 18),
        ],
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
          // Canvas with touch gestures
          GestureDetector(
            onDoubleTap: () => setState(() {
              _canvasScale = _canvasScale == 1.0 ? 2.0 : 1.0;
              _canvasOffset = Offset.zero;
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
          
          // Safe area overlay
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
          
          // Zoom indicator (when scaled)
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
    // Placeholder for actual media content
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
          // Time Display
          Text(
            _formatDuration(_currentTime),
            style: dm(sz: 12, w: FontWeight.w600, c: C.brand),
          ),
          
          // Playback Buttons
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
          
          // Duration Display
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
          // Timeline ruler
          _buildTimelineRuler(screenSize),
          
          // Tracks
          Expanded(
            child: ListView.builder(
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
    const rulerHeight = 24.0;
    final rulerWidth = screenSize.width * 0.85;
    
    return Container(
      height: rulerHeight,
      color: C.card,
      padding: const EdgeInsets.only(left: 48),
      child: Stack(
        children: [
          // Time markers
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
          
          // Playhead
          Positioned(
            left: 48 + _playheadPosition,
            top: 0,
            bottom: 0,
            child: Container(
              width: 2,
              color: C.brand,
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildTrackRow(EditorTrack track, int index, Size screenSize) {
    final isSelected = _selectedTrackIndex == index;
    
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      decoration: BoxDecoration(
        color: isSelected ? C.brand.withAlpha(26) : C.surface,
        border: Border.all(
          color: isSelected ? C.brand : C.border,
          width: isSelected ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          // Track Label
          GestureDetector(
            onTap: () => setState(() => _selectedTrackIndex = index),
            child: Container(
              width: 48,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    _getTrackIcon(track.type),
                    style: const TextStyle(fontSize: 16),
                  ),
                  Text(
                    track.name.substring(0, min(3, track.name.length)),
                    style: dm(sz: 7, c: C.dim),
                  ),
                ],
              ),
            ),
          ),
          
          // Clips & Timeline
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: track.clips.map((clip) {
                  return GestureDetector(
                    onTap: () => setState(() {
                      _selectedObject = clip;
                      _selectedTrackId = track.id;
                    }),
                    child: Container(
                      width: (clip.duration.inMilliseconds / 100).toDouble(),
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: clip == _selectedObject ? C.brand : C.dim.withAlpha(77),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: clip == _selectedObject ? C.brand : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Text(
                        clip.name,
                        style: dm(sz: 8, c: Colors.white, w: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          
          // Track Controls
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
      height: 48,
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: _buildContextualTools(),
    );
  }
  
  Widget _buildContextualTools() {
    if (_selectedObject == null) {
      return Center(
        child: Text(
          'Select an item to edit',
          style: dm(sz: 11, c: C.dim, w: FontWeight.w500),
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
      height: 56,
      decoration: BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(
          navItems.length,
          (index) => GestureDetector(
            onTap: () => setState(() => _bottomNavController.index = index),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(navItems[index].$1, style: const TextStyle(fontSize: 18)),
                Text(
                  navItems[index].$2,
                  style: dm(sz: 7, c: C.dim),
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Aspect ratio selector')),
    );
  }
  
  void _undo() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Undo')));
  void _redo() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Redo')));
  void _export() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Export')));
  void _togglePlayback() => setState(() => _isPlaying = !_isPlaying);
  void _previousFrame() => setState(() => _currentTime = Duration(milliseconds: math.max(0, _currentTime.inMilliseconds - 100)));
  void _nextFrame() => setState(() => _currentTime = Duration(milliseconds: _currentTime.inMilliseconds + 100));
  void _toggleTrackVisibility(int index) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Toggle visibility: ${_tracks[index].name}')));
  void _toggleTrackLock(int index) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Toggle lock: ${_tracks[index].name}')));
  void _splitClip() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Split clip')));
  void _trimClip() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trim clip')));
  void _adjustSpeed() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Adjust speed')));
  void _adjustOpacity() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Adjust opacity')));
  void _applyFilter() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Apply filter')));
  void _deleteClip() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Delete clip')));
  void _changeFont() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Change font')));
  void _changeFontSize() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Change font size')));
  void _changeTextColor() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Change text color')));
  void _addShadow() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add shadow')));
  void _adjustVolume() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Adjust volume')));
  void _addFade() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add fade')));
  void _saveDraft() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Draft saved')));
  void _showPreview() => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Playing preview')));
  
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
