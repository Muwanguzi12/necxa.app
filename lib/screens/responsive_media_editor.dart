import 'dart:io';
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../models/music_models.dart';
import 'pro_media_editor_screen.dart';
import 'mobile_media_editor.dart';

// ══════════════════════════════════════════════════════════════
// RESPONSIVE MEDIA EDITOR ROUTER
// ══════════════════════════════════════════════════════════════
// This widget automatically routes to the appropriate editor
// based on device orientation and screen size.
// 
// Desktop/Landscape → ProMediaEditorScreen (full desktop UI)
// Mobile/Portrait → MobileMediaEditor (touch-optimized mobile UI)

class ResponsiveMediaEditor extends StatelessWidget {
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
            state: state,
            initialImage: initialImage,
            initialVideo: initialVideo,
            initialTrack: initialTrack,
            multiFiles: multiFiles,
            isFastSync: isFastSync,
          );
        }
        
        // Mobile portrait: use mobile editor
        return MobileMediaEditor(
          state: state,
          initialMedia: initialVideo ?? initialImage,
        );
      },
    );
  }
}
