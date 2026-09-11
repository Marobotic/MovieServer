import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/poster_card.dart';
import 'watch.dart';

class MovieDetailScreen extends StatefulWidget {
  final int movieId;

  const MovieDetailScreen({super.key, required this.movieId});

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  late Future<Movie> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<Api>().movie(widget.movieId);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<Movie>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFE50914)),
            );
          }
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          final m = snap.data!;
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 300,
                pinned: true,
                backgroundColor: const Color(0xFF141414),
                flexibleSpace: FlexibleSpaceBar(
                  background: BackdropImage(url: m.backdrop, title: m.title),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(
                              m.title,
                              style: const TextStyle(
                                  fontSize: 26, fontWeight: FontWeight.w800),
                            ),
                          ),
                          if (m.year > 0)
                            Text('${m.year}',
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 18)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () => _play(m),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Play',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700, fontSize: 16)),
                            ),
                          ),
                          if (m.trailerUrl.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _openTrailer(m.trailerUrl),
                                icon: const Icon(Icons.movie_outlined),
                                label: const Text('Trailer'),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (m.overview.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(m.overview,
                            style: const TextStyle(
                                color: Colors.white70, height: 1.4)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _play(Movie m) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WatchScreen(
          item: PlayableItem(
            mediaKind: 'movie',
            mediaId: m.id,
            title: m.title,
          ),
        ),
      ),
    );
  }

  void _openTrailer(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return;
    }
  }
}