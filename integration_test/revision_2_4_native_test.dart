import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian, ByteData;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:scanora/l10n/app_localizations.dart';
import 'package:scanora/services/ocr/offline_ocr_engine.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/tts/espeak_tts_service.dart';
import 'package:scanora/services/tts/tts_models.dart';
import 'package:scanora/ui/screens/pdf_viewer_screen.dart';
import 'package:scanora/ui/widgets/tts_playback_bar.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Finishing a manually started page reads the next page',
      (tester) async {
    final settings = SettingsService.memory();
    await settings.setAutoReadOnOpen(false);
    await settings.setAutoAdvancePage(true);
    await settings.setPlayPageFlipSound(false);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: [
          AppLocalizationsDelegate(),
          ...GlobalMaterialLocalizations.delegates
        ],
        home: PdfViewerScreen(),
      ),
    ));
    await tester.pumpAndSettle();
    final paste = find.text('Read / Paste Text Directly');
    await tester.ensureVisible(paste);
    await tester.tap(paste);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last,
        'First page.\nThe second page starts here. ${List.filled(260, 'continued').join(' ')}');
    await tester.tap(find.text('Open in Reader'));
    await tester.pumpAndSettle();
    expect(EspeakTtsService.playbackState.value.isPlaying, isFalse);
    await tester.tap(find.byTooltip('Play audio'));
    var continued = false;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    try {
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final bar = tester.widget<TtsPlaybackBar>(find.byType(TtsPlaybackBar));
        if (bar.textToSpeak.contains('The second page starts here.') &&
            EspeakTtsService.isPlayingText(bar.textToSpeak)) {
          continued = true;
          break;
        }
      }
    } finally {
      await EspeakTtsService.stop();
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    }
    expect(continued, isTrue);
  });
  testWidgets(
      'Boosted English and Persian speech produces playable PCM, including short clips',
      (tester) async {
    await tester.runAsync(() async {
      final s = SettingsService.memory();
      final report = <Map<String, Object>>[];
      for (final rate in [175, 450]) {
        await s.setTtsRate(rate);
        await s.setTtsRateBoost(true);
        for (final text in ['Hello', 'سلام']) {
          final wav =
              await EspeakTtsService.synthesizeToWavBytes(text, settings: s);
          expect(wav.length, greaterThan(44));
          final data = ByteData.sublistView(wav);
          final sampleRate = data.getUint32(24, Endian.little);
          final seconds = (wav.length - 44) / (sampleRate * 2);
          expect(seconds, greaterThan(.015));
          expect(wav.sublist(44).any((v) => v != 0), isTrue);
          report.add({
            'text': text,
            'rate': s.effectiveTtsRate,
            'seconds': seconds,
            'pcm_bytes': wav.length - 44
          });
        }
      }
      await File('build/audit/boost-facade-2.4.json')
          .writeAsString(jsonEncode(report));
    });
  });

  testWidgets('All four punctuation levels produce distinct native speech',
      (tester) async {
    await tester.runAsync(() async {
      final settings = SettingsService.memory();
      final clipLengths = <int>[];
      for (final level in TtsPunctuation.values) {
        await settings.setTtsPunctuation(level);
        final wav = await EspeakTtsService.synthesizeToWavBytes(
            'One @ two (three), four! Five «six» — seven © eight.',
            settings: settings);
        expect(wav.length, greaterThan(44), reason: level.name);
        clipLengths.add(wav.length);
      }
      expect(clipLengths.toSet(), hasLength(TtsPunctuation.values.length));
    });
  });

  testWidgets(
      'Fast offline camera recognition reads inverted Persian and English display text',
      (tester) async {
    await tester.runAsync(() async {
      final source = img.decodeImage(
          await File('test/fixtures/mixed_line.png').readAsBytes())!;
      final display = img.invert(source);
      final bytes = img.encodePng(display);
      await File('build/audit/dark-display-2.4.png').writeAsBytes(bytes);
      final text = await OfflineOcrEngine.recognizeText(bytes, fast: true);
      await File('build/audit/dark-display-2.4.txt').writeAsString(text);
      expect(text, contains('سلام'));
      expect(text, contains('Scanora'));
    });
  });
}
