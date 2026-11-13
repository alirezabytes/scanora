import 'dart:async';
import 'dart:convert';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:scanora/models/ai_provider.dart';
import 'package:scanora/models/pdf_document.dart';
import 'package:scanora/services/ai/ai_access.dart';
import 'package:scanora/services/ai/ai_service.dart';
import 'package:scanora/services/ai/online_access_service.dart';
import 'package:scanora/services/captcha/captcha_solver_service.dart';
import 'package:scanora/services/ocr/ocr_service.dart';
import 'package:scanora/services/pdf/document_batch_processor.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/stt/speech_to_text_service.dart';
import 'package:scanora/ui/screens/studio/batch_book_scanner_screen.dart';
import 'package:scanora/ui/screens/studio/instant_live_reader_screen.dart';
import 'package:scanora/ui/widgets/in_app_camera_screen.dart';
import 'package:scanora/ui/widgets/online_access_guard.dart';

class _CameraProbe extends CameraPlatform {
  int opens = 0;
  @override
  Future<List<CameraDescription>> availableCameras() async {
    opens++;
    return [];
  }
}

Matcher failure(AiFailureKind kind) =>
    isA<AiServiceException>().having((error) => error.kind, 'kind', kind);

Future<SettingsService> onlineSettings({String key = ''}) async {
  final settings = SettingsService.memory();
  await settings.toggleOfflineMode(false);
  await settings.setUseScanoraCloudOcr(false);
  await settings.setActiveProvider(AIProviderType.gemini);
  await settings.setApiKey(AIProviderType.gemini, key);
  await settings.setDiscoveredModels(AIProviderType.gemini, ['gemini-test']);
  await settings.setSelectedModel(AIProviderType.gemini, 'gemini-test');
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AiAccess.clearCache);

  test('An empty key is rejected before image decoding or any request',
      () async {
    var requests = 0;
    await http.runWithClient(() async {
      await expectLater(
          AIService.callVisionModel(
              providerType: AIProviderType.openai,
              apiKey: '  ',
              modelName: '',
              customBaseUrl: '',
              imageBytes: Uint8List(0),
              prompt: 'Read'),
          throwsA(failure(AiFailureKind.missingKey)));
    },
        () => MockClient((_) async {
              requests++;
              return http.Response('', 500);
            }));
    expect(requests, 0);
  });

  for (final sample in [
    (
      401,
      '{"error":{"code":"invalid_api_key","message":"secret-key"}}',
      AiFailureKind.invalidKey
    ),
    (400, '{"error":{"status":"API_KEY_INVALID"}}', AiFailureKind.invalidKey),
    (403, '{"error":{"type":"permission_error"}}', AiFailureKind.permission),
    (
      403,
      '{"error":{"code":"unsupported_country_region_territory"}}',
      AiFailureKind.regionUnavailable
    ),
    (
      404,
      '{"error":{"code":"model_not_found"}}',
      AiFailureKind.modelUnavailable
    ),
    (402, '{}', AiFailureKind.quota),
    (429, '{"error":{"code":"insufficient_quota"}}', AiFailureKind.quota),
    (429, '{"error":{"code":"rate_limit_exceeded"}}', AiFailureKind.rateLimit),
    (503, '{}', AiFailureKind.unavailable),
  ]) {
    test(
        'Access failure ${sample.$1}/${sample.$3.name} stops OCR before progress',
        () async {
      final methods = <String>[];
      final progress = <int>[];
      final result = await http.runWithClient(
          () => OcrService.processImage(
              imageBytes: Uint8List(0),
              isOfflineMode: false,
              activeProvider: AIProviderType.openai,
              apiKey: 'secret-key',
              modelName: 'test-model',
              customBaseUrl: '',
              isPersian: true,
              onProgress: progress.add),
          () => MockClient((request) async {
                methods.add(request.method);
                expect(request.url.path, '/v1/models/test-model');
                expect(request.bodyBytes, isEmpty);
                return http.Response(sample.$2, sample.$1);
              }));
      expect(methods, ['GET']);
      expect(progress, isEmpty);
      expect(result.didFail, isTrue);
      expect(result.isOffline, isFalse);
      expect(result.text, isEmpty);
      expect(result.errorMessage, AiServiceException(sample.$3).message(true));
      expect(result.errorMessage, isNot(contains('secret-key')));
    });
  }

  test('Key checks are authenticated for every supported provider', () async {
    for (final provider in AIProviderType.values) {
      await http.runWithClient(
          () => AiAccess.ensure(
              provider: provider,
              apiKey: 'test-key',
              model: 'test-model',
              baseUrl: 'https://example.test/v1'),
          () => MockClient((request) async {
                expect(request.method, 'GET');
                expect(request.bodyBytes, isEmpty);
                if (provider == AIProviderType.gemini) {
                  expect(request.headers['x-goog-api-key'], 'test-key');
                  return http.Response('{"name":"models/test-model"}', 200);
                }
                if (provider == AIProviderType.anthropic) {
                  expect(request.headers['x-api-key'], 'test-key');
                } else {
                  expect(request.headers['authorization'], 'Bearer test-key');
                }
                return http.Response(
                    jsonEncode(provider == AIProviderType.openrouter
                        ? {
                            'data': {'limit_remaining': 10}
                          }
                        : provider == AIProviderType.custom
                            ? {
                                'data': [
                                  {'id': 'test-model'}
                                ]
                              }
                            : {'id': 'test-model'}),
                    200);
              }));
    }
  });

  test(
      'Valid access sends only to the selected provider and runtime rejection invalidates access',
      () async {
    final methods = <String>[];
    var reject = false;
    final image = img.encodePng(img.Image(width: 24, height: 24));
    Future<String> read() => AIService.callVisionModel(
        providerType: AIProviderType.openai,
        apiKey: 'test-key',
        modelName: 'test-model',
        customBaseUrl: '',
        imageBytes: image,
        prompt: 'Read');
    await http.runWithClient(() async {
      expect(await read(), 'Actual AI result');
      reject = true;
      await expectLater(read(), throwsA(failure(AiFailureKind.invalidKey)));
      reject = false;
      expect(await read(), 'Actual AI result');
    },
        () => MockClient((request) async {
              expect(request.url.host, 'api.openai.com');
              methods.add(request.method);
              if (request.method == 'GET') {
                return http.Response('{"id":"test-model"}', 200);
              }
              expect(request.url.path, '/v1/responses');
              final body = jsonDecode(request.body);
              expect(body['model'], 'test-model');
              expect(body['input'][0]['content'][1]['image_url'],
                  startsWith('data:image/jpeg;base64,'));
              return reject
                  ? http.Response('{}', 401)
                  : http.Response(
                      '{"output":[{"type":"message","content":[{"type":"output_text","text":"Actual AI result"}]}]}',
                      200);
            }));
    expect(methods, ['GET', 'POST', 'POST', 'GET', 'POST']);
  });

  test('A changed key is checked separately from a recently accepted key',
      () async {
    final keys = <String>[];
    await http.runWithClient(() async {
      for (final key in ['first', 'first', 'second']) {
        await AiAccess.ensure(
            provider: AIProviderType.openai,
            apiKey: key,
            model: 'test-model',
            baseUrl: '');
      }
    },
        () => MockClient((request) async {
              keys.add(request.headers['authorization']!);
              return http.Response('{"id":"test-model"}', 200);
            }));
    expect(keys, ['Bearer first', 'Bearer second']);
  });

  test(
      'Online captcha and speech reject missing access without an offline retry',
      () async {
    final settings = await onlineSettings();
    final progress = <int>[];
    final engines = <String>[];
    await expectLater(
        CaptchaSolverService.solve(
            imageBytes: Uint8List(0),
            isOfflineMode: false,
            activeProvider: AIProviderType.gemini,
            apiKey: '',
            modelName: '',
            customBaseUrl: ''),
        throwsA(failure(AiFailureKind.missingKey)));
    await expectLater(
        SpeechToTextService.transcribeWavBytes(Uint8List(0),
            settings: settings,
            onProgress: progress.add,
            onEngine: engines.add),
        throwsA(failure(AiFailureKind.missingKey)));
    expect(progress, isEmpty);
    expect(engines, isEmpty);
  });

  test('Offline access needs no key, model or connection', () async {
    final settings = SettingsService.memory();
    await OnlineAccessService.ensure(settings);
    await OnlineAccessService.ensure(settings, task: OnlineTask.speech);
  });

  test(
      'Document processing stops after an online error before rendering or uploading other pages',
      () async {
    var rendered = 0, uploaded = 0;
    await expectLater(
        DocumentBatchProcessor.process(
            pages: List.generate(
                3,
                (i) => PdfPageInfo(
                    pageNumber: i + 1,
                    sourcePageIndex: i,
                    text: '',
                    needsOcr: true)),
            render: (_) async {
              rendered++;
              return Uint8List.fromList([1]);
            },
            recognize: (_) async {
              uploaded++;
              return const ScanRecognitionResult(
                  text: '',
                  isOffline: false,
                  engine: '',
                  didFail: true,
                  errorMessage: 'The AI service did not accept this API key.');
            },
            onProgress: (_) {}),
        throwsA(isA<DocumentOnlineFailure>()));
    expect(rendered, 1);
    expect(uploaded, 1);
  });

  for (final screen in <Widget>[
    const InstantLiveReaderScreen(),
    const BatchBookScannerScreen(),
    const InAppCameraScreen()
  ]) {
    testWidgets(
        '${screen.runtimeType} rejects a missing key before opening a camera',
        (tester) async {
      final settings = await onlineSettings();
      await settings.setEnableInternalTts(false);
      final original = CameraPlatform.instance;
      final camera = _CameraProbe();
      CameraPlatform.instance = camera;
      addTearDown(() => CameraPlatform.instance = original);
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility,
              (message) async {
        announcements.add(message.toString());
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(
              SystemChannels.accessibility, null));
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: settings, child: MaterialApp(home: screen)));
      await tester.pumpAndSettle();
      expect(find.text('Online service is not ready'), findsOneWidget);
      expect(find.textContaining('Enter the selected AI service API key'),
          findsOneWidget);
      expect(find.text('Checking online access'), findsNothing);
      expect(camera.opens, 0);
      expect(
          announcements
              .any((m) => m.contains('Enter the selected AI service API key')),
          isTrue);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
      'Cancelling an access check returns immediately and never starts processing',
      (tester) async {
    final settings = await onlineSettings(key: 'test-key');
    final pending = Completer<http.Response>();
    bool? result;
    var processing = false;
    await http.runWithClient(() async {
      await tester.pumpWidget(ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
              home: Builder(
                  builder: (context) => Scaffold(
                      body: TextButton(
                          onPressed: () async {
                            result = await OnlineAccessGuard.require(
                                context, settings);
                            if (result == true) processing = true;
                          },
                          child: const Text('Start')))))));
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(find.text('Checking online access'), findsOneWidget);
      expect(processing, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      pending.complete(http.Response('{"name":"models/gemini-test"}', 200));
      await tester.pumpAndSettle();
      expect(processing, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient((_) => pending.future));
  });
}
