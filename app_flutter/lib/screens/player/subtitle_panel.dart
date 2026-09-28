import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../subtitles/overlay.dart';
import '../../theme/tokens.dart';
import 'player_panel.dart';

enum PanelTab { subtitles, audio, style }

/// The player's one settings surface: track selection, timing and appearance
/// behind a segmented control, in a panel anchored above the control bar.
///
/// Replaces the pair of half-screen bottom sheets this used to be - and the
/// awkward hop between them through a back chevron.
class SubtitlePanel extends StatefulWidget {
  final MediaTracks tracks;
  final bool tracksLoaded;
  final int? activeSubtitle;
  final int? activeAudio;
  final void Function(int? index) onSelectSubtitle;
  final void Function(int index) onSelectAudio;
  final VoidCallback onClose;

  final SubtitleStyle style;
  final ValueChanged<SubtitleStyle> onStyleChanged;

  /// Artwork for the style preview, so the sample text is judged against a
  /// real frame rather than an invented backdrop.
  final String? previewImageUrl;

  /// Admin-only per-title timing. Null hides the whole timing block.
  final double? delaySeconds;
  final ValueChanged<double>? onDelayChanged;
  final VoidCallback? onAutoSync;

  /// Admin-only: fetch a subtitle that was timed for this release.
  final VoidCallback? onFindBetter;
  final bool autoSyncBusy;
  final bool findBusy;

  /// Admin-only: browse everything OpenSubtitles has for this title.
  final Future<List<SubtitleOption>> Function()? onBrowseOptions;
  final Future<void> Function(SubtitleOption)? onInstallOption;

  const SubtitlePanel({
    super.key,
    required this.tracks,
    required this.tracksLoaded,
    required this.activeSubtitle,
    required this.activeAudio,
    required this.onSelectSubtitle,
    required this.onSelectAudio,
    required this.onClose,
    required this.style,
    required this.onStyleChanged,
    this.previewImageUrl,
    this.delaySeconds,
    this.onDelayChanged,
    this.onAutoSync,
    this.onFindBetter,
    this.autoSyncBusy = false,
    this.findBusy = false,
    this.onBrowseOptions,
    this.onInstallOption,
  });

