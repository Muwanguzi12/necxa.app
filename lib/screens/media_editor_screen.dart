import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/edit_models.dart';
import '../widgets/media_editor_tools.dart';
import '../theme.dart';

const double _kContextToolbarHeight = 80.0;
const double _kBottomNavBarEstHeight = 56.0; // Estimated height for icons and padding, excluding safe area
const double _kFabBottomMargin = 16.0;

enum _DragInteractionType { move, resizeStart, resizeEnd, none }

enum MobileEditorTool { timeline, media, audio, text, effects, transitions, assets, settings }

class MediaEditorScreen extends StatefulWidget {
  final String mediaPath;
  const MediaEditorScreen({super.key, required this.mediaPath});

  @override
  State<MediaEditorScreen> createState() => _MobileMediaEditorScreenState();
}

class _MobileMediaEditorScreenState extends State<MediaEditorScreen> {
  // --- STATE ---
  late VideoPlayerController _controller;
  MobileEditorTool _activeTool = MobileEditorTool.timeline;

  // Store for non-destructive edits
  final List<EditOperation> _edits = [];
  TrimOperation? _trimOp;
  String _activeFilter = 'None';

  // --- Timeline State ---
  List<TimelineTrack> _tracks = [];
  final ScrollController _timelineScrollController = ScrollController();
  bool _isScrubbing = false;
  static const double _pixelsPerSecond = 60.0;

