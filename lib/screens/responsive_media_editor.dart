import 'package:universal_io/io.dart';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models/music_models.dart';
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

import '../services/filter_catalogue_service.dart';

class ResponsiveMediaEditor extends StatefulWidget {
  final AppState state;
  final File? initialImage;
  final File? initialVideo;
  final MusicTrack? initialTrack;
  final List<File>? multiFiles;
  final bool isFastSync;
  final NecxaFilterMeta? initialFilter;
  final double initialFilterIntensity;

  const ResponsiveMediaEditor({
    super.key,
    required this.state,
    this.initialImage,
    this.initialVideo,
    this.initialTrack,
    this.multiFiles,
    this.isFastSync = false,
    this.initialFilter,
    this.initialFilterIntensity = 1.0,
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
      final clip = TimelineClip(
        id: 'initial-$index-${file.path.hashCode}',
        start: start,
        duration: duration,
        file: file,
        operation: TrimOperation(
          start: Duration.zero,
          end: duration,
          maxDuration: duration,
        ),
      );
      if (widget.initialFilter != null && !widget.initialFilter!.isNone) {
        clip.filter = FilterOperation(
          filterName: widget.initialFilter!.displayName,
          intensity: widget.initialFilterIntensity,
        );
      }
      TimelineModelUtils.insertClip(
        _project.tracks,
        clip,
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
    // Unified mobile-first media editor across all device sizes and orientations
    return MobileMediaEditor(
      state: widget.state,
      initialMedia: widget.initialVideo ?? widget.initialImage,
      initialTrack: widget.initialTrack,
      multiFiles: widget.multiFiles,
      isFastSync: widget.isFastSync,
      projectController: _project,
    );
  }
}
