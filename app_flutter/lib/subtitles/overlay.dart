import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/tokens.dart';
import 'parser.dart';

/// How the text is separated from the picture behind it.
enum SubtitleBackground {
  /// Outline only - the cinema default.
  none,

  /// Outline plus a soft drop shadow; easier to read over bright scenes.
  shadow,

  /// A filled box behind the text.
  box;

  String get label => switch (this) {
        SubtitleBackground.none => 'None',
        SubtitleBackground.shadow => 'Shadow',
        SubtitleBackground.box => 'Box',
      };
}

class SubtitleStyle {
  final String fontFamily;
  final double fontSize;
  final Color textColor;
  final Color outlineColor;
  final SubtitleBackground background;
  final Color backgroundColor;

  /// Pixels from the bottom of the video area.
  final double bottomOffset;

  /// Pixels from the horizontal centre; negative moves left, positive right.
  /// Subtitles used to be locked to the centre and draggable only up and down.
  final double sideOffset;

  const SubtitleStyle({
    this.fontFamily = 'Noto Sans',
    this.fontSize = 24.0,
    this.textColor = Colors.white,
    this.outlineColor = Colors.black,
    this.background = SubtitleBackground.none,
    this.backgroundColor = const Color(0xCC000000),
    this.bottomOffset = 85.0,
    this.sideOffset = 0.0,
  });

  SubtitleStyle copyWith({
    String? fontFamily,
    double? fontSize,
    Color? textColor,
    Color? outlineColor,
    SubtitleBackground? background,
    Color? backgroundColor,
    double? bottomOffset,
    double? sideOffset,
  }) {
    return SubtitleStyle(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      outlineColor: outlineColor ?? this.outlineColor,
      background: background ?? this.background,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      bottomOffset: bottomOffset ?? this.bottomOffset,
      sideOffset: sideOffset ?? this.sideOffset,
    );
  }

  Future<void> saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sub_font_family', fontFamily);
      await prefs.setDouble('sub_font_size', fontSize);
      await prefs.setInt('sub_text_color', textColor.value);
      await prefs.setInt('sub_outline_color', outlineColor.value);
      await prefs.setString('sub_bg_mode', background.name);
      await prefs.setInt('sub_bg_color', backgroundColor.value);
      await prefs.setDouble('sub_bottom_offset', bottomOffset);
      await prefs.setDouble('sub_side_offset', sideOffset);
    } catch (_) {}
  }

  /// Reads the background mode, falling back to the older boolean setting so
  /// a saved preference is not lost.
  static SubtitleBackground _readBackground(SharedPreferences prefs) {
    final name = prefs.getString('sub_bg_mode');
    if (name != null) {
      for (final v in SubtitleBackground.values) {
        if (v.name == name) return v;
      }
    }
    return (prefs.getBool('sub_has_bg') ?? false)
        ? SubtitleBackground.box
        : SubtitleBackground.none;
  }

  static Future<SubtitleStyle> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final textInt = prefs.getInt('sub_text_color');
      final outInt = prefs.getInt('sub_outline_color');
      final bgInt = prefs.getInt('sub_bg_color');

      return SubtitleStyle(
        fontFamily: prefs.getString('sub_font_family') ?? 'Noto Sans',
        fontSize: prefs.getDouble('sub_font_size') ?? 24.0,
        textColor: textInt != null ? Color(textInt) : Colors.white,
        outlineColor: outInt != null ? Color(outInt) : Colors.black,
        background: _readBackground(prefs),
        backgroundColor: bgInt != null ? Color(bgInt) : const Color(0xCC000000),
        bottomOffset: prefs.getDouble('sub_bottom_offset') ?? 85.0,
        sideOffset: prefs.getDouble('sub_side_offset') ?? 0.0,
      );
    } catch (_) {
      return const SubtitleStyle();
    }
  }
}

/// Draws the active cues over the video and lets them be dragged anywhere in
/// the frame, not just up and down.
class SubtitleOverlay extends StatefulWidget {
  final List<SubtitleCue> cues;
  final Duration position;
  final Duration delay;
  final SubtitleStyle style;

  /// Reports a new (sideOffset, bottomOffset) while dragging.
  final void Function(double side, double bottom)? onPositionChanged;

  /// Called once when a drag finishes, so the caller can persist.
  final VoidCallback? onPositionCommitted;
  final bool showPositionGuide;

