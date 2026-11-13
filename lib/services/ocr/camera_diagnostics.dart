import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Local evidence for an explicitly built camera investigation APK. Ordinary
/// releases never save camera images or recognized text through this class.
class CameraDiagnostics {
  static const enabled = bool.fromEnvironment('SCANORA_CAMERA_DIAGNOSTICS');
  static const _imageLimit = 160;
  static const _imageBytesLimit = 192 * 1024 * 1024;
  static const _logBytesLimit = 16 * 1024 * 1024;
  static Future<Directory?>? _directory;
  static Future<void> _writes = Future<void>.value();
  static int _images = 0;
  static int _bytes = 0;
  static int _logBytes = 0;
  static int _events = 0;
  static final _session = DateTime.now().toUtc().microsecondsSinceEpoch;

  static Future<Directory?> _open() async {
    if (!enabled || !Platform.isAndroid) return null;
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return null;
      final directory = Directory('${base.path}/camera_diagnostics');
      await directory.create(recursive: true);
      // Bound the entire investigation folder, including previous app starts.
      await for (final entry in directory.list()) {
        if (entry is File) {
          if (entry.path.endsWith('.jsonl')) {
            _logBytes += await entry.length();
          } else {
            _bytes += await entry.length();
            _images++;
          }
        }
      }
      return directory;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> image(String stage, Uint8List bytes,
      {String extension = 'jpg',
      Map<String, Object?> metadata = const {}}) async {
    if (!enabled || !Platform.isAndroid) return null;
    try {
      final directory = await (_directory ??= _open());
      if (directory == null ||
          _images >= _imageLimit ||
          _bytes + bytes.length > _imageBytesLimit) {
        return null;
      }
      final name = '${_session}_${++_images}_$stage.$extension';
      _bytes += bytes.length;
      await File('${directory.path}/$name').writeAsBytes(bytes, flush: true);
      event('image', {'file': name, 'stage': stage, ...metadata});
      return name;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> luma(Uint8List pixels, int width, int height,
      {String stage = 'preview'}) async {
    if (!enabled || !Platform.isAndroid || _images >= _imageLimit) return null;
    try {
      final png = await Isolate.run(() => img.encodePng(
          img.Image.fromBytes(
              width: width,
              height: height,
              bytes: pixels.buffer,
              bytesOffset: pixels.offsetInBytes,
              numChannels: 1),
          level: 1));
      return await image(stage, png,
          extension: 'png', metadata: {'width': width, 'height': height});
    } catch (_) {
      return null;
    }
  }

  static void event(String name, Map<String, Object?> data) {
    if (!enabled || !Platform.isAndroid || _events++ >= 3600) return;
    final line = jsonEncode({
      'utc': DateTime.now().toUtc().toIso8601String(),
      'event': name,
      ...data,
    });
    _writes = _writes.then((_) async {
      final directory = await (_directory ??= _open());
      if (directory == null || _logBytes + line.length * 4 > _logBytesLimit) {
        return;
      }
      _logBytes += line.length * 4;
      await File('${directory.path}/$_session.jsonl')
          .writeAsString('$line\n', mode: FileMode.append, flush: true);
    }).catchError((Object _) {});
  }
}