  // --- Clip Dragging State ---
  _DragInteractionType _dragInteraction = _DragInteractionType.none;
  String? _draggedClipId;
  String? _draggedTrackId;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.mediaPath))
      ..initialize().then((_) {
        setState(() {
          _trimOp = TrimOperation(
            start: Duration.zero,
            end: _controller.value.duration,
            maxDuration: _controller.value.duration,
          );
          _tracks = _generateInitialTracks();
        });
        _controller.play();
        _controller.addListener(_handlePlaybackLooping);
        _controller.addListener(_syncTimelineWithPlayhead);
      });
  }

  @override
  void dispose() {
    _controller.removeListener(_handlePlaybackLooping);
    _controller.removeListener(_syncTimelineWithPlayhead);
    _timelineScrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  // --- ACTIONS ---
  void _onToolSelected(MobileEditorTool tool) {
    setState(() {
      _activeTool = _activeTool == tool ? MobileEditorTool.timeline : tool;
    });
  }

  void _handlePlaybackLooping() {
    if (!mounted || _trimOp == null || !_controller.value.isPlaying) return;

    final position = _controller.value.position;
    if (position >= _trimOp!.end) {
      _controller.seekTo(_trimOp!.start);
    }
  }

  // --- Timeline Actions ---

  List<TimelineTrack> _generateInitialTracks() {
    if (_trimOp == null) return [];
    return [
      TimelineTrack(
        id: 'video-track-1',
        type: TrackType.video,
        label: 'Video',
        icon: Icons.videocam,
        clips: [
          TimelineClip(
            id: 'video-clip-1',
            start: Duration.zero,
            duration: _controller.value.duration,
            operation: _trimOp!,
          ),
        ],
      ),
      TimelineTrack(
        id: 'text-track-1',
        type: TrackType.text,
        label: 'Text',
        icon: Icons.text_fields,
        clips: [
          TimelineClip(
            id: 'text-clip-1',
            start: const Duration(seconds: 1),
            duration: const Duration(seconds: 3),
            operation: TextOverlay(text: 'Hello World'),
          ),
        ],
      ),
      TimelineTrack(
        id: 'audio-track-1',
        type: TrackType.audio,
        label: 'Music',
        icon: Icons.music_note,
        clips: [],
      ),
    ];
  }

  void _syncTimelineWithPlayhead() {
    if (!mounted || !_timelineScrollController.hasClients || _isScrubbing) return;
    final playheadPositionPixels = _controller.value.position.inMilliseconds / 1000.0 * _pixelsPerSecond;
    final screenWidth = MediaQuery.of(context).size.width;
    final targetOffset = (playheadPositionPixels - screenWidth / 2).clamp(0.0, _timelineScrollController.position.maxScrollExtent);

    if ((_timelineScrollController.offset - targetOffset).abs() > 1.0) {
      _timelineScrollController.jumpTo(targetOffset);
    }
  }

  void _onScrubStart(DragStartDetails details) {
    setState(() => _isScrubbing = true);
    if (_controller.value.isPlaying) _controller.pause();
  }

  void _onScrubUpdate(DragUpdateDetails details) {
    final newOffset = (_timelineScrollController.offset - details.delta.dx).clamp(0.0, _timelineScrollController.position.maxScrollExtent);
    _timelineScrollController.jumpTo(newOffset);
    final playheadPixelPosition = newOffset + (MediaQuery.of(context).size.width / 2);
    final newPositionMs = playheadPixelPosition / _pixelsPerSecond * 1000.0;
    _controller.seekTo(Duration(milliseconds: newPositionMs.round().clamp(0, _controller.value.duration.inMilliseconds)));
  }

  void _onClipDragStart(DragStartDetails details, TimelineClip clip, TimelineTrack track, _DragInteractionType interactionType) {
    if (track.isLocked) return;
    if (_controller.value.isPlaying) _controller.pause();
    setState(() {
      _isScrubbing = true; // Use scrubbing flag to prevent timeline auto-scroll
      _dragInteraction = interactionType;
      _draggedClipId = clip.id;
      _draggedTrackId = track.id;
    });
  }

  void _onClipDragUpdate(DragUpdateDetails details) {
    if (_dragInteraction == _DragInteractionType.none || _draggedClipId == null) return;

    final dx = details.delta.dx;
    final deltaDuration = Duration(milliseconds: (dx / _pixelsPerSecond * 1000).round());

    setState(() {
      final track = _tracks.firstWhere((t) => t.id == _draggedTrackId);
      final clip = track.clips.firstWhere((c) => c.id == _draggedClipId);

      switch (_dragInteraction) {
        case _DragInteractionType.move:
          final newStart = clip.start + deltaDuration;
          // Prevent moving before time 0
          clip.start = newStart.isNegative ? Duration.zero : newStart;
          break;
        case _DragInteractionType.resizeStart:
          final newStart = clip.start + deltaDuration;
          final newDuration = clip.duration - deltaDuration;
          // Prevent negative duration and resizing past time 0
          if (newDuration > const Duration(milliseconds: 200) && !newStart.isNegative) {
            clip.start = newStart;
            clip.duration = newDuration;
          }
          break;
        case _DragInteractionType.resizeEnd:
          final newDuration = clip.duration + deltaDuration;
          // Prevent negative duration
          if (newDuration > const Duration(milliseconds: 200)) {
            clip.duration = newDuration;
          }
          break;
        case _DragInteractionType.none:
          break;
      }
    });
  }

  void _onClipDragEnd(DragEndDetails details) {
    setState(() {
      _isScrubbing = false;
      _dragInteraction = _DragInteractionType.none;
      _draggedClipId = null;
      _draggedTrackId = null;
    });
  }
  void _onScrubEnd(DragEndDetails details) => setState(() => _isScrubbing = false);
  void _onFinishEditing() {
    // 1. Consolidate all edits
    final finalEdits = <EditOperation>[];
    if (_trimOp != null && (_trimOp!.start > Duration.zero || _trimOp!.end < _trimOp!.maxDuration)) {
      finalEdits.add(_trimOp!);
    }
    finalEdits.addAll(_edits.where((e) => e is! TrimOperation));

    // 2. Serialize to JSON
    final editingMetadata = {
      'version': '1.0',
      'edits': finalEdits.map((e) => e.toJson()).toList(),
    };

    // 3. Return metadata to the previous screen
    Navigator.pop(context, editingMetadata);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111), // Dark editor theme
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                _MobileEditorHeader(onExport: _onFinishEditing),
                _PreviewCanvas(controller: _controller, activeFilter: _activeFilter),
                _PlaybackControls(controller: _controller, trimOp: _trimOp),
                Expanded(
                  child: _TimelineWorkspace(
                    tracks: _tracks,
                    controller: _controller,
                    scrollController: _timelineScrollController,
                    onScrubStart: _onScrubStart,
                    onScrubUpdate: _onScrubUpdate,
                    onScrubEnd: _onScrubEnd,
                    onClipDragStart: _onClipDragStart,
                    onClipDragUpdate: _onClipDragUpdate,
                    onClipDragEnd: _onClipDragEnd,
                    pixelsPerSecond: _pixelsPerSecond,
                  ),
                ),
                _ContextToolbar(
                  activeTool: _activeTool,
                  trimOp: _trimOp,
                  controller: _controller,
                  onTrimChanged: (start, end) {
                    setState(() {
                      _trimOp?.start = start;
                      _trimOp?.end = end;
                    });
                    // When the trim range changes, ensure the playhead stays within the new bounds
                    // for a more intuitive user experience.
                    final currentPosition = _controller.value.position;
                    if (currentPosition < start) {
                      _controller.seekTo(start);
                    } else if (currentPosition > end) {
                      // Seeking to the start of the trim is often more intuitive.
                      _controller.seekTo(start);
                    }
                  },
                  activeFilter: _activeFilter,
                  onFilterSelected: (filterName) {
                    setState(() => _activeFilter = filterName);
                  },
                ),
                _BottomNavBar(
                  activeTool: _activeTool,
                  onToolSelected: _onToolSelected,
                ),
              ],
            ),
            const _FloatingActionButtons(),
          ],
        ),
      ),
    );
  }
}

