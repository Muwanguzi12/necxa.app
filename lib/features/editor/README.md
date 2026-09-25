# Media Editor State Management

This directory contains the new Riverpod-based state management system for the media editor, designed to solve the poor state management issues in the original implementation.

## Problems Solved

### 1. Manual setState Calls
- **Before**: 60+ state variables in a single class with manual setState calls throughout
- **After**: Centralized state management with Riverpod providers and immutable state objects

### 2. Complex Synchronization Logic
- **Before**: Difficult to sync state between desktop/mobile views
- **After**: Dedicated `EditorSyncProvider` with serialization/deserialization for cross-view sync

### 3. Race Conditions in Video/Audio Loading
- **Before**: Multiple concurrent loads could cause conflicts and crashes
- **After**: Generation-based loading system that prevents race conditions

## Architecture

### State Classes

#### `EditorState`
Central immutable state class containing all editor-related state:
- Timeline tracks and clips
- Playback state
- Selection state (tracks, clips)
- UI state (zoom, canvas transforms, tool panels)
- Media loading states
- Audio state
- Effects state

#### `VideoLoadingState` / `AudioLoadingState`
Track loading state for individual media assets with controller references

### Notifiers

#### `EditorNotifier`
Main state notifier that:
- Manages all editor state changes
- Handles video/audio loading with race condition prevention
- Provides methods for track/clip selection
- Manages timeline and canvas transforms
- Properly disposes controllers on cleanup

#### `EditorSyncNotifier`
Handles synchronization between desktop and mobile views:
- Serializes/deserializes timeline data
- Syncs selected clips and transforms
- Manages active view tracking

### Providers

#### Core Providers
- `editorProjectControllerProvider`: Project controller instance
- `editorMediaServiceProvider`: Media service instance
- `editorNotifierProvider`: Main editor state
- `editorSyncProvider`: Synchronization state

#### Convenience Providers
- `tracksProvider`: Access timeline tracks
- `playbackStateProvider`: Access playback state
- `selectedClipProvider`: Access selected clip
- `mediaLoadingStatesProvider`: Access loading states
- `editorActionsProvider`: Access notifier methods

## Usage Example

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/editor/state/editor_providers.dart';

class MyEditorWidget extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch state
    final editorState = ref.watch(editorNotifierProvider);
    final editorActions = ref.watch(editorActionsProvider);

    return Column(
      children: [
        // Use state values
        Text('Zoom: ${editorState.timelineZoom}'),
        
        // Call state methods
        ElevatedButton(
          onPressed: () => editorActions.setTimelineZoom(2.0),
          child: Text('Set Zoom'),
        ),
        
        // Load video with race condition prevention
        ElevatedButton(
          onPressed: () async {
            await editorActions.loadVideoClip(myClip);
          },
          child: Text('Load Video'),
        ),
      ],
    );
  }
}
```

## Race Condition Prevention

The video loading system uses a generation-based approach:

```dart
int _videoLoadGeneration = 0;

Future<void> loadVideoClip(TimelineClip clip) async {
  final loadGeneration = ++_videoLoadGeneration;
  
  // ... load video ...
  
  // Check if this load is still valid
  if (loadGeneration != _videoLoadGeneration) {
    await controller.dispose(); // Cancel if outdated
    return;
  }
  
  // Use the loaded controller
}
```

This ensures that if a new load is initiated before the previous one completes, the old load is automatically cancelled.

## Synchronization

To sync state between desktop and mobile views:

```dart
final syncActions = ref.watch(editorSyncActionsProvider);

// Sync timeline
syncActions.syncTimeline(tracks, playbackState);

// Sync selected clip
syncActions.syncSelectedClip(clip, trackId);

// Sync canvas transforms
syncActions.syncCanvasTransform(
  scale: 1.5,
  rotation: 0.0,
  offset: Offset(10, 20),
);
```

## Migration Guide

### Step 1: Wrap App with ProviderScope

```dart
void main() {
  runApp(
    ProviderScope(
      child: MyApp(),
    ),
  );
}
```

### Step 2: Replace setState with Riverpod

**Before:**
```dart
class MyEditor extends StatefulWidget {
  @override
  _MyEditorState createState() => _MyEditorState();
}

class _MyEditorState extends State<MyEditor> {
  double _zoom = 1.0;
  
  void setZoom(double value) {
    setState(() => _zoom = value);
  }
}
```

**After:**
```dart
class MyEditor extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zoom = ref.watch(editorNotifierProvider).timelineZoom;
    final actions = ref.watch(editorActionsProvider);
    
    return Slider(
      value: zoom,
      onChanged: actions.setTimelineZoom,
    );
  }
}
```

### Step 3: Replace Video Loading

**Before:**
```dart
VideoPlayerController? _controller;

Future<void> loadVideo(File file) async {
  _controller = VideoPlayerController.file(file);
  await _controller!.initialize();
  setState(() {});
}
```

**After:**
```dart
final editorActions = ref.watch(editorActionsProvider);

Future<void> loadVideo(TimelineClip clip) async {
  await editorActions.loadVideoClip(clip);
  // Controller is managed by state, no need to store manually
}
```

## File Structure

```
lib/features/editor/
├── state/
│   ├── editor_state.dart          # State classes
│   ├── editor_notifier.dart       # State notifier
│   ├── editor_providers.dart      # Riverpod providers
│   └── editor_sync_provider.dart  # Synchronization
├── presentation/
│   └── mobile_editor_wrapper.dart # Example implementation
└── README.md                      # This file
```

## Benefits

1. **Type Safety**: All state is strongly typed
2. **Immutability**: State cannot be mutated accidentally
3. **Testability**: Easy to test state logic in isolation
4. **Performance**: Only rebuilds widgets that depend on changed state
5. **Race Condition Prevention**: Generation-based loading system
6. **Cross-View Sync**: Built-in synchronization support
7. **Scalability**: Easy to add new state fields and providers

## Next Steps

1. Gradually migrate `mobile_media_editor.dart` to use the new state management
2. Migrate `pro_media_editor_screen.dart` to use the new state management
3. Add comprehensive tests for state management logic
4. Consider adding persistence layer for state
