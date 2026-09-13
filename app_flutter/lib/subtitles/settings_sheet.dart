import 'package:flutter/material.dart';
import 'overlay.dart';

class SubtitleSettingsSheet extends StatefulWidget {
  final SubtitleStyle initialStyle;
  final ValueChanged<SubtitleStyle> onStyleChanged;

  const SubtitleSettingsSheet({
    super.key,
    required this.initialStyle,
    required this.onStyleChanged,
  });

  @override
  State<SubtitleSettingsSheet> createState() => _SubtitleSettingsSheetState();
}

class _SubtitleSettingsSheetState extends State<SubtitleSettingsSheet> {
  late SubtitleStyle _current;

  static const List<Map<String, String>> _fonts = [
    {'label': 'Noto Sans', 'family': 'Noto Sans', 'desc': 'Streaming Standard'},
    {
      'label': 'Noto Sans Arabic',
      'family': 'Noto Sans Arabic',
      'desc': 'Modern Arabic'
    },
    {'label': 'Cairo', 'family': 'Cairo', 'desc': 'Cinema / OSN'},
    {'label': 'DejaVu Sans', 'family': 'DejaVu Sans', 'desc': 'Classic VLC'},
    {
      'label': 'Liberation Sans',
      'family': 'Liberation Sans',
      'desc': 'Arial / Theater'
    },
    {'label': 'System', 'family': 'System', 'desc': 'Default'},
  ];

  static const List<Map<String, dynamic>> _textColors = [
    {'name': 'White', 'color': Color(0xFFFFFFFF)},
    {'name': 'Yellow', 'color': Color(0xFFFFEE00)},
    {'name': 'Cyan', 'color': Color(0xFF80D8FF)},
    {'name': 'Green', 'color': Color(0xFFA7F3D0)},
    {'name': 'Amber', 'color': Color(0xFFFDE68A)},
  ];

  static const List<Map<String, dynamic>> _bgColors = [
    {'name': 'Dark Black', 'color': Color(0xCC000000)},
    {'name': 'Translucent', 'color': Color(0x80000000)},
    {'name': 'Solid Black', 'color': Color(0xFF000000)},
    {'name': 'Charcoal', 'color': Color(0xD91E1E1E)},
    {'name': 'Navy', 'color': Color(0xD90A192F)},
  ];

  @override
  void initState() {
    super.initState();
    _current = widget.initialStyle;
  }

  void _update(SubtitleStyle newStyle) {
    setState(() => _current = newStyle);
    widget.onStyleChanged(newStyle);
    newStyle.saveToPrefs();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF181818),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.tune, color: Color(0xFFE50914), size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Subtitle Appearance',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),

