import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' show Point;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:scanora/models/ai_provider.dart';
import 'package:scanora/services/ai/ai_access.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:camera/camera.dart' show CameraImage, CameraPreview;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/native_bridge_service.dart';
import 'package:scanora/services/ocr/camera_frame_capture.dart';
import 'package:scanora/services/ocr/ocr_service.dart';
import 'package:scanora/ui/screens/pdf_viewer_screen.dart';
import 'package:scanora/ui/screens/studio/instant_live_reader_screen.dart';
import 'package:scanora/ui/screens/studio/batch_book_scanner_screen.dart';
import 'package:scanora/ui/widgets/in_app_camera_screen.dart';

class _TestCamera extends CameraPlatform {
  final bool fail;
  final bool rejectVeryHigh;
  final bool framed;
  Uint8List? _photo;
  final StreamController<CameraImageData>? frames;
  final requestedPresets = <ResolutionPreset?>[];
  final Completer<void>? initializeGate;
  final Completer<void>? meteringGate;
  int captures = 0;
  int disposals = 0;
  _TestCamera(
      {this.fail = false,
      this.initializeGate,
      this.meteringGate,
      this.rejectVeryHigh = false,
      this.framed = false,
      this.frames});
  final _errors = StreamController<CameraErrorEvent>.broadcast();
  @override
  Future<List<CameraDescription>> availableCameras() async => [
        const CameraDescription(
            name: 'Test sensor',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 0)
      ];
  @override
  Future<int> createCameraWithSettings(
      CameraDescription cameraDescription, MediaSettings? mediaSettings) async {
    requestedPresets.add(mediaSettings?.resolutionPreset);
    return 1;
  }

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(CameraInitializedEvent(cameraId, 1400, 600,
          ExposureMode.auto, false, FocusMode.auto, meteringGate != null));
  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {
    await meteringGate?.future;
  }

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;
  @override
  Future<void> initializeCamera(int cameraId,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    await initializeGate?.future;
    if (rejectVeryHigh && requestedPresets.last == ResolutionPreset.veryHigh) {
      throw CameraException(
          'unsupported-resolution', 'Test camera rejects high resolution.');
    }
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposals++;
  }

  @override
  Widget buildPreview(int cameraId) => const SizedBox();
  @override
  bool supportsImageStreaming() => frames != null;
  @override
  Stream<CameraImageData> onStreamedFrameAvailable(int cameraId,
          {CameraImageStreamOptions? options}) =>
      frames!.stream;
  @override
  Future<XFile> takePicture(int cameraId) async {
    captures++;
    if (fail) {
      throw CameraException('sensor-failed', 'Camera capture failed for test');
    }
    final file = File(
        '${Directory.systemTemp.path}/scanora_test_frame_${DateTime.now().microsecondsSinceEpoch}.png');
    var photo = _photo;
    if (photo == null) {
      photo = await File('test/fixtures/english_document.png').readAsBytes();
      if (framed) {
        final page = img.decodeImage(photo)!;
        final scene =
            img.Image(width: page.width + 200, height: page.height + 200);
        img.fill(scene, color: img.ColorRgb8(35, 35, 35));
        img.compositeImage(scene, page, dstX: 100, dstY: 100);
        photo = img.encodePng(scene);
      }
      _photo = photo;
    }
    await file.writeAsBytes(photo);
    return XFile(file.path);
  }
}

class _OnlineCameraSettings extends SettingsService {
  @override
  bool get isOfflineMode => false;
  @override
  bool get useScanoraCloudOcr => false;
  @override
  bool get playPageFlipSound => false;
  @override
  AIProviderType get activeProvider => AIProviderType.gemini;
  @override
  String getApiKey(AIProviderType provider) => 'local-test-key';
  @override
  String getSelectedModel(AIProviderType provider) => 'gemini-test';
}

