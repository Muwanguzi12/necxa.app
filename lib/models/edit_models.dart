import 'package:universal_io/io.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
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

  TrimOperation({
    required this.start,
    required this.end,
    required this.maxDuration,
  }) : super('trim');

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
    this.style = const TextStyle(
      fontSize: 24,
      color: Color(0xFFF0F4FF),
      fontWeight: FontWeight.bold,
    ),
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
  final double intensity;
  FilterOperation({required this.filterName, this.intensity = 1.0})
      : super('filter');

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'name': filterName,
    'intensity': intensity,
  };
}

/// Non-destructive visual transform shared by every editor surface and renderer.
class TransformOperation extends EditOperation {
  double scale;
  double rotation;
  Offset position;
  double opacity;

  TransformOperation({
    this.scale = 1.0,
    this.rotation = 0.0,
    this.position = Offset.zero,
    this.opacity = 1.0,
  }) : super('transform');

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'scale': scale,
    'rotation': rotation,
    'position': {'dx': position.dx, 'dy': position.dy},
    'opacity': opacity,
  };
}

/// Typed overlay metadata shared by editor surfaces and the renderer.
class OverlayOperation extends EditOperation {
  String kind;
  String text;
  String? imagePath;
  double start;
  double end;
  Offset position;
  double scale;
  double rotation;
  double opacity;
  double fontSize;
  Color color;
  Color background;
  double backgroundOpacity;
  bool shadow;
  bool stroke;
  String align;
  String fontFamily;
  String animationIn;
  String animationOut;
  String themeId;

  OverlayOperation({
    required this.kind,
    required this.text,
    this.imagePath,
    this.start = 0,
    this.end = 1,
    this.position = const Offset(0.5, 0.5),
    this.scale = 1,
    this.rotation = 0,
    this.opacity = 1,
    this.fontSize = 28,
    this.color = const Color(0xFFF0F4FF),
    this.background = Colors.transparent,
    this.backgroundOpacity = 0,
    this.shadow = true,
    this.stroke = false,
    this.align = 'center',
    this.fontFamily = 'Syne',
    this.animationIn = 'none',
    this.animationOut = 'none',
    this.themeId = 'cinematic',
  }) : super('overlay');

  factory OverlayOperation.fromLegacy(Map<String, dynamic> values) {
    return OverlayOperation(
      kind: values['type'] as String? ?? 'text',
      text: values['text'] as String? ?? '',
      imagePath: values['image'] as String?,
      start: (values['start'] as num?)?.toDouble() ?? 0,
      end: (values['end'] as num?)?.toDouble() ?? 1,
      position: Offset(
        (values['x'] as num?)?.toDouble() ?? 0.5,
        (values['y'] as num?)?.toDouble() ?? 0.5,
      ),
      scale: (values['scale'] as num?)?.toDouble() ?? 1,
      rotation: (values['rotation'] as num?)?.toDouble() ?? 0,
      opacity: (values['opacity'] as num?)?.toDouble() ?? 1,
      fontSize: (values['fontSize'] as num?)?.toDouble() ?? 28,
      color: values['color'] as Color? ?? C.text,
      background: values['background'] as Color? ?? Colors.transparent,
      backgroundOpacity: (values['backgroundOpacity'] as num?)?.toDouble() ?? 0,
      shadow: values['shadow'] as bool? ?? true,
      stroke: values['stroke'] as bool? ?? false,
      align: values['align'] as String? ?? 'center',
      fontFamily: values['fontFamily'] as String? ?? 'Syne',
      animationIn: values['animationIn'] as String? ?? 'none',
      animationOut: values['animationOut'] as String? ?? 'none',
      themeId: values['themeId'] as String? ?? 'cinematic',
    );
  }

  OverlayOperation copy() => OverlayOperation(
    kind: kind,
    text: text,
    imagePath: imagePath,
    start: start,
    end: end,
    position: position,
    scale: scale,
    rotation: rotation,
    opacity: opacity,
    fontSize: fontSize,
    color: color,
    background: background,
    backgroundOpacity: backgroundOpacity,
    shadow: shadow,
    stroke: stroke,
    align: align,
    fontFamily: fontFamily,
    animationIn: animationIn,
    animationOut: animationOut,
    themeId: themeId,
  );

