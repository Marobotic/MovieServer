import 'package:flutter/widgets.dart';

/// Layout sizes the UI adapts to. The app was phone-only; every responsive
/// decision now goes through this enum instead of ad-hoc width checks.
enum WindowSize { compact, medium, expanded, wide }

abstract final class Breakpoints {
  static const medium = 600.0;
  static const expanded = 1024.0;
  static const wide = 1600.0;

  static WindowSize of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);

  static WindowSize fromWidth(double width) {
    if (width >= wide) return WindowSize.wide;
    if (width >= expanded) return WindowSize.expanded;
    if (width >= medium) return WindowSize.medium;
    return WindowSize.compact;
  }
}

extension WindowSizeX on WindowSize {
  bool get isCompact => this == WindowSize.compact;
  bool get isMedium => this == WindowSize.medium;

  /// True for tablet-and-up: top navigation instead of a bottom bar.
  bool get hasTopNav => index >= WindowSize.medium.index;

  /// True for desktop-shaped windows: hover affordances, modal detail pages.
  bool get isDesktop => index >= WindowSize.expanded.index;

  /// Horizontal page gutter, matching Netflix's wide margins on big screens.
  double get gutter => switch (this) {
        WindowSize.compact => 16.0,
        WindowSize.medium => 32.0,
        WindowSize.expanded => 48.0,
        WindowSize.wide => 60.0,
      };

  /// Width of one poster card in a browse row.
  double get posterWidth => switch (this) {
        WindowSize.compact => 116.0,
        WindowSize.medium => 150.0,
        WindowSize.expanded => 180.0,
        WindowSize.wide => 210.0,
      };

  /// Width of one 16:9 thumbnail card (continue watching, episodes).
  double get thumbWidth => switch (this) {
        WindowSize.compact => 200.0,
        WindowSize.medium => 250.0,
        WindowSize.expanded => 300.0,
        WindowSize.wide => 340.0,
      };

  /// Height of the hero billboard.
  double get heroHeight => switch (this) {
        WindowSize.compact => 460.0,
        WindowSize.medium => 520.0,
        WindowSize.expanded => 620.0,
        WindowSize.wide => 720.0,
      };
}
