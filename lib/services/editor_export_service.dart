import '../theme.dart';
import 'dart:convert';
import 'package:universal_io/io.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'media_compression_service.dart';
import '../models/edit_models.dart';
import 'video_enhancement_service.dart';
import 'filter_catalogue_service.dart';
import 'ffmpeg_stub.dart'
    if (dart.library.io) 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart'
    show FFprobeKit;

class EditorExportResult {
  final bool success;
  final String? outputPath;
  final String? thumbnailPath;
  final String? verificationSummary;
  final List<String> issues;
  final Map<String, dynamic> verificationPayload;
  final bool audioExpected;

  const EditorExportResult({
    required this.success,
    this.outputPath,
    this.thumbnailPath,
    this.verificationSummary,
    this.issues = const [],
    this.verificationPayload = const {},
    this.audioExpected = false,
  });
}

class EditorExportService {
  static const _exportHistoryKey = 'necxa_editor_export_history_v1';

  static Future<EditorExportResult> exportProject({
    required File sourceVideo,
    String projectName = 'Project',
    String description = '',
    String creatorName = 'Creator',
    String copyright = 'All rights reserved',
    String platform = 'NECXA Platform',
    bool rightsConfirmed = false,
    List<TimelineTrack>? tracks,
    String aspectRatio = '9:16',
    ValueChanged<String>? onStage,
  }) async {
    try {
      if (!rightsConfirmed) {
        return const EditorExportResult(
          success: false,
          issues: [
            'Confirm that you own or are licensed to use this content before publishing.',
          ],
        );
      }
      final tempDir = await getTemporaryDirectory();
      onStage?.call('Saving project');
      final rendered = tracks == null
          ? null
          : await renderTimeline(tracks: tracks, aspectRatio: aspectRatio);
      if (tracks != null && rendered == null) {
        return const EditorExportResult(
          success: false,
          issues: ['The timeline did not produce a final video.'],
        );
      }
      final renderSource = rendered ?? sourceVideo;
      if (!await renderSource.exists() || await renderSource.length() == 0) {
        return const EditorExportResult(
          success: false,
          issues: ['The final video file is missing or empty.'],
        );
      }

      onStage?.call('Compressing video');
      // Timeline renders are already encoded as the final MP4 master. Do not
      // run a second lossy compression pass over the completed audio mix.
      final compressedFile = tracks != null
          ? renderSource
          : await MediaCompressionService.compressVideo(renderSource);
      final audioExpected = tracks == null
          ? await _fileHasAudioStream(sourceVideo)
          : await projectHasAudio(tracks);
      final streamCheck = await inspectFinalMp4(
        compressedFile,
        requireAudio: audioExpected,
      );
      if (streamCheck['video'] != true || streamCheck['valid'] != true) {
        return EditorExportResult(
          success: false,
          issues: [
            audioExpected
                ? 'The exported MP4 is missing its expected video or audio stream.'
                : 'The exported MP4 is missing its video stream.',
          ],
          audioExpected: audioExpected,
        );
      }

      onStage?.call('Preparing publishing package');
      final frameDirectory = await Directory.systemTemp.createTemp(
        'necxa_export_frames_',
      );
      final frameFiles = await NecxaAI.extractVideoFrameFiles(
        compressedFile,
        directory: frameDirectory,
      );
      if (frameFiles.isEmpty) {
        await frameDirectory.delete(recursive: true);
        return const EditorExportResult(
          success: false,
          issues: ['Could not extract video frames for verification'],
        );
      }
      final thumbnailFile = File('${tempDir.path}/${projectName}_thumb.jpg');
      await frameFiles.first.copy(thumbnailFile.path);

      final payload = {
        'project': projectName,
        'description': description,
        'creator': creatorName,
        'copyright': copyright,
        'platform': platform,
        'videoPath': compressedFile.path,
        'thumbnailPath': thumbnailFile.path,
      };

      onStage?.call('Uploading for AI verification');
      final verification = await NecxaAI.verifyVideoWorker(frameFiles);
      try {
        await frameDirectory.delete(recursive: true);
      } catch (_) {}
      final issues = <String>[];
      if (verification['success'] == false) {
        issues.add(
          verification['error']?.toString() ?? 'AI verification failed',
        );
      } else if (!NecxaAI.moderationVerified(verification)) {
        issues.add('AI verification flagged the content');
      }

      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getStringList(_exportHistoryKey) ?? [];
      history.add(jsonEncode(payload));
      await prefs.setStringList(_exportHistoryKey, history.take(20).toList());

      onStage?.call(
        issues.isEmpty
            ? 'Preparing publishing targets'
            : 'Verification needs attention',
      );
      return EditorExportResult(
        success: issues.isEmpty,
        outputPath: compressedFile.path,
        thumbnailPath: thumbnailFile.path,
        verificationSummary: issues.isEmpty ? 'Verified for publishing' : null,
        issues: issues,
        verificationPayload: verification,
        audioExpected: audioExpected,
      );
    } catch (e) {
      debugPrint('Editor export failed: $e');
      return const EditorExportResult(
        success: false,
        issues: ['Export failed'],
      );
    }
  }

