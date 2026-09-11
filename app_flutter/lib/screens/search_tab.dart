import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import 'movie_detail.dart';
import 'show_detail.dart';

class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _q = TextEditingController();
  List<Movie> _movies = [];
  List<Show> _shows = [];
  bool _loading = false;
  bool _searched = false;

  Future<void> _search(String q) async {
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      final res = await context.read<Api>().search(q);
      setState(() {
        _movies = res.movies;
        _shows = res.shows;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        const SizedBox(height: 16),
        TextField(
          controller: _q,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: 'Search movies and shows',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _q.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _q.clear();
                      setState(() {
                        _movies = [];
                        _shows = [];
                        _searched = false;
                      });
                    },
                  ),
          ),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
                child: CircularProgressIndicator(color: Color(0xFFE50914))),
          )
        else if (!_searched)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: Text('Type something to search your library',
                  style: TextStyle(color: Colors.white54)),
            ),
          )
        else if (_movies.isEmpty && _shows.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(48),
              child: Text('No results',
                  style: TextStyle(color: Colors.white54)),
            ),
          )
        else ...[
          for (final m in _movies)
            _ResultTile(
              title: m.title,
              subtitle: m.year > 0 ? '${m.year} - Movie' : 'Movie',
              poster: m.poster,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => MovieDetailScreen(movieId: m.id))),
            ),
          for (final sh in _shows)
            _ResultTile(
              title: sh.title,
              subtitle: sh.year > 0 ? '${sh.year} - TV Show' : 'TV Show',
              poster: sh.poster,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ShowDetailScreen(showId: sh.id))),
            ),
        ],
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String poster;
  final VoidCallback onTap;

  const _ResultTile({
    required this.title,
    required this.subtitle,
    required this.poster,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final api = context.read<Api>();
    final url = api.assetUrl(poster);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 56,
          height: 80,
          child: url.isEmpty
              ? Container(color: const Color(0xFF262626))
              : Image.network(url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(color: const Color(0xFF262626))),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}