import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../api.dart';
import '../fullscreen.dart';
import '../keyboard.dart';
import '../models.dart';
import '../playback.dart';
import '../subtitles/overlay.dart';
import '../subtitles/parser.dart';
import '../subtitles/settings_sheet.dart';
import '../widgets/seek_bar.dart';

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
}

class WatchScreen extends StatefulWidget {
  final PlayableItem item;
  final String? externalUrl;

  const WatchScreen({super.key, required this.item, this.externalUrl});

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  late final PlaybackController _controller;
  late final Api _api;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  Duration _offset = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  Timer? _progressTimer;
  Timer? _jobPollTimer;
  Timer? _settingsTimer;
  final List<StreamSubscription> _subs = [];
  Duration _disposePos = Duration.zero;
  MediaTracks _tracks = const MediaTracks.empty();
  bool _tracksLoaded = false;
  int? _activeSubtitle;
  int? _activeAudio;
  double _subDelaySec = 0;
  String? _formatError;

  PlaybackDecision? _pendingDecision;
  PlaybackJobBrief? _activeJob;
  PlaybackJobBrief? _activeQueueJob;
  int _queuePos = 0;
  List<SubtitleCue> _subtitleCues = [];
  SubtitleStyle _subtitleStyle = const SubtitleStyle();

