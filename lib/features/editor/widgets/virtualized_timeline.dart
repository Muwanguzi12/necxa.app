import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../../models/edit_models.dart';

/// Virtualized timeline widget that only renders visible clips
/// This dramatically improves performance with large clip counts
class VirtualizedTimeline extends StatefulWidget {
  final List<TimelineTrack> tracks;
  final double timelineWidth;
  final double timelineHeight;
  final double pixelsPerSecond;
  final Function(TimelineClip, TimelineTrack)? onClipTap;
  final Function(TimelineClip, TimelineTrack)? onClipLongPress;
  final Widget Function(TimelineClip, TimelineTrack)? clipBuilder;
  final Widget Function(TimelineTrack)? trackHeaderBuilder;
  final Duration playheadPosition;
  final bool showPlayhead;
  final bool rippleMode;
  final bool snappingEnabled;
  final double snapThresholdPixels;
  final ValueChanged<List<TimelineTrack>>? onTimelineChanged;
  final void Function(TimelineClip, TimelineTrack, Duration)? onClipMoved;
  final void Function(TimelineClip, TimelineTrack, Duration, Duration)? onClipTrimmed;

  const VirtualizedTimeline({
    super.key,
    required this.tracks,
    required this.timelineWidth,
    required this.timelineHeight,
    required this.pixelsPerSecond,
    this.onClipTap,
    this.onClipLongPress,
    this.clipBuilder,
    this.trackHeaderBuilder,
    this.playheadPosition = Duration.zero,
    this.showPlayhead = true,
    this.rippleMode = true,
    this.snappingEnabled = true,
    this.snapThresholdPixels = 10,
    this.onTimelineChanged,
    this.onClipMoved,
    this.onClipTrimmed,
  });

  @override
  State<VirtualizedTimeline> createState() => _VirtualizedTimelineState();
}

class _VirtualizedTimelineState extends State<VirtualizedTimeline> {
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  final GlobalKey _timelineKey = GlobalKey();
  
  // Visible range tracking
  double _visibleStartSeconds = 0;
  double _visibleEndSeconds = 0;

  String? _dragClipId;
  TimelineTrack? _dragTrack;
  String? _dragMode;
  double _dragOriginGlobalX = 0;
  Duration _originalStart = Duration.zero;
  Duration _originalDuration = Duration.zero;
  Duration _originalSourceStart = Duration.zero;
  Duration? _originalSourceEnd;
  Duration _lastAppliedDelta = Duration.zero;
  
