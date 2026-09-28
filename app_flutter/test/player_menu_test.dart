import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:movieserver_app/models.dart';
import 'package:movieserver_app/screens/player/subtitle_panel.dart';
import 'package:movieserver_app/subtitles/overlay.dart';
import 'package:movieserver_app/theme/theme.dart';

/// A desktop-sized player surface with the panel anchored above the control
/// bar, the way WatchScreen positions it.
Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned(right: 48, bottom: 108, child: child),
          ],
        ),
      ),
    );

const _tracks = MediaTracks(
  subtitles: [
    SubtitleInfo(index: 0, url: '/s/0', language: 'Arabic', name: 'Arabic'),
    SubtitleInfo(index: 1, url: '/s/1', language: 'English', name: 'English'),
  ],
  audio: [
    AudioTrackInfo(
        index: 0, language: 'eng', title: 'English 5.1', isDefault: true),
    AudioTrackInfo(index: 1, language: 'ara', title: 'Arabic', isDefault: false),
  ],
);

void main() {
  const viewport = Size(1600, 900);

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(child));
    await tester.pump();
  }

  Widget panel({
    double? delay,
    MediaTracks tracks = _tracks,
    bool loaded = true,
    int? activeSubtitle = 1,
    void Function(int?)? onSelectSubtitle,
    SubtitleStyle style = const SubtitleStyle(),
    ValueChanged<SubtitleStyle>? onStyleChanged,
  }) =>
      SubtitlePanel(
        tracks: tracks,
        tracksLoaded: loaded,
        activeSubtitle: activeSubtitle,
        activeAudio: 0,
        onSelectSubtitle: onSelectSubtitle ?? (_) {},
        onSelectAudio: (_) {},
        onClose: () {},
        style: style,
        onStyleChanged: onStyleChanged ?? (_) {},
        delaySeconds: delay,
        onDelayChanged: delay == null ? null : (_) {},
      );

  group('SubtitlePanel layout', () {
    testWidgets('stays a small panel instead of covering the video',
        (tester) async {
      await pump(tester, panel());

      final size = tester.getSize(find.byType(SubtitlePanel));
      // The old bottom sheets were pinned to 55% and 60% of screen height.
      expect(size.height, lessThanOrEqualTo(470));
      expect(size.width, lessThanOrEqualTo(400));
      expect(size.height / viewport.height, lessThan(0.55));
    });

    testWidgets('puts tracks, audio and style behind one tab bar',
        (tester) async {
      await pump(tester, panel());
      for (final tab in ['Subtitles', 'Audio', 'Style']) {
        expect(find.text(tab), findsOneWidget);
      }
    });
  });

  group('Subtitles tab', () {
    testWidgets('lists the tracks plus Off', (tester) async {
      await pump(tester, panel());

      expect(find.text('Off'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Arabic'), findsOneWidget);
      // The language is not repeated as a sublabel when it equals the name.
      expect(find.text('English 5.1'), findsNothing);
    });

    testWidgets('reports the chosen track', (tester) async {
      int? picked;
      var called = false;
      await pump(tester, panel(
        activeSubtitle: null,
        onSelectSubtitle: (i) {
          picked = i;
          called = true;
        },
      ));

      await tester.tap(find.text('Arabic'));
      await tester.pump();
      expect(called, isTrue);
      expect(picked, 0);
    });

    testWidgets('says so when a file has no subtitles', (tester) async {
      await pump(tester, panel(
        tracks: const MediaTracks(subtitles: [], audio: []),
        activeSubtitle: null,
      ));
      expect(
          find.text('No subtitle files were found next to this video.'),
          findsOneWidget);
    });

    testWidgets('hides timing from non-admins', (tester) async {
      await pump(tester, panel());
      expect(find.text('TIMING'), findsNothing);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('shows timing to admins', (tester) async {
      await pump(tester, panel(delay: 1.5));
      expect(find.text('TIMING'), findsOneWidget);
      // A big signed readout plus a plain-English direction, not a tiny field.
      expect(find.text('+1.5s'), findsOneWidget);
      expect(find.text('Subtitles appear 1.5s later'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      // Tenth-of-a-second steps, which the slider cannot resolve.
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.byIcon(Icons.remove), findsOneWidget);
    });
  });

  group('Audio tab', () {
    testWidgets('lists the audio tracks', (tester) async {
      await pump(tester, panel());
      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();

      expect(find.text('English 5.1'), findsOneWidget);
      expect(find.text('Arabic'), findsOneWidget);
      expect(find.text('ara'), findsOneWidget);
    });

    testWidgets('says so when there is only one track', (tester) async {
      await pump(tester, panel(
        tracks: const MediaTracks(subtitles: [], audio: []),
        activeSubtitle: null,
      ));
      await tester.tap(find.text('Audio'));
      await tester.pumpAndSettle();
      expect(find.text('This file has a single audio track.'), findsOneWidget);
    });
  });

  group('Style tab', () {
    testWidgets('exposes every appearance control', (tester) async {
      await pump(tester, panel());
      await tester.tap(find.text('Style'));
      await tester.pumpAndSettle();

      for (final label in ['Font', 'Size', 'Colour', 'Backing']) {
        expect(find.text(label), findsOneWidget);
      }
      // Backing is a three-way choice now, not an on/off switch.
      expect(find.byType(Switch), findsNothing);
      for (final mode in ['None', 'Shadow', 'Box']) {
        expect(find.text(mode), findsOneWidget);
      }
      // Position is handled by dragging on the video.
      expect(find.text('Recentre'), findsOneWidget);
    });

    testWidgets('emits style changes', (tester) async {
      SubtitleStyle? latest;
      await pump(tester, panel(onStyleChanged: (s) => latest = s));
      await tester.tap(find.text('Style'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Shadow'));
      await tester.pump();
      expect(latest?.background, SubtitleBackground.shadow);

      await tester.tap(find.text('XL'));
      await tester.pump();
      expect(latest?.fontSize, 42);
    });

    testWidgets('recentre restores the default position', (tester) async {
      SubtitleStyle? latest;
      await pump(tester, panel(
        style: const SubtitleStyle(sideOffset: -140, bottomOffset: 300),
        onStyleChanged: (s) => latest = s,
      ));
      await tester.tap(find.text('Style'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Recentre'));
      await tester.pump();
      expect(latest?.sideOffset, 0);
      expect(latest?.bottomOffset, 85);
    });

    testWidgets('reset appearance keeps where the user put the text',
        (tester) async {
      SubtitleStyle? latest;
      await pump(tester, panel(
        style: const SubtitleStyle(
          sideOffset: -140,
          bottomOffset: 300,
          fontSize: 48,
          background: SubtitleBackground.box,
        ),
        onStyleChanged: (s) => latest = s,
      ));
      await tester.tap(find.text('Style'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reset appearance'));
      await tester.pump();
      expect(latest?.fontSize, 24);
      expect(latest?.background, SubtitleBackground.none);
      // Position is deliberately untouched.
      expect(latest?.sideOffset, -140);
      expect(latest?.bottomOffset, 300);
    });
  });
}