  /// The single project-to-renderer adapter used by mobile and desktop export.
  static Future<File?> renderTimeline({
    required List<TimelineTrack> tracks,
    String aspectRatio = '9:16',
  }) async {
    final visualClips =
        tracks
            .where(
              (track) =>
                  track.isVisible &&
                  (track.type == TrackType.video ||
                      track.type == TrackType.images),
            )
            .expand((track) => track.clips)
            .where(
              (clip) =>
                  !clip.isHidden &&
                  clip.file != null &&
                  clip.file!.existsSync(),
            )
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    if (visualClips.isEmpty) return null;

    final clips = <ClipData>[];
    for (final clip in visualClips) {
      final path = clip.file!.path.toLowerCase();
      final isVideo = path.endsWith('.mp4') ||
          path.endsWith('.mov') ||
          path.endsWith('.m4v') ||
          path.endsWith('.mkv') ||
          path.endsWith('.webm');
      clips.add(ClipData(
        path: clip.file!.path,
        start: clip.sourceStart.inMilliseconds / 1000,
        end:
            (clip.sourceEnd ?? clip.sourceStart + clip.sourceDuration)
                .inMilliseconds /
            1000,
        speed: clip.speed,
        volume: clip.volume,
        isVideo: isVideo,
        hasAudio: isVideo && await _fileHasAudioStream(clip.file!),
        reverse: clip.isReversed,
        scale: clip.transform.scale,
        rotation: clip.transform.rotation,
        offsetX: clip.transform.position.dx,
        offsetY: clip.transform.position.dy,
        opacity: clip.transform.opacity,
      ));
    }

    final overlays = <RenderOverlay>[];
    final transitions = <RenderTransition>[];
    final audioTracks = <RenderAudioTrack>[];
    var effects = const RenderEffects();
    for (final track in tracks.where((item) => item.isVisible)) {
      for (final clip in track.clips.where((item) => !item.isHidden)) {
        final operation = clip.operation;
        if (operation is OverlayOperation) {
          overlays.add(
            RenderOverlay(
              type: operation.kind,
              text: operation.text,
              start: clip.start.inMilliseconds / 1000,
              end: (clip.start + clip.duration).inMilliseconds / 1000,
              x: operation.position.dx,
              y: operation.position.dy,
              scale: operation.scale,
              rotation: operation.rotation,
              opacity: operation.opacity,
              fontSize: operation.fontSize,
              color: operation.color,
              background: operation.background,
              backgroundOpacity: operation.backgroundOpacity,
              shadow: operation.shadow,
              align: operation.align,
              fontFamily: operation.fontFamily,
              stroke: operation.stroke,
              animationIn: operation.animationIn,
              animationOut: operation.animationOut,
              depthLayer: operation.depthLayer,
            ),
          );
        } else if (operation is TextOverlay) {
          overlays.add(
            RenderOverlay(
              type: 'text',
              text: operation.text,
              start: clip.start.inMilliseconds / 1000,
              end: (clip.start + clip.duration).inMilliseconds / 1000,
              x: operation.position.dx,
              y: operation.position.dy,
              scale: operation.scale,
              rotation: operation.rotation,
              fontSize: operation.style.fontSize ?? 28,
              color: operation.style.color ?? C.text,
            ),
          );
        } else if (operation is TransitionOperation) {
          if (visualClips.length < 2) continue;
          var afterIndex = 0;
          for (var index = 0; index < visualClips.length - 1; index++) {
            if (clip.start >= visualClips[index].start) afterIndex = index;
          }
          transitions.add(
            RenderTransition(
              afterClipIndex: afterIndex.clamp(0, visualClips.length - 2),
              presetId: operation.presetId,
              duration: operation.duration,
            ),
          );
        } else if (operation is AudioClipOperation) {
          final path = clip.file?.path ?? operation.sourceUrl;
          final effectiveVolume = clip.volume == 1.0
              ? operation.volume
              : clip.volume;
          final effectiveSpeed = clip.speed == 1.0
              ? operation.speed
              : clip.speed;
          if (path != null && path.isNotEmpty && effectiveVolume > 0) {
            audioTracks.add(
              RenderAudioTrack(
                path: path,
                sourceStart:
                    operation.startOffset ??
                    clip.sourceStart.inMilliseconds / 1000,
                sourceEnd:
                    operation.endOffset ??
                    (clip.sourceEnd == null
                        ? null
                        : clip.sourceEnd!.inMilliseconds / 1000),
                timelineStart: clip.start.inMilliseconds / 1000,
                volume: effectiveVolume,
                speed: effectiveSpeed,
                reverse: clip.isReversed || operation.reverse,
                timelineDuration: clip.duration.inMilliseconds / 1000,
                fadeIn: operation.fadeIn,
                fadeOut: operation.fadeOut,
              ),
            );
          }
        } else if (operation is EffectOperation) {
          effects = operation.renderEffects();
        }
      }
    }
    FilterOperation? filter;
    for (final clip in visualClips) {
      if (clip.filter != null) {
        filter = clip.filter;
        break;
      }
    }
    if (filter != null) {
      effects = _effectsForFilter(
        filter.filterName,
        effects,
        intensity: filter.intensity,
      );
    }
    return VideoEnhancementService().combineSequence(
      clips: clips,
      aspectRatio: aspectRatio,
      overlays: overlays,
      transitions: transitions,
      audioTracks: audioTracks,
      effects: effects,
    );
  }

