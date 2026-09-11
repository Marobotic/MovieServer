import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../models.dart';
import '../playback.dart';

class PlayableItem {
  final String mediaKind; // movie | episode | external
  final int mediaId;
  final String title;
  final String? externalUrl;

  const PlayableItem({
    required this.mediaKind,
    required this.mediaId,
    required this.title,
    this.externalUrl,
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
  Duration _offset = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  Timer? _progressTimer;
  final List<StreamSubscription> _subs = [];
  Duration _disposePos = Duration.zero;
  MediaTracks _tracks = const MediaTracks.empty();
  bool _tracksLoaded = false;
  int? _activeSubtitle;
  int? _activeAudio;
  double _subDelaySec = 0;
  String? _formatError;

  @override
  void initState() {
    super.initState();
    _api = context.read<Api>();
    _controller = createPlaybackController();
    _listen();
    _open();
  }

  Future<void> _open() async {
    final api = _api;
    String? url;
    Duration startAt = Duration.zero;
    String? blockReason;
    final isLibrary = widget.item.mediaKind == 'movie' ||
        widget.item.mediaKind == 'episode';
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
        blockReason = 'Playback check failed ($e). Try again.';
      }
      if (pf != null) {
        if (pf.decision == 'play') {
          if (kIsWeb) {
            url = _webUrl(pf.url);
          } else {
            url = api.streamUrl(widget.item.mediaKind, widget.item.mediaId);
          }
        } else {
          blockReason = _playbackBlockMessage(pf);
        }
      }
    } else {
      url = api.streamUrl(widget.item.mediaKind, widget.item.mediaId);
    }
    if (url == null && blockReason == null) {
      blockReason = 'Playback check unavailable. Try again.';
    }
    if (!mounted) return;
    _loadTracks();
    if (blockReason != null) {
      setState(() {
        _formatError = blockReason;
        _buffering = false;
      });
      return;
    }
    if (kIsWeb) {
      _offset = Duration.zero;
      try {
        await _controller.open(url!);
        if (startAt.inSeconds > 15) {
          await _controller.seek(startAt);
        }
      } catch (_) {}
    } else {
      await _controller.open(url!, startAt: startAt);
      _offset = startAt;
      await _loadTracks();
      _applyPreferredAudio();
    }
    await _controller.play();
    _startProgressTimer();
  }

  // Server paths come back without a token; the <video> element needs one.
  String _webUrl(String path) {
    final u = Uri.parse('${_api.baseUrl}$path');
    return u
        .replace(queryParameters: {...u.queryParameters, 'token': _api.token ?? ''})
        .toString();
  }

  String _playbackBlockMessage(PlaybackDecision pf) {
    if (pf.decision == 'damaged' || pf.decision == 'still_copying') {
      if (pf.reason.isNotEmpty) return pf.reason;
      return pf.decision == 'damaged'
          ? 'This file is damaged and cannot be played.'
          : 'Still being copied to the server. Try again in a few minutes.';
    }
    final est = pf.estimate;
    final detail = est == null
        ? ''
        : 'About ${est.minutes} min, '
            '${est.worker == 'gpu' ? 'GPU encode' : 'one CPU core'}'
            '${est.sizeGB != null ? ', about ${est.sizeGB} GB' : ''}.';
    if (_api.user?.isAdmin ?? false) {
      return '${pf.title} can\'t play in the browser as it is.\n${pf.reason}\n$detail';
    }
    _askMaro();
    return 'Not ready on this device yet. Maro has been asked to prepare it.\n${pf.reason}';
  }

  Future<void> _askMaro() async {
    try {
      await _api.createRequest(
          'prepare', widget.item.title, 0, 'Prepare for web browser', 0);
    } catch (_) {}
  }

  // Native players pick the audio stream by the profile's preferred language
  // (default eng) instead of defaulting to whatever stream is first in the
  // file (e.g. an Italian dub).
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

  // Seeking works natively for direct file playback on every platform. The
  // resume offset only applies to native players (started via startAt).
  Future<void> _seek(int targetSec) async {
    setState(() => _buffering = true);
    final rel = targetSec - _offset.inSeconds;
    final target = Duration(seconds: rel < 0 ? 0 : rel);
    try {
      await _controller.seek(target);
    } catch (_) {}
    if (mounted) {
      setState(() => _buffering = false);
    }
  }

