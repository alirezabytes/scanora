import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scanora/services/cloud/google_account_service.dart';
import 'package:scanora/services/cloud/scanora_cloud_ocr_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Saved Google session performs real image import and text export',
      (tester) async {
    final report = <String, dynamic>{
      'test': 'real Google Docs OCR',
      'cases': []
    };
    try {
      expect(GoogleAccountService.desktopConfigured, isTrue);
      expect(await GoogleAccountService.accessToken(), isNotNull,
          reason:
              'No saved authorized session. This test never opens sign-in.');
      for (final sample in [
        ('english_document.png', false, 'Scanora'),
        ('persian_document.png', true, 'اسکنورا')
      ]) {
        final text = await ScanoraCloudOcrService.recognize(
            await File('test/fixtures/${sample.$1}').readAsBytes(),
            isPersian: sample.$2,
            allowInteractiveBrowserAuth: false);
        (report['cases'] as List).add({
          'file': sample.$1,
          'text': text,
          'backend': 'Google Drive import + Google Docs text export',
          'http_operations':
              Map<String, int>.from(ScanoraCloudOcrService.lastHttpOperations),
        });
        expect(text, contains(sample.$3));
        expect(ScanoraCloudOcrService.lastHttpOperations['export'], 200);
        expect(ScanoraCloudOcrService.lastHttpOperations['delete'], 204);
      }
      report['passed'] = true;
    } catch (error) {
      report['passed'] = false;
      report['error'] = error.toString();
      rethrow;
    } finally {
      await Directory('build/audit').create(recursive: true);
      await File('build/audit/google-ocr-live.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
