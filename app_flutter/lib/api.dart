import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, [this.status = 0]);

  @override
  String toString() => message;
}

class Api {
  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_user';
  static const _serverKey = 'server_url';

  String baseUrl;
  String? token;
  User? user;

  Api._({required this.baseUrl});

  /// Creates an Api instance with persisted token/user already loaded.
  static Future<Api> create({required String baseUrl}) async {
    final api = Api._(baseUrl: baseUrl);
    await api._initSaved();
    return api;
  }

  static Future<String> defaultBaseUrl() async {
    if (kIsWeb) {
      final origin = Uri.base.origin;
      if (origin != 'null' && origin.isNotEmpty) {
        return origin;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverKey) ?? 'http://localhost:8080';
  }

  Future<void> _initSaved() async {
    final prefs = await SharedPreferences.getInstance();
    token = prefs.getString(_tokenKey);
    final u = prefs.getString(_userKey);
    if (u != null) {
      try {
        user = User.fromJson(jsonDecode(u));
      } catch (_) {}
    }
  }

  Future<void> saveToken(String t, User u) async {
    token = t;
    user = u;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, t);
    await prefs.setString(
        _userKey,
        jsonEncode({
          'id': u.id,
          'username': u.username,
          'role': u.role,
          'avatar_color': u.avatarColor,
        }));
  }

