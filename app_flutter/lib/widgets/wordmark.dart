import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The MOVIESERVER logotype. One definition so the login page, the top nav
/// bar and the splash screen cannot drift apart.
class Wordmark extends StatelessWidget {
  final double fontSize;
  final VoidCallback? onTap;

  const Wordmark({super.key, this.fontSize = 26, this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Text(
      'MOVIESERVER',
      style: TextStyle(
        color: AppColors.red,
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        letterSpacing: fontSize * 0.045,
        height: 1.0,
      ),
    );
    if (onTap == null) return text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
        child: text,
      ),
    );
  }
}
