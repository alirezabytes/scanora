import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:scanora/models/ai_provider.dart';
import 'package:scanora/services/ai/ai_access.dart';
import 'package:scanora/services/ai/ai_service.dart';
import 'package:scanora/services/captcha/captcha_solver_service.dart';
import 'package:scanora/services/captcha/math_evaluator.dart';
import 'package:scanora/services/export/docx_exporter.dart';
import 'package:scanora/services/pdf/document_image_loader.dart';
import 'package:scanora/services/pdf/document_text_decoder.dart';
import 'package:scanora/services/pdf/pdf_service.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/stt/speech_to_text_service.dart';
import 'package:scanora/services/tts/tts_text_planner.dart';
import 'package:scanora/ui/settings/about_settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AiAccess.clearCache);
  test('RTF export round trips Persian, Latin, braces and Unicode escapes', () {
    final bytes = DocxExporter.createRtf(
        title: 'عنوان English',
        paragraphs: ['سلام {Scanora} \\ ۱۲۳', 'Second line'],
        isRtl: true);
    expect(ascii.decode(bytes), startsWith(r'{\rtf1'));
    final text = DocumentTextDecoder.rtf(bytes);
    expect(text, contains('سلام {Scanora} \\ ۱۲۳'));
    expect(text, contains('Second line'));
    expect(text, isNot(contains('Tahoma')));
  });
  test('UTF-16 LE and BE documents keep Persian and English text', () {
    const text = 'سلام Scanora ۱۲۳';
    for (final endian in [Endian.little, Endian.big]) {
      final data = ByteData(2 + text.length * 2)..setUint16(0, 0xFEFF, endian);
      for (var i = 0; i < text.length; i++) {
        data.setUint16(2 + i * 2, text.codeUnitAt(i), endian);
      }
      expect(
          PdfService.extractTextDocument(
                  fileBytes: data.buffer.asUint8List(), fileName: 'book.txt')
              .pages
              .first
              .text,
          text);
    }
  });
  test('Binary Word data is not reported as a successful document transcript',
      () {
    expect(
        () => PdfService.extractWordDocument(
            fileBytes: Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 65, 66, 67]),
            fileName: 'book.doc'),
        throwsUnsupportedError);
  });
  test('Image archives use natural page order instead of 1, 10, 2', () {
    final names = ['page10.png', 'page2.png', 'page1.png']
      ..sort(naturalDocumentOrder);
    expect(names, ['page1.png', 'page2.png', 'page10.png']);
  });
  test('Sparse XLSX cells retain addresses, dates and workbook sheet order',
      () {
    final zip = Archive();
    void add(String path, String text) {
      final bytes = utf8.encode(text);
      zip.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('xl/workbook.xml',
        '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="فارسی" r:id="r2"/><sheet name="English" r:id="r1"/></sheets></workbook>');
    add('xl/_rels/workbook.xml.rels',
        '<Relationships><Relationship Id="r1" Target="worksheets/sheet1.xml"/><Relationship Id="r2" Target="worksheets/sheet2.xml"/></Relationships>');
    add('xl/styles.xml',
        '<styleSheet><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>');
    add('xl/worksheets/sheet2.xml',
        '<worksheet><sheetData><row><c r="A1" t="inlineStr"><is><r><t>نام</t></r><r><t> کالا</t></r></is></c><c r="C1" s="1"><v>45292</v></c></row></sheetData></worksheet>');
    add('xl/worksheets/sheet1.xml',
        '<worksheet><sheetData><row><c r="B2"><f>1+2</f><v>3</v></c></row></sheetData></worksheet>');
    final book = PdfService.extractExcelDocument(
        fileBytes: Uint8List.fromList(ZipEncoder().encode(zip)),
        fileName: 'book.xlsx');
    expect(book.pages.first.text, startsWith('فارسی'));
    expect(book.pages.first.text, contains('A1: نام کالا'));
    expect(book.pages.first.text, contains('C1: 2024-01-01'));
    expect(book.pages.last.text, contains('B2: 3'));
  });
  test('Math captchas preserve fractions instead of truncating division', () {
    expect(MathEvaluator.evaluateEquation('۷ ÷ ۲ = ؟'), '3.5');
    expect(MathEvaluator.evaluateEquation('7/3'), '7/3');
    expect(MathEvaluator.evaluateEquation('3/0'), isNull);
    expect(MathEvaluator.evaluateEquation('۱۲ به علاوه ۳ = ؟'), '15');
    expect(MathEvaluator.evaluateEquation('12 plus 3 = ?'), '15');
  });
  test(
      'Unicode normalization changes synthesis text while preserving display text',
      () {
    final chunk = TtsTextPlanner.single('Ｓｃａｎｏｒａ １２３', configuredVoice: 'auto');
    expect(chunk.engineText, 'Scanora 123');
    expect(chunk.displayText, 'Ｓｃａｎｏｒａ １２３');
  });
  test(
      'OpenAI vision sends actual image to Responses and keeps the selected model',
      () async {
    final fixture =
        await File('test/fixtures/english_document.png').readAsBytes();
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        expect(request.url.path, '/v1/models/gpt-5');
        return http.Response('{"id":"gpt-5"}', 200);
      }
      expect(request.url.path, '/v1/responses');
      final body = jsonDecode(request.body);
      expect(body['model'], 'gpt-5');
      expect(body['store'], isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body['input'][0]['content'][1]['image_url'],
          startsWith('data:image/jpeg;base64,'));
      return http.Response(
          jsonEncode({
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'سلام Scanora 123'}
                ]
              }
            ]
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final result = await http.runWithClient(
        () => AIService.callVisionModel(
            providerType: AIProviderType.openai,
            apiKey: 'fixture-key',
            modelName: 'gpt-5',
            customBaseUrl: '',
            imageBytes: fixture,
            prompt: 'Read'),
        () => client);
    expect(result, 'سلام Scanora 123');
  });
  test(
      'Authentication failure never silently sends an image to another service',
      () async {
    var requests = 0;
    final fixture =
        await File('test/fixtures/english_document.png').readAsBytes();
    await http.runWithClient(() async {
      await expectLater(
          AIService.callVisionModel(
              providerType: AIProviderType.openai,
              apiKey: 'bad-key',
              modelName: 'gpt-5',
              customBaseUrl: '',
              imageBytes: fixture,
              prompt: 'Read'),
          throwsA(isA<AiServiceException>().having(
              (error) => error.kind, 'kind', AiFailureKind.invalidKey)));
    },
        () => MockClient((request) async {
              requests++;
              expect(request.url.host, 'api.openai.com');
              return http.Response('{"error":{"message":"Invalid key"}}', 401);
            }));
    expect(requests, 1);
  });
  test('Online captcha does not manufacture a confidence percentage', () async {
    final bytes = await File('test/fixtures/captchas/upper.png').readAsBytes();
    final result = await http.runWithClient(
        () => CaptchaSolverService.solve(
            imageBytes: bytes,
            isOfflineMode: false,
            activeProvider: AIProviderType.openai,
            apiKey: 'fixture-key',
            modelName: 'gpt-5',
            customBaseUrl: ''),
        () => MockClient((request) async => request.method == 'GET'
            ? http.Response('{"id":"gpt-5"}', 200)
            : http.Response(
                '{"output":[{"type":"message","content":[{"type":"output_text","text":"ABC123"}]}]}',
                200)));
    expect(result.finalClipboardValue, 'ABC123');
    expect(result.isOffline, isFalse);
    expect(result.confidence, isNull);
  });
  test(
      'Online transcription sends a real audio file and multilingual API fields',
      () async {
    await http.runWithClient(() async {
      final result = await SpeechToTextService.transcribeOpenAI(
          await File('test/fixtures/audio/english_reference.wav').readAsBytes(),
          key: 'fixture-key',
          language: 'fa');
      expect(result, 'سلام English');
    },
        () => MockClient((request) async {
              if (request.method == 'GET') {
                expect(request.url.path, '/v1/models/gpt-transcribe');
                return http.Response('{"id":"gpt-transcribe"}', 200);
              }
              expect(request.url.path, '/v1/audio/transcriptions');
              final multipart = latin1.decode(request.bodyBytes);
              expect(multipart, contains('gpt-transcribe'));
              expect(multipart, contains('languages[]'));
              expect(multipart, contains('scanora_recording.wav'));
              return http.Response(jsonEncode({'text': 'سلام English'}), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  });
  testWidgets('English About shows the founder and no Persian interface text',
      (tester) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: SettingsService(),
        child: const MaterialApp(home: AboutSettingsScreen())));
    expect(find.text('alireza marzbn'), findsOneWidget);
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join();
    expect(RegExp(r'[\u0600-\u06FF]').hasMatch(labels), isFalse);
    expect(
        RegExp(r'TalkBack|NVDA|ONNX|Tesseract|Whisper|INT8').hasMatch(labels),
        isFalse);
  });
}
