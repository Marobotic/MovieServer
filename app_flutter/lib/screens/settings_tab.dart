import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import '../widgets/profile_avatar.dart';
import 'user_select.dart';
import 'admin_tab.dart';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final user = session.user;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 8),
        Center(
          child: Column(
            children: [
              ProfileAvatar(
                username: user?.username,
                color: colorFromHex(user?.avatarColor ?? '#3D5AFE'),
                size: 88,
              ),
              const SizedBox(height: 12),
              Text(user?.username ?? '',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700)),
              Text(user?.isAdmin == true ? 'Administrator' : 'Family member',
                  style: const TextStyle(color: Colors.white54)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (session.isAdmin) ...[
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Admin panel'),
            subtitle: const Text('Users, scanning, uploads, requests'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AdminScreen()),
            ),
          ),
          const Divider(height: 1),
        ],
        ListTile(
          leading: const Icon(Icons.person_add_alt),
          title: const Text('Switch profile'),
          subtitle: const Text('Return to the profile picker'),
          onTap: () async {
            await session.logout();
            if (!mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const UserSelectScreen()),
              (route) => false,
            );
          },
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          subtitle: const Text('Forget this session'),
          onTap: () async {
            await session.logout();
            if (!mounted) return;
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const UserSelectScreen()),
              (route) => false,
            );
          },
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text('MovieServer',
              style: TextStyle(color: Colors.white24, fontSize: 13)),
        ),
      ],
    );
  }
}