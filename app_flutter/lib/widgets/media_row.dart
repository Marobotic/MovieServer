import 'package:flutter/material.dart';

import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import 'media_card.dart';

/// A horizontally scrolling row of cards with a heading, edge fades and
/// hover-revealed paging arrows.
///
/// Items are supplied as a count plus a builder so the underlying
/// [ListView.builder] stays lazy: the previous implementation pre-built a
/// widget for every title in the library on each rebuild.
class MediaRow extends StatefulWidget {
  final String title;
  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;
  final double itemHeight;
  final VoidCallback? onSeeAll;

  const MediaRow({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemHeight,
    this.onSeeAll,
  });

  @override
  State<MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<MediaRow> {
  final ScrollController _controller = ScrollController();
  bool _hover = false;
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void didUpdateWidget(covariant MediaRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted) return;
    if (!_controller.hasClients) {
      if (_canLeft || _canRight) {
        setState(() {
          _canLeft = false;
          _canRight = false;
        });
      }
      return;
    }
    final p = _controller.position;
    final left = p.pixels > 4;
    final right = p.pixels < p.maxScrollExtent - 4;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _page(double dir) {
    if (!_controller.hasClients) return;
    final delta = _controller.position.viewportDimension * 0.85;
    _controller.animateTo(
      (_controller.offset + dir * delta)
          .clamp(0.0, _controller.position.maxScrollExtent),
      duration: AppMotion.medium,
      curve: AppMotion.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final gutter = size.gutter;
    // Room for the hover scale, vertically as overscan and horizontally as the
    // gap between cards, so a lifted card is never clipped or overdrawn.
    const grow = hoverScale - 1.0;
    final overscan = size.isDesktop ? widget.itemHeight * grow / 2 + 2 : 0.0;
    final gap = size.isDesktop
        ? size.posterWidth * grow + AppSpacing.sm
        : AppSpacing.sm;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                gutter, AppSpacing.xl, gutter, AppSpacing.md),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: size.isDesktop ? 22 : 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (widget.onSeeAll != null) ...[
                  const SizedBox(width: AppSpacing.md),
                  AnimatedOpacity(
                    opacity: _hover || !size.isDesktop ? 1 : 0,
                    duration: AppMotion.fast,
                    child: TextButton(
                      onPressed: widget.onSeeAll,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: AppColors.textSecondary,
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('See all', style: TextStyle(fontSize: 12)),
                          Icon(Icons.chevron_right, size: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            height: widget.itemHeight + overscan * 2,
            child: Stack(
              children: [
                ListView.separated(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: EdgeInsets.symmetric(
                      horizontal: gutter, vertical: overscan),
                  itemCount: widget.itemCount,
                  separatorBuilder: (_, __) => SizedBox(width: gap),
                  itemBuilder: widget.itemBuilder,
                ),
                if (size.isDesktop) ...[
                  _edgeFade(left: true, visible: _canLeft, width: gutter),
                  _edgeFade(left: false, visible: _canRight, width: gutter),
                  _arrow(left: true, visible: _hover && _canLeft),
                  _arrow(left: false, visible: _hover && _canRight),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _edgeFade(
      {required bool left, required bool visible, required double width}) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: left ? 0 : null,
      right: left ? null : 0,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: AppMotion.fast,
          child: Container(
            width: width,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: left ? Alignment.centerLeft : Alignment.centerRight,
                end: left ? Alignment.centerRight : Alignment.centerLeft,
                colors: const [AppColors.bg, Color(0x00141414)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _arrow({required bool left, required bool visible}) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: left ? 0 : null,
      right: left ? null : 0,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AppMotion.fast,
        child: IgnorePointer(
          ignoring: !visible,
          child: Center(
            child: Material(
              color: AppColors.black.withOpacity(0.6),
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
              ),
              child: InkWell(
                onTap: () => _page(left ? -1 : 1),
                child: SizedBox(
                  width: 40,
                  height: 72,
                  child: Icon(
                    left ? Icons.chevron_left : Icons.chevron_right,
                    color: AppColors.textPrimary,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
