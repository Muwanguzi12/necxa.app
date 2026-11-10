import 'dart:io';

import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Runs audio processing through Necxa's bundled FFmpeg engine.
///
/// Every operation writes a new file. The input is never overwritten.
class AudioEnhancementService {
  static final Uuid _uuid = Uuid();

  /// Applies one of the public studio effects and writes a new audio file.
  /// Effect strength is normalized to 0..1; source audio is never overwritten.
  Future<File> applyEffect({
    required File inputAudio,
    required AudioEffect effect,
    double amount = 0.5,
    void Function(double)? onProgress,
  }) async {
    _validateInput(inputAudio);
    final strength = _unit(amount, 'amount');
    if (strength == 0) {
      throw ArgumentError('Effect amount must be greater than zero.');
    }

    final filters = <String>[];
    switch (effect) {
      case AudioEffect.reverb:
        final delay = (35 + strength * 115).round();
        final decay = 0.12 + strength * 0.55;
        filters.add('aecho=0.85:0.9:$delay:${_number(decay)}');
        break;
      case AudioEffect.echo:
        final delay = (90 + strength * 410).round();
        final decay = 0.15 + strength * 0.65;
        filters.add('aecho=0.8:0.88:$delay:${_number(decay)}');
        break;
      case AudioEffect.chorus:
        // Multi-voice chorus using FFmpeg's native chorus filter.
        filters.add(
          'chorus=0.7:0.9:'
          '${(18 + strength * 42).round()}|${(28 + strength * 54).round()}:'
          '0.35|0.25:0.25|0.4:${_number(1.2 + strength * 2.8)}|${_number(0.8 + strength * 2.0)}',
        );
        break;
      case AudioEffect.flanger:
        filters.add(
          'flanger=delay=${_number(1 + strength * 4)}:'
          'depth=${_number(1 + strength * 5)}:'
          'regen=${_number(strength * 45)}:'
          'width=${_number(50 + strength * 50)}:'
          'speed=${_number(0.1 + strength * 0.8)}',
        );
        break;
      case AudioEffect.distortion:
        filters.add(
          'asoftclip=type=atan:threshold=${_number(1 - strength * 0.75)}:'
          'output=1:oversample=4',
        );
        break;
      case AudioEffect.robot:
        // Tremolo plus short, metallic reflections creates a robot-style
        // modulation; this is an effect, not AI voice conversion.
        filters
          ..add('tremolo=f=${_number(18 + strength * 42)}:d=${_number(0.35 + strength * 0.55)}')
          ..add('aecho=0.8:0.75:18:0.45');
        break;
      case AudioEffect.telephone:
        filters
          ..add('highpass=f=300')
          ..add('lowpass=f=3400')
          ..add('acompressor=threshold=-20dB:ratio=3:attack=10:release=120');
        break;
      case AudioEffect.stadium:
        filters
          ..add('aecho=0.8:0.92:'
              '${(75 + strength * 175).round()}|${(110 + strength * 240).round()}:'
              '${_number(0.35 + strength * 0.35)}|${_number(0.2 + strength * 0.25)}');
        break;
    }

    return _renderAudio(
      inputAudio: inputAudio,
      filters: filters,
      onProgress: onProgress,
      outputLabel: 'effect_${effect.name}',
    );
  }

  Future<File> enhanceAudio({
    required File inputAudio,
    AudioEnhancementOptions options = const AudioEnhancementOptions(),
    void Function(double progress)? onProgress,
  }) async {
    _validateInput(inputAudio);
    if (options.pitchShift.abs() > 0.0001) {
      throw UnsupportedError(
        'Pitch shifting is not enabled in the current Necxa FFmpeg profile.',
      );
    }

    final filters = <String>[];
    final noise = _unit(options.noiseReduction, 'noiseReduction');
    final compression = _unit(options.compression, 'compression');
    final reverb = _unit(options.reverbAmount, 'reverbAmount');

    if (noise > 0) filters.add(_noiseFilter(noise));
    if (options.voiceIsolation) {
      filters
        ..add('highpass=f=80')
        ..add('lowpass=f=12000');
      if (noise == 0) filters.add(_noiseFilter(0.55));
    }
    if (options.equalizerEnabled) {
      for (final entry in options.equalizerBands.entries) {
        final frequency = entry.key;
        final gain = entry.value;
        if (frequency < 20 || frequency > 20000 ||
            !gain.isFinite || gain < -24 || gain > 24) {
          throw ArgumentError(
            'Equalizer bands require frequencies 20–20000 Hz and gains -24 to 24 dB.',
          );
        }
        if (gain.abs() > 0.001) {
          filters.add(
            'equalizer=f=$frequency:width_type=o:width=1:g=${_number(gain)}',
          );
        }
      }
    }
    if (compression > 0) {
      final ratio = 1 + compression * 5;
      final threshold = -18 - compression * 12;
      filters.add(
        'acompressor=threshold=${_number(threshold)}dB:'
        'ratio=${_number(ratio)}:attack=20:release=250',
      );
    }
    if (reverb > 0) {
      final delay = (35 + reverb * 90).round();
      final decay = 0.15 + reverb * 0.45;
      filters.add('aecho=0.8:0.88:$delay:${_number(decay)}');
    }
    if (options.normalizeVolume) {
      filters.add('loudnorm=I=-16:TP=-1.5:LRA=11');
    }
    if (filters.isEmpty) {
      throw ArgumentError('Select at least one audio enhancement option.');
    }

    return _renderAudio(
      inputAudio: inputAudio,
      filters: filters,
      onProgress: onProgress,
      outputLabel: 'enhanced',
    );
  }

