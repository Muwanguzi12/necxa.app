import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:video_compress/video_compress.dart';
import 'package:path_provider/path_provider.dart';

import 'data_saver_service.dart';

class MediaCompressionService {
  /// Compresses an image to a specific quality and max dimensions.
  static Future<File> compressImage(
    File file, {
    int? quality,
    int? maxSize,
  }) async {
    final ds = DataSaverService();
    final targetQuality = quality ?? ds.imageQuality;
    final targetMaxSize = maxSize ?? (ds.isEnabled ? 720 : 1280);
    try {
      final bytes = await file.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) throw Exception('Unsupported or damaged image');

      // Resize if too large
      if (image.width > targetMaxSize || image.height > targetMaxSize) {
        image = img.copyResize(
          image,
          width: image.width > image.height ? targetMaxSize : null,
          height: image.height >= image.width ? targetMaxSize : null,
          interpolation: img.Interpolation.linear,
        );
      }

      final compressedBytes = img.encodeJpg(image, quality: targetQuality);
      final tempDir = await getTemporaryDirectory();
      final compressedFile = File(
        '${tempDir.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await compressedFile.writeAsBytes(compressedBytes);

      return compressedFile;
    } catch (e) {
      debugPrint('Image Compression Error: $e');
      throw Exception('Image compression failed: $e');
    }
  }

  /// Compresses a video.
  static Future<File> compressVideo(File file) async {
    try {
      final quality = DataSaverService().isEnabled
          ? VideoQuality.LowQuality
          : VideoQuality.MediumQuality;
      final info = await VideoCompress.compressVideo(
        file.path,
        quality: quality,
        deleteOrigin: false,
        includeAudio: true,
      );

      final compressed = info?.file;
      if (compressed == null || !await compressed.exists()) {
        throw Exception('The video compressor returned no output');
      }
      return compressed;
    } catch (e) {
      debugPrint('Video Compression Error: $e');
      throw Exception('Video compression failed: $e');
    }
  }

  /// Generic helper that detects type and compresses.
  static Future<File> optimizeMedia(File file) async {
    final path = file.path.toLowerCase();
    if (path.endsWith('.mp4') ||
        path.endsWith('.mov') ||
        path.endsWith('.avi')) {
      return await compressVideo(file);
    } else if (path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png')) {
      return await compressImage(file);
    }
    return file;
  }
}
