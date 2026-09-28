import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../models.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import '../widgets/detail_scaffold.dart';
import '../widgets/state_views.dart';
import 'watch.dart';

class MovieDetailScreen extends StatefulWidget {
  final int movieId;
  final bool modal;

  const MovieDetailScreen({
    super.key,
    required this.movieId,
    this.modal = false,
  });

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

  void _reload() =>
      setState(() => _future = context.read<Api>().movie(widget.movieId));

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

  Future<void> _openTrailer(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _runtime(int sec) {
    if (sec <= 0) return '';
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  String _size(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 10 || i == 0 ? 0 : 1)} ${units[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);

    return FutureBuilder<Movie>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _wrap(const LoadingView());
        }
        if (snap.hasError) {
          return _wrap(ErrorView(message: '${snap.error}', onRetry: _reload));
        }
        final m = snap.data!;
        final meta = [
          if (m.year > 0) '${m.year}',
          if (m.durationSec > 0) _runtime(m.durationSec),
          'Movie',
        ].join('  •  ');

        return DetailScaffold(
          modal: widget.modal,
          backdropUrl: m.backdrop.isNotEmpty ? m.backdrop : m.poster,
          title: m.title,
          header: DetailHeader(
            title: m.title,
            meta: meta,
            actions: [
              FilledButton.icon(
                onPressed: () => _play(m),
                icon: const Icon(Icons.play_arrow, size: 24),
                label: const Text('Play'),
              ),
              if (m.trailerUrl.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _openTrailer(m.trailerUrl),
                  icon: const Icon(Icons.movie_outlined, size: 20),
                  label: const Text('Trailer'),
                ),
            ],
          ),
          children: [
            if (size.isDesktop)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: _overview(m)),
                  const SizedBox(width: AppSpacing.xxl),
                  Expanded(flex: 2, child: _facts(m)),
                ],
              )
            else ...[
              _overview(m),
              const SizedBox(height: AppSpacing.xl),
              _facts(m),
            ],
          ],
        );
      },
    );
  }

  /// Loading and error states still need the modal/page chrome around them.
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

  Widget _overview(Movie m) {
    if (m.overview.isEmpty) {
      return const Text(
        'No synopsis available for this title.',
        style: TextStyle(color: AppColors.textTertiary, fontSize: 14),
      );
    }
    return Text(
      m.overview,
      style: const TextStyle(
          color: AppColors.textPrimary, fontSize: 15, height: 1.6),
    );
  }

  Widget _facts(Movie m) {
    final rows = <(String, String)>[
      if (m.year > 0) ('Year', '${m.year}'),
      if (m.durationSec > 0) ('Runtime', _runtime(m.durationSec)),
      if (m.sizeBytes > 0) ('File size', _size(m.sizeBytes)),
      if (m.addedAt != null)
        ('Added', '${m.addedAt!.year}-${m.addedAt!.month.toString().padLeft(2, '0')}-${m.addedAt!.day.toString().padLeft(2, '0')}'),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 13, height: 1.5),
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: const TextStyle(color: AppColors.textTertiary),
                  ),
                  TextSpan(
                    text: value,
                    style: const TextStyle(color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
