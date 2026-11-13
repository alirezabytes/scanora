import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../native_bridge_service.dart';

class DemoLicenseService extends ChangeNotifier {
  /// Compile-time flag: FALSE in main builds (`Scanora.exe` & `Scanora-Universal.apk`),
  /// TRUE only when compiled via `build_demo.bat` with `--dart-define=SCANORA_DEMO=true`.
  static const bool isDemoBuildCompiled = bool.fromEnvironment(
    'SCANORA_DEMO',
    defaultValue: false,
  );

  /// Default demo duration in hours specified at compile time via `--dart-define=SCANORA_DEMO_HOURS=24`
  static const int compiledDemoHours = int.fromEnvironment(
    'SCANORA_DEMO_HOURS',
    defaultValue: 24,
  );

  /// Default demo duration in minutes (optional fine-grained override for testing)
  static const int compiledDemoMinutes = int.fromEnvironment(
    'SCANORA_DEMO_MINUTES',
    defaultValue: 0,
  );

  static const String _kSecretSalt =
      'scanora-public-source-demo-only';

  bool _initialized = false;
  String _deviceCode = 'SCN-00000000';
  bool _isPermanentlyActivated = false;
  int _firstLaunchMs = 0;
  int _lastSeenMs = 0;
  int _accumulatedTamperMs = 0;
  int _allowedDurationMs = 0;
  final Set<String> _redeemedTokens = {};
  Timer? _watchdogTimer;

  bool get isInitialized => _initialized;
  String get deviceCode => _deviceCode;

  /// Returns true if this is a Demo build AND it has not been permanently unlocked.
  bool get isDemoActive => isDemoBuildCompiled && !_isPermanentlyActivated;

  bool get isPermanentlyActivated =>
      !isDemoBuildCompiled || _isPermanentlyActivated;

  /// Remaining milliseconds of demo time
  int get remainingMilliseconds {
    if (!isDemoBuildCompiled || _isPermanentlyActivated) {
      return const Duration(days: 36500).inMilliseconds;
    }
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final wallElapsed = now > _firstLaunchMs ? (now - _firstLaunchMs) : 0;
    final effectiveElapsed = wallElapsed + _accumulatedTamperMs;
    final rem = _allowedDurationMs - effectiveElapsed;
    return rem > 0 ? rem : 0;
  }

  bool get isExpired {
    if (!isDemoBuildCompiled || _isPermanentlyActivated) return false;
    return remainingMilliseconds <= 0;
  }

  String formatRemainingTime({required bool isPersian}) {
    if (!isDemoBuildCompiled || _isPermanentlyActivated) {
      return isPersian ? 'نسخه کامل و دائمی' : 'Full Permanent Version';
    }
    final remMs = remainingMilliseconds;
    if (remMs <= 0) {
      return isPersian ? 'منقضی شده (۰ دقیقه)' : 'Expired (0m)';
    }
    final totalMinutes = (remMs / 60000).ceil();
    final days = totalMinutes ~/ (60 * 24);
    final hours = (totalMinutes % (60 * 24)) ~/ 60;
    final mins = totalMinutes % 60;

    if (isPersian) {
      final parts = <String>[];
      if (days > 0) parts.add('$days روز');
      if (hours > 0) parts.add('$hours ساعت');
      parts.add('$mins دقیقه');
      return parts.join(' و ');
    } else {
      final parts = <String>[];
      if (days > 0) parts.add('${days}d');
      if (hours > 0) parts.add('${hours}h');
      parts.add('${mins}m');
      return parts.join(' ');
    }
  }

