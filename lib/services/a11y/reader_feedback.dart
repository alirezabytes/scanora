import 'package:flutter/widgets.dart';
import '../settings_service.dart';
import '../ocr/camera_diagnostics.dart';
import '../tts/espeak_tts_service.dart';
import 'accessibility_service.dart';

/// Route automatic reader feedback to the output selected by the user.
class ReaderFeedback {
  static Future<void> speak(
      BuildContext context, String text, SettingsService settings,
      {bool assertive = false, String? diagnosticSource}) async {
    if (!context.mounted || text.trim().isEmpty) return;
    if (diagnosticSource != null && CameraDiagnostics.enabled) {
      CameraDiagnostics.event('speech.request', {
        'source': diagnosticSource,
        'output': settings.enableInternalTts ? 'built-in' : 'screen-reader',
        'text': text
      });
    }
    if (!settings.enableInternalTts) {
      AccessibilityService.announce(context, text,
          assertive: assertive, diagnosticSource: diagnosticSource);
      return;
    }
    try {
      await EspeakTtsService.speak(text, settings: settings);
      if (context.mounted &&
          EspeakTtsService.engineStatus.value == TtsEngineStatus.error) {
        AccessibilityService.announce(context, text, assertive: assertive);
      } else if (EspeakTtsService.isSpeakingNotifier.value) {
        // Synthesis runs after speak() starts the worker. Catch failures that
        // arrive later as well, then release both listeners on stop/completion.
        late void Function() onError;
        late void Function() onStopped;
        void cleanup() {
          EspeakTtsService.engineStatus.removeListener(onError);
          EspeakTtsService.isSpeakingNotifier.removeListener(onStopped);
        }

        onError = () {
          if (EspeakTtsService.engineStatus.value != TtsEngineStatus.error) {
            return;
          }
          cleanup();
          if (context.mounted) {
            AccessibilityService.announce(context, text, assertive: assertive);
          }
        };
        onStopped = () {
          if (!EspeakTtsService.isSpeakingNotifier.value) cleanup();
        };
        EspeakTtsService.engineStatus.addListener(onError);
        EspeakTtsService.isSpeakingNotifier.addListener(onStopped);
      }
    } catch (_) {
      if (context.mounted) {
        AccessibilityService.announce(context, text, assertive: assertive);
      }
    }
  }
}
