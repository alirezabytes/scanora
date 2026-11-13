import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';
import 'package:image/image.dart' as img;
import 'camera_scene_ocr.dart';

/// Combine independently recognized lines and leave doubtful regions marked.
class AutomaticHandwriting {
  static final _persian = RegExp(r'[\u0621-\u063A\u0641-\u064A\u0671-\u06D3]');
  static final _latin = RegExp(r'[A-Za-z]+');
  static final _letters = RegExp(r'\p{L}', unicode: true);

  static Future<List<Uint8List>> cropLines(
          Uint8List bytes, List<Rect> bounds) =>
      Isolate.run(() {
        final source = img.decodeImage(bytes);
        if (source == null) return <Uint8List>[];
        return [for (final rect in bounds) _crop(source, rect)];
      });

  static Uint8List _crop(img.Image source, Rect rect) {
    final padded = rect.inflate(rect.height * .14);
    final x = padded.left.floor().clamp(0, source.width - 1);
    final y = padded.top.floor().clamp(0, source.height - 1);
    final right = padded.right.ceil().clamp(x + 1, source.width);
    final bottom = padded.bottom.ceil().clamp(y + 1, source.height);
    return img.encodePng(
        img.copyCrop(source, x: x, y: y, width: right - x, height: bottom - y),
        level: 1);
  }

  static CameraSceneRead combine(
      CameraSceneRead persian, CameraSceneRead english,
      {required String unreadable}) {
    final count = persian.lines.length;
    if (count == 0 || count != english.lines.length) {
      return CameraSceneRead('', 0, count);
    }
    final lines = <String>[];
    var accepted = 0;
    var score = 0.0;
    for (var i = 0; i < count; i++) {
      final read = _choose(persian.lines[i], english.lines[i]);
      if (read == null) {
        lines.add(unreadable);
      } else {
        var text = read.$1;
        if (_persian.hasMatch(text)) {
          // A recognizer may confidently turn unfamiliar writing into Latin
          // characters. Keep mixed-script words that both engines support.
          final englishText = english.lines[i]?.$1.toLowerCase() ?? '';
          final words = _latin.allMatches(englishText).map((m) => m[0]).toSet();
          text = text.replaceAllMapped(
              _latin,
              (match) => words.contains(match[0]!.toLowerCase())
                  ? match[0]!
                  : unreadable);
        }
        lines.add(text);
        score += read.$2;
        accepted++;
      }
    }
    return CameraSceneRead(accepted == 0 ? '' : lines.join('\n'),
        accepted == 0 ? 0 : score / accepted, count);
  }

  static (String, double)? _choose((String, double)? fa, (String, double)? en) {
    final persian =
        fa != null && _persian.allMatches(fa.$1).length >= 2 && fa.$2 >= .85;
    final english = en != null &&
        _letters.allMatches(en.$1).length >= 3 &&
        _latin.hasMatch(en.$1) &&
        (en.$2 >= .88 ||
            (en.$2 >= .82 && _latin.allMatches(en.$1).length >= 3));
    if (persian && english) {
      final faWords =
          _latin.allMatches(fa.$1.toLowerCase()).map((m) => m[0]).toSet();
      final overlap = _latin
          .allMatches(en.$1.toLowerCase())
          .any((word) => faWords.contains(word[0]));
      if (overlap || fa.$2 >= en.$2 + .06) return fa;
      if (en.$2 >= fa.$2 + .08) return en;
      return null;
    }
    if (persian) return fa;
    if (english) return en;
    if (fa != null &&
        en != null &&
        fa.$1 == en.$1 &&
        fa.$2 >= .80 &&
        en.$2 >= .80) {
      return fa;
    }
    return null;
  }
}
