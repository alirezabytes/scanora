import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import '../../models/ai_provider.dart';
import '../../models/captcha_result.dart';
import '../ai/ai_service.dart';
import '../native_bridge_service.dart';
import 'math_evaluator.dart';
import 'onnx_captcha_engine.dart';

/// Local text CAPTCHA recognition using ddddocr and PP-OCRv5, with stroke
/// cleanup and measured-confidence Tesseract fallback when the original is
/// uncertain. Model confidence is a score, not a guarantee of correctness.
class CaptchaSolverService {
  CaptchaSolverService._();

  static const String offlineEngineName =
      'ddddocr + PP-OCRv5 + Tesseract (offline)';

  static Future<CaptchaResult> solve({
    required Uint8List imageBytes,
    required bool isOfflineMode,
    required AIProviderType activeProvider,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
    bool isPersian = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (isOfflineMode) {
      return solveOffline(imageBytes, stopwatch: stopwatch);
    }
    return _solveOnline(
      imageBytes: imageBytes,
      activeProvider: activeProvider,
      apiKey: apiKey,
      modelName: modelName,
      customBaseUrl: customBaseUrl,
      thinkingEffort: thinkingEffort,
      isPersian: isPersian,
      stopwatch: stopwatch,
    );
  }

  /// Runs entirely on-device. Prefer the original image before cleanup, which
  /// can erase Persian dots or alter a numeral. Never boosts confidence merely
  /// because a guessed string looks like arithmetic.
  static Future<CaptchaResult> solveOffline(
    Uint8List imageBytes, {
    Stopwatch? stopwatch,
  }) async {
    final watch = stopwatch ?? (Stopwatch()..start());
    if (!watch.isRunning) watch.start();

    // Prefer a readable original over aggressive cleanup, which may erase
    // dots or change a digit. Cleanup and Tesseract are fallback stages.
    final results = await Future.wait<_CaptchaCandidate>([
      _runEnglishDdddocrCandidate(imageBytes, stateLabel: 'Raw'),
      _runPersianCaptchaCandidate(imageBytes, stateLabel: 'Raw'),
    ]);
    _CaptchaCandidate bestOf(
            List<_CaptchaCandidate> candidates) =>
        candidates.fold(
            const _CaptchaCandidate(
                text: '', confidence: 0, modelLabel: 'Offline OCR'),
            (best, candidate) => candidate.text.isNotEmpty &&
                    candidate.confidence > best.confidence
                ? candidate
                : best);
    var best = bestOf(results);
    final arithmeticHint =
        results.any((c) => RegExp(r'[+×÷=]').hasMatch(c.text));
    if (arithmeticHint && _arithmeticExpressionOf(best.text) == null) {
      final alternatives = await Future.wait<_CaptchaCandidate>([
        _runTesseractCandidate(imageBytes, language: 'fas'),
        _runTesseractCandidate(imageBytes, language: 'eng'),
      ]);
      final valid = alternatives
          .where((c) =>
              c.confidence >= 0.4 && _arithmeticExpressionOf(c.text) != null)
          .toList();
      if (valid.isNotEmpty) best = bestOf(valid);
      results.addAll(alternatives);
    }
    if (best.confidence < 0.65) {
      final cleanedBytes = await Isolate.run(
          () => _generateMorphologicalStrokeCleanedImage(imageBytes));
      results.addAll(await Future.wait<_CaptchaCandidate>([
        _runEnglishDdddocrCandidate(cleanedBytes, stateLabel: 'Stroke-Cleaned'),
        _runPersianCaptchaCandidate(cleanedBytes, stateLabel: 'Stroke-Cleaned'),
      ]));
      best = bestOf(results);
      if (best.confidence < 0.65) {
        results.addAll(await Future.wait<_CaptchaCandidate>([
          _runTesseractCandidate(imageBytes, language: 'eng'),
          _runTesseractCandidate(imageBytes, language: 'fas'),
        ]));
        best = bestOf(results);
      }
    }

    watch.stop();

    final normalized = MathEvaluator.normalizeDigits(best.text);
    final expression = _arithmeticExpressionOf(normalized);
    final answer =
        expression == null ? null : MathEvaluator.evaluateEquation(expression);

    return CaptchaResult(
      text: normalized,
      isMath: answer != null,
      mathEquation: answer != null ? expression : null,
      calculatedAnswer: answer,
      confidence: best.confidence,
      elapsedMilliseconds: watch.elapsedMilliseconds,
      isOffline: true,
      providerName: offlineEngineName,
      modelName: best.modelLabel,
    );
  }

  static Future<_CaptchaCandidate> _runEnglishDdddocrCandidate(
    Uint8List bytes, {
    required String stateLabel,
  }) async {
    try {
      final r = await OnnxCaptchaEngine.recognize(bytes);
      final cleaned = r.text.trim();
      if (cleaned.isEmpty) {
        return _CaptchaCandidate(
          text: '',
          confidence: 0.0,
          modelLabel: 'ddddocr.onnx ($stateLabel)',
        );
      }
      return _CaptchaCandidate(
        text: cleaned,
        confidence: r.confidence,
        modelLabel: 'ddddocr.onnx ($stateLabel)',
      );
    } catch (_) {
      return _CaptchaCandidate(
        text: '',
        confidence: 0.0,
        modelLabel: 'ddddocr.onnx ($stateLabel)',
      );
    }
  }

  static Future<_CaptchaCandidate> _runPersianCaptchaCandidate(
    Uint8List bytes, {
    required String stateLabel,
  }) async {
    try {
      final recognized = await OnnxCaptchaEngine.recognizePersianOnnx(bytes);
      final contextual = MathEvaluator.recoverPersianMath(recognized.text);
      final text = contextual ?? _cleanPersianCaptchaString(recognized.text);
      return _CaptchaCandidate(
          text: text,
          confidence: recognized.confidence,
          modelLabel:
              'PP-OCRv5 Arabic/Persian/English ($stateLabel${contextual == null ? '' : ', arithmetic context'})');
    } catch (_) {}

    return _CaptchaCandidate(
      text: '',
      confidence: 0.0,
      modelLabel: 'PP-OCRv5 ($stateLabel)',
    );
  }

  static String _cleanPersianCaptchaString(String raw) {
    final singleLine = raw
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'[^\u0600-\u06FFA-Za-z0-9\+\-\*\/×÷=؟\?\s]'), '')
        .trim();
    if (singleLine.isEmpty) return '';
    final normalized = MathEvaluator.normalizeDigits(singleLine);
    final expression = _arithmeticExpressionOf(normalized);
    if (expression != null) {
      return expression.replaceAll(' ', '');
    }
    return singleLine.replaceAll(RegExp(r'\s+'), '');
  }

  static Future<_CaptchaCandidate> _runTesseractCandidate(Uint8List bytes,
      {required String language}) async {
    try {
      final result = await NativeBridgeService.recognizeCaptchaTesseract(bytes,
          language: language);
      return _CaptchaCandidate(
          text: _cleanPersianCaptchaString(result.text),
          confidence: result.confidence,
          modelLabel: 'Tesseract 5 ($language, measured confidence)');
    } catch (_) {
      return _CaptchaCandidate(
          text: '', confidence: 0, modelLabel: 'Tesseract 5 ($language)');
    }
  }

  /// Morphological Stroke-Cleaned preprocessing in Isolate:
  /// Removes 1-pixel thin noise lines while preserving thicker character strokes.
  static Uint8List _generateMorphologicalStrokeCleanedImage(
      Uint8List sourceBytes) {
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null || decoded.width < 8 || decoded.height < 8) {
      return sourceBytes;
    }

    final w = decoded.width;
    final h = decoded.height;
    final out = img.Image(width: w, height: h, numChannels: 3);
    img.fill(out, color: img.ColorRgb8(255, 255, 255));

    // Compute luminance map
    final lum = Uint8List(w * h);
    int sumLum = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = decoded.getPixel(x, y);
        final a = p.a / 255.0;
        final r = (p.r * a + 255.0 * (1.0 - a)).round();
        final g = (p.g * a + 255.0 * (1.0 - a)).round();
        final b = (p.b * a + 255.0 * (1.0 - a)).round();
        final l = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
        lum[y * w + x] = l;
        sumLum += l;
      }
    }

    final meanLum = sumLum / (w * h);
    final threshold = (meanLum * 0.82).round().clamp(60, 200);

    // Morphological stroke cleaning: a dark pixel is kept only if it has sufficient
    // connected stroke thickness in its 3x3 neighborhood (eliminates 1-pixel thin lines).
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final center = lum[y * w + x];
        if (center > threshold) continue;

        final top = lum[(y - 1) * w + x] <= threshold;
        final bot = lum[(y + 1) * w + x] <= threshold;
        final left = lum[y * w + (x - 1)] <= threshold;
        final right = lum[y * w + (x + 1)] <= threshold;

        int darkNeighbors = 0;
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            if (lum[(y + dy) * w + (x + dx)] <= threshold) {
              darkNeighbors++;
            }
          }
        }

        // 1-pixel horizontal line has left+right but neither top nor bot;
        // 1-pixel vertical line has top+bot but neither left nor right.
        final isThinHorizontalLine = !top && !bot && darkNeighbors <= 2;
        final isThinVerticalLine = !left && !right && darkNeighbors <= 2;
        if (isThinHorizontalLine || isThinVerticalLine || darkNeighbors <= 1) {
          continue; // Erase 1-px noise stroke to white background
        }

        final darkened = math.max(0, (center * 0.65).round());
        out.setPixelRgb(x, y, darkened, darkened, darkened);
      }
    }

    return Uint8List.fromList(img.encodePng(out, level: 1));
  }

  /// Extracts "a op b" from the raw network output, or null if the text is not an
  /// arithmetic captcha.
  static String? _arithmeticExpressionOf(String raw) {
    var t = MathEvaluator.normalizeEquation(raw).trim();
    if (t.isEmpty) return null;
    final hasEquals = t.contains('=');
    final eq = t.indexOf('=');
    if (eq >= 0) t = t.substring(0, eq);
    while (t.isNotEmpty && '-?:؟'.contains(t[t.length - 1])) {
      t = t.substring(0, t.length - 1);
    }
    final hasSymbolOperator = t.contains('+') ||
        t.contains('*') ||
        t.contains('/') ||
        t.contains('×') ||
        t.contains('÷') ||
        (t.contains('-') && t.indexOf('-') > 0);
    if (!hasSymbolOperator && !hasEquals) return null;
    return MathEvaluator.isMathEquation(t) ? t : null;
  }

  static Future<CaptchaResult> _solveOnline({
    required Uint8List imageBytes,
    required AIProviderType activeProvider,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    required ThinkingEffort thinkingEffort,
    required bool isPersian,
    required Stopwatch stopwatch,
  }) async {
    final config = AIProviderConfig.getByType(activeProvider);

    const prompt = '''
You are a precise captcha reader for blind and visually impaired users.
Read the captcha image (English or Persian).
1. If it is an arithmetic expression, return the expression (e.g. 12+5) or calculate it.
2. If it contains digits or letters, return exactly those characters without spaces.
3. Preserve Latin case. Output ONLY the exact code or expression, with no explanation, quotes or markdown. If unreadable, output [NO_TEXT].
''';

    final response = await AIService.callVisionModel(
      providerType: activeProvider,
      apiKey: apiKey,
      modelName: modelName,
      customBaseUrl: customBaseUrl,
      imageBytes: imageBytes,
      prompt: prompt,
      thinkingEffort: thinkingEffort,
      isPersian: isPersian,
    );
    stopwatch.stop();

    final cleaned = response
        .replaceAll('```', '')
        .replaceAll('"', '')
        .replaceAll("'", '')
        .trim();
    final normalized = MathEvaluator.normalizeDigits(cleaned);
    final isMath = MathEvaluator.isMathEquation(normalized);
    if (normalized.isEmpty ||
        normalized == '[NO_TEXT]' ||
        normalized.length > 64 ||
        !isMath && RegExp(r'[\s\[\]<>]').hasMatch(normalized)) {
      throw const FormatException(
          'The online provider did not return a readable captcha code.');
    }
    final answer = isMath ? MathEvaluator.evaluateEquation(normalized) : null;

    return CaptchaResult(
      text: normalized,
      isMath: isMath,
      mathEquation: isMath ? normalized : null,
      calculatedAnswer: answer,
      elapsedMilliseconds: stopwatch.elapsedMilliseconds,
      isOffline: false,
      providerName: config.displayName,
      modelName: modelName,
    );
  }
}

class _CaptchaCandidate {
  final String text;
  final double confidence;
  final String modelLabel;

  const _CaptchaCandidate({
    required this.text,
    required this.confidence,
    required this.modelLabel,
  });
}
