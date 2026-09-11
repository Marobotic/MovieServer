import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'sub_delay.dart';

/// Video playback built entirely on media_kit (libmpv). One code path across
/// Android, Windows, Linux AND web (mpv compiled to WebAssembly), so formats
/// like MKV and HEVC play everywhere - including in the browser.
abstract class PlaybackController {
  String get url;

  Stream<Duration> get position;
  Stream<Duration> get duration;
  Stream<bool> get buffering;
  Stream<bool> get playing;

  Widget buildSurface(BuildContext context);

  Future<void> open(String url, {Duration startAt});
  Future<void> play();
  Future<void> pause();
  Future<void> toggle();
  Future<void> seek(Duration position);

  /// Loads an external subtitle track; pass null to turn subtitles off.
  Future<void> setSubtitle(String? url, {String? language});

  /// Switches audio by stream index (0-based); null restores the default.
  Future<void> setAudioTrack(int? streamIndex);

  /// Shifts subtitle timing; positive delays subtitles, negative advances.
  Future<void> setSubtitleDelay(Duration delay);

  Future<void> dispose();
}

class NativePlaybackController implements PlaybackController {
  @override
  String url = '';

  final Player _player = Player();
  VideoController? _videoController;

  @override
  Widget buildSurface(BuildContext context) {
    _videoController ??= VideoController(_player);
    return Video(
      controller: _videoController!,
      controls: NoVideoControls,
      fit: BoxFit.contain,
    );
  }

  @override
  Stream<Duration> get position => _player.stream.position;

  @override
  Stream<Duration> get duration => _player.stream.duration;

  @override
  Stream<bool> get buffering => _player.stream.buffering;

  @override
  Stream<bool> get playing => _player.stream.playing;

  @override
  Future<void> open(String url, {Duration startAt = Duration.zero}) async {
    this.url = url;
    await _player.open(Media(url, start: startAt));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> toggle() => _player.playOrPause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSubtitle(String? url, {String? language}) async {
    if (kIsWeb) return;
    try {
      if (url == null) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        await _player.setSubtitleTrack(SubtitleTrack.uri(url, title: language));
      }
    } catch (_) {}
  }

  @override
  Future<void> setAudioTrack(int? streamIndex) async {
    if (kIsWeb) return;
    try {
      final avail = _player.state.tracks.audio;
      if (streamIndex == null || avail.isEmpty) {
        await _player.setAudioTrack(AudioTrack.no());
        return;
      }
      final t = avail[streamIndex.clamp(0, avail.length - 1)];
      await _player.setAudioTrack(t);
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    if (kIsWeb) return;
    await applySubtitleDelay(_player, delay);
  }

  @override
  Future<void> dispose() => _player.dispose();
}

PlaybackController createPlaybackController() => NativePlaybackController();