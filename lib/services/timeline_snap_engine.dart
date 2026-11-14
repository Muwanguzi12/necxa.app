import '../models/edit_models.dart';

/// A stateless magnetic-snapping engine for the timeline.
///
/// Given a raw [Duration] time, a set of [TimelineTrack]s, and the current
/// zoom/scale, [snap] returns either the input time (if no snap target is
/// within the physical threshold) or the nearest snap target time.
///
/// Snap targets are the In-point and Out-point of every non-hidden,
/// non-locked clip across all visible tracks.
class TimelineSnapEngine {
  /// Physical pixel distance within which a snap is triggered.
  static const double snapThresholdPx = 11.0;

  TimelineSnapEngine._();

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the snapped [Duration] closest to [rawTime], or [rawTime] itself
  /// if no snap target is within [snapThresholdPx] physical pixels.
  ///
  /// [pixelsPerSecond] × [zoom] gives the effective pixels-per-second scale.
  /// [enabled] can be set to false to pass [rawTime] through unchanged.
  static Duration snap(
    Duration rawTime,
    List<TimelineTrack> tracks, {
    required double pixelsPerSecond,
    required double zoom,
    bool enabled = true,
  }) {
    if (!enabled) return rawTime;

    final scale = pixelsPerSecond * zoom;
    if (scale <= 0) return rawTime;

    final thresholdUs =
        (snapThresholdPx / scale * Duration.microsecondsPerSecond).round();

    Duration? best;
    int bestDist = thresholdUs + 1;

    for (final target in collectSnapTargets(tracks)) {
      final dist = (target.inMicroseconds - rawTime.inMicroseconds).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = target;
      }
    }

    return best ?? rawTime;
  }

  /// Returns true iff [rawTime] would snap to a different value under the
  /// current scale. Useful for rendering the snap indicator ring.
  static bool wouldSnap(
    Duration rawTime,
    List<TimelineTrack> tracks, {
    required double pixelsPerSecond,
    required double zoom,
  }) {
    final snapped = snap(
      rawTime,
      tracks,
      pixelsPerSecond: pixelsPerSecond,
      zoom: zoom,
    );
    return snapped != rawTime;
  }

  /// Collects all snap-target [Duration]s from the given tracks.
  ///
  /// Each clip contributes two targets:
  ///   * its [TimelineClip.start] (In-point)
  ///   * its `start + duration` (Out-point)
  ///
  /// Hidden and locked clips are excluded as snap targets because they are not
  /// visible to the user.
  static List<Duration> collectSnapTargets(List<TimelineTrack> tracks) {
    final targets = <Duration>[];
    for (final track in tracks) {
      if (!track.isVisible) continue;
      for (final clip in track.clips) {
        if (clip.isHidden) continue;
        targets.add(clip.start);
        targets.add(clip.start + clip.duration);
      }
    }
    // De-duplicate by sorting and removing exact duplicates.
    targets.sort();
    for (var i = targets.length - 1; i > 0; i--) {
      if (targets[i] == targets[i - 1]) targets.removeAt(i);
    }
    return targets;
  }
}
