import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Local, bounded diagnostics. Do not save recognized text, URLs, tokens or
/// exception messages, which may contain personal data or credentials.
class DiagnosticsService {
  static Directory? _directory;
  static Future<void> _writes = Future<void>.value();
  static Future<void> initialize() async {
    try {
      _directory = Directory(
          '${(await getApplicationSupportDirectory()).path}/diagnostics');
      await _directory!.create(recursive: true);
    } catch (_) {}
  }

  static void record(String operation, Object error, StackTrace stack) {
    debugPrint('$operation: ${error.runtimeType}');
    final dir = _directory;
    if (dir == null) return;
    _writes = _writes.then((_) async {
      final file = File('${dir.path}/errors.log');
      if (await file.exists() && await file.length() > 256 * 1024) {
        final previous = File('${dir.path}/errors.previous.log');
        if (await previous.exists()) await previous.delete();
        await file.rename(previous.path);
      }
      final frames = stack.toString().split('\n').take(18).join('\n');
      await file.writeAsString(
          '${DateTime.now().toUtc().toIso8601String()} $operation ${error.runtimeType}\n$frames\n',
          mode: FileMode.append,
          flush: true);
    }).catchError((Object _) {});
  }
}
