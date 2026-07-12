import 'package:shared_preferences/shared_preferences.dart';

class EditorSubscriptionService {
  static const _storageKey = 'necxa_editor_pro_enabled_v1';

  static Future<bool> isProEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_storageKey) ?? false;
  }

  static Future<void> setProEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, enabled);
  }

  static Future<List<String>> getPremiumFeatures() async {
    return const [
      'AI Editing Tools',
      'Premium Effects',
      'Premium Transitions',
      'Premium Fonts',
      'AI Background Removal',
      'AI Auto Captions',
      'AI Voice Enhancement',
      'Motion Tracking',
      'Advanced Color Grading',
      'Higher export quality',
      'Increased cloud storage',
      'Team collaboration',
      'Future premium editor features',
    ];
  }
}
