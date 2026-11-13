import 'page_turn_tracker.dart';

/// Tracks what was actually spoken in the current view. OCR can finish again
/// while speech is active without restarting the same words.
class LiveTextTracker {
  final List<String> _spoken = [];

  static bool replacesView(String previous, String current) {
    Set<String> words(String text) => RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(
            text.toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک'))
        .map((match) => match[0]!)
        .toSet();
    final a = words(previous), b = words(current);
    if (a.isEmpty || b.isEmpty) return false;
    final smaller = a.length < b.length ? a.length : b.length;
    return a.intersection(b).length / smaller < .45;
  }

  String takeUnread(String text) {
    final unread = <String>[];
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      final normalized = line.toLowerCase();
      if (_spoken.any((spoken) => PageTurnTracker.sameText(spoken, normalized,
          minimumSimilarity: .9))) {
        continue;
      }
      var addition = line;
      for (final spoken in _spoken.reversed) {
        if (spoken.length >= 12 && normalized.startsWith('$spoken ')) {
          addition = line.substring(spoken.length).trim();
          break;
        }
      }
      if (unread.isNotEmpty &&
          unread.join('\n').length + addition.length > 350) {
        break;
      }
      unread.add(addition);
      _spoken.add(normalized);
      if (_spoken.length > 120) _spoken.removeAt(0);
    }
    return unread.join('\n');
  }

  void reset() => _spoken.clear();
}
