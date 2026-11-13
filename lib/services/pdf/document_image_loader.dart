import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'document_formats.dart';

class DocumentImageLoader {
  static Future<List<Uint8List>?> load(Uint8List bytes, String name) =>
      Isolate.run(() => _load(bytes, name));
  static List<Uint8List>? _load(Uint8List bytes, String name) {
    final extension = DocumentFormats.extension(name);
    if (DocumentFormats.images.contains(extension)) {
      final image = img.decodeImage(bytes);
      if (image == null) {
        throw const FormatException('This image format could not be decoded.');
      }
      // Animated GIFs describe one picture. Multi-page TIFFs contain book pages.
      return [
        for (final frame
            in (['tif', 'tiff'].contains(extension) ? image.frames : [image]))
          Uint8List.fromList(img.encodePng(img.bakeOrientation(frame)))
      ];
    }
    if (!['cbz', 'zip'].contains(extension)) return null;
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.findFile('audiobook.json') != null) return null;
    final files = archive.files
        .where((f) =>
            f.isFile &&
            !f.name.startsWith('__MACOSX/') &&
            DocumentFormats.images.contains(DocumentFormats.extension(f.name)))
        .toList();
    if (files.isEmpty) return null;
    files.sort((a, b) => naturalDocumentOrder(a.name, b.name));
    return [
      for (final file in files)
        ..._load(Uint8List.fromList(file.content), file.name)!
    ];
  }
}

int naturalDocumentOrder(String a, String b) {
  final ar = RegExp(r'\d+|\D+')
      .allMatches(a.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  final br = RegExp(r'\d+|\D+')
      .allMatches(b.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  for (var i = 0; i < ar.length && i < br.length; i++) {
    final ai = int.tryParse(ar[i]), bi = int.tryParse(br[i]);
    final result =
        ai != null && bi != null ? ai.compareTo(bi) : ar[i].compareTo(br[i]);
    if (result != 0) return result;
  }
  return ar.length.compareTo(br.length);
}
