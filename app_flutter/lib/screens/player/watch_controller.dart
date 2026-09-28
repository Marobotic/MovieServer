import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../api.dart';
import '../../models.dart';
import '../../playback.dart';
import '../../subtitles/parser.dart';

/// What the caller should be watching for this title.
class PlayableItem {
  final String mediaKind; // movie | episode | external
  final int mediaId;
  final String title;
  final String? externalUrl;
  final int? showId;
  final int? season;
  final int? episode;

  const PlayableItem({
    required this.mediaKind,
    required this.mediaId,
    required this.title,
    this.externalUrl,
    this.showId,
    this.season,
    this.episode,
  });

  bool get isLibraryItem => mediaKind == 'movie' || mediaKind == 'episode';
}

/// Owns everything about a playback session except the chrome: the preflight
/// decision, the prepare job it may be waiting on, track selection, subtitle
/// timing and progress reporting.
///
/// Deliberately free of BuildContext so the watch screen is only responsible
/// for laying out what this exposes.
class WatchController extends ChangeNotifier {
  final Api api;
  final PlayableItem item;
  final String? externalUrl;

  WatchController({
    required this.api,
    required this.item,
    this.externalUrl,
  });

  final PlaybackController player = createPlaybackController();
  final List<StreamSubscription> _subs = [];

  Timer? _progressTimer;
  Timer? _jobPollTimer;
  Timer? _delayPollTimer;
  Timer? _delayCommitTimer;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  Duration buffered = Duration.zero;
  Duration offset = Duration.zero;
  bool playing = false;
  bool buffering = true;

  MediaTracks tracks = const MediaTracks.empty();
  bool tracksLoaded = false;
  int? activeSubtitle;
  int? activeAudio;
  List<SubtitleCue> subtitleCues = [];

  double subDelaySec = 0;
  int? _pendingDelayMs;

  /// Set while a menu is open so the periodic poll cannot overwrite an edit
  /// in progress.
  bool menuOpen = false;

  String? formatError;
  PlaybackDecision? pendingDecision;
  PlaybackJobBrief? activeJob;
  PlaybackJobBrief? queueLeader;
  int queuePos = 0;

  Episode? nextEpisode;
  bool _nextChecked = false;
  bool _disposed = false;

  int get realSec => offset.inSeconds + position.inSeconds;
  int get effectiveSec => duration.inSeconds;

  bool get isBlocked =>
      pendingDecision != null ||
      formatError != null ||
      (activeJob != null && !activeJob!.isFinished);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---- lifecycle ----

  Future<void> init() async {
    _listen();
    await _open();
    _delayPollTimer = Timer.periodic(
        const Duration(seconds: 8), (_) => _loadSubtitleDelay());
  }

  void _listen() {
    _subs.add(player.position.listen((p) {
      position = p;
      _maybeLoadNext();
      _notify();
    }));
    _subs.add(player.duration.listen((d) {
      if (d > Duration.zero) duration = d;
      _notify();
    }));
    _subs.add(player.buffered.listen((b) {
      buffered = b;
      _notify();
    }));
    _subs.add(player.playing.listen((p) {
      playing = p;
      _notify();
    }));
    _subs.add(player.buffering.listen((b) {
      buffering = b;
      _notify();
    }));
  }

  @override
  void dispose() {
    _disposed = true;
    _progressTimer?.cancel();
    _jobPollTimer?.cancel();
    _delayPollTimer?.cancel();
    _delayCommitTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    saveProgress();
    player.dispose();
    super.dispose();
  }

  // ---- opening ----

