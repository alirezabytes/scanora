import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class AppStorageService {
  /// Returns the default or user-configured export directory.
  /// On Windows, defaults to `~/Documents/Scanora`.
  /// On Android / Linux / macOS, defaults to suitable documents/downloads folder.
  static Future<Directory> getExportDirectory([String? customPath]) async {
    if (customPath != null && customPath.trim().isNotEmpty) {
      final customDir = Directory(customPath.trim());
      if (!await customDir.exists()) {
        try {
          await customDir.create(recursive: true);
        } catch (_) {}
      }
      if (await customDir.exists()) {
        return customDir;
      }
    }

    Directory baseDir;
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          'C:\\';
      baseDir = Directory('$userProfile\\Documents\\Scanora');
    } else if (Platform.isAndroid) {
      // Standard Android Download or Documents location
      final downloadDir = Directory('/storage/emulated/0/Download/Scanora');
      final docDir = Directory('/storage/emulated/0/Documents/Scanora');
      if (await downloadDir.exists()) {
        baseDir = downloadDir;
      } else {
        baseDir = docDir;
      }
    } else {
      final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
      baseDir = Directory('$home/Documents/Scanora');
    }

    if (!await baseDir.exists()) {
      try {
        await baseDir.create(recursive: true);
      } catch (e) {
        debugPrint('Could not create default Scanora directory: $e');
        return Directory.systemTemp;
      }
    }

    return baseDir;
  }

  /// Saves binary data to a file inside the export directory
  static Future<File> saveFile({
    required String fileName,
    required List<int> bytes,
    String? customDirectory,
  }) async {
    final target = await _reserveFile(fileName, customDirectory);
    try {
      return await target.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await target.delete();
      rethrow;
    }
  }

  /// Saves text data to a file inside the export directory
  static Future<File> saveString({
    required String fileName,
    required String content,
    String? customDirectory,
  }) async {
    return saveFile(
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(content)),
        customDirectory: customDirectory);
  }

  /// Opens the folder in the operating system's native file manager
  static Future<bool> openDirectory(String directoryPath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [directoryPath]);
        return true;
      } else if (Platform.isMacOS) {
        await Process.run('open', [directoryPath]);
        return true;
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [directoryPath]);
        return true;
      }
    } catch (e) {
      debugPrint('Failed to open directory: $e');
    }
    return false;
  }

  /// Highlights or opens a specific file in the file manager
  static Future<bool> highlightFile(String filePath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', ['/select,', filePath]);
        return true;
      } else {
        final parent = File(filePath).parent.path;
        return await openDirectory(parent);
      }
    } catch (e) {
      debugPrint('Failed to highlight file: $e');
    }
    return false;
  }

  static String sourceStem(String name) =>
      name.replaceFirst(RegExp(r'\.[a-zA-Z0-9]+$'), '');

  static String outputName(String stem, String extension) {
    final name = stem.trim();
    final suffix = '.$extension';
    return name.toLowerCase().endsWith(suffix.toLowerCase())
        ? name
        : '$name$suffix';
  }

  static Future<File> _reserveFile(String name, String? directory) async {
    final exportDir = await getExportDirectory(directory);
    final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    final stem = sourceStem(safeName);
    final extension = safeName.substring(stem.length);
    for (var index = 1;; index++) {
      final candidate = index == 1 ? safeName : '$stem ($index)$extension';
      final file = File('${exportDir.path}${Platform.pathSeparator}$candidate');
      try {
        return await file.create(exclusive: true);
      } on PathExistsException {
        continue;
      }
    }
  }
}
