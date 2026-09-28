import 'package:flutter/material.dart';

import '../../theme/breakpoints.dart';
import '../../theme/tokens.dart';
import '../../widgets/seek_bar.dart';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Gradient title bar over the top of the video.
class PlayerTopBar extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const PlayerTopBar({super.key, required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.sm, AppSpacing.xl, size.gutter, AppSpacing.xl),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.scrim, Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              color: AppColors.textPrimary,
              iconSize: 28,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back',
              onPressed: onBack,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: size.isCompact ? 16 : 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Seek bar plus the transport row along the bottom of the video.
class PlayerBottomBar extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final Duration buffered;
  final String? trickplayUrl;
  final String? token;
  final bool playing;
  final bool hasSubtitles;
  final bool subtitlesOn;
  final bool menuOpen;
  final bool fullscreen;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onTogglePlay;
  final VoidCallback onSkipBack;
  final VoidCallback onSkipForward;
  final VoidCallback onToggleMenu;
  final VoidCallback onToggleFullscreen;
  final VoidCallback? onNextEpisode;

  const PlayerBottomBar({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.trickplayUrl,
    required this.token,
    required this.playing,
    required this.hasSubtitles,
    required this.subtitlesOn,
    required this.menuOpen,
    required this.fullscreen,
    required this.onSeek,
    required this.onTogglePlay,
    required this.onSkipBack,
    required this.onSkipForward,
    required this.onToggleMenu,
    required this.onToggleFullscreen,
    this.onNextEpisode,
  });

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final compact = size.isCompact;

    return Container(
      padding: EdgeInsets.fromLTRB(
          size.gutter, AppSpacing.xl, size.gutter, AppSpacing.lg),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [AppColors.scrim, Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SeekBar(
              position: position,
              duration: duration,
              buffered: buffered,
              trickplayUrl: trickplayUrl,
              token: token,
              onSeek: onSeek,
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                _btn(
                  icon: playing
                      ? Icons.pause
                      : Icons.play_arrow,
                  size: 34,
                  tooltip: playing ? 'Pause (space)' : 'Play (space)',
                  onTap: onTogglePlay,
                ),
                _btn(
                  icon: Icons.replay_10,
                  tooltip: 'Back 10s',
                  onTap: onSkipBack,
                ),
                _btn(
                  icon: Icons.forward_10,
                  tooltip: 'Forward 10s',
                  onTap: onSkipForward,
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  '${formatDuration(position)} / ${formatDuration(duration)}',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                if (onNextEpisode != null && !compact)
                  TextButton.icon(
                    onPressed: onNextEpisode,
                    icon: const Icon(Icons.skip_next, size: 20),
                    label: const Text('Next episode'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                    ),
                  ),
                _btn(
                  icon: Icons.subtitles_outlined,
                  tooltip: 'Audio & subtitles',
                  active: menuOpen || subtitlesOn,
                  onTap: hasSubtitles ? onToggleMenu : null,
                ),
                _btn(
                  icon: fullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  tooltip: 'Fullscreen (f)',
                  onTap: onToggleFullscreen,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    double size = 26,
    bool active = false,
  }) {
    return IconButton(
      icon: Icon(icon),
      iconSize: size,
      tooltip: tooltip,
      onPressed: onTap,
      color: active ? AppColors.red : AppColors.textPrimary,
      disabledColor: AppColors.textTertiary,
    );
  }
}
