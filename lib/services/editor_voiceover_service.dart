import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class RecordedVoiceover {
  final File file;
  final Duration duration;

  const RecordedVoiceover({required this.file, required this.duration});
}

/// Shared voiceover engine for desktop and mobile editor surfaces.
class EditorVoiceoverService {
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _clock = Stopwatch();

  bool get isRecording => _clock.isRunning;
  bool get isPaused => !_clock.isRunning && _started;
  bool _started = false;
  static final List<RecordedVoiceover> _recentRecordings = <RecordedVoiceover>[];
  Duration get elapsed => _clock.elapsed;
  List<RecordedVoiceover> get recentRecordings => List.unmodifiable(_recentRecordings);

  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/voiceover_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(), path: path);
    _clock
      ..reset()
      ..start();
    _started = true;
    return true;
  }

  Future<void> pause() async {
    if (!isRecording) return;
    await _recorder.pause();
    _clock.stop();
  }

  Future<void> resume() async {
    if (!isPaused) return;
    await _recorder.resume();
    _clock.start();
  }

  Future<RecordedVoiceover?> stop() async {
    if (!_started) return null;
    final duration = _clock.elapsed;
    final path = await _recorder.stop();
    _clock.reset();
    _started = false;
    if (path == null) return null;
    final recording = RecordedVoiceover(file: File(path), duration: duration);
    _recentRecordings.removeWhere((item) => item.file.path == recording.file.path);
    _recentRecordings.insert(0, recording);
    return recording;
  }

  Future<void> dispose() => _recorder.dispose();
}
