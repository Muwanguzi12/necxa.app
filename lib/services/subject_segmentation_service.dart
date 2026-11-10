import 'dart:io';

import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Produces a local, time-aligned grayscale subject matte for Text Studio.
/// Frames are sampled at 8 fps and 640 px width. No video frames are uploaded.
class SubjectSegmentationResult {
  final String maskVideoPath;
  final int frameCount;
  final int framesPerSecond;
  final int width;
  final int height;
  final double durationSeconds;

  const SubjectSegmentationResult({
    required this.maskVideoPath,
    required this.frameCount,
    required this.framesPerSecond,
    required this.width,
    required this.height,
    required this.durationSeconds,
  });
}

class SubjectSegmentationService {
  static const int _fps = 8;
  static const int _maxWidth = 640;
  static const int _maxDurationSeconds = 120;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<SubjectSegmentationResult?> generateMaskVideo({
    required File sourceVideo,
    void Function(double progress)? onProgress,
  }) async {
    _cancelled = false;
    if (!sourceVideo.existsSync() || sourceVideo.lengthSync() == 0) {
      throw ArgumentError('The source video is missing or empty.');
    }

    final support = await getTemporaryDirectory();
    final jobDir = await Directory(
      p.join(support.path, 'necxa_subject_${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
    final frameDir = await Directory(p.join(jobDir.path, 'frames')).create();
    final maskDir = await Directory(p.join(jobDir.path, 'masks')).create();
    final maskVideo = File(p.join(jobDir.path, 'subject_mask.mkv'));

    try {
      final framePattern = p.join(frameDir.path, 'frame_%06d.jpg');
      final extract = await FFmpegKit.execute(
        "-hide_banner -loglevel error -i \"${_escape(sourceVideo.path)}\" "
        "-t $_maxDurationSeconds -vf \"fps=$_fps,scale=$_maxWidth:-2\" "
        "-q:v 4 -vsync 0 -y \"${_escape(framePattern)}\"",
      );
      if (!ReturnCode.isSuccess(await extract.getReturnCode())) {
        throw StateError('Could not prepare video frames for subject segmentation.');
      }

      final frames = frameDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (frames.isEmpty) return null;

      final segmenter = SelfieSegmenter(
        mode: SegmenterMode.stream,
        enableRawSizeMask: true,
      );
      var outputWidth = 0;
      var outputHeight = 0;
      try {
        for (var index = 0; index < frames.length; index++) {
          if (_cancelled) return null;
          final mask = await segmenter.processImage(
            InputImage.fromFilePath(frames[index].path),
          );
          if (mask == null || mask.confidences.isEmpty) {
            throw StateError('Subject segmentation returned an empty mask.');
          }

          outputWidth = mask.width;
          outputHeight = mask.height;
          final matte = img.Image(width: mask.width, height: mask.height);
          final confidences = mask.confidences;
          final expected = mask.width * mask.height;
          if (confidences.length < expected) {
            throw StateError('Subject mask dimensions were incomplete.');
          }

          for (var y = 0; y < mask.height; y++) {
            for (var x = 0; x < mask.width; x++) {
              final value = (confidences[y * mask.width + x]
                          .clamp(0.0, 1.0) *
                      255)
                  .round();
              matte.setPixelRgba(x, y, value, value, value, 255);
            }
          }

          final maskFile = File(
            p.join(
              maskDir.path,
              'mask_${(index + 1).toString().padLeft(6, '0')}.png',
            ),
          );
          await maskFile.writeAsBytes(img.encodePng(matte), flush: false);
          onProgress?.call((index + 1) / frames.length);
        }
      } finally {
        await segmenter.close();
      }

      if (_cancelled) return null;
      final maskPattern = p.join(maskDir.path, 'mask_%06d.png');
      final encode = await FFmpegKit.execute(
        "-hide_banner -loglevel error -framerate $_fps "
        "-i \"${_escape(maskPattern)}\" -an -vf format=gray "
        "-c:v ffv1 -pix_fmt gray -y \"${_escape(maskVideo.path)}\"",
      );
      if (!ReturnCode.isSuccess(await encode.getReturnCode()) ||
          !maskVideo.existsSync() ||
          maskVideo.lengthSync() == 0) {
        throw StateError('Could not encode the subject matte video.');
      }

      await frameDir.delete(recursive: true);
      await maskDir.delete(recursive: true);
      return SubjectSegmentationResult(
        maskVideoPath: maskVideo.path,
        frameCount: frames.length,
        framesPerSecond: _fps,
        width: outputWidth,
        height: outputHeight,
        durationSeconds: frames.length / _fps,
      );
    } catch (_) {
      try {
        if (jobDir.existsSync()) await jobDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      try {
        if (frameDir.existsSync()) await frameDir.delete(recursive: true);
        if (maskDir.existsSync()) await maskDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _escape(String value) => value.replaceAll('"', r'\"');
}
