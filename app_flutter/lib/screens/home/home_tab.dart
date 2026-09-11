import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart';
import '../../models.dart';
import '../../widgets/poster_card.dart';
import '../movie_detail.dart';
import '../show_detail.dart';

enum _MediaTab { movies, shows }

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  late Future<_HomeData> _future;
  _MediaTab _tab = _MediaTab.movies;

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

  void _reload() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFFE50914)),
          );
        }
        if (snap.hasError) {
          return _ErrorView(message: '${snap.error}', onRetry: _reload);
        }
        final data = snap.data!;
        return CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: const Color(0xFF141414),
              title: const Text('MOVIESERVER',
                  style: TextStyle(
                    color: Color(0xFFE50914),
                    fontWeight: FontWeight.w900,
                    fontSize: 24,
                    letterSpacing: 1.2,
                  )),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _reload,
                  tooltip: 'Reload',
                ),
              ],
            ),
            if (data.continueWatching.isNotEmpty)
              SliverToBoxAdapter(
                child: _MediaRow(
                  'Continue watching',
                  children: [
                    for (final item in data.continueWatching)
                      _ContinueCard(item: item),
                  ],
                ),
              ),
            SliverToBoxAdapter(
              child: _TabHeader(
                active: _tab,
                onChanged: (t) => setState(() => _tab = t),
              ),
            ),
            if (_tab == _MediaTab.movies &&
                data.movies.isNotEmpty)
              SliverToBoxAdapter(
                child: _MediaRow(
                  'Movies',
                  children: [
                    for (final m in data.movies)
                      PosterCard(
                        url: m.poster,
                        title: m.title,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  MovieDetailScreen(movieId: m.id)),
                        ),
                      ),
                  ],
                ),
              ),
            if (_tab == _MediaTab.movies && data.movies.isEmpty)
              const SliverToBoxAdapter(
                child: _EmptySection(
                    message: 'No movies yet.',
                    hint: 'Drop files in ~/Documents/MovieServer/Movies, '
                        'then run "Scan library" in Admin.'),
              ),
            if (_tab == _MediaTab.shows &&
                data.shows.isNotEmpty)
              SliverToBoxAdapter(
                child: _MediaRow(
                  'TV Shows',
                  children: [
                    for (final sh in data.shows)
                      PosterCard(
                        url: sh.poster,
                        title: sh.title,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  ShowDetailScreen(showId: sh.id)),
                        ),
                      ),
                  ],
                ),
              ),
            if (_tab == _MediaTab.shows && data.shows.isEmpty)
              const SliverToBoxAdapter(
                child: _EmptySection(
                    message: 'No TV shows yet.',
                    hint: 'Drop files in ~/Documents/MovieServer/Shows, '
                        'then run "Scan library" in Admin.'),
              ),
            if (data.movies.isEmpty && data.shows.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Your library is empty.',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 18)),
                      const SizedBox(height: 8),
                      const Text(
                          'Put files in ~/Documents/MovieServer/Movies and '
                          '/Shows, then run "Scan library" in Admin.',
                          style: TextStyle(color: Colors.white38),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _reload,
                        child: const Text('Reload'),
                      ),
                    ],
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

class _TabHeader extends StatelessWidget {
  final _MediaTab active;
  final ValueChanged<_MediaTab> onChanged;

  const _TabHeader({required this.active, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Row(
        children: [
          _tabButton(_MediaTab.movies, 'Movies'),
          const SizedBox(width: 8),
          _tabButton(_MediaTab.shows, 'TV Shows'),
        ],
      ),
    );
  }

  Widget _tabButton(_MediaTab t, String label) {
    final selected = active == t;
    return InkWell(
      onTap: () => onChanged(t),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE50914) : Colors.transparent,
          border: Border.all(
              color: selected ? const Color(0xFFE50914) : Colors.white24),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

class _EmptySection extends StatelessWidget {
  final String message;
  final String hint;

  const _EmptySection({required this.message, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(hint, style: const TextStyle(color: Colors.white38)),
        ],
      ),
    );
  }
}

class _MediaRow extends StatefulWidget {
  final String title;
  final List<Widget> children;

  const _MediaRow(this.title, {required this.children});

  @override
  State<_MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<_MediaRow> {
  final ScrollController _controller = ScrollController();
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateArrows);
  }

  @override
  void didUpdateWidget(covariant _MediaRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!_controller.hasClients) {
      if (_canLeft || _canRight) {
        setState(() {
          _canLeft = false;
          _canRight = false;
        });
      }
      return;
    }
    final position = _controller.position;
    final left = position.pixels > 4;
    final right = position.pixels < position.maxScrollExtent - 4;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _scrollBy(double dir) {
    _controller.animateTo(
      _controller.offset +
          dir * _controller.position.viewportDimension * 0.85,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _arrow(bool left) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: left ? 0 : null,
      right: left ? null : 0,
      child: Center(
        child: Material(
          color: const Color(0xB3000000),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => _scrollBy(left ? -1 : 1),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                left ? Icons.chevron_left : Icons.chevron_right,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(widget.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
        ),
        SizedBox(
          height: 190,
          child: Stack(
            children: [
              ListView.builder(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: widget.children.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: widget.children[i],
                ),
              ),
              if (_canLeft) _arrow(true),
              if (_canRight) _arrow(false),
            ],
          ),
        ),
      ],
    );
  }
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
}

class _ContinueCard extends StatelessWidget {
  final ContinueItem item;

  const _ContinueCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final api = context.watch<Api>();
    final url = api.assetUrl(item.poster);
    return InkWell(
      onTap: () {
        if (item.mediaKind == 'movie') {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MovieDetailScreen(movieId: item.mediaId)));
        } else {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ShowDetailScreen(showId: item.showId)));
        }
      },
      child: SizedBox(
        width: 200,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: url.isEmpty
                        ? Container(
                            color: const Color(0xFF262626),
                            child: const Icon(Icons.play_circle_outline,
                                color: Colors.white38, size: 40),
                          )
                        : Image.network(url,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox()),
                  ),
                  if (item.duration > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: (item.position / item.duration).clamp(0.0, 1.0),
                        color: const Color(0xFFE50914),
                        backgroundColor: Colors.white24,
                        minHeight: 3,
                      ),
                    ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xAA000000),
                      ),
                      child: const Icon(Icons.play_arrow, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off, color: Colors.white38, size: 48),
            const SizedBox(height: 12),
            const Text('Cannot reach the MovieServer',
                style: TextStyle(color: Colors.white, fontSize: 18)),
            const SizedBox(height: 6),
            Text(message,
                style: const TextStyle(color: Colors.white54),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}