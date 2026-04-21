import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // PREMIUM LIGHT COLOR PALETTE
  static const Color background = Color(0xFFF8F9FA); // Very light grey surface
  static const Color surface = Color(0xFFFFFFFF);     // Pure white
  static const Color accent = Color(0xFFFDB022);      // Taxi Gold
  static const Color primaryText = Color(0xFF1D1F24); // Deep charcoal
  static const Color secondaryText = Color(0xFF6C757D); // Muted grey
  static const Color divider = Color(0xFFE9ECEF);    // Soft border

  static ThemeData get lightTheme {
    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: background,
      primaryColor: accent,
      useMaterial3: true,
      cardColor: surface,
      dividerColor: divider,
      textTheme: GoogleFonts.outfitTextTheme(
        ThemeData.light().textTheme.copyWith(
          displayLarge: const TextStyle(fontSize: 96, fontWeight: FontWeight.bold, letterSpacing: -2, color: primaryText),
          displayMedium: const TextStyle(fontSize: 32, fontWeight: FontWeight.w300, color: accent),
          titleLarge: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: primaryText),
          labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: secondaryText),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
    );
  }

  static BoxDecoration glassBox({double blur = 10, double opacity = 1.0}) {
    return BoxDecoration(
      color: surface.withOpacity(opacity),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: divider),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 20,
          offset: const Offset(0, 10),
        )
      ],
    );
  }
}
