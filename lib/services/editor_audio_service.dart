import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';

enum EditorAudioKind { music, voiceover, soundEffect, deviceFile }

class EditorAudioAsset {
  final String id;
  final String name;
  final String source;
  final EditorAudioKind kind;
  final Duration duration;
  final int sizeBytes;
  final String? artist;

  const EditorAudioAsset({required this.id, required this.name, required this.source, required this.kind, this.duration = Duration.zero, this.sizeBytes = 0, this.artist});
}

/// Shared editor audio library and non-destructive preview transport.
class EditorAudioService {
  final AudioPlayer _preview = AudioPlayer();
  static final List<EditorAudioAsset> _recent = <EditorAudioAsset>[];
  static final Set<String> _favorites = <String>{};

  List<EditorAudioAsset> get recent => List.unmodifiable(_recent);
  Set<String> get favorites => Set.unmodifiable(_favorites);

  Future<List<EditorAudioAsset>> importDeviceAudio() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true, withData: false);
    if (result == null) return [];
    final assets = <EditorAudioAsset>[];
    for (final file in result.files) {
      if (file.path == null) continue;
      final local = File(file.path!);
      final size = await local.exists() ? await local.length() : 0;
      final asset = EditorAudioAsset(id: 'audio-${DateTime.now().microsecondsSinceEpoch}-${assets.length}', name: file.name, source: local.path, kind: EditorAudioKind.deviceFile, sizeBytes: size);
      register(asset);
      assets.add(asset);
    }
    return assets;
  }

  void register(EditorAudioAsset asset) {
    _recent.removeWhere((item) => item.source == asset.source);
    _recent.insert(0, asset);
  }

  void toggleFavorite(String id) => _favorites.contains(id) ? _favorites.remove(id) : _favorites.add(id);

  Future<void> play(EditorAudioAsset asset, {bool loop = false}) async {
    await _preview.stop();
    await _preview.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
    await _preview.play(asset.source.startsWith('http') ? UrlSource(asset.source) : DeviceFileSource(asset.source));
  }

  Future<void> pause() => _preview.pause();
  Future<void> seek(Duration position) => _preview.seek(position);
  Future<void> stop() => _preview.stop();
  Future<void> dispose() => _preview.dispose();
}
