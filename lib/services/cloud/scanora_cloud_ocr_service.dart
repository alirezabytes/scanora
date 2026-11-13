import 'dart:convert';
import 'dart:async';
import '../ai/ai_access.dart';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'google_account_service.dart';
import 'google_drive_ocr_client.dart';

/// Connection stage of the optional Google Docs OCR account.
enum CloudSyncStage {
  unchecked,
  checking,
  synced,
  pendingBrowser,
  notSynced,
  error,
}

/// Connection status; it does not imply document synchronization or OCR success.
class ScanoraCloudSyncInfo {
  final CloudSyncStage stage;
  final String? accountEmail;
  final String? accountName;
  final DateTime? updatedAt;
  final String? detail;

  const ScanoraCloudSyncInfo({
    required this.stage,
    this.accountEmail,
    this.accountName,
    this.updatedAt,
    this.detail,
  });

  bool get isSynced => stage == CloudSyncStage.synced;

  String shortStatus({required bool isPersian}) {
    final email = accountEmail?.trim() ?? '';
    switch (stage) {
      case CloudSyncStage.unchecked:
        return isPersian
            ? 'وضعیت حساب بررسی نشده'
            : 'Account status not checked';
      case CloudSyncStage.synced:
        if (email.isNotEmpty) {
          return isPersian ? 'حساب متصل است ($email)' : 'Connected ($email)';
        }
        return isPersian ? 'حساب متصل است' : 'Connected';
      case CloudSyncStage.pendingBrowser:
        return isPersian
            ? 'در انتظار انتخاب حساب در مرورگر...'
            : 'Pending account selection in browser...';
      case CloudSyncStage.checking:
        return isPersian
            ? 'در حال بررسی اتصال حساب گوگل...'
            : 'Checking Google account connection...';
      case CloudSyncStage.notSynced:
        return isPersian
            ? 'حساب گوگل متصل نیست'
            : 'Google account not connected';
      case CloudSyncStage.error:
        return isPersian
            ? 'خطای اتصال حساب (${detail ?? "نیازمند تلاش مجدد"})'
            : 'Account connection failed (${detail ?? "Retry required"})';
    }
  }

  String fullReport({required bool isPersian}) {
    final email = accountEmail?.trim() ?? '';
    final name = accountName?.trim() ?? '';
    final accountLabel = (name.isNotEmpty && email.isNotEmpty && name != email)
        ? '$name ($email)'
        : (email.isNotEmpty ? email : name);

    switch (stage) {
      case CloudSyncStage.unchecked:
        return isPersian
            ? 'اتصال گوگل اختیاری و فقط برای OCR ابر است. برای بررسی حساب ذخیره‌شده، وضعیت حساب را باز کنید.'
            : 'Google sign-in is optional and used for Cloud OCR. Open account status to check a saved connection.';
      case CloudSyncStage.synced:
        if (accountLabel.isNotEmpty) {
          return isPersian
              ? 'حساب گوگل متصل است: $accountLabel'
              : 'Google account connected: $accountLabel';
        }
        return isPersian
            ? 'حساب گوگل متصل است. با ارسال تصویر، OCR در Google Docs انجام می‌شود.'
            : 'Google account connected. Google Docs OCR runs when you submit an image.';
      case CloudSyncStage.pendingBrowser:
        return isPersian
            ? 'در انتظار انتخاب حساب گوگل در صفحهٔ ورود.'
            : 'Waiting for Google account selection in the sign-in window.';
      case CloudSyncStage.checking:
        return isPersian
            ? 'در حال بررسی اتصال حساب با سرورهای گوگل...'
            : 'Checking Google account connection...';
      case CloudSyncStage.notSynced:
        return isPersian
            ? 'حساب گوگل متصل نیست. برای استفاده از Scanora Cloud حساب خود را متصل کنید.'
            : 'Google account is not connected. Connect your account to use Scanora Cloud.';
      case CloudSyncStage.error:
        return isPersian
            ? 'خطای اتصال حساب گوگل (${detail ?? "نیازمند تایید مجدد"}).'
            : 'Google account connection failed (${detail ?? "Re-authorization required"}).';
    }
  }
}

/// Google Docs OCR using verified Google authorization and Drive v3 only.
class ScanoraCloudOcrService {
  static DateTime? _accessCheckedAt;
  static Future<void> checkAccess({bool force = false}) async {
    if (!force &&
        _accessCheckedAt != null &&
        DateTime.now().difference(_accessCheckedAt!).inSeconds < 30) {
      return;
    }
    final profile = await GoogleAccountService.verifiedProfile()
        .timeout(const Duration(seconds: 8));
    if (profile == null) {
      throw const AiServiceException(AiFailureKind.googleSignIn);
    }
    _accessCheckedAt = DateTime.now();
  }

