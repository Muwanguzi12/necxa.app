import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/face_engine/core/face_engine_controller.dart';
import 'package:necxa_flutter/face_engine/presets/face_presets.dart';

void main() {
  group('Face Engine presets', () {
    test('catalog exposes three free and four Pro presets', () {
      expect(FacePresets.all, hasLength(7));
      expect(
        FacePresets.all.where((preset) => !preset.isPro).map((p) => p.id),
        ['original', 'natural', 'fresh'],
      );
      expect(FacePresets.all.where((preset) => preset.isPro).map((p) => p.id), [
        'sharp',
        'glow',
        'glam',
        'soft',
      ]);
    });

    test('all preset values remain normalized', () {
      for (final preset in FacePresets.all) {
        final values = [
          preset.skinSmooth,
          preset.skinTone,
          preset.eyeEnhance,
          preset.lipEnhance,
          preset.jawDefinition,
          preset.faceShape,
          preset.lighting,
          preset.sharpening,
          preset.beardDetail,
          preset.complexion,
        ];
        expect(
          values.every((value) => value >= 0 && value <= 1),
          isTrue,
          reason: '${preset.name} has an out-of-range value',
        );
      }
    });

    test('free users cannot select Pro presets or exceed 50 percent', () {
      final controller = FaceEngineController();

      expect(controller.selectPreset(FacePresets.glam, isPro: false), isFalse);
      expect(controller.selectedPreset, FacePresets.natural);

      controller.setIntensity(1, isPro: false);
      expect(controller.intensity, FaceEngineController.freeIntensityLimit);
    });

    test('Pro users receive intensity-scaled render parameters', () {
      final controller = FaceEngineController();
      expect(controller.selectPreset(FacePresets.glow, isPro: true), isTrue);
      controller.setIntensity(0.75, isPro: true);

      final parameters = controller.parameters;
      expect(parameters.intensity, 0.75);
      expect(parameters.skinSmooth, FacePresets.glow.skinSmooth * 0.75);
      expect(parameters.lighting, FacePresets.glow.lighting * 0.75);
      expect(parameters.isEnabled, isTrue);
    });

    test('Original never enables processing', () {
      final controller = FaceEngineController(
        selectedPreset: FacePresets.original,
        intensity: 1,
      );

      expect(controller.parameters.isEnabled, isFalse);
    });
  });
}