  Future<File> removeBackgroundNoise({
    required File inputAudio,
    double noiseReductionLevel = 0.8,
    void Function(double)? onProgress,
  }) async {
    _validateInput(inputAudio);
    final level = _unit(noiseReductionLevel, 'noiseReductionLevel');
    if (level == 0) {
      throw ArgumentError('Noise reduction level must be greater than zero.');
    }
    return _renderAudio(
      inputAudio: inputAudio,
      filters: [_noiseFilter(level), 'loudnorm=I=-16:TP=-1.5:LRA=11'],
      onProgress: onProgress,
      outputLabel: 'denoised',
    );
  }

  Future<File> enhanceVoiceClarity({
    required File inputAudio,
    VoiceEnhancementType type = VoiceEnhancementType.natural,
    void Function(double)? onProgress,
  }) async {
    _validateInput(inputAudio);
    final filters = <String>[
      'highpass=f=80',
      'lowpass=f=12000',
      _noiseFilter(0.45),
    ];

    switch (type) {
      case VoiceEnhancementType.natural:
        filters.add('equalizer=f=3000:width_type=o:width=1:g=2');
        break;
      case VoiceEnhancementType.bright:
        filters
          ..add('equalizer=f=3500:width_type=o:width=1:g=3')
          ..add('equalizer=f=8000:width_type=o:width=1:g=1.5');
        break;
      case VoiceEnhancementType.warm:
        filters
          ..add('equalizer=f=180:width_type=o:width=1:g=1.5')
          ..add('equalizer=f=3000:width_type=o:width=1:g=-1');
        break;
      case VoiceEnhancementType.radio:
        filters
          ..add('highpass=f=180')
          ..add('lowpass=f=6500')
          ..add('acompressor=threshold=-22dB:ratio=3:attack=15:release=180');
        break;
    }

    filters.add('loudnorm=I=-16:TP=-1.5:LRA=11');
    return _renderAudio(
      inputAudio: inputAudio,
      filters: filters,
      onProgress: onProgress,
      outputLabel: 'voice',
    );
  }

  Future<File> mixBackgroundMusic({
    required File inputAudio,
    required File backgroundMusic,
    double musicVolume = 0.3,
    double fadeInDuration = 2.0,
    double fadeOutDuration = 2.0,
    void Function(double)? onProgress,
  }) async {
    _validateInput(inputAudio);
    _validateInput(backgroundMusic);
    final volume = _unit(musicVolume, 'musicVolume');
    _validateDuration(fadeInDuration, 'fadeInDuration');
    _validateDuration(fadeOutDuration, 'fadeOutDuration');

    // Probe the master duration so short background tracks can loop cleanly
    // and the fade-out lands at the end of the actual output, not the source
    // music file's end.
    final sourceInfo = await FFprobeKit.getMediaInformation(inputAudio.path);
    final sourceDuration = double.tryParse(
      sourceInfo.getMediaInformation()?.getDuration() ?? '',
    );
    if (sourceDuration == null ||
        !sourceDuration.isFinite ||
        sourceDuration <= 0) {
      throw const AudioProcessingException(
        'Unable to determine the original audio duration for mixing.',
      );
    }

    final musicFilters = <String>[
      'atrim=duration=${_number(sourceDuration)}',
      'asetpts=PTS-STARTPTS',
      'volume=${_number(volume)}',
    ];
    if (fadeInDuration > 0) {
      musicFilters.add(
        'afade=t=in:st=0:d=${_number(fadeInDuration.clamp(0.0, sourceDuration))}',
      );
    }
    final effectiveFadeOut = fadeOutDuration.clamp(0.0, sourceDuration);
    if (effectiveFadeOut > 0) {
      final fadeOutStart = sourceDuration - effectiveFadeOut;
      musicFilters.add(
        'afade=t=out:st=${_number(fadeOutStart)}:d=${_number(effectiveFadeOut)}',
      );
    }

    final output = await _newOutputPath('mixed');
    onProgress?.call(0.05);
    final session = await FFmpegKit.executeWithArguments([
      '-hide_banner',
      '-y',
      '-i', inputAudio.path,
      '-stream_loop', '-1',
      '-i', backgroundMusic.path,
      '-filter_complex',
      '[1:a]${musicFilters.join(',')}[music];'
          '[0:a]aresample=async=1:first_pts=0[original];'
          '[original][music]amix=inputs=2:duration=first:'
          'dropout_transition=2:normalize=0[mix]',
      '-map', '[mix]',
      '-vn',
      '-t', _number(sourceDuration),
      '-c:a', 'aac',
      '-b:a', '192k',
      '-movflags', '+faststart',
      output.path,
    ]);
    onProgress?.call(0.9);
    await _verifySession(session, output);
    onProgress?.call(1);
    return output;
  }

