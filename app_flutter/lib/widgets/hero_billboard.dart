import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';

/// The featured title at the top of the home page: full-bleed backdrop,
/// title, synopsis and the Play / More Info pair.
class HeroBillboard extends StatelessWidget {
  final String title;
  final String? backdropUrl;
  final String overview;
  final String? meta;
  final VoidCallback onPlay;
  final VoidCallback onMoreInfo;

  const HeroBillboard({
    super.key,
    required this.title,
    required this.backdropUrl,
    required this.overview,
    required this.onPlay,
    required this.onMoreInfo,
    this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final src = context.read<Api>().assetUrl(backdropUrl ?? '');
    final height = size.heroHeight;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (src.isEmpty)
            const ColoredBox(color: AppColors.surface)
          else
            Image.network(
              src,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: AppColors.surface),
            ),
          // Bottom fade into the page, plus a side fade behind the copy.
          const DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.heroScrim),
          ),
          if (size.isDesktop)
            const DecoratedBox(
              decoration: BoxDecoration(gradient: AppColors.heroSideScrim),
            ),
          Align(
            alignment:
                size.isDesktop ? Alignment.centerLeft : Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.only(
                left: size.gutter,
                right: size.gutter,
                bottom: size.isDesktop ? 0 : AppSpacing.xxl,
                top: size.isDesktop ? 40 : 0,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: size.isDesktop ? 560 : double.infinity),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: size.isDesktop
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      textAlign:
                          size.isDesktop ? TextAlign.left : TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: size.isDesktop ? 56 : 34,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                        shadows: const [
                          Shadow(color: Color(0xCC000000), blurRadius: 12),
                        ],
                      ),
                    ),
                    if (meta != null && meta!.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        meta!,
                        style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                    if (overview.isNotEmpty && size.hasTopNav) ...[
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        overview,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign:
                            size.isDesktop ? TextAlign.left : TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          height: 1.5,
                          shadows: [
                            Shadow(color: Color(0xCC000000), blurRadius: 8),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton.icon(
                          onPressed: onPlay,
                          icon: const Icon(Icons.play_arrow, size: 26),
                          label: const Text('Play'),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        FilledButton.icon(
                          onPressed: onMoreInfo,
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                AppColors.textTertiary.withOpacity(0.55),
                            foregroundColor: AppColors.textPrimary,
                          ),
                          icon: const Icon(Icons.info_outline, size: 22),
                          label: const Text('More Info'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
