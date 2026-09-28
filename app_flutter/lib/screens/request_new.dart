import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../theme/tokens.dart';
import '../widgets/toast.dart';

class RequestNewScreen extends StatefulWidget {
  const RequestNewScreen({super.key});

  @override
  State<RequestNewScreen> createState() => _RequestNewScreenState();
}

class _RequestNewScreenState extends State<RequestNewScreen> {
  bool _kindShow = false;
  final _title = TextEditingController();
  final _year = TextEditingController();
  final _note = TextEditingController();

  // TMDB suggestion picking
  bool _tmdbUsable = false;
  bool _searching = false;
  List<TMDbHit> _hits = [];
  TMDbHit? _selected;

  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _tmdbUsable = context.read<AppSession>().tmdbConfigured;
  }

  Future<void> _searchTMDb(String q) async {
    if (q.trim().isEmpty) return;
    setState(() {
      _searching = true;
      _hits = [];
    });
    try {
      final hits = await context.read<Api>().tmdbSearch(
            q.trim(),
            _kindShow ? 'tv' : 'movie',
          );
      setState(() => _hits = hits);
    } catch (e) {
      if (mounted) {
        Toast.show(context, '$e', kind: ToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final title = _selected?.title ?? _title.text.trim();
      final year = _year.text.trim().isEmpty
          ? (_selected?.year ?? 0)
          : (int.tryParse(_year.text) ?? 0);
      if (title.isEmpty) {
        setState(() => _error = 'Please enter a title');
        return;
      }
      await context.read<Api>().createRequest(
            _kindShow ? 'show' : 'movie',
            title,
            year,
            _note.text.trim(),
            _selected?.tmdbId ?? 0,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Request a title')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('What should the admin add to the library?',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),

          // Type toggle
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Movie'), icon: Icon(Icons.movie)),
              ButtonSegment(value: true, label: Text('TV Show'), icon: Icon(Icons.tv)),
            ],
            selected: {_kindShow},
            onSelectionChanged: (s) {
              setState(() {
                _kindShow = s.first;
                _hits = [];
                _selected = null;
              });
            },
          ),
          const SizedBox(height: 18),

          if (_tmdbUsable) ...[
            const Text(
                'Search (picks the exact title and year automatically). Leave blank to type it.',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search The Movie DB...',
                prefixIcon: Icon(Icons.travel_explore),
              ),
              onSubmitted: _searchTMDb,
            ),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.red))),
              ),
            if (_hits.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final h in _hits.take(6))
                      ListTile(
                        dense: true,
                        title: Text((h.year > 0 ? '${h.title} (${h.year})' : h.title)),
                        subtitle: Text(h.overview.split('\n').first,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        selected: _selected == h,
                        trailing: h.type == 'show'
                            ? const Icon(Icons.tv)
                            : const Icon(Icons.movie),
                        onTap: () => setState(() {
                          _selected = h;
                          _title.text = h.title;
                          _year.text = h.year > 0 ? '${h.year}' : '';
                        }),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
          ],

          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Title',
              prefixIcon: Icon(Icons.title),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _year,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Year (optional)',
              prefixIcon: Icon(Icons.calendar_today_outlined),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              prefixIcon: Icon(Icons.notes),
              alignLabelWithHint: true,
            ),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 22),
          ElevatedButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Send request'),
          ),
          if (!kIsWeb) const SizedBox(height: 6),
          if (!kIsWeb && !_tmdbUsable)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'The Movie DB search is not configured yet - type the exact title. '
                  'The admin can enable it later for posters and trailers.',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}