import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scanora/services/captcha/captcha_solver_service.dart';
import 'package:scanora/services/captcha/onnx_captcha_engine.dart';
import 'package:scanora/services/native_bridge_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Native offline captcha engines and full solver corpus',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('Scanora offline captcha test'))));
    final results = <Map<String, dynamic>>[];
    await tester.runAsync(() async {
      final dir = Directory('test/fixtures/captchas');
      final cases =
          jsonDecode(await File('${dir.path}/cases.json').readAsString())
              as List;
      for (final sample in cases) {
        final bytes = await File('${dir.path}/${sample['file']}').readAsBytes();
        final english = await OnnxCaptchaEngine.recognize(bytes);
        final persian = await OnnxCaptchaEngine.recognizePersianOnnx(bytes);
        final result = await CaptchaSolverService.solveOffline(bytes);
        final row = <String, dynamic>{
          'file': sample['file'],
          'expected': sample['answer'],
          'english_neural': english.text,
          'english_confidence': english.confidence,
          'persian_neural': persian.text,
          'persian_confidence': persian.confidence,
          'actual': result.finalClipboardValue,
          'confidence': result.confidence,
          'engine': result.modelName,
          'milliseconds': result.elapsedMilliseconds,
          'correct': result.finalClipboardValue == sample['answer']
        };
        results.add(row);
        // ignore: avoid_print
        print(jsonEncode(row));
      }
      await Directory('build/audit').create(recursive: true);
      await File('build/audit/captcha-native-results.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    });
    expect(results.length, 8);
    final measured = await NativeBridgeService.recognizeCaptchaTesseract(
        await File('test/fixtures/captchas/upper.png').readAsBytes(),
        language: 'eng');
    expect(measured.text, 'ABC123');
    expect(measured.confidence, greaterThan(0.8));
    expect(
        results.where((row) => row['correct'] == true).length, results.length,
        reason:
            'Every synthetic fixture must be recognized exactly, including case and Persian digits.');
  }, skip: !Platform.isWindows);
}
