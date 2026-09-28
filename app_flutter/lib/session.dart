import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

class AppSession extends ChangeNotifier {
  final Api api;
  bool needsSetup = false;
  bool tmdbConfigured = false;
  bool _loadingUsers = false;
  Future<void>? _init;

  AppSession(this.api);

  User? get user => api.user;
  bool get isAdmin => user?.isAdmin ?? false;

  /// Completes once capabilities and the stored session have been checked.
  /// Safe to await from several places; the work runs exactly once.
  Future<void> get ready => _init ??= _bootstrap();

  /// Kept for the call in main(); it just starts [ready].
  Future<void> init() => ready;

  Future<void> _bootstrap() async {
    try {
      final caps = await api.capabilities();
      needsSetup = caps['needs_setup'] == true;
      tmdbConfigured = caps['tmdb_configured'] == true;
    } catch (_) {
      // server unreachable; the screen will offer a retry
    }
    if (api.token != null) {
      await api.me();
    }
    notifyListeners();
  }

  bool get loadingUsers => _loadingUsers;

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
