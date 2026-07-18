import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/services/editor_subscription_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('pro toggle persists and reports premium features', () async {
    await EditorSubscriptionService.setProEnabled(true);
    final isPro = await EditorSubscriptionService.isProEnabled();
    final features = await EditorSubscriptionService.getPremiumFeatures();

    expect(isPro, isTrue);
    expect(features, contains('AI Editing Tools'));
    expect(features, contains('Advanced Color Grading'));
  });
}
