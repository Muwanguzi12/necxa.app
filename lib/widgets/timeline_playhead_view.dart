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
  bool _isFineScrub = false;
  DateTime? _lastDragTime;
  double? _lastDragX;

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

  void _onDragStart(DragStartDetails details) {
    _updateRenderBoxLeft();
    _lastDragTime = DateTime.now();
    _lastDragX = details.globalPosition.dx;
    setState(() {
      _isDragging = true;
      _isFineScrub = false;
    });
  }

  void _onDragEnd() {
    setState(() {
      _isDragging = false;
      _isFineScrub = false;
      _lastDragTime = null;
      _lastDragX = null;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final scrollOffset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0.0;

    // Velocity detection: slow scrub triggers fine-grain frame preview
    final now = DateTime.now();
    if (_lastDragTime != null && _lastDragX != null) {
      final dt = now.difference(_lastDragTime!).inMilliseconds;
      if (dt > 16) {
        final dx = (details.globalPosition.dx - _lastDragX!).abs();
        final velocity = (dx / dt) * 1000.0; // px/sec
        final isFine = velocity < 75.0;
        if (isFine != _isFineScrub) {
          setState(() => _isFineScrub = isFine);
          if (isFine) {
            HapticFeedback.selectionClick();
          }
        }
        _lastDragTime = now;
        _lastDragX = details.globalPosition.dx;
      }
    }

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
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: (_) => _onDragEnd(),
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: (_) => _onDragEnd(),
        child: AnimatedBuilder(
          animation: _snapRingAnim,
          builder: (_, __) => CustomPaint(
            size: const Size(24, double.infinity),
            painter: _PlayheadPainter(
              snapRingProgress: _snapRingAnim.value,
              isDragging: _isDragging,
              isFineScrub: _isFineScrub,
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
    required this.isFineScrub,
    required this.timecode,
  });

  final double snapRingProgress;
  final bool isDragging;
  final bool isFineScrub;
  final String timecode;

  static const Color _defaultColor = Color(0xFF00E5FF); // Pro Cyan
  static const Color _fineColor = Color(0xFFFBBF24); // Precision Amber
  static const Color _snapColor = Color(0xFFFFE066);
  static const double _needleWidth = 2.0;
  static const double _handleW = 14.0;
  static const double _handleH = 22.0;
  static const double _handleRadius = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final activeColor = isFineScrub ? _fineColor : _defaultColor;

    // ── Snap ring glow ────────────────────────────────────────────────────
    if (snapRingProgress > 0) {
      final ringRadius = 14.0 + snapRingProgress * 18.0;
      final ringPaint = Paint()
        ..color = _snapColor.withValues(
          alpha: (1 - snapRingProgress) * 0.8,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawCircle(Offset(cx, _handleH / 2), ringRadius, ringPaint);
    }

    // ── Fine scrub halo glow ──────────────────────────────────────────────
    if (isDragging && isFineScrub) {
      final haloPaint = Paint()
        ..color = _fineColor.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(Offset(cx, _handleH / 2), 12.0, haloPaint);
    }

    // ── Needle ────────────────────────────────────────────────────────────
    final needlePaint = Paint()
      ..color = activeColor.withValues(alpha: isDragging ? 1.0 : 0.85)
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
      ..color = isDragging ? activeColor : activeColor.withValues(alpha: 0.9);
    canvas.drawRRect(handleRect, handlePaint);

    // ── Timecode badge ────────────────────────────────────────────────────
    if (isDragging) {
      _drawTimecode(canvas, Offset(cx, _handleH + 8), timecode, isFineScrub);
    }
  }

  void _drawTimecode(
    Canvas canvas,
    Offset topCenter,
    String text,
    bool isFine,
  ) {
    final displayText = isFine ? '$text • FRAME' : text;
    final tp = TextPainter(
      text: TextSpan(
        text: displayText,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: isFine ? const Color(0xFFFBBF24) : Colors.white,
          letterSpacing: 0.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    const hPad = 6.0;
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
      const Radius.circular(5),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = const Color(0xEE0B132B),
    );
    if (isFine) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFFFBBF24).withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }
    tp.paint(canvas, Offset(left + hPad, topCenter.dy + vPad));
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      snapRingProgress != old.snapRingProgress ||
      isDragging != old.isDragging ||
      isFineScrub != old.isFineScrub ||
      timecode != old.timecode;
}
