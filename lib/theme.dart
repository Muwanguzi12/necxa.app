import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── Colors ────────────────────────────────────────────────────
class C {
  static ThemeMode themeMode = ThemeMode.system;

  static const Color softWhite = Color(0xFFF7F8FA);
  static const Color softWhiteCard = Color(0xFFFFFFFF);
  static const Color softWhiteSurface = Color(0xFFF0F3F6);
  static const Color softWhiteBorder = Color(0xFFD7DEE8);

  static bool get isDark {
    if (themeMode == ThemeMode.dark) return true;
    if (themeMode == ThemeMode.light) return false;
    try {
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      return dispatcher.platformBrightness == Brightness.dark;
    } catch (_) {
      return true;
    }
  }

  static Color get bg => isDark ? const Color(0xFF030A14) : softWhite;
  static Color get card => isDark ? const Color(0xFF0A1324) : softWhiteCard;
  static Color get surface =>
      isDark ? const Color(0xFF101B2E) : softWhiteSurface;
  static Color get card2 => isDark ? const Color(0xFF101B2E) : softWhiteSurface;
  static Color get border => isDark ? const Color(0xFF1A263D) : softWhiteBorder;
  static Color get dark =>
      isDark ? const Color(0xFF1A263D) : const Color(0xFFE4E9EF);
  static Color get cardDk =>
      isDark ? const Color(0xFF060F1E) : const Color(0xFFF2F4F7);

  static const Color brand = Color(0xFF00E5FF); // Cyan
  static const Color brandDk = Color(0xFF00B2CC); // Darker Cyan
  static const Color gold = Color(0xFFF4A228);
  static const Color gold2 = Color(0xFFE08010);
  static const Color green = Color(0xFF22C55E);
  static const Color blue = Color(0xFF3B82F6);
  static const Color red = Color(0xFFEF4444);
  static const Color purple = Color(0xFFA855F7);
  static const Color orange = Color(0xFFF97316);

  // Dynamic Text Colors for Light/Dark Mode compatibility
  static Color get text => isDark ? const Color(0xFFF0F4FF) : const Color(0xFF172033);
  static Color get sub => isDark ? const Color(0xFF8A9AB2) : const Color(0xFF5A6A82);
  static Color get dim => isDark ? const Color(0xFF5A6A82) : const Color(0xFF8A9AB2);
  static Color get icon => isDark ? Colors.white : Colors.black;
}

// ── Text helpers ──────────────────────────────────────────────
TextStyle syne({
  double sz = 14,
  FontWeight w = FontWeight.w700,
  Color? c,
  FontStyle fs = FontStyle.normal,
  double? ls,
  double? h,
}) => GoogleFonts.inter(
  fontSize: sz,
  fontWeight: w,
  color: c ?? C.text,
  fontStyle: fs,
  letterSpacing: ls,
  height: h,
).copyWith(
  fontFamilyFallback: const ['NotoColorEmoji', 'Apple Color Emoji', 'Segoe UI Emoji'],
);

TextStyle dm({
  double sz = 14,
  FontWeight w = FontWeight.w400,
  Color? c,
  FontStyle fs = FontStyle.normal,
  double? ls,
  double? h,
}) => GoogleFonts.roboto(
  fontSize: sz,
  fontWeight: w,
  color: c ?? C.text,
  fontStyle: fs,
  letterSpacing: ls,
  height: h,
).copyWith(
  fontFamilyFallback: const ['NotoColorEmoji', 'Apple Color Emoji', 'Segoe UI Emoji'],
);

// ── Gradient helpers ──────────────────────────────────────────
const brandGrad = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF00E5FF), Color(0xFF00B2CC)],
);

const goldGrad = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFF4A228), Color(0xFFE08010)],
);

const greenGrad = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF22C55E), Color(0xFF16A34A)],
);

const neonCyanGreen = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF00FFFF), Color(0xFF39FF14)],
);

const neonOrangePurple = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFFF5F1F), Color(0xFFBF00FF)],
);

const neonYellowPink = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFFFFF00), Color(0xFFFF10F0)],
);

List<Color> listingGrad(String type) {
  switch (type) {
    case 'villa':
      return [const Color(0xFF0d2a1a), const Color(0xFF1a5034)];
    case 'studio':
      return [const Color(0xFF2a0d1a), const Color(0xFF5a1a3a)];
    case 'commercial':
      return [const Color(0xFF2a1a0d), const Color(0xFF5a3a1a)];
    default:
      return [const Color(0xFF0d1f3c), const Color(0xFF1a3a6e)];
  }
}

List<Color> postGrad(String grad) {
  switch (grad) {
    case 'music':
      return [const Color(0xFF1a0d2a), const Color(0xFF3a1a6e)];
    case 'art':
      return [const Color(0xFF2a1a0a), const Color(0xFF6e3a1a)];
    case 'live':
      return [const Color(0xFF2a0a0a), const Color(0xFF6e1a1a)];
    default:
      return [const Color(0xFF0d1f3c), const Color(0xFF1a3a6e)];
  }
}

// ── MaterialApp ThemeData ─────────────────────────────────────
ThemeData buildLightTheme() => ThemeData(
  brightness: Brightness.light,
  scaffoldBackgroundColor: C.softWhite,
  colorScheme: const ColorScheme.light(
    surface: C.softWhiteCard,
    primary: C.brand,
    secondary: C.brandDk,
    onPrimary: Color(0xFF001F24),
    onSurface: Color(0xFF172033),
    outline: C.softWhiteBorder,
    surfaceContainerLowest: C.softWhiteCard,
    surfaceContainerLow: C.softWhite,
    surfaceContainer: C.softWhiteSurface,
    surfaceContainerHigh: Color(0xFFE9EDF2),
    surfaceContainerHighest: Color(0xFFE2E8EF),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: C.softWhite,
    foregroundColor: Color(0xFF172033),
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    iconTheme: IconThemeData(color: Color(0xFF172033)),
  ),
  dividerColor: C.softWhiteBorder,
  textTheme: GoogleFonts.robotoTextTheme(ThemeData.light().textTheme).apply(
    fontFamilyFallback: const ['NotoColorEmoji', 'Apple Color Emoji', 'Segoe UI Emoji'],
  ),
);

ThemeData buildDarkTheme() => ThemeData(
  brightness: Brightness.dark,
  scaffoldBackgroundColor: const Color(0xFF030A14), // Night Blue
  colorScheme: const ColorScheme.dark(
    surface: Color(0xFF030A14),
    primary: C.brand,
    secondary: C.brandDk,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF0A1324),
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    iconTheme: IconThemeData(color: Color(0xFFF0F4FF)),
  ),
  dividerColor: const Color(0xFF1C2535),
  textTheme: GoogleFonts.robotoTextTheme(ThemeData.dark().textTheme).apply(
    fontFamilyFallback: const ['NotoColorEmoji', 'Apple Color Emoji', 'Segoe UI Emoji'],
  ),
);

class NecxaLogo extends StatelessWidget {
  final double size;
  final bool shadow;
  const NecxaLogo({super.key, this.size = 68, this.shadow = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: C.brand.withOpacity(0.25),
                  blurRadius: size * 0.4,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
      ),
    );
  }
}
