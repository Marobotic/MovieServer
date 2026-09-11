import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../widgets/poster_card.dart';
import 'watch.dart';

class ShowDetailScreen extends StatefulWidget {
  final int showId;

  const ShowDetailScreen({super.key, required this.showId});

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

  void _reload() {
    setState(() => _future = context.read<Api>().showDetail(widget.showId));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<ShowDetail>(
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
          final detail = snap.data!;
          final sh = detail.show;
          final seasons = detail.episodes.map((e) => e.season).toSet().toList()
            ..sort();
          final season = _season != null && seasons.contains(_season)
              ? _season!
              : (seasons.isNotEmpty ? seasons.first : 1);
          final eps = detail.episodes
              .where((e) => e.season == season)
              .toList()
            ..sort((a, b) => a.episode.compareTo(b.episode));

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: CustomScrollView(
              slivers: [
                SliverAppBar(
                  expandedHeight: 280,
                  pinned: true,
                  backgroundColor: const Color(0xFF141414),
                  flexibleSpace: FlexibleSpaceBar(
                    background: BackdropImage(url: sh.backdrop, title: sh.title),
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
                              child: Text(sh.title,
                                  style: const TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.w800)),
                            ),
                            if (sh.year > 0)
                              Text('${sh.year}',
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 18)),
                          ],
                        ),
                        if (sh.overview.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(sh.overview,
                              style: const TextStyle(
                                  color: Colors.white70, height: 1.4)),
                        ],
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final s in seasons)
                              ChoiceChip(
                                label: Text('Season $s'),
                                selected: s == season,
                                onSelected: (_) =>
                                    setState(() => _season = s),
                                selectedColor: const Color(0xFFE50914),
                                backgroundColor: const Color(0xFF262626),
                                labelStyle:
                                    const TextStyle(color: Colors.white),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        for (final e in eps)
                          _EpisodeTile(
                            ep: e,
                            season: season,
                            onPlay: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => WatchScreen(
                                    item: PlayableItem(
                                      mediaKind: 'episode',
                                      mediaId: e.id,
                                      title: '${sh.title} S${e.season
                                          .toString()
                                          .padLeft(2, '0')}E${e.episode
                                          .toString()
                                          .padLeft(2, '0')}',
                                    ),
                                  ),
                                ),
                              );
                              _reload();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  final Episode ep;
  final int season;
  final VoidCallback onPlay;

  const _EpisodeTile({
    required this.ep,
    required this.season,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final api = context.read<Api>();
    final stillUrl = api.assetUrl(ep.still);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPlay,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 130,
              height: 76,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  stillUrl.isEmpty
                      ? Container(color: const Color(0xFF262626))
                      : Image.network(stillUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Container(color: const Color(0xFF262626))),
                  if (ep.completed)
                    Container(
                      color: const Color(0x66000000),
                      child: const Icon(Icons.check_circle,
                          color: Color(0xFF4CAF50)),
                    )
                  else if (ep.positionSec > 0)
                    Container(
                      color: const Color(0x66000000),
                      child: const Icon(Icons.play_arrow,
                          color: Colors.white),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Episode ${ep.episode}',
                        style: const TextStyle(
                            color: Color(0xFFE50914),
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(ep.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                    if (ep.overview.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(ep.overview,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}