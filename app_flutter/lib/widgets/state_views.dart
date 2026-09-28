import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Shared loading / empty / error states so every screen fails the same way.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
              color: AppColors.red, strokeWidth: 2.5),
        ),
      );
}

class EmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback? onRetry;

  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: AppColors.textTertiary, size: 48),
              const SizedBox(height: AppSpacing.lg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13, height: 1.5),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: AppSpacing.xl),
                OutlinedButton(onPressed: onRetry, child: const Text('Reload')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const ErrorView({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: Icons.wifi_off,
      title: 'Cannot reach the MovieServer',
      hint: message,
      onRetry: onRetry,
    );
  }
}
