import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/breakpoints.dart';
import '../theme/tokens.dart';

enum ToastKind { info, success, warning, error }

/// Top-right notifications.
///
/// The default SnackBar is pinned to the bottom of the screen, where in the
/// player it lands squarely on top of the seek bar and transport controls and
/// covers the very thing you just changed. These sit clear of the chrome,
/// stack downwards, and each one can be dismissed outright rather than only
/// offering its action.
abstract final class Toast {
  static final List<_ToastHandle> _live = [];

  static void show(
    BuildContext context,
    String message, {
    ToastKind kind = ToastKind.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // Something worth acting on should not vanish while you reach for it.
    final life = duration ??
        (actionLabel != null
            ? const Duration(seconds: 12)
            : const Duration(seconds: 6));

    late final _ToastHandle handle;
    final entry = OverlayEntry(
      builder: (context) => _ToastCard(
        message: message,
        kind: kind,
        actionLabel: actionLabel,
        index: _live.indexOf(handle),
        onAction: onAction == null
            ? null
            : () {
                handle.dismiss();
                onAction();
              },
        onDismiss: () => handle.dismiss(),
      ),
    );

    handle = _ToastHandle(entry);
    _live.add(handle);
    overlay.insert(entry);
    handle.timer = Timer(life, handle.dismiss);

    // Keep the stack shallow; the oldest goes first.
    while (_live.length > 3) {
      _live.first.dismiss();
    }
  }

  static void _remove(_ToastHandle h) {
    if (!_live.remove(h)) return;
    h.entry.remove();
    // Everything below shuffles up.
    for (final other in _live) {
      other.entry.markNeedsBuild();
    }
  }
}

class _ToastHandle {
  final OverlayEntry entry;
  Timer? timer;
  bool _gone = false;

  _ToastHandle(this.entry);

  void dismiss() {
    if (_gone) return;
    _gone = true;
    timer?.cancel();
    Toast._remove(this);
  }
}

class _ToastCard extends StatefulWidget {
  final String message;
  final ToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;
  final int index;

  const _ToastCard({
    required this.message,
    required this.kind,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
    required this.index,
  });

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  )..forward();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  (IconData, Color) get _badge => switch (widget.kind) {
        ToastKind.success => (Icons.check_circle_outline, AppColors.success),
        ToastKind.warning => (Icons.warning_amber_rounded, AppColors.warning),
        ToastKind.error => (Icons.error_outline, AppColors.red),
        ToastKind.info => (Icons.info_outline, AppColors.textSecondary),
      };

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final (icon, colour) = _badge;
    final slot = widget.index < 0 ? 0 : widget.index;
    final curved = CurvedAnimation(parent: _ctl, curve: AppMotion.emphasized);

    return Positioned(
      top: MediaQuery.paddingOf(context).top + AppSpacing.lg + slot * 92,
      right: size.gutter,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, child) => Opacity(
          opacity: curved.value,
          child: Transform.translate(
            offset: Offset((1 - curved.value) * 28, 0),
            child: child,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: size.isCompact ? 320 : 400,
            ),
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.scrimHeavy,
                borderRadius: BorderRadius.circular(AppRadius.panel),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadows.menu,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(icon, size: 18, color: colour),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.message,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                        if (widget.actionLabel != null) ...[
                          const SizedBox(height: AppSpacing.sm),
                          SizedBox(
                            height: 30,
                            child: OutlinedButton(
                              onPressed: widget.onAction,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.md),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                textStyle: const TextStyle(
                                    fontFamily: 'Noto Sans', fontSize: 12),
                              ),
                              child: Text(widget.actionLabel!),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    color: AppColors.textTertiary,
                    onPressed: widget.onDismiss,
                    tooltip: 'Dismiss',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
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
