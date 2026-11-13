class MathEvaluator {
  static const Map<String, String> _persianToAscii = {
    '۰': '0',
    '۱': '1',
    '۲': '2',
    '۳': '3',
    '۴': '4',
    '۵': '5',
    '۶': '6',
    '۷': '7',
    '۸': '8',
    '۹': '9',
    '٠': '0',
    '١': '1',
    '٢': '2',
    '٣': '3',
    '٤': '4',
    '٥': '5',
    '٦': '6',
    '٧': '7',
    '٨': '8',
    '٩': '9',
  };

  static const Map<String, String> _asciiToPersian = {
    '0': '۰',
    '1': '۱',
    '2': '۲',
    '3': '۳',
    '4': '۴',
    '5': '۵',
    '6': '۶',
    '7': '۷',
    '8': '۸',
    '9': '۹',
  };

  /// Normalizes Persian and Arabic numerals to ASCII digits (0-9).
  static String normalizeDigits(String input) {
    String result = input;
    _persianToAscii.forEach((fa, en) {
      result = result.replaceAll(fa, en);
    });
    return result;
  }

  /// Converts ASCII digits to Persian digits.
  static String toPersianDigits(String input) {
    String result = input;
    _asciiToPersian.forEach((en, fa) {
      result = result.replaceAll(en, fa);
    });
    return result;
  }

  static String normalizeEquation(String text) {
    return normalizeDigits(text.trim())
        .replaceAll('×', '*')
        .replaceAll('∗', '*')
        .replaceAll('·', '*')
        .replaceAll('÷', '/')
        .replaceAll('−', '-')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('﹣', '-')
        .replaceAll('＋', '+')
        .replaceAll('ضربدر', '*')
        .replaceAll('ضرب در', '*')
        .replaceAll('در', '*')
        .replaceAll('بعلاوه', '+')
        .replaceAll('به علاوه', '+')
        .replaceAll('به‌علاوه', '+')
        .replaceAll('جمع', '+')
        .replaceAll('منهای', '-')
        .replaceAll('منها', '-')
        .replaceAll('تقسیم بر', '/')
        .replaceAll('مساوی', '=')
        .replaceAllMapped(RegExp(r'\bplus\b', caseSensitive: false), (_) => '+')
        .replaceAllMapped(
            RegExp(r'\bminus\b', caseSensitive: false), (_) => '-')
        .replaceAllMapped(
            RegExp(r'\btimes\b', caseSensitive: false), (_) => '*')
        .replaceAllMapped(
            RegExp(r'\bdivided by\b', caseSensitive: false), (_) => '/')
        .replaceAll('؟', '?')
        .replaceAll('？', '?')
        .trim();
  }

  /// Persian ۷ and Latin V, and Persian ۱ and a vertical stroke can be visually
  /// identical. Resolve them only in an explicit arithmetic question containing
  /// actual Persian/Arabic numerals; ordinary alphanumeric codes stay untouched.
  static String? recoverPersianMath(String raw) {
    if (!RegExp(r'[\u0660-\u0669\u06F0-\u06F9]').hasMatch(raw) ||
        !raw.contains('=') ||
        !RegExp(r'[+\-×÷*/]').hasMatch(raw)) {
      return null;
    }
    final candidate = normalizeEquation(raw)
        .replaceAll(RegExp(r'[|Il]'), '1')
        .replaceAll(RegExp(r'[Vv]'), '7');
    return isMathEquation(candidate) ? candidate : null;
  }

  /// Strictly checks if the entire string is a single arithmetic captcha equation
  /// e.g. "15 + 4 = ?", "۲۴ - ۸ = ؟", "3 * 7" (does NOT match dates like 2026-10-24 or multi-line text)
  static bool isMathEquation(String text) {
    if (text.contains('\n')) return false;
    final normalized = normalizeEquation(text);
    if (normalized.length > 28) return false;
    final strictMathRegex = RegExp(
      r'^\s*(\d{1,4})\s*([\+\-\*\/xX])\s*(\d{1,4})\s*([=＝:：]\s*[\?]*)?\s*$',
    );
    return strictMathRegex.hasMatch(normalized);
  }

  /// Solves the arithmetic expression and returns the calculated number as a string.
  static String? evaluateEquation(String text) {
    try {
      if (!isMathEquation(text)) return null;
      final normalized = normalizeEquation(text);

      final strictMathRegex = RegExp(
        r'^\s*(\d{1,4})\s*([\+\-\*\/xX])\s*(\d{1,4})\s*([=＝:：]\s*[\?]*)?\s*$',
      );
      final match = strictMathRegex.firstMatch(normalized);
      if (match == null) return null;

      final num1 = int.parse(match.group(1)!);
      final rawOp = match.group(2)!;
      final op = (rawOp == 'x' || rawOp == 'X') ? '*' : rawOp;
      final num2 = int.parse(match.group(3)!);

      int result = 0;
      switch (op) {
        case '+':
          result = num1 + num2;
          break;
        case '-':
          result = num1 - num2;
          break;
        case '*':
          result = num1 * num2;
          break;
        case '/':
          if (num2 != 0) {
            if (num1 % num2 == 0) return (num1 ~/ num2).toString();
            var denominator = num2 ~/ num1.gcd(num2);
            while (denominator % 2 == 0) {
              denominator ~/= 2;
            }
            while (denominator % 5 == 0) {
              denominator ~/= 5;
            }
            if (denominator == 1) return (num1 / num2).toString();
            final gcd = num1.gcd(num2);
            return '${num1 ~/ gcd}/${num2 ~/ gcd}';
          } else {
            return null;
          }
        default:
          return null;
      }

      return result.toString();
    } catch (_) {
      return null;
    }
  }
}
