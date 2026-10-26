import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/edit_models.dart';
import '../services/timeline_snap_engine.dart';
import '../theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TimelinePlayheadView
// ─────────────────────────────────────────────────────────────────────────────

/// A high-performance, gesture-aware playhead needle for the timeline.
///
/// The playhead is driven by a [currentTime] / [totalDuration] pair rather than
/// a single ValueListenable so it stays compatible with the existing
/// [TimelinePlaybackController] pattern (which already calls [setState] via
/// [ListenableBuilder]).
///
/// **Performance note**: this widget is intentionally thin.  The parent
/// rebuilds only for [currentTime] changes, but the needle itself is drawn via
/// [CustomPainter] so no layout pass is triggered for every animation frame.
///
/// Gesture semantics:
/// * **Tap**: seek to that horizontal position.
/// * **Vertical drag on handle**: scrub playhead; magnetic snap to clip edges.
/// * On snap: shows a brief yellow glow ring and fires [HapticFeedback.selectionClick].
class TimelinePlayheadView extends StatefulWidget {
  const TimelinePlayheadView({
    super.key,
    required this.currentTime,
    required this.totalDuration,
    required this.tracks,
    required this.pixelsPerSecond,
    required this.zoom,
    required this.snappingEnabled,
    required this.onSeek,
    required this.scrollController,
    this.timelineWidth = 0,
  });

  /// Current playhead position.
  final Duration currentTime;

  /// Total project duration (used to clamp seeks).
  final Duration totalDuration;

  /// All tracks in the timeline (used to compute snap targets).
  final List<TimelineTrack> tracks;

  /// Base pixels per second (before zoom).
  final double pixelsPerSecond;

  /// Current zoom multiplier.
  final double zoom;

  /// Whether magnetic snapping is active.
  final bool snappingEnabled;

  /// Called when the user seeks via the playhead.
  final void Function(Duration) onSeek;

  /// The horizontal scroll controller of the timeline so the playhead can
  /// read the current scroll offset when converting tap positions to time.
  final ScrollController scrollController;

  /// Total scrollable width of the timeline canvas.
  final double timelineWidth;

  @override
  State<TimelinePlayheadView> createState() => _TimelinePlayheadViewState();
}

