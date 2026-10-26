import 'dart:math' as math;

import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TimelineRulerView
// ─────────────────────────────────────────────────────────────────────────────

/// An adaptive, multi-scale ruler for the timeline.
///
/// The ruler auto-selects major / minor tick intervals based on the current
/// zoom level so that ticks are never so dense they overlap, and never so
/// sparse they become uninformative.
///
/// Drawn entirely via [CustomPainter] — zero widget overhead.
class TimelineRulerView extends StatelessWidget {
  const TimelineRulerView({
    super.key,
    required this.totalDuration,
    required this.pixelsPerSecond,
    required this.zoom,
    this.height = 22.0,
    this.width,
  });

  /// Total project duration — used to know how many ticks to draw.
  final Duration totalDuration;

  /// Base pixels per second (before zoom).
  final double pixelsPerSecond;

  /// Current zoom multiplier.
  final double zoom;

  /// Height of the ruler bar.
  final double height;

  /// Explicit width override. If null, uses the available constraint width.
  final double? width;

  @override
  Widget build(BuildContext context) {
    final effectiveWidth =
        width ??
        math.max(
          totalDuration.inSeconds * pixelsPerSecond * zoom + 64,
          MediaQuery.of(context).size.width,
        );

    return SizedBox(
      height: height,
      width: effectiveWidth,
      child: CustomPaint(
        painter: _RulerPainter(
          totalDuration: totalDuration,
          pixelsPerSecond: pixelsPerSecond,
          zoom: zoom,
          height: height,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _RulerPainter
// ─────────────────────────────────────────────────────────────────────────────

class _RulerPainter extends CustomPainter {
  const _RulerPainter({
    required this.totalDuration,
    required this.pixelsPerSecond,
    required this.zoom,
    required this.height,
  });

  final Duration totalDuration;
  final double pixelsPerSecond;
  final double zoom;
  final double height;

  // ── Tick-interval selection ───────────────────────────────────────────────

  /// Minimum desired pixel spacing between major ticks.
  static const double _minMajorPx = 60.0;

  /// Returns the major/minor interval (in seconds) for the current scale.
  ///
  /// Candidate intervals (seconds): 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600
  static ({double major, double minor}) _pickIntervals(double pxPerSec) {
    const candidates = <(double major, double minor)>[
      (0.1, 0.025),
      (0.25, 0.05),
      (0.5, 0.1),
      (1.0, 0.25),
      (2.0, 0.5),
      (5.0, 1.0),
      (10.0, 2.0),
      (30.0, 5.0),
      (60.0, 10.0),
      (120.0, 30.0),
      (300.0, 60.0),
      (600.0, 120.0),
    ];

    for (final (major, minor) in candidates) {
      if (major * pxPerSec >= _minMajorPx) {
        return (major: major, minor: minor);
      }
    }
    // Fallback for extremely zoomed-out views.
    return (major: 600.0, minor: 120.0);
  }

  // ── Formatting ────────────────────────────────────────────────────────────

  static String _label(double seconds) {
    if (seconds < 60) {
      // Show sub-second precision only when intervals are very fine.
      if (seconds < 1 && seconds != seconds.truncate()) {
        return '${seconds.toStringAsFixed(2)}s';
      }
      return '${seconds.toStringAsFixed(0)}s';
    }
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toStringAsFixed(0).padLeft(2, '0');
    return '$m:$s';
  }

  // ── Paint ─────────────────────────────────────────────────────────────────

  @override
  void paint(Canvas canvas, Size size) {
    final scale = pixelsPerSecond * zoom;
    final intervals = _pickIntervals(scale);

    final tickPaintMajor = Paint()
      ..color = const Color(0xFF6B7280)  // C.dim-ish
      ..strokeWidth = 1.0;
    final tickPaintMinor = Paint()
      ..color = const Color(0xFF374151)
      ..strokeWidth = 0.75;

    // Background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF0D0D12),
    );

    // Bottom border line
    canvas.drawLine(
      Offset(0, size.height - 0.5),
      Offset(size.width, size.height - 0.5),
      Paint()
        ..color = const Color(0xFF1F2937)
        ..strokeWidth = 1,
    );

    final totalSecs =
        totalDuration.inMicroseconds / Duration.microsecondsPerSecond;
    final totalWidth = totalSecs * scale;
    final drawWidth = math.max(size.width, totalWidth + 64);

    final minorStep = intervals.minor;
    final majorStep = intervals.major;

    double t = 0.0;
    while (t <= drawWidth / scale + majorStep) {
      final x = t * scale;
      if (x > size.width + 4) break;

      final isMajor = (t % majorStep).abs() < minorStep * 0.5;

      if (isMajor) {
        // Major tick
        final tickTop = size.height * 0.35;
        canvas.drawLine(
          Offset(x, tickTop),
          Offset(x, size.height - 1),
          tickPaintMajor,
        );

        // Label
        final label = _label(t);
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w500,
              color: Color(0xFF9CA3AF),
              letterSpacing: 0.2,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Pin label just right of the tick, but never overflow the canvas.
        final labelX = (x + 3.0).clamp(0.0, size.width - tp.width - 2);
        tp.paint(canvas, Offset(labelX, 2.0));
      } else {
        // Minor tick
        final tickTop = size.height * 0.60;
        canvas.drawLine(
          Offset(x, tickTop),
          Offset(x, size.height - 1),
          tickPaintMinor,
        );
      }

      t += minorStep;
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      totalDuration != old.totalDuration ||
      pixelsPerSecond != old.pixelsPerSecond ||
      zoom != old.zoom ||
      height != old.height;
}
