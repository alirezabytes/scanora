import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../native_bridge_service.dart';

class EspeakDictionaryService {
  static bool isValid(String name, Uint8List bytes) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+_dict$').hasMatch(name) ||
        bytes.length < 1033 ||
        bytes.length > 20 * 1024 * 1024) {
      return false;
    }
    final header = ByteData.sublistView(bytes);
    final rules = header.getUint32(4, Endian.little);
    if (header.getUint32(0, Endian.little) != 1024 ||
        rules < 1032 ||
        rules >= bytes.length) {
      return false;
    }
    var position = 8;
    for (var bucket = 0; bucket < 1024; bucket++) {
      while (position < rules && bytes[position] != 0) {
        final length = bytes[position];
        if (length < 2 || position + length >= rules) return false;
        position += length;
      }
      if (position >= rules) return false;
      position++;
    }
    return position <= rules;
  }

  static Future<String> importDictionary(String name, Uint8List bytes,
      {String? previousDataDirectory, Directory? storageDirectory}) async {
    if (!isValid(name, bytes)) {
      throw const FormatException('Invalid eSpeak dictionary.');
    }
    final sourceParent = previousDataDirectory ??
        await NativeBridgeService.ensureEspeakDataExtracted();
    final source = Directory('$sourceParent/espeak-ng-data');
    if (!await File('${source.path}/phontab').exists()) {
      throw const FormatException('Voice files are unavailable.');
    }
    final support = storageDirectory ?? await getApplicationSupportDirectory();
    final destination = Directory(
        '${support.path}/voice-dictionaries/${DateTime.now().microsecondsSinceEpoch}');
    await destination.create(recursive: true);
    final target = Directory('${destination.path}/espeak-ng-data');
    await target.create();
    await for (final entry
        in source.list(recursive: true, followLinks: false)) {
      final relative = entry.path.substring(source.path.length + 1);
      final path = '${target.path}/$relative';
      if (entry is Directory) {
        await Directory(path).create(recursive: true);
      }
      if (entry is File) {
        await File(path).parent.create(recursive: true);
        await entry.copy(path);
      }
    }
    await File('${target.path}/$name').writeAsBytes(bytes, flush: true);
    return destination.path;
  }
}