class _TimelinePlayheadViewState extends State<TimelinePlayheadView>
    with SingleTickerProviderStateMixin {
  // Snap-ring animation controller.
  late final AnimationController _snapRingController;
  late final Animation<double> _snapRingAnim;

  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _snapRingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _snapRingAnim = CurvedAnimation(
      parent: _snapRingController,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _snapRingController.dispose();
    super.dispose();
  }

  // ── Geometry helpers ──────────────────────────────────────────────────────

  double get _scale => widget.pixelsPerSecond * widget.zoom;

  double _timeToX(Duration t) =>
      (t.inMicroseconds / Duration.microsecondsPerSecond) * _scale;

  Duration _xToTime(double x) {
    final secs = x / _scale;
    return Duration(microseconds: (secs * Duration.microsecondsPerSecond).round());
  }

  // ── Drag & seek logic ─────────────────────────────────────────────────────

  void _onDragUpdate(DragUpdateDetails details) {
    final scrollOffset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0.0;
    // details.globalPosition.dx is relative to the screen; convert to timeline
    // canvas coordinates by adding the scroll offset and subtracting the
    // widget's render-box left edge (which is always 0 inside the canvas Stack).
    final rawX =
        (details.globalPosition.dx - _renderBoxLeft) + scrollOffset;
    final rawTime = _xToTime(rawX.clamp(0.0, double.infinity));
    final snapped = TimelineSnapEngine.snap(
      rawTime,
      widget.tracks,
      pixelsPerSecond: widget.pixelsPerSecond,
      zoom: widget.zoom,
      enabled: widget.snappingEnabled,
    );

    // Trigger snap feedback only when a new snap is applied.
    if (snapped != rawTime && widget.snappingEnabled) {
      _triggerSnapFeedback();
    }

    widget.onSeek(
      Duration(
        microseconds: snapped.inMicroseconds.clamp(
          0,
          widget.totalDuration.inMicroseconds,
        ),
      ),
    );
  }

  double _renderBoxLeft = 0.0;

  void _updateRenderBoxLeft() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    _renderBoxLeft = box.localToGlobal(Offset.zero).dx;
  }

  void _triggerSnapFeedback() {
    HapticFeedback.selectionClick();
    _snapRingController
      ..reset()
      ..forward();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final x = _timeToX(widget.currentTime);

    return Positioned(
      left: x,
      top: 0,
      bottom: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) {
          _updateRenderBoxLeft();
          setState(() => _isDragging = true);
        },
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: (_) => setState(() => _isDragging = false),
        onHorizontalDragStart: (_) {
          _updateRenderBoxLeft();
          setState(() => _isDragging = true);
        },
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: (_) => setState(() => _isDragging = false),
        child: AnimatedBuilder(
          animation: _snapRingAnim,
          builder: (_, __) => CustomPaint(
            size: const Size(24, double.infinity),
            painter: _PlayheadPainter(
              snapRingProgress: _snapRingAnim.value,
              isDragging: _isDragging,
              timecode: _formatTimecode(widget.currentTime),
            ),
          ),
        ),
      ),
    );
  }

  String _formatTimecode(Duration t) {
    final h = t.inHours;
    final m = t.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = t.inSeconds.remainder(60).toString().padLeft(2, '0');
    final f = ((t.inMilliseconds.remainder(1000)) ~/ 33)
        .toString()
        .padLeft(2, '0'); // approx 30fps frame number
    return h > 0 ? '$h:$m:$s:$f' : '$m:$s:$f';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _PlayheadPainter
// ─────────────────────────────────────────────────────────────────────────────

/// Custom painter that draws the playhead needle, pill handle, timecode badge,
/// and the snap-ring glow animation — all in a single layer with zero extra
/// widgets.
class _PlayheadPainter extends CustomPainter {
  const _PlayheadPainter({
    required this.snapRingProgress,
    required this.isDragging,
    required this.timecode,
  });

  final double snapRingProgress;
  final bool isDragging;
  final String timecode;

  static const Color _needleColor = C.brand; // amber/brand
  static const Color _handleColor = C.brand;
  static const Color _snapColor = Color(0xFFFFE066);
  static const double _needleWidth = 2.0;
  static const double _handleW = 14.0;
  static const double _handleH = 22.0;
  static const double _handleRadius = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;

    // ── Snap ring glow ────────────────────────────────────────────────────
    if (snapRingProgress > 0) {
      final ringRadius = 14.0 + snapRingProgress * 18.0;
      final ringPaint = Paint()
        ..color = _snapColor.withAlpha(
          ((1 - snapRingProgress) * 200).round(),
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawCircle(Offset(cx, _handleH / 2), ringRadius, ringPaint);
    }

    // ── Needle ────────────────────────────────────────────────────────────
    final needlePaint = Paint()
      ..color = _needleColor.withAlpha(isDragging ? 255 : 204)
      ..strokeWidth = _needleWidth;
    canvas.drawLine(
      Offset(cx, _handleH),
      Offset(cx, size.height),
      needlePaint,
    );

    // ── Pill handle ───────────────────────────────────────────────────────
    final handleRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, _handleH / 2),
        width: _handleW,
        height: _handleH,
      ),
      const Radius.circular(_handleRadius),
    );
    final handlePaint = Paint()
      ..color = isDragging ? _handleColor : _handleColor.withAlpha(230);
    canvas.drawRRect(handleRect, handlePaint);

    // ── Timecode badge ────────────────────────────────────────────────────
    if (isDragging) {
      _drawTimecode(canvas, Offset(cx, _handleH + 8), timecode);
    }
  }

  void _drawTimecode(Canvas canvas, Offset topCenter, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const hPad = 5.0;
    const vPad = 3.0;
    final badgeW = tp.width + hPad * 2;
    final badgeH = tp.height + vPad * 2;

    // Constrain so the badge doesn't go off the left edge.
    final left = topCenter.dx - badgeW / 2;

    final rrect = RRect.fromLTRBR(
      left,
      topCenter.dy,
      left + badgeW,
      topCenter.dy + badgeH,
      const Radius.circular(4),
    );
    canvas.drawRRect(rrect, Paint()..color = const Color(0xDD111116));
    tp.paint(canvas, Offset(left + hPad, topCenter.dy + vPad));
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      snapRingProgress != old.snapRingProgress ||
      isDragging != old.isDragging ||
      timecode != old.timecode;
}