  ScanoraCloudOcrService._();
  static final authorizationSuccessNotifier = ValueNotifier<int>(0);
  static final syncStatusNotifier = ValueNotifier<ScanoraCloudSyncInfo>(
      const ScanoraCloudSyncInfo(stage: CloudSyncStage.unchecked));
  static Future<bool>? _authorizing;
  @visibleForTesting
  static Map<String, int> lastHttpOperations = {};
  static const _persianLetterForms = {'ي': 'ی', 'ى': 'ی', 'ك': 'ک'};

  static Future<ScanoraCloudSyncInfo> refreshSyncStatus() async {
    if (_authorizing != null) return syncStatusNotifier.value;
    try {
      final profile = await GoogleAccountService.verifiedProfile();
      return syncStatusNotifier.value = ScanoraCloudSyncInfo(
          stage: profile == null
              ? CloudSyncStage.notSynced
              : CloudSyncStage.synced,
          accountEmail: profile?['email'],
          accountName: profile?['name'],
          updatedAt: DateTime.now());
    } catch (error) {
      return syncStatusNotifier.value = ScanoraCloudSyncInfo(
          stage: CloudSyncStage.error,
          detail: error.toString(),
          updatedAt: DateTime.now());
    }
  }

  static Future<bool> isGoogleDriveAuthorized() async =>
      (await refreshSyncStatus()).isSynced;

  static Future<bool> ensureAuthorized({bool? isPersian}) async {
    if (await isGoogleDriveAuthorized()) return true;
    return authorizeWithBrowser(isPersian: isPersian);
  }

  /// Android uses Google's native account chooser; Windows uses accounts.google.com.
  static Future<bool> authorizeWithBrowser(
          {int clientIndex = 0, bool? isPersian}) =>
      _authorizing ??= _authorize(isPersian ?? false)
          .whenComplete(() => _authorizing = null);

  static Future<bool> _authorize(bool isPersian) async {
    syncStatusNotifier.value = ScanoraCloudSyncInfo(
        stage: CloudSyncStage.pendingBrowser, updatedAt: DateTime.now());
    try {
      final profile =
          await GoogleAccountService.authorize(isPersian: isPersian);
      syncStatusNotifier.value = ScanoraCloudSyncInfo(
          stage: CloudSyncStage.synced,
          accountEmail: profile['email'],
          accountName: profile['name'],
          updatedAt: DateTime.now());
      authorizationSuccessNotifier.value++;
      return true;
    } catch (error) {
      syncStatusNotifier.value = ScanoraCloudSyncInfo(
          stage: CloudSyncStage.error,
          detail: error.toString(),
          updatedAt: DateTime.now());
      return false;
    }
  }

  static Future<void> disconnectGoogleAccount() async {
    _accessCheckedAt = null;
    await GoogleAccountService.disconnect();
    syncStatusNotifier.value = ScanoraCloudSyncInfo(
        stage: CloudSyncStage.notSynced, updatedAt: DateTime.now());
  }

  static Future<String> recognize(
    Uint8List imageBytes, {
    bool isPersian = true,
    bool allowInteractiveBrowserAuth = true,
    void Function(int percent)? onProgress,
  }) async {
    if (imageBytes.isEmpty) {
      throw const ScanoraCloudException('The image is empty.');
    }
    await checkAccess();
    final prepared = await Isolate.run(() => prepareUpload(imageBytes));
    return _recognize(prepared, 'image/jpeg', 'scanora_page.jpg', isPersian,
        allowInteractiveBrowserAuth, onProgress);
  }

  static Future<String> recognizePdfBytes(
    Uint8List pdfBytes, {
    String fileName = 'scanora_document.pdf',
    bool isPersian = true,
    void Function(int percent)? onProgress,
  }) =>
      _recognize(
          pdfBytes, 'application/pdf', fileName, isPersian, true, onProgress);

  static Future<String> _recognize(
      Uint8List bytes,
      String mime,
      String fileName,
      bool isPersian,
      bool interactive,
      void Function(int)? onProgress) async {
    await checkAccess();
    onProgress?.call(15);
    if (interactive && !await ensureAuthorized(isPersian: isPersian)) {
      throw ScanoraCloudException(
          syncStatusNotifier.value.fullReport(isPersian: isPersian));
    }
    final access = await GoogleAccountService.accessToken();
    if (access == null) {
      throw ScanoraCloudException(isPersian
          ? 'برای OCR گوگل ابتدا حساب گوگل را در تنظیمات متصل کنید.'
          : 'Connect your Google account in Settings before using Google Docs OCR.');
    }
    final client = http.Client();
    lastHttpOperations = {};
    try {
      final text =
          await GoogleDriveOcrClient(client, onTrace: (operation, status) {
        lastHttpOperations[operation] = status;
      }).recognize(
              bytes: bytes,
              mimeType: mime,
              fileName: fileName,
              accessToken: access,
              language: isPersian ? 'fa' : 'en',
              onProgress: onProgress);
      onProgress?.call(100);
      return cleanGoogleDriveOcrOutput(text);
    } catch (error) {
      throw ScanoraCloudException('Google Docs OCR: $error');
    } finally {
      client.close();
    }
  }

