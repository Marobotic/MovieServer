
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../session.dart';
import '../widgets/profile_avatar.dart';

class AdminTab extends StatelessWidget {
  const AdminTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const AdminScreen();
  }
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text('Admin panel',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              for (final (i, label) in const [
                (0, 'Library'),
                (1, 'Requests'),
                (2, 'Users'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _section == i,
                  onSelected: (_) => setState(() => _section = i),
                  selectedColor: const Color(0xFFE50914),
                  backgroundColor: const Color(0xFF262626),
                  labelStyle: const TextStyle(color: Colors.white),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: IndexedStack(
            index: _section,
            children: const [
              _LibrarySection(),
              _AdminRequests(),
              _UsersSection(),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- Library: scan + upload ----

class _LibrarySection extends StatefulWidget {
  const _LibrarySection();

  @override
  State<_LibrarySection> createState() => _LibrarySectionState();
}

class _LibrarySectionState extends State<_LibrarySection> {
  bool _scanning = false;
  String _scanResult = '';
  bool _downloadingSubs = false;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanResult = '';
    });
    try {
      final r = await context.read<Api>().scan();
      setState(() => _scanResult =
          'Scanned: ${r['movies']} movies, ${r['shows']} shows, ${r['episodes']} episodes');
    } catch (e) {
      setState(() => _scanResult = '$e');
    } finally {
      setState(() => _scanning = false);
    }
  }

  Future<void> _downloadSubs() async {
    setState(() {
      _downloadingSubs = true;
      _scanResult = '';
    });
    try {
      final r = await context.read<Api>().downloadSubtitles();
      setState(() =>
          _scanResult = '${r['status']} - this runs in the background; check server log');
    } catch (e) {
      setState(() => _scanResult = '$e');
    } finally {
      setState(() => _downloadingSubs = false);
    }
  }

  Future<void> _upload() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'mp4', 'mkv', 'avi', 'mov', 'm4v', 'webm', 'ts', 'mpg', 'mpeg', 'wmv', 'flv'
      ],
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;

    // choose kind
    final kind = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('What kind of file is this?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'movie'),
            child: const Row(children: [
              Icon(Icons.movie),
              SizedBox(width: 10),
              Text('Movie'),
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'show'),
            child: const Row(children: [
              Icon(Icons.tv),
              SizedBox(width: 10),
              Text('TV show episode'),
            ]),
          ),
        ],
      ),
    );
    if (kind == null || !mounted) return;

    final fields = <String, String>{'kind': kind};
    if (kind == 'show') {
      final showTitle = await _askText('Show title', hint: 'e.g. Breaking Bad');
      if (showTitle == null || showTitle.trim().isEmpty || !mounted) return;
      fields['show_title'] = showTitle.trim();
      final season = await _askText('Season number', initial: '1',
          keyboard: TextInputType.number);
      if (season == null || !mounted) return;
      fields['season'] = season.trim();
    }

    try {
      if (kIsWeb) {
        final bytes = file.bytes;
        if (bytes == null) throw ApiException('Could not read file');
        final r = await context.read<Api>().uploadBytes(
              fields,
              file.name,
              bytes,
            );
        _showSnack('Uploaded and scanned: ${r['movies']} movies, ${r['shows']} shows');
      } else {
        final path = file.path;
        if (path == null) throw ApiException('Could not read file');
        final r = await context
            .read<Api>()
            .upload(fields, path);
        _showSnack('Uploaded and scanned: ${r['movies']} movies, ${r['shows']} shows');
      }
    } catch (e) {
      if (mounted) _showSnack('Upload failed: $e');
    }
  }

  Future<String?> _askText(String label,
      {String? hint, String? initial, TextInputType? keyboard}) async {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          keyboardType: keyboard,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Library',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text(
                    'Files live in ~/Documents/MovieServer/Movies and /Shows.\n'
                    'After dropping files in, run a scan so they appear in the catalog.',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _scanning ? null : _scan,
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.refresh),
                      label: Text(_scanning ? 'Scanning...' : 'Scan library'),
                    ),
                    const SizedBox(width: 12),
                    if (_scanResult.isNotEmpty)
                      Expanded(
                        child: Text(_scanResult,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _downloadingSubs ? null : _downloadSubs,
                    icon: _downloadingSubs
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.closed_caption),
                    label: Text(_downloadingSubs
                        ? 'Downloading subtitles...'
                        : 'Download en/ar subtitles'),
                  ),
                ),
                const Divider(height: 28),
                const Text('Add media',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text(
                    'Upload a movie or show file directly from this device.',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _upload,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload a video file...'),
                ),
              ],
            ),
          ),
        ),
        if (!context.read<AppSession>().tmdbConfigured)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFFF9A825)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                        'Posters, descriptions and trailers need a free TMDB API key '
                        '(tmdb.org). Add it to the server config.json and restart.',
                        style: TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 80),
      ],
    );
  }
}

// ---- Requests management ----

class _AdminRequests extends StatefulWidget {
  const _AdminRequests();

  @override
  State<_AdminRequests> createState() => _AdminRequestsState();
}

class _AdminRequestsState extends State<_AdminRequests> {
  late Future<List<MediaRequest>> _future;
  String _filter = 'pending';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<MediaRequest>> _load() => context.read<Api>().requests();

  void _reload() => setState(() => _future = _load());

  Future<void> _set(int id, String status) async {
    await context.read<Api>().setRequestStatus(id, status);
    _reload();
  }

