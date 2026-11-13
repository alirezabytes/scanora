/// Restore logical reading order from PaddleOCR's visual-order Arabic CTC
/// labels. Matches PaddleOCR BaseRecLabelDecode.pred_reverse; Latin words and
/// ASCII number runs keep their internal order.
class PaddleArabicText {
  static String logicalOrder(String visualText) {
    // Numbers and equations are already in reading order, even when the model
    // belongs to the Arabic family. Reversing them moves "=?" to the front.
    if (!RegExp(r'[\u0621-\u063A\u0641-\u064A\u0671-\u06D3]')
        .hasMatch(visualText)) {
      return visualText;
    }
    final segments = <String>[];
    final latin = StringBuffer();
    final contiguous =
        RegExp(r'[a-zA-Z0-9\u0660-\u0669\u06F0-\u06F9 @_:*./%+\-]');
    void flush() {
      if (latin.isNotEmpty) {
        final raw = latin.toString();
        final core = raw.trim();
        if (core.isEmpty) {
          segments.add(raw);
        } else {
          final leading = raw.length - raw.trimLeft().length;
          final trailing = raw.trimRight().length;
          if (leading > 0) segments.add(raw.substring(0, leading));
          segments.add(core);
          if (trailing < raw.length) segments.add(raw.substring(trailing));
        }
        latin.clear();
      }
    }

    for (final rune in visualText.runes) {
      final character = String.fromCharCode(rune);
      if (contiguous.hasMatch(character)) {
        latin.write(character);
      } else {
        flush();
        segments.add(character);
      }
    }
    flush();
    return segments.reversed.join();
  }
}
