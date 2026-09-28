import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The small floating panel the player uses for its menus. Sized to its
/// content with a hard height cap, so it never covers the video the way the
/// old half-screen bottom sheets did.
class PlayerPanel extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final double width;
  final double maxHeight;

  /// Shows a back chevron instead of a close button when set.
  final VoidCallback? onBack;
  final VoidCallback? onClose;

  /// Pinned under the title, above the scrolling body - used for the tab bar,
  /// which must stay put while the content below it scrolls.
  final Widget? subheader;

  const PlayerPanel({
    super.key,
    required this.title,
    required this.children,
    this.width = 360,
    this.maxHeight = 420,
    this.onBack,
    this.onClose,
    this.subheader,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: AppColors.scrimHeavy,
          borderRadius: BorderRadius.circular(AppRadius.panel),
          border: Border.all(color: AppColors.border),
          boxShadow: AppShadows.menu,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.xs),
              child: Row(
                children: [
                  if (onBack != null)
                    _iconButton(Icons.chevron_left, onBack!, 'Back'),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                          left: onBack != null ? AppSpacing.xs : 0),
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                  if (onClose != null)
                    _iconButton(Icons.close, onClose!, 'Close'),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.border),
            if (subheader != null) subheader!,
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(AppSpacing.md,
                    subheader == null ? AppSpacing.md : 0,
                    AppSpacing.md, AppSpacing.md),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap, String tooltip) {
    return IconButton(
      icon: Icon(icon, size: 18, color: AppColors.textSecondary),
      onPressed: onTap,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }
}

/// A selectable line in a player menu column.
class PlayerMenuOption extends StatefulWidget {
  final String label;
  final String? sublabel;
  final bool selected;
  final VoidCallback onTap;

  const PlayerMenuOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.sublabel,
  });

  @override
  State<PlayerMenuOption> createState() => _PlayerMenuOptionState();
}

class _PlayerMenuOptionState extends State<PlayerMenuOption> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: _hover ? AppColors.border : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: widget.selected
                    ? const Icon(Icons.check,
                        size: 15, color: AppColors.textPrimary)
                    : null,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: widget.selected
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                    if (widget.sublabel != null &&
                        widget.sublabel!.isNotEmpty)
                      Text(
                        widget.sublabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textTertiary, fontSize: 11),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
