import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => C.themeMode = ThemeMode.system);

  test('light mode uses the soft-white palette', () {
    C.themeMode = ThemeMode.light;
    final theme = buildLightTheme();

    expect(C.bg, C.softWhite);
    expect(C.card, C.softWhiteCard);
    expect(C.surface, C.softWhiteSurface);
    expect(C.border, C.softWhiteBorder);
    expect(theme.scaffoldBackgroundColor, C.softWhite);
    expect(theme.colorScheme.surface, C.softWhiteCard);
  });

  test('dark mode palette remains unchanged', () {
    C.themeMode = ThemeMode.dark;

    expect(C.bg, const Color(0xFF030A14));
    expect(buildDarkTheme().brightness, Brightness.dark);
  });
}
