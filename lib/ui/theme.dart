import 'package:flutter/material.dart';

/// "Backcountry Sunlight Utility": dark ink on bone/parchment, readable in direct sun.
/// Light only (no dark mode). Depth comes from tonal surfaces and hairline borders, not shadows.
const kInk = Color(0xFF142019); // forest pine: text, primary buttons
const kInkMuted = Color(0xFF485B4F);
const kGround = Color(0xFFF4F7F4); // layer 0: page and map canvas
const kCard = Color(0xFFFFFFFF); // layer 1: cards, sheets, composer
const kWell = Color(0xFFF8FAF8); // inset wells inside cards
const kInset = Color(0xFFE8EDE8); // chips, icon buttons
const kLine = Color(0xFFD9E0D9); // card hairlines
const kOutline = Color(0xFFBDC9BD);
const kUserBubble = Color(0xFFE3EBE4);
const kUserBorder = Color(0xFFCFDAC0);
const kMoss = Color(0xFF1D5C2F); // nominal: GPS fixed, AI label, routes
const kClay = Color(0xFFD94819); // hazard: SOS, sunset warnings, off route
const kWater = Color(0xFF1F6FA8);
const kTrail = Color(0xFF8A5A2B);

const kFont = 'SpaceGrotesk';

/// Uppercase tracked label (label-sm / label-md in the design).
TextStyle label(Color color, {double size = 11}) =>
    TextStyle(fontFamily: kFont, fontSize: size, fontWeight: FontWeight.w700, letterSpacing: size * 0.08, color: color);

ThemeData survivalTheme() {
  final scheme = ColorScheme.light(
    primary: kInk,
    onPrimary: kCard,
    secondary: kMoss,
    onSecondary: kCard,
    tertiary: kClay,
    surface: kGround,
    onSurface: kInk,
    onSurfaceVariant: kInkMuted,
    surfaceContainerLowest: kCard,
    surfaceContainerLow: kCard,
    surfaceContainer: kCard,
    surfaceContainerHigh: kCard,
    surfaceContainerHighest: kInset,
    outline: kOutline,
    outlineVariant: kLine,
    error: const Color(0xFFBA1A1A),
  );
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
    side: BorderSide(color: kLine),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true, fontFamily: kFont);
  return base.copyWith(
    scaffoldBackgroundColor: kGround,
    textTheme: base.textTheme.apply(bodyColor: kInk, displayColor: kInk, fontFamily: kFont),
    cardTheme: const CardThemeData(color: kCard, margin: EdgeInsets.zero, elevation: 0, shape: shape),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: kCard, surfaceTintColor: Colors.transparent),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kInk,
      contentTextStyle: TextStyle(fontFamily: kFont, color: kCard),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kGround,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => label(s.contains(WidgetState.selected) ? kInk : kInkMuted, size: 10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kInk,
        foregroundColor: kCard,
        minimumSize: const Size(48, 48),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        textStyle: label(kCard, size: 13),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kInk,
        backgroundColor: kCard,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: kInk, width: 1.5),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        textStyle: label(kInk, size: 13),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: kCard,
      foregroundColor: kInk,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: kInk, width: 2),
      ),
    ),
    dividerTheme: const DividerThemeData(color: kLine, thickness: 1),
    // no page transition animations: less GPU work
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: FadeUpwardsPageTransitionsBuilder()}),
  );
}