  @override
  State<SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends State<SubtitlePanel> {
  PanelTab _tab = PanelTab.subtitles;
  Timer? _saveTimer;

  // The options browser lives inside the Subtitles tab rather than as another
  // panel, so getting back to the track list is one tap.
  bool _browsing = false;
  bool _loadingOptions = false;
  int? _installingId;
  String? _optionsError;
  List<SubtitleOption> _options = const [];

  Future<void> _loadOptions() async {
    final fetch = widget.onBrowseOptions;
    if (fetch == null) return;
    setState(() {
      _browsing = true;
      _loadingOptions = true;
      _optionsError = null;
    });
    try {
      final list = await fetch();
      if (mounted) setState(() => _options = list);
    } catch (e) {
      if (mounted) setState(() => _optionsError = '$e');
    } finally {
      if (mounted) setState(() => _loadingOptions = false);
    }
  }

  Future<void> _install(SubtitleOption option) async {
    final install = widget.onInstallOption;
    if (install == null) return;
    setState(() => _installingId = option.fileId);
    try {
      await install(option);
      if (mounted) setState(() => _browsing = false);
    } finally {
      if (mounted) setState(() => _installingId = null);
    }
  }

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      widget.style.saveToPrefs();
    }
    super.dispose();
  }

  /// Applies immediately, writes to disk once the user pauses; the old sheet
  /// hit SharedPreferences on every slider frame.
  void _setStyle(SubtitleStyle next) {
    widget.onStyleChanged(next);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), next.saveToPrefs);
  }

  @override
  Widget build(BuildContext context) {
    return PlayerPanel(
      title: 'Subtitles & Audio',
      onClose: widget.onClose,
      width: 400,
      maxHeight: 470,
      subheader: _TabBar(
        active: _tab,
        onChanged: (t) => setState(() => _tab = t),
      ),
      children: switch (_tab) {
        PanelTab.subtitles =>
          _browsing ? _optionsView() : _subtitlesTab(),
        PanelTab.audio => _audioTab(),
        PanelTab.style => _styleTab(),
      },
    );
  }

  // ---- tracks ----

  List<Widget> _subtitlesTab() {
    final subs = widget.tracks.subtitles;
    return [
      PlayerMenuOption(
        label: 'Off',
        selected: widget.activeSubtitle == null,
        onTap: () => widget.onSelectSubtitle(null),
      ),
      if (!widget.tracksLoaded)
        const _Hint('Looking for subtitle files...')
      else if (subs.isEmpty)
        const _Hint('No subtitle files were found next to this video.')
      else
        for (final s in subs)
          PlayerMenuOption(
            label: s.name,
            // External SRTs usually carry the language as their name too;
            // showing both just prints "English" twice.
            sublabel: _distinct(s.name, s.language),
            selected: widget.activeSubtitle == s.index,
            onTap: () => widget.onSelectSubtitle(s.index),
          ),
      if (widget.onBrowseOptions != null) ...[
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          height: 32,
          child: OutlinedButton.icon(
            onPressed: _loadOptions,
            icon: const Icon(Icons.library_books_outlined, size: 15),
            label: const Text('More subtitles for this title'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              textStyle: const TextStyle(
                  fontFamily: 'Noto Sans', fontSize: 12),
            ),
          ),
        ),
      ],
      if (widget.delaySeconds != null && widget.onDelayChanged != null) ...[
        const _SectionRule(label: 'Timing'),
        _TimingBlock(
          seconds: widget.delaySeconds!,
          onChanged: widget.onDelayChanged!,
          onAutoSync: widget.onAutoSync,
          onFindBetter: widget.onFindBetter,
          busy: widget.autoSyncBusy,
          findBusy: widget.findBusy,
        ),
      ],
    ];
  }

  /// Everything OpenSubtitles lists for this title. Browsing is free; only
  /// installing one spends a download.
  List<Widget> _optionsView() {
    return [
      Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 18),
            color: AppColors.textSecondary,
            onPressed: () => setState(() => _browsing = false),
            tooltip: 'Back to tracks',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const Expanded(
            child: Text('Pick a different subtitle',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      if (_loadingOptions)
        const Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      else if (_optionsError != null)
        _Hint(_optionsError!)
      else if (_options.isEmpty)
        const _Hint('OpenSubtitles has nothing listed for this title.')
      else
        for (final o in _options)
          PlayerMenuOption(
            label: o.name,
            sublabel: o.hashMatch
                ? 'Matched to this exact file'
                : '${_compactCount(o.downloads)} downloads',
            selected: _installingId == o.fileId,
            onTap: _installingId == null ? () => _install(o) : () {},
          ),
      const SizedBox(height: AppSpacing.xs),
      const Text(
        'Tap one to try it. The previous file is kept, so you can undo.',
        style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
      ),
    ];
  }

  static String _compactCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).round()}k';
    return '$n';
  }

  List<Widget> _audioTab() {
    final audio = widget.tracks.audio;
    return [
      if (!widget.tracksLoaded)
        const _Hint('Reading the audio streams...')
      else if (audio.isEmpty)
        const _Hint('This file has a single audio track.')
      else
        for (final a in audio)
          PlayerMenuOption(
            label: a.label.isNotEmpty ? a.label : a.language,
            sublabel: _distinct(a.label, a.language),
            selected: widget.activeAudio == a.index,
            onTap: () => widget.onSelectAudio(a.index),
          ),
    ];
  }

  // ---- style ----

  static const _sizePresets = <String, double>{
    'S': 18,
    'M': 24,
    'L': 32,
    'XL': 42,
  };

  static const _fonts = <String, String>{
    'Noto Sans': 'Streaming standard',
    'Noto Sans Arabic': 'Modern Arabic',
    'Cairo': 'Cinema / OSN',
    'DejaVu Sans': 'Classic VLC',
    'Liberation Sans': 'Arial / theater',
    'System': 'Platform default',
  };

  static const _textColors = [
    Color(0xFFFFFFFF),
    Color(0xFFFFEE00),
    Color(0xFF80D8FF),
    Color(0xFFA7F3D0),
    Color(0xFFFDE68A),
  ];

  List<Widget> _styleTab() {
    final style = widget.style;
    return [
      _StylePreview(style: style, imageUrl: widget.previewImageUrl),
      const SizedBox(height: AppSpacing.md),
      _StyleRow(
        label: 'Font',
        child: _FontPicker(
          value: style.fontFamily,
          fonts: _fonts,
          onChanged: (v) => _setStyle(style.copyWith(fontFamily: v)),
        ),
      ),
      _StyleRow(
        label: 'Size',
        child: Row(
          children: [
            Expanded(
              child: _Segmented<double>(
                values: _sizePresets,
                // Match the preset the current size is nearest to.
                selected: _sizePresets.values.reduce((a, b) =>
                    (a - style.fontSize).abs() < (b - style.fontSize).abs()
                        ? a
                        : b),
                onChanged: (v) => _setStyle(style.copyWith(fontSize: v)),
              ),
            ),
            SizedBox(
              width: 34,
              child: Text('${style.fontSize.round()}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: AppColors.textTertiary, fontSize: 11)),
            ),
          ],
        ),
      ),
      _StyleRow(
        label: '',
        child: _MiniSlider(
          value: style.fontSize,
          min: 14,
          max: 52,
          onChanged: (v) => _setStyle(style.copyWith(fontSize: v)),
        ),
      ),
      _StyleRow(
        label: 'Colour',
        child: _Swatches(
          colors: _textColors,
          selected: style.textColor,
          checkColor: AppColors.black,
          onPick: (c) => _setStyle(style.copyWith(textColor: c)),
        ),
      ),
      _StyleRow(
        label: 'Backing',
        child: _Segmented<SubtitleBackground>(
          values: {
            for (final v in SubtitleBackground.values) v.label: v,
          },
          selected: style.background,
          onChanged: (v) => _setStyle(style.copyWith(background: v)),
        ),
      ),
      const _SectionRule(label: 'Position'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Drag the subtitle anywhere on the video.',
                style:
                    TextStyle(color: AppColors.textTertiary, fontSize: 11),
              ),
            ),
            TextButton(
              onPressed: (style.sideOffset == 0 && style.bottomOffset == 85)
                  ? null
                  : () => _setStyle(
                      style.copyWith(sideOffset: 0, bottomOffset: 85)),
              style: _linkButton,
              child: const Text('Recentre', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.xs),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => _setStyle(SubtitleStyle(
            bottomOffset: style.bottomOffset,
            sideOffset: style.sideOffset,
          )),
          icon: const Icon(Icons.restart_alt, size: 15),
          label: const Text('Reset appearance',
              style: TextStyle(fontSize: 12)),
          style: _linkButton,
        ),
      ),
    ];
  }
}

