import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final String? trickplayUrl; // baseUrl + /api/movies/{id}/trickplay
  final String? token;
  final ValueChanged<Duration> onSeek;

  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    this.trickplayUrl,
    this.token,
    required this.onSeek,
  });

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  bool _hovered = false;
  double _hoverX = 0;
  double _barWidth = 0;
  bool _isDragging = false;
  double _dragRatio = 0;

  Map<String, dynamic>? _manifest;
  bool _manifestChecked = false;

  @override
  void initState() {
    super.initState();
    _loadManifest();
  }

  @override
  void didUpdateWidget(covariant SeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trickplayUrl != widget.trickplayUrl) {
      _manifest = null;
      _manifestChecked = false;
      _loadManifest();
    }
  }

  Future<void> _loadManifest() async {
    if (_manifestChecked || widget.trickplayUrl == null) return;
    _manifestChecked = true;
    try {
      final res = await http.get(Uri.parse(widget.trickplayUrl!), headers: {
        if (widget.token != null) 'Authorization': 'Bearer ${widget.token}',
      });
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (mounted) {
          setState(() => _manifest = data);
        }
      }
    } catch (_) {}
  }

  String _fmt(int totalSeconds) {
    if (totalSeconds < 0) totalSeconds = 0;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget? _buildThumbnail(int previewSec) {
    final m = _manifest;
    if (m == null || widget.trickplayUrl == null) return null;

    final interval = m['interval'] as int? ?? 10;
    final cols = m['cols'] as int? ?? 10;
    final rows = m['rows'] as int? ?? 10;
    final thumbW = m['thumb_w'] as int? ?? 320;
    final thumbH = m['thumb_h'] as int? ?? 180;
    final count = m['count'] as int? ?? 1;

    final i = (previewSec / interval).floor().clamp(0, count - 1);
    final sheetNum = i ~/ (cols * rows) + 1;
    final cell = i % (cols * rows);
    final col = cell % cols;
    final row = cell ~/ cols;

    const displayW = 160.0;
    final scale = displayW / thumbW;
    final displayH = thumbH * scale;

    final spriteUrl = '${widget.trickplayUrl}/sprite_${sheetNum.toString().padLeft(3, '0')}.jpg';

    return Container(
      width: displayW,
      height: displayH,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: -col * thumbW * scale,
            top: -row * thumbH * scale,
            child: Image.network(
              spriteUrl,
              width: thumbW * cols * scale,
              height: thumbH * rows * scale,
              fit: BoxFit.fill,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalSec = widget.duration.inSeconds;
    final curSec = widget.position.inSeconds;
    final playedRatio = totalSec > 0 ? (curSec / totalSec).clamp(0.0, 1.0) : 0.0;
    final bufferedRatio = totalSec > 0 ? (widget.buffered.inSeconds / totalSec).clamp(0.0, 1.0) : 0.0;
    final displayRatio = _isDragging ? _dragRatio : playedRatio;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        if (!_isDragging) _hoverX = 0;
      }),
      onHover: (e) {
        setState(() {
          _hoverX = e.localPosition.dx;
        });
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          _barWidth = constraints.maxWidth;
          final hoverRatio = _barWidth > 0 ? (_hoverX / _barWidth).clamp(0.0, 1.0) : 0.0;
          final previewSec = (hoverRatio * totalSec).round();
          final thumbWidget = _buildThumbnail(previewSec);

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Bubble (Peek)
              if ((_hovered || _isDragging) && _barWidth > 0 && totalSec > 0)
                Positioned(
                  left: (_hoverX - (thumbWidget != null ? 80 : 45)).clamp(8.0, _barWidth - (thumbWidget != null ? 176.0 : 98.0)),
                  bottom: 24,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: const Color(0xE61F1F1F),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white24, width: 1),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2)),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (thumbWidget != null) ...[
                          thumbWidget,
                          const SizedBox(height: 4),
                        ],
                        Text(
                          _fmt(previewSec),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Interactive Slider Bar
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  final r = (details.localPosition.dx / _barWidth).clamp(0.0, 1.0);
                  widget.onSeek(Duration(seconds: (r * totalSec).round()));
                },
                onHorizontalDragStart: (details) {
                  setState(() {
                    _isDragging = true;
                    _dragRatio = (details.localPosition.dx / _barWidth).clamp(0.0, 1.0);
                    _hoverX = details.localPosition.dx;
                  });
                },
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _dragRatio = (details.localPosition.dx / _barWidth).clamp(0.0, 1.0);
                    _hoverX = details.localPosition.dx;
                  });
                },
                onHorizontalDragEnd: (_) {
                  final target = Duration(seconds: (_dragRatio * totalSec).round());
                  setState(() => _isDragging = false);
                  widget.onSeek(target);
                },
                child: Container(
                  height: 20,
                  alignment: Alignment.center,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Background Track
                      Container(
                        height: _hovered || _isDragging ? 7 : 4,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      // Buffered Track
                      Container(
                        height: _hovered || _isDragging ? 7 : 4,
                        width: _barWidth * bufferedRatio,
                        decoration: BoxDecoration(
                          color: Colors.white38,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      // Played Track
                      Container(
                        height: _hovered || _isDragging ? 7 : 4,
                        width: _barWidth * displayRatio,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE50914),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      // Thumb Dot
                      if (_hovered || _isDragging)
                        Positioned(
                          left: (_barWidth * displayRatio - 7).clamp(0.0, _barWidth - 14.0),
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: const BoxDecoration(
                              color: Color(0xFFE50914),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(color: Colors.black45, blurRadius: 4),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
