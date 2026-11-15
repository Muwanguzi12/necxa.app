import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/live_streaming_service.dart';

void main() {
  test('livestream actions use the primary authenticated backend', () {
    final backend = Uri.parse(LiveStreamingService.liveBackendUrl);

    expect(backend.host, 'lzdtrmjcwzalckszdzpt.supabase.co');
    expect(backend.host, isNot('ayvescksetiuekoyfqar.supabase.co'));
  });

  test('host credentials use the server-allocated session room', () {
    final credentials = LiveSessionCredentials.fromBackend(
      const {
        'token': 'host-token',
        'url': 'wss://live.example.test',
        'streamId': 'live_8f29bca7',
        'channelId': 'necxa_live_8f29bca7',
      },
      requestedChannelId: 'Sarah_Live',
      requireServerChannel: true,
    );

    expect(credentials.streamId, 'live_8f29bca7');
    expect(credentials.channelId, 'necxa_live_8f29bca7');
    expect(credentials.channelId, isNot('Sarah_Live'));
  });

  test('host startup rejects a response without a canonical session room', () {
    expect(
      () => LiveSessionCredentials.fromBackend(
        const {'token': 'host-token', 'streamId': 'live_8f29bca7'},
        requestedChannelId: 'Sarah_Live',
        requireServerChannel: true,
      ),
      throwsFormatException,
    );
  });

  test('viewer credentials preserve the selected discovery room', () {
    final credentials = LiveSessionCredentials.fromBackend(
      const {'token': 'viewer-token'},
      requestedChannelId: 'necxa_live_c417',
      requireServerChannel: false,
    );

    expect(credentials.channelId, 'necxa_live_c417');
  });
}
