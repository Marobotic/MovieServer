import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import '../widgets/media_card.dart';
import '../widgets/state_views.dart';
import 'detail_nav.dart';

enum MediaKind { movies, shows }

enum _Sort { title, recent, year }

/// Full-library grid for one media kind. The column count follows the window
/// width, so a desktop window shows a dense wall of posters instead of the
/// phone-sized row the app used to reuse everywhere.
class BrowseTab extends StatefulWidget {
  final MediaKind kind;

  const BrowseTab({super.key, required this.kind});

  @override
  State<BrowseTab> createState() => _BrowseTabState();
}

class _BrowseTabState extends State<BrowseTab>
    with AutomaticKeepAliveClientMixin {
  late Future<List<dynamic>> _future;
  _Sort _sort = _Sort.title;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<dynamic>> _load() {
    final api = context.read<Api>();
    return widget.kind == MediaKind.movies ? api.movies() : api.shows();
  }

  void _reload() => setState(() => _future = _load());

  String _titleOf(dynamic e) => e is Movie ? e.title : (e as Show).title;
  int _yearOf(dynamic e) => e is Movie ? e.year : (e as Show).year;
  DateTime? _addedOf(dynamic e) => e is Movie ? e.addedAt : (e as Show).addedAt;
  String _posterOf(dynamic e) => e is Movie ? e.poster : (e as Show).poster;
  /// Only movies carry this flag; for a series the work is per episode, so
  /// the badge lives on the episode rows in the show's page.
  bool _needsPrep(dynamic e) => e is Movie && e.needsPrep;

  List<dynamic> _sorted(List<dynamic> items) {
    final out = [...items];
    switch (_sort) {
      case _Sort.title:
        out.sort((a, b) =>
            _titleOf(a).toLowerCase().compareTo(_titleOf(b).toLowerCase()));
      case _Sort.recent:
        out.sort((a, b) => (_addedOf(b) ?? DateTime(0))
            .compareTo(_addedOf(a) ?? DateTime(0)));
      case _Sort.year:
        out.sort((a, b) => _yearOf(b).compareTo(_yearOf(a)));
    }
    return out;
  }

  void _open(dynamic e) {
    if (e is Movie) {
      openMovieDetail(context, e.id);
    } else {
      openShowDetail(context, (e as Show).id);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final size = Breakpoints.of(context);
    final isMovies = widget.kind == MediaKind.movies;

    return FutureBuilder<List<dynamic>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const LoadingView();
        }
        if (snap.hasError) {
          return ErrorView(message: '${snap.error}', onRetry: _reload);
        }
        final items = _sorted(snap.data ?? const []);
        if (items.isEmpty) {
          return EmptyView(
            icon: isMovies ? Icons.movie_outlined : Icons.live_tv_outlined,
            title: isMovies ? 'No movies yet' : 'No TV shows yet',
            hint: 'Drop files in ~/Documents/MovieServer/'
                '${isMovies ? 'Movies' : 'Shows'}, then run '
                '"Scan library" in Admin.',
            onRetry: _reload,
          );
        }

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  size.gutter,
                  size.hasTopNav ? 96 : AppSpacing.lg,
                  size.gutter,
                  AppSpacing.lg,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        isMovies ? 'Movies' : 'TV Shows',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: size.isDesktop ? 32 : 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _sortMenu(),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  size.gutter, 0, size.gutter, AppSpacing.xxxl),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: size.posterWidth,
                  childAspectRatio: 2 / 3,
                  crossAxisSpacing: AppSpacing.md,
                  mainAxisSpacing: AppSpacing.xl,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final e = items[i];
                    final year = _yearOf(e);
                    return PosterCard(
                      url: _posterOf(e),
                      title: _titleOf(e),
                      subtitle: year > 0 ? '$year' : null,
                      badge: _needsPrep(e) ? 'Unprocessed' : null,
                      width: double.infinity,
                      onTap: () => _open(e),
                    );
                  },
                  childCount: items.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sortMenu() {
    const labels = {
      _Sort.title: 'A-Z',
      _Sort.recent: 'Recently added',
      _Sort.year: 'Newest first',
    };
    return PopupMenuButton<_Sort>(
      initialValue: _sort,
      tooltip: 'Sort',
      color: AppColors.surface,
      position: PopupMenuPosition.under,
      onSelected: (v) => setState(() => _sort = v),
      itemBuilder: (_) => [
        for (final e in labels.entries)
          PopupMenuItem(value: e.key, height: 40, child: Text(e.value)),
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
            Text(labels[_sort]!,
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