  Future<void> init() async {
    if (_initialized) return;

    final rawDeviceId = await NativeBridgeService.getDeviceIdentifier();
    _deviceCode = computeDeviceCode(rawDeviceId);

    if (!isDemoBuildCompiled) {
      _isPermanentlyActivated = true;
      _initialized = true;
      notifyListeners();
      return;
    }

    const initialMinutes = compiledDemoMinutes > 0
        ? compiledDemoMinutes
        : (compiledDemoHours > 0 ? compiledDemoHours * 60 : 24 * 60);
    const defaultDurationMs = initialMinutes * 60 * 1000;

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final pkgInstallMs =
        await NativeBridgeService.getAndroidPackageFirstInstallTime();
    final loaded = await _loadState();

    if (loaded != null) {
      _isPermanentlyActivated = loaded['perm'] == true;
      _firstLaunchMs = (loaded['first'] as int?) ?? now;
      if (pkgInstallMs > 1700000000000 && pkgInstallMs < _firstLaunchMs) {
        _firstLaunchMs = pkgInstallMs;
      }
      _lastSeenMs = (loaded['last'] as int?) ?? now;
      _accumulatedTamperMs = (loaded['tamper'] as int?) ?? 0;
      _allowedDurationMs = (loaded['allowed'] as int?) ?? defaultDurationMs;
      final tokens = loaded['tokens'] as List<dynamic>? ?? [];
      _redeemedTokens.addAll(tokens.map((e) => e.toString()));

      // Clock rollback detection: if system clock was moved backwards, add the difference to tamper counter
      if (now < _lastSeenMs) {
        _accumulatedTamperMs += (_lastSeenMs - now);
      }
      _lastSeenMs = now;
    } else {
      _isPermanentlyActivated = false;
      // Anchor to Android OS package firstInstallTime if available so Clear Data / Clear Cache never resets the timer!
      _firstLaunchMs = (pkgInstallMs > 1700000000000 && pkgInstallMs <= now)
          ? pkgInstallMs
          : now;
      _lastSeenMs = now;
      _accumulatedTamperMs = 0;
      _allowedDurationMs = defaultDurationMs;
    }

    await _saveState();

    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final currentNow = DateTime.now().toUtc().millisecondsSinceEpoch;
      if (currentNow < _lastSeenMs) {
        _accumulatedTamperMs += (_lastSeenMs - currentNow);
      }
      _lastSeenMs = currentNow;
      await _saveState();
      notifyListeners();
    });

    _initialized = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    super.dispose();
  }

  /// Generates an 8-character Device Code (`SCN-XXXXXXXX`) from raw hardware identifier
  static String computeDeviceCode(String rawId) {
    final hash = _computeSignature('DEVICE_ID:$rawId').substring(0, 8);
    return 'SCN-$hash';
  }

  /// Generates an offline cryptographic activation or time-extension key:
  /// - For permanent full unlock (`isPermanent: true`):
  ///   `SCAN-PRO-PERM-<SEQ>-<10_CHAR_SIG>`
  /// - For time extension (`hoursToAdd > 0`):
  ///   `SCAN-EXT-<HOURS_HEX>-<SEQ>-<10_CHAR_SIG>`
  /// - `targetDeviceCode`: either the user's `SCN-XXXXXXXX` or `ANY` (universal key)
  static String generateLicenseKey({
    required String targetDeviceCode,
    required bool isPermanent,
    int hoursToAdd = 24,
    int? minutesToAdd,
    int sequenceNumber = 1,
  }) {
    final cleanDevice = targetDeviceCode.trim().toUpperCase();
    final effectiveDevice =
        (cleanDevice == '*' || cleanDevice == 'ANY' || cleanDevice.isEmpty)
            ? 'ANY'
            : cleanDevice;
    final seqHex = sequenceNumber
        .clamp(1, 9999)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(3, '0');

    if (isPermanent) {
      final payload = 'PRO|PERM|$effectiveDevice|$seqHex';
      final sig = _computeSignature(payload).substring(0, 10);
      final devFlag = effectiveDevice == 'ANY' ? 'U' : 'D';
      return 'SCAN-PRO-$devFlag$seqHex-$sig';
    } else if (minutesToAdd != null && minutesToAdd > 0) {
      final mins = minutesToAdd.clamp(1, 5256000);
      final minsHex = mins.toRadixString(16).toUpperCase().padLeft(6, '0');
      final payload = 'EXTM|$minsHex|$effectiveDevice|$seqHex';
      final sig = _computeSignature(payload).substring(0, 10);
      final devFlag = effectiveDevice == 'ANY' ? 'U' : 'D';
      return 'SCAN-EXTM-$minsHex-$devFlag$seqHex-$sig';
    } else {
      final hours = hoursToAdd.clamp(1, 87600);
      final hoursHex = hours.toRadixString(16).toUpperCase().padLeft(4, '0');
      final payload = 'EXT|$hoursHex|$effectiveDevice|$seqHex';
      final sig = _computeSignature(payload).substring(0, 10);
      final devFlag = effectiveDevice == 'ANY' ? 'U' : 'D';
      return 'SCAN-EXT-$hoursHex-$devFlag$seqHex-$sig';
    }
  }

  /// Verifies and applies an offline extension or permanent activation key.
  /// Returns `(bool success, String message)`.
  Future<(bool, String)> redeemLicenseKey(
    String rawKey, {
    required bool isPersian,
  }) async {
    final clean = rawKey.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (clean.isEmpty) {
      return (
        false,
        isPersian
            ? 'لطفاً کد فعال‌سازی یا تمدید را وارد کنید.'
            : 'Please enter an activation or extension code.',
      );
    }

    if (_redeemedTokens.contains(clean)) {
      return (
        false,
        isPersian
            ? 'این کد قبلاً روی این دستگاه استفاده شده است. برای تمدید مجدد، کد جدید دریافت کنید.'
            : 'This code has already been used on this device.',
      );
    }

    final parts = clean.split('-');
    // Format 1: Permanent Key -> SCAN-PRO-<D/U><SEQ>-<SIG> (4 parts)
    if (parts.length == 4 && parts[0] == 'SCAN' && parts[1] == 'PRO') {
      final seqPart = parts[2];
      final providedSig = parts[3];
      if (seqPart.length == 4) {
        final devFlag = seqPart[0];
        final seqHex = seqPart.substring(1);
        final targetDev = devFlag == 'U' ? 'ANY' : _deviceCode;
        final expectedPayload = 'PRO|PERM|$targetDev|$seqHex';
        final expectedSig = _computeSignature(expectedPayload).substring(0, 10);

        if (providedSig == expectedSig) {
          _isPermanentlyActivated = true;
          _redeemedTokens.add(clean);
          await _saveState();
          notifyListeners();
          return (
            true,
            isPersian
                ? 'تبریک! برنامه به صورت دائمی فعال شد و محدودیت نسخه دمو به طور کامل برداشته شد.'
                : 'Congratulations! Scanora is now permanently activated with no time limits.',
          );
        }
      }
    }

    // Format 2: Time Extension Key -> SCAN-EXT-<HOURS_HEX>-<D/U><SEQ>-<SIG> (5 parts)
    if (parts.length == 5 && parts[0] == 'SCAN' && parts[1] == 'EXT') {
      final hoursHex = parts[2];
      final seqPart = parts[3];
      final providedSig = parts[4];
      final hours = int.tryParse(hoursHex, radix: 16);

      if (hours != null && hours > 0 && seqPart.length == 4) {
        final devFlag = seqPart[0];
        final seqHex = seqPart.substring(1);
        final targetDev = devFlag == 'U' ? 'ANY' : _deviceCode;
        final expectedPayload = 'EXT|$hoursHex|$targetDev|$seqHex';
        final expectedSig = _computeSignature(expectedPayload).substring(0, 10);

        if (providedSig == expectedSig) {
          final now = DateTime.now().toUtc().millisecondsSinceEpoch;
          final wallElapsed = now > _firstLaunchMs ? (now - _firstLaunchMs) : 0;
          final effectiveElapsed = wallElapsed + _accumulatedTamperMs;
          final baseMs = _allowedDurationMs > effectiveElapsed
              ? _allowedDurationMs
              : effectiveElapsed;
          _allowedDurationMs = baseMs + (hours * 3600 * 1000);
          _redeemedTokens.add(clean);
          await _saveState();
          notifyListeners();
          return (
            true,
            isPersian
                ? 'زمان استفاده از برنامه با موفقیت به مدت $hours ساعت تمدید شد!'
                : 'Demo duration successfully extended by $hours hours!',
          );
        }
      }
    }

    // Format 3: Custom Minutes Extension Key -> SCAN-EXTM-<MINS_HEX>-<D/U><SEQ>-<SIG> (5 parts)
    if (parts.length == 5 && parts[0] == 'SCAN' && parts[1] == 'EXTM') {
      final minsHex = parts[2];
      final seqPart = parts[3];
      final providedSig = parts[4];
      final mins = int.tryParse(minsHex, radix: 16);

      if (mins != null && mins > 0 && seqPart.length == 4) {
        final devFlag = seqPart[0];
        final seqHex = seqPart.substring(1);
        final targetDev = devFlag == 'U' ? 'ANY' : _deviceCode;
        final expectedPayload = 'EXTM|$minsHex|$targetDev|$seqHex';
        final expectedSig = _computeSignature(expectedPayload).substring(0, 10);

        if (providedSig == expectedSig) {
          final now = DateTime.now().toUtc().millisecondsSinceEpoch;
          final wallElapsed = now > _firstLaunchMs ? (now - _firstLaunchMs) : 0;
          final effectiveElapsed = wallElapsed + _accumulatedTamperMs;
          final baseMs = _allowedDurationMs > effectiveElapsed
              ? _allowedDurationMs
              : effectiveElapsed;
          _allowedDurationMs = baseMs + (mins * 60 * 1000);
          _redeemedTokens.add(clean);
          await _saveState();
          notifyListeners();
          return (
            true,
            isPersian
                ? 'زمان استفاده از برنامه با موفقیت به مدت $mins دقیقه تمدید شد!'
                : 'Demo duration successfully extended by $mins minutes!',
          );
        }
      }
    }

    return (
      false,
      isPersian
          ? 'کد وارد شده نامعتبر است یا مربوط به دستگاه دیگری می‌باشد.'
          : 'Invalid activation code or code belongs to another device.',
    );
  }

  /// Deterministic 128-bit double-round keyed hash (works identically in Dart VM, Flutter, and CLI keygen)
  static String _computeSignature(String input) {
    final bytes = utf8.encode('$_kSecretSalt::$input::$_kSecretSalt');
    int h1 = 0xCBF29CE484222325;
    int h2 = 0x84222325CBF29CE4;

    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      h1 ^= b;
      h1 = (h1 * 0x100000001B3) & 0x7FFFFFFFFFFFFFFF;
      h1 ^= (h1 >> 31);

      h2 ^= (b + i * 131);
      h2 = (h2 * 0x1099511628211) & 0x7FFFFFFFFFFFFFFF;
      h2 ^= (h2 >> 29);
    }

    final p1 = h1.toRadixString(16).toUpperCase().padLeft(16, '0');
    final p2 = h2.toRadixString(16).toUpperCase().padLeft(16, '0');
    return '$p1$p2';
  }

  List<File> _getStateFiles() {
    final files = <File>[];
    if (Platform.isAndroid) {
      files.add(File('/data/user/0/com.scanora.app/files/.scanora_lic_v2.dat'));
      files.add(File('${Directory.systemTemp.path}/.scanora_lic_v2.dat'));
    } else if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      final userProfile =
          Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
      files.add(File('$appData\\Scanora\\.scanora_lic_v2.dat'));
      files.add(File('$localAppData\\.scanora_lic_v2.dat'));
      files.add(File('$userProfile\\.scanora_lic_v2.dat'));
    } else {
      files.add(File('${Directory.systemTemp.path}/.scanora_lic_v2.dat'));
    }
    return files;
  }

  Future<Map<String, dynamic>?> _loadState() async {
    // 1. Check OS-persistent storage first (survives Clear Cache & Clear Data on Android, and Registry on Windows)
    try {
      final osRaw = await NativeBridgeService.loadPersistentLicenseState(
          '.scn_lic_$_deviceCode.dat');
      if (osRaw != null && osRaw.isNotEmpty) {
        final decoded = jsonDecode(utf8.decode(base64Decode(osRaw)))
            as Map<String, dynamic>;
        return decoded;
      }
    } catch (_) {}

    // 2. Fallback to local state files
    for (final file in _getStateFiles()) {
      try {
        if (file.existsSync()) {
          final raw = await file.readAsString();
          final decoded = jsonDecode(utf8.decode(base64Decode(raw)))
              as Map<String, dynamic>;
          return decoded;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> _saveState() async {
    final payload = {
      'perm': _isPermanentlyActivated,
      'first': _firstLaunchMs,
      'last': _lastSeenMs,
      'tamper': _accumulatedTamperMs,
      'allowed': _allowedDurationMs,
      'tokens': _redeemedTokens.toList(),
    };
    final encoded = base64Encode(utf8.encode(jsonEncode(payload)));

    // 1. Save to OS-persistent storage (Android MediaStore/Shared Downloads + Windows Registry)
    await NativeBridgeService.savePersistentLicenseState(
        '.scn_lic_$_deviceCode.dat', encoded);

    // 2. Save to local state files
    for (final file in _getStateFiles()) {
      try {
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        await file.writeAsString(encoded, flush: true);
      } catch (_) {}
    }
  }
}
