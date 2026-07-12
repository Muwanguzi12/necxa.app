import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/editor_subscription_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pro toggle persists and reports premium features', () async {
    await EditorSubscriptionService.setProEnabled(true);
    final isPro = await EditorSubscriptionService.isProEnabled();
    final features = await EditorSubscriptionService.getPremiumFeatures();

    expect(isPro, isTrue);
    expect(features, contains('AI Editing Tools'));
    expect(features, contains('Advanced Color Grading'));
  });
}
