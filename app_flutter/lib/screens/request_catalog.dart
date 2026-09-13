import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';

class RequestCatalog extends StatefulWidget {
  const RequestCatalog({super.key});

  @override
  State<RequestCatalog> createState() => _RequestCatalogState();
}

class _RequestCatalogState extends State<RequestCatalog> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final Set<int> _requested = {};
  List<TMDbHit> _items = [];
  String _type = 'movie';
  String _category = 'popular';
  String _query = '';
  int _page = 0;
  int _totalPages = 1;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadMoreIfNeeded);
    _loadRequested();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadRequested() async {
    try {
      final requests = await context.read<Api>().requests();
      if (mounted) {
        setState(() => _requested
          ..clear()
          ..addAll(requests.where((r) => r.tmdbId > 0).map((r) => r.tmdbId)));
      }
    } catch (_) {}
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 0;
      _items = [];
    });
    await _loadPage(1);
  }

  Future<void> _loadPage(int page) async {
    try {
      final result = await context.read<Api>().catalog(
            type: _type,
            category: _category,
            query: _query,
            page: page,
          );
      if (!mounted) return;
      setState(() {
        _page = result.page;
        _totalPages = result.totalPages;
        if (page == 1) {
          _items = result.results;
        } else {
          _items.addAll(result.results);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _loadMoreIfNeeded() {
    if (_loading || _loadingMore || _page >= _totalPages) return;
    if (_scroll.position.extentAfter > 500) return;
    setState(() => _loadingMore = true);
    _loadPage(_page + 1);
  }

  void _setType(String type) {
    if (_type == type) return;
    setState(() {
      _type = type;
      _category = 'popular';
      _query = '';
      _search.clear();
    });
    _reload();
  }

  Future<void> _open(TMDbHit item) async {
    final detail =
        await context.read<Api>().catalogDetail(item.type, item.tmdbId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CatalogDetail(
        item: detail,
        requested: _requested.contains(detail.tmdbId),
        onRequest: () => _request(detail),
      ),
    );
  }

  Future<void> _request(TMDbHit item) async {
    if (_requested.contains(item.tmdbId)) return;
    try {
      await context.read<Api>().createRequest(
            item.type,
            item.title,
            item.year,
            '',
            item.tmdbId,
          );
      if (!mounted) return;
      setState(() => _requested.add(item.tmdbId));
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${item.title} was added to your requests.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tmdbReady = context.watch<AppSession>().tmdbConfigured;
    if (!tmdbReady) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('The catalog needs TMDB to be configured by the admin.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54)),
        ),
      );
    }
    final categories = _type == 'movie'
        ? const {
            'popular': 'Popular',
            'top_rated': 'Top rated',
            'now_playing': 'In theaters',
            'upcoming': 'Upcoming'
          }
        : const {
            'popular': 'Popular',
            'top_rated': 'Top rated',
            'airing_today': 'Airing today',
            'on_the_air': 'On the air'
          };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) {
              _query = value.trim();
              _reload();
            },
            decoration: InputDecoration(
              hintText: 'Search movies and TV shows',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        _query = '';
                        _reload();
                      },
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'movie',
                  icon: Icon(Icons.movie),
                  label: Text('Movies')),
              ButtonSegment(
                  value: 'show', icon: Icon(Icons.tv), label: Text('TV shows')),
            ],
            selected: {_type},
            onSelectionChanged: (values) => _setType(values.first),
          ),
        ),
        SizedBox(
          height: 54,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            children: categories.entries
                .map((entry) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(entry.value),
                        selected: _query.isEmpty && _category == entry.key,
                        onSelected: (_) {
                          _search.clear();
                          _query = '';
                          _category = entry.key;
                          _reload();
                        },
                      ),
                    ))
                .toList(),
          ),
        ),
        Expanded(child: _buildResults()),
      ],
    );
  }

  Widget _buildResults() {
    if (_loading && _items.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFE50914)));
    }
    if (_error != null && _items.isEmpty) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }
    if (_items.isEmpty) {
      return const Center(
          child: Text('No titles found.',
              style: TextStyle(color: Colors.white54)));
    }
    return LayoutBuilder(builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1000
          ? 6
          : constraints.maxWidth >= 650
              ? 4
              : 3;
      return GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          childAspectRatio: .58,
          crossAxisSpacing: 12,
          mainAxisSpacing: 14,
        ),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _items.length) {
            return const Center(child: CircularProgressIndicator());
          }
          final item = _items[index];
          return _CatalogCard(
              item: item,
              requested: _requested.contains(item.tmdbId),
              onTap: () => _open(item));
        },
      );
    });
  }
}

class _CatalogCard extends StatelessWidget {
  final TMDbHit item;
  final bool requested;
  final VoidCallback onTap;

  const _CatalogCard(
      {required this.item, required this.requested, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: item.poster.isEmpty
                      ? Container(
                          color: const Color(0xFF292929),
                          child: const Icon(Icons.movie, size: 42))
                      : Image.network(item.poster, fit: BoxFit.cover),
                ),
                if (requested)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      color: const Color(0xFFE50914),
                      child: const Text('REQUESTED',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          Text(item.year > 0 ? '${item.year}' : 'Coming soon',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}

class _CatalogDetail extends StatelessWidget {
  final TMDbHit item;
  final bool requested;
  final VoidCallback onRequest;

  const _CatalogDetail(
      {required this.item, required this.requested, required this.onRequest});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: .78,
      minChildSize: .5,
      maxChildSize: .95,
      builder: (context, controller) => Container(
        decoration: const BoxDecoration(
            color: Color(0xFF181818),
            borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            if (item.backdrop.isNotEmpty)
              AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(item.backdrop, fit: BoxFit.cover)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Text(item.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 25,
                      fontWeight: FontWeight.bold)),
            ),
            Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
                child: Text(
                    '${item.type == 'show' ? 'TV show' : 'Movie'}${item.year > 0 ? ' • ${item.year}' : ''}',
                    style: const TextStyle(color: Colors.white54))),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                    item.overview.isEmpty
                        ? 'No overview available.'
                        : item.overview,
                    style:
                        const TextStyle(color: Colors.white70, height: 1.35))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  ElevatedButton.icon(
                    onPressed: requested ? null : onRequest,
                    icon: Icon(requested ? Icons.check : Icons.playlist_add),
                    label: Text(requested ? 'Requested' : 'Request this title'),
                  ),
                  if (item.trailerUrl.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(Uri.parse(item.trailerUrl),
                          mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.play_circle_outline),
                      label: const Text('Trailer'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