  Future<void> _del(int id) async {
    await context.read<Api>().deleteRequest(id);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaRequest>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFFE50914)));
        }
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        final list = (snap.data ?? [])
            .where((r) => _filter == 'all' || r.status == _filter)
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  for (final f in const ['pending', 'approved', 'denied', 'all'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                        selectedColor: const Color(0xFFE50914),
                        backgroundColor: const Color(0xFF262626),
                        labelStyle: const TextStyle(color: Colors.white),
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                      icon: const Icon(Icons.refresh), onPressed: _reload),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(
                      child: Text('No requests in this filter',
                          style: TextStyle(color: Colors.white54)))
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final r in list)
                          Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(r.kind == 'show'
                                          ? Icons.tv
                                          : Icons.movie,
                                          color: const Color(0xFFE50914),
                                          size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${r.title}${r.year > 0 ? ' (${r.year})' : ''}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                      Text(r.status.toUpperCase(),
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w800,
                                              color: r.status == 'approved'
                                                  ? Colors.greenAccent
                                                  : r.status == 'denied'
                                                      ? Colors.redAccent
                                                      : const Color(0xFFF9A825))),
                                    ],
                                  ),
                                  if (r.note.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(r.note,
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 13)),
                                  ],
                                  const SizedBox(height: 2),
                                  Text('by ${r.username}',
                                      style: const TextStyle(
                                          color: Colors.white38,
                                          fontSize: 12)),
                                  const SizedBox(height: 8),
                                  Row(
                                    children: [
                                      FilledButton.icon(
                                        style: FilledButton.styleFrom(
                                            backgroundColor:
                                                Colors.green.shade700,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12, vertical: 8)),
                                        onPressed: r.status == 'approved'
                                            ? null
                                            : () => _set(r.id, 'approved'),
                                        icon: const Icon(Icons.check,
                                            size: 16),
                                        label: const Text('Approve'),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: r.status == 'denied'
                                            ? null
                                            : () => _set(r.id, 'denied'),
                                        icon: const Icon(Icons.close, size: 16),
                                        label: const Text('Deny'),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () => _del(r.id),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Approved = the admin will add this file. '
                                      'Place it in the library folder and scan.',
                                      style: const TextStyle(
                                          color: Colors.white24, fontSize: 11)),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 60),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ---- Users management ----

class _UsersSection extends StatefulWidget {
  const _UsersSection();

  @override
  State<_UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends State<_UsersSection> {
  late Future<List<User>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<User>> _load() => context.read<Api>().users();

  void _reload() => setState(() => _future = _load());

  Future<void> _add() async {
    final u = await _UserDialog.show(context);
    if (u == null || !mounted) return;
    try {
      await context.read<Api>().createUser(u.$1, u.$2, u.$3, u.$4);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _edit(User user) async {
    final res = await _EditUserDialog.show(context, user: user);
    if (res == null || !mounted) return;
    try {
      await context.read<Api>().updateUser(
            user.id,
            password: res.$1,
            role: res.$2,
          );
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _delete(User user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${user.username}?'),
        content: const Text('This removes their account and progress.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<Api>().deleteUser(user.id);
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
    return FutureBuilder<List<User>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFFE50914)));
        }
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        final users = snap.data ?? [];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Text('Family accounts',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.person_add),
                  label: const Text('Add user'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
                'Each account keeps its own watch progress.',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            for (final u in users)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: ProfileAvatar(
                    username: u.username,
                    color: colorFromHex(u.avatarColor),
                    size: 44,
                  ),
                  title: Text(u.username,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(u.isAdmin ? 'Admin' : 'Viewer'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit',
                        onPressed: () => _edit(u),
                      ),
                      if (u.id != context.read<AppSession>().user?.id)
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete',
                          onPressed: () => _delete(u),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _UserDialog {
  static Future<(String, String, String, String)?> show(BuildContext context) async {
    final user = TextEditingController();
    final pass = TextEditingController();
    String role = 'viewer';
    final colors = ['#E50914', '#3D5AFE', '#00897B', '#F9A825', '#9C27B0', '#FF5722', '#5E35B1'];
    String color = colors.first;

    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('New user'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: user,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password (min 6)'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: role,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: const [
                    DropdownMenuItem(value: 'viewer', child: Text('Viewer')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                  ],
                  onChanged: (v) => setState(() => role = v ?? 'viewer'),
                ),
                const SizedBox(height: 10),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Avatar colour',
                      style: TextStyle(fontSize: 13, color: Colors.white54)),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final c in colors)
                      InkWell(
                        onTap: () => setState(() => color = c),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: colorFromHex(c),
                            shape: BoxShape.circle,
                            border: color == c
                                ? Border.all(color: Colors.white, width: 3)
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Create')),
          ],
        ),
      ),
    );
    if (res != true) return null;
    return (user.text.trim(), pass.text, role, color);
  }
}

class _EditUserDialog {
  static Future<(String?, String)?> show(BuildContext context, {required User user}) async {
    final pass = TextEditingController();
    String role = user.role;

    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(user.username),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'New password (blank = keep)'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: role,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: const [
                    DropdownMenuItem(value: 'viewer', child: Text('Viewer')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                  ],
                  onChanged: (v) => setState(() => role = v ?? role),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (res != true) return null;
    final pw = pass.text;
    return (pw.isEmpty ? null : pw, role);
  }
}