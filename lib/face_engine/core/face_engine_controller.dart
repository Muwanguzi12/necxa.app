import '../models/face_preset.dart';
import '../presets/face_presets.dart';

class FaceEngineController {
  static const double freeIntensityLimit = 0.5;

  FacePreset _selectedPreset;
  double _intensity;

  FaceEngineController({
    FacePreset selectedPreset = FacePresets.natural,
    double intensity = 0.5,
  }) : _selectedPreset = selectedPreset,
       _intensity = intensity.clamp(0.0, 1.0);

  FacePreset get selectedPreset => _selectedPreset;
  double get intensity => _intensity;

  bool selectPreset(FacePreset preset, {required bool isPro}) {
    if (preset.isPro && !isPro) return false;
    _selectedPreset = preset;
    _intensity = _intensity.clamp(0.0, maxIntensity(isPro));
    return true;
  }

  void setIntensity(double value, {required bool isPro}) {
    _intensity = value.clamp(0.0, maxIntensity(isPro));
  }

  double maxIntensity(bool isPro) => isPro ? 1.0 : freeIntensityLimit;

  FaceRenderParameters get parameters =>
      _selectedPreset.atIntensity(_intensity);
}