  @override
  Map<String, dynamic> toJson() => {
    'operationType': type,
    'type': kind,
    'text': text,
    'image': imagePath,
    'start': start,
    'end': end,
    'x': position.dx,
    'y': position.dy,
    'scale': scale,
    'rotation': rotation,
    'opacity': opacity,
    'fontSize': fontSize,
    'color': color,
    'background': background,
    'backgroundOpacity': backgroundOpacity,
    'shadow': shadow,
    'stroke': stroke,
    'align': align,
    'fontFamily': fontFamily,
    'animationIn': animationIn,
    'animationOut': animationOut,
    'themeId': themeId,
  };
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
    TransitionPreset(
      id: 'crossfade',
      name: 'Crossfade',
      category: 'Crossfade',
      icon: '🌫️',
      description: 'Smooth dissolve between clips.',
      tags: <String>['featured', 'recommended'],
      featured: true,
      recommended: true,
      defaultDuration: 0.7,
    ),
    TransitionPreset(
      id: 'fade',
      name: 'Fade',
      category: 'Fade',
      icon: '⬜',
      description: 'Classic fade-to-black transition.',
      tags: <String>['fade'],
      recommended: true,
      defaultDuration: 0.55,
    ),
    TransitionPreset(
      id: 'dissolve',
      name: 'Dissolve',
      category: 'Dissolve',
      icon: '✨',
      description: 'Soft pixel dissolve.',
      tags: <String>['new'],
      isNew: true,
      defaultDuration: 0.5,
    ),
    TransitionPreset(
      id: 'slide',
      name: 'Slide',
      category: 'Slide',
      icon: '➡️',
      description: 'Directional slide motion.',
      tags: <String>['motion'],
      trending: true,
      defaultDuration: 0.6,
    ),
    TransitionPreset(
      id: 'wipe',
      name: 'Wipe',
      category: 'Wipe',
      icon: '🧹',
      description: 'Clean wipe across the frame.',
      tags: <String>['creative'],
      defaultDuration: 0.65,
    ),
    TransitionPreset(
      id: 'zoom',
      name: 'Zoom',
      category: 'Zoom',
      icon: '🔍',
      description: 'Punch-in transition with scale.',
      tags: <String>['cinematic'],
      defaultDuration: 0.75,
    ),
    TransitionPreset(
      id: 'spin',
      name: 'Spin',
      category: 'Spin',
      icon: '🌀',
      description: 'Rotational transition.',
      tags: <String>['3d'],
      defaultDuration: 0.8,
    ),
    TransitionPreset(
      id: 'blur',
      name: 'Blur',
      category: 'Blur',
      icon: '🌫️',
      description: 'Blurred transition between clips.',
      tags: <String>['creative'],
      defaultDuration: 0.6,
    ),
    TransitionPreset(
      id: 'glitch',
      name: 'Glitch',
      category: 'Glitch',
      icon: '📡',
      description: 'Stylized glitch cut.',
      tags: <String>['trending'],
      trending: true,
      defaultDuration: 0.45,
    ),
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
  // Visual style key: drives CustomPainter overlays (glitch, vhs, scanlines, bloom, duotone, etc.)
  final String visualStyle;
  // Duotone shadow/highlight tint colours (as 0xAARRGGBB int)
  final int? duotoneShadow;
  final int? duotoneHighlight;

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
    this.visualStyle = 'none',
    this.duotoneShadow,
    this.duotoneHighlight,
  });

  static const List<EffectPreset> presets = <EffectPreset>[
    // ── Cinematic ──────────────────────────────────────────────
    EffectPreset(
      id: 'cinematic',
      name: 'Cinematic',
      category: 'Cinematic',
      icon: '🎬',
      description: 'Dramatic contrast with warm letterbox depth.',
      tags: <String>['featured', 'cinematic'],
      featured: true,
      trending: true,
      recommended: true,
      defaultIntensity: 0.75,
      brightness: -0.04,
      contrast: 1.18,
      saturation: 0.90,
      vignette: 0.28,
      blur: 0.02,
      visualStyle: 'letterbox',
    ),
    EffectPreset(
      id: 'teal_orange',
      name: 'Teal & Orange',
      category: 'Cinematic',
      icon: '🎞️',
      description: 'Hollywood blockbuster colour grade.',
      tags: <String>['featured', 'cinematic'],
      featured: true,
      defaultIntensity: 0.65,
      brightness: -0.02,
      contrast: 1.14,
      saturation: 1.08,
      hue: 0.04,
      vignette: 0.18,
      visualStyle: 'teal_orange',
    ),
    EffectPreset(
      id: 'matte',
      name: 'Matte Film',
      category: 'Cinematic',
      icon: '🌁',
      description: 'Faded matte with lifted shadows.',
      tags: <String>['cinematic', 'film'],
      defaultIntensity: 0.68,
      brightness: 0.06,
      contrast: 0.92,
      saturation: 0.82,
      vignette: 0.14,
      visualStyle: 'matte',
    ),
    // ── Retro ──────────────────────────────────────────────────
    EffectPreset(
      id: 'vhs',
      name: 'VHS',
      category: 'Retro',
      icon: '📼',
      description: 'Analog tape noise with horizontal tracking lines.',
      tags: <String>['new', 'retro'],
      isNew: true,
      trending: true,
      defaultIntensity: 0.6,
      defaultOpacity: 0.95,
      brightness: 0.02,
      contrast: 1.08,
      saturation: 0.78,
      grain: 0.22,
      vignette: 0.14,
      visualStyle: 'vhs',
    ),
    EffectPreset(
      id: 'noir',
      name: 'Noir',
      category: 'Retro',
      icon: '🖤',
      description: 'Moody monochrome with deep shadows.',
      tags: <String>['retro'],
      defaultIntensity: 0.85,
      saturation: 0.0,
      contrast: 1.22,
      vignette: 0.32,
      blur: 0.015,
      grain: 0.08,
      visualStyle: 'none',
    ),
    EffectPreset(
      id: 'super8',
      name: 'Super 8',
      category: 'Retro',
      icon: '🎥',
      description: 'Warm 1970s home-movie look with gate weave.',
      tags: <String>['retro', 'film'],
      isNew: true,
      defaultIntensity: 0.72,
      brightness: 0.05,
      contrast: 1.06,
      saturation: 0.86,
      hue: 0.03,
      grain: 0.28,
      vignette: 0.22,
      visualStyle: 'super8',
    ),
    // ── Glitch ─────────────────────────────────────────────────
    EffectPreset(
      id: 'glitch',
      name: 'Glitch',
      category: 'Glitch',
      icon: '📡',
      description: 'RGB channel split and digital scan corruption.',
      tags: <String>['trending', 'glitch'],
      trending: true,
      defaultIntensity: 0.55,
      contrast: 1.14,
      saturation: 1.08,
      hue: 0.06,
      grain: 0.14,
      visualStyle: 'glitch',
    ),
    EffectPreset(
      id: 'datamosh',
      name: 'Datamosh',
      category: 'Glitch',
      icon: '💾',
      description: 'Pixel bleed and macro block corruption.',
      tags: <String>['glitch', 'trending'],
      trending: true,
      isNew: true,
      defaultIntensity: 0.5,
      contrast: 1.1,
      saturation: 1.12,
      grain: 0.18,
      visualStyle: 'datamosh',
    ),
    // ── Neon & Light ───────────────────────────────────────────
    EffectPreset(
      id: 'neon',
      name: 'Neon',
      category: 'Neon',
      icon: '💡',
      description: 'Electric colour pop with highlight bloom.',
      tags: <String>['recommended', 'color'],
      recommended: true,
      defaultIntensity: 0.62,
      brightness: 0.05,
      contrast: 1.12,
      saturation: 1.28,
      hue: 0.1,
      visualStyle: 'bloom',
    ),
    EffectPreset(
      id: 'lightning',
      name: 'Lightning',
      category: 'Neon',
      icon: '⚡',
      description: 'High-energy contrast flash.',
      tags: <String>['light'],
      defaultIntensity: 0.65,
      brightness: 0.08,
      contrast: 1.24,
      saturation: 1.1,
      hue: 0.08,
      visualStyle: 'scanlines',
    ),
    EffectPreset(
      id: 'hologram',
      name: 'Hologram',
      category: 'Neon',
      icon: '🔮',
      description: 'Cyan phosphor scanlines with spectral shimmer.',
      tags: <String>['neon', 'new'],
      isNew: true,
      defaultIntensity: 0.58,
      brightness: 0.03,
      contrast: 1.08,
      saturation: 1.18,
      hue: 0.14,
      vignette: 0.1,
      visualStyle: 'hologram',
    ),
    // ── Duotone ────────────────────────────────────────────────
    EffectPreset(
      id: 'duotone_midnight',
      name: 'Midnight',
      category: 'Duotone',
      icon: '🌙',
      description: 'Deep navy-to-gold duotone.',
      tags: <String>['featured', 'duotone'],
      featured: true,
      defaultIntensity: 0.72,
      saturation: 0.0,
      contrast: 1.08,
      visualStyle: 'duotone',
      duotoneShadow: 0xFF0D1B2A,
      duotoneHighlight: 0xFFFFB347,
    ),
    EffectPreset(
      id: 'duotone_rose',
      name: 'Rose Gold',
      category: 'Duotone',
      icon: '🌸',
      description: 'Warm rose-to-champagne duotone.',
      tags: <String>['duotone', 'new'],
      isNew: true,
      defaultIntensity: 0.68,
      saturation: 0.0,
      contrast: 1.05,
      visualStyle: 'duotone',
      duotoneShadow: 0xFF6B1F3A,
      duotoneHighlight: 0xFFF5D6C0,
    ),
    // ── Film ───────────────────────────────────────────────────
    EffectPreset(
      id: 'film',
      name: 'Film Grain',
      category: 'Film',
      icon: '🎞️',
      description: 'Organic film texture with sprocket overlay.',
      tags: <String>['featured', 'film'],
      featured: true,
      defaultIntensity: 0.7,
      grain: 0.24,
      saturation: 0.88,
      vignette: 0.18,
      contrast: 1.06,
      visualStyle: 'film',
    ),
    EffectPreset(
      id: 'faded',
      name: 'Faded',
      category: 'Film',
      icon: '☁️',
      description: 'Bleached desaturated look with lifted blacks.',
      tags: <String>['film'],
      defaultIntensity: 0.65,
      brightness: 0.08,
      contrast: 0.9,
      saturation: 0.72,
      vignette: 0.1,
      grain: 0.1,
      visualStyle: 'matte',
    ),
    // ── Blur & Soft ────────────────────────────────────────────
    EffectPreset(
      id: 'blur',
      name: 'Soft Blur',
      category: 'Blur',
      icon: '🌫️',
      description: 'Dreamy motion and depth of field.',
      tags: <String>['cinematic'],
      defaultIntensity: 0.45,
      blur: 2.0,
      visualStyle: 'none',
    ),
    EffectPreset(
      id: 'dream',
      name: 'Dream',
      category: 'Blur',
      icon: '✨',
      description: 'Soft glow with highlight bloom.',
      tags: <String>['blur', 'new'],
      isNew: true,
      defaultIntensity: 0.5,
      brightness: 0.06,
      contrast: 0.95,
      saturation: 1.06,
      blur: 0.8,
      vignette: 0.08,
      visualStyle: 'bloom',
    ),
    // ── Colour Pop ─────────────────────────────────────────────
    EffectPreset(
      id: 'vivid',
      name: 'Vivid',
      category: 'Colour',
      icon: '🎨',
      description: 'Punchy saturated colours.',
      tags: <String>['recommended', 'color'],
      recommended: true,
      defaultIntensity: 0.7,
      brightness: 0.03,
      contrast: 1.14,
      saturation: 1.42,
      visualStyle: 'none',
    ),
    EffectPreset(
      id: 'cold',
      name: 'Arctic',
      category: 'Colour',
      icon: '🧊',
      description: 'Icy blue-tinted cool grade.',
      tags: <String>['color'],
      defaultIntensity: 0.65,
      brightness: 0.02,
      contrast: 1.08,
      saturation: 0.9,
      hue: -0.08,
      vignette: 0.1,
      visualStyle: 'none',
    ),
    EffectPreset(
      id: 'golden',
      name: 'Golden Hour',
      category: 'Colour',
      icon: '🌅',
      description: 'Warm amber sunset tones.',
      tags: <String>['recommended', 'color'],
      recommended: true,
      defaultIntensity: 0.68,
      brightness: 0.04,
      contrast: 1.06,
      saturation: 1.16,
      hue: 0.06,
      vignette: 0.12,
      visualStyle: 'none',
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

  RenderEffects renderEffects() => (preset ?? EffectPreset.presets.first)
      .toRenderEffects(intensity: intensity);

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
  double volume;
  double speed;
  bool reverse;
  double fadeIn;
  double fadeOut;
  final double? startOffset;
  final double? endOffset;

  AudioClipOperation({
    required this.sourceType,
    this.sourceUrl,
    this.label,
    this.volume = 1.0,
    this.speed = 1.0,
    this.reverse = false,
    this.fadeIn = 0.0,
    this.fadeOut = 0.0,
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
    'speed': speed,
    'reverse': reverse,
    'fadeIn': fadeIn,
    'fadeOut': fadeOut,
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
  File? file;
  Duration sourceStart;
  Duration? sourceEnd;
  double speed;
  double volume;
  String cropAspectRatio;
  bool isReversed;
  TransformOperation transform;
  FilterOperation? filter;
  TransitionOperation? transitionIn;
  bool
  isHidden; // when true, clip is not rendered in preview (used for advanced trim hide semantics)
  File? proxyFile;
  bool isProxyReady;
  double faceSymmetry;
  bool symmetryMirrorLeft;
  double skinSmoothing;
  int smoothingMode;
  double skinBrightening;
  int skinToneMode;
  int makeupGender;
  int makeupStyle;
  double makeupIntensity;
  double brightness;
  double contrast;
  double saturation;
  double hue;
  double vignette;
  double grain;
  double blur;

  TimelineClip({
    required this.id,
    required this.start,
    required this.duration,
    required this.operation,
    this.file,
    this.proxyFile,
    this.isProxyReady = false,
    this.faceSymmetry = 0.0,
    this.symmetryMirrorLeft = true,
    this.skinSmoothing = 0.0,
    this.smoothingMode = 0,
    this.skinBrightening = 0.0,
    this.skinToneMode = 0,
    this.makeupGender = 0,
    this.makeupStyle = 0,
    this.makeupIntensity = 0.7,
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.hue = 0.0,
    this.vignette = 0.0,
    this.grain = 0.0,
    this.blur = 0.0,
    this.sourceStart = Duration.zero,
    this.sourceEnd,
    this.speed = 1.0,
    this.volume = 1.0,
    this.cropAspectRatio = 'Original',
    this.isReversed = false,
    TransformOperation? transform,
    this.filter,
    this.transitionIn,
    this.isHidden = false,
  }) : transform = transform ?? TransformOperation();

  TimelineClip copyWith({
    String? id,
    Duration? start,
    Duration? duration,
    EditOperation? operation,
    File? file,
    File? proxyFile,
    bool? isProxyReady,
    double? faceSymmetry,
    bool? symmetryMirrorLeft,
    double? skinSmoothing,
    int? smoothingMode,
    double? skinBrightening,
    int? skinToneMode,
    int? makeupGender,
    int? makeupStyle,
    double? makeupIntensity,
    double? brightness,
    double? contrast,
    double? saturation,
    double? hue,
    double? vignette,
    double? grain,
    double? blur,
    Duration? sourceStart,
    Duration? sourceEnd,
    double? speed,
    double? volume,
    String? cropAspectRatio,
    bool? isReversed,
    TransformOperation? transform,
    FilterOperation? filter,
    TransitionOperation? transitionIn,
    bool? isHidden,
  }) {
    return TimelineClip(
      id: id ?? this.id,
      start: start ?? this.start,
      duration: duration ?? this.duration,
      operation: operation ?? this.operation,
      file: file ?? this.file,
      proxyFile: proxyFile ?? this.proxyFile,
      isProxyReady: isProxyReady ?? this.isProxyReady,
      faceSymmetry: faceSymmetry ?? this.faceSymmetry,
      symmetryMirrorLeft: symmetryMirrorLeft ?? this.symmetryMirrorLeft,
      skinSmoothing: skinSmoothing ?? this.skinSmoothing,
      smoothingMode: smoothingMode ?? this.smoothingMode,
      skinBrightening: skinBrightening ?? this.skinBrightening,
      skinToneMode: skinToneMode ?? this.skinToneMode,
      makeupGender: makeupGender ?? this.makeupGender,
      makeupStyle: makeupStyle ?? this.makeupStyle,
      makeupIntensity: makeupIntensity ?? this.makeupIntensity,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      hue: hue ?? this.hue,
      vignette: vignette ?? this.vignette,
      grain: grain ?? this.grain,
      blur: blur ?? this.blur,
      sourceStart: sourceStart ?? this.sourceStart,
      sourceEnd: sourceEnd ?? this.sourceEnd,
      speed: speed ?? this.speed,
      volume: volume ?? this.volume,
      cropAspectRatio: cropAspectRatio ?? this.cropAspectRatio,
      isReversed: isReversed ?? this.isReversed,
      transform: transform ?? this.transform,
      filter: filter ?? this.filter,
      transitionIn: transitionIn ?? this.transitionIn,
      isHidden: isHidden ?? this.isHidden,
    );
  }

  Duration get sourceDuration =>
      (sourceEnd ?? (sourceStart + duration)) - sourceStart;
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
  static bool applyDiscoveredSourceDuration(
    TimelineClip clip,
    Duration discoveredDuration,
  ) {
    if (discoveredDuration <= Duration.zero || clip.sourceEnd != null) {
      return false;
    }
    final available = discoveredDuration - clip.sourceStart;
    if (available <= Duration.zero) return false;

    clip.sourceEnd = discoveredDuration;
    clip.duration = Duration(
      milliseconds: (available.inMilliseconds / clip.speed).round(),
    );
    if (clip.operation is TrimOperation) {
      (clip.operation as TrimOperation).end = discoveredDuration;
    }
    return true;
  }

  static void reflowInitialVisualClips(List<TimelineTrack> tracks) {
    final clips =
        tracks
            .where(
              (track) =>
                  track.type == TrackType.video ||
                  track.type == TrackType.images,
            )
            .expand((track) => track.clips)
            .where((clip) => clip.id.startsWith('initial-'))
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    var cursor = Duration.zero;
    for (final clip in clips) {
      clip.start = cursor;
      cursor += clip.duration;
    }
  }

  static Duration relativeTimeForClip(
    TimelineClip clip,
    Duration timelineTime,
  ) {
    final elapsed = timelineTime - clip.start;
    if (elapsed <= Duration.zero) return Duration.zero;
    if (elapsed >= clip.duration) return clip.duration;
    return elapsed;
  }

  static TimelineTrack ensureTrackForType(
    List<TimelineTrack> tracks,
    TrackType type, {
    String? id,
    String? label,
    IconData? icon,
  }) {
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
  }) {
    final targetTrack = ensureTrackForType(
      tracks,
      type,
      id: id,
      label: label,
      icon: icon,
    );
    // Insert clip keeping clips sorted by start time to make multi-clip
    // operations and rendering predictable.
    final insertIndex = targetTrack.clips.indexWhere(
      (c) => clip.start < c.start,
    );
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
  }) {
    final clip = TimelineClip(
      id: id ?? 'text-${DateTime.now().millisecondsSinceEpoch}',
      start: start,
      duration: duration ?? const Duration(seconds: 4),
      operation: TextOverlay(
        text: text,
        position: position ?? const Offset(0.5, 0.5),
        scale: scale ?? 1.0,
        rotation: rotation ?? 0.0,
        style:
            style ??
            const TextStyle(
              fontSize: 28,
              color: Color(0xFFF0F4FF),
              fontWeight: FontWeight.bold,
            ),
      ),
    );
    insertClip(tracks, clip, TrackType.text);
    return clip;
  }

  static void pruneEmptyTracks(List<TimelineTrack> tracks) {
    tracks.removeWhere(
      (track) => track.type != TrackType.video && track.clips.isEmpty,
    );
  }

  static List<TimelineTrack> visibleTracks(List<TimelineTrack> tracks) {
    return tracks
        .where(
          (track) =>
              track.isVisible &&
              (track.type == TrackType.video || track.clips.isNotEmpty),
        )
        .toList();
  }
}

