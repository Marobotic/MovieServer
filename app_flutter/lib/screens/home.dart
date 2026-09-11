import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../session.dart';
import 'home/home_tab.dart';
import 'search_tab.dart';
import 'requests_tab.dart';
import 'admin_tab.dart';
import 'settings_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final tabs = [
      const HomeTab(),
      const SearchTab(),
      const RequestsTab(),
      if (session.isAdmin) const AdminTab(),
      const SettingsTab(),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _index, children: tabs)),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: [
          const BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined), label: 'Home'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.search), label: 'Search'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.playlist_add_check), label: 'Requests'),
          if (session.isAdmin)
            const BottomNavigationBarItem(
                icon: Icon(Icons.admin_panel_settings_outlined), label: 'Admin'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }
}