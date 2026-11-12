import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/models/edit_models.dart';

void main() {
  test('Text Studio timer layers persist their render settings', () {
    final timer = TextOverlay(
      text: '',
      timerMode: 'countdown',
      timerDuration: 90,
    );

    expect(timer.toJson()['timerMode'], 'countdown');
    expect(timer.toJson()['timerDuration'], 90);
  });

  test('legacy text overlays default to static text without a timer', () {
    final restored = OverlayOperation.fromLegacy({
      'type': 'text',
      'text': 'Legacy caption',
    });

    expect(restored.timerMode, 'none');
    expect(restored.timerDuration, 0);
  });

  test('overlay preserves karaoke word timing and imported font metadata', () {
    final overlay = OverlayOperation(
      kind: 'text',
      text: 'Necxa makes editing easier',
      fontFamily: 'NecxaFont_12345',
      fontFilePath: '/app/support/necxa_fonts/sample.ttf',
      timerMode: 'countdown',
      timerDuration: 42,
      wordTimings: const [
        {'text': 'Necxa', 'start': 0.0, 'end': 0.4},
        {'text': 'makes', 'start': 0.4, 'end': 0.7},
        {'text': 'editing', 'start': 0.7, 'end': 1.1},
        {'text': 'easier', 'start': 1.1, 'end': 1.5},
      ],
    );

    final restored = OverlayOperation.fromLegacy(overlay.toJson());
    expect(restored.fontFamily, overlay.fontFamily);
    expect(restored.fontFilePath, overlay.fontFilePath);
    expect(restored.wordTimings, hasLength(4));
    expect(restored.wordTimings[2]['text'], 'editing');
    expect(restored.wordTimings[2]['start'], 0.7);
    expect(restored.timerMode, 'countdown');
    expect(restored.timerDuration, 42);

    final copied = overlay.copy();
    expect(copied.fontFilePath, overlay.fontFilePath);
    expect(copied.wordTimings, overlay.wordTimings);
    expect(copied.timerMode, 'countdown');
    expect(copied.timerDuration, 42);
  });
}