            // Live Preview Box
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                children: [
                  const Text('PREVIEW',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          letterSpacing: 1.2)),
                  const SizedBox(height: 8),
                  _buildPreviewText(
                      'Where we\'re going, we don\'t need roads.'),
                  const SizedBox(height: 4),
                  _buildPreviewText('إلى أين نحن ذاهبون، لا نحتاج إلى طرق.',
                      isRtl: true),
                ],
              ),
            ),

            // Scrollable Settings
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                children: [
                  // Font Selector
                  _buildSectionTitle('Font Family'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _fonts.map((f) {
                      final selected = _current.fontFamily == f['family'];
                      return ChoiceChip(
                        selected: selected,
                        label: Text(f['label']!),
                        selectedColor: const Color(0xFFE50914),
                        backgroundColor: const Color(0xFF2A2A2A),
                        labelStyle: TextStyle(
                          color: selected ? Colors.white : Colors.white70,
                          fontWeight:
                              selected ? FontWeight.bold : FontWeight.normal,
                          fontFamily:
                              f['family'] == 'System' ? null : f['family'],
                        ),
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) =>
                            _update(_current.copyWith(fontFamily: f['family'])),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),

                  // Font Size
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionTitle('Font Size'),
                      Text('${_current.fontSize.round()} px',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: _current.fontSize.clamp(16.0, 48.0),
                    min: 16.0,
                    max: 48.0,
                    divisions: 16,
                    activeColor: const Color(0xFFE50914),
                    inactiveColor: Colors.white24,
                    onChanged: (val) =>
                        _update(_current.copyWith(fontSize: val)),
                  ),
                  const SizedBox(height: 8),

                  // Text Color
                  _buildSectionTitle('Text Color'),
                  const SizedBox(height: 6),
                  Row(
                    children: _textColors.map((c) {
                      final Color col = c['color'] as Color;
                      final bool isSelected =
                          _current.textColor.value == col.value;
                      return Padding(
                        padding: const EdgeInsets.only(right: 14),
                        child: GestureDetector(
                          onTap: () =>
                              _update(_current.copyWith(textColor: col)),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: col,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFFE50914)
                                    : Colors.white30,
                                width: isSelected ? 3 : 1,
                              ),
                            ),
                            child: isSelected
                                ? const Icon(Icons.check,
                                    size: 18, color: Colors.black)
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),

                  // Background Box
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionTitle('Background Box'),
                      Switch(
                        value: _current.hasBackground,
                        activeColor: const Color(0xFFE50914),
                        onChanged: (val) =>
                            _update(_current.copyWith(hasBackground: val)),
                      ),
                    ],
                  ),
                  if (_current.hasBackground) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: _bgColors.map((c) {
                        final Color col = c['color'] as Color;
                        final bool isSelected =
                            _current.backgroundColor.value == col.value;
                        return Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: GestureDetector(
                            onTap: () => _update(
                                _current.copyWith(backgroundColor: col)),
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: col,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFFE50914)
                                      : Colors.white30,
                                  width: isSelected ? 3 : 1,
                                ),
                              ),
                              child: isSelected
                                  ? const Icon(Icons.check,
                                      size: 18, color: Colors.white)
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 16),

                  // Vertical Position
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionTitle('Vertical Position'),
                      Text('${_current.bottomOffset.round()} px from bottom',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: _current.bottomOffset.clamp(20.0, 500.0),
                    min: 20.0,
                    max: 500.0,
                    divisions: 48,
                    activeColor: const Color(0xFFE50914),
                    inactiveColor: Colors.white24,
                    onChanged: (val) =>
                        _update(_current.copyWith(bottomOffset: val)),
                  ),
                  Row(
                    children: [
                      _buildPositionPreset('Bottom', 40.0),
                      const SizedBox(width: 8),
                      _buildPositionPreset('Above Controls', 85.0),
                      const SizedBox(width: 8),
                      _buildPositionPreset('Middle', 220.0),
                      const SizedBox(width: 8),
                      _buildPositionPreset('Top', 450.0),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tip: You can also drag the subtitle up or down directly on the video!',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
          color: Colors.white70,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5),
    );
  }

  Widget _buildPositionPreset(String label, double offset) {
    final selected = (_current.bottomOffset - offset).abs() < 5;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? const Color(0xFFE50914) : Colors.white70,
        side: BorderSide(
            color: selected ? const Color(0xFFE50914) : Colors.white24),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => _update(_current.copyWith(bottomOffset: offset)),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }

  Widget _buildPreviewText(String text, {bool isRtl = false}) {
    final String? font =
        _current.fontFamily == 'System' ? null : _current.fontFamily;

    Widget content = Stack(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          style: TextStyle(
            fontFamily: font,
            fontSize: _current.fontSize,
            fontWeight: FontWeight.w700,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = (_current.fontSize * 0.14).clamp(2.0, 5.0)
              ..color = _current.outlineColor,
          ),
        ),
        Text(
          text,
          textAlign: TextAlign.center,
          textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
          style: TextStyle(
            fontFamily: font,
            fontSize: _current.fontSize,
            fontWeight: FontWeight.w700,
            color: _current.textColor,
          ),
        ),
      ],
    );

    if (_current.hasBackground) {
      content = Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: _current.backgroundColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: content,
      );
    }

    return content;
  }
}
