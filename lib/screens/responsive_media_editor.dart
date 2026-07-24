import 'dart:io';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models/music_models.dart';
import 'pro_media_editor_screen.dart';
import 'mobile_media_editor.dart';
import '../models/edit_models.dart';
import '../services/timeline_playback_controller.dart';

// ══════════════════════════════════════════════════════════════
// RESPONSIVE MEDIA EDITOR ROUTER
// ══════════════════════════════════════════════════════════════
// This widget automatically routes to the appropriate editor
// based on device orientation and screen size.
//
// Desktop/Landscape → ProMediaEditorScreen (full desktop UI)
// Mobile/Portrait → MobileMediaEditor (touch-optimized mobile UI)

class ResponsiveMediaEditor extends StatefulWidget {
  final AppState state;
  final File? initialImage;
  final File? initialVideo;
  final MusicTrack? initialTrack;
  final List<File>? multiFiles;
  final bool isFastSync;

  const ResponsiveMediaEditor({
    super.key,
    required this.state,
    this.initialImage,
    this.initialVideo,
    this.initialTrack,
    this.multiFiles,
    this.isFastSync = false,
  });

  @override
  State<ResponsiveMediaEditor> createState() => _ResponsiveMediaEditorState();
}

class _ResponsiveMediaEditorState extends State<ResponsiveMediaEditor> {
  late final EditorProjectController _project;

  @override
  void initState() {
    super.initState();
    _project = EditorProjectController();
    final files =
        widget.multiFiles ??
        [
          if (widget.initialVideo != null) widget.initialVideo!,
          if (widget.initialImage != null) widget.initialImage!,
        ];
    var start = Duration.zero;
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final isVideo =
          file.path.toLowerCase().endsWith('.mp4') ||
          file.path.toLowerCase().endsWith('.mov');
      final duration = isVideo
          ? const Duration(seconds: 12)
          : const Duration(seconds: 4);
      TimelineModelUtils.insertClip(
        _project.tracks,
        TimelineClip(
          id: 'initial-${index}-${file.path.hashCode}',
          start: start,
          duration: duration,
          file: file,
          operation: TrimOperation(
            start: Duration.zero,
            end: duration,
            maxDuration: duration,
          ),
        ),
        isVideo ? TrackType.video : TrackType.images,
      );
      start += duration;
    }
    if (widget.initialTrack != null) {
      TimelineModelUtils.insertClip(
        _project.tracks,
        TimelineClip(
          id: 'initial-music-${widget.initialTrack!.id}',
          start: Duration.zero,
          duration: start > Duration.zero ? start : const Duration(seconds: 30),
          operation: AudioClipOperation(
            sourceType: 'music',
            sourceUrl: widget.initialTrack!.audioUrl,
            label: widget.initialTrack!.title,
          ),
        ),
        TrackType.music,
      );
    }
    _project.playback.updateProject(_project.tracks);
  }

  @override
  void dispose() {
    _project.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;
        final isLandscape = screenWidth > screenHeight;
        final isTablet = screenWidth > 600;

        // Desktop or landscape tablet: use full editor
        if (isLandscape || isTablet) {
          return ProMediaEditorScreen(
            state: widget.state,
            initialImage: widget.initialImage,
            initialVideo: widget.initialVideo,
            initialTrack: widget.initialTrack,
            multiFiles: widget.multiFiles,
            isFastSync: widget.isFastSync,
            projectController: _project,
          );
        }

        // Mobile portrait: use mobile editor
        return MobileMediaEditor(
          state: widget.state,
          initialMedia: widget.initialVideo ?? widget.initialImage,
          initialTrack: widget.initialTrack,
          multiFiles: widget.multiFiles,
          isFastSync: widget.isFastSync,
          projectController: _project,
        );
      },
    );
  }
}
