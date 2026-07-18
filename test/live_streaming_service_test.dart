import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/live_streaming_service.dart';

void main() {
  test('livestream tokens are routed through Supabase project 2', () {
    final backend = Uri.parse(LiveStreamingService.liveBackendUrl);

    expect(backend.host, 'ayvescksetiuekoyfqar.supabase.co');
    expect(backend.host, isNot('lzdtrmjcwzalckszdzpt.supabase.co'));
  });
}
