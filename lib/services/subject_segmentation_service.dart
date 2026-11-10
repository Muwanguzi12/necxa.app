import 'dart:io';

import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Produces a local grayscale subject matte for Text Studio.
/// Decoding and segmentation are performed in two-second batches. No frames
/// are uploaded; temporary source frames are deleted after each batch.
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
  static const int _batchDurationSeconds = 2;
  static const int _maxFrames = _maxDurationSeconds * _fps;
  static const int _maxSourceBytes = 1024 * 1024 * 1024;

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
    if (sourceVideo.lengthSync() > _maxSourceBytes) {
      throw ArgumentError('Subject masking supports source files up to 1 GB.');
    }

    final support = await getTemporaryDirectory();
    final jobDir = await Directory(
      p.join(support.path, 'necxa_subject_${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
    final maskDir = await Directory(p.join(jobDir.path, 'masks')).create();
    // Keep the returned matte outside the scratch directory: scratch frames and
    // PNG masks are deleted in finally, while the caller owns this output file.
    final maskVideo = File(p.join(
      support.path,
      'necxa_subject_mask_${DateTime.now().microsecondsSinceEpoch}.mkv',
    ));
    SelfieSegmenter? segmenter;
    var frameCount = 0;
    var outputWidth = 0;
    var outputHeight = 0;

    try {
      // Keep the ML Kit mask at its bounded model resolution. The renderer
      // scales this matte to the video dimensions during compositing.
      // Segmentation is deliberately capped at 120 seconds to bound on-device
      // compute and scratch storage, even when the source file is up to 1 GB.
      segmenter = SelfieSegmenter(
        mode: SegmenterMode.stream,
        enableRawSizeMask: false,
      );

      for (var batchStart = 0;
          batchStart < _maxDurationSeconds && frameCount < _maxFrames;
          batchStart += _batchDurationSeconds) {
        if (_cancelled) return null;

        final frameDir = await Directory(
          p.join(jobDir.path, 'frames_${batchStart.toString().padLeft(3, '0')}'),
        ).create();
        try {
          final framePattern = p.join(frameDir.path, 'frame_%04d.jpg');
          final extract = await FFmpegKit.execute(
            '-hide_banner -loglevel error -ss $batchStart '
            '-t $_batchDurationSeconds -i "${_escape(sourceVideo.path)}" '
            '-vf "fps=$_fps,scale=$_maxWidth:-2" -q:v 5 -vsync 0 '
            '-y "${_escape(framePattern)}"',
          );
          if (!ReturnCode.isSuccess(await extract.getReturnCode())) {
            throw StateError('Could not decode a video batch for segmentation.');
          }

          final frames = frameDir
              .listSync()
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.jpg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

          // An empty batch means the source has ended.
          if (frames.isEmpty) break;

          for (final frame in frames) {
            if (_cancelled || frameCount >= _maxFrames) return null;
            final mask = await segmenter.processImage(
              InputImage.fromFilePath(frame.path),
            );
            if (mask == null || mask.confidences.isEmpty) {
              throw StateError('Subject segmentation returned an empty mask.');
            }

            outputWidth = mask.width;
            outputHeight = mask.height;
            final expected = mask.width * mask.height;
            if (mask.width <= 0 ||
                mask.height <= 0 ||
                mask.confidences.length < expected) {
              throw StateError('Subject mask dimensions were incomplete.');
            }

            final matte = img.Image(width: mask.width, height: mask.height);
            for (var y = 0; y < mask.height; y++) {
              for (var x = 0; x < mask.width; x++) {
                final value = (mask.confidences[y * mask.width + x]
                            .clamp(0.0, 1.0) *
                        255)
                    .round();
                matte.setPixelRgba(x, y, value, value, value, 255);
              }
            }

            frameCount++;
            final maskFile = File(
              p.join(
                maskDir.path,
                'mask_${frameCount.toString().padLeft(6, '0')}.png',
              ),
            );
            await maskFile.writeAsBytes(img.encodePng(matte), flush: false);
            onProgress?.call(
              (frameCount / _maxFrames).clamp(0.0, 1.0),
            );
          }
        } finally {
          // Never retain decoded source frames between batches.
          if (frameDir.existsSync()) {
            await frameDir.delete(recursive: true);
          }
        }

        if (frameCount >= _maxFrames) break;
      }

      if (_cancelled || frameCount == 0) return null;
      if (frameCount >= _maxFrames) {
        throw StateError(
          'Subject masking is limited to 120 seconds per clip. '
          'The source file is supported, but its full-length subject matte '
          'cannot be generated within the current on-device processing budget.',
        );
      }

      final maskPattern = p.join(maskDir.path, 'mask_%06d.png');
      final encode = await FFmpegKit.execute(
        '-hide_banner -loglevel error -framerate $_fps '
        '-i "${_escape(maskPattern)}" -an -vf format=gray '
        '-c:v ffv1 -pix_fmt gray -y "${_escape(maskVideo.path)}"',
      );
      if (!ReturnCode.isSuccess(await encode.getReturnCode()) ||
          !maskVideo.existsSync() ||
          maskVideo.lengthSync() == 0) {
        throw StateError('Could not encode the subject matte video.');
      }

      return SubjectSegmentationResult(
        maskVideoPath: maskVideo.path,
        frameCount: frameCount,
        framesPerSecond: _fps,
        width: outputWidth,
        height: outputHeight,
        durationSeconds: frameCount / _fps,
      );
    } catch (_) {
      try {
        if (jobDir.existsSync()) await jobDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      await segmenter?.close();
      try {
        if (jobDir.existsSync()) await jobDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _escape(String value) => value.replaceAll('"', r'\"');
}
