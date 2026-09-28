import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The user's initial on their chosen colour. Netflix uses a rounded square
/// in the nav bar and a larger one on the account page; [radius] picks between
/// them (pass a large value for a circle).
class ProfileAvatar extends StatelessWidget {
  final String? username;
  final Color? color;
  final double size;
  final double radius;

  const ProfileAvatar({
    super.key,
    this.username,
    this.color,
    this.size = 96,
    this.radius = AppRadius.control,
  });

  @override
  Widget build(BuildContext context) {
    final name = username ?? '';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? const Color(0xFF3D5AFE),
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?',
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
          height: 1.0,
        ),
      ),
    );
  }
}

Color colorFromHex(String hex) {
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 6) {
    h = 'FF$h';
  }
  final v = int.tryParse(h, radix: 16);
  if (v == null) {
    return const Color(0xFF3D5AFE);
  }
  return Color(v);
}
