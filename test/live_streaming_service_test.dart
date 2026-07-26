import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/live_streaming_service.dart';

void main() {
  test('livestream actions use the primary authenticated backend', () {
    final backend = Uri.parse(LiveStreamingService.liveBackendUrl);

    expect(backend.host, 'lzdtrmjcwzalckszdzpt.supabase.co');
    expect(backend.host, isNot('ayvescksetiuekoyfqar.supabase.co'));
  });
}
