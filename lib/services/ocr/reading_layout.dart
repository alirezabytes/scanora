import 'dart:math' as math;
import 'dart:ui';

typedef ReadingLayoutLine = ({Rect bounds, String text, double size});

/// Restores the reading order of columns separated by a vertical gutter.
class ReadingLayout {
  static String format(List<ReadingLayoutLine> lines,
      {required String heading}) {
    if (lines.isEmpty) return '';
    final sizes = lines.map((line) => line.size).toList()..sort();
    final typicalSize = sizes[sizes.length ~/ 2];
    final rtl = _isRtl(lines);
    final result = _order(lines, rtl, 0);
    return result.map((line) {
      final text = line.text.trim();
      final isHeading = lines.length >= 4 &&
          line.size >= typicalSize * 1.45 &&
          text.length <= 120 &&
          !text.endsWith('.');
      return isHeading ? '$heading. $text' : text;
    }).join('\n');
  }

  static List<ReadingLayoutLine> _order(
      List<ReadingLayoutLine> lines, bool rtl, int depth) {
    final ordered = lines.toList()
      ..sort((a, b) {
        final vertical = a.bounds.top.compareTo(b.bounds.top);
        if (vertical != 0) return vertical;
        return rtl
            ? b.bounds.right.compareTo(a.bounds.right)
            : a.bounds.left.compareTo(b.bounds.left);
      });
    if (depth >= 2 || lines.length < 8) return ordered;
    final x1 = lines.map((line) => line.bounds.left).reduce(math.min);
    final x2 = lines.map((line) => line.bounds.right).reduce(math.max);
    if (x2 <= x1) return ordered;
    final margin = (x2 - x1) * .015;
    double? bestGutter;
    num bestScore = 0;
    for (var part = 25; part <= 75; part++) {
      final x = x1 + (x2 - x1) * part / 100;
      final left =
          lines.where((line) => line.bounds.right <= x - margin).toList();
      final right =
          lines.where((line) => line.bounds.left >= x + margin).toList();
      if (left.length < 4 ||
          right.length < 4 ||
          left.length + right.length < lines.length * .8) {
        continue;
      }
      final commonTop = math.max(
        left.map((l) => l.bounds.top).reduce(math.min),
        right.map((l) => l.bounds.top).reduce(math.min),
      );
      final commonBottom = math.min(
        left.map((l) => l.bounds.bottom).reduce(math.max),
        right.map((l) => l.bounds.bottom).reduce(math.max),
      );
      if (commonBottom <= commonTop) continue;
      final score = 2 * (left.length + right.length) +
          math.min(left.length, right.length);
      if (score > bestScore) {
        bestScore = score;
        bestGutter = x;
      }
    }
    if (bestGutter == null) return ordered;
    final gutter = bestGutter;
    final output = <ReadingLayoutLine>[];
    final left = <ReadingLayoutLine>[];
    final right = <ReadingLayoutLine>[];
    void addColumns() {
      output.addAll(_order(rtl ? right : left, rtl, depth + 1));
      output.addAll(_order(rtl ? left : right, rtl, depth + 1));
      left.clear();
      right.clear();
    }

    for (final line in ordered) {
      if (line.bounds.right <= gutter - margin) {
        left.add(line);
      } else if (line.bounds.left >= gutter + margin) {
        right.add(line);
      } else {
        addColumns();
        output.add(line);
      }
    }
    addColumns();
    return output;
  }

  static bool _isRtl(Iterable<ReadingLayoutLine> lines) {
    var rtl = 0, latin = 0;
    for (final line in lines) {
      for (final code in line.text.codeUnits) {
        if (code >= 0x0620 && code <= 0x06ff) {
          rtl++;
        } else if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
          latin++;
        }
      }
    }
    return rtl > latin;
  }
}
