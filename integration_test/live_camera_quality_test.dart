import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:scanora/services/native_bridge_service.dart';
import 'package:scanora/services/ocr/offline_ocr_engine.dart';
import 'package:scanora/services/ocr/onnx_text_detector_service.dart';
import 'package:scanora/services/pdf/pdf_service.dart';
import 'package:scanora/services/vision/image_description_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Camera quality OCR reads English, Persian and mixed samples',
      (tester) async {
    for (final (file, expected) in [
      ('english_document.png', ['Scanora', 'without internet', '12345']),
      ('persian_document.png', ['اسکنورا', 'فارسی', 'اینترنت']),
      ('mixed_line.png', ['Scanora', 'سلام', '123']),
    ]) {
      final source =
          img.decodeImage(await File('test/fixtures/$file').readAsBytes())!;
      // Exercise focus loss and compression with a known reference text.
      final photo =
          img.encodeJpg(img.gaussianBlur(source, radius: 1), quality: 82);
      for (final bookPage in [false, true]) {
        final read = await OfflineOcrEngine.recognizeCameraText(photo,
            bookPage: bookPage);
        for (final word in expected) {
          expect(read.text, contains(word), reason: '$file, book=$bookPage');
        }
        expect(read.confidence, greaterThanOrEqualTo(.66), reason: file);
      }
    }
  });

  testWidgets(
      'Offline object description reads real print and skips blank surfaces',
      (tester) async {
    final street = img
        .decodeImage(await File('test/fixtures/vision_bus.jpg').readAsBytes())!;
    final subject =
        img.copyCrop(street, x: 43, y: 399, width: 185, height: 508);
    final scene = img.Image(width: 225, height: 588, numChannels: 3);
    img.fill(scene, color: img.ColorRgb8(245, 245, 245));
    img.compositeImage(scene, subject, dstX: 20, dstY: 0);
    for (final labeled in [false, true]) {
      if (labeled) {
        img.drawString(scene, 'SCANORA',
            font: img.arial24, x: 60, y: 540, color: img.ColorRgb8(20, 20, 20));
      }
      final result = await ImageDescriptionService.describeOffline(
        imageBytes: img.encodePng(scene),
        isPersian: false,
      );
      expect(result.description.toLowerCase(), contains('person'));
      if (labeled) {
        expect(result.extractedText?.toUpperCase(), contains('SCANORA'));
        expect(result.description, contains('Text read from the image'));
        expect(result.description.indexOf('person'),
            lessThan(result.description.indexOf('Text read from the image')));
      } else {
        expect(result.extractedText, isEmpty);
        expect(result.description, isNot(contains('Text read from the image')));
      }
    }
  });

  testWidgets('Camera quality OCR leaves an unreadable image empty',
      (tester) async {
    final frame = img.Image(width: 720, height: 540, numChannels: 3);
    img.fill(frame, color: img.ColorRgb8(88, 88, 88));
    final read =
        await OfflineOcrEngine.recognizeCameraText(img.encodeJpg(frame));
    expect(read.text, isEmpty);
  });

  testWidgets('Windows file-backed PDF stays readable with responsive OCR',
      (tester) async {
    final directory =
        await Directory.systemTemp.createTemp('scanora_pdf_perf_');
    final file = File('${directory.path}/Scanned test.pdf');
    try {
      final pdf = PdfDocument();
      try {
        final photo =
            await File('test/fixtures/english_document.png').readAsBytes();
        pdf.pages
            .add()
            .graphics
            .drawImage(PdfBitmap(photo), const Rect.fromLTWH(20, 30, 500, 214));
        await file.writeAsBytes(Uint8List.fromList(await pdf.save()));
      } finally {
        pdf.dispose();
      }
      final loading = Stopwatch()..start();
      final source = await PdfService.extractPdfFile(
          path: file.path, fileName: 'Scanned test.pdf', isOfflineMode: true);
      expect(source.pages.single.needsOcr, isTrue);
      final bytes = await NativeBridgeService.renderPdfPageAsPng(
          pdfPath: file.path, pageIndex: source.pages.single.sourcePageIndex);
      loading.stop();
      expect(bytes, isNotNull);
      await NativeBridgeService.ensureTessDataExtracted();
      await OnnxTextDetectorService.ensureInitialized();
      for (final responsive in [false, true]) {
        final timer = Stopwatch()..start();
        var lastTick = 0, longestGap = 0;
        final pulse = Timer.periodic(const Duration(milliseconds: 20), (_) {
          final elapsed = timer.elapsedMilliseconds;
          final gap = elapsed - lastTick;
          if (gap > longestGap) longestGap = gap;
          lastTick = elapsed;
        });
        try {
          final text = await OfflineOcrEngine.recognizeText(
            bytes!,
            preferResponsive: responsive,
          );
          expect(text, contains('without internet'));
          final tailGap = timer.elapsedMilliseconds - lastTick;
          if (tailGap > longestGap) longestGap = tailGap;
          debugPrint('PDF input and render ${loading.elapsedMilliseconds} ms, '
              'responsive=$responsive OCR ${timer.elapsedMilliseconds} ms, '
              'longest Dart timer gap $longestGap ms');
        } finally {
          pulse.cancel();
        }
      }
    } finally {
      if (await file.exists()) await file.delete();
      await directory.delete();
    }
  }, skip: !Platform.isWindows);
}