// =================================================================
// A. HEADER
// =================================================================
class _MobileEditorHeader extends StatelessWidget {
  final VoidCallback onExport;
  const _MobileEditorHeader({required this.onExport});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
        left: 16,
        right: 16,
        bottom: 8,
      ),
      color: const Color(0xFF1A1A1A),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Icon(Icons.movie_filter_sharp, color: C.brand, size: 28),
          const SizedBox(width: 12),
          Text('Untitled Project', style: syne(c: Colors.white, sz: 16)),
          const Spacer(),
          // Placeholder for selectors
          const Text('9:16', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(width: 12),
          const Text('1080p', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(width: 12),
          const Text('30fps', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.undo, color: Colors.white, size: 24), onPressed: () {}),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.redo, color: Colors.white, size: 24), onPressed: () {}),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onExport,
            style: TextButton.styleFrom(
                backgroundColor: C.brand,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8)),
            child: Text('Export', style: syne(c: Colors.black, w: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

// =================================================================
// B. PREVIEW CANVAS
// =================================================================
class _PreviewCanvas extends StatelessWidget {
  final VideoPlayerController controller;
  final String activeFilter;
  const _PreviewCanvas({required this.controller, required this.activeFilter});

  // A map of filter names to ColorFilter objects for demonstration.
  static final Map<String, ColorFilter> _filterMap = {
    'None': ColorFilter.mode(Colors.transparent, BlendMode.dst), // No effect
    'Sepia': ColorFilter.matrix(<double>[
      0.393, 0.769, 0.189, 0, 0, //
      0.349, 0.686, 0.168, 0, 0, //
      0.272, 0.534, 0.131, 0, 0, //
      0, 0, 0, 1, 0,
    ]),
    'Grayscale': ColorFilter.matrix(<double>[
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0, 0, 0, 1, 0,
    ]),
    'Vintage': ColorFilter.mode(Color(0xFFF5E0B0), BlendMode.multiply),
    'Cold': ColorFilter.mode(Color(0xFFB0E0E6), BlendMode.softLight),
    'Warm': ColorFilter.mode(Color(0xFFFFDAB9), BlendMode.softLight),
    'Vivid': ColorFilter.mode(Colors.red, BlendMode.colorBurn),
    'Chrome': ColorFilter.mode(Colors.grey, BlendMode.saturation),
    'Fade': ColorFilter.mode(Colors.black.withAlpha(77), BlendMode.darken),
  };
  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final colorFilter = _filterMap[activeFilter] ?? _filterMap['None']!;

    return Container(
      height: screenHeight * 0.35,
      color: Colors.black,
      alignment: Alignment.center,
      child: controller.value.isInitialized
          ? ColorFiltered(
              colorFilter: colorFilter,
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            )
          : const Center(child: CircularProgressIndicator(color: C.brand)),
    );
  }
}

// =================================================================
// C. PLAYBACK CONTROLS
// =================================================================
class _PlaybackControls extends StatelessWidget {
  final VideoPlayerController controller;
  final TrimOperation? trimOp;
  const _PlaybackControls({required this.controller, this.trimOp});

  String _format(Duration d) => d.toString().split('.').first.padLeft(8, '0').substring(3);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: (context, VideoPlayerValue value, child) {
        final fullDuration = value.isInitialized ? value.duration : Duration.zero;
        final position = value.isInitialized ? value.position : Duration.zero;

        // Adjust position and duration based on the trim operation
        final trimStart = trimOp?.start ?? Duration.zero;
        final trimEnd = trimOp?.end ?? fullDuration;

        final displayPosition = (position - trimStart).isNegative ? Duration.zero : position - trimStart;
        final displayDuration = trimEnd - trimStart;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          color: const Color(0xFF1A1A1A),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_format(displayPosition), style: const TextStyle(color: Colors.white, fontSize: 12)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white, size: 28),
                onPressed: () {
                  final newPos = position - const Duration(milliseconds: 34);
                  controller.seekTo(newPos < trimStart ? trimStart : newPos);
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: Icon(value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white, size: 36),
                onPressed: () => value.isPlaying ? controller.pause() : controller.play(),
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.skip_next, color: Colors.white, size: 28),
                onPressed: () {
                  final newPos = position + const Duration(milliseconds: 34);
                  controller.seekTo(newPos > trimEnd ? trimEnd : newPos);
                },
              ),
              const Spacer(),
              Text(_format(displayDuration), style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        );
      },
    );
  }
}

