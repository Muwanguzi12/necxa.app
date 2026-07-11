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

/// Represents the type of a timeline track.
enum TrackType { video, audio, text, effect }

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