  Future<void> _loadTracks() async {
    if (_tracksLoaded || widget.item.externalUrl != null) return;
    final api = context.read<Api>();
    try {
      final t = await api.tracks(widget.item.mediaKind, widget.item.mediaId);
      setState(() {
        _tracks = t;
        _tracksLoaded = true;
      });
    } catch (_) {
      setState(() => _tracksLoaded = true);
    }
  }

  void _openTrackSheet() {
    _scheduleHide();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F1F1F),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
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
              onTap: () async {
                _controller.setSubtitle(null);
                setState(() => _activeSubtitle = null);
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
                  title:
                      Text(s.name, style: const TextStyle(color: Colors.white)),
                  subtitle: s.language.isNotEmpty
                      ? Text(s.language,
                          style: const TextStyle(color: Colors.white38))
                      : null,
                  trailing: _activeSubtitle == s.index
                      ? const Icon(Icons.check, color: Color(0xFFE50914))
                      : null,
                  onTap: () async {
                    final api = context.read<Api>();
                    _controller.setSubtitle(
                        api.subtitleUrl(widget.item.mediaKind,
                            widget.item.mediaId, s.index),
                        language: s.language.isEmpty ? s.name : s.language);
                    setState(() => _activeSubtitle = s.index);
                    Navigator.of(sheetCtx).pop();
                  },
                )),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text('Subtitle delay',
                  style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Row(
                children: [
                  const Icon(Icons.slow_motion_video,
                      color: Colors.white54, size: 20),
                  Expanded(
                    child: Slider(
                      min: -10,
                      max: 10,
                      divisions: 400,
                      value: _subDelaySec.clamp(-10.0, 10.0),
                      activeColor: const Color(0xFFE50914),
                      onChanged: (v) {
                        setState(() => _subDelaySec = v);
                      },
                      onChangeEnd: (v) {
                        _controller.setSubtitleDelay(
                            Duration(milliseconds: (v * 1000).round()));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 54,
                    child: Text(
                      '${_subDelaySec >= 0 ? '+' : ''}${_subDelaySec.toStringAsFixed(1)}s',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(
                color: Colors.white12, height: 24, indent: 20, endIndent: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
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
                  onTap: () async {
                    _controller.setAudioTrack(a.index);
                    setState(() => _activeAudio = a.index);
                    Navigator.of(sheetCtx).pop();
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _listen() {
    _subs.add(_controller.position.listen((p) {
      _position = p;
      _disposePos = p;
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

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_controlsVisible) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  int get _effectiveSec => _duration.inSeconds;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _save();
    _controller.dispose();
    super.dispose();
  }

  int get _realSec => _offset.inSeconds + _position.inSeconds;

  @override
  Widget build(BuildContext context) {
    final progress =
        _effectiveSec > 0 ? (_realSec / _effectiveSec).clamp(0.0, 1.0) : 0.0;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
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
            if (_buffering && _position == Duration.zero)
              const Center(
                  child: CircularProgressIndicator(color: Colors.white)),
            if (_formatError != null)
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
                        const Text('Format not supported',
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
            if (_controlsVisible) ...[
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
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: const Color(0xCC000000),
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Slider(
                        value: progress,
                        activeColor: const Color(0xFFE50914),
                        inactiveColor: Colors.white38,
                        onChanged: (v) {
                          setState(() {});
                        },
                        onChangeEnd: (v) {
                          final target = (v * _effectiveSec).round();
                          _seek(target);
                        },
                      ),
                      Row(
                        children: [
                          IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.replay_10),
                            onPressed: () {
                              _seek(_realSec - 10);
                            },
                          ),
                          IconButton(
                            color: Colors.white,
                            iconSize: 40,
                            icon: Icon(_playing
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill),
                            onPressed: () async {
                              _controller.toggle();
                              if (_playing) {
                                _scheduleHide();
                              }
                            },
                          ),
                          IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.forward_10),
                            onPressed: () {
                              _seek(_realSec + 10);
                            },
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
          ],
        ),
      ),
    );
  }
}
