import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'parser.dart';

class SubtitleStyle {
  final String fontFamily;
  final double fontSize;
  final Color textColor;
  final Color outlineColor;
  final bool hasBackground;
  final Color backgroundColor;
  final double bottomOffset;

  const SubtitleStyle({
    this.fontFamily = 'Noto Sans',
    this.fontSize = 24.0,
    this.textColor = Colors.white,
    this.outlineColor = Colors.black,
    this.hasBackground = false,
    this.backgroundColor = const Color(0xCC000000),
    this.bottomOffset = 85.0,
  });

  SubtitleStyle copyWith({
    String? fontFamily,
    double? fontSize,
    Color? textColor,
    Color? outlineColor,
    bool? hasBackground,
    Color? backgroundColor,
    double? bottomOffset,
  }) {
    return SubtitleStyle(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      outlineColor: outlineColor ?? this.outlineColor,
      hasBackground: hasBackground ?? this.hasBackground,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      bottomOffset: bottomOffset ?? this.bottomOffset,
    );
  }

  Future<void> saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sub_font_family', fontFamily);
      await prefs.setDouble('sub_font_size', fontSize);
      await prefs.setInt('sub_text_color', textColor.value);
      await prefs.setInt('sub_outline_color', outlineColor.value);
      await prefs.setBool('sub_has_bg', hasBackground);
      await prefs.setInt('sub_bg_color', backgroundColor.value);
      await prefs.setDouble('sub_bottom_offset', bottomOffset);
    } catch (_) {}
  }

  static Future<SubtitleStyle> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = prefs.getString('sub_font_family') ?? 'Noto Sans';
      final size = prefs.getDouble('sub_font_size') ?? 24.0;
      final textInt = prefs.getInt('sub_text_color');
      final outInt = prefs.getInt('sub_outline_color');
      final hasBg = prefs.getBool('sub_has_bg') ?? false;
      final bgInt = prefs.getInt('sub_bg_color');
      final offset = prefs.getDouble('sub_bottom_offset') ?? 85.0;

      return SubtitleStyle(
        fontFamily: family,
        fontSize: size,
        textColor: textInt != null ? Color(textInt) : Colors.white,
        outlineColor: outInt != null ? Color(outInt) : Colors.black,
        hasBackground: hasBg,
        backgroundColor: bgInt != null ? Color(bgInt) : const Color(0xCC000000),
        bottomOffset: offset,
      );
    } catch (_) {
      return const SubtitleStyle();
    }
  }
}

class SubtitleOverlay extends StatelessWidget {
  final List<SubtitleCue> cues;
  final Duration position;
  final Duration delay;
  final SubtitleStyle style;
  final ValueChanged<double>? onPositionChanged;
  final bool showPositionGuide;

  const SubtitleOverlay({
    super.key,
    required this.cues,
    required this.position,
    this.delay = Duration.zero,
    this.style = const SubtitleStyle(),
    this.onPositionChanged,
    this.showPositionGuide = false,
  });

  @override
  Widget build(BuildContext context) {
    if (cues.isEmpty) return const SizedBox.shrink();

    final effectivePos = position + delay;
    final activeCues = cues.where((c) => c.matches(effectivePos)).toList();
    if (activeCues.isEmpty) return const SizedBox.shrink();

    final topCues = activeCues.where((c) => c.isTop).toList();
    final bottomCues = activeCues.where((c) => !c.isTop).toList();

    return Stack(
      children: [
        if (topCues.isNotEmpty)
          Positioned(
            top: 32,
            left: 32,
            right: 32,
            child: IgnorePointer(
              child: _buildCueList(topCues),
            ),
          ),
        if (bottomCues.isNotEmpty)
          Positioned(
            bottom: style.bottomOffset.clamp(20.0, 700.0),
            left: 32,
            right: 32,
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (details) {
                  if (onPositionChanged != null) {
                    final newOffset = (style.bottomOffset - details.delta.dy)
                        .clamp(20.0, 700.0);
                    onPositionChanged!(newOffset);
                  }
                },
                child: MouseRegion(
                  cursor: onPositionChanged != null
                      ? SystemMouseCursors.grab
                      : MouseCursor.defer,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showPositionGuide)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.drag_handle,
                                  size: 14, color: Colors.white70),
                              SizedBox(width: 4),
                              Text('Drag to move',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 10)),
                            ],
                          ),
                        ),
                      _buildCueList(bottomCues),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCueList(List<SubtitleCue> list) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: list.map((cue) => _buildCueText(cue)).toList(),
    );
  }

  Widget _buildCueText(SubtitleCue cue) {
    final String? font = style.fontFamily == 'System' ? null : style.fontFamily;

    Widget textContent = Stack(
      children: [
        // Outline stroke
        Text(
          cue.text,
          textAlign: TextAlign.center,
          textDirection: cue.direction,
          style: TextStyle(
            fontFamily: font,
            fontSize: style.fontSize,
            fontWeight: FontWeight.w700,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = (style.fontSize * 0.14).clamp(2.0, 5.0)
              ..color = style.outlineColor,
          ),
        ),
        // Text fill
        Text(
          cue.text,
          textAlign: TextAlign.center,
          textDirection: cue.direction,
          style: TextStyle(
            fontFamily: font,
            fontSize: style.fontSize,
            fontWeight: FontWeight.w700,
            color: style.textColor,
          ),
        ),
      ],
    );

    if (style.hasBackground) {
      textContent = Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: style.backgroundColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: textContent,
      );
    }

    return textContent;
  }
}
