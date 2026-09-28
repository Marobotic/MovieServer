import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import '../widgets/app_shell.dart';
import '../widgets/profile_avatar.dart';
import 'admin_tab.dart';
import 'browse_tab.dart';
import 'home/home_tab.dart';
import 'login.dart';
import 'requests_tab.dart';
import 'search_tab.dart';
import 'settings_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;
  String _query = '';

  late final _homeKey = GlobalKey<HomeTabState>();

  void _goBrowse(MediaKind kind) {
    setState(() => _index = kind == MediaKind.movies ? 1 : 2);
  }

  Future<void> _signOut() async {
    final session = context.read<AppSession>();
    final navigator = Navigator.of(context);
    await session.logout();
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final isAdmin = session.isAdmin;

    final destinations = <NavDestination>[
      NavDestination(
        label: 'Home',
        icon: Icons.home_outlined,
        build: () => HomeTab(key: _homeKey, onSeeAll: _goBrowse),
      ),
      NavDestination(
        label: 'Movies',
        icon: Icons.movie_outlined,
        build: () => const BrowseTab(kind: MediaKind.movies),
      ),
      NavDestination(
        label: 'TV Shows',
        icon: Icons.live_tv_outlined,
        build: () => const BrowseTab(kind: MediaKind.shows),
      ),
      NavDestination(
        label: 'Search',
        icon: Icons.search,
        inTopBar: false,
        build: () => SearchTab(query: _query),
      ),
      NavDestination(
        label: 'Requests',
        icon: Icons.playlist_add_check,
        inBottomBar: false,
        build: () => const RequestsTab(),
      ),
      if (isAdmin)
        NavDestination(
          label: 'Admin',
          icon: Icons.admin_panel_settings_outlined,
          inBottomBar: false,
          build: () => const AdminTab(),
        ),
      NavDestination(
        label: 'Account',
        icon: Icons.person_outline,
        inTopBar: false,
        build: () => SettingsTab(
          onOpenRequests: () => setState(() => _index = 4),
          onSignOut: _signOut,
        ),
      ),
    ];

    final profileIndex = destinations.length - 1;
    const searchIndex = 3;
    final safeIndex = _index.clamp(0, destinations.length - 1);

    return AppShell(
      destinations: destinations,
      index: safeIndex,
      onSelect: (i) => setState(() => _index = i),
      username: session.user?.username,
      avatarColor: colorFromHex(session.user?.avatarColor ?? '#3D5AFE'),
      onSearch: (q) => setState(() {
        _query = q;
        _index = searchIndex;
      }),
      onOpenProfile: () => setState(() => _index = profileIndex),
      onSignOut: _signOut,
    );
  }
}