  Future<void> saveServerUrl(String url) async {
    baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, url);
  }

  Future<void> logout() async {
    token = null;
    user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, String>? q]) {
    final u = Uri.parse('$baseUrl$path');
    if (q == null || q.isEmpty) {
      return u;
    }
    return u.replace(queryParameters: {...u.queryParameters, ...q});
  }

  Future<dynamic> _request(String method, String path,
      {Object? body, Map<String, String>? query, bool authFree = false}) async {
    final uri = _uri(path, query);
    final headers = authFree ? {'Content-Type': 'application/json'} : _headers;
    http.Response? resp;
    if (method == 'GET') {
      resp = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 30));
    } else if (method == 'DELETE') {
      resp = await http
          .delete(uri, headers: headers)
          .timeout(const Duration(seconds: 30));
    } else if (method == 'PATCH') {
      resp = await http
          .patch(uri,
              headers: headers,
              body: body is String ? body : jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 30));
    } else {
      resp = await http
          .post(uri,
              headers: headers,
              body: body is String ? body : jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 60));
    }
    final text = utf8.decode(resp.bodyBytes);
    if (resp.statusCode >= 400) {
      String msg = 'Request failed (${resp.statusCode})';
      try {
        msg = jsonDecode(text)['error'] ?? msg;
      } catch (_) {}
      throw ApiException(msg, resp.statusCode);
    }
    if (text.isEmpty) {
      return null;
    }
    return jsonDecode(text);
  }

  // ---- capabilities & auth ----

  Future<Map<String, dynamic>> capabilities() async =>
      Map<String, dynamic>.from(
          await _request('GET', '/api/capabilities', authFree: true));

  Future<void> setup(String username, String password) async {
    final r = await _request('POST', '/api/auth/setup',
        body: {'username': username, 'password': password}, authFree: true);
    await saveToken(r['token'], User.fromJson(r['user']));
  }

  Future<void> login(String username, String password) async {
    final r = await _request('POST', '/api/auth/login',
        body: {'username': username, 'password': password}, authFree: true);
    await saveToken(r['token'], User.fromJson(r['user']));
  }

  Future<User?> me() async {
    try {
      final r = await _request('GET', '/api/me');
      return User.fromJson(r);
    } on ApiException catch (e) {
      if (e.status == 401) {
        await logout();
      }
      return null;
    }
  }

  Future<List<User>> users() async {
    final r = await _request('GET', '/api/users');
    return (r as List).map((e) => User.fromJson(e)).toList();
  }

  /// Public profile list, callable before login (profile picker).
  Future<List<User>> profiles() async {
    final r = await _request('GET', '/api/profiles', authFree: true);
    return (r as List).map((e) => User.fromJson(e)).toList();
  }

  Future<User> createUser(
      String username, String password, String role, String avatarColor) async {
    final r = await _request('POST', '/api/users', body: {
      'username': username,
      'password': password,
      'role': role,
      'avatar_color': avatarColor,
    });
    return User.fromJson(r);
  }

  Future<void> updateUser(int id,
      {String? password,
      String? role,
      String? avatarColor,
      String? audioLang}) async {
    await _request('PUT', '/api/users/$id', body: {
      if (password != null) 'password': password,
      if (role != null) 'role': role,
      if (avatarColor != null) 'avatar_color': avatarColor,
      if (audioLang != null) 'audio_lang': audioLang,
    });
  }

  Future<void> deleteUser(int id) => _request('DELETE', '/api/users/$id');

  // ---- library ----

  Future<List<Movie>> movies() async {
    final r = await _request('GET', '/api/movies');
    return (r as List).map((e) => Movie.fromJson(e)).toList();
  }

  Future<List<Show>> shows() async {
    final r = await _request('GET', '/api/shows');
    return (r as List).map((e) => Show.fromJson(e)).toList();
  }

  Future<Movie> movie(int id) async =>
      Movie.fromJson(await _request('GET', '/api/movies/$id'));

  Future<ShowDetail> showDetail(int id) async =>
      ShowDetail.fromJson(await _request('GET', '/api/shows/$id'));

  Future<List<ContinueItem>> continueWatching() async {
    final r = await _request('GET', '/api/library/continue_watching');
    return (r as List).map((e) => ContinueItem.fromJson(e)).toList();
  }

  Future<({List<Movie> movies, List<Show> shows})> search(String q) async {
    final r = await _request('GET', '/api/search', query: {'q': q});
    return (
      movies: (r['movies'] as List).map((e) => Movie.fromJson(e)).toList(),
      shows: (r['shows'] as List).map((e) => Show.fromJson(e)).toList(),
    );
  }

  Future<void> saveProgress(String mediaKind, int mediaId, int position,
      int duration, bool completed) {
    return _request('POST', '/api/progress', body: {
      'media_kind': mediaKind,
      'media_id': mediaId,
      'position': position,
      'duration': duration,
      'completed': completed,
    });
  }

  Future<void> clearProgress(String mediaKind, int mediaId) => _request(
      'DELETE', '/api/progress?media_kind=$mediaKind&media_id=$mediaId');

  // ---- streaming ----

  /// Resource routes on the server are plural (/api/movies/..., /api/episodes/...);
  /// progress bodies use the singular media_kind value.
  String _pluralKind(String kind) => switch (kind) {
        'movie' => 'movies',
        'show' => 'shows',
        'episode' => 'episodes',
        _ => kind,
      };

  String streamUrl(String mediaKind, int id) {
    final t = token ?? '';
    return '$baseUrl/api/${_pluralKind(mediaKind)}/$id/stream?token=$t';
  }

  /// HLS transcoded URL. Browsers can't play MKV/HEVC directly, so the web
  /// player uses this and the server converts on the fly.
  String hlsUrl(String mediaKind, int id, {int startSeconds = 0}) {
    final t = token ?? '';
    var u =
        '$baseUrl/api/${_pluralKind(mediaKind)}/$id/hls/master.m3u8?token=$t';
    if (startSeconds > 15) {
      u += '&start=$startSeconds';
    }
    return u;
  }

  String assetUrl(String path) {
    if (path.isEmpty) {
      return '';
    }
    if (path.startsWith('http')) {
      return path;
    }
    return '$baseUrl$path';
  }

  // ---- media extras ----

  /// URL for a local artwork slot (poster/backdrop/banner/logo/icon/...)
  /// stored inside the media item's folder. Public endpoint, no auth needed.
  String artUrl(String kind, int id, String slot) {
    return '$baseUrl/api/${_pluralKind(kind)}/$id/art/$slot';
  }

  /// Subtitle file URL with token (players fetch it on their own).
  String subtitleUrl(String mediaKind, int id, int index) {
    final t = token ?? '';
    return '$baseUrl/api/${_pluralKind(mediaKind)}/$id/subtitles/$index?token=$t';
  }

  /// Subtitle + audio track listings for a playable item.
  Future<MediaTracks> tracks(String mediaKind, int id) async {
    final r =
        await _request('GET', '/api/${_pluralKind(mediaKind)}/$id/tracks');
    return MediaTracks.fromJson(r);
  }

  /// Reports whether the server can transcode this item for browser playback.
  Future<MediaFormat> detect(String mediaKind, int id) async {
    final r =
        await _request('GET', '/api/${_pluralKind(mediaKind)}/$id/detect');
    return MediaFormat.fromJson(r);
  }

  // ---- requests ----

  Future<int> createRequest(
      String kind, String title, int year, String note, int tmdbId) async {
    final r = await _request('POST', '/api/requests', body: {
      'kind': kind,
      'title': title,
      'year': year,
      'note': note,
      'tmdb_id': tmdbId,
    });
    return r['id'];
  }

  Future<List<MediaRequest>> requests({String? status}) async {
    final r = await _request('GET', '/api/requests',
        query: status != null ? {'status': status} : null);
    return (r as List).map((e) => MediaRequest.fromJson(e)).toList();
  }

  Future<void> setRequestStatus(int id, String status) =>
      _request('PATCH', '/api/requests/$id', body: {'status': status});

  Future<void> deleteRequest(int id) => _request('DELETE', '/api/requests/$id');

  // ---- admin ----

  Future<Map<String, dynamic>> scan() async =>
      Map<String, dynamic>.from(await _request('POST', '/api/admin/scan'));

  Future<Map<String, dynamic>> downloadSubtitles() async =>
      Map<String, dynamic>.from(await _request('POST', '/api/admin/subs'));

  Future<List<TMDbHit>> tmdbSearch(String query, String type) async {
    final r = await _request('GET', '/api/admin/tmdb/search',
        query: {'q': query, 'type': type});
    return (r as List).map((e) => TMDbHit.fromJson(e)).toList();
  }

  // ---- upload ----

  Future<Map<String, dynamic>> upload(
      Map<String, String> fields, String filePath) async {
    final req = http.MultipartRequest('POST', _uri('/api/admin/upload'))
      ..headers['Authorization'] = 'Bearer ${token ?? ''}'
      ..fields.addAll(fields)
      ..files.add(await http.MultipartFile.fromPath('file', filePath));
    final resp = await req.send().timeout(const Duration(minutes: 30));
    final text = await resp.stream.bytesToString();
    if (resp.statusCode >= 400) {
      String msg = 'Upload failed (${resp.statusCode})';
      try {
        msg = jsonDecode(text)['error'] ?? msg;
      } catch (_) {}
      throw ApiException(msg, resp.statusCode);
    }
    return jsonDecode(text);
  }

  Future<Map<String, dynamic>> uploadBytes(
      Map<String, String> fields, String name, List<int> bytes) async {
    final req = http.MultipartRequest('POST', _uri('/api/admin/upload'))
      ..headers['Authorization'] = 'Bearer ${token ?? ''}'
      ..fields.addAll(fields)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    final resp = await req.send().timeout(const Duration(minutes: 30));
    final text = await resp.stream.bytesToString();
    if (resp.statusCode >= 400) {
      String msg = 'Upload failed (${resp.statusCode})';
      try {
        msg = jsonDecode(text)['error'] ?? msg;
      } catch (_) {}
      throw ApiException(msg, resp.statusCode);
    }
    return jsonDecode(text);
  }
}