  @override
  void initState() {
    super.initState();
    _horizontalScrollController.addListener(_onHorizontalScroll);
    _verticalScrollController.addListener(_onVerticalScroll);
    
    // Initial visible range calculation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateVisibleRange();
    });
  }

  void _onHorizontalScroll() {
    _updateVisibleRange();
  }

  void _onVerticalScroll() {
    // Trigger rebuild for visible tracks
    setState(() {});
  }

  void _updateVisibleRange() {
    if (!mounted) return;
    
    final renderObject = _timelineKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox) {
      final scrollOffset = _horizontalScrollController.offset;
      final viewportWidth = renderObject.size.width;
      
      _visibleStartSeconds = scrollOffset / widget.pixelsPerSecond;
      _visibleEndSeconds = (scrollOffset + viewportWidth) / widget.pixelsPerSecond;
      
      // Add buffer for smoother scrolling
      const bufferSeconds = 5.0;
      _visibleStartSeconds = (_visibleStartSeconds - bufferSeconds).clamp(0, double.infinity);
      _visibleEndSeconds += bufferSeconds;
      
      setState(() {});
    }
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalDuration = _calculateTotalDuration();
    final contentWidth = totalDuration * widget.pixelsPerSecond;
    
    return Column(
      children: [
        // Timeline header (time markers)
        _buildTimelineHeader(contentWidth),
        
        // Scrollable timeline content
        Expanded(
          child: SingleChildScrollView(
            controller: _verticalScrollController,
            child: SizedBox(
              height: widget.tracks.length * widget.timelineHeight,
              child: SingleChildScrollView(
                controller: _horizontalScrollController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: contentWidth.clamp(widget.timelineWidth, double.infinity),
                  child: Stack(
                    key: _timelineKey,
                    children: [
                      // Virtualized tracks
                      ..._buildVirtualizedTracks(),
                      
                      // Playhead
                      if (widget.showPlayhead)
                        _buildPlayhead(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimelineHeader(double contentWidth) {
    return SizedBox(
      height: 30,
      child: SingleChildScrollView(
        controller: _horizontalScrollController,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: contentWidth.clamp(widget.timelineWidth, double.infinity),
          child: CustomPaint(
            size: Size(contentWidth, 30),
            painter: _TimelineHeaderPainter(
              pixelsPerSecond: widget.pixelsPerSecond,
              totalDuration: _calculateTotalDuration(),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildVirtualizedTracks() {
    final visibleTracks = _getVisibleTracks();
    
    return visibleTracks.map((trackData) {
      final track = trackData.track;
      final index = trackData.index;
      final visibleClips = _getVisibleClips(track);
      
      return Positioned(
        top: index * widget.timelineHeight,
        left: 0,
        right: 0,
        height: widget.timelineHeight,
        child: Stack(
          children: [
            // Track background
            Container(
              height: widget.timelineHeight,
              decoration: BoxDecoration(
                color: track.isLocked 
                    ? Colors.grey[800] 
                    : Colors.grey[700],
                border: Border(
                  bottom: BorderSide(color: Colors.grey[600]!),
                ),
              ),
              child: widget.trackHeaderBuilder?.call(track) ?? _buildDefaultTrackHeader(track),
            ),
            
            // Virtualized clips
            ...visibleClips.map((clip) {
              final clipX = clip.start.inSeconds * widget.pixelsPerSecond;
              final clipWidth = clip.duration.inMilliseconds / 1000 * widget.pixelsPerSecond;
              
              return Positioned(
                left: clipX,
                top: 4,
                width: clipWidth.clamp(24.0, double.infinity),
                height: widget.timelineHeight - 8,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onClipTap?.call(clip, track),
                  onLongPress: () => widget.onClipLongPress?.call(clip, track),
                  onPanStart: (details) => _beginClipDrag(
                    clip, track, details.localPosition.dx, details.globalPosition.dx,
                  ),
                  onPanUpdate: (details) => _updateClipDrag(details.globalPosition.dx),
                  onPanEnd: (_) => _finishClipDrag(),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.clipBuilder?.call(clip, track) ?? _buildDefaultClip(clip, track),
                      Positioned(left: 0, top: 0, bottom: 0, width: 12,
                        child: IgnorePointer(child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.22),
                            borderRadius: const BorderRadius.horizontal(left: Radius.circular(4)),
                          ),
                          child: const Center(child: Icon(Icons.drag_indicator, size: 11, color: Colors.white)),
                        )),
                      ),
                      Positioned(right: 0, top: 0, bottom: 0, width: 12,
                        child: IgnorePointer(child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.22),
                            borderRadius: const BorderRadius.horizontal(right: Radius.circular(4)),
                          ),
                          child: const Center(child: Icon(Icons.drag_indicator, size: 11, color: Colors.white)),
                        )),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      );
    }).toList();
  }

  void _beginClipDrag(
    TimelineClip clip,
    TimelineTrack track,
    double localX,
    double globalX,
  ) {
    if (track.isLocked) return;
    _dragClipId = clip.id;
    _dragTrack = track;
    _dragMode = localX <= 14
        ? 'trim-start'
        : (localX >= clip.duration.inMilliseconds / 1000 * widget.pixelsPerSecond - 14
            ? 'trim-end'
            : 'move');
    _dragOriginGlobalX = globalX;
    _originalStart = clip.start;
    _originalDuration = clip.duration;
    _originalSourceStart = clip.sourceStart;
    _originalSourceEnd = clip.sourceEnd;
    _lastAppliedDelta = Duration.zero;
  }

  void _updateClipDrag(double globalX) {
    final id = _dragClipId;
    final track = _dragTrack;
    final mode = _dragMode;
    if (id == null || track == null || mode == null || widget.pixelsPerSecond <= 0) return;
    final matches = track.clips.where((item) => item.id == id);
    if (matches.isEmpty) return;
    final clip = matches.first;

    final deltaMs = ((globalX - _dragOriginGlobalX) / widget.pixelsPerSecond * 1000).round();
    final delta = Duration(milliseconds: deltaMs);
    final minDuration = const Duration(milliseconds: 100);

    if (mode == 'move') {
      var target = _originalStart + delta;
      if (target < Duration.zero) target = Duration.zero;
      if (widget.snappingEnabled) target = _snapStart(clip, track, target);
      clip.start = target;
      _lastAppliedDelta = target - _originalStart;
    } else if (mode == 'trim-start') {
      // A clip shorter than the minimum trim length cannot be trimmed further.
      final maxTrimMs = (_originalDuration - minDuration).inMilliseconds;
      if (maxTrimMs < 0 || clip.speed <= 0) return;
      final applied = delta.inMilliseconds
          .clamp(-_originalStart.inMilliseconds, maxTrimMs)
          .toInt();
      final appliedDuration = Duration(milliseconds: applied);
      var newSourceStart = _originalSourceStart +
          Duration(milliseconds: (applied * clip.speed).round());
      if (newSourceStart < Duration.zero) newSourceStart = Duration.zero;
      final preservedSourceEnd = _originalSourceEnd ??
          (_originalSourceStart +
              Duration(milliseconds: (_originalDuration.inMilliseconds * clip.speed).round()));
      clip.start = _originalStart;
      clip.duration = _originalDuration - appliedDuration;
      clip.sourceStart = newSourceStart;
      clip.sourceEnd = preservedSourceEnd;
      if (clip.operation is TrimOperation) {
        final trim = clip.operation as TrimOperation;
        trim.start = newSourceStart;
        trim.end = preservedSourceEnd;
      }
      _lastAppliedDelta = clip.duration - _originalDuration;
    } else {
      if (clip.speed <= 0) return;
      final minimumDeltaMs = -(_originalDuration - minDuration).inMilliseconds;
      final originalSourceEnd = _originalSourceEnd ??
          (_originalSourceStart +
              Duration(milliseconds: (_originalDuration.inMilliseconds * clip.speed).round()));
      final maximumSourceEnd = clip.operation is TrimOperation
          ? (clip.operation as TrimOperation).maxDuration
          : originalSourceEnd;
      final availableSourceMs =
          (maximumSourceEnd - clip.sourceStart).inMilliseconds;
      final maximumDurationMs = (availableSourceMs / clip.speed).floor();
      final maximumDeltaMs = math.max(
        0,
        maximumDurationMs - _originalDuration.inMilliseconds,
      );
      if (maximumDeltaMs <= 0 && delta.inMilliseconds > 0) return;
      final applied = delta.inMilliseconds
          .clamp(minimumDeltaMs, maximumDeltaMs)
          .toInt();
      final nextDuration = _originalDuration + Duration(milliseconds: applied);
      final nextSourceEnd = clip.sourceStart +
          Duration(milliseconds: (nextDuration.inMilliseconds * clip.speed).round());
      clip.duration = nextDuration;
      clip.sourceEnd = nextSourceEnd;
      if (clip.operation is TrimOperation) {
        (clip.operation as TrimOperation).end = nextSourceEnd;
      }
      _lastAppliedDelta = nextDuration - _originalDuration;
    }

    setState(() {});
  }

  Duration _snapStart(TimelineClip moving, TimelineTrack track, Duration target) {
    final candidates = <Duration>[widget.playheadPosition];
    for (final other in track.clips) {
      if (other.id == moving.id) continue;
      candidates
        ..add(other.start)
        ..add(other.start + other.duration);
    }
    final threshold = Duration(
      milliseconds: (widget.snapThresholdPixels / widget.pixelsPerSecond * 1000).round(),
    );
    var best = target;
    var bestDistance = threshold.inMilliseconds + 1;
    for (final candidate in candidates) {
      final distance = (candidate - target).inMilliseconds.abs();
      if (distance <= bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    return best;
  }

  void _finishClipDrag() {
    final id = _dragClipId;
    final track = _dragTrack;
    final mode = _dragMode;
    if (id == null || track == null || mode == null) return;
    final matches = track.clips.where((item) => item.id == id);
    if (matches.isNotEmpty) {
      final clip = matches.first;
      if (mode == 'move') {
        widget.onClipMoved?.call(clip, track, clip.start);
      } else {
        if (widget.rippleMode && mode != 'move') {
          final oldEnd = _originalStart + _originalDuration;
          final newEnd = clip.start + clip.duration;
          final endShift = newEnd - oldEnd;
          if (endShift != Duration.zero) {
            for (final other in track.clips) {
              if (other.id != clip.id && other.start >= oldEnd) {
                other.start += endShift;
                if (other.start < Duration.zero) other.start = Duration.zero;
              }
            }
          }
        }
        widget.onClipTrimmed?.call(
          clip, track, clip.sourceStart, clip.sourceEnd ?? (clip.sourceStart + Duration(milliseconds: (clip.duration.inMilliseconds * clip.speed).round())),
        );
      }
      track.clips.sort((a, b) => a.start.compareTo(b.start));
      widget.onTimelineChanged?.call(widget.tracks);
    }
    _dragClipId = null;
    _dragTrack = null;
    _dragMode = null;
    _lastAppliedDelta = Duration.zero;
    setState(() {});
  }

  void deleteClip(TimelineClip clip, TimelineTrack track) {
    if (track.isLocked) return;
    final removedStart = clip.start;
    final removedDuration = clip.duration;
    track.clips.removeWhere((item) => item.id == clip.id);
    if (widget.rippleMode) {
      for (final other in track.clips) {
        if (other.start >= removedStart + removedDuration) {
          other.start -= removedDuration;
        }
      }
    }
    widget.onTimelineChanged?.call(widget.tracks);
    setState(() {});
  }

  Widget _buildDefaultTrackHeader(TimelineTrack track) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(
            track.icon,
            size: 16,
            color: track.isLocked ? Colors.grey : Colors.white,
          ),
          const SizedBox(width: 8),
          Text(
            track.label,
            style: TextStyle(
              color: track.isLocked ? Colors.grey : Colors.white,
              fontSize: 12,
            ),
          ),
          if (!track.isVisible) ...[
            const Spacer(),
            const Icon(Icons.visibility_off, size: 16, color: Colors.grey),
          ],
        ],
      ),
    );
  }

  Widget _buildDefaultClip(TimelineClip clip, TimelineTrack track) {
    return Container(
      decoration: BoxDecoration(
        color: _getClipColor(track.type),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.white.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Text(
          clip.id,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            overflow: TextOverflow.ellipsis,
          ),
          maxLines: 1,
        ),
      ),
    );
  }

  Widget _buildPlayhead() {
    final playheadX = widget.playheadPosition.inMilliseconds / 1000 * widget.pixelsPerSecond;
    
    return Positioned(
      left: playheadX,
      top: 0,
      bottom: 0,
      child: Container(
        width: 2,
        color: Colors.red,
        child: CustomPaint(
          size: const Size(2, double.infinity),
          painter: _PlayheadPainter(),
        ),
      ),
    );
  }

  Color _getClipColor(TrackType type) {
    switch (type) {
      case TrackType.video:
        return Colors.blue[700]!;
      case TrackType.audio:
        return Colors.green[700]!;
      case TrackType.text:
        return Colors.orange[700]!;
      default:
        return Colors.grey[700]!;
    }
  }

  double _calculateTotalDuration() {
    double maxDuration = 0;
    for (final track in widget.tracks) {
      for (final clip in track.clips) {
        final clipEnd = clip.start.inMilliseconds / 1000 + clip.duration.inMilliseconds / 1000;
        if (clipEnd > maxDuration) {
          maxDuration = clipEnd;
        }
      }
    }
    return maxDuration;
  }

  List<_TrackData> _getVisibleTracks() {
    if (_verticalScrollController.hasClients) {
      final viewportHeight = _verticalScrollController.position.viewportDimension;
      final scrollOffset = _verticalScrollController.offset;
      
      final startIndex = (scrollOffset / widget.timelineHeight).floor().clamp(0, widget.tracks.length - 1);
      final endIndex = ((scrollOffset + viewportHeight) / widget.timelineHeight).ceil().clamp(0, widget.tracks.length);
      
      final visibleTracks = <_TrackData>[];
      for (int i = startIndex; i < endIndex; i++) {
        visibleTracks.add(_TrackData(widget.tracks[i], i));
      }
      
      return visibleTracks;
    }
    
    // Fallback: return all tracks
    return widget.tracks
        .asMap()
        .entries
        .map((e) => _TrackData(e.value, e.key))
        .toList();
  }

  List<TimelineClip> _getVisibleClips(TimelineTrack track) {
    return track.clips.where((clip) {
      final clipStart = clip.start.inMilliseconds / 1000;
      final clipEnd = clipStart + clip.duration.inMilliseconds / 1000;
      
      // Check if clip overlaps with visible range
      return clipEnd >= _visibleStartSeconds && clipStart <= _visibleEndSeconds;
    }).toList();
  }
}

/// Data class for track with index
class _TrackData {
  final TimelineTrack track;
  final int index;
  
  _TrackData(this.track, this.index);
}

/// Custom painter for timeline header (time markers)
class _TimelineHeaderPainter extends CustomPainter {
  final double pixelsPerSecond;
  final double totalDuration;

  _TimelineHeaderPainter({
    required this.pixelsPerSecond,
    required this.totalDuration,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Determine marker interval based on zoom level
    double interval = _calculateInterval();
    
    // Draw time markers
    for (double time = 0; time <= totalDuration; time += interval) {
      final x = time * pixelsPerSecond;
      
      if (x > size.width) break;
      
      // Draw major tick
      canvas.drawLine(
        Offset(x, size.height - 10),
        Offset(x, size.height),
        paint,
      );
      
      // Draw time label
      final textPainter = TextPainter(
        text: TextSpan(
          text: _formatTime(Duration(seconds: time.toInt())),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, size.height - 22));
    }
  }

  double _calculateInterval() {
    // Adjust interval based on zoom level for optimal density
    if (pixelsPerSecond < 5) return 60; // Every minute
    if (pixelsPerSecond < 20) return 30; // Every 30 seconds
    if (pixelsPerSecond < 50) return 10; // Every 10 seconds
    if (pixelsPerSecond < 100) return 5; // Every 5 seconds
    return 1; // Every second
  }

  String _formatTime(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  bool shouldRepaint(_TimelineHeaderPainter oldDelegate) {
    return oldDelegate.pixelsPerSecond != pixelsPerSecond ||
           oldDelegate.totalDuration != totalDuration;
  }
}

/// Custom painter for playhead
class _PlayheadPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    // Draw triangle at top
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, 10)
      ..lineTo(0, 10)
      ..close();
    
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_PlayheadPainter oldDelegate) => false;
}
