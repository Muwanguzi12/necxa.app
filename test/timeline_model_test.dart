import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/models/edit_models.dart';
import 'package:necxa_flutter/services/timeline_playback_controller.dart';

void main() {
  group('Timeline model helpers', () {
    test('creates a track when a clip of that type is added', () {
      final tracks = <TimelineTrack>[
        TimelineTrack(
          id: 'video-1',
          type: TrackType.video,
          label: 'Video',
          icon: Icons.videocam,
          clips: [
            TimelineClip(
              id: 'clip-1',
              start: Duration.zero,
              duration: const Duration(seconds: 3),
              operation: TrimOperation(
                start: Duration.zero,
                end: const Duration(seconds: 3),
                maxDuration: const Duration(seconds: 3),
              ),
            ),
          ],
        ),
      ];

      TimelineModelUtils.ensureTrackForType(
        tracks,
        TrackType.text,
        label: 'Text',
      );

      expect(tracks.any((track) => track.type == TrackType.text), isTrue);
    });

    test('removes empty non-video tracks', () {
      final tracks = <TimelineTrack>[
        TimelineTrack(
          id: 'video-1',
          type: TrackType.video,
          label: 'Video',
          icon: Icons.videocam,
          clips: [
            TimelineClip(
              id: 'clip-1',
              start: Duration.zero,
              duration: const Duration(seconds: 1),
              operation: TrimOperation(
                start: Duration.zero,
                end: const Duration(seconds: 1),
                maxDuration: const Duration(seconds: 1),
              ),
            ),
          ],
        ),
        TimelineTrack(
          id: 'text-1',
          type: TrackType.text,
          label: 'Text',
          icon: Icons.text_fields,
          clips: const [],
        ),
      ];

      TimelineModelUtils.pruneEmptyTracks(tracks);

      expect(tracks.where((track) => track.type == TrackType.text), isEmpty);
    });

    test('inserts a clip into a newly created track when needed', () {
      final tracks = <TimelineTrack>[
        TimelineTrack(
          id: 'video-1',
          type: TrackType.video,
          label: 'Video',
          icon: Icons.videocam,
          clips: [],
        ),
      ];

      final inserted = TimelineModelUtils.insertClip(
        tracks,
        TimelineClip(
          id: 'image-1',
          start: Duration.zero,
          duration: const Duration(seconds: 3),
          operation: TrimOperation(
            start: Duration.zero,
            end: const Duration(seconds: 3),
            maxDuration: const Duration(seconds: 3),
          ),
        ),
        TrackType.images,
      );

      expect(
        tracks.where((track) => track.type == TrackType.images),
        hasLength(1),
      );
      expect(
        tracks
            .firstWhere((track) => track.type == TrackType.images)
            .clips
            .single
            .id,
        'image-1',
      );
      expect(inserted.id, 'image-1');
    });

    test('serializes shared audio clip metadata', () {
      final operation = AudioClipOperation(
        sourceType: 'music',
        sourceUrl: 'https://cdn.example.com/track.mp3',
        label: 'Intro Beat',
        volume: 0.75,
        speed: 1.5,
        reverse: true,
      );

      final json = operation.toJson();

      expect(json['sourceType'], 'music');
      expect(json['label'], 'Intro Beat');
      expect(json['volume'], 0.75);
      expect(json['speed'], 1.5);
      expect(json['reverse'], isTrue);
    });

    test('copies non-destructive clip playback properties', () {
      final clip = TimelineClip(
        id: 'source',
        start: Duration.zero,
        duration: const Duration(seconds: 4),
        sourceStart: const Duration(seconds: 2),
        sourceEnd: const Duration(seconds: 6),
        speed: 2,
        volume: 0.4,
        cropAspectRatio: '1:1',
        isReversed: true,
        operation: TrimOperation(
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 6),
          maxDuration: const Duration(seconds: 10),
        ),
      );

      final copy = clip.copyWith(id: 'copy');

      expect(copy.sourceStart, const Duration(seconds: 2));
      expect(copy.sourceEnd, const Duration(seconds: 6));
      expect(copy.speed, 2);
      expect(copy.volume, 0.4);
      expect(copy.cropAspectRatio, '1:1');
      expect(copy.isReversed, isTrue);
    });

    test('inserts a shared text overlay clip into the text track', () {
      final tracks = <TimelineTrack>[];
      final clip = TimelineModelUtils.insertTextClip(
        tracks,
        text: 'Hello',
        start: Duration.zero,
      );

      expect(clip.operation is TextOverlay, isTrue);
      expect(tracks.single.type, TrackType.text);
      expect(tracks.single.clips.single.id, clip.id);
    });
  });

  group('Shared timeline playback', () {
    final tracks = <TimelineTrack>[
      TimelineTrack(
        id: 'video',
        type: TrackType.video,
        label: 'Video',
        icon: Icons.videocam,
        clips: [
          TimelineClip(
            id: 'intro',
            start: Duration.zero,
            duration: const Duration(seconds: 5),
            operation: TrimOperation(
              start: Duration.zero,
              end: const Duration(seconds: 5),
              maxDuration: const Duration(seconds: 5),
            ),
          ),
        ],
      ),
      TimelineTrack(
        id: 'music',
        type: TrackType.music,
        label: 'Music',
        icon: Icons.music_note,
        clips: [
          TimelineClip(
            id: 'bed',
            start: const Duration(seconds: 2),
            duration: const Duration(seconds: 8),
            operation: AudioClipOperation(sourceType: 'music'),
          ),
        ],
      ),
    ];

    test('resolves every active track against the same time', () {
      final active = TimelinePlaybackController.resolve(
        tracks,
        const Duration(seconds: 3),
      );

      expect(active.ofType(TrackType.video).single.id, 'intro');
      expect(active.ofType(TrackType.music).single.id, 'bed');
    });

    test('uses the latest item end as composition duration', () {
      expect(
        TimelinePlaybackController.projectDuration(tracks),
        const Duration(seconds: 10),
      );
    });

    test('seek updates time and active clip ids together', () {
      final controller = TimelinePlaybackController();
      controller.seek(const Duration(seconds: 7), tracks);

      expect(controller.state.currentTime, const Duration(seconds: 7));
      expect(controller.state.activeClipIds, {'bed'});
      controller.dispose();
    });
  });

  group('Timeline undo and redo', () {
    test('restores deep clip and operation state', () {
      final trim = TrimOperation(
        start: Duration.zero,
        end: const Duration(seconds: 5),
        maxDuration: const Duration(seconds: 10),
      );
      final clip = TimelineClip(
        id: 'clip',
        start: Duration.zero,
        duration: const Duration(seconds: 5),
        speed: 1,
        operation: trim,
      );
      final tracks = <TimelineTrack>[
        TimelineTrack(
          id: 'video',
          type: TrackType.video,
          clips: [clip],
          label: 'Video',
          icon: Icons.videocam,
        ),
      ];
      final history = TimelineHistoryController();

      history.capture(tracks);
      clip.speed = 2;
      clip.duration = const Duration(milliseconds: 2500);
      trim.end = const Duration(seconds: 4);

      final undone = history.undo(tracks)!;
      final restored = undone.single.clips.single;
      expect(restored.speed, 1);
      expect(restored.duration, const Duration(seconds: 5));
      expect(
        (restored.operation as TrimOperation).end,
        const Duration(seconds: 5),
      );

      final redone = history.redo(undone)!;
      expect(redone.single.clips.single.speed, 2);
      expect(
        (redone.single.clips.single.operation as TrimOperation).end,
        const Duration(seconds: 4),
      );
    });

    test('new capture clears redo history', () {
      final tracks = <TimelineTrack>[];
      final history = TimelineHistoryController();
      history.capture(tracks);
      tracks.add(
        TimelineTrack(
          id: 'text',
          type: TrackType.text,
          clips: const [],
          label: 'Text',
          icon: Icons.text_fields,
        ),
      );
      final undone = history.undo(tracks)!;
      expect(history.canRedo, isTrue);

      history.capture(undone);
      expect(history.canRedo, isFalse);
    });
  });
}
