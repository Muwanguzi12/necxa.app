import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../services/timeline_playback_controller.dart';
import '../../../services/editor_media_service.dart';
import '../../../models/edit_models.dart';
import 'editor_notifier.dart';
import 'editor_state.dart';

/// Provider for EditorProjectController
final editorProjectControllerProvider = Provider<EditorProjectController>((ref) {
  final controller = EditorProjectController();
  ref.onDispose(() => controller.dispose());
  return controller;
});

/// Provider for EditorMediaService
final editorMediaServiceProvider = Provider<EditorMediaService>((ref) {
  return EditorMediaService();
});

/// Provider for EditorNotifier
final editorNotifierProvider = StateNotifierProvider<EditorNotifier, EditorState>((ref) {
  final projectController = ref.watch(editorProjectControllerProvider);
  final mediaService = ref.watch(editorMediaServiceProvider);
  
  final notifier = EditorNotifier(
    projectController: projectController,
    mediaService: mediaService,
  );
  
  ref.onDispose(() => notifier.dispose());
  return notifier;
});

/// Convenience providers for accessing specific state values
final tracksProvider = Provider<List<TimelineTrack>>((ref) {
  return ref.watch(editorNotifierProvider).tracks;
});

final playbackStateProvider = Provider<TimelinePlaybackState>((ref) {
  return ref.watch(editorNotifierProvider).playbackState;
});

final selectedClipProvider = Provider<TimelineClip?>((ref) {
  return ref.watch(editorNotifierProvider).selectedClip;
});

final selectedTrackIdProvider = Provider<String?>((ref) {
  return ref.watch(editorNotifierProvider).selectedTrackId;
});

final timelineZoomProvider = Provider<double>((ref) {
  return ref.watch(editorNotifierProvider).timelineZoom;
});

final mediaLoadingStatesProvider = Provider<Map<String, MediaLoadingState>>((ref) {
  return ref.watch(editorNotifierProvider).mediaLoadingStates;
});

final mediaErrorMessagesProvider = Provider<Map<String, String>>((ref) {
  return ref.watch(editorNotifierProvider).mediaErrorMessages;
});

/// Provider for accessing the editor notifier methods
final editorActionsProvider = Provider<EditorNotifier>((ref) {
  return ref.watch(editorNotifierProvider.notifier);
});
