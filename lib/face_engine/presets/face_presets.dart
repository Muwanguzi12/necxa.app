import '../models/face_preset.dart';

abstract final class FacePresets {
  static const original = FacePreset(
    id: 'original',
    name: 'Original',
    audience: FacePresetAudience.universal,
    isPro: false,
  );

  static const natural = FacePreset(
    id: 'natural',
    name: 'Natural',
    audience: FacePresetAudience.universal,
    isPro: false,
    skinSmooth: 0.28,
    skinTone: 0.18,
    eyeEnhance: 0.1,
    lighting: 0.18,
    sharpening: 0.08,
    complexion: 0.22,
  );

  static const fresh = FacePreset(
    id: 'fresh',
    name: 'Fresh',
    audience: FacePresetAudience.masculine,
    isPro: false,
    skinSmooth: 0.2,
    skinTone: 0.24,
    eyeEnhance: 0.12,
    jawDefinition: 0.14,
    lighting: 0.28,
    sharpening: 0.16,
    beardDetail: 0.12,
    complexion: 0.24,
  );

  static const sharp = FacePreset(
    id: 'sharp',
    name: 'Sharp',
    audience: FacePresetAudience.masculine,
    isPro: true,
    skinSmooth: 0.12,
    eyeEnhance: 0.24,
    jawDefinition: 0.4,
    lighting: 0.2,
    sharpening: 0.55,
    beardDetail: 0.52,
    complexion: 0.16,
  );

  static const glow = FacePreset(
    id: 'glow',
    name: 'Glow',
    audience: FacePresetAudience.feminine,
    isPro: true,
    skinSmooth: 0.48,
    skinTone: 0.35,
    eyeEnhance: 0.24,
    lipEnhance: 0.18,
    lighting: 0.55,
    sharpening: 0.1,
    complexion: 0.5,
  );

  static const glam = FacePreset(
    id: 'glam',
    name: 'Glam',
    audience: FacePresetAudience.feminine,
    isPro: true,
    skinSmooth: 0.62,
    skinTone: 0.44,
    eyeEnhance: 0.48,
    lipEnhance: 0.46,
    jawDefinition: 0.2,
    faceShape: 0.18,
    lighting: 0.52,
    sharpening: 0.2,
    complexion: 0.58,
  );

  static const soft = FacePreset(
    id: 'soft',
    name: 'Soft',
    audience: FacePresetAudience.feminine,
    isPro: true,
    skinSmooth: 0.72,
    skinTone: 0.28,
    eyeEnhance: 0.16,
    lipEnhance: 0.12,
    faceShape: 0.1,
    lighting: 0.42,
    sharpening: 0.04,
    complexion: 0.5,
  );

  static const all = [original, natural, fresh, sharp, glow, glam, soft];
}
