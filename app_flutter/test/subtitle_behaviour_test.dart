import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:movieserver_app/models.dart';
import 'package:movieserver_app/screens/player/subtitle_panel.dart';
import 'package:movieserver_app/screens/player/watch_controller.dart';
import 'package:movieserver_app/subtitles/overlay.dart';
import 'package:movieserver_app/subtitles/parser.dart';
import 'package:movieserver_app/theme/theme.dart';

void main() {
  group('English subtitle detection', () {
    test('matches every spelling the library actually produces', () {
      // The server names external tracks from the file, so "English" is the
      // common case; the short codes come from embedded streams.
      for (final label in [
        'English',
        'english',
        ' English ',
        'en',
        'eng',
        'en-US',
        'en_GB',
        'English SDH',
      ]) {
        expect(WatchController.isEnglishTrack(label), isTrue,
            reason: '"$label" should count as English');
      }
    });

    test('does not match other languages or empty labels', () {
      for (final label in ['', 'Arabic', 'ar', 'ara', 'Spanish', 'Enochian']) {
        expect(WatchController.isEnglishTrack(label), isFalse,
            reason: '"$label" should not count as English');
      }
    });
  });

  group('Track preference', () {
    // A track muxed into the release was timed against that exact cut, so it
    // cannot be out of sync; a downloaded .srt is a guess about which release
    // you have.
    SubtitleInfo sub(int i, String name, {bool embedded = false}) =>
        SubtitleInfo(
            index: i,
            url: '/s/\$i',
            language: 'English',
            name: name,
            embedded: embedded);

    test('an embedded English track wins over a downloaded one', () {
      final tracks = [
        sub(0, 'English - in video', embedded: true),
        sub(1, 'English'),
      ];
      final english = tracks
          .where((s) => WatchController.isEnglishTrack(s.language))
          .toList();
      final preferred =
          english.firstWhere((s) => s.embedded, orElse: () => english.first);
      expect(preferred.index, 0);
    });

    test('falls back to a file when nothing is embedded', () {
      final tracks = [sub(0, 'English'), sub(1, 'English SDH')];
      final english = tracks
          .where((s) => WatchController.isEnglishTrack(s.language))
          .toList();
      final preferred =
          english.firstWhere((s) => s.embedded, orElse: () => english.first);
      expect(preferred.index, 0);
    });

    test('the embedded flag survives the wire format', () {
      final parsed = SubtitleInfo.fromJson({
        'index': 3,
        'url': '/s/3',
        'language': 'English',
        'name': 'English - in video',
        'embedded': true,
      });
      expect(parsed.embedded, isTrue);
      expect(SubtitleInfo.fromJson({'index': 0}).embedded, isFalse);
    });
  });

  group('SubtitleStyle position', () {
    test('carries a horizontal offset alongside the vertical one', () {
      const base = SubtitleStyle();
      expect(base.sideOffset, 0);

      final moved = base.copyWith(sideOffset: -120, bottomOffset: 300);
      expect(moved.sideOffset, -120);
      expect(moved.bottomOffset, 300);
      // Everything else is preserved.
      expect(moved.fontFamily, base.fontFamily);
      expect(moved.fontSize, base.fontSize);
    });
  });

  group('SubtitleOverlay dragging', () {
    final cues = [
      const SubtitleCue(
        start: Duration.zero,
        end: Duration(seconds: 10),
        text: 'Dragging test',
      ),
    ];

    testWidgets('a drag reports movement on both axes', (tester) async {
      double? side;
      double? bottom;
      var commits = 0;

      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: SubtitleOverlay(
              cues: cues,
              position: const Duration(seconds: 1),
              style: const SubtitleStyle(bottomOffset: 100, sideOffset: 0),
              onPositionChanged: (s, b) {
                side = s;
                bottom = b;
              },
              onPositionCommitted: () => commits++,
            ),
          ),
        ),
      ));
      await tester.pump();

      // The cue is painted twice (outline stroke under the fill), so both
      // matches are the same on-screen block.
      final text = find.text('Dragging test');
      expect(text, findsNWidgets(2));

      // Drag right and up; the old overlay only ever reported vertical moves.
      await tester.drag(text.first, const Offset(60, -40));
      await tester.pumpAndSettle();

      expect(side, closeTo(60, 0.001));
      expect(bottom, closeTo(140, 0.001));
      expect(commits, 1);
    });

    testWidgets('keeps the block inside the frame', (tester) async {
      double? side;
      double? bottom;

      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: SubtitleOverlay(
              cues: cues,
              position: const Duration(seconds: 1),
              style: const SubtitleStyle(bottomOffset: 100, sideOffset: 0),
              onPositionChanged: (s, b) {
                side = s;
                bottom = b;
              },
            ),
          ),
        ),
      ));
      await tester.pump();

      await tester.drag(find.text('Dragging test').first,
          const Offset(5000, -5000));
      await tester.pumpAndSettle();

      expect(side, lessThanOrEqualTo(200)); // half the 400px width
      expect(bottom, lessThanOrEqualTo(260)); // height - 40
    });
  });

  group('Timing controls', () {
    Widget host(Widget child) => MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: Center(child: child)),
        );

    const tracks = MediaTracks(
      subtitles: [
        SubtitleInfo(index: 0, url: '/s/0', language: 'English', name: 'English')
      ],
      audio: [
        AudioTrackInfo(
            index: 0, language: 'eng', title: 'English', isDefault: true)
      ],
    );

    Widget menu({
      double? delay,
      VoidCallback? onAutoSync,
      VoidCallback? onFindBetter,
      bool busy = false,
      bool findBusy = false,
      ValueChanged<double>? onDelayChanged,
      Future<List<SubtitleOption>> Function()? onBrowseOptions,
      Future<void> Function(SubtitleOption)? onInstallOption,
    }) =>
        SubtitlePanel(
          tracks: tracks,
          tracksLoaded: true,
          activeSubtitle: 0,
          activeAudio: 0,
          onSelectSubtitle: (_) {},
          onSelectAudio: (_) {},
          onClose: () {},
          style: const SubtitleStyle(),
          onStyleChanged: (_) {},
          delaySeconds: delay,
          onDelayChanged: onDelayChanged ?? (_) {},
          onAutoSync: onAutoSync,
          onFindBetter: onFindBetter,
          autoSyncBusy: busy,
          findBusy: findBusy,
          onBrowseOptions: onBrowseOptions,
          onInstallOption: onInstallOption,
        );

    testWidgets('timing is driven by a slider', (tester) async {
      double? sent;
      await tester.pumpWidget(host(
        menu(delay: 0, onDelayChanged: (v) => sent = v),
      ));
      await tester.pump();

      expect(find.text('TIMING'), findsOneWidget);
      expect(find.text('+0.0s'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);

      // Drag the slider thumb and confirm the change is reported.
      await tester.drag(find.byType(Slider), const Offset(40, 0));
      await tester.pump();
      expect(sent, isNotNull);
      expect(sent, greaterThan(0));
    });

    testWidgets('offers auto-sync to admins and shows progress',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(menu(delay: 0, onAutoSync: () => taps++)));
      await tester.pump();

      expect(find.text('Auto-sync'), findsOneWidget);
      await tester.tap(find.text('Auto-sync'));
      await tester.pump();
      expect(taps, 1);

      await tester.pumpWidget(
          host(menu(delay: 0, onAutoSync: () => taps++, busy: true)));
      await tester.pump();
      expect(find.text('Listening...'), findsOneWidget);

      // A run in flight must not be started twice.
      await tester.tap(find.text('Listening...'), warnIfMissed: false);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('hides auto-sync when the caller gives no handler',
        (tester) async {
      await tester.pumpWidget(host(menu(delay: 0)));
      await tester.pump();
      expect(find.text('Auto-sync'), findsNothing);
    });

    testWidgets('the nudge buttons step by a tenth of a second',
        (tester) async {
      double? sent;
      await tester.pumpWidget(host(
        menu(delay: 1.0, onDelayChanged: (v) => sent = v),
      ));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(sent, closeTo(1.1, 1e-9));

      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(sent, closeTo(0.9, 1e-9));
    });

    testWidgets('offers to fetch a subtitle timed for this release',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(
          host(menu(delay: 0, onFindBetter: () => taps++)));
      await tester.pump();

      expect(find.text('Find better'), findsOneWidget);
      await tester.tap(find.text('Find better'));
      await tester.pump();
      expect(taps, 1);

      // While a search runs, neither action may be started again.
      await tester.pumpWidget(host(menu(
          delay: 0, onFindBetter: () => taps++, onAutoSync: () => taps++,
          findBusy: true)));
      await tester.pump();
      expect(find.text('Searching...'), findsOneWidget);
      await tester.tap(find.text('Searching...'), warnIfMissed: false);
      await tester.tap(find.text('Auto-sync'), warnIfMissed: false);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('hides the search when the caller gives no handler',
        (tester) async {
      await tester.pumpWidget(host(menu(delay: 0)));
      await tester.pump();
      expect(find.text('Find better'), findsNothing);
    });

    testWidgets('lists alternative subtitles and installs the one picked',
        (tester) async {
      const options = [
        SubtitleOption(
            fileId: 11,
            name: 'doctor.who.2005.s01e02.720p.bluray.x264-shortbrehd',
            language: 'en',
            downloads: 41374,
            hashMatch: false),
        SubtitleOption(
            fileId: 22,
            name: 'Matched upload',
            language: 'en',
            downloads: 12,
            hashMatch: true),
      ];
      SubtitleOption? installed;

      await tester.pumpWidget(host(menu(
        delay: 0,
        onBrowseOptions: () async => options,
        onInstallOption: (o) async => installed = o,
      )));
      await tester.pump();

      await tester.tap(find.text('More subtitles for this title'));
      await tester.pumpAndSettle();

      expect(find.text('Pick a different subtitle'), findsOneWidget);
      expect(find.text(options[0].name), findsOneWidget);
      // Popularity is shown compactly; an exact match says so instead.
      expect(find.text('41k downloads'), findsOneWidget);
      expect(find.text('Matched to this exact file'), findsOneWidget);

      await tester.tap(find.text(options[0].name));
      await tester.pumpAndSettle();
      expect(installed?.fileId, 11);
      // Installing returns to the track list.
      expect(find.text('Pick a different subtitle'), findsNothing);
    });

    testWidgets('hides the options browser for non-admins', (tester) async {
      await tester.pumpWidget(host(menu(delay: 0)));
      await tester.pump();
      expect(find.text('More subtitles for this title'), findsNothing);
    });

    testWidgets('spells out which way the shift runs', (tester) async {
      await tester.pumpWidget(host(menu(delay: -2.5)));
      await tester.pump();
      expect(find.text('-2.5s'), findsOneWidget);
      expect(find.text('Subtitles appear 2.5s earlier'), findsOneWidget);

      await tester.pumpWidget(host(menu(delay: 0)));
      await tester.pump();
      expect(find.text('Subtitles follow the file as authored'),
          findsOneWidget);
    });
  });

  group('Unprocessed flag', () {
    test('movies follow the server media-check state', () {
      Movie movie(String state) => Movie.fromJson({
            'id': 1,
            'title': 'x',
            'year': 2024,
            'file_path': 'a.mkv',
            'size_bytes': 1,
            'overview': '',
            'poster': '',
            'backdrop': '',
            'trailer_url': '',
            'duration_sec': 100,
            'web_state': state,
          });

      expect(movie('quick_fix').needsPrep, isTrue);
      expect(movie('needs_encode').needsPrep, isTrue);
      expect(movie('web_ready').needsPrep, isFalse);
      expect(movie('web_direct').needsPrep, isFalse);
      expect(movie('').needsPrep, isFalse);
    });

    test('episodes carry the flag, because preparing is per file', () {
      Episode ep(String state) => Episode.fromJson({
            'id': 1,
            'show_id': 2,
            'season': 1,
            'episode': 3,
            'title': 'x',
            'overview': '',
            'still': '',
            'web_state': state,
          });

      expect(ep('quick_fix').needsPrep, isTrue);
      expect(ep('needs_encode').needsPrep, isTrue);
      expect(ep('web_ready').needsPrep, isFalse);
      expect(ep('').needsPrep, isFalse);
    });
  });
}
