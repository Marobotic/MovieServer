import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';

/// Presentation shell for a title's detail view.
///
/// On desktop the caller opens this inside a dialog, so it renders as the
/// Netflix "info card": a rounded panel floating over the browse page with a
/// backdrop header and a close button. On phones the same content is a normal
/// full-height page.
class DetailScaffold extends StatelessWidget {
  final bool modal;
  final String? backdropUrl;
  final String title;

  /// Rendered over the bottom of the backdrop (title block + action buttons).
  final Widget header;

  /// Everything below the backdrop.
  final List<Widget> children;

  const DetailScaffold({
    super.key,
    required this.modal,
    required this.backdropUrl,
    required this.title,
    required this.header,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final pad = modal ? AppSpacing.xxl : size.gutter;

    final content = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Backdrop(
            url: backdropUrl,
            title: title,
            height: modal
                ? 380
                : (size.isCompact ? 260 : size.heroHeight * 0.6),
            surface: modal ? AppColors.surface : AppColors.bg,
            header: Padding(
              padding: EdgeInsets.fromLTRB(pad, 0, pad, AppSpacing.xl),
              child: header,
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, AppSpacing.xxl),
          sliver: SliverList(delegate: SliverChildListDelegate(children)),
        ),
      ],
    );

    if (!modal) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Stack(
          children: [
            Positioned.fill(child: content),
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: _RoundIcon(
                    icon: Icons.arrow_back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final viewport = MediaQuery.sizeOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 880,
            maxHeight: viewport.height * 0.9,
          ),
          child: Material(
            color: AppColors.surface,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(AppRadius.modal),
            child: Stack(
              children: [
                Positioned.fill(child: content),
                Positioned(
                  top: AppSpacing.lg,
                  right: AppSpacing.lg,
                  child: _RoundIcon(
                    icon: Icons.close,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  final String? url;
  final String title;
  final double height;
  final Color surface;
  final Widget header;

  const _Backdrop({
    required this.url,
    required this.title,
    required this.height,
    required this.surface,
    required this.header,
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
          if (src.isEmpty)
            const ColoredBox(color: AppColors.surfaceHigh)
          else
            Image.network(
              src,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: AppColors.surfaceHigh),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  surface.withOpacity(0.0),
                  surface.withOpacity(0.65),
                  surface,
                ],
                stops: const [0.25, 0.75, 1.0],
              ),
            ),
          ),
          Align(alignment: Alignment.bottomLeft, child: header),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _RoundIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.black.withOpacity(0.6),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Icon(icon, color: AppColors.textPrimary, size: 22),
        ),
      ),
    );
  }
}

/// Title + action row shown over the backdrop.
class DetailHeader extends StatelessWidget {
  final String title;
  final String meta;
  final List<Widget> actions;

  const DetailHeader({
    super.key,
    required this.title,
    required this.meta,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: size.isCompact ? 26 : 38,
            fontWeight: FontWeight.w900,
            height: 1.1,
            shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 10)],
          ),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            meta,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.sm,
          children: actions,
        ),
      ],
    );
  }
}
