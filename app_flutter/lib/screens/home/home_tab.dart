import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../models.dart';
import '../../theme/breakpoints.dart';
import '../../theme/tokens.dart';
import '../../widgets/hero_billboard.dart';
import '../../widgets/media_card.dart';
import '../../widgets/media_row.dart';
import '../../widgets/state_views.dart';
import '../browse_tab.dart';
import '../detail_nav.dart';
import '../watch.dart';

class HomeTab extends StatefulWidget {
  final void Function(MediaKind kind) onSeeAll;

  const HomeTab({super.key, required this.onSeeAll});

  @override
  State<HomeTab> createState() => HomeTabState();
}

class HomeTabState extends State<HomeTab> with AutomaticKeepAliveClientMixin {
  late Future<_HomeData> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_HomeData> _load() async {
    final api = context.read<Api>();
    final results = await Future.wait([
      api.continueWatching(),
      api.movies(),
      api.shows(),
    ]);
    return _HomeData(
      continueWatching: results[0] as List<ContinueItem>,
      movies: results[1] as List<Movie>,
      shows: results[2] as List<Show>,
    );
  }

  /// Public so the shell can refresh the page after a scan.
  void reload() => setState(() => _future = _load());

  void _openMovie(int id) => openMovieDetail(context, id);

  void _openShow(int id) => openShowDetail(context, id);

  void _playMovie(Movie m) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WatchScreen(
        item: PlayableItem(mediaKind: 'movie', mediaId: m.id, title: m.title),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final size = Breakpoints.of(context);

    return FutureBuilder<_HomeData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const LoadingView();
        }
        if (snap.hasError) {
          return ErrorView(message: '${snap.error}', onRetry: reload);
        }
        final data = snap.data!;
        if (data.movies.isEmpty && data.shows.isEmpty) {
          return EmptyView(
            icon: Icons.video_library_outlined,
            title: 'Your library is empty',
            hint: 'Put files in ~/Documents/MovieServer/Movies and /Shows, '
                'then run "Scan library" in Admin.',
            onRetry: reload,
          );
        }

        final featured = data.featured;
        final posterHeight = size.posterWidth * 1.5;
        final thumbHeight = size.thumbWidth * 9 / 16 + 44;

        return RefreshIndicator(
          onRefresh: () async => reload(),
          color: AppColors.red,
          backgroundColor: AppColors.surface,
          child: CustomScrollView(
            slivers: [
              if (featured != null)
                SliverToBoxAdapter(
                  child: HeroBillboard(
                    title: featured.title,
                    backdropUrl: featured.backdrop.isNotEmpty
                        ? featured.backdrop
                        : featured.poster,
                    overview: featured.overview,
                    meta: featured.meta,
                    onPlay: () {
                      if (featured.movie != null) {
                        _playMovie(featured.movie!);
                      } else {
                        _openShow(featured.showId!);
                      }
                    },
                    onMoreInfo: () {
                      if (featured.movie != null) {
                        _openMovie(featured.movie!.id);
                      } else {
                        _openShow(featured.showId!);
                      }
                    },
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: SizedBox(height: size.hasTopNav ? 88 : AppSpacing.lg),
                ),

              if (data.continueWatching.isNotEmpty)
                SliverToBoxAdapter(
                  child: MediaRow(
                    title: 'Continue Watching',
                    itemCount: data.continueWatching.length,
                    itemHeight: thumbHeight,
                    itemBuilder: (context, i) {
                      final item = data.continueWatching[i];
                      return ThumbCard(
                        url: item.poster,
                        title: item.title,
                        subtitle: item.duration > 0
                            ? '${((item.position / item.duration) * 100).round()}% watched'
                            : null,
                        progress: item.duration > 0
                            ? item.position / item.duration
                            : null,
                        onTap: () => item.mediaKind == 'movie'
                            ? _openMovie(item.mediaId)
                            : _openShow(item.showId),
                      );
                    },
                  ),
                ),

              if (data.recentlyAdded.isNotEmpty)
                SliverToBoxAdapter(
                  child: MediaRow(
                    title: 'Recently Added',
                    itemCount: data.recentlyAdded.length,
                    itemHeight: posterHeight,
                    itemBuilder: (context, i) {
                      final e = data.recentlyAdded[i];
                      return e.movie != null
                          ? PosterCard(
                              url: e.movie!.poster,
                              title: e.movie!.title,
                              subtitle:
                                  e.movie!.year > 0 ? '${e.movie!.year}' : null,
                              badge:
                                  e.movie!.needsPrep ? 'Unprocessed' : null,
                              onTap: () => _openMovie(e.movie!.id),
                            )
                          : PosterCard(
                              url: e.show!.poster,
                              title: e.show!.title,
                              subtitle:
                                  e.show!.year > 0 ? '${e.show!.year}' : null,
                              onTap: () => _openShow(e.show!.id),
                            );
                    },
                  ),
                ),

              if (data.movies.isNotEmpty)
                SliverToBoxAdapter(
                  child: MediaRow(
                    title: 'Movies',
                    itemCount: data.movies.length,
                    itemHeight: posterHeight,
                    onSeeAll: () => widget.onSeeAll(MediaKind.movies),
                    itemBuilder: (context, i) {
                      final m = data.movies[i];
                      return PosterCard(
                        url: m.poster,
                        title: m.title,
                        subtitle: m.year > 0 ? '${m.year}' : null,
                        badge: m.needsPrep ? 'Unprocessed' : null,
                        onTap: () => _openMovie(m.id),
                      );
                    },
                  ),
                ),

              if (data.shows.isNotEmpty)
                SliverToBoxAdapter(
                  child: MediaRow(
                    title: 'TV Shows',
                    itemCount: data.shows.length,
                    itemHeight: posterHeight,
                    onSeeAll: () => widget.onSeeAll(MediaKind.shows),
                    itemBuilder: (context, i) {
                      final sh = data.shows[i];
                      return PosterCard(
                        url: sh.poster,
                        title: sh.title,
                        subtitle: sh.year > 0 ? '${sh.year}' : null,
                        onTap: () => _openShow(sh.id),
                      );
                    },
                  ),
                ),

              const SliverToBoxAdapter(
                  child: SizedBox(height: AppSpacing.xxxl)),
            ],
          ),
        );
      },
    );
  }
}

