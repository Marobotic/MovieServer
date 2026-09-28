import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import '../widgets/profile_avatar.dart';
import 'admin_tab.dart';

/// Account page. On compact layouts it is also the overflow home for
/// destinations that do not fit in the bottom bar.
class SettingsTab extends StatelessWidget {
  final VoidCallback onOpenRequests;
  final VoidCallback onSignOut;

  const SettingsTab({
    super.key,
    required this.onOpenRequests,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final user = session.user;
    final size = Breakpoints.of(context);

    return ListView(
      padding: EdgeInsets.fromLTRB(
        size.gutter,
        size.hasTopNav ? 96 : AppSpacing.lg,
        size.gutter,
        AppSpacing.xxxl,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ProfileAvatar(
                      username: user?.username,
                      color: colorFromHex(user?.avatarColor ?? '#3D5AFE'),
                      size: 72,
                      radius: AppRadius.panel,
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user?.username ?? '',
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            user?.isAdmin == true
                                ? 'Administrator'
                                : 'Family member',
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xxl),
                if (size.isCompact) ...[
                  _Tile(
                    icon: Icons.playlist_add_check,
                    title: 'Requests',
                    subtitle: 'Ask for something to be added',
                    onTap: onOpenRequests,
                  ),
                  const Divider(),
                ],
                if (session.isAdmin) ...[
                  _Tile(
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Admin panel',
                    subtitle: 'Users, scanning, uploads, requests',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AdminScreen()),
                    ),
                  ),
                  const Divider(),
                ],
                _Tile(
                  icon: Icons.logout,
                  title: 'Sign out',
                  subtitle: 'Forget this session on this device',
                  onTap: onSignOut,
                ),
                const SizedBox(height: AppSpacing.xxl),
                const Center(
                  child: Text(
                    'MOVIESERVER',
                    style: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(subtitle,
          style: const TextStyle(
              color: AppColors.textSecondary, fontSize: 13)),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textTertiary),
      onTap: onTap,
    );
  }
}
