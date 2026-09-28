import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';

/// Artwork with a graceful placeholder and a fade-in, used by every card.
class _Art extends StatelessWidget {
  final String src;
  final String title;

  const _Art({required this.src, required this.title});

  @override
  Widget build(BuildContext context) {
    if (src.isEmpty) return _placeholder();
    return Image.network(
      src,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _placeholder(),
      frameBuilder: (context, child, frame, wasSync) {
        if (wasSync || frame != null) {
          return AnimatedOpacity(
            opacity: 1,
            duration: AppMotion.fast,
            child: child,
          );
        }
        return _placeholder();
      },
    );
  }

  Widget _placeholder() {
    return Container(
      color: AppColors.surfaceHigh,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Text(
        title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
      ),
    );
  }
}

/// How much a card grows under the pointer. MediaRow's gap is derived from
/// this so neighbouring cards never clip the one being hovered.
const double hoverScale = 1.06;

/// Wraps a card so it scales and lifts under the pointer, the way a Netflix
/// row tile does. No-op on touch layouts.
class _Hoverable extends StatefulWidget {
  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;
  final bool enabled;

  const _Hoverable({
    required this.builder,
    required this.onTap,
    required this.enabled,
  });

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final child = GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: widget.builder(_hover && widget.enabled),
    );
    if (!widget.enabled) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Kept modest on purpose: items in a row paint in index order, so a
      // card that grows past the gap gets overdrawn by its right-hand
      // neighbour. MediaRow's separator is sized to match this overhang.
      child: AnimatedScale(
        scale: _hover ? hoverScale : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.easeOut,
        child: child,
      ),
    );
  }
}

/// Corner flag for titles a browser cannot play until the server has
/// remuxed or re-encoded them.
class MediaBadge extends StatelessWidget {
  final String label;
  final Color color;

  const MediaBadge({
    super.key,
    required this.label,
    this.color = AppColors.warning,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: AppColors.black,
          fontSize: 9,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
          height: 1.3,
        ),
      ),
    );
  }
}

/// 2:3 poster tile for browse rows and grids.
class PosterCard extends StatelessWidget {
  final String? url;
  final String title;
  final String? subtitle;
  final double? width;
  final VoidCallback? onTap;

  /// Shown as a corner flag, e.g. "Unprocessed".
  final String? badge;

  const PosterCard({
    super.key,
    required this.url,
    required this.title,
    this.subtitle,
    this.width,
    this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final src = context.read<Api>().assetUrl(url ?? '');
    final w = width ?? size.posterWidth;

    return _Hoverable(
      onTap: onTap,
      enabled: size.isDesktop,
      builder: (hovered) => SizedBox(
        width: w,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              boxShadow: hovered ? AppShadows.card : const [],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Art(src: src, title: title),
                  if (badge != null)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: MediaBadge(label: badge!),
                    ),
                  AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: AppMotion.fast,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0xE6000000)],
                          stops: [0.5, 1.0],
                        ),
                      ),
                      alignment: Alignment.bottomLeft,
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (subtitle != null && subtitle!.isNotEmpty)
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 16:9 tile with a caption underneath, used for Continue Watching and
/// episode lists.
class ThumbCard extends StatelessWidget {
  final String? url;
  final String title;
  final String? subtitle;

  /// 0..1 watched fraction; omitted when there is no progress to show.
  final double? progress;
  final double? width;
  final VoidCallback? onTap;
  final bool showPlayBadge;

  const ThumbCard({
    super.key,
    required this.url,
    required this.title,
    this.subtitle,
    this.progress,
    this.width,
    this.onTap,
    this.showPlayBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final src = context.read<Api>().assetUrl(url ?? '');
    final w = width ?? size.thumbWidth;

    return _Hoverable(
      onTap: onTap,
      enabled: size.isDesktop,
      builder: (hovered) => SizedBox(
        width: w,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: AppMotion.fast,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.card),
                boxShadow: hovered ? AppShadows.card : const [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _Art(src: src, title: title),
                      if (showPlayBadge)
                        Center(
                          child: AnimatedScale(
                            scale: hovered ? 1.0 : 0.85,
                            duration: AppMotion.fast,
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppColors.black.withOpacity(0.55),
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: AppColors.textPrimary, width: 1.5),
                              ),
                              padding: const EdgeInsets.all(AppSpacing.sm),
                              child: const Icon(Icons.play_arrow,
                                  color: AppColors.textPrimary, size: 22),
                            ),
                          ),
                        ),
                      if (progress != null && progress! > 0)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: progress!.clamp(0.0, 1.0),
                            minHeight: 3,
                            color: AppColors.red,
                            backgroundColor: AppColors.borderStrong,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

/// Full-bleed backdrop with a scrim, used behind detail headers.
class BackdropImage extends StatelessWidget {
  final String? url;
  final String title;
  final double height;

  const BackdropImage({
    super.key,
    required this.url,
    required this.title,
    this.height = 280,
  });

  @override
  Widget build(BuildContext context) {
    final src = context.read<Api>().assetUrl(url ?? '');
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: AppColors.surface,
            child: _Art(src: src, title: title),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.heroScrim),
          ),
        ],
      ),
    );
  }
}
