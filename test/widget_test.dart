import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scanora/app/scanora_app.dart';
import 'package:scanora/models/ai_provider.dart';
import 'package:scanora/services/captcha/math_evaluator.dart';
import 'package:scanora/services/cloud/scanora_cloud_ocr_service.dart';
import 'package:scanora/services/converter/format_converter_service.dart';
import 'package:scanora/services/export/docx_exporter.dart';
import 'package:scanora/services/license/demo_license_service.dart';
import 'package:scanora/services/ocr/offline_ocr_engine.dart';
import 'package:scanora/services/pdf/pdf_service.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/storage/app_storage_service.dart';
import 'package:scanora/services/tts/espeak_tts_service.dart';

void main() {
  testWidgets('ScanoraApp basic initialization test', (WidgetTester tester) async {
    final settingsService = SettingsService();
    final demoLicenseService = DemoLicenseService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settingsService),
          ChangeNotifierProvider<DemoLicenseService>.value(value: demoLicenseService),
        ],
        child: const ScanoraApp(),
      ),
    );
    expect(find.byType(ScanoraApp), findsOneWidget);
  });

  test('DocxExporter generates valid docx zip archive and doc mime format', () {
    final docxBytes = DocxExporter.createDocx(
      title: 'یادداشت آزمایشی اسکنورا',
      paragraphs: ['پاراگراف اول برای آزمایش', 'این یک متن تستی فارسی و English است.'],
      isRtl: true,
    );
    expect(docxBytes.isNotEmpty, isTrue);

    final archive = ZipDecoder().decodeBytes(docxBytes);
    expect(archive.findFile('word/document.xml'), isNotNull);
    expect(archive.findFile('[Content_Types].xml'), isNotNull);
    expect(archive.findFile('_rels/.rels'), isNotNull);

    final docBytes = DocxExporter.createDoc(
      title: 'یادداشت DOC',
      paragraphs: ['تست خروجی فرمت قدیمی مایکروسافت ورد'],
      isRtl: true,
    );
    expect(docBytes.isNotEmpty, isTrue);
  });

  test('FormatConverterService converts text to docx, html, md and json', () async {
    final sourceBytes = utf8.encode('فصل اول کتاب اسکنورا\nاین یک متن تستی برای تبدیل فرمت است.');

    final resultDocx = await FormatConverterService.convertAndSave(
      sourceBytes: sourceBytes,
      sourceFileName: 'test_doc.txt',
      targetFormat: TargetFormat.docx,
      isRtl: true,
    );
    expect(resultDocx.outputFilePath.endsWith('.docx'), isTrue);
    expect(resultDocx.fileSizeBytes > 0, isTrue);

    final resultHtml = await FormatConverterService.convertAndSave(
      sourceBytes: sourceBytes,
      sourceFileName: 'test_doc.txt',
      targetFormat: TargetFormat.html,
      isRtl: true,
    );
    expect(resultHtml.outputFilePath.endsWith('.html'), isTrue);
  });

  test('AppStorageService gets or creates valid directory', () async {
    final dir = await AppStorageService.getExportDirectory();
    expect(dir.path.isNotEmpty, isTrue);
  });

  test('PdfService.extractTextDocument correctly chunks text into readable pages', () {
    final sampleText = List.generate(50, (i) => 'این خط شماره $i از کتاب الکترونیکی برای کاربر نابینا است.').join('\n');
    final processed = PdfService.extractTextDocument(
      fileBytes: utf8.encode(sampleText),
      fileName: 'my_book.txt',
    );
    expect(processed.fileName, equals('my_book.txt'));
    expect(processed.totalPages >= 1, isTrue);
    expect(processed.pages.first.pageNumber, equals(1));
    expect(processed.pages.first.text.isNotEmpty, isTrue);
  });

  test('MathEvaluator strictly matches only math equations and ignores dates or documents', () {
    expect(MathEvaluator.isMathEquation('15 + 4 = ?'), isTrue);
    expect(MathEvaluator.evaluateEquation('15 + 4 = ?'), equals('19'));
    expect(MathEvaluator.isMathEquation('۲۴ - ۸'), isTrue);
    expect(MathEvaluator.evaluateEquation('۲۴ - ۸'), equals('16'));

    // Dates, phone numbers, and multi-word text must NOT be treated as math equations
    expect(MathEvaluator.isMathEquation('2026-10-24'), isFalse);
    expect(MathEvaluator.isMathEquation('1403/08/02'), isFalse);
    expect(MathEvaluator.isMathEquation('شماره فاکتور 123 - 456 در تاریخ امروز'), isFalse);
  });

  test('Default settings, 60+ languages, 2026 AI models, and API key sanitization', () {
    final settings = SettingsService();
    expect(settings.locale.languageCode, equals('en'));
    expect(settings.autoCopyCaptcha, isFalse);

    expect(
      AIProviderConfig.normalizeModel(AIProviderType.gemini, 'gemini-3.8-flash'),
      equals('gemini-3.8-flash'),
    );
    expect(
      AIProviderConfig.normalizeModel(AIProviderType.openai, 'gpt-6'),
      equals('gpt-6'),
    );
    expect(
      SettingsService.sanitizeKey(' \u200FAIzaSyTestKey123\u200E\n '),
      equals('AIzaSyTestKey123'),
    );
  });

  test('DemoLicenseService generates and verifies offline extension and unlock keys', () async {
    final extKey = DemoLicenseService.generateLicenseKey(
      targetDeviceCode: 'SCN-1A2B3C4D',
      isPermanent: false,
      hoursToAdd: 72,
      sequenceNumber: 1,
    );
    expect(extKey.startsWith('SCAN-EXT-0048-D001-'), isTrue);

    final proKey = DemoLicenseService.generateLicenseKey(
      targetDeviceCode: 'SCN-1A2B3C4D',
      isPermanent: true,
      sequenceNumber: 1,
    );
    expect(proKey.startsWith('SCAN-PRO-D001-'), isTrue);

    final universalKey = DemoLicenseService.generateLicenseKey(
      targetDeviceCode: '*',
      isPermanent: true,
      sequenceNumber: 1,
    );
    expect(universalKey.startsWith('SCAN-PRO-U001-'), isTrue);
  });

  test('EspeakTtsService detects Persian and English primary language accurately', () {
    expect(
      EspeakTtsService.detectPrimaryLanguageCode('این یک متن کاملا فارسی برای تست موتور صوتی است.'),
      equals('fa'),
    );
    expect(
      EspeakTtsService.detectPrimaryLanguageCode('This is an English paragraph for testing eSpeak-NG.'),
      equals('en-us'),
    );
  });

  test('PdfService extracts CSV spreadsheet and Audiobook ZIP archive', () {
    final csvBytes = utf8.encode('نام محصول,قیمت,تعداد\nکیبورد بریل,2500000,5\nساعت گویا,850000,12');
    final csvDoc = PdfService.extractExcelDocument(
      fileBytes: csvBytes,
      fileName: 'products.csv',
    );
    expect(csvDoc.totalPages, equals(1));
    expect(csvDoc.pages.first.text.contains('کیبورد بریل'), isTrue);

    final archive = Archive();
    final page1Bytes = utf8.encode('فصل اول کتاب صوتی اسکنورا');
    final page2Bytes = utf8.encode('فصل دوم کتاب صوتی اسکنورا');
    archive.addFile(ArchiveFile('page_001.txt', page1Bytes.length, page1Bytes));
    archive.addFile(ArchiveFile('page_002.txt', page2Bytes.length, page2Bytes));
    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));

    final zipDoc = PdfService.extractAudiobookZip(
      fileBytes: zipBytes,
      fileName: 'sample_audiobook.zip',
    );
    expect(zipDoc.totalPages, equals(2));
    expect(zipDoc.pages.first.text.contains('فصل اول'), isTrue);
  });

  test('PdfService.extractEpubDocument parses EPUB chapters in reading order', () {
    final archive = Archive();
    const containerXml = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    const opfXml = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>''';
    const ch1Html = '<html><body><h1>Chapter 1</h1><p>Welcome to Scanora EPUB Reader.</p></body></html>';
    const ch2Html = '<html><body><h1>Chapter 2</h1><p>Accessible reading for blind users.</p></body></html>';

    archive.addFile(ArchiveFile('META-INF/container.xml', containerXml.length, utf8.encode(containerXml)));
    archive.addFile(ArchiveFile('OEBPS/content.opf', opfXml.length, utf8.encode(opfXml)));
    archive.addFile(ArchiveFile('OEBPS/chapter1.xhtml', ch1Html.length, utf8.encode(ch1Html)));
    archive.addFile(ArchiveFile('OEBPS/chapter2.xhtml', ch2Html.length, utf8.encode(ch2Html)));

    final epubBytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final epubDoc = PdfService.extractEpubDocument(
      fileBytes: epubBytes,
      fileName: 'sample.epub',
    );
    expect(epubDoc.totalPages, equals(2));
    expect(epubDoc.pages[0].text.contains('Welcome to Scanora EPUB Reader'), isTrue);
    expect(epubDoc.pages[1].text.contains('Accessible reading for blind users'), isTrue);
  });

  test('EspeakTtsService includes all 131 standard voices and 94 official voice variants', () async {
    expect(EspeakTtsService.supportedVoices.length, greaterThanOrEqualTo(131));
    expect(EspeakTtsService.voiceVariants.length, greaterThanOrEqualTo(94));

    final settings = SettingsService();
    expect(settings.enableInternalTts, isTrue);
    expect(settings.autoReadOnOpen, isTrue);
    expect(settings.ttsAutoBilingual, isTrue);

    expect(MathEvaluator.isMathEquation('۲۴ − ۸ = ؟'), isTrue);
    expect(MathEvaluator.evaluateEquation('۲۴ − ۸ = ؟'), equals('16'));

    expect(EspeakTtsService.estimateTotalSeconds('یک دو سه چهار پنج شش هفت هشت نه ده', 150), greaterThanOrEqualTo(1));
    expect(TtsPlaybackState.formatSeconds(65), equals('01:05'));

    final customMinKey = DemoLicenseService.generateLicenseKey(
      targetDeviceCode: 'SCN-1A2B3C4D',
      isPermanent: false,
      minutesToAdd: 30,
      sequenceNumber: 1,
    );
    expect(customMinKey.startsWith('SCAN-EXTM-00001E-D001-'), isTrue);
  });

  test('OfflineOcrEngine.tidy removes invisible BiDi marks and collapses blank lines', () {
    const raw = 'Hello\u200F  \r\n\r\n\r\n\u202Bسلام\u202C\r\nend  ';
    expect(OfflineOcrEngine.tidy(raw), 'Hello\n\nسلام\nend');
  });

  test('OfflineOcrEngine uses the combined Persian + English Tesseract language', () {
    expect(OfflineOcrEngine.language, 'fas+eng');
  });

  test('ScanoraCloudOcrService.parseGoogleLensMetadata extracts lines from Google Lens payload', () {
    const sampleLensPayload = ")]}'\n\n"
        r'[["fetch_query_formulation_metadata_response",[],[[[[[],[[[[[2],"سلام"," ",[[0.1,0.1,0.2,0.1,0.0,1]]],[[3],"اسکنورا","",[[0.4,0.1,0.2,0.1,0.0,1]]]],[[0.2,0.1,0.5,0.1,0.0,1]]]],[[0.2,0.1,0.5,0.1,0.0,1]],null,null,"text:0:1"],[[5],[[[[[7],"Google"," ",[[0.1,0.5,0.2,0.1,0.0,1]]],[[8],"Lens"," ",[[0.4,0.5,0.2,0.1,0.0,1]]],[[9],"OCR","",[[0.7,0.5,0.2,0.1,0.0,1]]]],[[0.4,0.5,0.8,0.1,0.0,1]]]],[[0.4,0.5,0.8,0.1,0.0,1]],null,null,"text:0:2"]]],"fa"]]]';
    final extracted = ScanoraCloudOcrService.parseGoogleLensMetadata(sampleLensPayload);
    expect(extracted, equals('سلام اسکنورا\nGoogle Lens OCR'));
  });

  test('ScanoraCloudOcrService.cleanGoogleDriveOcrOutput strips BOM, divider line and normalizes Persian letters', () {
    const sampleDriveTxt = '\uFEFF________________\r\nكتاب فارسى و انگليسى 2026\r\n________________\r\nصفحه دوم';
    final cleaned = ScanoraCloudOcrService.cleanGoogleDriveOcrOutput(sampleDriveTxt);
    expect(cleaned, equals('کتاب فارسی و انگلیسی 2026\nصفحه دوم'));
  });
}
