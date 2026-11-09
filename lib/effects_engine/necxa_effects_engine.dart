import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../services/filter_catalogue_service.dart';

/// Builds mathematically precise ColorFilter matrices and FFmpeg eq filter strings for NECXA effects.
class NativeEffectParameters {
  final double brightness;
  final double contrast;
  final double saturation;
  final double hue;
  final double warmth;

  const NativeEffectParameters({
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.hue,
    required this.warmth,
  });

  Map<String, double> toMap() => {
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'hue': hue,
    'warmth': warmth,
  };
}

class NecxaEffectsEngine {
  // Named matrix presets (4x5 row-major, Flutter ColorFilter.matrix format).
  static const Map<String, List<double>> _namedMatrices = {
    'cinema': [
      1.15,  0.0,   0.0,   0.0,  12.0,
      0.0,   1.02,  0.0,   0.0,  -4.0,
      0.0,   0.0,   0.88,  0.0, -12.0,
      0.0,   0.0,   0.0,   1.0,   0.0,
    ],
    'neon': [
      0.95, 0.08, 0.22, 0.0,   4.0,
      0.08, 0.85, 0.12, 0.0,   0.0,
      0.20, 0.18, 1.25, 0.0,  10.0,
      0.0,  0.0,  0.0,  1.0,   0.0,
    ],
    'grayscale': [
      0.2126, 0.7152, 0.0722, 0.0, 0.0,
      0.2126, 0.7152, 0.0722, 0.0, 0.0,
      0.2126, 0.7152, 0.0722, 0.0, 0.0,
      0.0,    0.0,    0.0,    1.0, 0.0,
    ],
  };

  /// Builds a 4x5 ColorFilter matrix from individual parameters.
  /// Brightness: -1.0 to 1.0 (0 is neutral)
  /// Contrast: 0.0 to 2.0 (1.0 is neutral)
  /// Saturation: 0.0 to 2.0 (1.0 is neutral)
  /// Hue: in radians, -pi to pi (0 is neutral)
  static List<double> buildMatrix({
    double brightness = 0.0,
    double contrast = 1.0,
    double saturation = 1.0,
    double hue = 0.0,
  }) {
    // 1. Start with identity
    var m = _identity();

    // 2. Brightness
    m = _applyBrightness(m, brightness);

    // 3. Contrast
    m = _applyContrast(m, contrast);

    // 4. Saturation
    m = _applySaturation(m, saturation);

    // 5. Hue
    if (hue.abs() > 0.001) {
      m = _applyHue(m, hue);
    }

    return m;
  }

  /// Compose `buildMatrix` result with intensity interpolation.
  static List<double> buildMatrixForMeta(
    NecxaFilterMeta meta, {
    double intensity = 1.0,
  }) {
    if (meta.isNone) return _identity();
    final t = intensity.clamp(0.0, 1.0);
    if (t <= 0.001) return _identity();

    if (meta.colorMatrixPreset != null &&
        _namedMatrices.containsKey(meta.colorMatrixPreset)) {
      final preset = _namedMatrices[meta.colorMatrixPreset!]!;
      final id = _identity();
      return List<double>.generate(20, (i) => _lerp(id[i], preset[i], t));
    }

    return buildMatrix(
      brightness: meta.brightness * t,
      contrast: 1.0 + (meta.contrast - 1.0) * t,
      saturation: 1.0 + (meta.saturation - 1.0) * t,
      hue: meta.hue * t,
    );
  }

  /// Maps a catalogue preset to the native I420 processor's controls.
  /// The same catalogue values feed Flutter preview and FFmpeg export.
  static NativeEffectParameters nativeParametersForMeta(
    NecxaFilterMeta? meta, {
    double intensity = 1.0,
    double skinBrightening = 0.0,
    int skinTone = 0,
  }) {
    final strength = meta == null || meta.isNone
        ? 0.0
        : intensity.clamp(0.0, 1.0);
    final brightness = (((meta?.brightness ?? 0.0) * strength) +
            (skinBrightening.clamp(0.0, 1.0) * 0.08))
        .clamp(-0.25, 0.25)
        .toDouble();
    final contrast = (1.0 +
            ((meta?.contrast ?? 1.0) - 1.0) * strength)
        .clamp(0.5, 1.8)
        .toDouble();
    final isMonochrome = meta?.colorMatrixPreset == 'grayscale' ||
        meta?.displayName.toLowerCase() == 'noir';
    final saturation = isMonochrome
        ? 0.0
        : (1.0 + ((meta?.saturation ?? 1.0) - 1.0) * strength)
            .clamp(0.0, 2.0)
            .toDouble();
    final hue = ((meta?.hue ?? 0.0) * strength).clamp(-math.pi, math.pi).toDouble();
    final toneWarmth = skinBrightening <= 0
        ? 0.0
        : (skinTone == 0 ? 0.12 : (skinTone == 1 ? -0.08 : 0.0));
    final warmth = toneWarmth.clamp(-0.5, 0.5)
        .toDouble();
    return NativeEffectParameters(
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
      hue: hue,
      warmth: warmth,
    );
  }

