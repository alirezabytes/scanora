import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scanora/services/converter/format_converter_service.dart';
import 'package:scanora/services/native_bridge_service.dart';
import 'package:scanora/services/ocr/offline_ocr_engine.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/stt/whisper_onnx_service.dart';
import 'package:scanora/services/tts/espeak_tts_service.dart';
import 'package:scanora/services/tts/espeak_dictionary_service.dart';
import 'package:scanora/services/vision/onnx_vision_classifier_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'Bundled Whisper Small transcribes real English speech and synthetic Persian speech offline',
      (tester) async {
    final report = <String, dynamic>{};
    await tester.runAsync(() async {
      final clock = Stopwatch()..start();
      final english = await WhisperOnnxService.transcribeWavBytes(
          await File('test/fixtures/audio/english_reference.wav').readAsBytes(),
          preferredLanguage: 'en');
      report['english'] = english.text;
      report['english_elapsed_ms'] = clock.elapsedMilliseconds;
      await Directory('build/audit').create(recursive: true);
      await File('build/audit/speech-native-2.4.json')
          .writeAsString(jsonEncode(report));
      final wav = await EspeakTtsService.synthesizeToWavBytes(
          'سلام. امروز هوا خوب است. من کتاب فارسی می‌خوانم.',
          settings: SettingsService());
      final persian = await WhisperOnnxService.transcribeWavBytes(wav,
          preferredLanguage: 'fa');
      report['persian_synthetic'] = persian.text;
      await Directory('build/audit').create(recursive: true);
      await File('build/audit/speech-native-2.4.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      expect(english.text.toLowerCase(), contains('yellow lamps'));
      expect(english.text.toLowerCase(), contains('nightfall'));
      expect(persian.hasText, isTrue);
      expect(RegExp(r'[\u0621-\u06CC]').hasMatch(persian.text), isTrue);
    });
  }, timeout: const Timeout(Duration(minutes: 8)));

  testWidgets('Real object detector reports a bus, count and spatial region',
      (tester) async {
    await tester.runAsync(() async {
      final scene = await OnnxVisionClassifierService.analyzeScene(
          await File('test/fixtures/vision_bus.jpg').readAsBytes());
      final objects = scene.objects
          .map((o) => {
                'name': o.labelEn,
                'count': o.count,
                'region': o.regionEn,
                'score': o.confidence
              })
          .toList();
      await File('build/audit/vision-native-2.4.json')
          .writeAsString(jsonEncode(objects));
      expect(
          scene.objects.any((o) => o.labelEn.toLowerCase() == 'bus'), isTrue);
      expect(scene.objects.every((o) => o.count > 0 && o.regionEn.isNotEmpty),
          isTrue);
    });
  });

  testWidgets(
      'Automatic speech detects Persian and English in separate utterances',
      (tester) async {
    await tester.runAsync(() async {
      final settings = SettingsService();
      final fa = await EspeakTtsService.synthesizeToWavBytes(
          'سلام. امروز هوا خوب است.',
          settings: settings);
      final en = await EspeakTtsService.synthesizeToWavBytes(
          'You can read this book without internet.',
          settings: settings);
      final sampleRate = ByteData.sublistView(fa).getUint32(24, Endian.little);
      final gap = Uint8List(sampleRate * 2 * 2);
      final joined =
          Uint8List(44 + fa.length - 44 + gap.length + en.length - 44);
      joined.setRange(0, fa.length, fa);
      joined.setRange(fa.length, fa.length + gap.length, gap);
      joined.setRange(fa.length + gap.length, joined.length, en.sublist(44));
      ByteData.sublistView(joined)
        ..setUint32(4, joined.length - 8, Endian.little)
        ..setUint32(40, joined.length - 44, Endian.little);
      final result = await WhisperOnnxService.transcribeWavBytes(joined);
      await File('build/audit/speech-mixed-2.4.txt').writeAsString(result.text);
      expect(RegExp(r'[\u0621-\u06CC]').hasMatch(result.text), isTrue);
      expect(result.text.toLowerCase(),
          anyOf(contains('book'), contains('internet')));
    });
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('Fast camera OCR keeps Persian and English on the same line',
      (tester) async {
    await tester.runAsync(() async {
      final text = await OfflineOcrEngine.recognizeText(
          await File('test/fixtures/mixed_line.png').readAsBytes(),
          fast: true);
      await File('build/audit/ocr-fast-mixed-2.4.txt').writeAsString(text);
      expect(text, contains('سلام'));
      expect(text, contains('Scanora'));
    });
  });

  testWidgets(
      'Unicode PDF export renders Persian and English glyphs with its embedded font',
      (tester) async {
    await tester.runAsync(() async {
      final result = await FormatConverterService.convertAndSave(
          sourceBytes: Uint8List.fromList(utf8.encode(
              'سلام اسکنورا. این یک کتاب فارسی است.\nScanora reads English text 12345.')),
          sourceFileName: 'mixed-export.txt',
          targetFormat: TargetFormat.pdf,
          customExportDir: Directory('build/audit').absolute.path,
          isRtl: true);
      final bytes = await File(result.outputFilePath).readAsBytes();
      final png = await NativeBridgeService.renderPdfPageToPng(bytes, 0);
      expect(png, isNotNull);
      await File('build/audit/mixed-export.png').writeAsBytes(png!);
      final text = await OfflineOcrEngine.recognizeText(png);
      await File('build/audit/pdf-export-ocr.txt').writeAsString(text);
      expect(text, contains('Scanora'));
      expect(text, contains('فارسی'));
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets(
      'Imported dictionary and repeated voice restarts preserve real WAV synthesis',
      (tester) async {
    await tester.runAsync(() async {
      final previous = NativeBridgeService.espeakDataOverride;
      final bytes =
          await File('windows/espeak-ng/espeak-ng-data/en_dict').readAsBytes();
      final destination = await EspeakDictionaryService.importDictionary(
          'en_dict', bytes,
          storageDirectory: Directory('build/audit/dictionary-test').absolute);
      try {
        NativeBridgeService.espeakDataOverride = destination;
        for (var i = 0; i < 3; i++) {
          expect(await EspeakTtsService.restartEngine(), isTrue);
          final wav = await EspeakTtsService.synthesizeToWavBytes(
              'Scanora reads with the imported dictionary.',
              settings: SettingsService());
          expect(wav.length, greaterThan(1000));
          expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
        }
      } finally {
        NativeBridgeService.espeakDataOverride = previous;
        await EspeakTtsService.restartEngine();
        final directory = Directory(destination).absolute;
        final allowed = Directory('build/audit/dictionary-test').absolute.path;
        if (directory.path.startsWith('$allowed${Platform.pathSeparator}')) {
          await directory.delete(recursive: true);
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