// =================================================================
// D. TIMELINE WORKSPACE
// =================================================================
class _TimelineWorkspace extends StatelessWidget {
  final List<TimelineTrack> tracks;
  final VideoPlayerController controller;
  final ScrollController scrollController;
  final Function(DragStartDetails) onScrubStart;
  final Function(DragUpdateDetails) onScrubUpdate;
  final Function(DragEndDetails) onScrubEnd;
  final Function(DragStartDetails, TimelineClip, TimelineTrack, _DragInteractionType) onClipDragStart;
  final Function(DragUpdateDetails) onClipDragUpdate;
  final Function(DragEndDetails) onClipDragEnd;
  final double pixelsPerSecond;

  const _TimelineWorkspace({
    required this.tracks,
    required this.controller,
    required this.scrollController,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onClipDragStart,
    required this.onClipDragUpdate,
    required this.onClipDragEnd,
    required this.pixelsPerSecond,
  });

  @override
  Widget build(BuildContext context) {
    final totalDuration = controller.value.isInitialized ? controller.value.duration : const Duration(seconds: 30);
    final timelineWidth = totalDuration.inSeconds * pixelsPerSecond;

    return Container(
      color: const Color(0xFF222222),
      child: GestureDetector(
        onHorizontalDragStart: onScrubStart,
        onHorizontalDragUpdate: onScrubUpdate,
        onHorizontalDragEnd: onScrubEnd,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SingleChildScrollView(
              controller: scrollController,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: timelineWidth,
                child: ListView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: tracks.length,
                  itemBuilder: (context, index) {
                    return _TimelineTrackItem(
                      track: tracks[index],
                      pixelsPerSecond: pixelsPerSecond,
                      onClipDragStart: onClipDragStart,
                      onClipDragUpdate: onClipDragUpdate,
                      onClipDragEnd: onClipDragEnd,
                    );
                  },
                ),
              ),
            ),
            Container(width: 2, height: double.infinity, color: C.brand),
          ],
        ),
      ),
    );
  }
}

