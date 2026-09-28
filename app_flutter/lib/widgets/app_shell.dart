import 'package:flutter/material.dart';

import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import 'profile_avatar.dart';
import 'wordmark.dart';

/// One navigation destination in the shell.
class NavDestination {
  final String label;
  final IconData icon;
  final Widget Function() build;

  /// Whether the destination appears in the compact bottom bar. Overflow
  /// destinations stay reachable from the profile tab.
  final bool inBottomBar;

  /// Whether the destination appears as a link in the desktop top bar.
  final bool inTopBar;

  const NavDestination({
    required this.label,
    required this.icon,
    required this.build,
    this.inBottomBar = true,
    this.inTopBar = true,
  });
}

/// Netflix-style application chrome. On tablet and desktop the navigation is a
/// top bar that floats over the content and fades in a solid background as the
/// page scrolls; on phones it stays a bottom bar.
class AppShell extends StatefulWidget {
  final List<NavDestination> destinations;
  final int index;
  final ValueChanged<int> onSelect;
  final String? username;
  final Color avatarColor;
  final ValueChanged<String> onSearch;
  final VoidCallback onOpenProfile;
  final VoidCallback onSignOut;

  const AppShell({
    super.key,
    required this.destinations,
    required this.index,
    required this.onSelect,
    required this.username,
    required this.avatarColor,
    required this.onSearch,
    required this.onOpenProfile,
    required this.onSignOut,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  double _scrolled = 0;
  bool _searchOpen = false;
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final t = (n.metrics.pixels / 90).clamp(0.0, 1.0);
    if ((t - _scrolled).abs() > 0.02) setState(() => _scrolled = t);
    return false;
  }

  void _submitSearch(String q) {
    if (q.trim().isEmpty) return;
    widget.onSearch(q.trim());
  }

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final pages = [
      for (final d in widget.destinations) d.build(),
    ];
    final body = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: IndexedStack(index: widget.index, children: pages),
    );

    if (!size.hasTopNav) {
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: _bottomBar(),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _topBar(size),
          ),
        ],
      ),
    );
  }

  // ---- compact ----

  Widget _bottomBar() {
    final visible = [
      for (var i = 0; i < widget.destinations.length; i++)
        if (widget.destinations[i].inBottomBar) i,
    ];
    final current = visible.indexOf(widget.index);
    return BottomNavigationBar(
      currentIndex: current < 0 ? 0 : current,
      onTap: (i) => widget.onSelect(visible[i]),
      items: [
        for (final i in visible)
          BottomNavigationBarItem(
            icon: Icon(widget.destinations[i].icon),
            label: widget.destinations[i].label,
          ),
      ],
    );
  }

  // ---- tablet / desktop ----

  Widget _topBar(WindowSize size) {
    final solid = AppColors.bg.withOpacity(_scrolled);
    return AnimatedContainer(
      duration: AppMotion.fast,
      height: size.isDesktop ? 68 : 60,
      decoration: BoxDecoration(
        color: solid,
        gradient: _scrolled > 0.9
            ? null
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB3000000), Color(0x00000000)],
              ),
      ),
      padding: EdgeInsets.symmetric(horizontal: size.gutter),
      child: Row(
        children: [
          Wordmark(
            fontSize: size.isDesktop ? 26 : 22,
            onTap: () => widget.onSelect(0),
          ),
          SizedBox(width: size.isDesktop ? AppSpacing.xxl : AppSpacing.lg),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < widget.destinations.length; i++)
                    if (widget.destinations[i].inTopBar)
                      _NavLink(
                        label: widget.destinations[i].label,
                        selected: widget.index == i,
                        onTap: () => widget.onSelect(i),
                      ),
                ],
              ),
            ),
          ),
          _searchField(size),
          const SizedBox(width: AppSpacing.md),
          _avatarMenu(),
        ],
      ),
    );
  }

  Widget _searchField(WindowSize size) {
    if (!_searchOpen) {
      return IconButton(
        icon: const Icon(Icons.search, color: AppColors.textPrimary),
        tooltip: 'Search',
        onPressed: () {
          setState(() => _searchOpen = true);
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _searchFocus.requestFocus());
        },
      );
    }
    return AnimatedContainer(
      duration: AppMotion.fast,
      width: size.isDesktop ? 260 : 190,
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.black.withOpacity(0.7),
        border: Border.all(color: AppColors.borderStrong),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        children: [
          const Icon(Icons.search, size: 18, color: AppColors.textPrimary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: _searchCtl,
              focusNode: _searchFocus,
              style: const TextStyle(
                  color: AppColors.textPrimary, fontSize: 14),
              cursorColor: AppColors.textPrimary,
              textInputAction: TextInputAction.search,
              onSubmitted: _submitSearch,
              onChanged: (v) {
                if (v.trim().length >= 2) _submitSearch(v);
              },
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: 'Titles',
              ),
            ),
          ),
          InkWell(
            onTap: () {
              _searchCtl.clear();
              setState(() => _searchOpen = false);
            },
            child: const Icon(Icons.close,
                size: 16, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _avatarMenu() {
    return PopupMenuButton<String>(
      tooltip: widget.username ?? 'Account',
      offset: const Offset(0, 48),
      position: PopupMenuPosition.under,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        side: const BorderSide(color: AppColors.border),
      ),
      onSelected: (v) {
        if (v == 'profile') widget.onOpenProfile();
        if (v == 'signout') widget.onSignOut();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          height: 40,
          child: Text(
            widget.username ?? '',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 13),
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem(
          value: 'profile',
          height: 42,
          child: Row(children: [
            Icon(Icons.person_outline, size: 18),
            SizedBox(width: AppSpacing.md),
            Text('Account'),
          ]),
        ),
        const PopupMenuItem(
          value: 'signout',
          height: 42,
          child: Row(children: [
            Icon(Icons.logout, size: 18),
            SizedBox(width: AppSpacing.md),
            Text('Sign out'),
          ]),
        ),
      ],
      child: ProfileAvatar(
        username: widget.username,
        color: widget.avatarColor,
        size: 32,
        radius: AppRadius.control,
      ),
    );
  }
}

class _NavLink extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavLink({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavLink> createState() => _NavLinkState();
}

class _NavLinkState extends State<_NavLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? AppColors.textPrimary
        : (_hover ? AppColors.textPrimary : AppColors.textSecondary);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.fast,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight:
                  widget.selected ? FontWeight.w700 : FontWeight.w400,
            ),
            child: Text(widget.label),
          ),
        ),
      ),
    );
  }
}
