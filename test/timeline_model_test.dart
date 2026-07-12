import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/models/edit_models.dart';

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

      TimelineModelUtils.ensureTrackForType(tracks, TrackType.text, label: 'Text');

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

      expect(tracks.where((track) => track.type == TrackType.images), hasLength(1));
      expect(tracks.firstWhere((track) => track.type == TrackType.images).clips.single.id, 'image-1');
      expect(inserted.id, 'image-1');
    });

    test('serializes shared audio clip metadata', () {
      final operation = AudioClipOperation(
        sourceType: 'music',
        sourceUrl: 'https://cdn.example.com/track.mp3',
        label: 'Intro Beat',
        volume: 0.75,
      );

      final json = operation.toJson();

      expect(json['sourceType'], 'music');
      expect(json['label'], 'Intro Beat');
      expect(json['volume'], 0.75);
    });

    test('inserts a shared text overlay clip into the text track', () {
      final tracks = <TimelineTrack>[];
      final clip = TimelineModelUtils.insertTextClip(tracks, text: 'Hello', start: Duration.zero);

      expect(clip.operation is TextOverlay, isTrue);
      expect(tracks.single.type, TrackType.text);
      expect(tracks.single.clips.single.id, clip.id);
    });
  });
}
