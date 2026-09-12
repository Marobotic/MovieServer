import 'dart:ui';
import 'package:flutter/widgets.dart';

class SubtitleCue {
  final Duration start;
  final Duration end;
  final String text;
  final bool isTop;
  final TextDirection direction;

  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
    this.isTop = false,
    this.direction = TextDirection.ltr,
  });

  bool matches(Duration position) => position >= start && position <= end;
}

class SubtitleParser {
  static final RegExp _arabicRegex = RegExp(
    r'[\u0590-\u08FF\uFB1D-\uFDFF\uFE70-\uFEFF]',
  );

  static TextDirection detectDirection(String text) {
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      // Skip whitespace, punctuation, digits
      if (code <= 0x40 || (code >= 0x5B && code <= 0x60) || (code >= 0x7B && code <= 0xBF)) {
        continue;
      }
      final char = text[i];
      if (_arabicRegex.hasMatch(char)) {
        return TextDirection.rtl;
      }
      return TextDirection.ltr;
    }
    return TextDirection.ltr;
  }

  static List<SubtitleCue> parse(String content) {
    if (content.isEmpty) return [];

    // Strip BOM
    if (content.startsWith('\uFEFF')) {
      content = content.substring(1);
    }

    // Normalize line breaks
    final lines = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final cues = <SubtitleCue>[];

    int i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();

      // Skip WEBVTT header, NOTE, STYLE, comments, empty lines
      if (line.isEmpty ||
          line.startsWith('WEBVTT') ||
          line.startsWith('NOTE') ||
          line.startsWith('STYLE')) {
        i++;
        continue;
      }

      // Check if this line is an index or directly a timestamp line
      String timestampLine = line;
      if (!line.contains('-->') && i + 1 < lines.length && lines[i + 1].contains('-->')) {
        i++;
        timestampLine = lines[i].trim();
      }

      if (timestampLine.contains('-->')) {
        final arrowParts = timestampLine.split('-->');
        if (arrowParts.length == 2) {
          final start = _parseTimestamp(arrowParts[0].trim());
          final endRaw = arrowParts[1].trim().split(RegExp(r'\s+'))[0];
          final end = _parseTimestamp(endRaw);

          i++;
          final textLines = <String>[];
          bool isTop = false;

          while (i < lines.length && lines[i].trim().isNotEmpty) {
            String textLine = lines[i].trim();
            if (textLine.contains(r'{\an8}') ||
                textLine.contains(r'{\an7}') ||
                textLine.contains(r'{\an9}')) {
              isTop = true;
            }
            textLine = textLine.replaceAll(RegExp(r'\{\\[^}]*\}'), '');
            textLine = textLine.replaceAll(RegExp(r'<[^>]*>'), '');
            if (textLine.isNotEmpty) {
              textLines.add(textLine);
            }
            i++;
          }

          if (start != null && end != null && textLines.isNotEmpty) {
            final fullText = textLines.join('\n');
            final dir = detectDirection(fullText);
            cues.add(SubtitleCue(
              start: start,
              end: end,
              text: fullText,
              isTop: isTop,
              direction: dir,
            ));
          }
        }
      }
      i++;
    }

    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  static Duration? _parseTimestamp(String raw) {
    raw = raw.replaceAll(',', '.');
    final parts = raw.split(':');
    try {
      if (parts.length == 3) {
        final hours = int.parse(parts[0]);
        final minutes = int.parse(parts[1]);
        final secParts = parts[2].split('.');
        final seconds = int.parse(secParts[0]);
        final millis = secParts.length > 1 ? int.parse(secParts[1].padRight(3, '0').substring(0, 3)) : 0;
        return Duration(hours: hours, minutes: minutes, seconds: seconds, milliseconds: millis);
      } else if (parts.length == 2) {
        final minutes = int.parse(parts[0]);
        final secParts = parts[1].split('.');
        final seconds = int.parse(secParts[0]);
        final millis = secParts.length > 1 ? int.parse(secParts[1].padRight(3, '0').substring(0, 3)) : 0;
        return Duration(minutes: minutes, seconds: seconds, milliseconds: millis);
      }
    } catch (_) {}
    return null;
  }
}