  Future<void> _open() async {
    String? url;
    Duration startAt = Duration.zero;

    try {
      final ms =
          (await api.getSubtitleDelay(item.mediaKind, item.mediaId))
              .inMilliseconds;
      if (ms != (subDelaySec * 1000).round()) {
        subDelaySec = ms / 1000;
        _notify();
      }
    } catch (_) {}

    if (item.externalUrl != null && externalUrl != null) {
      url = externalUrl!;
    } else if (item.isLibraryItem) {
      try {
        for (final c in await api.continueWatching()) {
          if (c.mediaKind == item.mediaKind &&
              c.mediaId == item.mediaId &&
              c.position > 15) {
            startAt = Duration(seconds: c.position);
            break;
          }
        }
      } catch (_) {}

      final PlaybackDecision decision;
      try {
        decision = await api.playback(item.mediaKind, item.mediaId,
            client: kIsWeb ? 'web' : 'native');
      } catch (e) {
        formatError = 'Playback check failed ($e). Try again.';
        buffering = false;
        _notify();
        return;
      }

      switch (decision.decision) {
        case 'play':
          url = kIsWeb
              ? _webUrl(decision.url)
              : api.streamUrl(item.mediaKind, item.mediaId);
          pendingDecision = null;
          activeJob = null;
          formatError = null;
        case 'needs_quick_fix':
        case 'needs_encode':
          pendingDecision = decision;
          activeJob = null;
          formatError = null;
          buffering = false;
          _notify();
          return;
        case 'preparing':
          activeJob = decision.job;
          queueLeader = decision.activeJob;
          queuePos = decision.queuePos;
          pendingDecision = null;
          formatError = null;
          buffering = false;
          _notify();
          startJobPolling();
          return;
        default: // damaged | still_copying
          formatError = decision.reason.isNotEmpty
              ? decision.reason
              : (decision.decision == 'damaged'
                  ? 'This file is damaged and cannot be played.'
                  : 'Still being copied to the server. Try again shortly.');
          buffering = false;
          _notify();
          return;
      }
    } else {
      url = api.streamUrl(item.mediaKind, item.mediaId);
    }

    if (_disposed) return;
    loadTracks();

    if (kIsWeb) {
      offset = Duration.zero;
      try {
        await player.open(url);
        if (startAt.inSeconds > 15) await player.seek(startAt);
      } catch (_) {}
    } else {
      await player.open(url, startAt: startAt);
      offset = startAt;
      await loadTracks();
      await _applyPreferredAudio();
    }

    await player.play();
    await applyDelayLocally(subDelaySec);
    _progressTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => saveProgress());
  }

  String _webUrl(String path) {
    final u = Uri.parse('${api.baseUrl}$path');
    return u.replace(queryParameters: {
      ...u.queryParameters,
      'token': api.token ?? '',
    }).toString();
  }

  // ---- prepare jobs ----

  void startJobPolling() {
    _jobPollTimer?.cancel();
    _jobPollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final pf = await api.playback(item.mediaKind, item.mediaId,
            client: kIsWeb ? 'web' : 'native');
        if (_disposed) return;

        if (pf.decision == 'play') {
          _jobPollTimer?.cancel();
          await _open();
          return;
        }
        if (pf.job != null) {
          activeJob = pf.job;
          queueLeader = pf.activeJob;
          queuePos = pf.queuePos;
          _notify();
          if (pf.job!.isDone) {
            _jobPollTimer?.cancel();
            await _open();
          } else if (pf.job!.isFailed) {
            _jobPollTimer?.cancel();
            formatError = 'Preparation failed: ${pf.job!.error}';
            activeJob = null;
            _notify();
          }
        }
      } catch (_) {}
    });
  }

  /// Returns true when the job was scheduled for later, so the caller can
  /// leave the player.
  Future<bool> startPrepare(PlaybackDecision pf, String mode) async {
    final type = pf.decision == 'needs_encode' ? 'encode' : 'quick_fix';
    final job = await api.createJob(item.mediaKind, item.mediaId, type,
        mode: mode);
    pendingDecision = null;
    activeJob = job;
    _notify();
    if (mode == 'now') {
      startJobPolling();
      return false;
    }
    return true;
  }

  Future<void> pauseJob(int id) async {
    try {
      await api.pauseJob(id);
    } catch (_) {}
  }

  Future<void> resumeJob(int id) async {
    try {
      await api.resumeJob(id);
    } catch (_) {}
  }

  Future<void> cancelJob(int id) async {
    try {
      await api.cancelJob(id);
    } catch (_) {}
  }

  // ---- transport ----

  Future<void> togglePlay() => player.toggle();

  Future<void> seekTo(int targetSec) async {
    final rel = targetSec - offset.inSeconds;
    try {
      await player.seek(Duration(seconds: rel < 0 ? 0 : rel));
    } catch (_) {}
  }

  Future<void> saveProgress() async {
    if (item.mediaKind == 'external') return;
    final dur = effectiveSec;
    final pos = realSec;
    if (dur <= 0 || pos < 0) return;
    try {
      await api.saveProgress(
          item.mediaKind, item.mediaId, pos, dur, (pos / dur) > 0.9);
    } catch (_) {}
  }

  // ---- tracks ----

  Future<void> loadTracks() async {
    if (tracksLoaded || item.externalUrl != null) return;
    try {
      tracks = await api.tracks(item.mediaKind, item.mediaId);
      tracksLoaded = true;
      _notify();
      _selectEnglishByDefault(tracks);
    } catch (_) {
      tracksLoaded = true;
      _notify();
    }
  }

  /// Turns English subtitles on by default, preferring one that came out of
  /// the video file.
  ///
  /// A track muxed into the release was timed against that exact cut, so it
  /// cannot be out of sync; a downloaded .srt is a guess about which release
  /// you have. When both are present the embedded one wins.
  ///
  /// The server labels external tracks from the file name, so a track can
  /// arrive as "en", "eng", "en-US" *or* "English" - matching only the short
  /// codes is why English was never picked up for the SRTs in this library.
  void _selectEnglishByDefault(MediaTracks t) {
    if (activeSubtitle != null) return;
    final english = t.subtitles
        .where((s) => isEnglishTrack(s.language) || isEnglishTrack(s.name))
        .toList();
    if (english.isEmpty) return;
    final preferred = english.firstWhere((s) => s.embedded,
        orElse: () => english.first);
    selectSubtitle(preferred.index);
  }

  Future<void> _applyPreferredAudio() async {
    if (kIsWeb || tracks.audio.isEmpty) return;
    try {
      final me = await api.me();
      final pref = (me?.audioLang ?? 'eng').toLowerCase();
      for (final lang in [pref, 'eng', 'ara']) {
        for (final t in tracks.audio) {
          if (t.language.toLowerCase() == lang) {
            await selectAudio(t.index);
            return;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> selectAudio(int index) async {
    activeAudio = index;
    _notify();
    await player.setAudioTrack(index);
  }

  Future<void> selectSubtitle(int? index) async {
    activeSubtitle = index;
    if (index == null) {
      subtitleCues = [];
      _notify();
      await player.setSubtitle(null);
      return;
    }
    _notify();

    final url = api.subtitleUrl(item.mediaKind, item.mediaId, index);
    await player.setSubtitle(url);
    try {
      final res = await http.get(Uri.parse(url), headers: {
        if (api.token != null) 'Authorization': 'Bearer ${api.token}',
      });
      if (res.statusCode == 200 && !_disposed) {
        subtitleCues = SubtitleParser.parse(utf8.decode(res.bodyBytes));
        _notify();
      }
    } catch (_) {}
  }

  /// Re-reads the track list and the active subtitle, after the set of files
  /// beside the video has changed.
  Future<void> reloadTracks() async {
    tracksLoaded = false;
    await loadTracks();
    await reloadSubtitle();
  }

  /// Re-fetches the active subtitle after the server has rewritten the file,
  /// so the cues on screen match the corrected timings.
  Future<void> reloadSubtitle() async {
    final index = activeSubtitle;
    if (index == null) return;
    subtitleCues = [];
    _notify();
    await selectSubtitle(index);
  }

  // ---- subtitle timing ----

  /// Applies a delay to the local player only (mpv sub-delay on native; the
  /// web overlay shifts its own cues).
  Future<void> applyDelayLocally(double sec) async {
    if (kIsWeb) return;
    await player
        .setSubtitleDelay(Duration(milliseconds: (sec * 1000).round()));
  }

  void setDelay(double sec) {
    subDelaySec = sec;
    _notify();
    applyDelayLocally(sec);
    _delayCommitTimer?.cancel();
    _delayCommitTimer =
        Timer(const Duration(milliseconds: 500), commitDelay);
  }

  /// Takes a delay decided elsewhere (the server's auto-sync) as the current
  /// value, applying it locally without writing it back again.
  Future<void> adoptDelay(double sec) async {
    _delayCommitTimer?.cancel();
    subDelaySec = sec;
    _pendingDelayMs = (sec * 1000).round();
    await applyDelayLocally(sec);
    _notify();
  }

  Future<void> commitDelay() async {
    _delayCommitTimer?.cancel();
    final ms = (subDelaySec * 1000).round();
    _pendingDelayMs = ms;
    try {
      await api.updateSubtitleDelay(
          item.mediaKind, item.mediaId, Duration(milliseconds: ms));
    } catch (_) {}
    _pendingDelayMs = null;
  }

  /// Flushes an edit the user made but did not submit before closing a menu.
  void flushPendingDelay() {
    if (_delayCommitTimer?.isActive ?? false) {
      _delayCommitTimer!.cancel();
      commitDelay();
    }
  }

  /// Non-admins have no local control and always inherit the stored value.
  /// Skipped while a menu is open, and ignores reads that raced a local
  /// commit still in flight.
  Future<void> _loadSubtitleDelay() async {
    if (menuOpen) return;
    try {
      final ms =
          (await api.getSubtitleDelay(item.mediaKind, item.mediaId))
              .inMilliseconds;
      if (_disposed || menuOpen) return;
      if (_pendingDelayMs != null) {
        if (ms == _pendingDelayMs) _pendingDelayMs = null;
        return;
      }
      if (ms != (subDelaySec * 1000).round()) {
        subDelaySec = ms / 1000;
        await applyDelayLocally(subDelaySec);
        _notify();
      }
    } catch (_) {}
  }

  // ---- next episode ----

  /// Loads the following episode once the current one nears its end, so the
  /// player can offer a "next episode" shortcut.
  void _maybeLoadNext() {
    if (_nextChecked) return;
    if (item.mediaKind != 'episode' ||
        item.showId == null ||
        item.episode == null) {
      _nextChecked = true;
      return;
    }
    final eff = effectiveSec;
    if (eff <= 300 || realSec < eff - 300) return;
    _nextChecked = true;

    final curS = item.season ?? 0;
    final curE = item.episode!;
    () async {
      try {
        final eps = (await api.showDetail(item.showId!)).episodes;
        Episode? next;
        for (final e in eps) {
          if (e.season == curS && e.episode == curE + 1) {
            next = e;
            break;
          }
        }
        if (next == null) {
          final later = eps.map((e) => e.season).where((s) => s > curS).toSet();
          for (final s in later.toList()..sort()) {
            next = eps
                .where((e) => e.season == s && e.episode == 1)
                .firstOrNull;
            if (next != null) break;
          }
        }
        if (!_disposed && next != null) {
          nextEpisode = next;
          _notify();
        }
      } catch (_) {}
    }();
  }

  /// Whether a track label names English, in any of the spellings the
  /// scanner and OpenSubtitles produce.
  static bool isEnglishTrack(String label) {
    final v = label.trim().toLowerCase();
    if (v.isEmpty) return false;
    return v == 'en' ||
        v == 'eng' ||
        v == 'english' ||
        v.startsWith('en-') ||
        v.startsWith('en_') ||
        v.startsWith('english ');
  }

  bool get showNextEpisodeCue =>
      nextEpisode != null &&
      effectiveSec > 300 &&
      realSec >= effectiveSec - 300 &&
      !isBlocked;
}
