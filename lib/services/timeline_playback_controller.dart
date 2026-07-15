import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/edit_models.dart';

@immutable
class TimelinePlaybackState {
  final Duration currentTime;
  final Duration duration;
  final bool isPlaying;
  final bool isSeeking;
  final double playbackRate;
  final Set<String> activeClipIds;

  const TimelinePlaybackState({
    this.currentTime = Duration.zero,
    this.duration = Duration.zero,
    this.isPlaying = false,
    this.isSeeking = false,
    this.playbackRate = 1,
    this.activeClipIds = const <String>{},
  });

  TimelinePlaybackState copyWith({
    Duration? currentTime,
    Duration? duration,
    bool? isPlaying,
    bool? isSeeking,
    double? playbackRate,
    Set<String>? activeClipIds,
  }) => TimelinePlaybackState(
    currentTime: currentTime ?? this.currentTime,
    duration: duration ?? this.duration,
    isPlaying: isPlaying ?? this.isPlaying,
    isSeeking: isSeeking ?? this.isSeeking,
    playbackRate: playbackRate ?? this.playbackRate,
    activeClipIds: activeClipIds ?? this.activeClipIds,
  );
}

class ActiveTimelineItems {
  final Map<TrackType, List<TimelineClip>> byType;

  const ActiveTimelineItems(this.byType);

  List<TimelineClip> ofType(TrackType type) => byType[type] ?? const [];
  Iterable<TimelineClip> get all => byType.values.expand((clips) => clips);
}

class TimelinePlaybackController extends ChangeNotifier {
  TimelinePlaybackState _state = const TimelinePlaybackState();
  Timer? _ticker;
  final Stopwatch _stopwatch = Stopwatch();
  Duration _playOrigin = Duration.zero;

  TimelinePlaybackState get state => _state;

  static Duration projectDuration(List<TimelineTrack> tracks) {
    var end = Duration.zero;
    for (final track in tracks) {
      for (final clip in track.clips) {
        final clipEnd = clip.start + clip.duration;
        if (clipEnd > end) end = clipEnd;
      }
    }
    return end;
  }

  static ActiveTimelineItems resolve(
    List<TimelineTrack> tracks,
    Duration time,
  ) {
    final grouped = <TrackType, List<TimelineClip>>{};
    for (final track in tracks) {
      if (!track.isVisible) continue;
      for (final clip in track.clips) {
        if (time >= clip.start && time < clip.start + clip.duration) {
          grouped.putIfAbsent(track.type, () => <TimelineClip>[]).add(clip);
        }
      }
    }
    return ActiveTimelineItems(grouped);
  }

  void updateProject(List<TimelineTrack> tracks) {
    final duration = projectDuration(tracks);
    final time = _state.currentTime > duration ? duration : _state.currentTime;
    _emit(time: time, duration: duration, tracks: tracks);
  }

  void play(List<TimelineTrack> tracks) {
    if (_state.isPlaying) return;
    final initialDuration = projectDuration(tracks);
    _playOrigin = _state.currentTime >= initialDuration
        ? Duration.zero
        : _state.currentTime;
    _stopwatch
      ..reset()
      ..start();
    _state = _state.copyWith(isPlaying: true, duration: initialDuration);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final duration = projectDuration(tracks);
      final elapsed = Duration(
        microseconds: (_stopwatch.elapsedMicroseconds * _state.playbackRate)
            .round(),
      );
      final next = _playOrigin + elapsed;
      if (next >= duration) {
        seek(duration, tracks);
        pause();
      } else {
        _emit(time: next, duration: duration, tracks: tracks);
      }
    });
    notifyListeners();
  }

  void pause() {
    _ticker?.cancel();
    _stopwatch.stop();
    if (!_state.isPlaying) return;
    _state = _state.copyWith(isPlaying: false);
    notifyListeners();
  }

  void stop(List<TimelineTrack> tracks) {
    pause();
    seek(Duration.zero, tracks);
  }

  void seek(Duration time, List<TimelineTrack> tracks) {
    final duration = projectDuration(tracks);
    final clamped = Duration(
      microseconds: time.inMicroseconds.clamp(0, duration.inMicroseconds),
    );
    _playOrigin = clamped;
    _stopwatch.reset();
    _emit(time: clamped, duration: duration, tracks: tracks);
  }

  void setPlaybackRate(double rate, List<TimelineTrack> tracks) {
    final wasPlaying = _state.isPlaying;
    if (wasPlaying) pause();
    _state = _state.copyWith(playbackRate: rate.clamp(0.25, 4));
    notifyListeners();
    if (wasPlaying) play(tracks);
  }

  void stepForward(List<TimelineTrack> tracks) =>
      seek(_state.currentTime + const Duration(milliseconds: 100), tracks);
  void stepBackward(List<TimelineTrack> tracks) =>
      seek(_state.currentTime - const Duration(milliseconds: 100), tracks);

  void _emit({
    required Duration time,
    required Duration duration,
    required List<TimelineTrack> tracks,
  }) {
    final active = resolve(tracks, time);
    _state = _state.copyWith(
      currentTime: time,
      duration: duration,
      activeClipIds: active.all.map((clip) => clip.id).toSet(),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stopwatch.stop();
    super.dispose();
  }
}
