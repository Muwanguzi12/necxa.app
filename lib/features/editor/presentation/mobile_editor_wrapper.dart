import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:universal_io/io.dart';
import 'package:video_player/video_player.dart';
import '../../../models/edit_models.dart';
import '../state/editor_providers.dart';
import '../state/editor_state.dart';

/// Example implementation showing how to use the new Riverpod state management
/// This demonstrates the pattern for migrating from manual setState to Riverpod
class MobileEditorWrapperExample extends ConsumerStatefulWidget {
  const MobileEditorWrapperExample({super.key});

  @override
  ConsumerState<MobileEditorWrapperExample> createState() => _MobileEditorWrapperExampleState();
}

class _MobileEditorWrapperExampleState extends ConsumerState<MobileEditorWrapperExample> {
  @override
  Widget build(BuildContext context) {
    // Watch the editor state from Riverpod
    final editorState = ref.watch(editorNotifierProvider);
    final editorActions = ref.watch(editorActionsProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Media Editor (Riverpod Example)', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          // Preview canvas with state-driven transforms
          Expanded(
            child: _buildPreviewCanvas(editorState, editorActions),
          ),
          
          // Timeline with state-driven zoom
          _buildTimeline(editorState, editorActions),
          
          // Media loading status indicator
          if (editorState.mediaLoadingStates.isNotEmpty)
            _buildLoadingIndicator(editorState),
        ],
      ),
    );
  }

  Widget _buildPreviewCanvas(EditorState state, dynamic actions) {
    return Container(
      color: Colors.grey[900],
      child: Center(
        child: Transform(
          transform: Matrix4.identity()
            ..scale(state.canvasScale)
            ..rotateZ(state.canvasRotation),
          alignment: Alignment.center,
          child: Container(
            width: 200,
            height: 350,
            color: Colors.black,
            child: state.selectedClip != null
                ? _buildVideoPreview(state.selectedClip!)
                : const Center(
                    child: Text('No clip selected', style: TextStyle(color: Colors.white)),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoPreview(TimelineClip clip) {
    final loadingState = ref.read(editorNotifierProvider).mediaLoadingStates[clip.id];
    
    if (loadingState == MediaLoadingState.loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    
    if (loadingState == MediaLoadingState.error) {
      final errorMessage = ref.read(editorNotifierProvider).mediaErrorMessages[clip.id] ?? 'Unknown error';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: $errorMessage', style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
        ),
      );
    }
    
    // Get controller from state
    final controller = ref.read(editorActionsProvider).getVideoController(clip.id);
    if (controller != null && controller.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      );
    }
    
    return const Center(
      child: Text('Video not ready', style: TextStyle(color: Colors.white)),
    );
  }

  Widget _buildTimeline(EditorState state, dynamic actions) {
    return Container(
      height: 200,
      color: Colors.grey[800],
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Timeline zoom control
          Row(
            children: [
              const Text('Zoom: ', style: TextStyle(color: Colors.white)),
              Expanded(
                child: Slider(
                  value: state.timelineZoom,
                  min: 0.5,
                  max: 3.0,
                  onChanged: (value) => actions.setTimelineZoom(value),
                  activeColor: Colors.blue,
                ),
              ),
              Text('${state.timelineZoom.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white)),
            ],
          ),
          const SizedBox(height: 8),
          // Timeline tracks placeholder
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[700],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Timeline (State-driven)', style: TextStyle(color: Colors.white)),
                    const SizedBox(height: 8),
                    if (state.selectedClip != null)
                      Text('Selected: ${state.selectedClip!.id}', style: const TextStyle(color: Colors.blue)),
                    if (state.selectedTrackId != null)
                      Text('Track: ${state.selectedTrackId}', style: const TextStyle(color: Colors.green)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator(EditorState state) {
    final loadingCount = state.mediaLoadingStates.values
        .where((s) => s == MediaLoadingState.loading)
        .length;
    final errorCount = state.mediaLoadingStates.values
        .where((s) => s == MediaLoadingState.error)
        .length;
    
    if (loadingCount == 0 && errorCount == 0) return const SizedBox.shrink();
    
    return Container(
      padding: const EdgeInsets.all(8),
      color: errorCount > 0 ? Colors.red.withOpacity(0.8) : Colors.blue.withOpacity(0.8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loadingCount > 0) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            'Loading: $loadingCount | Errors: $errorCount',
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }
}
