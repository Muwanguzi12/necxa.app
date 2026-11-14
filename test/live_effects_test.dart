import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/effects_engine/necxa_effects_engine.dart';
import 'package:necxa_flutter/services/filter_catalogue_service.dart';

void main() {
  group('Live Effects & Filter Catalogue Engine', () {
    test('NecxaFilterMeta.none is correctly identified as normal', () {
      expect(NecxaFilterMeta.none.isNone, isTrue);
      expect(NecxaFilterMeta.none.displayName, 'Normal');
    });

    test('NecxaFilterMeta parses effect parameters correctly', () {
      final json = {
        'id': 'test-123',
        'display_name': 'Cinema Teaser',
        'category': 'color',
        'effect_params': {
          'brightness': 0.1,
          'contrast': 1.2,
          'saturation': 1.3,
          'hue': 0.05,
          'colorMatrixPreset': 'cinema',
        },
      };

      final meta = NecxaFilterMeta.fromJson(json);
      expect(meta.id, 'test-123');
      expect(meta.displayName, 'Cinema Teaser');
      expect(meta.category, 'color');
      expect(meta.brightness, 0.1);
      expect(meta.contrast, 1.2);
      expect(meta.saturation, 1.3);
      expect(meta.hue, 0.05);
      expect(meta.colorMatrixPreset, 'cinema');
      expect(meta.isNone, isFalse);
    });

    test('NecxaEffectsEngine returns identity matrix for none', () {
      final matrix = NecxaEffectsEngine.buildMatrixForMeta(NecxaFilterMeta.none);
      expect(matrix, hasLength(20));
      // Row 0: 1, 0, 0, 0, 0
      expect(matrix[0], 1.0);
      expect(matrix[1], 0.0);
      // Row 1: 0, 1, 0, 0, 0
      expect(matrix[6], 1.0);
      // Row 2: 0, 0, 1, 0, 0
      expect(matrix[12], 1.0);
      // Row 3: 0, 0, 0, 1, 0
      expect(matrix[18], 1.0);
    });

    test('Intensity scaling smoothly transitions matrix toward identity', () {
      const meta = NecxaFilterMeta(
        id: 'glow_test',
        displayName: 'Glow Test',
        category: 'glow',
        brightness: 0.2,
        contrast: 1.1,
        saturation: 1.4,
      );

      final fullMatrix = NecxaEffectsEngine.buildMatrixForMeta(meta, intensity: 1.0);
      final zeroMatrix = NecxaEffectsEngine.buildMatrixForMeta(meta, intensity: 0.0);
      final halfMatrix = NecxaEffectsEngine.buildMatrixForMeta(meta, intensity: 0.5);

      // At zero intensity, should match identity (no effect)
      expect(zeroMatrix[0], closeTo(1.0, 0.001));
      expect(zeroMatrix[4], closeTo(0.0, 0.001));

      // At full intensity, brightness offset is applied
      expect(fullMatrix[4], greaterThan(0.0));

      // Half intensity should lie between zero and full
      expect(halfMatrix[4], lessThan(fullMatrix[4]));
      expect(halfMatrix[4], greaterThan(zeroMatrix[4]));
    });

    test('FFmpeg filter generator builds valid video filter strings', () {
      const meta = NecxaFilterMeta(
        id: 'vivid_test',
        displayName: 'Vivid Test',
        category: 'color',
        brightness: 0.05,
        contrast: 1.15,
        saturation: 1.5,
      );

      final ffmpegStr = NecxaEffectsEngine.buildFfmpegEqFilter(meta);
      expect(ffmpegStr, contains('eq=brightness=0.0500'));
      expect(ffmpegStr, contains('contrast=1.1500'));
      expect(ffmpegStr, contains('saturation=1.5000'));
    });
  });
}