/// A movie or show, whichever this entry holds.
class _Entry {
  final Movie? movie;
  final Show? show;
  const _Entry.ofMovie(this.movie) : show = null;
  const _Entry.ofShow(this.show) : movie = null;

  DateTime get added =>
      (movie?.addedAt ?? show?.addedAt) ?? DateTime.fromMillisecondsSinceEpoch(0);
}

class _Featured {
  final String title;
  final String backdrop;
  final String poster;
  final String overview;
  final String meta;
  final Movie? movie;
  final int? showId;

  const _Featured({
    required this.title,
    required this.backdrop,
    required this.poster,
    required this.overview,
    required this.meta,
    this.movie,
    this.showId,
  });
}

class _HomeData {
  final List<ContinueItem> continueWatching;
  final List<Movie> movies;
  final List<Show> shows;

  _HomeData({
    required this.continueWatching,
    required this.movies,
    required this.shows,
  });

  /// Newest 20 titles across both kinds.
  late final List<_Entry> recentlyAdded = () {
    final all = <_Entry>[
      for (final m in movies) _Entry.ofMovie(m),
      for (final s in shows) _Entry.ofShow(s),
    ]..sort((a, b) => b.added.compareTo(a.added));
    return all.take(20).toList();
  }();

  /// The billboard title. Prefers something with a backdrop, and stays stable
  /// for the day so the page does not reshuffle on every rebuild.
  late final _Featured? featured = () {
    final candidates = [
      for (final m in movies)
        if (m.backdrop.isNotEmpty) _Entry.ofMovie(m),
      for (final s in shows)
        if (s.backdrop.isNotEmpty) _Entry.ofShow(s),
    ];
    final pool = candidates.isNotEmpty
        ? candidates
        : [
            for (final m in movies) _Entry.ofMovie(m),
            for (final s in shows) _Entry.ofShow(s),
          ];
    if (pool.isEmpty) return null;

    final today = DateTime.now();
    final seed = today.year * 10000 + today.month * 100 + today.day;
    final pick = pool[math.Random(seed).nextInt(pool.length)];

    if (pick.movie != null) {
      final m = pick.movie!;
      return _Featured(
        title: m.title,
        backdrop: m.backdrop,
        poster: m.poster,
        overview: m.overview,
        meta: [
          if (m.year > 0) '${m.year}',
          if (m.durationSec > 0) '${(m.durationSec / 60).round()} min',
          'Movie',
        ].join('  •  '),
        movie: m,
      );
    }
    final s = pick.show!;
    return _Featured(
      title: s.title,
      backdrop: s.backdrop,
      poster: s.poster,
      overview: s.overview,
      meta: [if (s.year > 0) '${s.year}', 'Series'].join('  •  '),
      showId: s.id,
    );
  }();
}
