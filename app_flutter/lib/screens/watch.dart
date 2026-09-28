import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../fullscreen.dart';
import '../keyboard.dart';
import '../models.dart';
import '../subtitles/overlay.dart';
import '../theme/breakpoints.dart';
import '../theme/tokens.dart';
import '../widgets/toast.dart';
import 'player/player_controls.dart';
import 'player/prepare_gate.dart';
import 'player/subtitle_panel.dart';
import 'player/watch_controller.dart';

export 'player/watch_controller.dart' show PlayableItem;

class WatchScreen extends StatefulWidget {
  final PlayableItem item;
  final String? externalUrl;

  const WatchScreen({super.key, required this.item, this.externalUrl});

  @override
  State<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends State<WatchScreen> {
  late final WatchController _c;
  final FocusNode _focusNode = FocusNode();

  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _panelOpen = false;
  Timer? _hideTimer;
  void Function()? _webKeyUninstall;

  SubtitleStyle _subtitleStyle = const SubtitleStyle();
  bool _autoSyncBusy = false;
  bool _findBusy = false;

  @override
  void initState() {
    super.initState();
    _c = WatchController(
      api: context.read<Api>(),
      item: widget.item,
      externalUrl: widget.externalUrl,
    )..addListener(_onControllerChange);
    _loadSubtitleStyle();
    _webKeyUninstall = installWebKeyHandler(_onWebKeyCode);
    _c.init();
    _scheduleHide();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSubtitleStyle() async {
    final style = await SubtitleStyle.loadFromPrefs();
    if (mounted) setState(() => _subtitleStyle = style);
  }

  @override
  void dispose() {
    _webKeyUninstall?.call();
    _hideTimer?.cancel();
    _c.removeListener(_onControllerChange);
    _c.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ---- chrome visibility ----

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_panelOpen) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _c.playing && !_panelOpen) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _onSurfaceTap() {
    if (_panelOpen) {
      _closeMenu();
      return;
    }
    if (_c.isBlocked) return;
    _showControls();
    _c.togglePlay();
  }

  // ---- menus ----

  void _openMenu() {
    setState(() {
      _panelOpen = true;
      _controlsVisible = true;
    });
    _c.menuOpen = true;
    _hideTimer?.cancel();
  }

  void _closeMenu() {
    if (!_panelOpen) return;
    setState(() => _panelOpen = false);
    _c.menuOpen = false;
    _c.flushPendingDelay();
    _scheduleHide();
  }

  void _toggleTrackMenu() {
    if (_panelOpen) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  // ---- keyboard ----

  bool _onWebKeyCode(String code) {
    switch (code) {
      case 'Space':
        _showControls();
        _c.togglePlay();
        return true;
      case 'KeyF':
      case 'F11':
        _toggleFullscreen();
        return true;
      case 'ArrowRight':
        _showControls();
        _c.seekTo(_c.realSec + 10);
        return true;
      case 'ArrowLeft':
        _showControls();
        _c.seekTo(_c.realSec - 10);
        return true;
      case 'Escape':
        if (_panelOpen) {
          _closeMenu();
          return true;
        }
        if (_fullscreen) {
          _toggleFullscreen();
          return true;
        }
        return false;
      default:
        return false;
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (kIsWeb) return KeyEventResult.ignored;
    if (event is! KeyDownEvent || event is KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _showControls();
        _c.togglePlay();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
      case LogicalKeyboardKey.f11:
        _toggleFullscreen();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _showControls();
        _c.seekTo(_c.realSec + 10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _showControls();
        _c.seekTo(_c.realSec - 10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_panelOpen) {
          _closeMenu();
          return KeyEventResult.handled;
        }
        if (_fullscreen) {
          _toggleFullscreen();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  // ---- fullscreen ----

  Future<void> _toggleFullscreen() async {
    _focusNode.requestFocus();
    if (kIsWeb) {
      final active = await toggleBrowserFullscreen();
      if (mounted) setState(() => _fullscreen = active);
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      await SystemChrome.setEnabledSystemUIMode(
          _fullscreen ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
      if (mounted) setState(() => _fullscreen = !_fullscreen);
      return;
    }
    // Desktop: the player already fills the window; just drop the chrome the
    // rest of the app draws around it.
    await SystemChrome.setEnabledSystemUIMode(
        _fullscreen ? SystemUiMode.edgeToEdge : SystemUiMode.immersive);
    if (mounted) setState(() => _fullscreen = !_fullscreen);
  }

  // ---- actions ----

  Future<void> _prepare(PlaybackDecision pf, String mode) async {
    final navigator = Navigator.of(context);
    try {
      final scheduled = await _c.startPrepare(pf, mode);
      if (!mounted) return;
      if (scheduled) {
        Toast.show(context, 'Scheduled for tonight.', kind: ToastKind.success);
        navigator.pop();
      }
    } catch (e) {
      if (mounted) {
        Toast.show(context, 'Could not start: $e', kind: ToastKind.error);
      }
    }
  }

  /// Asks the server to measure the drift between the selected subtitle and
  /// the audio, then reflects whatever it decided in the slider.
  Future<void> _autoSync() async {
    final index = _c.activeSubtitle ?? 0;
    if (_c.tracks.subtitles.isEmpty) return;
    setState(() => _autoSyncBusy = true);
    try {
      final res = await _c.api.syncSubtitles(
          widget.item.mediaKind, widget.item.mediaId, index);
      if (!mounted) return;
      if (res.applied && !res.rewroteFile) {
        await _c.adoptDelay(res.offsetMs / 1000);
      } else if (res.rewroteFile) {
        // The file itself was corrected, so any stored delay is now zero and
        // the cues on screen have to be re-read.
        await _c.adoptDelay(0);
        await _c.reloadSubtitle();
      }
      if (!mounted) return;
      Toast.show(
        context,
        res.message,
        kind: res.applied
            ? ToastKind.success
            : (res.rewroteFile ? ToastKind.info : ToastKind.warning),
        actionLabel: res.rewroteFile ? 'Undo' : null,
        onAction: res.rewroteFile ? () => _restoreSubtitle(index) : null,
      );
    } catch (e) {
      if (mounted) {
        Toast.show(context, 'Auto-sync failed: $e', kind: ToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _autoSyncBusy = false);
    }
  }

  /// Puts back the subtitle file a rewrite set aside.
  Future<void> _restoreSubtitle(int index) async {
    try {
      await _c.api
          .restoreSubtitles(widget.item.mediaKind, widget.item.mediaId, index);
      await _c.adoptDelay(0);
      await _c.reloadSubtitle();
      if (mounted) {
        Toast.show(context, 'Original subtitle restored.',
            kind: ToastKind.success);
      }
    } catch (e) {
      if (mounted) {
        Toast.show(context, 'Could not restore: $e', kind: ToastKind.error);
      }
    }
  }

  /// Fetches a subtitle that was timed for this exact release, rather than
  /// trying to bend the current one into place.
  Future<void> _findBetterSubtitle() async {
    final index = _c.activeSubtitle ?? 0;
    setState(() => _findBusy = true);
    try {
      final res = await _c.api.findSubtitles(
          widget.item.mediaKind, widget.item.mediaId, index);
      if (!mounted) return;
      if (res.applied) {
        await _c.adoptDelay(0);
        await _c.reloadSubtitle();
      }
      if (!mounted) return;
      Toast.show(
        context,
        res.message,
        kind: res.applied ? ToastKind.success : ToastKind.warning,
        actionLabel: res.applied ? 'Undo' : null,
        onAction: res.applied ? () => _restoreSubtitle(index) : null,
      );
    } catch (e) {
      if (mounted) {
        Toast.show(context, 'Subtitle search failed: $e', kind: ToastKind.error);
      }
    } finally {
      if (mounted) setState(() => _findBusy = false);
    }
  }

  /// Lists what OpenSubtitles has for this title. Free to browse.
  Future<List<SubtitleOption>> _subtitleOptions() {
    final lang = _currentSubtitleLanguage();
    return _c.api.subtitleOptions(widget.item.mediaKind, widget.item.mediaId,
        language: lang);
  }

  /// Installs the option the user picked and reloads the cues on screen.
  Future<void> _installOption(SubtitleOption option) async {
    final index = _c.activeSubtitle;
    try {
      final res = await _c.api.installSubtitle(
          widget.item.mediaKind, widget.item.mediaId, option.fileId,
          index: index, language: option.language);
      await _c.adoptDelay(0);
      await _c.reloadTracks();
      if (!mounted) return;
      Toast.show(context, res.message,
          kind: ToastKind.success,
          actionLabel: index == null ? null : 'Undo',
          onAction: index == null ? null : () => _restoreSubtitle(index));
    } catch (e) {
      if (mounted) {
        Toast.show(context, 'Could not install that subtitle: $e',
            kind: ToastKind.error);
      }
    }
  }

  /// Two-letter tag of the track being watched, so the search looks for more
  /// of the same language.
  String _currentSubtitleLanguage() {
    final index = _c.activeSubtitle;
    if (index != null) {
      for (final s in _c.tracks.subtitles) {
        if (s.index == index) {
          final v = s.language.toLowerCase();
          if (v.startsWith('ar')) return 'ar';
          if (v.startsWith('en')) return 'en';
        }
      }
    }
    return 'en';
  }

  void _openNextEpisode() {
    final next = _c.nextEpisode;
    if (next == null) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => WatchScreen(
          item: PlayableItem(
            mediaKind: 'episode',
            mediaId: next.id,
            title: '${next.showTitle} '
                'S${next.season.toString().padLeft(2, '0')}'
                'E${next.episode.toString().padLeft(2, '0')}',
            showId: next.showId,
            season: next.season,
            episode: next.episode,
          ),
        ),
      ),
    );
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final size = Breakpoints.of(context);
    final isAdmin = _c.api.user?.isAdmin ?? false;
    final showChrome = _controlsVisible && !_c.isBlocked;

    return Scaffold(
      backgroundColor: AppColors.black,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: MouseRegion(
          onHover: (_) {
            if (!_controlsVisible) _showControls();
          },
          child: Stack(
            children: [
              // Video surface.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onSurfaceTap,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: _c.player.buildSurface(context),
                    ),
                  ),
                ),
              ),

              if (_c.buffering &&
                  _c.position == Duration.zero &&
                  !_c.isBlocked)
                const Center(
                  child: CircularProgressIndicator(
                      color: AppColors.textPrimary),
                ),

              // Web renders subtitles itself; native uses mpv's renderer.
              if (kIsWeb)
                Positioned.fill(
                  child: SubtitleOverlay(
                    cues: _c.subtitleCues,
                    position: Duration(seconds: _c.realSec),
                    delay: Duration(
                        milliseconds: (_c.subDelaySec * 1000).round()),
                    style: _subtitleStyle,
                    showPositionGuide: _controlsVisible,
                    onPositionChanged: (side, bottom) {
                      setState(() => _subtitleStyle = _subtitleStyle.copyWith(
                            sideOffset: side,
                            bottomOffset: bottom,
                          ));
                    },
                    onPositionCommitted: () => _subtitleStyle.saveToPrefs(),
                  ),
                ),

              // Chrome.
              if (showChrome) ...[
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: PlayerTopBar(
                    title: widget.item.title,
                    onBack: () => Navigator.of(context).maybePop(),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: PlayerBottomBar(
                    position: Duration(seconds: _c.realSec),
                    duration: Duration(seconds: _c.effectiveSec),
                    buffered: _c.buffered + _c.offset,
                    trickplayUrl: widget.item.isLibraryItem
                        ? '${_c.api.baseUrl}/api/'
                            '${widget.item.mediaKind == 'movie' ? 'movies' : 'episodes'}'
                            '/${widget.item.mediaId}/trickplay'
                        : null,
                    token: _c.api.token,
                    playing: _c.playing,
                    hasSubtitles: _c.tracksLoaded,
                    subtitlesOn: _c.activeSubtitle != null,
                    menuOpen: _panelOpen,
                    fullscreen: _fullscreen,
                    onSeek: (d) {
                      _showControls();
                      _c.seekTo(d.inSeconds);
                    },
                    onTogglePlay: () {
                      _showControls();
                      _c.togglePlay();
                    },
                    onSkipBack: () {
                      _showControls();
                      _c.seekTo(_c.realSec - 10);
                    },
                    onSkipForward: () {
                      _showControls();
                      _c.seekTo(_c.realSec + 10);
                    },
                    onToggleMenu: _toggleTrackMenu,
                    onToggleFullscreen: _toggleFullscreen,
                    onNextEpisode:
                        _c.showNextEpisodeCue ? _openNextEpisode : null,
                  ),
                ),
              ],

              // Next-episode cue for phones, where the bottom bar has no room.
              if (_c.showNextEpisodeCue && showChrome && size.isCompact)
                Positioned(
                  bottom: 120,
                  right: size.gutter,
                  child: _NextEpisodeChip(onTap: _openNextEpisode),
                ),

              // The settings panel, anchored above the control bar.
              if (_panelOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _closeMenu,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned(
                  right: size.gutter,
                  bottom: 108,
                  child: SubtitlePanel(
                    tracks: _c.tracks,
                    tracksLoaded: _c.tracksLoaded,
                    activeSubtitle: _c.activeSubtitle,
                    activeAudio: _c.activeAudio,
                    onSelectSubtitle: _c.selectSubtitle,
                    onSelectAudio: _c.selectAudio,
                    onClose: _closeMenu,
                    style: _subtitleStyle,
                    previewImageUrl: widget.item.isLibraryItem
                        ? _c.api.artUrl(
                            widget.item.mediaKind,
                            widget.item.mediaId,
                            widget.item.mediaKind == 'episode'
                                ? 'still'
                                : 'backdrop')
                        : null,
                    onStyleChanged: (style) {
                      if (mounted) setState(() => _subtitleStyle = style);
                    },
                    delaySeconds: isAdmin ? _c.subDelaySec : null,
                    onDelayChanged: isAdmin ? _c.setDelay : null,
                    onAutoSync: isAdmin && _c.tracks.subtitles.isNotEmpty
                        ? _autoSync
                        : null,
                    onFindBetter: isAdmin ? _findBetterSubtitle : null,
                    autoSyncBusy: _autoSyncBusy,
                    findBusy: _findBusy,
                    onBrowseOptions: isAdmin ? _subtitleOptions : null,
                    onInstallOption: isAdmin ? _installOption : null,
                  ),
                ),
              ],

              // Blocking states.
              if (_c.pendingDecision != null)
                Positioned.fill(
                  child: ColoredBox(
                    color: AppColors.scrimHeavy,
                    child: PreparePrompt(
                      decision: _c.pendingDecision!,
                      fallbackTitle: widget.item.title,
                      isAdmin: isAdmin,
                      onPrepare: (mode) =>
                          _prepare(_c.pendingDecision!, mode),
                      onCancel: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                )
              else if (_c.activeJob != null && !_c.activeJob!.isFinished)
                Positioned.fill(
                  child: ColoredBox(
                    color: AppColors.scrimHeavy,
                    child: PrepareProgress(
                      job: _c.activeJob!,
                      queueLeader: _c.queueLeader,
                      queuePos: _c.queuePos,
                      fallbackTitle: widget.item.title,
                      isAdmin: isAdmin,
                      onPause: () => _c.pauseJob(_c.activeJob!.id),
                      onResume: () => _c.resumeJob(_c.activeJob!.id),
                      onCancel: () async {
                        final navigator = Navigator.of(context);
                        await _c.cancelJob(_c.activeJob!.id);
                        navigator.pop();
                      },
                      onClose: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                )
              else if (_c.formatError != null)
                Positioned.fill(
                  child: ColoredBox(
                    color: AppColors.black,
                    child: PlaybackError(
                      message: _c.formatError!,
                      onBack: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NextEpisodeChip extends StatelessWidget {
  final VoidCallback onTap;

  const _NextEpisodeChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.red,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.skip_next, color: AppColors.textPrimary, size: 20),
              SizedBox(width: AppSpacing.sm),
              Text('Next episode',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
