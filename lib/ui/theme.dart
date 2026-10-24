import 'package:flutter/material.dart';

/// True black for OLED (black pixels are off), high-contrast accents readable in sunlight.
const kBlack = Color(0xFF000000);
const kSurface = Color(0xFF111111);
const kSurfaceHigh = Color(0xFF1C1C1C);
const kAccent = Color(0xFFFFB300); // amber
const kDanger = Color(0xFFFF5252);
const kWater = Color(0xFF4FC3F7);
const kTrail = Color(0xFFFFCC80);
const kGood = Color(0xFF81C784);
const kMuted = Color(0xFF9E9E9E);

ThemeData survivalTheme() {
  final scheme = const ColorScheme.dark(
    primary: kAccent,
    secondary: kWater,
    surface: kBlack,
    error: kDanger,
    onPrimary: Colors.black,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: kBlack,
    useMaterial3: true,
    cardTheme: const CardThemeData(color: kSurface, margin: EdgeInsets.zero),
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: kBlack, indicatorColor: kSurfaceHigh, height: 64),
    // no page transition animations: less GPU work
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
    }),
  );
}
