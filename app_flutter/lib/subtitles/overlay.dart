import 'package:flutter/material.dart';
import 'parser.dart';

class SubtitleOverlay extends StatelessWidget {
  final List<SubtitleCue> cues;
  final Duration position;
  final Duration delay;
  final double fontSize;
  final Color textColor;
  final Color outlineColor;
  final bool hasBackground;

  const SubtitleOverlay({
    super.key,
    required this.cues,
    required this.position,
    this.delay = Duration.zero,
    this.fontSize = 20.0,
    this.textColor = Colors.white,
    this.outlineColor = Colors.black,
    this.hasBackground = false,
  });

  @override
  Widget build(BuildContext context) {
    if (cues.isEmpty) return const SizedBox.shrink();

    final effectivePos = position + delay;
    final activeCues = cues.where((c) => c.matches(effectivePos)).toList();
    if (activeCues.isEmpty) return const SizedBox.shrink();

    final topCues = activeCues.where((c) => c.isTop).toList();
    final bottomCues = activeCues.where((c) => !c.isTop).toList();

    return IgnorePointer(
      child: Stack(
        children: [
          if (topCues.isNotEmpty)
            Positioned(
              top: 32,
              left: 32,
              right: 32,
              child: _buildCueList(topCues),
            ),
          if (bottomCues.isNotEmpty)
            Positioned(
              bottom: 64,
              left: 32,
              right: 32,
              child: _buildCueList(bottomCues),
            ),
        ],
      ),
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
    Widget textContent = Stack(
      children: [
        // Outline
        Text(
          cue.text,
          textAlign: TextAlign.center,
          textDirection: cue.direction,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = (fontSize * 0.15).clamp(2.0, 4.0)
              ..color = outlineColor,
          ),
        ),
        // Fill
        Text(
          cue.text,
          textAlign: TextAlign.center,
          textDirection: cue.direction,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ],
    );

    if (hasBackground) {
      textContent = Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          borderRadius: BorderRadius.circular(4),
        ),
        child: textContent,
      );
    }

    return textContent;
  }
}
