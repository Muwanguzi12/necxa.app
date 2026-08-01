import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:necxa_flutter/theme.dart';

void main() {
  tearDown(() => C.themeMode = ThemeMode.system);

  test('light mode uses the soft-white palette', () {
    C.themeMode = ThemeMode.light;
    expect(C.bg, C.softWhite);
    expect(C.card, C.softWhiteCard);
    expect(C.surface, C.softWhiteSurface);
    expect(C.border, C.softWhiteBorder);
  });

  test('dark mode palette remains unchanged', () {
    C.themeMode = ThemeMode.dark;

    expect(C.bg, const Color(0xFF030A14));
    expect(C.card, const Color(0xFF0A1324));
  });
}