  final FocusNode _focusNode = FocusNode();
  bool _fullscreen = false;
  Episode? _nextEpisode;
  bool _nextChecked = false;
  void Function()? _webKeyUninstall;
  final TextEditingController _subDelayCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _api = context.read<Api>();
    _controller = createPlaybackController();
    _listen();
    _loadSubtitleStyle();
    _webKeyUninstall = installWebKeyHandler(_onWebKeyCode);
    _open();
    _settingsTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      await _loadGlobalDelay();
    });
  }

  /// Fetches the server-wide subtitle delay and applies it to the player.
  /// Non-admins have no local control; they always inherit this value.
  Future<void> _loadGlobalDelay() async {
    try {
      final s = await _api.getSettings();
      if (!mounted) return;
      final ms = s.subtitleDelay.inMilliseconds;
      if (ms != (_subDelaySec * 1000).round()) {
        if (kIsWeb) {
          setState(() => _subDelaySec = ms / 1000);
        } else {
          await _controller.setSubtitleDelay(Duration(milliseconds: ms));
          if (mounted) setState(() => _subDelaySec = ms / 1000);
        }
      }
    } catch (_) {}
  }

  bool _onWebKeyCode(String code) {
    switch (code) {
      case 'Space':
        _togglePlayPause();
        return true;
      case 'KeyF':
      case 'F11':
        _toggleFullscreen();
        return true;
      case 'ArrowRight':
        _seek(_realSec + 10);
        return true;
      case 'ArrowLeft':
        _seek(_realSec - 10);
        return true;
      case 'Escape':
        if (_fullscreen) {
          _toggleFullscreen();
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  Future<void> _loadSubtitleStyle() async {
    final style = await SubtitleStyle.loadFromPrefs();
    if (mounted) setState(() => _subtitleStyle = style);
  }

  Future<void> _open() async {
    final api = _api;
    String? url;
    Duration startAt = Duration.zero;
    final isLibrary =
        widget.item.mediaKind == 'movie' || widget.item.mediaKind == 'episode';

    try {
      final s = await api.getSettings();
      final ms = s.subtitleDelay.inMilliseconds;
      if (mounted && ms != (_subDelaySec * 1000).round()) {
        setState(() => _subDelaySec = ms / 1000);
      }
    } catch (_) {}

    if (widget.item.externalUrl != null && widget.externalUrl != null) {
      url = widget.externalUrl!;
    } else if (isLibrary) {
      try {
        final cont = await api.continueWatching();
        for (final c in cont) {
          if (c.mediaKind == widget.item.mediaKind &&
              c.mediaId == widget.item.mediaId &&
              c.position > 15) {
            startAt = Duration(seconds: c.position);
            break;
          }
        }
      } catch (_) {}

      PlaybackDecision? pf;
      try {
        pf = await api.playback(widget.item.mediaKind, widget.item.mediaId,
            client: kIsWeb ? 'web' : 'native');
      } catch (e) {
        if (mounted) {
          setState(() {
            _formatError = 'Playback check failed ($e). Try again.';
            _buffering = false;
          });
        }
        return;
      }

      final decision = pf;
      if (decision != null) {
        if (decision.decision == 'play') {
          url = kIsWeb
              ? _webUrl(decision.url)
              : api.streamUrl(widget.item.mediaKind, widget.item.mediaId);
          setState(() {
            _pendingDecision = null;
            _activeJob = null;
            _formatError = null;
          });
        } else if (decision.decision == 'needs_quick_fix' ||
            decision.decision == 'needs_encode') {
          setState(() {
            _pendingDecision = decision;
            _activeJob = null;
            _formatError = null;
            _buffering = false;
          });
          return;
        } else if (decision.decision == 'preparing') {
          setState(() {
            _activeJob = decision.job;
            _activeQueueJob = decision.activeJob;
            _queuePos = decision.queuePos;
            _pendingDecision = null;
            _formatError = null;
            _buffering = false;
          });
          _startJobPolling();
          return;
        } else {
          // damaged or still_copying
          setState(() {
            _formatError = decision.reason.isNotEmpty
                ? decision.reason
                : (decision.decision == 'damaged'
                    ? 'This file is damaged and cannot be played.'
                    : 'Still being copied to the server. Try again shortly.');
            _buffering = false;
          });
          return;
        }
      }
    } else {
      url = api.streamUrl(widget.item.mediaKind, widget.item.mediaId);
    }

    if (!mounted) return;
    _loadTracks();

    if (url == null) {
      setState(() {
        _formatError = 'No stream URL available.';
        _buffering = false;
      });
      return;
    }

    if (kIsWeb) {
      _offset = Duration.zero;
      try {
        await _controller.open(url);
        if (startAt.inSeconds > 15) {
          await _controller.seek(startAt);
        }
      } catch (_) {}
    } else {
      await _controller.open(url, startAt: startAt);
      _offset = startAt;
      await _loadTracks();
      _applyPreferredAudio();
    }

    await _controller.play();
    await _applyGlobalDelay(_subDelaySec);
    _startProgressTimer();
  }

  void _startJobPolling() {
    _jobPollTimer?.cancel();
    _jobPollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final pf = await _api.playback(
            widget.item.mediaKind, widget.item.mediaId,
            client: kIsWeb ? 'web' : 'native');
        if (!mounted) return;

        if (pf.decision == 'play') {
          _jobPollTimer?.cancel();
          _open();
          return;
        }

        if (pf.job != null) {
          setState(() {
            _activeJob = pf.job;
            _activeQueueJob = pf.activeJob;
            _queuePos = pf.queuePos;
          });
          if (pf.job!.isDone) {
            _jobPollTimer?.cancel();
            _open();
          } else if (pf.job!.isFailed) {
            _jobPollTimer?.cancel();
            setState(() {
              _formatError = 'Preparation failed: ${pf.job!.error}';
              _activeJob = null;
            });
          }
        }
      } catch (_) {}
    });
  }

  String _webUrl(String path) {
    final u = Uri.parse('${_api.baseUrl}$path');
    return u.replace(queryParameters: {
      ...u.queryParameters,
      'token': _api.token ?? ''
    }).toString();
  }

  Future<void> _startPrepare(PlaybackDecision pf, String mode) async {
    final type = pf.decision == 'needs_encode' ? 'encode' : 'quick_fix';
    try {
      final job = await _api.createJob(
        widget.item.mediaKind,
        widget.item.mediaId,
        type,
        mode: mode,
      );
      if (mounted) {
        setState(() {
          _pendingDecision = null;
          _activeJob = job;
        });
        if (mode == 'now') {
          _startJobPolling();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Scheduled for tonight.')),
          );
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start job: $e')),
        );
      }
    }
  }

  Future<void> _applyPreferredAudio() async {
    if (kIsWeb) return;
    if (_tracks.audio.isEmpty) return;
    try {
      final me = await _api.me();
      final pref = (me?.audioLang ?? 'eng').toLowerCase();
      AudioTrackInfo? chosen;
      for (final lang in [pref, 'eng', 'ara']) {
        for (final t in _tracks.audio) {
          if (t.language.toLowerCase() == lang) {
            chosen = t;
            break;
          }
        }
        if (chosen != null) break;
      }
      final track = chosen;
      if (track != null) {
        _controller.setAudioTrack(track.index);
        setState(() => _activeAudio = track.index);
      }
    } catch (_) {}
  }

  Future<void> _seek(int targetSec) async {
    final rel = targetSec - _offset.inSeconds;
    final target = Duration(seconds: rel < 0 ? 0 : rel);
    try {
      await _controller.seek(target);
    } catch (_) {}
  }

  Future<void> _loadTracks() async {
    if (_tracksLoaded || widget.item.externalUrl != null) return;
    try {
      final t = await _api.tracks(widget.item.mediaKind, widget.item.mediaId);
      if (mounted) {
        setState(() {
          _tracks = t;
          _tracksLoaded = true;
        });
        _selectEnglishByDefault(t);
      }
    } catch (_) {
      if (mounted) setState(() => _tracksLoaded = true);
    }
  }

  void _selectEnglishByDefault(MediaTracks tracks) {
    if (_activeSubtitle != null) return;
    SubtitleInfo? english;
    for (final subtitle in tracks.subtitles) {
      final language = subtitle.language.toLowerCase();
      if (language == 'en' || language == 'eng' || language.startsWith('en-')) {
        english = subtitle;
        break;
      }
    }
    if (english != null) {
      _selectSubtitle(
        english.index,
        _api.subtitleUrl(
            widget.item.mediaKind, widget.item.mediaId, english.index),
      );
    }
  }

  Future<void> _selectSubtitle(int? index, String? url) async {
    setState(() => _activeSubtitle = index);
    if (index == null || url == null) {
      setState(() => _subtitleCues = []);
      _controller.setSubtitle(null);
      return;
    }

    _controller.setSubtitle(url);
    try {
      final res = await http.get(Uri.parse(url), headers: {
        if (_api.token != null) 'Authorization': 'Bearer ${_api.token}',
      });
      if (res.statusCode == 200) {
        final cues = SubtitleParser.parse(utf8.decode(res.bodyBytes));
        if (mounted) {
          setState(() => _subtitleCues = cues);
        }
      }
    } catch (_) {}
  }

  void _openTrackSheet() {
    _scheduleHide();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F1F1F),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.55,
            ),
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text('Subtitles',
                    style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ),
              ListTile(
                leading: const Icon(Icons.subtitles_off, color: Colors.white),
                title: const Text('Off', style: TextStyle(color: Colors.white)),
                trailing: _activeSubtitle == null
                    ? const Icon(Icons.check, color: Color(0xFFE50914))
                    : null,
                onTap: () {
                  _selectSubtitle(null, null);
                  Navigator.of(sheetCtx).pop();
                },
              ),
              if (_tracksLoaded && _tracks.subtitles.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text('No external subtitles found',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ),
              ..._tracks.subtitles.map((s) => ListTile(
                    leading: const Icon(Icons.subtitles, color: Colors.white70),
                    title: Text(s.name,
                        style: const TextStyle(color: Colors.white)),
                    subtitle: s.language.isNotEmpty
                        ? Text(s.language,
                            style: const TextStyle(color: Colors.white38))
                        : null,
                    trailing: _activeSubtitle == s.index
                        ? const Icon(Icons.check, color: Color(0xFFE50914))
                        : null,
                    onTap: () {
                      final url = _api.subtitleUrl(
                          widget.item.mediaKind, widget.item.mediaId, s.index);
                      _selectSubtitle(s.index, url);
                      Navigator.of(sheetCtx).pop();
                    },
                  )),
              const Divider(
                  color: Colors.white12, height: 24, indent: 20, endIndent: 20),
              ListTile(
                leading: const Icon(Icons.format_paint, color: Colors.white70),
                title: const Text('Subtitle appearance',
                    style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                    'Font, size, colors, background and position',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                dense: true,
                visualDensity: VisualDensity.compact,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _openSubtitleSettings();
                },
              ),
              if (_api.user?.isAdmin ?? false) ...[
                const Divider(
                    color: Colors.white12,
                    height: 16,
                    indent: 20,
                    endIndent: 20),
                _buildAdminDelayControl(setSheetState),
              ],
              const Divider(
                  color: Colors.white12, height: 24, indent: 20, endIndent: 20),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text('Audio',
                    style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5)),
              ),
              if (_tracksLoaded && _tracks.audio.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text('Single audio track',
                      style: TextStyle(color: Colors.white38, fontSize: 13)),
                ),
              ..._tracks.audio.map((a) => ListTile(
                    leading: const Icon(Icons.volume_up, color: Colors.white70),
                    title: Text(a.label,
                        style: const TextStyle(color: Colors.white)),
                    subtitle: Text(a.language,
                        style: const TextStyle(color: Colors.white38)),
                    trailing: _activeAudio == a.index
                        ? const Icon(Icons.check, color: Color(0xFFE50914))
                        : null,
                    onTap: () {
                      _controller.setAudioTrack(a.index);
                      setState(() => _activeAudio = a.index);
                      Navigator.of(sheetCtx).pop();
                    },
                  )),
              const SizedBox(height: 8),
              ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAdminDelayControl(void Function(void Function()) setSheetState) {
    _subDelayCtl.text = _subDelaySec.toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 8, bottom: 2),
            child: Text('Subtitle delay (global)',
                style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    letterSpacing: 0.5)),
          ),
          Row(
            children: [
              const Icon(Icons.slow_motion_video,
                  color: Colors.white54, size: 20),
              Expanded(
                child: Slider(
                  min: -600,
                  max: 600,
                  divisions: 24000,
                  value: _subDelaySec.clamp(-600.0, 600.0),
                  activeColor: const Color(0xFFE50914),
                  onChanged: (v) {
                    _subDelaySec = v;
                    setSheetState(() {});
                    setState(() {});
                    _applyGlobalDelay(_subDelaySec);
                  },
                  onChangeEnd: (_) => _commitGlobalDelay(),
                ),
              ),
              SizedBox(
                width: 86,
                child: TextField(
                  controller: _subDelayCtl,
                  keyboardType: const TextInputType.numberWithOptions(
                      signed: true, decimal: true),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    suffixText: 's',
                    suffixStyle: TextStyle(color: Colors.white38),
                  ),
                  textAlign: TextAlign.right,
                  onSubmitted: (txt) {
                    final v = double.tryParse(txt);
                    if (v == null) return;
                    _subDelaySec = v;
                    setSheetState(() {});
                    setState(() {});
                    _applyGlobalDelay(v);
                    _commitGlobalDelay();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Applies the delay to the local player (mpv sub-delay on native, overlay
  /// position shift on web) without touching the server yet.
  Future<void> _applyGlobalDelay(double sec) async {
    if (kIsWeb) return;
    await _controller.setSubtitleDelay(
        Duration(milliseconds: (sec * 1000).round()));
  }

  Future<void> _commitGlobalDelay() async {
    try {
      await _api.updateSubtitleDelay(
          Duration(milliseconds: (_subDelaySec * 1000).round()));
    } catch (_) {}
  }

  void _openSubtitleSettings() {
    _scheduleHide();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SubtitleSettingsSheet(
        initialStyle: _subtitleStyle,
        onStyleChanged: (style) {
          if (mounted) setState(() => _subtitleStyle = style);
        },
      ),
    );
  }

  void _listen() {
    _subs.add(_controller.position.listen((p) {
      _position = p;
      _disposePos = p;
      _maybeLoadNext();
      if (mounted) setState(() {});
    }));
    _subs.add(_controller.duration.listen((d) {
      if (d > Duration.zero) _duration = d;
      if (mounted) setState(() {});
    }));
    _subs.add(_controller.playing.listen((p) {
      _playing = p;
      if (mounted) setState(() {});
    }));
    _subs.add(_controller.buffering.listen((b) {
      _buffering = b;
      if (mounted) setState(() {});
    }));
  }

  void _startProgressTimer() {
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) => _save());
  }

  Future<void> _save() async {
    if (widget.item.mediaKind == 'external') return;
    final dur = _effectiveSec;
    final pos = _offset.inSeconds + _disposePos.inSeconds;
    if (dur <= 0 || pos < 0) return;
    final done = dur > 0 && (pos / dur) > 0.9;
    try {
      await _api.saveProgress(
        widget.item.mediaKind,
        widget.item.mediaId,
        pos,
        dur,
        done,
      );
    } catch (_) {}
  }

  void _togglePlayPause() {
    if (_pendingDecision != null || _activeJob != null) return;
    if (_formatError != null) return;
    FocusScope.of(context).requestFocus(_focusNode);
    setState(() => _controlsVisible = true);
    _scheduleHide();
    _controller.toggle();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (kIsWeb) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent || event is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _togglePlayPause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
      case LogicalKeyboardKey.f11:
        _toggleFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _seek(_realSec + 10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _seek(_realSec - 10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_fullscreen) {
          _toggleFullscreen();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  // Loads the following episode once when the current one nears its end so
  // the watch screen can offer a "play next" shortcut for shows.
  void _maybeLoadNext() {
    if (_nextChecked) return;
    if (widget.item.mediaKind != 'episode' ||
        widget.item.showId == null ||
        widget.item.episode == null) {
      _nextChecked = true;
      return;
    }
    final eff = _effectiveSec;
    if (eff <= 300 || _realSec < eff - 300) return;
    _nextChecked = true;
    final showId = widget.item.showId!;
    final curS = widget.item.season ?? 0;
    final curE = widget.item.episode!;
    () async {
      try {
        final det = await _api.showDetail(showId);
        final eps = det.episodes;
        Episode? next;
        for (final e in eps) {
          if (e.season == curS && e.episode == curE + 1) {
            next = e;
            break;
          }
        }
        if (next == null) {
          final laterSeasons = <int>{};
          for (final e in eps) {
            if (e.season > curS) laterSeasons.add(e.season);
          }
          final sorted = laterSeasons.toList()..sort();
          for (final s in sorted) {
            next = eps.where((e) => e.season == s && e.episode == 1).firstOrNull;
            if (next != null) break;
          }
        }
        if (mounted && next != null) setState(() => _nextEpisode = next);
      } catch (_) {}
    }();
  }

  void _openNextEpisode() {
    final next = _nextEpisode;
    if (next == null) return;
    _scheduleHide();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => WatchScreen(
          item: PlayableItem(
            mediaKind: 'episode',
            mediaId: next.id,
            title:
                '${next.showTitle} S${next.season.toString().padLeft(2, '0')}E${next.episode.toString().padLeft(2, '0')}',
            showId: next.showId,
            season: next.season,
            episode: next.episode,
          ),
        ),
      ),
    );
  }

  Future<void> _toggleFullscreen() async {
    FocusScope.of(context).requestFocus(_focusNode);
    if (kIsWeb) {
      final active = await toggleBrowserFullscreen();
      if (mounted) setState(() => _fullscreen = active);
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      if (!_fullscreen) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
      if (mounted) setState(() => _fullscreen = !_fullscreen);
      return;
    }
    // Desktop: cover the window with the same player skin.
    if (!_fullscreen) {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            body: Focus(
              autofocus: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _controller.toggle(),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: _controller.buildSurface(context),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: Align(
                          alignment: Alignment.topRight,
                          child: IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.fullscreen_exit),
                            onPressed: () => Navigator.of(context).pop(true),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      if (mounted && ok == true) setState(() => _fullscreen = false);
      return;
    }
    if (mounted) setState(() => _fullscreen = false);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_controlsVisible) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  int get _effectiveSec => _duration.inSeconds;
  int get _realSec => _offset.inSeconds + _position.inSeconds;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _webKeyUninstall?.call();
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _jobPollTimer?.cancel();
    _settingsTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _save();
    _subDelayCtl.dispose();
    _controller.dispose();
    super.dispose();
  }

  Widget _buildPreparePrompt(PlaybackDecision pf) {
    final est = pf.estimate;
    final workerStr = est?.worker == 'gpu' ? 'GPU encode' : 'one CPU core';
    final timeStr = est != null
        ? 'About ${est.minutes} min, $workerStr${est.sizeGB != null ? ', ~${est.sizeGB} GB' : ''}'
        : '';
    final isAdmin = _api.user?.isAdmin ?? false;

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
          boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 16)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_fix_high, color: Color(0xFFE50914), size: 48),
            const SizedBox(height: 16),
            Text(
              pf.title.isNotEmpty ? pf.title : widget.item.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              pf.reason.isNotEmpty
                  ? pf.reason
                  : 'Needs preparation for browser playback.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            if (timeStr.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                timeStr,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
            const SizedBox(height: 24),
            if (isAdmin)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE50914),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                    ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Prepare now'),
                    onPressed: () => _startPrepare(pf, 'now'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                    onPressed: () => _startPrepare(pf, 'idle'),
                    child: const Text('Tonight'),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white54)),
                  ),
                ],
              )
            else
              Column(
                children: [
                  const Text(
                    'Not ready on this device yet. Maro has been asked to prepare it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Back'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(PlaybackJobBrief job) {
    final statusText = switch (job.status) {
      'running' => 'Preparing for web (${job.worker.toUpperCase()})...',
      'paused_gaming' => 'Paused while you\'re gaming',
      'paused' => 'Paused',
      'queued' => 'Queued...',
      'done' => 'Ready to play!',
      'failed' => 'Failed: ${job.error}',
      _ => job.status,
    };

    final isGaming = job.status == 'paused_gaming';
    final isAdmin = _api.user?.isAdmin ?? false;
    final queuedBehind =
        job.isQueued && _activeQueueJob != null && _queuePos > 1;

    // The percent/speed/eta shown come from whatever job is actually burning
    // the CPU: this item's own job when it's running, or the job at the front
    // of the line while we're queued behind it.
    final liveJob = queuedBehind ? _activeQueueJob! : job;
    final displayPercent = liveJob.percent;
    final displaySpeed = liveJob.speed;
    final displayEta = liveJob.etaSec;

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isGaming ? Colors.amber.withAlpha(100) : Colors.white12),
          boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 16)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  isGaming ? Icons.sports_esports : Icons.hourglass_top,
                  color: isGaming ? Colors.amber : const Color(0xFFE50914),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    job.title.isNotEmpty ? job.title : widget.item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isGaming
                        ? Colors.amber.withAlpha(50)
                        : const Color(0xFFE50914).withAlpha(50),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${displayPercent.toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: isGaming ? Colors.amber : const Color(0xFFE50914),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (displayPercent / 100).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: Colors.white12,
                color: isGaming ? Colors.amber : const Color(0xFFE50914),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: isGaming ? Colors.amber : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
                Text(
                  [
                    if (displaySpeed > 0) '${displaySpeed.toStringAsFixed(1)}x',
                    if (displayEta > 0) '${(displayEta / 60).ceil()}m left',
                  ].join(' · '),
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
            if (queuedBehind) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'You are #$_queuePos in line. Preparing '
                      '${_activeQueueJob!.title.isEmpty ? 'another item' : _activeQueueJob!.title} first...',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            if (isAdmin)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (job.isRunning)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70),
                      onPressed: () => _api.pauseJob(job.id),
                      child: const Text('Pause'),
                    )
                  else if (job.isPaused)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70),
                      onPressed: () => _api.resumeJob(job.id),
                      child: const Text('Resume'),
                    ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      await _api.cancelJob(job.id);
                      if (mounted) Navigator.of(context).pop();
                    },
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white54)),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _togglePlayPause,
          child: Stack(
            children: [
            // Video Surface
            Positioned.fill(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _controller.buildSurface(context),
                ),
              ),
            ),

            // Buffering Indicator
            if (_buffering &&
                _position == Duration.zero &&
                _pendingDecision == null &&
                _activeJob == null &&
                _formatError == null)
              const Center(
                  child: CircularProgressIndicator(color: Colors.white)),

            // Prepare Prompt Dialog
            if (_pendingDecision != null)
              Positioned.fill(
                  child: Container(
                      color: Colors.black87,
                      child: _buildPreparePrompt(_pendingDecision!))),

            // Real-time Progress Card
            if (_activeJob != null && !_activeJob!.isFinished)
              Positioned.fill(
                  child: Container(
                      color: Colors.black87,
                      child: _buildProgressCard(_activeJob!))),

            // Error Screen
            if (_formatError != null &&
                _pendingDecision == null &&
                _activeJob == null)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.highlight_off,
                            color: Color(0xFFE50914), size: 56),
                        const SizedBox(height: 16),
                        const Text('Cannot Play',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(_formatError!,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 14),
                            textAlign: TextAlign.center),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Back'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Controls Overlay
            if (_controlsVisible &&
                _pendingDecision == null &&
                (_activeJob == null || _activeJob!.isFinished) &&
                _formatError == null) ...[
              // Top Bar
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: const Color(0xCC000000),
                  padding: const EdgeInsets.only(top: 24, bottom: 12),
                  child: Row(
                    children: [
                      IconButton(
                        color: Colors.white,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          widget.item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom Bar
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: const Color(0xCC000000),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Custom SeekBar with hover peek
                      SeekBar(
                        position: Duration(seconds: _realSec),
                        duration: Duration(seconds: _effectiveSec),
                        buffered: _buffered,
                        trickplayUrl:
                            '${_api.baseUrl}/api/${widget.item.mediaKind == 'movie' ? 'movies' : 'episodes'}/${widget.item.mediaId}/trickplay',
                        token: _api.token,
                        onSeek: (target) => _seek(target.inSeconds),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.replay_10),
                            onPressed: () => _seek(_realSec - 10),
                          ),
                          IconButton(
                            color: Colors.white,
                            iconSize: 40,
                            icon: Icon(_playing
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill),
                            onPressed: _togglePlayPause,
                          ),
                          IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.forward_10),
                            onPressed: () => _seek(_realSec + 10),
                          ),
                          IconButton(
                            color: _activeSubtitle != null
                                ? const Color(0xFFE50914)
                                : Colors.white,
                            icon: const Icon(Icons.subtitles),
                            onPressed:
                                _tracksLoaded && _tracks.subtitles.isNotEmpty
                                    ? _openTrackSheet
                                    : null,
                          ),
                          IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.settings_voice),
                            onPressed: _tracksLoaded && _tracks.audio.length > 1
                                ? _openTrackSheet
                                : null,
                          ),
                          const Spacer(),
                          IconButton(
                            color: Colors.white,
                            icon: Icon(_fullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen),
                            onPressed: _toggleFullscreen,
                            tooltip: 'Fullscreen (F)',
                          ),
                          Text(
                            '${_fmt(Duration(seconds: _realSec))} / ${_fmt(Duration(seconds: _effectiveSec))}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],

            // Next-episode shortcut for shows near the end of an episode.
            if (_nextEpisode != null &&
                _effectiveSec > 300 &&
                _realSec >= _effectiveSec - 300 &&
                _formatError == null &&
                _pendingDecision == null &&
                (_activeJob == null || _activeJob!.isFinished))
              Positioned(
                bottom: 96,
                right: 24,
                child: Material(
                  color: const Color(0xE6E50914),
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: _openNextEpisode,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.skip_next, color: Colors.white, size: 22),
                          SizedBox(width: 8),
                          Text('Next episode',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            if (kIsWeb)
              Positioned.fill(
                child: SubtitleOverlay(
                  cues: _subtitleCues,
                  position: Duration(seconds: _realSec),
                  delay: Duration(milliseconds: (_subDelaySec * 1000).round()),
                  style: _subtitleStyle,
                  showPositionGuide: _controlsVisible,
                  onPositionChanged: (offset) {
                    final style =
                        _subtitleStyle.copyWith(bottomOffset: offset);
                    setState(() => _subtitleStyle = style);
                    style.saveToPrefs();
                  },
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }
}
