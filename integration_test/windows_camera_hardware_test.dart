import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:scanora/services/ocr/camera_frame_capture.dart';
import 'package:scanora/services/ocr/ocr_service.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/ui/screens/studio/instant_live_reader_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows live reader runs with the real webcam', (tester) async {
    const target = String.fromEnvironment('SCANORA_CAMERA_TARGET');
    final settings = SettingsService.memory();
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
      value: settings,
      child: const MaterialApp(home: InstantLiveReaderScreen()),
    ));
    final clock = Stopwatch()..start();
    final active = find.byType(CameraPreview);
    final ready = find.textContaining('Live Camera Reader active.');
    while (ready.evaluate().isEmpty &&
        active.evaluate().isEmpty &&
        clock.elapsed < const Duration(seconds: 23)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    expect(active, findsOneWidget);
    final idleGuide = find.textContaining('Live Camera Reader active.');
    final detected = find.textContaining('Latest Detected Text');
    final expected = find.textContaining(target, findRichText: true);
    final deadline = clock.elapsed + const Duration(seconds: 14);
    while (clock.elapsed < deadline) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      if (target.isNotEmpty
          ? detected.evaluate().isNotEmpty && expected.evaluate().isNotEmpty
          : idleGuide.evaluate().isEmpty) {
        break;
      }
    }
    if (target.isNotEmpty) {
      expect(detected, findsOneWidget);
      expect(expected, findsWidgets);
    } else {
      expect(idleGuide, findsNothing,
          reason: 'The reader must process a frame.');
      expect(find.textContaining('The image could not be read.'), findsNothing);
    }
    debugPrint(
        'Live reader processed webcam frames in ${clock.elapsedMilliseconds} ms.');
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  }, skip: !Platform.isWindows);

  testWidgets('Windows webcam takes successive photos at both reader presets',
      (tester) async {
    final cameras = await availableCameras();
    expect(cameras, isNotEmpty);
    for (final preset in [ResolutionPreset.high, ResolutionPreset.veryHigh]) {
      final controller =
          CameraController(cameras.first, preset, enableAudio: false);
      try {
        await controller.initialize().timeout(const Duration(seconds: 20));
        for (var i = 0; i < 2; i++) {
          final bytes = await CameraFrameCapture.capture(controller);
          final decoded = image.decodeImage(bytes);
          expect(decoded, isNotNull);
          expect(decoded!.width, greaterThan(100));
          expect(decoded.height, greaterThan(100));
          debugPrint('${preset.name}: ${decoded.width} × ${decoded.height}');
          if (i == 0 && preset == ResolutionPreset.high) {
            final settings = SettingsService.memory();
            final clock = Stopwatch()..start();
            final result = await CameraFrameCapture().recognize(
              imageBytes: bytes,
              isOfflineMode: true,
              activeProvider: settings.activeProvider,
              apiKey: '',
              modelName: '',
              customBaseUrl: '',
              thinkingEffort: settings.thinkingEffort,
              isPersian: false,
              useScanoraCloud: false,
              useFastModel: true,
              cameraMode: CameraOcrMode.live,
              allowInteractiveBrowserAuth: false,
            );
            settings.dispose();
            expect(result.didFail, isFalse, reason: result.errorMessage);
            debugPrint(
                'Local OCR completed on a real webcam frame in ${clock.elapsedMilliseconds} ms.');
          }
        }
      } finally {
        await controller.dispose();
      }
    }
  }, skip: !Platform.isWindows);
}
