import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import '../native_bridge_service.dart';
import 'windows_captcha_capture.dart';
import '../../models/captcha_result.dart';
import '../settings_service.dart';
import '../ai/online_access_service.dart';
import '../ai/ai_access.dart';
import '../tts/espeak_tts_service.dart';
import 'captcha_solver_service.dart';

/// Windows global hotkey (default Ctrl+Shift+C).
///
/// Pressing it from ANY application captures a labelled captcha image in the active window, solves
/// it automatically, replaces the clipboard content with the final answer, reads the
/// answer aloud with eSpeak-NG, and notifies the app UI so Captcha Solver displays it.
class CaptchaHotkeyService {
  CaptchaHotkeyService._();

  static const String defaultCombo = 'ctrl+shift+c';

  static HotKey? _registered;
  static SettingsService? _settings;
  static bool _busy = false;

  /// Optional callback invoked on the UI thread when a captcha image is solved via hotkey.
  static void Function(Uint8List imageBytes, CaptchaResult result)?
      onHotkeyCaptchaSolved;

  static bool get isSupported => Platform.isWindows;

  static const Map<String, PhysicalKeyboardKey> _keys = {
    'a': PhysicalKeyboardKey.keyA,
    'b': PhysicalKeyboardKey.keyB,
    'c': PhysicalKeyboardKey.keyC,
    'd': PhysicalKeyboardKey.keyD,
    'e': PhysicalKeyboardKey.keyE,
    'f': PhysicalKeyboardKey.keyF,
    'g': PhysicalKeyboardKey.keyG,
    'h': PhysicalKeyboardKey.keyH,
    'i': PhysicalKeyboardKey.keyI,
    'j': PhysicalKeyboardKey.keyJ,
    'k': PhysicalKeyboardKey.keyK,
    'l': PhysicalKeyboardKey.keyL,
    'm': PhysicalKeyboardKey.keyM,
    'n': PhysicalKeyboardKey.keyN,
    'o': PhysicalKeyboardKey.keyO,
    'p': PhysicalKeyboardKey.keyP,
    'q': PhysicalKeyboardKey.keyQ,
    'r': PhysicalKeyboardKey.keyR,
    's': PhysicalKeyboardKey.keyS,
    't': PhysicalKeyboardKey.keyT,
    'u': PhysicalKeyboardKey.keyU,
    'v': PhysicalKeyboardKey.keyV,
    'w': PhysicalKeyboardKey.keyW,
    'x': PhysicalKeyboardKey.keyX,
    'y': PhysicalKeyboardKey.keyY,
    'z': PhysicalKeyboardKey.keyZ,
    '0': PhysicalKeyboardKey.digit0,
    '1': PhysicalKeyboardKey.digit1,
    '2': PhysicalKeyboardKey.digit2,
    '3': PhysicalKeyboardKey.digit3,
    '4': PhysicalKeyboardKey.digit4,
    '5': PhysicalKeyboardKey.digit5,
    '6': PhysicalKeyboardKey.digit6,
    '7': PhysicalKeyboardKey.digit7,
    '8': PhysicalKeyboardKey.digit8,
    '9': PhysicalKeyboardKey.digit9,
    'f1': PhysicalKeyboardKey.f1,
    'f2': PhysicalKeyboardKey.f2,
    'f3': PhysicalKeyboardKey.f3,
    'f4': PhysicalKeyboardKey.f4,
    'f5': PhysicalKeyboardKey.f5,
    'f6': PhysicalKeyboardKey.f6,
    'f7': PhysicalKeyboardKey.f7,
    'f8': PhysicalKeyboardKey.f8,
    'f9': PhysicalKeyboardKey.f9,
    'f10': PhysicalKeyboardKey.f10,
    'f11': PhysicalKeyboardKey.f11,
    'f12': PhysicalKeyboardKey.f12,
  };

