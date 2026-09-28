import 'package:flutter/material.dart';

/// Design tokens for the Netflix-style skin. Every colour, gap, radius and
/// duration in the app comes from here so a restyle touches one file.
abstract final class AppColors {
  static const black = Color(0xFF000000);

  /// Page background.
  static const bg = Color(0xFF141414);

  /// Cards, sheets, menus.
  static const surface = Color(0xFF1F1F1F);

  /// Raised elements inside a surface (chips, inputs, placeholders).
  static const surfaceHigh = Color(0xFF262626);
  static const surfaceHigher = Color(0xFF2A2A2A);

  /// Brand red.
  static const red = Color(0xFFE50914);
  static const redHover = Color(0xFFF6121D);

  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB3B3B3);
  static const textTertiary = Color(0xFF808080);

  static const border = Color(0x1FFFFFFF);
  static const borderStrong = Color(0x3DFFFFFF);

  /// Scrims used over artwork and under the player chrome.
  static const scrim = Color(0xCC000000);
  static const scrimSoft = Color(0x99000000);
  static const scrimHeavy = Color(0xF2000000);

  static const success = Color(0xFF46D369);
  static const warning = Color(0xFFFFB800);

  /// Top-to-bottom fade that lets text sit on a backdrop image.
  static const heroScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00141414), Color(0x99141414), Color(0xFF141414)],
    stops: [0.0, 0.6, 1.0],
  );

  /// Left-to-right fade behind hero copy.
  static const heroSideScrim = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xE6141414), Color(0x80141414), Color(0x00141414)],
    stops: [0.0, 0.5, 1.0],
  );
}

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;
}

abstract final class AppRadius {
  static const card = 4.0;
  static const control = 4.0;
  static const panel = 8.0;
  static const modal = 12.0;
  static const pill = 999.0;
}

abstract final class AppMotion {
  static const fast = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 450);

  static const easeOut = Curves.easeOutCubic;
  static const emphasized = Curves.easeOutQuint;
}

abstract final class AppShadows {
  static const card = [
    BoxShadow(color: Color(0xB3000000), blurRadius: 16, offset: Offset(0, 8)),
  ];
  static const menu = [
    BoxShadow(color: Color(0xCC000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
}
