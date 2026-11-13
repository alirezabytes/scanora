import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:provider/provider.dart';
import 'package:scanora/l10n/app_localizations.dart';
import 'package:scanora/services/ocr/reading_layout.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/vision/center_color_reader.dart';
import 'package:scanora/ui/screens/pdf_viewer_screen.dart';
import 'package:scanora/ui/widgets/accessible_output_text.dart';
import 'package:scanora/ui/widgets/tts_playback_bar.dart';

void main() {
  test('Reads complete columns and announces the full-width heading', () {
    final lines = <ReadingLayoutLine>[
      (
        bounds: const Rect.fromLTWH(10, 5, 180, 24),
        text: 'A chapter',
        size: 24
      ),
      for (var i = 0; i < 4; i++) ...[
        (
          bounds: Rect.fromLTWH(10, 40 + 16.0 * i, 65, 11),
          text: 'Left $i',
          size: 11
        ),
        (
          bounds: Rect.fromLTWH(110, 40 + 16.0 * i, 80, 11),
          text: 'Right $i',
          size: 11
        ),
      ],
    ];
    expect(
      ReadingLayout.format(lines, heading: 'Heading').split('\n'),
      [
        'Heading. A chapter',
        for (var i = 0; i < 4; i++) 'Left $i',
        for (var i = 0; i < 4; i++) 'Right $i',
      ],
    );

    final persian = lines
        .map((line) => (
              bounds: line.bounds,
              size: line.size,
              text: line.text
                  .replaceAll('Left', 'ستون چپ')
                  .replaceAll('Right', 'ستون راست')
                  .replaceAll('A chapter', 'یک فصل')
            ))
        .toList();
    expect(ReadingLayout.format(persian, heading: 'عنوان').split('\n'), [
      'عنوان. یک فصل',
      for (var i = 0; i < 4; i++) 'ستون راست $i',
      for (var i = 0; i < 4; i++) 'ستون چپ $i',
    ]);
  });

  test('Reports the center color even when the surroundings are different', () {
    final photo = image.Image(width: 100, height: 100);
    image.fill(photo, color: image.ColorRgb8(255, 255, 255));
    image.fillRect(photo,
        x1: 41, y1: 41, x2: 59, y2: 59, color: image.ColorRgb8(180, 0, 0));
    expect(CenterColor.fromPhoto(image.encodePng(photo)), CenterColor.red);
    image.fillRect(photo,
        x1: 41, y1: 41, x2: 59, y2: 59, color: image.ColorRgb8(255, 66, 0));
    expect(CenterColor.fromPhoto(image.encodePng(photo)), CenterColor.red);
    image.fillRect(photo,
        x1: 41, y1: 41, x2: 59, y2: 59, color: image.ColorRgb8(255, 128, 0));
    expect(CenterColor.fromPhoto(image.encodePng(photo)), CenterColor.orange);
    image.fillRect(photo,
        x1: 41, y1: 41, x2: 59, y2: 59, color: image.ColorRgb8(0, 0, 0));
    expect(CenterColor.fromPhoto(image.encodePng(photo)), CenterColor.black);
    image.fill(photo, color: image.ColorRgb8(12, 12, 12));
    expect(CenterColor.fromPhoto(image.encodePng(photo)), CenterColor.lowLight);
    expect(CenterColor.fromPhoto(Uint8List(0)), isNull);
  });

  testWidgets('Skips selected narration and tracks time by document',
      (tester) async {
    const text = 'Keep this. Skip this sentence. Keep the ending.';
    const secondPage = 'Second page starts here.';
    final bookText =
        '$text\n$secondPage ${List.filled(247, 'continued').join(' ')}';
    final settings = SettingsService.memory();
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
      value: settings,
      child: const MaterialApp(
        restorationScopeId: 'scanora-test',
        locale: Locale('en'),
        localizationsDelegates: [
          AppLocalizationsDelegate(),
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: PdfViewerScreen(),
      ),
    ));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    final paste = find.text('Read / Paste Text Directly');
    await tester.ensureVisible(paste);
    await tester.tap(paste);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, bookText);
    await tester.tap(find.text('Open in Reader'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.descendant(
      of: find.byType(AccessibleOutputText),
      matching: find.byType(TextField),
    ));
    final controller = field.controller!;
    final start = controller.text.indexOf('Skip');
    controller.selection = TextSelection(
        baseOffset: start, extentOffset: start + 'Skip this sentence.'.length);
    final skip = find.text('Skip selected text in audio');
    await tester.ensureVisible(skip);
    await tester.tap(skip);
    await tester.pumpAndSettle();
    final player = find.byType(TtsPlaybackBar);
    expect(tester.widget<TtsPlaybackBar>(player).textToSpeak,
        isNot(contains('Skip this sentence.')));
    expect(controller.text, contains(text));

    final restore = find.text('Read all text again');
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(tester.widget<TtsPlaybackBar>(player).textToSpeak, contains(text));

    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.byTooltip('Next Page'));
    await tester.pumpAndSettle();
    expect(tester.widget<TtsPlaybackBar>(player).textToSpeak,
        contains(secondPage));
    await tester.restartAndRestore();
    await tester.pumpAndSettle();
    expect(tester.widget<TtsPlaybackBar>(player).textToSpeak,
        contains(secondPage));
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
      value: settings,
      child: const MaterialApp(
        key: ValueKey('cold-launch'),
        locale: Locale('en'),
        localizationsDelegates: [
          AppLocalizationsDelegate(),
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: PdfViewerScreen(resumeSession: true),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<TtsPlaybackBar>(player).textToSpeak,
        contains(secondPage));
    await settings.setShowReaderText(false);
    await tester.pump();
    expect(find.byType(AccessibleOutputText), findsNothing);
    expect(find.byTooltip('Play audio'), findsOneWidget);
    await tester.tap(find.byTooltip('Reader tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Books & Files Manager'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(settings.readingTimeHistory.single.milliseconds,
        greaterThanOrEqualTo(3000));
    expect(settings.readingTimeHistory.single.audioMilliseconds, 0);
    expect(find.textContaining(RegExp(r'About .+ left')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
}