  /// Returns a Flutter `ColorFilter` for camera preview rendering.
  static ColorFilter? colorFilterForMeta(
    NecxaFilterMeta? meta, {
    double intensity = 1.0,
  }) {
    if (meta == null || meta.isNone || intensity <= 0.001) return null;
    final m = buildMatrixForMeta(meta, intensity: intensity);
    return ColorFilter.matrix(m);
  }

  /// Returns an FFmpeg vf filter string fragment for video export.
  static String buildFfmpegEqFilter(NecxaFilterMeta meta, {double intensity = 1.0}) {
    if (meta.isNone || intensity <= 0.001) return '';
    final t = intensity.clamp(0.0, 1.0);

    if (meta.colorMatrixPreset == 'grayscale' || meta.displayName.toLowerCase() == 'noir') {
      final c = 1.0 + (meta.contrast - 1.0) * t;
      return 'hue=s=0,eq=contrast=${c.toStringAsFixed(3)}';
    }

    final native = nativeParametersForMeta(meta, intensity: t);
    final parts = <String>[];
    parts.add(
      'eq=brightness=${native.brightness.toStringAsFixed(4)}:'
      'contrast=${native.contrast.toStringAsFixed(4)}:'
      'saturation=${native.saturation.toStringAsFixed(4)}',
    );

    if (native.hue.abs() > 0.001) {
      final hueDeg = (native.hue * 180.0 / math.pi).toStringAsFixed(2);
      parts.add('hue=h=$hueDeg');
    }

    return parts.join(',');
  }

  // ── Internal matrix helpers ──────────────────────────────────

  static List<double> _identity() => [
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
  ];

  static List<double> _applyBrightness(List<double> m, double b) {
    final offset = b * 255.0;
    final r = List<double>.from(m);
    r[4] += offset;
    r[9] += offset;
    r[14] += offset;
    return r;
  }

  static List<double> _applyContrast(List<double> m, double c) {
    final offset = 127.5 * (1.0 - c);
    final r = List<double>.from(m);
    r[0] *= c;  r[4] = r[4] * c + offset;
    r[6] *= c;  r[9] = r[9] * c + offset;
    r[12] *= c; r[14] = r[14] * c + offset;
    return r;
  }

  static List<double> _applySaturation(List<double> m, double s) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final r = List<double>.from(m);
    final rr = (1 - s) * lr + s; final rg = (1 - s) * lg;       final rb = (1 - s) * lb;
    final gr = (1 - s) * lr;     final gg = (1 - s) * lg + s;   final gb = (1 - s) * lb;
    final br2 = (1 - s) * lr;    final bg = (1 - s) * lg;       final bb2 = (1 - s) * lb + s;

    r[0] = rr; r[1] = rg; r[2] = rb;
    r[5] = gr; r[6] = gg; r[7] = gb;
    r[10] = br2; r[11] = bg; r[12] = bb2;
    return r;
  }

  static List<double> _applyHue(List<double> m, double angle) {
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    final yiqR = [0.299,  0.587,  0.114];
    final yiqI = [0.596, -0.274, -0.322];
    final yiqQ = [0.212, -0.523,  0.311];

    final hue3x3 = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      hue3x3[i * 3 + 0] = yiqR[i] + cosA * yiqI[i] + sinA * yiqQ[i];
      hue3x3[i * 3 + 1] = yiqR[i] - cosA * yiqI[i] - sinA * yiqQ[i];
      hue3x3[i * 3 + 2] = yiqR[i] + cosA * (-yiqI[i]) + sinA * (-yiqQ[i]);
    }

    final r = List<double>.from(m);
    final origR0 = [m[0], m[1], m[2]];
    final origG0 = [m[5], m[6], m[7]];
    final origB0 = [m[10], m[11], m[12]];

    for (var c = 0; c < 3; c++) {
      r[0 + c] = hue3x3[0] * origR0[c] + hue3x3[1] * origG0[c] + hue3x3[2] * origB0[c];
      r[5 + c] = hue3x3[3] * origR0[c] + hue3x3[4] * origG0[c] + hue3x3[5] * origB0[c];
      r[10 + c] = hue3x3[6] * origR0[c] + hue3x3[7] * origG0[c] + hue3x3[8] * origB0[c];
    }
    return r;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
