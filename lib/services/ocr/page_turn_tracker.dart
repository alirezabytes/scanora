import 'dart:typed_data';

/// Detect a settled change from the captured page, even when the turn happened
/// between camera samples. OCR checks the text again before saving the new page.
class PageTurnTracker {
  /// Ignore minor OCR jitter when comparing the same captured page.
  static bool sameText(String first, String second,
      {double minimumSimilarity = .96}) {
    String normalize(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final a = normalize(first), b = normalize(second);
    if (a == b) return true;
    final digits = RegExp(r'[0-9۰-۹٠-٩]+');
    if (digits.allMatches(a).map((m) => m[0]).join('|') !=
        digits.allMatches(b).map((m) => m[0]).join('|')) {
      return false;
    }
    if (a.length < 40 || b.length < 40) return false;
    Set<String> trigrams(String text) =>
        {for (var i = 0; i < text.length - 2; i++) text.substring(i, i + 3)};
    final left = trigrams(a), right = trigrams(b);
    return 2 * left.intersection(right).length / (left.length + right.length) >=
        minimumSimilarity;
  }

  static double imageDifference(Uint8List a, Uint8List b) {
    if (a.length != b.length || a.isEmpty) return 1;
    var exposure = 0.0, difference = 0.0;
    for (var i = 0; i < a.length; i++) {
      exposure += a[i] - b[i];
    }
    exposure /= a.length;
    for (var i = 0; i < a.length; i++) {
      difference += ((a[i] - b[i]) - exposure).abs() / 255;
    }
    return difference / a.length;
  }

  Uint8List? _reference;
  int _changedStableFrames = 0;

  void captured(Uint8List thumbnail) {
    _reference = Uint8List.fromList(thumbnail);
    _changedStableFrames = 0;
  }

  bool observe(Uint8List thumbnail, {required double motion}) {
    final reference = _reference;
    if (reference == null ||
        reference.length != thumbnail.length ||
        thumbnail.isEmpty) {
      return false;
    }
    if (motion > 0.06) {
      _changedStableFrames = 0;
      return false;
    }
    // Subtract the average exposure shift: automatic exposure is not a page turn.
    var exposure = 0.0;
    for (var i = 0; i < thumbnail.length; i++) {
      exposure += thumbnail[i] - reference[i];
    }
    exposure /= thumbnail.length;
    var difference = 0.0;
    for (var i = 0; i < thumbnail.length; i++) {
      difference += ((thumbnail[i] - reference[i]) - exposure).abs() / 255;
    }
    difference /= thumbnail.length;
    _changedStableFrames = difference >= 0.012 ? _changedStableFrames + 1 : 0;
    return _changedStableFrames >= 2;
  }
}