final ButtonStyle _linkButton = TextButton.styleFrom(
  minimumSize: Size.zero,
  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  foregroundColor: AppColors.textSecondary,
);

/// The secondary line, unless it just repeats the primary one.
String? _distinct(String label, String other) {
  if (other.isEmpty) return null;
  if (other.toLowerCase() == label.toLowerCase()) return null;
  return other;
}

// ---- pieces ----

class _TabBar extends StatelessWidget {
  final PanelTab active;
  final ValueChanged<PanelTab> onChanged;

  const _TabBar({required this.active, required this.onChanged});

  static const _labels = {
    PanelTab.subtitles: 'Subtitles',
    PanelTab.audio: 'Audio',
    PanelTab.style: 'Style',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
      child: Container(
        height: 30,
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            for (final tab in PanelTab.values)
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(tab),
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: AppMotion.fast,
                    margin: const EdgeInsets.all(2),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active == tab
                          ? AppColors.red
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      _labels[tab]!,
                      style: TextStyle(
                        color: active == tab
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: active == tab
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionRule extends StatelessWidget {
  final String label;
  const _SectionRule({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
          top: AppSpacing.md, bottom: AppSpacing.xs, left: AppSpacing.sm),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Expanded(child: Divider(color: AppColors.border, height: 1)),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.sm),
        child: Text(text,
            style:
                const TextStyle(color: AppColors.textTertiary, fontSize: 12)),
      );
}

/// Label on the left, control on the right, every row the same height.
class _StyleRow extends StatelessWidget {
  final String label;
  final Widget child;

  const _StyleRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Shows the current style the way it will actually appear.
///
/// It sits on a still from what is playing where one is available. The first
/// version invented a coloured gradient to stand in for a frame, which read as
/// though the subtitle had a background even with the backing set to None -
/// so the box now says what it is, and its backdrop is unmistakably a picture
/// rather than part of the styling.
class _StylePreview extends StatelessWidget {
  final SubtitleStyle style;
  final String? imageUrl;

  const _StylePreview({required this.style, this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 86,
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl != null && imageUrl!.isNotEmpty)
            Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              errorBuilder: (_, __, ___) => const _PreviewFallback(),
            )
          else
            const _PreviewFallback(),
          // Darkened a little so white text is legible on a bright still.
          Container(color: AppColors.black.withOpacity(0.28)),
          Positioned(
            top: 4,
            left: 6,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text(
                'PREVIEW',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: _sampleText(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sampleText() {
    final font = style.fontFamily == 'System' ? null : style.fontFamily;
    final size = style.fontSize.clamp(14.0, 22.0);

    Widget text = Stack(
      children: [
        Text(
          'Where we\'re going, we don\'t need roads.',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: font,
            fontSize: size,
            fontWeight: FontWeight.w700,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = (size * 0.14).clamp(2.0, 4.0)
              ..color = style.outlineColor,
          ),
        ),
        Text(
          'Where we\'re going, we don\'t need roads.',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: font,
            fontSize: size,
            fontWeight: FontWeight.w700,
            color: style.textColor,
            shadows: style.background == SubtitleBackground.shadow
                ? const [
                    Shadow(color: Color(0xE6000000), blurRadius: 10),
                    Shadow(
                        color: Color(0x99000000),
                        blurRadius: 4,
                        offset: Offset(0, 2)),
                  ]
                : null,
          ),
        ),
      ],
    );

    if (style.background == SubtitleBackground.box) {
      text = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: style.backgroundColor,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: text,
      );
    }
    return text;
  }
}

/// Stand-in when the item has no artwork: deliberately flat and grey so it
/// cannot be mistaken for a styling choice.
class _PreviewFallback extends StatelessWidget {
  const _PreviewFallback();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(color: Color(0xFF2B2B2B));
  }
}

class _FontPicker extends StatelessWidget {
  final String value;
  final Map<String, String> fonts;
  final ValueChanged<String> onChanged;

  const _FontPicker({
    required this.value,
    required this.fonts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      initialValue: value,
      color: AppColors.surfaceHigher,
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final e in fonts.entries)
          PopupMenuItem(
            value: e.key,
            height: 42,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.key,
                    style: TextStyle(
                        fontSize: 13,
                        fontFamily: e.key == 'System' ? null : e.key)),
                Text(e.value,
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textTertiary)),
              ],
            ),
          ),
      ],
      child: Container(
        height: 30,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 12)),
            ),
            const Icon(Icons.arrow_drop_down,
                size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Small pill-style choice row used for size presets and backing modes.
class _Segmented<T> extends StatelessWidget {
  final Map<String, T> values;
  final T selected;
  final ValueChanged<T> onChanged;

  const _Segmented({
    required this.values,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          for (final e in values.entries)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(e.value),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  margin: const EdgeInsets.all(2),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: e.value == selected
                        ? AppColors.borderStrong
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    e.key,
                    style: TextStyle(
                      color: e.value == selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: e.value == selected
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MiniSlider extends StatelessWidget {
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _MiniSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _Swatches extends StatelessWidget {
  final List<Color> colors;
  final Color selected;
  final Color checkColor;
  final ValueChanged<Color> onPick;

  const _Swatches({
    required this.colors,
    required this.selected,
    required this.checkColor,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final c in colors)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: GestureDetector(
              onTap: () => onPick(c),
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c.value == selected.value
                        ? AppColors.red
                        : AppColors.borderStrong,
                    width: c.value == selected.value ? 2.5 : 1,
                  ),
                ),
                child: c.value == selected.value
                    ? Icon(Icons.check, size: 12, color: checkColor)
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// Per-title subtitle timing, admin only.
///
/// Built around a big readout because this gets used while a film is playing,
/// on the other side of a room: the number has to be legible at a glance. The
/// arrows step by a tenth of a second, which a 400px slider cannot resolve,
/// and the slider underneath is for getting close quickly.
class _TimingBlock extends StatelessWidget {
  final double seconds;
  final ValueChanged<double> onChanged;
  final VoidCallback? onAutoSync;
  final VoidCallback? onFindBetter;
  final bool busy;
  final bool findBusy;

  const _TimingBlock({
    required this.seconds,
    required this.onChanged,
    required this.onAutoSync,
    required this.onFindBetter,
    required this.busy,
    required this.findBusy,
  });

  static const _baseRange = 15.0;

  /// The slider covers the range real desyncs live in; if a title is already
  /// set further out, widen to fit rather than snapping the value back.
  double get _range {
    final needed = seconds.abs();
    if (needed <= _baseRange) return _baseRange;
    return (needed / _baseRange).ceilToDouble() * _baseRange;
  }

  void _set(double v) => onChanged(v.clamp(-600.0, 600.0));

  /// Plain English for which way the shift runs, so the sign is never a guess.
  String get _hint {
    if (seconds == 0) return 'Subtitles follow the file as authored';
    final amount = seconds.abs().toStringAsFixed(1);
    return seconds > 0
        ? 'Subtitles appear ${amount}s later'
        : 'Subtitles appear ${amount}s earlier';
  }

  @override
  Widget build(BuildContext context) {
    final range = _range;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Readout with a nudge on either side.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Nudge(
                icon: Icons.remove,
                onTap: () => _set(seconds - 0.1),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '${seconds >= 0 ? '+' : '-'}'
                      '${seconds.abs().toStringAsFixed(1)}s',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: seconds == 0
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        height: 1.1,
                      ),
                    ),
                    Text(
                      _hint,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textTertiary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              _Nudge(
                icon: Icons.add,
                onTap: () => _set(seconds + 0.1),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            height: 26,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: seconds.clamp(-range, range),
                min: -range,
                max: range,
                divisions: (range * 20).round(),
                onChanged: _set,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('-${range.round()}s', style: _scaleLabel),
                const Text('0', style: _scaleLabel),
                Text('+${range.round()}s', style: _scaleLabel),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              if (onAutoSync != null)
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: ElevatedButton.icon(
                      onPressed: (busy || findBusy) ? null : onAutoSync,
                      icon: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.textPrimary),
                            )
                          : const Icon(Icons.auto_fix_high, size: 16),
                      label: Text(busy ? 'Listening...' : 'Auto-sync'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm),
                        textStyle: const TextStyle(
                            fontFamily: 'Noto Sans',
                            fontSize: 13,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              if (onFindBetter != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: OutlinedButton.icon(
                      onPressed: (busy || findBusy) ? null : onFindBetter,
                      icon: findBusy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.textSecondary),
                            )
                          : const Icon(Icons.travel_explore, size: 16),
                      label: Text(findBusy ? 'Searching...' : 'Find better'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm),
                        textStyle: const TextStyle(
                            fontFamily: 'Noto Sans', fontSize: 13),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: seconds == 0 ? null : () => _set(0),
              style: _linkButton,
              child: const Text('Reset delay', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

const TextStyle _scaleLabel =
    TextStyle(color: AppColors.textTertiary, fontSize: 10);

/// Square step button either side of the readout.
class _Nudge extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _Nudge({required this.icon, required this.onTap});

  @override
  State<_Nudge> createState() => _NudgeState();
}

class _NudgeState extends State<_Nudge> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _hover ? AppColors.borderStrong : AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Icon(widget.icon,
              size: 20, color: AppColors.textPrimary),
        ),
      ),
    );
  }
}
