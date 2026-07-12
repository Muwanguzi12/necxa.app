import 'package:flutter/material.dart';

/// Base class for any non-destructive edit operation.
/// Each operation can be converted to JSON to be stored in the database.
abstract class EditOperation {
  final String type;
  EditOperation(this.type);
  Map<String, dynamic> toJson();
}

/// Represents a trim operation, storing start and end times.
class TrimOperation extends EditOperation {
  Duration start;
  Duration end;
  final Duration maxDuration;

  TrimOperation({required this.start, required this.end, required this.maxDuration}) : super('trim');

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'startTime': start.inMilliseconds / 1000.0,
        'endTime': end.inMilliseconds / 1000.0,
      };
}

/// Represents a text overlay with its properties.
class TextOverlay extends EditOperation {
  String text;
  Offset position; // Relative position (0.0 to 1.0)
  double scale;
  double rotation;
  TextStyle style;

  TextOverlay({
    this.text = 'Enter Text',
    this.position = const Offset(0.5, 0.5),
    this.scale = 1.0,
    this.rotation = 0.0,
    this.style = const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold),
  }) : super('text');

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'content': text,
        'position': {'dx': position.dx, 'dy': position.dy},
        'scale': scale,
        'rotation': rotation,
        'font': style.fontFamily,
        'fontSize': style.fontSize,
        // ignore: deprecated_member_use
        'color': '#${style.color?.value.toRadixString(16)}',
      };
}

/// Represents a color filter operation.
class FilterOperation extends EditOperation {
  final String filterName; // e.g., 'sepia', 'grayscale', 'vignette'
  FilterOperation({required this.filterName}) : super('filter');

  @override
  Map<String, dynamic> toJson() => {'type': type, 'name': filterName};
}

/// Shared audio operation used by desktop and mobile editors for music,
/// voiceovers, and sound effects inserted into the timeline.
class AudioClipOperation extends EditOperation {
  final String sourceType;
  final String? sourceUrl;
  final String? label;
  final double volume;
  final double? startOffset;
  final double? endOffset;

  AudioClipOperation({
    required this.sourceType,
    this.sourceUrl,
    this.label,
    this.volume = 1.0,
    this.startOffset,
    this.endOffset,
  }) : super('audio');

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'sourceType': sourceType,
        'sourceUrl': sourceUrl,
        'label': label,
        'volume': volume,
        'startOffset': startOffset,
        'endOffset': endOffset,
      };
}

/// Represents the type of a timeline track.
enum TrackType {
  video,
  audio,
  text,
  images,
  captions,
  overlay,
  effects,
  music,
  voiceOver,
  soundEffects,
}

extension TrackTypeExtension on TrackType {
  String get defaultLabel {
    switch (this) {
      case TrackType.video:
        return 'Video';
      case TrackType.audio:
        return 'Audio';
      case TrackType.text:
        return 'Text';
      case TrackType.images:
        return 'Images';
      case TrackType.captions:
        return 'Captions';
      case TrackType.overlay:
        return 'Overlay';
      case TrackType.effects:
        return 'Effects';
      case TrackType.music:
        return 'Music';
      case TrackType.voiceOver:
        return 'Voiceover';
      case TrackType.soundEffects:
        return 'Sound Effects';
    }
  }

  IconData get defaultIcon {
    switch (this) {
      case TrackType.video:
        return Icons.videocam;
      case TrackType.audio:
        return Icons.music_note;
      case TrackType.text:
        return Icons.text_fields;
      case TrackType.images:
        return Icons.image;
      case TrackType.captions:
        return Icons.closed_caption;
      case TrackType.overlay:
        return Icons.layers;
      case TrackType.effects:
        return Icons.auto_awesome;
      case TrackType.music:
        return Icons.queue_music;
      case TrackType.voiceOver:
        return Icons.mic;
      case TrackType.soundEffects:
        return Icons.spatial_audio;
    }
  }
}

/// Represents a single clip on a timeline track.
class TimelineClip {
  final String id;
  Duration start;
  Duration duration;
  final EditOperation operation;

  TimelineClip({
    required this.id,
    required this.start,
    required this.duration,
    required this.operation,
  });

  TimelineClip copyWith({String? id, Duration? start, Duration? duration, EditOperation? operation}) {
    return TimelineClip(
      id: id ?? this.id,
      start: start ?? this.start,
      duration: duration ?? this.duration,
      operation: operation ?? this.operation,
    );
  }
}

/// Represents a full track in the timeline, containing multiple clips.
class TimelineTrack {
  final String id;
  final TrackType type;
  final List<TimelineClip> clips;
  final String label;
  final IconData icon;
  bool isLocked;
  bool isVisible;

  TimelineTrack({
    required this.id,
    required this.type,
    required this.clips,
    required this.label,
    required this.icon,
    this.isLocked = false,
    this.isVisible = true,
  });
}

class TimelineModelUtils {
  static TimelineTrack ensureTrackForType(
    List<TimelineTrack> tracks,
    TrackType type, {
      String? id,
      String? label,
      IconData? icon,
    }
  ) {
    for (final track in tracks) {
      if (track.type == type) {
        return track;
      }
    }

    final newTrack = TimelineTrack(
      id: id ?? '${type.name}-track-${tracks.length + 1}',
      type: type,
      label: label ?? type.defaultLabel,
      icon: icon ?? type.defaultIcon,
      clips: [],
    );
    tracks.add(newTrack);
    return newTrack;
  }

  static TimelineClip insertClip(
    List<TimelineTrack> tracks,
    TimelineClip clip,
    TrackType type, {
      String? id,
      String? label,
      IconData? icon,
    }
  ) {
    final targetTrack = ensureTrackForType(tracks, type, id: id, label: label, icon: icon);
    targetTrack.clips.add(clip);
    return clip;
  }

  static TimelineClip insertTextClip(
    List<TimelineTrack> tracks, {
      required String text,
      required Duration start,
      Duration? duration,
      TextStyle? style,
      Offset? position,
      double? scale,
      double? rotation,
      String? id,
    }
  ) {
    final clip = TimelineClip(
      id: id ?? 'text-${DateTime.now().millisecondsSinceEpoch}',
      start: start,
      duration: duration ?? const Duration(seconds: 4),
      operation: TextOverlay(
        text: text,
        position: position ?? const Offset(0.5, 0.5),
        scale: scale ?? 1.0,
        rotation: rotation ?? 0.0,
        style: style ?? const TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold),
      ),
    );
    insertClip(tracks, clip, TrackType.text);
    return clip;
  }

  static void pruneEmptyTracks(List<TimelineTrack> tracks) {
    tracks.removeWhere((track) => track.type != TrackType.video && track.clips.isEmpty);
  }

  static List<TimelineTrack> visibleTracks(List<TimelineTrack> tracks) {
    return tracks
        .where((track) => track.isVisible && (track.type == TrackType.video || track.clips.isNotEmpty))
        .toList();
  }
}