// =================================================================
// E. CONTEXT TOOLBAR
// =================================================================
class _ContextToolbar extends StatelessWidget {
  final MobileEditorTool activeTool;
  final TrimOperation? trimOp;
  final VideoPlayerController controller;
  final Function(Duration, Duration) onTrimChanged;
  final String activeFilter;
  final ValueChanged<String> onFilterSelected;
  const _ContextToolbar({
    required this.activeTool,
    this.trimOp,
    required this.controller,
    required this.onTrimChanged,
    required this.activeFilter,
    required this.onFilterSelected,
  });

  @override
  Widget build(BuildContext context) {
    switch (activeTool) {
      case MobileEditorTool.timeline:
        // The trim tool is shown when a video clip is selected on the timeline.
        if (trimOp != null) {
          return TrimTool(
            controller: controller,
            trimOperation: trimOp!,
            onTrimChanged: onTrimChanged,
          );
        }
        return const _ToolbarPlaceholder(tool: MobileEditorTool.timeline);
      case MobileEditorTool.text:
        return const TextTool();
      case MobileEditorTool.effects:
        return FilterTool(
          activeFilter: activeFilter,
          onFilterSelected: onFilterSelected,
        );
      // Placeholders for other tools
      case MobileEditorTool.media:
      case MobileEditorTool.audio:
      case MobileEditorTool.transitions:
      case MobileEditorTool.assets:
      case MobileEditorTool.settings:
        return _ToolbarPlaceholder(tool: activeTool);
    }
  }
}

class _TimelineTrackItem extends StatelessWidget {
  final TimelineTrack track;
  final double pixelsPerSecond;
  final Function(DragStartDetails, TimelineClip, TimelineTrack, _DragInteractionType) onClipDragStart;
  final Function(DragUpdateDetails) onClipDragUpdate;
  final Function(DragEndDetails) onClipDragEnd;