  /// Converts a stored combination such as `ctrl+shift+c` into a [HotKey], or null
  /// when it is not a valid combination (a modifier plus one letter, digit or F-key).
  static HotKey? parse(String combo) {
    final tokens = combo
        .toLowerCase()
        .split('+')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty);
    final modifiers = <HotKeyModifier>[];
    PhysicalKeyboardKey? key;
    for (final t in tokens) {
      switch (t) {
        case 'ctrl':
        case 'control':
          modifiers.add(HotKeyModifier.control);
        case 'shift':
          modifiers.add(HotKeyModifier.shift);
        case 'alt':
          modifiers.add(HotKeyModifier.alt);
        case 'win':
        case 'meta':
          modifiers.add(HotKeyModifier.meta);
        default:
          key = _keys[t];
          if (key == null) return null;
      }
    }
    if (key == null || modifiers.isEmpty) return null;
    return HotKey(key: key, modifiers: modifiers, scope: HotKeyScope.system);
  }

  /// Human readable form, e.g. `Ctrl+Shift+C`.
  static String describe(String combo) {
    return combo
        .split('+')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .map((t) => t.length == 1 || t.startsWith('f') && t.length <= 3
            ? t.toUpperCase()
            : t[0].toUpperCase() + t.substring(1))
        .join('+');
  }

  /// Builds a stored combination from a key event; returns null while the pressed key
  /// is only a modifier or the combination has no modifier.
  static String? comboFromKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return null;
    final pressed = HardwareKeyboard.instance;
    final parts = <String>[
      if (pressed.isControlPressed) 'ctrl',
      if (pressed.isShiftPressed) 'shift',
      if (pressed.isAltPressed) 'alt',
      if (pressed.isMetaPressed) 'win',
    ];
    String? keyToken;
    for (final e in _keys.entries) {
      if (e.value == event.physicalKey) keyToken = e.key;
    }
    if (keyToken == null || parts.isEmpty) return null;
    return [...parts, keyToken].join('+');
  }

  /// Registers (or unregisters) the hotkey according to the current settings.
  static Future<bool> apply(SettingsService settings) async {
    _settings = settings;
    if (!isSupported) return false;
    try {
      final old = _registered;
      if (old != null) {
        await hotKeyManager.unregister(old);
        _registered = null;
      }
      if (!settings.captchaHotkeyEnabled) return true;
      final hotKey = parse(settings.captchaHotkey) ?? parse(defaultCombo)!;
      await hotKeyManager.register(hotKey, keyDownHandler: (_) => _onPressed());
      _registered = hotKey;
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> dispose() async {
    if (!isSupported) return;
    try {
      await hotKeyManager.unregisterAll();
    } catch (_) {}
    _registered = null;
  }

  static Future<void> _onPressed() async {
    final settings = _settings;
    if (settings == null || _busy) return;
    _busy = true;
    final fa = settings.locale.languageCode == 'fa';
    Future<void> say(String text) =>
        EspeakTtsService.speak(text, settings: settings, forceSpeak: true);
    try {
      await OnlineAccessService.ensure(settings, force: true);
      final bytes = await WindowsCaptchaCapture.capture();
      if (bytes == null || bytes.isEmpty) {
        await say(fa
            ? 'تصویر کپچا در پنجرهٔ فعال پیدا نشد. می‌توانید تصویر را در حل‌کنندهٔ کپچا باز کنید.'
            : 'No identifiable captcha image was found in the active window. You can open the image in Captcha Solver.');
        return;
      }
      if (!settings.isOfflineMode) {
        unawaited(say(fa
            ? 'تصویر برای هوش مصنوعی ارسال می‌شود. لطفاً منتظر پاسخ بمانید.'
            : 'Sending the image to AI. Please wait for the response.'));
      }
      final result = await CaptchaSolverService.solve(
        imageBytes: bytes,
        isOfflineMode: settings.isOfflineMode,
        activeProvider: settings.activeProvider,
        apiKey: settings.getApiKey(settings.activeProvider),
        modelName: settings.getSelectedModel(settings.activeProvider),
        customBaseUrl: settings.customBaseUrl,
        thinkingEffort: settings.thinkingEffort,
        isPersian: fa,
      );
      final value = result.finalClipboardValue.trim();
      if (value.isEmpty) {
        await say(fa ? 'کپچا حل نشد.' : 'The captcha could not be solved.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: value));
      await NativeBridgeService.bringAppToFront();
      onHotkeyCaptchaSolved?.call(bytes, result);
      final spoken = result.isMath ? value : value.split('').join(' ');
      await say(fa ? 'پاسخ کپچا: $spoken' : 'Captcha answer: $spoken');
    } catch (error) {
      await say(AiServiceException.fromError(error).message(fa));
    } finally {
      _busy = false;
    }
  }
}
