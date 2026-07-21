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

class TimelineHistoryController {
  final int limit;
  final List<List<TimelineTrack>> _undoStack = [];
  final List<List<TimelineTrack>> _redoStack = [];

  TimelineHistoryController({this.limit = 50});

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void capture(List<TimelineTrack> tracks) {
    _undoStack.add(_cloneTracks(tracks));
    _redoStack.clear();
    if (_undoStack.length > limit) _undoStack.removeAt(0);
  }

  List<TimelineTrack>? undo(List<TimelineTrack> current) {
    if (_undoStack.isEmpty) return null;
    _redoStack.add(_cloneTracks(current));
    return _undoStack.removeLast();
  }

  List<TimelineTrack>? redo(List<TimelineTrack> current) {
    if (_redoStack.isEmpty) return null;
    _undoStack.add(_cloneTracks(current));
    return _redoStack.removeLast();
  }

  static List<TimelineTrack> _cloneTracks(List<TimelineTrack> tracks) => tracks
      .map(
        (track) => TimelineTrack(
          id: track.id,
          type: track.type,
          clips: track.clips.map(_cloneClip).toList(),
          label: track.label,
          icon: track.icon,
          isLocked: track.isLocked,
          isVisible: track.isVisible,
        ),
      )
      .toList();

  static TimelineClip _cloneClip(TimelineClip clip) => TimelineClip(
    id: clip.id,
    start: clip.start,
    duration: clip.duration,
    operation: _cloneOperation(clip.operation),
    file: clip.file,
    sourceStart: clip.sourceStart,
    sourceEnd: clip.sourceEnd,
    speed: clip.speed,
    volume: clip.volume,
    cropAspectRatio: clip.cropAspectRatio,
    isReversed: clip.isReversed,
    transform: TransformOperation(
      scale: clip.transform.scale,
      rotation: clip.transform.rotation,
      position: clip.transform.position,
      opacity: clip.transform.opacity,
    ),
    filter: clip.filter == null
        ? null
        : FilterOperation(filterName: clip.filter!.filterName),
    isHidden: clip.isHidden,
  );

  static EditOperation _cloneOperation(EditOperation operation) {
    if (operation is TrimOperation) {
      return TrimOperation(
        start: operation.start,
        end: operation.end,
        maxDuration: operation.maxDuration,
      );
    }
    if (operation is TextOverlay) {
      return TextOverlay(
        text: operation.text,
        position: operation.position,
        scale: operation.scale,
        rotation: operation.rotation,
        style: operation.style,
      );
    }
    if (operation is FilterOperation) {
      return FilterOperation(filterName: operation.filterName);
    }
    if (operation is TransformOperation) {
      return TransformOperation(
        scale: operation.scale,
        rotation: operation.rotation,
        position: operation.position,
        opacity: operation.opacity,
      );
    }
    if (operation is OverlayOperation) {
      return operation.copy();
    }
    if (operation is AudioClipOperation) {
      return AudioClipOperation(
        sourceType: operation.sourceType,
        sourceUrl: operation.sourceUrl,
        label: operation.label,
        volume: operation.volume,
        speed: operation.speed,
        reverse: operation.reverse,
        startOffset: operation.startOffset,
        endOffset: operation.endOffset,
      );
    }
    if (operation is EffectOperation) {
      return EffectOperation(
        presetId: operation.presetId,
        presetName: operation.presetName,
        category: operation.category,
        icon: operation.icon,
        intensity: operation.intensity,
        opacity: operation.opacity,
        blendMode: operation.blendMode,
        startOffset: operation.startOffset,
        endOffset: operation.endOffset,
        isFavorite: operation.isFavorite,
      );
    }
    if (operation is TransitionOperation) {
      return TransitionOperation(
        presetId: operation.presetId,
        presetName: operation.presetName,
        category: operation.category,
        icon: operation.icon,
        duration: operation.duration,
        direction: operation.direction,
        intensity: operation.intensity,
        easeIn: operation.easeIn,
        easeOut: operation.easeOut,
        reverse: operation.reverse,
        isFavorite: operation.isFavorite,
      );
    }
    throw UnsupportedError(
      'Unsupported edit operation: ${operation.runtimeType}',
    );
  }
}

class EditorProjectController {
  final List<TimelineTrack> tracks;
  final TimelinePlaybackController playback;
  final TimelineHistoryController history;

  EditorProjectController({
    List<TimelineTrack>? tracks,
    TimelinePlaybackController? playback,
    TimelineHistoryController? history,
  }) : tracks = tracks ?? <TimelineTrack>[],
       playback = playback ?? TimelinePlaybackController(),
       history = history ?? TimelineHistoryController();

  void replaceTracks(List<TimelineTrack> replacement) {
    tracks
      ..clear()
      ..addAll(replacement);
    playback.updateProject(tracks);
  }

  void dispose() => playback.dispose();
}
