import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scanora/models/ai_provider.dart';
import 'package:scanora/services/ai/ai_service.dart';
import 'package:scanora/services/captcha/captcha_solver_service.dart';
import 'package:scanora/services/ocr/ocr_service.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/vision/image_description_service.dart';

/// Explicit live test for the publisher's locally configured Gemini account.
/// Credentials never enter the report, console or source file.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'Configured AI performs real image OCR, captcha, vision and audio requests',
      (tester) async {
    final report = <String, dynamic>{
      'provider': 'Gemini',
      'tests': <String, dynamic>{}
    };
    var key = '';
    await tester.runAsync(() async {
      try {
        final settings = SettingsService();
        await settings.init();
        key = settings.getApiKey(AIProviderType.gemini);
        expect(key.isNotEmpty, isTrue,
            reason: 'No Gemini key is configured locally.');
        final models = await AIService.fetchAvailableModels(
            providerType: AIProviderType.gemini,
            apiKey: key,
            customBaseUrl: '');
        await settings.setDiscoveredModels(AIProviderType.gemini, models);
        report['discovered_model_count'] = models.length;
        final model = settings.getSelectedModel(AIProviderType.gemini);
        expect(models.contains(model), isTrue,
            reason: 'The saved model must still be advertised by the service.');
        report['model'] = model;
        final tests = report['tests'] as Map<String, dynamic>;
        final ocr = await OcrService.processImage(
            imageBytes:
                await File('test/fixtures/english_document.png').readAsBytes(),
            isOfflineMode: false,
            activeProvider: AIProviderType.gemini,
            apiKey: key,
            modelName: model,
            customBaseUrl: '');
        tests['ocr'] = {
          'text': ocr.text,
          'error': ocr.errorMessage?.replaceAll(key, '[REDACTED]')
        };
        expect(ocr.isOffline, isFalse);
        expect(ocr.text, contains('Scanora'));
        final captcha = await CaptchaSolverService.solve(
            imageBytes:
                await File('test/fixtures/captchas/upper.png').readAsBytes(),
            isOfflineMode: false,
            activeProvider: AIProviderType.gemini,
            apiKey: key,
            modelName: model,
            customBaseUrl: '');
        tests['captcha'] = {
          'text': captcha.finalClipboardValue,
          'offline': captcha.isOffline
        };
        expect(captcha.isOffline, isFalse);
        expect(captcha.finalClipboardValue, 'ABC123');
        final vision = await ImageDescriptionService.describeImage(
            imageBytes:
                await File('test/fixtures/vision_bus.jpg').readAsBytes(),
            isOfflineMode: false,
            activeProvider: AIProviderType.gemini,
            apiKey: key,
            modelName: model,
            customBaseUrl: '',
            isPersian: false);
        tests['vision'] = vision.description;
        expect(vision.description.toLowerCase(), contains('bus'));
        final audio = await AIService.transcribeGeminiAudio(
            apiKey: key,
            modelName: model,
            wavBytes: await File('test/fixtures/audio/english_reference.wav')
                .readAsBytes());
        tests['audio'] = audio;
        expect(audio.toLowerCase(), contains('yellow lamps'));
        report['passed'] = true;
      } catch (error) {
        report['passed'] = false;
        report['error'] = key.isEmpty
            ? 'No local credential configured.'
            : error.toString().replaceAll(key, '[REDACTED]');
      } finally {
        await Directory('build/audit').create(recursive: true);
        await File('build/audit/ai-live-2.4.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
    });
    expect(report['passed'], isTrue,
        reason: 'See the sanitized AI live audit report.');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
