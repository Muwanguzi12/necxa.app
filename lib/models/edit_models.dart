import 'package:flutter/material.dart';
import '../services/video_enhancement_service.dart';

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

/// Shared transition preset metadata reused by desktop and mobile editors.
class TransitionPreset {
  final String id;
  final String name;
  final String category;
  final String icon;
  final String description;
  final List<String> tags;
  final bool featured;
  final bool recommended;
  final bool trending;
  final bool isNew;
  final bool favorite;
  final double defaultDuration;
  final double defaultIntensity;
  final bool defaultReverse;

  const TransitionPreset({
    required this.id,
    required this.name,
    required this.category,
    required this.icon,
    required this.description,
    this.tags = const <String>[],
    this.featured = false,
    this.recommended = false,
    this.trending = false,
    this.isNew = false,
    this.favorite = false,
    this.defaultDuration = 0.6,
    this.defaultIntensity = 0.8,
    this.defaultReverse = false,
  });

  static const List<TransitionPreset> presets = <TransitionPreset>[
    TransitionPreset(id: 'crossfade', name: 'Crossfade', category: 'Crossfade', icon: '🌫️', description: 'Smooth dissolve between clips.', tags: <String>['featured', 'recommended'], featured: true, recommended: true, defaultDuration: 0.7),
    TransitionPreset(id: 'fade', name: 'Fade', category: 'Fade', icon: '⬜', description: 'Classic fade-to-black transition.', tags: <String>['fade'], recommended: true, defaultDuration: 0.55),
    TransitionPreset(id: 'dissolve', name: 'Dissolve', category: 'Dissolve', icon: '✨', description: 'Soft pixel dissolve.', tags: <String>['new'], isNew: true, defaultDuration: 0.5),
    TransitionPreset(id: 'slide', name: 'Slide', category: 'Slide', icon: '➡️', description: 'Directional slide motion.', tags: <String>['motion'], trending: true, defaultDuration: 0.6),
    TransitionPreset(id: 'wipe', name: 'Wipe', category: 'Wipe', icon: '🧹', description: 'Clean wipe across the frame.', tags: <String>['creative'], defaultDuration: 0.65),
    TransitionPreset(id: 'zoom', name: 'Zoom', category: 'Zoom', icon: '🔍', description: 'Punch-in transition with scale.', tags: <String>['cinematic'], defaultDuration: 0.75),
    TransitionPreset(id: 'spin', name: 'Spin', category: 'Spin', icon: '🌀', description: 'Rotational transition.', tags: <String>['3d'], defaultDuration: 0.8),
    TransitionPreset(id: 'blur', name: 'Blur', category: 'Blur', icon: '🌫️', description: 'Blurred transition between clips.', tags: <String>['creative'], defaultDuration: 0.6),
    TransitionPreset(id: 'glitch', name: 'Glitch', category: 'Glitch', icon: '📡', description: 'Stylized glitch cut.', tags: <String>['trending'], trending: true, defaultDuration: 0.45),
  ];
}

/// Shared transition operation stored on the timeline and reused across edit surfaces.
class TransitionOperation extends EditOperation {
  String presetId;
  String presetName;
  String category;
  String icon;
  double duration;
  String direction;
  double intensity;
  bool easeIn;
  bool easeOut;
  bool reverse;
  bool isFavorite;

  TransitionOperation({
    required this.presetId,
    required this.presetName,
    required this.category,
    required this.icon,
    this.duration = 0.6,
    this.direction = 'center',
    this.intensity = 0.8,
    this.easeIn = true,
    this.easeOut = true,
    this.reverse = false,
    this.isFavorite = false,
  }) : super('transition');

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'presetId': presetId,
        'presetName': presetName,
        'category': category,
        'duration': duration,
        'direction': direction,
        'intensity': intensity,
        'easeIn': easeIn,
        'easeOut': easeOut,
        'reverse': reverse,
        'isFavorite': isFavorite,
      };
}

/// Shared effect preset metadata reused by desktop and mobile editors.
class EffectPreset {
  final String id;
  final String name;
  final String category;
  final String icon;
  final String description;
  final List<String> tags;
  final bool featured;
  final bool trending;
  final bool isNew;
  final bool recommended;
  final double defaultIntensity;
  final double defaultOpacity;
  final String defaultBlendMode;
  final double brightness;
  final double contrast;
  final double saturation;
  final double hue;
  final double vignette;
  final double blur;
  final double grain;

  const EffectPreset({
    required this.id,
    required this.name,
    required this.category,
    required this.icon,
    required this.description,
    this.tags = const <String>[],
    this.featured = false,
    this.trending = false,
    this.isNew = false,
    this.recommended = false,
    this.defaultIntensity = 0.7,
    this.defaultOpacity = 1.0,
    this.defaultBlendMode = 'normal',
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.hue = 0.0,
    this.vignette = 0.0,
    this.blur = 0.0,
    this.grain = 0.0,
  });