  const SubtitleOverlay({
    super.key,
    required this.cues,
    required this.position,
    this.delay = Duration.zero,
    this.style = const SubtitleStyle(),
    this.onPositionChanged,
    this.onPositionCommitted,
    this.showPositionGuide = false,
  });

  @override
  State<SubtitleOverlay> createState() => _SubtitleOverlayState();
}

class _SubtitleOverlayState extends State<SubtitleOverlay> {
  bool _dragging = false;

  // A drag accumulates against its own starting point rather than against the
  // style prop. Reading the prop each event only worked if the parent rebuilt
  // between pointer moves, so fast drags lost everything but the last delta.
  double _dragSide = 0;
  double _dragBottom = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.cues.isEmpty) return const SizedBox.shrink();

    final effectivePos = widget.position + widget.delay;
    final active = widget.cues.where((c) => c.matches(effectivePos)).toList();
    if (active.isEmpty && !_dragging) return const SizedBox.shrink();

    final top = active.where((c) => c.isTop).toList();
    final bottom = active.where((c) => !c.isTop).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        return Stack(
          children: [
            // Cues the file explicitly positions at the top stay put; only the
            // main block is draggable.
            if (top.isNotEmpty)
              Positioned(
                top: 32,
                left: 32,
                right: 32,
                child: IgnorePointer(child: _cueList(top)),
              ),
            if (bottom.isNotEmpty || _dragging)
              _draggableBlock(bottom, w, h),
          ],
        );
      },
    );
  }

  Widget _draggableBlock(List<SubtitleCue> cues, double w, double h) {
    final style = widget.style;
    // Keep the block on screen no matter how far the pointer travels.
    final maxSide = w / 2;
    final maxBottom = h - 40;
    final side =
        (_dragging ? _dragSide : style.sideOffset).clamp(-maxSide, maxSide);
    final bottom =
        (_dragging ? _dragBottom : style.bottomOffset).clamp(0.0, maxBottom);
    final draggable = widget.onPositionChanged != null;

    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: Align(
        alignment: Alignment.center,
        child: Transform.translate(
          offset: Offset(side, 0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: draggable
                ? (_) => setState(() {
                      _dragging = true;
                      _dragSide = style.sideOffset;
                      _dragBottom = style.bottomOffset;
                    })
                : null,
            onPanUpdate: draggable
                ? (d) {
                    setState(() {
                      _dragSide =
                          (_dragSide + d.delta.dx).clamp(-maxSide, maxSide);
                      _dragBottom =
                          (_dragBottom - d.delta.dy).clamp(0.0, maxBottom);
                    });
                    widget.onPositionChanged!(_dragSide, _dragBottom);
                  }
                : null,
            onPanEnd: draggable ? (_) => _endDrag() : null,
            onPanCancel: draggable ? _endDrag : null,
            child: MouseRegion(
              cursor: draggable
                  ? (_dragging
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab)
                  : MouseCursor.defer,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.showPositionGuide || _dragging) _handle(),
                  if (cues.isNotEmpty) _cueList(cues),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _endDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onPositionCommitted?.call();
  }

  Widget _handle() {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: _dragging ? AppColors.red : AppColors.borderStrong,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.open_with, size: 12, color: AppColors.textPrimary),
          SizedBox(width: AppSpacing.xs),
          Text('Drag to move',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _cueList(List<SubtitleCue> list) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [for (final cue in list) _cueText(cue)],
    );
  }

  Widget _cueText(SubtitleCue cue) {
    final style = widget.style;
    final String? font = style.fontFamily == 'System' ? null : style.fontFamily;

    Widget content = Stack(
      children: [
        // Outline stroke behind the fill keeps text readable on any frame.
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
        Text(
          cue.text,
          textAlign: TextAlign.center,
          textDirection: cue.direction,
          style: TextStyle(
            fontFamily: font,
            fontSize: style.fontSize,
            fontWeight: FontWeight.w700,
            color: style.textColor,
            shadows: style.background == SubtitleBackground.shadow
                ? const [
                    Shadow(color: Color(0xE6000000), blurRadius: 10),
                    Shadow(
                        color: Color(0x99000000),
                        blurRadius: 4,
                        offset: Offset(0, 2)),
                  ]
                : null,
          ),
        ),
      ],
    );

    if (style.background == SubtitleBackground.box) {
      content = Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: style.backgroundColor,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: content,
      );
    }
    return content;
  }
}
