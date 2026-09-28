import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import '../widgets/detail_scaffold.dart';
import '../widgets/media_card.dart';
import '../widgets/state_views.dart';
import 'watch.dart';

class ShowDetailScreen extends StatefulWidget {
  final int showId;
  final bool modal;

  const ShowDetailScreen({
    super.key,
    required this.showId,
    this.modal = false,
  });

  @override
  State<ShowDetailScreen> createState() => _ShowDetailScreenState();
}

class _ShowDetailScreenState extends State<ShowDetailScreen> {
  late Future<ShowDetail> _future;
  int? _season;

  @override
  void initState() {
    super.initState();
    _future = context.read<Api>().showDetail(widget.showId);
  }

  void _reload() => setState(
      () => _future = context.read<Api>().showDetail(widget.showId));

  Future<void> _playEpisode(Show sh, Episode e) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WatchScreen(
          item: PlayableItem(
            mediaKind: 'episode',
            mediaId: e.id,
            title: '${sh.title} '
                'S${e.season.toString().padLeft(2, '0')}'
                'E${e.episode.toString().padLeft(2, '0')}',
            showId: sh.id,
            season: e.season,
            episode: e.episode,
          ),
        ),
      ),
    );
    _reload();
  }

  /// First unfinished episode, so the header Play button resumes the show.
  Episode? _nextUp(List<Episode> eps) {
    final ordered = [...eps]..sort((a, b) => a.season != b.season
        ? a.season.compareTo(b.season)
        : a.episode.compareTo(b.episode));
    for (final e in ordered) {
      if (!e.completed) return e;
    }
    return ordered.isEmpty ? null : ordered.first;
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);

    return FutureBuilder<ShowDetail>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _wrap(const LoadingView());
        }
        if (snap.hasError) {
          return _wrap(ErrorView(message: '${snap.error}', onRetry: _reload));
        }
        final detail = snap.data!;
        final sh = detail.show;
        final seasons = detail.episodes.map((e) => e.season).toSet().toList()
          ..sort();
        final season = _season != null && seasons.contains(_season)
            ? _season!
            : (seasons.isNotEmpty ? seasons.first : 1);
        final eps = detail.episodes.where((e) => e.season == season).toList()
          ..sort((a, b) => a.episode.compareTo(b.episode));
        final next = _nextUp(detail.episodes);

        final meta = [
          if (sh.year > 0) '${sh.year}',
          if (seasons.isNotEmpty)
            '${seasons.length} season${seasons.length == 1 ? '' : 's'}',
          'Series',
        ].join('  •  ');

        return DetailScaffold(
          modal: widget.modal,
          backdropUrl: sh.backdrop.isNotEmpty ? sh.backdrop : sh.poster,
          title: sh.title,
          header: DetailHeader(
            title: sh.title,
            meta: meta,
            actions: [
              if (next != null)
                FilledButton.icon(
                  onPressed: () => _playEpisode(sh, next),
                  icon: const Icon(Icons.play_arrow, size: 24),
                  label: Text(
                    next.positionSec > 0 ? 'Resume' : 'Play',
                  ),
                ),
              if (next != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    'S${next.season.toString().padLeft(2, '0')}'
                    'E${next.episode.toString().padLeft(2, '0')}'
                    '${next.title.isNotEmpty ? '  ${next.title}' : ''}',
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13),
                  ),
                ),
            ],
          ),
          children: [
            if (sh.overview.isNotEmpty) ...[
              Text(
                sh.overview,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 15, height: 1.6),
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
            Row(
              children: [
                Text(
                  'Episodes',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: size.isCompact ? 18 : 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (seasons.length > 1) _seasonMenu(seasons, season),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            if (eps.isEmpty)
              const Text(
                'No episodes found for this season.',
                style: TextStyle(color: AppColors.textTertiary),
              )
            else
              for (final e in eps)
                _EpisodeRow(
                  ep: e,
                  onPlay: () => _playEpisode(sh, e),
                ),
          ],
        );
      },
    );
  }

  Widget _wrap(Widget child) {
    if (!widget.modal) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: child,
      );
    }
    return Center(
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.modal),
        child: SizedBox(width: 480, height: 280, child: child),
      ),
    );
  }

  Widget _seasonMenu(List<int> seasons, int current) {
    return PopupMenuButton<int>(
      initialValue: current,
      tooltip: 'Season',
      color: AppColors.surfaceHigher,
      position: PopupMenuPosition.under,
      onSelected: (v) => setState(() => _season = v),
      itemBuilder: (_) => [
        for (final s in seasons)
          PopupMenuItem(value: s, height: 40, child: Text('Season $s')),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderStrong),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Season $current',
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 13)),
            const SizedBox(width: AppSpacing.xs),
            const Icon(Icons.arrow_drop_down,
                size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _EpisodeRow extends StatefulWidget {
  final Episode ep;
  final VoidCallback onPlay;

  const _EpisodeRow({required this.ep, required this.onPlay});

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.ep;
    final size = Breakpoints.of(context);
    final api = context.read<Api>();
    final still = api.assetUrl(e.still);
    final progress = e.durationSec > 0 && e.positionSec > 0
        ? (e.positionSec / e.durationSec).clamp(0.0, 1.0)
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onPlay,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: _hover ? AppColors.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.panel),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 38,
                child: Text(
                  '${e.episode}',
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: SizedBox(
                  width: size.isCompact ? 110 : 150,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (still.isEmpty)
                          const ColoredBox(color: AppColors.surfaceHigh)
                        else
                          Image.network(still,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const ColoredBox(
                                  color: AppColors.surfaceHigh)),
                        AnimatedOpacity(
                          opacity: _hover ? 1 : 0,
                          duration: AppMotion.fast,
                          child: Container(
                            color: AppColors.black.withOpacity(0.4),
                            alignment: Alignment.center,
                            child: const Icon(Icons.play_circle_fill,
                                color: AppColors.textPrimary, size: 32),
                          ),
                        ),
                        if (e.needsPrep)
                          const Positioned(
                            left: 4,
                            top: 4,
                            child: MediaBadge(label: 'Unprocessed'),
                          )
                        else if (e.completed)
                          const Positioned(
                            right: 4,
                            top: 4,
                            child: Icon(Icons.check_circle,
                                color: AppColors.success, size: 18),
                          ),
                        if (progress != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: progress,
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
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            e.title.isNotEmpty
                                ? e.title
                                : 'Episode ${e.episode}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15),
                          ),
                        ),
                        if (e.needsPrep)
                          const Padding(
                            padding: EdgeInsets.only(right: AppSpacing.sm),
                            child: Text(
                              'Needs preparing',
                              style: TextStyle(
                                  color: AppColors.warning, fontSize: 12),
                            ),
                          ),
                        if (e.durationSec > 0)
                          Text(
                            '${(e.durationSec / 60).round()}m',
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 13),
                          ),
                      ],
                    ),
                    if (e.overview.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        e.overview,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.45),
                      ),
                    ],
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
