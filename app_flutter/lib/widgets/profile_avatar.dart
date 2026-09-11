import 'package:flutter/material.dart';

/// Circular avatar showing the user's initial on their chosen color,
/// Netflix-profile style. Supports a "Guest"/add style when profile is null.
class ProfileAvatar extends StatelessWidget {
  final String? username;
  final Color? color;
  final double size;
  final bool isAdd;

  const ProfileAvatar({
    super.key,
    this.username,
    this.color,
    this.size = 96,
    this.isAdd = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isAdd
            ? Colors.transparent
            : (color ?? const Color(0xFF3D5AFE)),
        shape: BoxShape.circle,
        border: isAdd
            ? Border.all(color: Colors.white54, width: 2)
            : null,
      ),
      child: isAdd
          ? Icon(Icons.add, color: Colors.white54, size: size * 0.5)
          : Center(
              child: Text(
                username != null && username!.isNotEmpty
                    ? username!.substring(0, 1).toUpperCase()
                    : '?',
                style: TextStyle(
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
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