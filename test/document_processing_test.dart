import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanora/models/pdf_document.dart';
import 'package:scanora/services/cloud/google_account_service.dart';
import 'package:scanora/services/converter/format_converter_service.dart';
import 'package:scanora/services/ocr/ocr_service.dart';
import 'package:scanora/services/pdf/document_batch_processor.dart';
import 'package:scanora/services/pdf/document_work.dart';
import 'package:scanora/services/pdf/pdf_service.dart';
import 'package:scanora/services/stt/whisper_onnx_service.dart';
import 'package:scanora/ui/widgets/accessible_output_text.dart';
import 'package:scanora/ui/widgets/confirm_dialog.dart';
import 'package:scanora/ui/widgets/document_page_range_dialog.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Large single-line TXT files are paginated without splitting characters',
      () async {
    final directory = await Directory.systemTemp.createTemp('scanora_txt_');
    final file = File('${directory.path}/continuous.txt');
    addTearDown(() async {
      await file.delete();
      await directory.delete();
    });
    final text = 'ا\u0654🙂' * 300000;
    await file.writeAsString(text);
    final watch = Stopwatch()..start();
    final document = await PdfService.extractTextFileAsync(
        path: file.path, fileName: 'continuous.txt');
    watch.stop();
    debugPrint('Paginated 2.4 MB UTF-8 TXT in ${watch.elapsedMilliseconds} ms');
    expect(document.totalPages, greaterThan(1));
    expect(document.pages.every((page) => page.text.length <= 2500), isTrue);
    expect(
        document.pages.every((page) =>
            page.text.endsWith('🙂') || page.text.endsWith('ا\u0654')),
        isTrue);
    expect(document.pages.map((page) => page.text).join(), text);
  });

  testWidgets('Cancelling a running operation requires a separate confirmation',
      (tester) async {
    final work = DocumentWork(isPersian: false);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () async {
                    if (await confirmCancelOperation(context)) work.cancel();
                  },
                  child: const Text('Cancel processing'),
                )),
      ),
    ));
    await tester.tap(find.text('Cancel processing'));
    await tester.pumpAndSettle();
    expect(work.isCancelled, isFalse);
    await tester.tap(find.text('Continue working'));
    await tester.pumpAndSettle();
    expect(work.isCancelled, isFalse);
    await tester.tap(find.text('Cancel processing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes, cancel'));
    await tester.pumpAndSettle();
    expect(work.isCancelled, isTrue);
  });

  test('Cancelled conversion never creates the output file', () async {
    final work = DocumentWork(isPersian: false);
    final directory = await Directory.systemTemp.createTemp('scanora_cancel_');
    try {
      await expectLater(
        FormatConverterService.convertAndSave(
          sourceBytes: Uint8List(0),
          sourceFileName: 'example.txt',
          targetFormat: TargetFormat.txt,
          preExtractedParagraphs: ['Some example text'],
          customExportDir: directory.path,
          work: work,
          onProgress: (percent, _) {
            if (percent == 80) work.cancel();
          },
        ),
        throwsA(isA<DocumentProcessingCancelled>()),
      );
      expect(await directory.list().isEmpty, isTrue);
    } finally {
      await directory.delete();
    }
  });

  test('PDF conversion keeps the edited file name and preserves existing files',
      () async {
    final directory = await Directory.systemTemp.createTemp('scanora_name_');
    final source = File('${directory.path}/Original document.pdf');
    final existing = File('${directory.path}/Edited title.docx');
    File? output;
    try {
      final pdf = PdfDocument();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 14);
      for (var i = 0; i < 6; i++) {
        pdf.pages
            .add()
            .graphics
            .drawString('This is text on page ${i + 1}.', font);
      }
      await source.writeAsBytes(pdf.saveSync());
      pdf.dispose();
      await existing.writeAsString('Existing output');
      final result = await FormatConverterService.convertAndSave(
        sourceBytes: Uint8List(0),
        sourceFilePath: source.path,
        sourceFileName: 'Original document.pdf',
        targetFormat: TargetFormat.docx,
        outputStem: 'Edited title',
        customExportDir: directory.path,
      );
      output = File(result.outputFilePath);
      expect(output.uri.pathSegments.last, 'Edited title (2).docx');
      expect(await existing.readAsString(), 'Existing output');
      expect(await output.length(), greaterThan(0));
    } finally {
      if (await source.exists()) await source.delete();
      if (await existing.exists()) await existing.delete();
      if (output != null && await output.exists()) await output.delete();
      await directory.delete();
    }
  });

  test('Cancelling PDF preparation shuts down the extraction worker', () async {
    final work = DocumentWork(isPersian: false)..cancel();
    final pdf = PdfDocument();
    pdf.pages.add();
    final bytes = Uint8List.fromList(pdf.saveSync());
    pdf.dispose();
    await expectLater(
      PdfService.extractPdfPages(
        pdfBytes: bytes,
        fileName: 'cancelled.pdf',
        isOfflineMode: true,
        cancelled: work.whenCancelled,
      ),
      throwsA(isA<DocumentProcessingCancelled>()),
    );
  });
  test(
      'Mixed document awaits OCR, retains original image indices and counts failures',
      () async {
    final rendered = <int>[];
    final progress = <DocumentProgress>[];
    final result = await DocumentBatchProcessor.process(
        pages: [
          PdfPageInfo(pageNumber: 3, text: 'Embedded text'),
          PdfPageInfo(pageNumber: 4, text: '', needsOcr: true),
          PdfPageInfo(pageNumber: 5, text: '', needsOcr: true),
          PdfPageInfo(pageNumber: 6, text: '', needsOcr: true),
        ],
        render: (i) async {
          rendered.add(i);
          if (i == 5) throw StateError('Rendering failed');
          return Uint8List.fromList([i]);
        },
        recognize: (bytes) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return ScanRecognitionResult(
              text: bytes[0] == 3 ? 'متن OCR English 123' : '',
              isOffline: true,
              engine: 'fixture',
              errorMessage: 'No text');
        },
        onProgress: progress.add);
    expect(rendered, [3, 4, 5]);
    expect(result.progress.extracted, 1);
    expect(result.progress.recognized, 1);
    expect(result.progress.failed, 2);
    expect(result.progress.successful, 2);
    expect(progress.last.percent, 100);
    expect(result.pages[1].sourcePageIndex, 3);
    expect(result.pages[2].ocrError, isNotEmpty);
    expect(result.pages[2].text, isEmpty);
  });
  test('Cancelling a document prevents the next page from starting', () async {
    var cancelled = false, rendered = 0;
    await expectLater(
        DocumentBatchProcessor.process(
            pages: List.generate(
                3,
                (i) =>
                    PdfPageInfo(pageNumber: i + 1, text: '', needsOcr: true)),
            render: (_) async {
              rendered++;
              return Uint8List(1);
            },
            recognize: (_) async {
              cancelled = true;
              return const ScanRecognitionResult(
                  text: 'Page', isOffline: true, engine: 'fixture');
            },
            onProgress: (_) {},
            isCancelled: () => cancelled),
        throwsA(isA<DocumentProcessingCancelled>()));
    expect(rendered, 1);
  });
  test(
      'PDF preparation reports progress and flags scanned pages without fake document text',
      () async {
    final pdf = PdfDocument();
    pdf.pages.add().graphics.drawString(
        'Scanora text page', PdfStandardFont(PdfFontFamily.helvetica, 12),
        bounds: const Rect.fromLTWH(0, 0, 300, 40));
    pdf.pages.add();
    final bytes = Uint8List.fromList(pdf.saveSync());
    pdf.dispose();
    final progress = <int>[];
    final result = await PdfService.extractPdfPages(
        pdfBytes: bytes,
        fileName: 'book.pdf',
        isOfflineMode: true,
        onProgress: progress.add);
    expect(result.pages.first.text, contains('Scanora'));
    expect(result.pages.last.needsOcr, isTrue);
    expect(result.pages.last.text, isEmpty);
    expect(progress, contains(100));
  });
  test('Corrupt embedded font text triggers OCR', () {
    expect(PdfService.hasUsableEmbeddedText('Readable English و فارسی ۱۲۳'),
        isTrue);
    expect(PdfService.hasUsableEmbeddedText('\uFFFD\uFFFD\uFFFD ABC'), isFalse);
    expect(PdfService.hasUsableEmbeddedText('\uE010\uE020\uE040'), isFalse);
  });
  testWidgets(
      'Document output keeps its original text without numbered paragraph labels',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AccessibleOutputText(
                text: 'First paragraph.\n\nبند فارسی دوم.',
                liveRegion: false,
                label: 'Page text'))));
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, 'First paragraph.\n\nبند فارسی دوم.');
    expect(field.readOnly, isTrue);
    expect(find.bySemanticsLabel('Paragraph 1'), findsNothing);
  });
  testWidgets(
      'Output reading units select and advance through the original text',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AccessibleOutputText(
                text:
                    'ا\u0654 Persian word.\nSecond line.\n\nNew paragraph.'))));
    final field = tester.widget<EditableText>(find.byType(EditableText));
    String selected() =>
        field.controller.selection.textInside(field.controller.text);
    Future<void> choose(String current, String next) async {
      await tester.tap(find.text(current));
      await tester.pumpAndSettle();
      await tester.tap(find.text(next).last);
      await tester.pumpAndSettle();
    }

    await choose('Full text', 'Character');
    expect(selected(), 'ا\u0654');
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(selected(), ' ');
    await choose('Character', 'Word');
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(selected(), 'Persian');
    await tester.tap(find.text('Previous'));
    await tester.pump();
    expect(selected(), 'ا\u0654');
    await choose('Word', 'Line');
    expect(selected(), 'ا\u0654 Persian word.');
    await choose('Line', 'Paragraph');
    expect(selected(), 'ا\u0654 Persian word.\nSecond line.');
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(selected(), 'New paragraph.');
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
  test('OAuth callback uses only the selected interface language', () {
    final en =
        GoogleAccountService.callbackPage(success: true, isPersian: false);
    expect(en, contains('lang="en"'));
    expect(en, contains('Google access verified'));
    expect(RegExp(r'[\u0600-\u06FF]').hasMatch(en), isFalse);
    expect(GoogleAccountService.callbackPage(success: true, isPersian: true),
        isNot(contains('Google access verified')));
  });
  test('Silent and near-silent samples cannot trigger Whisper transcription',
      () {
    expect(WhisperOnnxService.hasAudibleSignal(Float32List(16000)), isFalse);
    expect(
        WhisperOnnxService.hasAudibleSignal(
            Float32List.fromList(List.filled(16000, 0.0001))),
        isFalse);
  });
  testWidgets(
      'Labeled page range accepts Persian digits and a force-OCR choice',
      (tester) async {
    PageRangeSelection? selection;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      selection = await showDialog<PageRangeSelection>(
                          context: context,
                          builder: (_) => const DocumentPageRangeDialog(
                              totalPages: 20, allowForceOcr: true));
                    },
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Start Page'), findsOneWidget);
    expect(find.text('End Page'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('start-page')), '۳');
    await tester.enterText(find.byKey(const ValueKey('end-page')), '۸');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Start Processing'));
    await tester.pumpAndSettle();
    expect(selection!.start, 3);
    expect(selection!.end, 8);
    expect(selection!.forceOcr, isTrue);
  });
}