  static Future<bool> projectHasAudio(List<TimelineTrack> tracks) async {
    for (final track in tracks.where((item) => item.isVisible)) {
      for (final clip in track.clips.where((item) => !item.isHidden)) {
        final operation = clip.operation;
        if (operation is AudioClipOperation) {
          final volume = clip.volume == 1.0 ? operation.volume : clip.volume;
          final source = clip.file?.path ?? operation.sourceUrl;
          if (source != null && source.isNotEmpty && volume > 0) return true;
        }
        final visualPath = clip.file?.path.toLowerCase() ?? '';
        final isVideo = visualPath.endsWith('.mp4') ||
            visualPath.endsWith('.mov') ||
            visualPath.endsWith('.m4v') ||
            visualPath.endsWith('.mkv') ||
            visualPath.endsWith('.webm');
        if ((track.type == TrackType.video || track.type == TrackType.images) &&
            isVideo &&
            clip.file != null &&
            await _fileHasAudioStream(clip.file!)) {
          return true;
        }
      }
    }
    return false;
  }

  static Future<bool> _fileHasAudioStream(File file) async {
    final session = await FFprobeKit.getMediaInformation(file.path);
    final info = session.getMediaInformation();
    if (info == null) {
      throw StateError('Unable to inspect media streams for ${file.path}.');
    }
    return info.getStreams().any((stream) => stream.getType() == 'audio');
  }

  /// Validates the actual MP4 written to disk, not the FFmpeg return code alone.
  static Future<Map<String, bool>> inspectFinalMp4(
    File file, {
    bool requireAudio = false,
  }) async {
    if (!await file.exists() || await file.length() == 0) {
      return const {'valid': false, 'video': false, 'audio': false};
    }
    try {
      final session = await FFprobeKit.getMediaInformation(file.path);
      final info = session.getMediaInformation();
      final streams = info?.getStreams() ?? const [];
      final hasVideo = streams.any((stream) => stream.getType() == 'video');
      final hasAudio = streams.any((stream) => stream.getType() == 'audio');
      return {
        'valid': hasVideo && (!requireAudio || hasAudio),
        'video': hasVideo,
        'audio': hasAudio,
      };
    } catch (_) {
      return const {'valid': false, 'video': false, 'audio': false};
    }
  }

  static RenderEffects _effectsForFilter(
    String name,
    RenderEffects base, {
    double intensity = 1.0,
  }) {
    final t = intensity.clamp(0.0, 1.0);
    final meta = FilterCatalogueService.findByName(name);
    if (meta != null && !meta.isNone) {
      final isNoirOrGrayscale = meta.colorMatrixPreset == 'grayscale' ||
          meta.displayName.toLowerCase() == 'noir';
      return RenderEffects(
        brightness: base.brightness,
        contrast: base.contrast,
        saturation: base.saturation,
        hue: base.hue,
        vignette: (meta.displayName.toLowerCase() == 'cinema' || isNoirOrGrayscale)
            ? (0.25 * t)
            : base.vignette,
        blur: base.blur,
        grain: base.grain,
        necxaFilter: meta,
        necxaFilterIntensity: t,
      );

    }

    switch (name.toLowerCase()) {
      case 'warm':
        return RenderEffects(
          brightness: base.brightness + (0.03 * t),
          contrast: base.contrast,
          saturation: base.saturation + (0.12 * t),
          hue: base.hue + (8 * t),
          vignette: base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      case 'cool':
        return RenderEffects(
          brightness: base.brightness,
          contrast: base.contrast,
          saturation: base.saturation - (0.05 * t),
          hue: base.hue - (8 * t),
          vignette: base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      case 'vivid':
        return RenderEffects(
          contrast: base.contrast + (0.16 * t),
          saturation: base.saturation + (0.3 * t),
          brightness: base.brightness,
          hue: base.hue,
          vignette: base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      case 'blackandwhite':
      case 'noir':
        return RenderEffects(
          contrast: base.contrast + (0.15 * t),
          saturation: 0,
          brightness: base.brightness,
          hue: base.hue,
          vignette: name.toLowerCase() == 'noir' ? (0.3 * t) : base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      default:
        return base;
    }
  }
}


