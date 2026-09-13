import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import 'request_new.dart';
import 'request_catalog.dart';

class RequestsTab extends StatefulWidget {
  const RequestsTab({super.key});

  @override
  State<RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends State<RequestsTab> {
  late Future<List<MediaRequest>> _future;
  String _filter = 'all';
  bool _browse = true;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<MediaRequest>> _load() async {
    return context.read<Api>().requests();
  }

  void _reload() {
    setState(() => _future = _load());
  }

  Future<void> _cancel(int id) async {
    try {
      await context.read<Api>().deleteRequest(id);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_browse) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                const Text('Discover',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _browse = false),
                  icon: const Icon(Icons.playlist_add_check),
                  label: const Text('My requests'),
                ),
              ],
            ),
          ),
          const Expanded(child: RequestCatalog()),
        ],
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              const Text('Requests',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _browse = true),
                child: const Text('Browse catalog'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RequestNewScreen()),
                  );
                  _reload();
                },
                icon: const Icon(Icons.add),
                label: const Text('Request'),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<MediaRequest>>(
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
              final all = snap.data ?? [];
              final list = _filter == 'all'
                  ? all
                  : all.where((r) => r.status == _filter).toList();
              if (list.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.playlist_add,
                          color: Colors.white38, size: 48),
                      const SizedBox(height: 12),
                      const Text('No requests yet',
                          style: TextStyle(color: Colors.white54)),
                      const SizedBox(height: 6),
                      const Text(
                          'Ask for a movie or show and the admin can add it.',
                          style: TextStyle(color: Colors.white38),
                          textAlign: TextAlign.center),
                    ],
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final f in const [
                        'all',
                        'pending',
                        'approved',
                        'denied'
                      ])
                        ChoiceChip(
                          label: Text(f),
                          selected: _filter == f,
                          onSelected: (_) {
                            setState(() => _filter = f);
                          },
                          selectedColor: const Color(0xFFE50914),
                          backgroundColor: const Color(0xFF262626),
                          labelStyle: const TextStyle(color: Colors.white),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final r in list) _RequestCard(r: r, onCancel: _cancel),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RequestCard extends StatelessWidget {
  final MediaRequest r;
  final ValueChanged<int> onCancel;

  const _RequestCard({required this.r, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(
          r.kind == 'show' ? Icons.tv : Icons.movie,
          color: const Color(0xFFE50914),
        ),
        title: Text(
          r.title + (r.year > 0 ? ' (${r.year})' : ''),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(r.note.isNotEmpty ? r.note : r.kind.toUpperCase()),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusBadge(status: r.status),
            if (r.status == 'pending')
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                tooltip: 'Cancel',
                onPressed: () => onCancel(r.id),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = {
      'pending': const Color(0xFFF9A825),
      'approved': const Color(0xFF4CAF50),
      'denied': const Color(0xFFF44336),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors[status] ?? const Color(0xFF757575),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(status,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