void main() {
  setUp(AiAccess.clearCache);
  CameraImageData previewFrame(int Function(int x, int y) luma) {
    const width = 96, height = 64, rowStride = 112;
    final bytes = Uint8List(rowStride * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        bytes[y * rowStride + x] = luma(x, y);
      }
    }
    return CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
      width: width,
      height: height,
      planes: [CameraImagePlane(bytes: bytes, bytesPerRow: rowStride)],
    );
  }

  test('Android preview samples respect row stride and sensor orientation', () {
    final frame = CameraImage.fromPlatformInterface(
        previewFrame((x, y) => y < 32 ? 20 : 210));
    final thumbnail = CameraPreviewSampler.thumbnail(
      frame,
      const CameraDescription(
        name: 'Back',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
      DeviceOrientation.portraitUp,
    )!;
    expect(thumbnail.first, 210);
    expect(thumbnail[63], 20);
    final luma = CameraLumaFrame.fromCamera(
      frame,
      const CameraDescription(
          name: 'Back',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90),
      DeviceOrientation.portraitUp,
    )!;
    expect(luma.width, 64);
    expect(luma.height, 96);
    expect(luma.pixels.first, 210);
    expect(luma.pixels[63], 20);
  });

  test('Camera OCR keeps the online result when AI reports no readable text',
      () async {
    final bytes =
        await File('test/fixtures/english_document.png').readAsBytes();
    final result = await http.runWithClient(
      () => CameraFrameCapture().recognize(
        imageBytes: bytes,
        isOfflineMode: false,
        activeProvider: AIProviderType.gemini,
        apiKey: 'local-test-key',
        modelName: 'gemini-test',
        customBaseUrl: '',
        thinkingEffort: ThinkingEffort.none,
        isPersian: false,
        useScanoraCloud: false,
        useFastModel: true,
        cameraMode: CameraOcrMode.live,
        allowInteractiveBrowserAuth: false,
      ),
      () => MockClient((request) async => request.method == 'GET'
          ? http.Response('{"name":"models/gemini-test"}', 200)
          : http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': '[NO_TEXT]'}
                      ]
                    }
                  }
                ]
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'})),
    );
    expect(result.isOffline, isFalse);
    expect(result.didFail, isFalse);
    expect(result.text, isEmpty);
    expect(result.errorMessage, contains('No readable text'));
  });

  test('Live preview OCR reads Persian and mixed text with the small models',
      () async {
    for (final sample in [
      ('persian_document.png', 'فارسی'),
      ('mixed_line.png', 'سلام'),
    ]) {
      final bytes = await File('test/fixtures/${sample.$1}').readAsBytes();
      final frame = await CameraFrameCapture.decodePhoto(bytes);
      expect(frame, isNotNull);
      final read = await CameraFrameCapture.recognizePreview(frame!);
      expect(read.text, contains(sample.$2), reason: sample.$1);
    }
  }, skip: !Platform.isWindows);

  Future<void> load(WidgetTester tester, Widget screen,
      {SettingsService? settings}) async {
    settings ??= SettingsService.memory();
    await settings.setEnableInternalTts(false);
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: settings, child: MaterialApp(home: screen)));
    await tester.pump();
    await tester.pump();
  }

  for (final screen in <Widget>[
    const InstantLiveReaderScreen(),
    const BatchBookScannerScreen(),
    const InAppCameraScreen(),
  ]) {
    testWidgets('${screen.runtimeType} stops after camera permission denial',
        (tester) async {
      final original = CameraPlatform.instance;
      final permission = Completer<void>();
      final camera = _TestCamera(initializeGate: permission);
      CameraPlatform.instance = camera;
      addTearDown(() => CameraPlatform.instance = original);
      await load(tester, screen);
      expect(camera.requestedPresets, hasLength(1));

      // The permission activity can resume Flutter before the first open settles.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      permission.completeError(CameraException('CameraAccessDenied', 'Denied'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Camera access was not granted'), findsOneWidget);
      expect(find.text('Request camera access'), findsNothing);
      expect(find.text('Camera permission settings'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(camera.requestedPresets, hasLength(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 15));
      expect(camera.requestedPresets, hasLength(1));
      expect(
          find.textContaining('Camera access was not granted'), findsOneWidget);
      expect(find.byType(CameraPreview), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));
  }

  testWidgets(
      'A camera policy block is announced separately from a missing grant',
      (tester) async {
    final original = CameraPlatform.instance;
    final initialization = Completer<void>();
    final camera = _TestCamera(initializeGate: initialization);
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = original);
    await load(tester, const InstantLiveReaderScreen());
    initialization
        .completeError(CameraException('CameraAccessBlocked', 'Blocked'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The device is blocking camera use'),
        findsOneWidget);
    expect(find.textContaining('Camera access was not granted'), findsNothing);
    expect(find.text('Request camera access'), findsNothing);
    expect(camera.requestedPresets, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('A live camera reopens once after returning from the background',
      (tester) async {
    final original = CameraPlatform.instance;
    final camera = _TestCamera();
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = original);
    await load(tester, const InstantLiveReaderScreen());
    await tester.pumpAndSettle();
    expect(camera.requestedPresets, hasLength(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(camera.disposals, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.requestedPresets, hasLength(2));
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Camera preview starts before metering needs preview frames',
      (tester) async {
    final original = CameraPlatform.instance;
    final metering = Completer<void>();
    CameraPlatform.instance = _TestCamera(meteringGate: metering);
    addTearDown(() {
      if (!metering.isCompleted) metering.complete();
      CameraPlatform.instance = original;
    });
    await load(tester, const InstantLiveReaderScreen());
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(metering.isCompleted, isFalse);
    expect(find.byType(CameraPreview), findsOneWidget,
        reason: 'Metering can finish only after preview frames start.');
    metering.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Pausing during startup does not discard the initializing camera',
      (tester) async {
    final original = CameraPlatform.instance;
    final gate = Completer<void>();
    CameraPlatform.instance = _TestCamera(initializeGate: gate);
    addTearDown(() => CameraPlatform.instance = original);
    await load(tester, const InstantLiveReaderScreen());
    await tester.tap(find.byTooltip('Pause Live Scan'));
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.tap(find.byTooltip('Resume Live Scan'));
    await tester.pump();
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Android live reader falls back if the higher photo preset fails',
      (tester) async {
    final original = CameraPlatform.instance;
    final camera = _TestCamera(rejectVeryHigh: true);
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = original);
    await load(tester, const InstantLiveReaderScreen());
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(camera.requestedPresets,
        [ResolutionPreset.veryHigh, ResolutionPreset.high]);
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Windows documents can take a photo and open the page selector',
      (tester) async {
    final original = CameraPlatform.instance;
    final camera = _TestCamera();
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = original);
    await load(tester, const PdfViewerScreen());
    final takePhoto = find.text('Take Photo from Camera');
    await tester.ensureVisible(takePhoto);
    await tester.tap(takePhoto);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take photos manually'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Capture Photo'));
    for (var i = 0; i < 60 && find.text('Done (1)').evaluate().isEmpty; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
    }
    expect(camera.captures, 1);
    await tester.tap(find.text('Done (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Start Page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Android batch guidance uses the preview without taking a photo',
      (tester) async {
    final original = CameraPlatform.instance;
    final frames = StreamController<CameraImageData>();
    final camera = _TestCamera(frames: frames);
    CameraPlatform.instance = camera;
    addTearDown(() async {
      CameraPlatform.instance = original;
      await frames.close();
    });
    await load(tester, const BatchBookScannerScreen());
    frames.add(previewFrame((_, __) => 15));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    for (var i = 0;
        i < 40 && find.text('Lighting is too dim').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(camera.captures, 0);
    expect(find.textContaining('Low light.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
      'Android live video reads text without triggering the photo shutter',
      (tester) async {
    final original = CameraPlatform.instance;
    final frames = StreamController<CameraImageData>();
    final camera = _TestCamera(frames: frames);
    CameraPlatform.instance = camera;
    addTearDown(() async {
      CameraPlatform.instance = original;
      await frames.close();
    });
    final messages = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (message) async {
      messages.add(message.toString());
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility, null));
    final fixture = await tester.runAsync(
        () => File('test/fixtures/english_document.png').readAsBytes());
    final source = img.decodeImage(fixture!)!;
    final pixels = Uint8List(source.width * source.height);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final p = source.getPixel(x, y);
        pixels[y * source.width + x] = (p.r + p.g + p.b) ~/ 3;
      }
    }
    await load(tester, const InstantLiveReaderScreen());
    final videoFrame = CameraImageData(
      format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
      width: source.width,
      height: source.height,
      planes: [CameraImagePlane(bytes: pixels, bytesPerRow: source.width)],
    );
    frames.add(videoFrame);
    await tester.pump();
    for (var i = 0;
        i < 100 &&
            !messages.any((message) => message.contains('without internet'));
        i++) {
      frames.add(videoFrame);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(messages.any((message) => message.contains('without internet')),
        isTrue);
    expect(camera.captures, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  },
      skip: !Platform.isWindows,
      variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Online video sends a sensor photo to AI and announces the wait',
      (tester) async {
    final original = CameraPlatform.instance;
    final frames = StreamController<CameraImageData>();
    final camera = _TestCamera(frames: frames);
    CameraPlatform.instance = camera;
    addTearDown(() async {
      CameraPlatform.instance = original;
      await frames.close();
    });
    final requests = <http.Request>[];
    final allowResponse = Completer<void>();
    addTearDown(() {
      if (!allowResponse.isCompleted) allowResponse.complete();
    });
    final fixture = await tester.runAsync(
        () => File('test/fixtures/english_document.png').readAsBytes());
    final source = img.decodeImage(fixture!)!;
    final pixels = Uint8List(source.width * source.height);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        pixels[y * source.width + x] = source.getPixel(x, y).r.toInt();
      }
    }
    final frame = CameraImageData(
        format: const CameraImageFormat(ImageFormatGroup.yuv420, raw: 35),
        width: source.width,
        height: source.height,
        planes: [CameraImagePlane(bytes: pixels, bytesPerRow: source.width)]);
    await http.runWithClient(() async {
      await load(tester, const InstantLiveReaderScreen(),
          settings: _OnlineCameraSettings());
      for (var i = 0; i < 100 && requests.isEmpty; i++) {
        frames.add(frame);
        await tester.pump(const Duration(milliseconds: 450));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)));
      }
      expect(requests, isNotEmpty);
      expect(requests.first.url.host, 'generativelanguage.googleapis.com');
      expect(camera.captures, 1);
      await tester.pump();
      expect(
          find.textContaining('Please wait for the response'), findsOneWidget);
      allowResponse.complete();
      for (var i = 0;
          i < 40 &&
              find
                  .textContaining('Text from the AI service')
                  .evaluate()
                  .isEmpty;
          i++) {
        frames.add(frame);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)));
      }
      expect(find.textContaining('Text from the AI service'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(seconds: 26));
    },
        () => MockClient((request) async {
              if (request.method == 'GET') {
                expect(camera.captures, 0);
                return http.Response('{"name":"models/gemini-test"}', 200);
              }
              requests.add(request);
              await allowResponse.future;
              return http.Response(
                  jsonEncode({
                    'candidates': [
                      {
                        'content': {
                          'parts': [
                            {'text': 'Text from the AI service'}
                          ]
                        }
                      }
                    ]
                  }),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  },
      skip: !Platform.isWindows,
      variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Unreadable live video recovers by reading the original photo',
      (tester) async {
    final original = CameraPlatform.instance;
    final frames = StreamController<CameraImageData>();
    final camera = _TestCamera(frames: frames);
    CameraPlatform.instance = camera;
    addTearDown(() async {
      CameraPlatform.instance = original;
      await frames.close();
    });
    final messages = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (message) async {
      messages.add(message.toString());
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility, null));
    await load(tester, const InstantLiveReaderScreen(),
        settings: SettingsService.memory());
    final blurryPreview = previewFrame((_, __) => 220);
    for (var i = 0;
        i < 240 &&
            !messages.any((message) => message.contains('without internet'));
        i++) {
      frames.add(blurryPreview);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(camera.captures, greaterThanOrEqualTo(1));
    expect(
        messages.any((message) => message.contains('without internet')), isTrue,
        reason: messages.join('\n'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
  },
      skip: !Platform.isWindows,
      variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
      'Batch scanner captures readable text without visible paper corners',
      (tester) async {
    final original = CameraPlatform.instance;
    CameraPlatform.instance = _TestCamera();
    addTearDown(() => CameraPlatform.instance = original);
    await load(tester, const BatchBookScannerScreen(),
        settings: SettingsService.memory());
    for (var i = 0;
        i < 400 && find.textContaining('Captured Pages: 1').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('Captured Pages: 1'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((widget) => widget.data)
            .join(' | '));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(seconds: 16));
  }, skip: !Platform.isWindows);

  testWidgets(
      'Live capture failure is visible and announced, with no black screenshot fallback',
      (tester) async {
    final original = CameraPlatform.instance;
    final camera = _TestCamera(fail: true);
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = original);
    final messages = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (message) async {
      messages.add(message.toString());
      return null;
    });
    await load(tester, const InstantLiveReaderScreen());
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(camera.captures, 1);
    expect(find.textContaining('The image could not be read.'), findsOneWidget);
    expect(messages.any((m) => m.contains('The image could not be read.')),
        isTrue);
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, null);
  });

  testWidgets('Online batch verifies an unframed page with the selected AI',
      (tester) async {
    final original = CameraPlatform.instance;
    CameraPlatform.instance = _TestCamera();
    addTearDown(() => CameraPlatform.instance = original);
    var requests = 0;
    await http.runWithClient(() async {
      await load(tester, const BatchBookScannerScreen(),
          settings: _OnlineCameraSettings());
      for (var i = 0;
          i < 400 &&
              find.textContaining('Captured Pages: 1').evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('Captured Pages: 1'), findsOneWidget);
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(seconds: 16));
    },
        () => MockClient((request) async {
              if (request.method == 'GET') {
                return http.Response('{"name":"models/gemini-test"}', 200);
              }
              requests++;
              return http.Response(
                  '{"candidates":[{"content":{"parts":[{"text":"Scanora reads pages in the original language. This entire document is readable with the selected AI service."}]}}]}',
                  200);
            }));
  }, skip: !Platform.isWindows);

  testWidgets(
      'Automatic live camera reads a real frame with internal TTS disabled',
      (tester) async {
    final original = CameraPlatform.instance;
    final camera = _TestCamera();
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = original);
    final messages = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (message) async {
      messages.add(message.toString());
      return null;
    });
    await tester.runAsync(
        () => NativeBridgeService.ensureTessDataExtracted(fast: true));
    await load(tester, const InstantLiveReaderScreen());
    await tester.pump(const Duration(milliseconds: 1500));
    for (var i = 0;
        i < 160 && !messages.any((m) => m.contains('without internet'));
        i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(camera.captures, 1);
    expect(
        messages.any((message) =>
            message.contains('Scanora') &&
            message.contains('without internet')),
        isTrue,
        reason:
            '${messages.join('\n')}\nUI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(' | ')}');
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, null);
  }, skip: !Platform.isWindows);

  testWidgets(
      'Batch camera saves framed pages before OCR and waits for a page turn',
      (tester) async {
    final original = CameraPlatform.instance;
    final camera = _TestCamera(framed: true);
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = original);
    await load(tester, const BatchBookScannerScreen());
    for (var i = 0;
        i < 400 && find.textContaining('Captured Pages: 1').evaluate().isEmpty;
        i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.textContaining('Captured Pages: 1'), findsOneWidget,
        reason:
            'Captures: ${camera.captures}; UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(' | ')}');
    expect(find.textContaining('Waiting for page turn'), findsOneWidget);
    final capturesBefore = camera.captures;
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(camera.captures, greaterThan(capturesBefore));
    expect(find.textContaining('Captured Pages: 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(seconds: 16));
  }, skip: !Platform.isWindows);
  for (final book in [false, true]) {
    testWidgets(
        book
            ? 'Book auto capture remains responsive without online OCR requests'
            : 'Live auto reading uses the selected online provider',
        (tester) async {
      final original = CameraPlatform.instance;
      final camera = _TestCamera(framed: book);
      CameraPlatform.instance = camera;
      addTearDown(() => CameraPlatform.instance = original);
      final requests = <http.Request>[];
      final messages = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility,
              (m) async {
        messages.add(m.toString());
        return null;
      });
      await http.runWithClient(() async {
        await load(
            tester,
            book
                ? const BatchBookScannerScreen()
                : const InstantLiveReaderScreen(),
            settings: _OnlineCameraSettings());
        for (var i = 0; i < 400; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 200));
          if (book
              ? find.textContaining('Captured Pages: 1').evaluate().isNotEmpty
              : messages.any((m) => m.contains('Online result فارسی 123'))) {
            break;
          }
        }
        if (book) {
          expect(requests, isEmpty);
          expect(find.textContaining('Captured Pages: 1'), findsOneWidget);
        } else {
          expect(requests, hasLength(1));
          expect(requests.single.url.host, 'generativelanguage.googleapis.com');
          expect(messages.any((m) => m.contains('Online result فارسی 123')),
              isTrue);
        }
        expect(find.text('Restart camera'), findsNothing);
        expect(find.text('Read Current Frame Now'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump(const Duration(seconds: 16));
      },
          () => MockClient((request) async {
                if (request.method == 'GET') {
                  return http.Response('{"name":"models/gemini-test"}', 200);
                }
                requests.add(request);
                return http.Response(
                    jsonEncode({
                      'candidates': [
                        {
                          'content': {
                            'parts': [
                              {'text': 'Online result فارسی 123'}
                            ]
                          }
                        }
                      ]
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }));
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(
              SystemChannels.accessibility, null);
    });
  }
}
