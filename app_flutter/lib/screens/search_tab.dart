import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import '../widgets/media_card.dart';
import '../widgets/state_views.dart';
import 'detail_nav.dart';

class SearchTab extends StatefulWidget {
  /// Query pushed in from the top-bar search field on desktop.
  final String query;

  const SearchTab({super.key, this.query = ''});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Movie> _movies = [];
  List<Show> _shows = [];
  bool _loading = false;
  bool _searched = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _q.addListener(_onChanged);
    if (widget.query.isNotEmpty) {
      _q.text = widget.query;
      _search(widget.query);
    }
  }

  @override
  void didUpdateWidget(covariant SearchTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != oldWidget.query && widget.query != _q.text) {
      _q.text = widget.query;
      _search(widget.query);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.removeListener(_onChanged);
    _q.dispose();
    super.dispose();
  }

  /// Rebuilds for the clear button and schedules a debounced search; the old
  /// screen only searched on submit and never repainted the suffix icon.
  void _onChanged() {
    setState(() {});
    _debounce?.cancel();
    final q = _q.text.trim();
    if (q.isEmpty) {
      setState(() {
        _movies = [];
        _shows = [];
        _searched = false;
        _error = '';
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
    });
    try {
      final res = await context.read<Api>().search(q.trim());
      if (!mounted) return;
      setState(() {
        _movies = res.movies;
        _shows = res.shows;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final results = <dynamic>[..._movies, ..._shows];

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
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: TextField(
                controller: _q,
                autofocus: size.isCompact,
                textInputAction: TextInputAction.search,
                onSubmitted: _search,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search movies and shows',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _q.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear',
                          onPressed: _q.clear,
                        ),
                ),
              ),
            ),
          ),
        ),
        if (_loading)
          const SliverFillRemaining(
              hasScrollBody: false, child: LoadingView())
        else if (_error.isNotEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorView(
                message: _error, onRetry: () => _search(_q.text)),
          )
        else if (!_searched)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(
              icon: Icons.search,
              title: 'Find something to watch',
              hint: 'Start typing to search titles in your library.',
            ),
          )
        else if (results.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(
              icon: Icons.search_off,
              title: 'No results for "${_q.text.trim()}"',
              hint: 'Try a different spelling, or ask for it in Requests.',
            ),
          )
        else
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
                  final e = results[i];
                  final isMovie = e is Movie;
                  final year = isMovie ? e.year : (e as Show).year;
                  // Series are flagged per episode, not as a whole.
                  final needsPrep = isMovie && e.needsPrep;
                  return PosterCard(
                    url: isMovie ? e.poster : (e as Show).poster,
                    title: isMovie ? e.title : (e as Show).title,
                    badge: needsPrep ? 'Unprocessed' : null,
                    subtitle: [
                      if (year > 0) '$year',
                      isMovie ? 'Movie' : 'Series',
                    ].join(' • '),
                    width: double.infinity,
                    onTap: () => isMovie
                        ? openMovieDetail(context, e.id)
                        : openShowDetail(context, (e as Show).id),
                  );
                },
                childCount: results.length,
              ),
            ),
          ),
      ],
    );
  }
}
