enum FacePresetAudience { universal, masculine, feminine }

class FacePreset {
  final String id;
  final String name;
  final FacePresetAudience audience;
  final bool isPro;
  final double skinSmooth;
  final double skinTone;
  final double eyeEnhance;
  final double lipEnhance;
  final double jawDefinition;
  final double faceShape;
  final double lighting;
  final double sharpening;
  final double beardDetail;
  final double complexion;

  const FacePreset({
    required this.id,
    required this.name,
    required this.audience,
    required this.isPro,
    this.skinSmooth = 0,
    this.skinTone = 0,
    this.eyeEnhance = 0,
    this.lipEnhance = 0,
    this.jawDefinition = 0,
    this.faceShape = 0,
    this.lighting = 0,
    this.sharpening = 0,
    this.beardDetail = 0,
    this.complexion = 0,
  });

  FaceRenderParameters atIntensity(double intensity) {
    final amount = intensity.clamp(0.0, 1.0);
    return FaceRenderParameters(
      presetId: id,
      intensity: amount,
      skinSmooth: skinSmooth * amount,
      skinTone: skinTone * amount,
      eyeEnhance: eyeEnhance * amount,
      lipEnhance: lipEnhance * amount,
      jawDefinition: jawDefinition * amount,
      faceShape: faceShape * amount,
      lighting: lighting * amount,
      sharpening: sharpening * amount,
      beardDetail: beardDetail * amount,
      complexion: complexion * amount,
    );
  }
}

class FaceRenderParameters {
  final String presetId;
  final double intensity;
  final double skinSmooth;
  final double skinTone;
  final double eyeEnhance;
  final double lipEnhance;
  final double jawDefinition;
  final double faceShape;
  final double lighting;
  final double sharpening;
  final double beardDetail;
  final double complexion;

  const FaceRenderParameters({
    required this.presetId,
    required this.intensity,
    required this.skinSmooth,
    required this.skinTone,
    required this.eyeEnhance,
    required this.lipEnhance,
    required this.jawDefinition,
    required this.faceShape,
    required this.lighting,
    required this.sharpening,
    required this.beardDetail,
    required this.complexion,
  });

  bool get isEnabled => presetId != 'original' && intensity > 0;
}