  static const List<EffectPreset> presets = <EffectPreset>[
    EffectPreset(
      id: 'cinematic',
      name: 'Cinematic',
      category: 'Cinematic',
      icon: '🎬',
      description: 'Dramatic contrast and warm depth.',
      tags: <String>['featured', 'cinematic'],
      featured: true,
      trending: true,
      recommended: true,
      defaultIntensity: 0.65,
      defaultOpacity: 1.0,
      brightness: -0.03,
      contrast: 1.16,
      saturation: 0.92,
      vignette: 0.22,
      blur: 0.03,
    ),
    EffectPreset(
      id: 'glitch',
      name: 'Glitch',
      category: 'Glitch',
      icon: '📡',
      description: 'Synthetic chromatic noise and edge disruption.',
      tags: <String>['trending', 'glitch'],
      trending: true,
      defaultIntensity: 0.45,
      defaultOpacity: 0.9,
      contrast: 1.14,
      saturation: 1.06,
      hue: 0.06,
      grain: 0.16,
      blur: 0.04,
    ),
    EffectPreset(
      id: 'vhs',
      name: 'VHS',
      category: 'VHS',
      icon: '📼',
      description: 'Analog tape texture with soft saturation loss.',
      tags: <String>['new', 'retro'],
      isNew: true,
      defaultIntensity: 0.55,
      defaultOpacity: 0.95,
      brightness: 0.02,
      contrast: 1.08,
      saturation: 0.8,
      grain: 0.2,
      vignette: 0.12,
    ),
    EffectPreset(
      id: 'neon',
      name: 'Neon',
      category: 'Neon',
      icon: '💡',
      description: 'Electric color pop with crisp highlights.',
      tags: <String>['recommended', 'color'],
      recommended: true,
      defaultIntensity: 0.58,
      defaultOpacity: 0.92,
      brightness: 0.04,
      contrast: 1.1,
      saturation: 1.25,
      hue: 0.12,
      blur: 0.02,
    ),
    EffectPreset(
      id: 'blur',
      name: 'Soft Blur',
      category: 'Blur',
      icon: '🌫️',
      description: 'Dreamy motion and depth.',
      tags: <String>['cinematic'],
      defaultIntensity: 0.35,
      defaultOpacity: 0.95,
      blur: 1.6,
    ),
    EffectPreset(
      id: 'film',
      name: 'Film Grain',
      category: 'Film',
      icon: '🎞️',
      description: 'Vintage film texture for editorial storytelling.',
      tags: <String>['featured', 'film'],
      featured: true,
      defaultIntensity: 0.7,
      defaultOpacity: 0.95,
      grain: 0.22,
      saturation: 0.9,
      vignette: 0.16,
    ),
    EffectPreset(
      id: 'noir',
      name: 'Noir',
      category: 'Retro',
      icon: '🖤',
      description: 'Moody monochrome styling for dramatic scenes.',
      tags: <String>['retro'],
      defaultIntensity: 0.82,
      defaultOpacity: 1.0,
      saturation: 0.55,
      contrast: 1.18,
      vignette: 0.28,
      blur: 0.02,
    ),
    EffectPreset(
      id: 'lightning',
      name: 'Lightning',
      category: 'Light',
      icon: '⚡',
      description: 'High-contrast flash and energy.',
      tags: <String>['light'],
      defaultIntensity: 0.6,
      defaultOpacity: 0.9,
      brightness: 0.08,
      contrast: 1.22,
      saturation: 1.08,
      hue: 0.07,
    ),
  ];

  static EffectPreset? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    return presets.cast<EffectPreset?>().firstWhere(
      (preset) => preset?.id == id,
      orElse: () => null,
    );
  }

  RenderEffects toRenderEffects({double intensity = 1.0}) {
    final safeIntensity = intensity.clamp(0.0, 1.0);
    return RenderEffects(
      brightness: brightness * safeIntensity,
      contrast: 1.0 + (contrast - 1.0) * safeIntensity,
      saturation: 1.0 + (saturation - 1.0) * safeIntensity,
      hue: hue * safeIntensity,
      vignette: vignette * safeIntensity,
      blur: blur * safeIntensity,
      grain: grain * safeIntensity,
    );
  }
}

/// Shared effect operation stored on the timeline and reused across edit surfaces.
class EffectOperation extends EditOperation {
  String presetId;
  String presetName;
  String category;
  String icon;
  double intensity;
  double opacity;
  String blendMode;
  double startOffset;
  double endOffset;
  bool isFavorite;

  EffectOperation({
    required this.presetId,
    required this.presetName,
    required this.category,
    required this.icon,
    this.intensity = 0.7,
    this.opacity = 1.0,
    this.blendMode = 'normal',
    this.startOffset = 0.0,
    this.endOffset = 0.0,
    this.isFavorite = false,
  }) : super('effect');

  EffectPreset? get preset => EffectPreset.byId(presetId);

  RenderEffects renderEffects() => (preset ?? EffectPreset.presets.first).toRenderEffects(intensity: intensity);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'presetId': presetId,
        'presetName': presetName,
        'category': category,
        'intensity': intensity,
        'opacity': opacity,
        'blendMode': blendMode,
        'startOffset': startOffset,
        'endOffset': endOffset,
        'isFavorite': isFavorite,
      };
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
    // Insert clip keeping clips sorted by start time to make multi-clip
    // operations and rendering predictable.
    final insertIndex = targetTrack.clips.indexWhere((c) => clip.start < c.start);
    if (insertIndex == -1) {
      targetTrack.clips.add(clip);
    } else {
      targetTrack.clips.insert(insertIndex, clip);
    }
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