  /// Preserve the original resolution where possible; compress only as needed.
  @visibleForTesting
  static Uint8List prepareUpload(Uint8List source) {
    final decoded = img.decodeImage(source);
    if (decoded == null) {
      throw const ScanoraCloudException('The image cannot be decoded.');
    }
    var working = img.bakeOrientation(decoded);
    if (working.hasAlpha) {
      final white = img.Image(
          width: working.width, height: working.height, numChannels: 3);
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(white, working);
      working = white;
    }
    for (var quality = 96; quality >= 72; quality -= 8) {
      final bytes =
          Uint8List.fromList(img.encodeJpg(working, quality: quality));
      if (bytes.length <= 2 * 1024 * 1024) return bytes;
    }
    while (true) {
      working = img.copyResize(working, width: (working.width * 0.85).round());
      final bytes = Uint8List.fromList(img.encodeJpg(working, quality: 88));
      if (bytes.length <= 2 * 1024 * 1024) return bytes;
    }
  }

  @visibleForTesting
  static String cleanGoogleDriveOcrOutput(String raw) {
    final withoutBom = raw.replaceAll('\uFEFF', '');
    final lines =
        withoutBom.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    final cleanedLines = <String>[];
    final separatorRegex = RegExp(r'^_{10,}\s*$');

    for (final line in lines) {
      if (separatorRegex.hasMatch(line.trim())) {
        continue;
      }
      cleanedLines.add(line.trimRight());
    }

    return _normalize(cleanedLines.join('\n'));
  }

  /// Parses the JSON payload returned by `https://lens.google.com/qfmetadata`.
  @visibleForTesting
  static String parseGoogleLensMetadata(String rawBody) {
    var cleaned = rawBody.trimLeft();
    if (cleaned.startsWith(")]}'")) {
      final firstNewline = cleaned.indexOf('\n');
      cleaned =
          firstNewline >= 0 ? cleaned.substring(firstNewline + 1).trim() : '';
    }
    if (cleaned.isEmpty) return '';

    final dynamic root;
    try {
      root = jsonDecode(cleaned);
    } catch (_) {
      return '';
    }

    final lines = <String>[];
    _collectLensLines(root, lines);
    return lines.join('\n').trim();
  }

  /// Parses inline `AF_initDataCallback` blocks from a Google Lens HTML page.
  @visibleForTesting
  static String parseGoogleLensHtml(String html) {
    final lines = <String>[];
    final callbackRegex = RegExp(
      r"AF_initDataCallback\(\{key:\s*'[^']*'.*?data:(\[.*?\]),\s*sideChannel:",
      dotAll: true,
    );
    for (final match in callbackRegex.allMatches(html)) {
      final jsonPart = match.group(1);
      if (jsonPart == null || jsonPart.isEmpty) continue;
      try {
        final dynamic parsed = jsonDecode(jsonPart);
        _collectLensLines(parsed, lines);
      } catch (_) {}
    }
    return lines.join('\n').trim();
  }

  static void _collectLensLines(dynamic node, List<String> outLines) {
    if (node is! List || node.isEmpty) return;

    if (_isWordTupleList(node)) {
      final buffer = StringBuffer();
      for (final wordTuple in node) {
        final list = wordTuple as List;
        final word = list[1] as String;
        final sep =
            (list.length >= 3 && list[2] is String) ? list[2] as String : ' ';
        buffer.write(word);
        buffer.write(sep);
      }
      final line = buffer.toString().trim();
      if (line.isNotEmpty) {
        outLines.add(line);
      }
      return;
    }

    for (final child in node) {
      if (child is List) {
        _collectLensLines(child, outLines);
      }
    }
  }

  static bool _isWordTupleList(List<dynamic> candidate) {
    if (candidate.isEmpty) return false;
    for (final item in candidate) {
      if (item is! List || item.length < 3) return false;
      final idPart = item[0];
      final wordPart = item[1];
      final sepPart = item[2];
      if (idPart is! List || idPart.isEmpty || idPart[0] is! int) return false;
      if (wordPart is! String || wordPart.isEmpty) return false;
      if (sepPart != null && sepPart is! String) return false;
    }
    return true;
  }

  static String _normalize(String raw) {
    final mapped = raw.runes.map((r) {
      final ch = String.fromCharCode(r);
      return _persianLetterForms[ch] ?? ch;
    }).join();
    return mapped.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  }
}

class ScanoraCloudException implements Exception {
  final String message;
  const ScanoraCloudException(this.message);
  @override
  String toString() => message;
}