  Future<File> _renderAudio({
    required File inputAudio,
    required List<String> filters,
    required void Function(double)? onProgress,
    required String outputLabel,
  }) async {
    final output = await _newOutputPath(outputLabel);
    onProgress?.call(0.05);
    final session = await FFmpegKit.executeWithArguments([
      '-hide_banner',
      '-y',
      '-i', inputAudio.path,
      '-map', '0:a:0',
      '-vn',
      '-af', filters.join(','),
      '-c:a', 'aac',
      '-b:a', '192k',
      '-movflags', '+faststart',
      output.path,
    ]);
    onProgress?.call(0.9);
    await _verifySession(session, output);
    onProgress?.call(1);
    return output;
  }

  String _noiseFilter(double level) {
    final reductionDb = 6 + level * 18;
    return 'afftdn=nr=${_number(reductionDb)}:nf=-40';
  }

  Future<void> _verifySession(FFmpegSession session, File output) async {
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      final details = (await session.getOutput() ?? '').trim();
      if (await output.exists()) await output.delete();
      final diagnostic = details.length > 600
          ? details.substring(details.length - 600)
          : details;
      throw AudioProcessingException(
        'FFmpeg audio processing failed '
        '(code: ${returnCode?.getValue() ?? 'unknown'}). $diagnostic',
      );
    }
    if (!await output.exists() || await output.length() == 0) {
      throw const AudioProcessingException(
        'FFmpeg reported success but produced no audio file.',
      );
    }
  }

  Future<File> _newOutputPath(String label) async {
    final directory = await getTemporaryDirectory();
    return File(
      '${directory.path}/necxa_${label}_${_uuid.v4()}.m4a',
    );
  }

  void _validateInput(File file) {
    if (!file.existsSync()) {
      throw ArgumentError.value(file.path, 'inputAudio', 'File does not exist.');
    }
    if (file.lengthSync() == 0) {
      throw ArgumentError.value(file.path, 'inputAudio', 'File is empty.');
    }
  }

  double _unit(double value, String name) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw RangeError('$name must be between 0 and 1.');
    }
    return value;
  }

  void _validateDuration(double value, String name) {
    if (!value.isFinite || value < 0 || value > 30) {
      throw RangeError('$name must be between 0 and 30 seconds.');
    }
  }

  String _number(num value) => value.toStringAsFixed(3);

  /// Retained for compatibility with any existing internal callers.
  // ignore: unused_element
  Future<String> _getOutputPath() async =>
      (await _newOutputPath('enhanced')).path;

  void dispose() {}
}

class AudioEnhancementOptions {
  final double noiseReduction;
  final bool voiceIsolation;
  final bool equalizerEnabled;
  final Map<int, double> equalizerBands;
  final double compression;
  final double reverbAmount;
  final double pitchShift;
  final bool normalizeVolume;
  final bool extractMetadata;
  final bool generateWaveform;

  const AudioEnhancementOptions({
    this.noiseReduction = 0.0,
    this.voiceIsolation = false,
    this.equalizerEnabled = false,
    this.equalizerBands = const {},
    this.compression = 0.0,
    this.reverbAmount = 0.0,
    this.pitchShift = 0.0,
    this.normalizeVolume = true,
    this.extractMetadata = true,
    this.generateWaveform = true,
  });
}

enum VoiceEnhancementType { natural, bright, warm, radio }
enum AudioEffect { reverb, echo, chorus, flanger, distortion, robot, telephone, stadium }

class WaveformData {
  final List<double> peaks;
  final double duration;

  WaveformData({required this.peaks, required this.duration});
}

class AudioProcessingException implements Exception {
  final String message;

  const AudioProcessingException(this.message);

  @override
  String toString() => 'AudioProcessingException: $message';
}
