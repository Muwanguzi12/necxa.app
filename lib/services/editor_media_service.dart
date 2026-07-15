import 'dart:io';

import 'package:image_picker/image_picker.dart';

/// Shared import and session-media source for every editor surface.
///
/// This deliberately owns no UI. Desktop and mobile both use it for the same
/// picker, asset classification, file metadata, and recently imported assets.
class EditorMediaAsset {
  final File file;
  final DateTime importedAt;
  final int sizeBytes;

  const EditorMediaAsset({
    required this.file,
    required this.importedAt,
    required this.sizeBytes,
  });

  String get path => file.path;
  String get name => path.split(Platform.pathSeparator).last;

  String get extension => name.contains('.') ? name.split('.').last.toLowerCase() : '';
  bool get isVideo => const {'mp4', 'mov', 'mkv', 'avi', 'webm', 'm4v'}.contains(extension);
  bool get isImage => const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic'}.contains(extension);
  String get category => isVideo ? 'Videos' : isImage ? 'Photos' : 'Files';
}

class EditorMediaService {
  EditorMediaService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;
  static final List<EditorMediaAsset> _recent = <EditorMediaAsset>[];

  List<EditorMediaAsset> get recentAssets => List.unmodifiable(_recent);

  Future<List<EditorMediaAsset>> pickMedia() async {
    final selected = await _picker.pickMultipleMedia();
    final assets = <EditorMediaAsset>[];
    for (final item in selected) {
      final file = File(item.path);
      if (!await file.exists()) continue;
      assets.add(EditorMediaAsset(
        file: file,
        importedAt: DateTime.now(),
        sizeBytes: await file.length(),
      ));
    }
    registerAll(assets);
    return assets;
  }

  void registerFile(File file) {
    if (!file.existsSync()) return;
    final asset = EditorMediaAsset(
      file: file,
      importedAt: DateTime.now(),
      sizeBytes: file.lengthSync(),
    );
    registerAll([asset]);
  }

  void registerAll(Iterable<EditorMediaAsset> assets) {
    for (final asset in assets) {
      _recent.removeWhere((existing) => existing.path == asset.path);
      _recent.insert(0, asset);
    }
  }
}
