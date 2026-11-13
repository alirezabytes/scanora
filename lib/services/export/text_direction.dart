/// Reading direction follows content, independently of the menu language.
bool textIsRtl(String text, {bool fallback = false}) {
  final first = RegExp(r'[A-Za-z\u0621-\u063A\u0641-\u064A\u0671-\u06D3]')
      .firstMatch(text);
  return first == null
      ? fallback
      : !RegExp(r'[A-Za-z]').hasMatch(first.group(0)!);
}
