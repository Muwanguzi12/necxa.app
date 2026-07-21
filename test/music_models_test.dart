import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/models/music_models.dart';

void main() {
  test('music duration remains in seconds for the editor timeline', () {
    final track = MusicTrack(
      id: 'track',
      title: 'Track',
      artistName: 'Artist',
      audioUrl: 'https://example.com/track.mp3',
      duration: 45,
      licenseType: 'platform_owned',
    );

    expect(track.timelineDuration, const Duration(seconds: 45));
    expect(track.formattedDuration, '0:45');
  });
}
