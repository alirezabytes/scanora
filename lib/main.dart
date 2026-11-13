import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'app/scanora_app.dart';
import 'services/captcha/captcha_hotkey_service.dart';
import 'services/license/demo_license_service.dart';
import 'services/settings_service.dart';
import 'services/diagnostics_service.dart';
import 'services/ocr/camera_diagnostic_replay.dart';
import 'services/native_bridge_service.dart';
import 'services/tts/espeak_tts_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DiagnosticsService.initialize();
  FlutterError.onError = (details) {
    DiagnosticsService.record(
        'flutter', details.exception, details.stack ?? StackTrace.current);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    DiagnosticsService.record('async', error, stack);
    return true;
  };
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
        ['Vazirmatn'], await rootBundle.loadString('assets/fonts/OFL.txt'));
    yield LicenseEntryWithLineBreaks(['eSpeak-NG'],
        await rootBundle.loadString('assets/licenses/espeak-ng.txt'));
    yield LicenseEntryWithLineBreaks(
        ['Sonic'], await rootBundle.loadString('assets/licenses/sonic.txt'));
    final license =
        await rootBundle.loadString('assets/licenses/bina-rizehpizeh.txt');
    yield LicenseEntryWithLineBreaks(
        ['Bina 0.2 RizehPizeh'],
        'Model by Reza2kn, based on PaddlePaddle PP-OCRv6_medium_rec.\n'
        'https://huggingface.co/Reza2kn/Bina-0.2-RizehPizeh\n\n'
        'Scanora converted the Paddle inference graph to ONNX with a fixed '
        '48 × 768 input and equivalent fixed-size pooling.\n\n$license');
  });

  final settingsService = SettingsService();
  await settingsService.init();
  NativeBridgeService.espeakDataOverride = settingsService.espeakDataDirectory;
  ErrorWidget.builder = (_) => Material(
      child: Center(
          child: Semantics(
              liveRegion: true,
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(settingsService.locale.languageCode == 'fa'
                      ? 'این بخش باز نشد. به صفحهٔ قبل برگردید و دوباره تلاش کنید.'
                      : 'This section could not be displayed. Go back and try again.')))));

  final demoLicenseService = DemoLicenseService();
  await demoLicenseService.init();

  if (Platform.isWindows) {
    // Clears stale registrations (hot restart) and registers the captcha hotkey.
    try {
      await hotKeyManager.unregisterAll();
      await CaptchaHotkeyService.apply(settingsService);
    } catch (error, stack) {
      DiagnosticsService.record('hotkey.start', error, stack);
    }
  }

  // Start the eSpeak-NG background worker early so the first utterance has no delay.
  EspeakTtsService.ensureEngine();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settingsService),
        ChangeNotifierProvider.value(value: demoLicenseService),
      ],
      child: const ScanoraApp(),
    ),
  );
  unawaited(CameraDiagnosticReplay.run());
}
