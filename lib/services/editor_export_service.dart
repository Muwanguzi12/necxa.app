import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'media_compression_service.dart';
import '../models/edit_models.dart';
import 'video_enhancement_service.dart';

class EditorExportResult {
  final bool success;
  final String? outputPath;
  final String? thumbnailPath;
  final String? verificationSummary;
  final List<String> issues;
  final Map<String, dynamic> verificationPayload;

  const EditorExportResult({
    required this.success,
    this.outputPath,
    this.thumbnailPath,
    this.verificationSummary,
    this.issues = const [],
    this.verificationPayload = const {},
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
      final outputFile = File(
        '${tempDir.path}/$projectName-${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      final rendered = tracks == null
          ? null
          : await renderTimeline(tracks: tracks, aspectRatio: aspectRatio);
      await (rendered ?? sourceVideo).copy(outputFile.path);

      onStage?.call('Compressing video');
      final compressedFile = await MediaCompressionService.compressVideo(
        outputFile,
      );

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
            .where((clip) => clip.file != null && clip.file!.existsSync())
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    if (visualClips.isEmpty) return null;

    final clips = visualClips.map((clip) {
      final path = clip.file!.path.toLowerCase();
      final isVideo = path.endsWith('.mp4') || path.endsWith('.mov');
      return ClipData(
        path: clip.file!.path,
        start: clip.sourceStart.inMilliseconds / 1000,
        end:
            (clip.sourceEnd ?? clip.sourceStart + clip.sourceDuration)
                .inMilliseconds /
            1000,
        speed: clip.speed,
        volume: clip.volume,
        isVideo: isVideo,
        hasAudio: isVideo,
        scale: clip.transform.scale,
        rotation: clip.transform.rotation,
        offsetX: clip.transform.position.dx,
        offsetY: clip.transform.position.dy,
        opacity: clip.transform.opacity,
      );
    }).toList();

    final overlays = <RenderOverlay>[];
    final transitions = <RenderTransition>[];
    final audioTracks = <RenderAudioTrack>[];
    var effects = const RenderEffects();
    for (final clip in tracks.expand((track) => track.clips)) {
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
            color: operation.style.color ?? Colors.white,
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
        if (path != null && path.isNotEmpty) {
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
              volume: clip.volume,
              speed: clip.speed,
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
    FilterOperation? filter;
    for (final clip in visualClips) {
      if (clip.filter != null) {
        filter = clip.filter;
        break;
      }
    }
    if (filter != null) effects = _effectsForFilter(filter.filterName, effects);
    return VideoEnhancementService().combineSequence(
      clips: clips,
      aspectRatio: aspectRatio,
      overlays: overlays,
      transitions: transitions,
      audioTracks: audioTracks,
      effects: effects,
    );
  }

  static RenderEffects _effectsForFilter(String name, RenderEffects base) {
    switch (name.toLowerCase()) {
      case 'warm':
        return RenderEffects(
          brightness: base.brightness + 0.03,
          contrast: base.contrast,
          saturation: base.saturation + 0.12,
          hue: base.hue + 8,
          vignette: base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      case 'cool':
        return RenderEffects(
          brightness: base.brightness,
          contrast: base.contrast,
          saturation: base.saturation - 0.05,
          hue: base.hue - 8,
          vignette: base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      case 'vivid':
        return RenderEffects(
          contrast: base.contrast + 0.16,
          saturation: base.saturation + 0.3,
          brightness: base.brightness,
          hue: base.hue,
          vignette: base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      case 'blackandwhite':
      case 'noir':
        return RenderEffects(
          contrast: base.contrast + 0.15,
          saturation: 0,
          brightness: base.brightness,
          hue: base.hue,
          vignette: name.toLowerCase() == 'noir' ? 0.3 : base.vignette,
          blur: base.blur,
          grain: base.grain,
        );
      default:
        return base;
    }
  }
}
