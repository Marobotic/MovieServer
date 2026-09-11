import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../session.dart';
import '../widgets/profile_avatar.dart';
import 'home.dart';
import 'login.dart';

/// Netflix-style profile picker shown when no session is active.
class UserSelectScreen extends StatefulWidget {
  const UserSelectScreen({super.key});

  @override
  State<UserSelectScreen> createState() => _UserSelectScreenState();
}

class _UserSelectScreenState extends State<UserSelectScreen> {
  List<User> _users = [];
  bool _loading = true;
  bool _askedLogin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await context.read<AppSession>().profiles();
      setState(() => _users = users);
    } catch (e) {
      debugPrint('profiles load failed: $e');
      _showError('Cannot reach the server.\n\nCheck that the MovieServer is running and your server URL is correct.');
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connection problem'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _load();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _pick(User u) async {
    if (_askedLogin) return;
    _askedLogin = true;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LoginScreen(initialUsername: u.username)),
    );
    _askedLogin = false;
    if (context.read<AppSession>().user != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      body: Column(
        children: [
          const SizedBox(height: 70),
          const Text('Who is watching?',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 44),
          Expanded(
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator(color: Color(0xFFE50914))
                  : _users.isEmpty
                      ? const Text('No users yet. Sign in to create the admin.',
                          style: TextStyle(color: Colors.white70))
                      : Wrap(
                          spacing: 36,
                          runSpacing: 36,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final u in _users)
                              _ProfileTile(
                                label: u.username,
                                child: ProfileAvatar(
                                  username: u.username,
                                  color: colorFromHex(u.avatarColor),
                                ),
                                onTap: () => _pick(u),
                              ),
                            if (context.read<AppSession>().isAdmin)
                              _ProfileTile(
                                label: 'Add profile',
                                child: const ProfileAvatar(isAdd: true),
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) => const LoginScreen()),
                                ),
                              ),
                          ],
                        ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              ),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Sign in / change server'),
              style: TextButton.styleFrom(foregroundColor: Colors.white54),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final Widget child;
  final String label;
  final VoidCallback onTap;

  const _ProfileTile({
    required this.child,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 10),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
        ],
      ),
    );
  }
}