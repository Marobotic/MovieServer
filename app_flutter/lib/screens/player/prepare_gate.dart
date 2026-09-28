import 'package:flutter/material.dart';

import '../../models.dart';
import '../../theme/tokens.dart';

/// Shared card chrome for the "this file needs work before it can play"
/// states that sit on top of the video surface.
class _GateCard extends StatelessWidget {
  final Widget child;
  final Color borderColor;

  const _GateCard({required this.child, this.borderColor = AppColors.border});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.all(AppSpacing.xl),
        padding: const EdgeInsets.all(AppSpacing.xxl),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.modal),
          border: Border.all(color: borderColor),
          boxShadow: AppShadows.card,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [child]),
      ),
    );
  }
}

/// Offered when the server says the file must be remuxed or re-encoded before
/// this client can play it.
class PreparePrompt extends StatelessWidget {
  final PlaybackDecision decision;
  final String fallbackTitle;
  final bool isAdmin;
  final void Function(String mode) onPrepare;
  final VoidCallback onCancel;

  const PreparePrompt({
    super.key,
    required this.decision,
    required this.fallbackTitle,
    required this.isAdmin,
    required this.onPrepare,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final est = decision.estimate;
    final worker = est?.worker == 'gpu' ? 'GPU encode' : 'one CPU core';
    final estimate = est != null
        ? 'About ${est.minutes} min, $worker'
            '${est.sizeGB != null ? ', ~${est.sizeGB} GB' : ''}'
        : '';

    return _GateCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_fix_high, color: AppColors.red, size: 44),
          const SizedBox(height: AppSpacing.lg),
          Text(
            decision.title.isNotEmpty ? decision.title : fallbackTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            decision.reason.isNotEmpty
                ? decision.reason
                : 'Needs preparation for browser playback.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 14, height: 1.5),
          ),
          if (estimate.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(estimate,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textTertiary, fontSize: 13)),
          ],
          const SizedBox(height: AppSpacing.xl),
          if (isAdmin)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Prepare now'),
                  onPressed: () => onPrepare('now'),
                ),
                OutlinedButton(
                  onPressed: () => onPrepare('idle'),
                  child: const Text('Tonight'),
                ),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
              ],
            )
          else
            Column(
              children: [
                const Text(
                  'Not ready for this device yet. The server admin has been '
                  'asked to prepare it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      height: 1.5),
                ),
                const SizedBox(height: AppSpacing.lg),
                ElevatedButton(
                    onPressed: onCancel, child: const Text('Back')),
              ],
            ),
        ],
      ),
    );
  }
}

/// Live progress while a prepare job runs (or waits behind another one).
class PrepareProgress extends StatelessWidget {
  final PlaybackJobBrief job;
  final PlaybackJobBrief? queueLeader;
  final int queuePos;
  final String fallbackTitle;
  final bool isAdmin;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;
  final VoidCallback onClose;

  const PrepareProgress({
    super.key,
    required this.job,
    required this.queueLeader,
    required this.queuePos,
    required this.fallbackTitle,
    required this.isAdmin,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final statusText = switch (job.status) {
      'running' => 'Preparing for web (${job.worker.toUpperCase()})...',
      'paused_gaming' => 'Paused while you\'re gaming',
      'paused' => 'Paused',
      'queued' => 'Queued...',
      'done' => 'Ready to play',
      'failed' => 'Failed: ${job.error}',
      _ => job.status,
    };

    final isGaming = job.status == 'paused_gaming';
    final accent = isGaming ? AppColors.warning : AppColors.red;
    final queuedBehind = job.isQueued && queueLeader != null && queuePos > 1;

    // Percent/speed/ETA come from whichever job is actually burning CPU: this
    // item's own job when running, or the one ahead of it in the queue.
    final live = queuedBehind ? queueLeader! : job;

    return _GateCard(
      borderColor: isGaming ? AppColors.warning : AppColors.border,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(isGaming ? Icons.sports_esports : Icons.hourglass_top,
                  color: accent, size: 26),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  job.title.isNotEmpty ? job.title : fallbackTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Text(
                  '${live.percent.toStringAsFixed(1)}%',
                  style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w700,
                      fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: LinearProgressIndicator(
              value: (live.percent / 100).clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppColors.border,
              color: accent,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(statusText,
                    style: TextStyle(
                        color: isGaming
                            ? AppColors.warning
                            : AppColors.textSecondary,
                        fontSize: 13)),
              ),
              Text(
                [
                  if (live.speed > 0) '${live.speed.toStringAsFixed(1)}x',
                  if (live.etaSec > 0) '${(live.etaSec / 60).ceil()}m left',
                ].join('  ·  '),
                style: const TextStyle(
                    color: AppColors.textTertiary, fontSize: 12),
              ),
            ],
          ),
          if (queuedBehind) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'You are #$queuePos in line. Preparing '
              '${queueLeader!.title.isEmpty ? 'another item' : queueLeader!.title} first...',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppColors.textTertiary, fontSize: 12),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              if (isAdmin) ...[
                if (job.isRunning)
                  OutlinedButton(
                      onPressed: onPause, child: const Text('Pause'))
                else if (job.isPaused)
                  OutlinedButton(
                      onPressed: onResume, child: const Text('Resume')),
                const SizedBox(width: AppSpacing.sm),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
              ],
              const Spacer(),
              ElevatedButton(onPressed: onClose, child: const Text('Close')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Terminal failure: damaged file, still copying, or a preflight error.
class PlaybackError extends StatelessWidget {
  final String message;
  final VoidCallback onBack;

  const PlaybackError({
    super.key,
    required this.message,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return _GateCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.highlight_off, color: AppColors.red, size: 48),
          const SizedBox(height: AppSpacing.lg),
          const Text('Cannot play',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.sm),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 14, height: 1.5)),
          const SizedBox(height: AppSpacing.xl),
          ElevatedButton(onPressed: onBack, child: const Text('Back')),
        ],
      ),
    );
  }
}