  const _TimelineTrackItem({
    required this.track,
    required this.pixelsPerSecond,
    required this.onClipDragStart,
    required this.onClipDragUpdate,
    required this.onClipDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: Stack(
        children: [
          Row(
            children: [
              Container(
                width: 80,
                color: Colors.black26,
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(track.icon, color: Colors.white70, size: 20),
                    const SizedBox(height: 4),
                    Text(track.label, style: dm(sz: 10, c: Colors.white70), overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Expanded(child: Container(color: Colors.black12))
            ],
          ),
          ...track.clips.map((clip) {
            final left = clip.start.inMilliseconds / 1000.0 * pixelsPerSecond;
            final width = clip.duration.inMilliseconds / 1000.0 * pixelsPerSecond;
            return Positioned(
              left: left,
              top: 5,
              bottom: 5,
              width: width,
              child: _TimelineClipItem(
                clip: clip,
                track: track,
                width: width,
                onDragStart: onClipDragStart,
                onDragUpdate: onClipDragUpdate,
                onDragEnd: onClipDragEnd,
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _TimelineClipItem extends StatelessWidget {
  final TimelineClip clip;
  final TimelineTrack track;
  final double width;
  final Function(DragStartDetails, TimelineClip, TimelineTrack, _DragInteractionType) onDragStart;
  final Function(DragUpdateDetails) onDragUpdate;
  final Function(DragEndDetails) onDragEnd;

  const _TimelineClipItem({
    required this.clip,
    required this.track,
    required this.width,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  static const double _handleWidth = 16.0;

  @override
  Widget build(BuildContext context) {
    Color clipColor;
    final isResizable = clip.operation.type == 'trim';

    switch (clip.operation.type) {
      case 'trim':
        clipColor = C.blue.withAlpha(179);
        break;
      case 'text':
        clipColor = C.purple.withAlpha(179);
        break;
      case 'audio':
        clipColor = C.green.withAlpha(179);
        break;
      default:
        clipColor = C.gold.withAlpha(179);
    }

    return GestureDetector(
      onHorizontalDragStart: (details) {
        final dx = details.localPosition.dx;
        _DragInteractionType type;
        if (dx < _handleWidth && isResizable) {
          type = _DragInteractionType.resizeStart;
        } else if (dx > (width - _handleWidth) && isResizable) {
          type = _DragInteractionType.resizeEnd;
        } else {
          type = _DragInteractionType.move;
        }
        onDragStart(details, clip, track, type);
      },
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: onDragEnd,
      child: Container(
        decoration: BoxDecoration(
          color: clipColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white.withAlpha(128), width: 1),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _handleWidth + 4),
              child: Text(
                clip.operation is TextOverlay ? (clip.operation as TextOverlay).text : clip.operation.type,
                style: dm(sz: 12, c: Colors.white),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (isResizable)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: _handleWidth,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(51),
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(3), bottomLeft: Radius.circular(3)),
                  ),
                  child: const Center(child: Icon(Icons.drag_handle, color: Colors.white54, size: 14)),
                ),
              ),
            if (isResizable)
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: _handleWidth,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(51),
                    borderRadius: const BorderRadius.only(topRight: Radius.circular(3), bottomRight: Radius.circular(3)),
                  ),
                  child: const Center(child: Icon(Icons.drag_handle, color: Colors.white54, size: 14)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =================================================================
// F. BOTTOM NAVIGATION
// =================================================================
class _BottomNavBar extends StatelessWidget {
  final MobileEditorTool activeTool;
  final ValueChanged<MobileEditorTool> onToolSelected;
  const _BottomNavBar({required this.activeTool, required this.onToolSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom, top: 8),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: MobileEditorTool.values.map((tool) {
          return IconButton(
            icon: Icon(_iconForTool(tool), color: activeTool == tool ? C.brand : Colors.white),
            onPressed: () => onToolSelected(tool),
          );
        }).toList(),
      ),
    );
  }

  IconData _iconForTool(MobileEditorTool tool) {
    switch (tool) {
      case MobileEditorTool.timeline: return Icons.timeline;
      case MobileEditorTool.media: return Icons.photo_library;
      case MobileEditorTool.audio: return Icons.audiotrack;
      case MobileEditorTool.text: return Icons.text_fields;
      case MobileEditorTool.effects: return Icons.auto_awesome;
      case MobileEditorTool.transitions: return Icons.transform;
      case MobileEditorTool.assets: return Icons.layers;
      case MobileEditorTool.settings: return Icons.settings;
    }
  }
}
// =================================================================
// FLOATING ACTION BUTTONS
// =================================================================
class _FloatingActionButtons extends StatelessWidget {
  const _FloatingActionButtons();

  @override
  Widget build(BuildContext context) {
    final bottomSafeArea = MediaQuery.of(context).padding.bottom;
    final fabBottomPosition = _kContextToolbarHeight + _kBottomNavBarEstHeight + bottomSafeArea + _kFabBottomMargin;
    return Positioned(
      bottom: fabBottomPosition,
      right: 16,
      child: Column(
        children: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.fullscreen, color: Colors.white, size: 28)),
          const SizedBox(height: 8),
          IconButton(onPressed: () {}, icon: const Icon(Icons.save_alt, color: Colors.white, size: 28)),
          const SizedBox(height: 8),
          IconButton(onPressed: () {}, icon: const Icon(Icons.preview, color: Colors.white, size: 28)),
          const SizedBox(height: 8),
          IconButton(onPressed: () {}, icon: const Icon(Icons.auto_fix_high, color: Colors.white, size: 28)),
        ],
      ),
    );
  }
}

/// A generic placeholder for an unimplemented toolbar.
class _ToolbarPlaceholder extends StatelessWidget {
  final MobileEditorTool tool;
  const _ToolbarPlaceholder({required this.tool});

  @override
  Widget build(BuildContext context) {
    final toolName = tool.name[0].toUpperCase() + tool.name.substring(1);
    return Container(
      height: _kContextToolbarHeight,
      color: const Color(0xFF1A1A1A),
      alignment: Alignment.center,
      child: Text('$toolName Toolbar', style: const TextStyle(color: Colors.white54)),
    );
  }
}