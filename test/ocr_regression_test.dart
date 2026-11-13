import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:scanora/services/a11y/reader_feedback.dart';
import 'package:scanora/services/cloud/google_drive_ocr_client.dart';
import 'package:scanora/services/cloud/desktop_token_store.dart';
import 'package:scanora/services/cloud/google_account_service.dart';
import 'package:scanora/services/cloud/scanora_cloud_ocr_service.dart';
import 'package:scanora/services/native_bridge_service.dart';
import 'package:scanora/services/ocr/offline_ocr_engine.dart';
import 'package:scanora/services/ocr/onnx_text_detector_service.dart';
import 'package:scanora/services/ocr/page_turn_tracker.dart';
import 'package:scanora/services/pdf/pdf_service.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/tts/espeak_tts_service.dart';
import 'package:scanora/services/vision/onnx_vision_classifier_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Live OCR suppresses weak text and preserves confident short labels',
      () {
    expect(
        OfflineOcrEngine.isReadableCameraText(
            const TesseractRead('Q ب ; O', .41)),
        isFalse);
    expect(OfflineOcrEngine.isReadableCameraText(const TesseractRead('A', .69)),
        isFalse);
    expect(OfflineOcrEngine.isReadableCameraText(const TesseractRead('A', .96)),
        isTrue);
    expect(
        OfflineOcrEngine.isReadableCameraText(
            const TesseractRead('سلام Scanora 123', .87)),
        isTrue);
  });

  test('A dark camera image passes its inverted pixels to the OCR engine',
      () async {
    final dark = image.Image(width: 640, height: 240, numChannels: 3);
    image.fill(dark, color: image.ColorRgb8(10, 10, 10));
    image.drawString(dark, 'SCANORA 12345 SCANORA 12345',
        x: 48,
        y: 100,
        font: image.arial48,
        color: image.ColorRgb8(245, 245, 245));
    final result = await OnnxTextDetectorService.detectAndDeskew(
        image.encodePng(dark),
        fastLiveMode: true);
    final normalized = image.decodePng(result.deskewedPngBytes)!;
    expect(normalized.getPixel(0, 0).r, greaterThan(225));
  });

  test('Real Windows PDF rendering preserves enough pixels for offline OCR',
      () async {
    if (!Platform.isWindows) return;
    final document = PdfDocument();
    final page = document.pages.add();
    final picture = PdfBitmap(
        await File('test/fixtures/english_document.png').readAsBytes());
    page.graphics.drawImage(picture, const Rect.fromLTWH(20, 30, 500, 214));
    final bytes = Uint8List.fromList(await document.save());
    document.dispose();
    final dir = await Directory.systemTemp.createTemp('scanora_pdf_test_');
    final file = File('${dir.path}/Scanora document.pdf');
    try {
      await file.writeAsBytes(bytes);
      final source = await PdfService.extractPdfFile(
          path: file.path,
          fileName: 'Scanora document.pdf',
          isOfflineMode: true);
      expect(source.pages.single.needsOcr, isTrue);
      final png = await NativeBridgeService.renderPdfPageAsPng(
          pdfPath: file.path, pageIndex: source.pages.single.sourcePageIndex);
      expect(png, isNotNull);
      final decoded = image.decodeImage(png!);
      expect(decoded, isNotNull);
      expect(decoded!.height, greaterThanOrEqualTo(3000));
      final text =
          await OfflineOcrEngine.recognizeText(png, preferResponsive: true);
      expect(text, contains('Scanora'));
      expect(text, contains('without internet'));
    } finally {
      if (await file.exists()) await file.delete();
      await dir.delete();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Minor OCR noise does not save the same book page twice', () {
    const page =
        'Scanora offline document reader. Camera recognition works without internet. Please turn the page after capture.';
    expect(
        PageTurnTracker.sameText(page, page.replaceFirst('Scanora', 'Scenora')),
        isTrue);
    expect(
        PageTurnTracker.sameText(page,
            'A different chapter about Persian literature and accessible audio books.'),
        isFalse);
  });

  test('Object counts suppress overlapping duplicate YOLO anchors', () {
    const anchors = 3;
    final output = List<double>.filled(84 * anchors, 0);
    for (var i = 0; i < anchors; i++) {
      output[i] = i == 2 ? 400 : 100 + i.toDouble();
      output[anchors + i] = 150;
      output[2 * anchors + i] = 80;
      output[3 * anchors + i] = 120;
      output[4 * anchors + i] = 0.9;
    }
    final objects =
        OnnxVisionClassifierService.decodeYolo(output, [1, 84, anchors]);
    expect(objects.single.labelEn, 'Person');
    expect(objects.single.count, 2);
  });

  test('Windows session encryption round-trips without storing plaintext', () {
    if (!Platform.isWindows) return;
    final source = Uint8List.fromList([83, 99, 97, 110, 111, 114, 97]);
    final encrypted = DesktopTokenStore.protect(source);
    expect(encrypted, isNot(source));
    expect(DesktopTokenStore.protect(encrypted, decrypt: true), source);
  });

  test('Bundled speech worker produces real Persian and English WAV audio',
      () async {
    if (!Platform.isWindows) return;
    final wav = await EspeakTtsService.synthesizeToWavBytes(
        'سلام. Scanora reads this text offline.',
        settings: SettingsService());
    expect(wav.length, greaterThan(1000));
    expect(String.fromCharCodes(wav.take(4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
  });

  test(
      'A settled page change is detected even when a turn happened between samples',
      () {
    final tracker = PageTurnTracker();
    final original = Uint8List.fromList(List.filled(4096, 220));
    tracker.captured(original);
    expect(tracker.observe(original, motion: 0), isFalse);
    final changed = Uint8List.fromList(original);
    for (var i = 1000; i < 1800; i++) {
      changed[i] = 100;
    }
    expect(tracker.observe(changed, motion: 0.02), isFalse);
    expect(tracker.observe(changed, motion: 0), isTrue);
    tracker.captured(changed);
    expect(tracker.observe(changed, motion: 0), isFalse);
  });

  test('Exposure changes and a moving hand do not immediately save a new page',
      () {
    final tracker = PageTurnTracker();
    tracker.captured(Uint8List.fromList(List.filled(4096, 200)));
    final brighter = Uint8List.fromList(List.filled(4096, 215));
    expect(tracker.observe(brighter, motion: 0), isFalse);
    expect(tracker.observe(brighter, motion: 0), isFalse);
    final hand = Uint8List(4096);
    expect(tracker.observe(hand, motion: 0.5), isFalse);
  });

  testWidgets('Internal TTS off sends recognized text to the screen reader',
      (tester) async {
    final messages = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (message) async {
      messages.add(message);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility, null));
    late BuildContext outputContext;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      outputContext = context;
      return const Text('Reader');
    })));
    final settings = SettingsService();
    await settings.setEnableInternalTts(false);
    expect(settings.enableInternalTts, isFalse);
    await ReaderFeedback.speak(outputContext, 'متن آزمایشی 123', settings,
        assertive: true);
    expect(
        messages,
        contains(predicate<Object?>(
            (value) => value.toString().contains('متن آزمایشی 123'))));
    expect(EspeakTtsService.isSpeakingNotifier.value, isFalse);
  });

  test('Cloud import requests a Google document and exports its actual text',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.headers['Authorization'], 'Bearer real-test-token');
      if (request.method == 'POST') {
        expect(request.url.path, '/upload/drive/v3/files');
        expect(request.url.queryParameters['ocrLanguage'], 'fa');
        expect(request.body, contains('application/vnd.google-apps.document'));
        return http.Response(
            '{"id":"created-doc","mimeType":"application/vnd.google-apps.document"}',
            200);
      }
      if (request.method == 'GET') {
        return http.Response('Google OCR result', 200);
      }
      return http.Response('', 204);
    });
    final text = await GoogleDriveOcrClient(client).recognize(
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/jpeg',
        fileName: 'page.jpg',
        accessToken: 'real-test-token',
        language: 'fa');
    expect(text, 'Google OCR result');
    expect(requests.map((r) => r.method), ['POST', 'GET', 'DELETE']);
    expect(requests.last.url.path, '/drive/v3/files/created-doc');
  });

  test('Cloud waits for document readiness and cleans up after export failure',
      () async {
    var gets = 0;
    var deleted = false;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        return http.Response(
            '{"id":"doc","mimeType":"application/vnd.google-apps.document"}',
            200);
      }
      if (request.method == 'DELETE') {
        deleted = true;
        return http.Response('', 204);
      }
      gets++;
      return http.Response('not ready', 503);
    });
    await expectLater(
        GoogleDriveOcrClient(client, delay: (_) async {}).recognize(
            bytes: Uint8List(3),
            mimeType: 'image/jpeg',
            fileName: 'page.jpg',
            accessToken: 'test',
            language: 'fa'),
        throwsStateError);
    expect(gets, 4);
    expect(deleted, isTrue);
  });

  test('A nonconverted upload is rejected and deleted', () async {
    var deleted = false;
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        deleted = true;
        return http.Response('', 204);
      }
      return http.Response('{"id":"image","mimeType":"image/jpeg"}', 200);
    });
    await expectLater(
        GoogleDriveOcrClient(client).recognize(
            bytes: Uint8List(3),
            mimeType: 'image/jpeg',
            fileName: 'page.jpg',
            accessToken: 'test',
            language: 'en'),
        throwsStateError);
    expect(deleted, isTrue);
  });

  test('Missing publisher OAuth never reports a successful Google connection',
      () async {
    if (!Platform.isWindows || GoogleAccountService.desktopConfigured) return;
    expect(await ScanoraCloudOcrService.authorizeWithBrowser(), isFalse);
    expect(ScanoraCloudOcrService.syncStatusNotifier.value.stage,
        CloudSyncStage.error);
  });

  group('Real bundled Windows OCR without network', () {
    test('Fast and high quality use separate complete language packs',
        () async {
      final fast =
          await NativeBridgeService.ensureTessDataExtracted(fast: true);
      final best = await NativeBridgeService.ensureTessDataExtracted();
      expect(fast, isNot(best));
      expect(File('$fast/tessdata/fas.traineddata').lengthSync(), 431500);
      expect(File('$best/tessdata/eng.traineddata').lengthSync(), 15400601);
    });
    for (final fast in [true, false]) {
      test('Reads a full English document, fast=$fast', () async {
        final bytes =
            await File('test/fixtures/english_document.png').readAsBytes();
        final watch = Stopwatch()..start();
        final text = await OfflineOcrEngine.recognizeText(bytes, fast: fast);
        expect(text, contains('Scanora'));
        expect(text.toLowerCase(), contains('without internet'));
        expect(text, contains('12345'));
        // Real elapsed time is printed for the audit, not a machine-speed assertion.
        // ignore: avoid_print
        print('Real Windows OCR fast=$fast: ${watch.elapsedMilliseconds} ms');
      }, timeout: const Timeout(Duration(minutes: 2)));
    }
    test('Reads a sideways document', () async {
      final bytes =
          await File('test/fixtures/english_rotated.png').readAsBytes();
      final text = await OfflineOcrEngine.recognizeText(bytes);
      expect(text.toLowerCase(), contains('scanora'));
      expect(text, contains('12345'));
    }, timeout: const Timeout(Duration(minutes: 3)));
    test('Reads Persian words and Persian digits with the bundled model',
        () async {
      final bytes =
          await File('test/fixtures/persian_document.png').readAsBytes();
      final text = await OfflineOcrEngine.recognizeText(bytes);
      expect(text, contains('اسکنورا'));
      expect(text, contains('اینترنت'));
      expect(text, contains('کتاب'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }, skip: !Platform.isWindows);
}
