import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

class AppSession extends ChangeNotifier {
  final Api api;
  bool needsSetup = false;
  bool tmdbConfigured = false;
  bool _loadingUsers = false;

  AppSession(this.api);

  User? get user => api.user;
  bool get isAdmin => user?.isAdmin ?? false;

  Future<void> init() async {
    try {
      final caps = await api.capabilities();
      needsSetup = caps['needs_setup'] == true;
      tmdbConfigured = caps['tmdb_configured'] == true;
    } catch (_) {
      // server unreachable; screen will show retry
    }
    if (api.token != null) {
      final u = await api.me();
      if (u != null) {
        notifyListeners();
      }
    }
  }

  bool get loadingUsers => _loadingUsers;

  /// Public list of profiles (works before login, Netflix-style picker).
  Future<List<User>> profiles() => api.profiles();

  Future<List<User>> users() async {
    _loadingUsers = true;
    notifyListeners();
    try {
      return await api.users();
    } finally {
      _loadingUsers = false;
      notifyListeners();
    }
  }

  Future<void> login(String username, String password) async {
    await api.login(username, password);
    notifyListeners();
  }

  Future<void> logout() async {
    await api.logout();
    notifyListeners();
  }
}