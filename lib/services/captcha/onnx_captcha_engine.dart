import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../ocr/paddle_arabic_text.dart';

/// Output of [OnnxCaptchaEngine.recognize] and [OnnxCaptchaEngine.recognizePersianOnnx].
class CaptchaRecognition {
  final String text;
  final double confidence;
  const CaptchaRecognition(this.text, this.confidence);
}

/// Bundled ddddocr and PP-OCRv5 Arabic/Persian/English CTC recognizers.
/// The latter uses the publisher's 747-character vocabulary, BGR inputs and
/// script-aware reading-order restoration. Scores are model estimates.
class OnnxCaptchaEngine {
  OnnxCaptchaEngine._();

  static const String _modelAsset = 'assets/models/ddddocr_common_old.onnx';
  static const String _charsetAsset =
      'assets/models/ddddocr_common_old_charset.json';
  static const String _persianRecAsset =
      'assets/models/arabic_PP-OCRv5_mobile_rec.onnx';
  static const String _persianCharsetAsset = 'assets/models/arabic_v5_dict.txt';
  static const String _allowedSymbols = '0123456789+-*/=?';

  static OrtSession? _session;
  static Future<void>? _loading;
  static List<String> _charset = const [];
  static Int32List _allowedIndices = Int32List(0);

  static OrtSession? _persianSession;
  static Future<void>? _persianLoading;
  static bool _persianProbeDone = false;
  static List<String> _persianCharset = const [];

  static Future<void> _ensureLoaded() {
    if (_session != null) return Future<void>.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  static Future<void> _load() async {
    try {
      final raw = await rootBundle.loadString(_charsetAsset);
      _charset =
          (jsonDecode(raw) as List<dynamic>).map((e) => e.toString()).toList();

      final allowed = <int>[];
      for (int i = 1; i < _charset.length; i++) {
        final c = _charset[i];
        if (c.length != 1) continue;
        final u = c.codeUnitAt(0);
        final isAlnum = (u >= 0x30 && u <= 0x39) ||
            (u >= 0x41 && u <= 0x5A) ||
            (u >= 0x61 && u <= 0x7A);
        if (isAlnum || _allowedSymbols.contains(c)) allowed.add(i);
      }
      _allowedIndices = Int32List.fromList(allowed);
    } catch (_) {}

    try {
      Directory dir;
      try {
        dir = await getApplicationSupportDirectory();
      } catch (_) {
        dir = Directory.systemTemp;
      }
      final modelFile =
          File('${dir.path}${Platform.pathSeparator}ddddocr_common_old.onnx');
      final data = await rootBundle.load(_modelAsset);
      if (!modelFile.existsSync() ||
          modelFile.lengthSync() != data.lengthInBytes) {
        await modelFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      _session = await OnnxRuntime().createSession(modelFile.path);
    } catch (_) {
      try {
        _session = await OnnxRuntime().createSessionFromAsset(_modelAsset);
      } catch (_) {
        _session = null;
      }
    }
  }

  static Future<void> _ensurePersianLoaded() {
    if (_persianProbeDone && _persianSession != null) {
      return Future<void>.value();
    }
    return _persianLoading ??= _loadPersianInternal().whenComplete(
      () => _persianLoading = null,
    );
  }

  static Future<void> _loadPersianInternal() async {
    _persianProbeDone = true;
    try {
      final dictStr = await rootBundle.loadString(_persianCharsetAsset);
      _persianCharset = [
        '',
        ...dictStr.split(RegExp(r'\r?\n')).where((s) => s.isNotEmpty),
        ' '
      ];
    } catch (_) {
      _persianCharset = const [];
    }
    if (_persianCharset.isEmpty) return;
    try {
      Directory dir;
      try {
        dir = await getApplicationSupportDirectory();
      } catch (_) {
        dir = Directory.systemTemp;
      }
      final recFile = File(
          '${dir.path}${Platform.pathSeparator}arabic_PP-OCRv5_mobile_rec.onnx');
      final data = await rootBundle.load(_persianRecAsset);
      if (!recFile.existsSync() || recFile.lengthSync() != data.lengthInBytes) {
        await recFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      _persianSession = await OnnxRuntime().createSession(recFile.path);
    } catch (_) {
      try {
        _persianSession =
            await OnnxRuntime().createSessionFromAsset(_persianRecAsset);
      } catch (_) {
        _persianSession = null;
      }
    }
  }

  /// Recognises the characters of [imageBytes] with `ddddocr.onnx` and computes the
  /// exact Softmax Mean Confidence Score.
  static Future<CaptchaRecognition> recognize(Uint8List imageBytes) async {
    await _ensureLoaded();
    final session = _session;
    if (session == null) return const CaptchaRecognition('', 0);

    final prepared = await Isolate.run(() => _preprocess(imageBytes));
    if (prepared == null) return const CaptchaRecognition('', 0);

    final input =
        await OrtValue.fromList(prepared.data, [1, 1, 64, prepared.width]);
    final inputName = session.inputNames.first;
    Map<String, OrtValue> outputs = const {};
    try {
      outputs = await session.run({inputName: input});
      final out = outputs.values.first;
      final shape = out.shape; // [sequence, 1, classes]
      final flat = await out.asFlattenedList();
      return _decode(flat, shape);
    } catch (_) {
      return const CaptchaRecognition('', 0);
    } finally {
      await input.dispose();
      for (final o in outputs.values) {
        await o.dispose();
      }
    }
  }

  /// Recognises Persian captcha characters with `PP-OCRv4 Arabic/Persian Rec (.onnx)`
  /// when bundled, returning its Softmax Mean Confidence Score.
  static Future<CaptchaRecognition> recognizePersianOnnx(
      Uint8List imageBytes) async {
    await _ensurePersianLoaded();
    final session = _persianSession;
    if (session == null) return const CaptchaRecognition('', 0.0);

    final prepared = await Isolate.run(() => _preprocessPersianRec(imageBytes));
    if (prepared == null) return const CaptchaRecognition('', 0.0);

    final input =
        await OrtValue.fromList(prepared.data, [1, 3, 48, prepared.width]);
    final inputName = session.inputNames.first;
    Map<String, OrtValue> outputs = const {};
    try {
      outputs = await session.run({inputName: input});
      final out = outputs.values.first;
      final shape = out.shape;
      final flat = await out.asFlattenedList();
      return _decodePersianCtc(flat, shape);
    } catch (_) {
      return const CaptchaRecognition('', 0.0);
    } finally {
      await input.dispose();
      for (final o in outputs.values) {
        await o.dispose();
      }
    }
  }

  static CaptchaRecognition _decode(List<dynamic> flat, List<int> shape) {
    final classes = shape.last;
    final steps = flat.length ~/ classes;
    final buffer = StringBuffer();
    var last = 0;
    var confSum = 0.0;
    var confCount = 0;

    for (int t = 0; t < steps; t++) {
      final base = t * classes;
      var maxLogit = -double.infinity;
      for (int c = 0; c < classes; c++) {
        final v = (flat[base + c] as num).toDouble();
        if (v > maxLogit) maxLogit = v;
      }
      var sum = 0.0;
      for (int c = 0; c < classes; c++) {
        sum += math.exp((flat[base + c] as num).toDouble() - maxLogit);
      }

      var bestIdx = 0;
      var bestVal = (flat[base] as num).toDouble();
      for (final idx in _allowedIndices) {
        final v = (flat[base + idx] as num).toDouble();
        if (v > bestVal) {
          bestVal = v;
          bestIdx = idx;
        }
      }

      if (bestIdx != 0 && bestIdx != last) {
        buffer.write(_charset[bestIdx]);
        confSum += math.exp(bestVal - maxLogit) / sum;
        confCount++;
      }
      last = bestIdx;
    }

    final text = buffer.toString();
    final confidence =
        confCount == 0 ? 0.0 : (confSum / confCount).clamp(0.0, 1.0);
    return CaptchaRecognition(text, confidence);
  }

  static CaptchaRecognition _decodePersianCtc(
      List<dynamic> flat, List<int> shape) {
    if (shape.length < 2 || shape.last != _persianCharset.length) {
      return const CaptchaRecognition('', 0.0);
    }
    final classes = shape.last;
    final steps = flat.length ~/ classes;
    final buffer = StringBuffer();
    var last = 0;
    var confSum = 0.0;
    var confCount = 0;

    for (int t = 0; t < steps; t++) {
      final base = t * classes;
      var maxLogit = -double.infinity;
      var bestIdx = 0;
      for (int c = 0; c < classes; c++) {
        final v = (flat[base + c] as num).toDouble();
        if (v > maxLogit) {
          maxLogit = v;
          bestIdx = c;
        }
      }
      var sum = 0.0;
      var rowRawSum = 0.0;
      for (int c = 0; c < classes; c++) {
        final v = (flat[base + c] as num).toDouble();
        rowRawSum += v;
        sum += math.exp(v - maxLogit);
      }
      final isAlreadySoftmax =
          (rowRawSum - 1.0).abs() < 0.05 && maxLogit <= 1.0 && maxLogit >= 0.0;
      final prob = isAlreadySoftmax
          ? maxLogit.clamp(0.0, 1.0)
          : (sum > 0 ? (1.0 / sum) : maxLogit.clamp(0.0, 1.0));

      if (bestIdx != 0 && bestIdx != last && bestIdx < _persianCharset.length) {
        buffer.write(_persianCharset[bestIdx]);
        confSum += prob;
        confCount++;
      }
      last = bestIdx;
    }

    final text = PaddleArabicText.logicalOrder(buffer.toString()).trim();
    final confidence =
        confCount == 0 ? 0.0 : (confSum / confCount).clamp(0.0, 1.0);
    return CaptchaRecognition(text, confidence);
  }

  static _PreparedInput? _preprocess(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width == 0 || decoded.height == 0) {
      return null;
    }

    final flattened =
        img.Image(width: decoded.width, height: decoded.height, numChannels: 3);
    img.fill(flattened, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flattened, decoded);

    final width = math.max(16, (decoded.width * 64 / decoded.height).round());
    final resized = img.copyResize(
      flattened,
      width: width,
      height: 64,
      interpolation: img.Interpolation.cubic,
    );

    final data = Float32List(64 * width);
    var i = 0;
    for (int y = 0; y < 64; y++) {
      for (int x = 0; x < width; x++) {
        final p = resized.getPixel(x, y);
        final gray = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        data[i++] = ((gray / 255.0) - 0.5) / 0.5;
      }
    }
    return _PreparedInput(data, width);
  }

  static _PreparedInput? _preprocessPersianRec(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width == 0 || decoded.height == 0) {
      return null;
    }

    // Remove large empty margins before resizing. Keeping them shrinks the
    // actual glyphs below the resolution used to train the line recognizer.
    final flattened =
        img.Image(width: decoded.width, height: decoded.height, numChannels: 3);
    img.fill(flattened, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flattened, decoded);
    var left = flattened.width, top = flattened.height, right = -1, bottom = -1;
    for (var y = 0; y < flattened.height; y++) {
      for (var x = 0; x < flattened.width; x++) {
        final p = flattened.getPixel(x, y);
        if (0.299 * p.r + 0.587 * p.g + 0.114 * p.b < 200) {
          left = math.min(left, x);
          right = math.max(right, x);
          top = math.min(top, y);
          bottom = math.max(bottom, y);
        }
      }
    }
    if (right < left || bottom < top) return null;
    final cropped = img.copyCrop(flattened,
        x: left, y: top, width: right - left + 1, height: bottom - top + 1);
    const targetH = 48;
    final targetW = math.max(
        32, math.min(2048, (cropped.width * targetH / cropped.height).round()));
    final resized = img.copyResize(cropped,
        width: targetW,
        height: targetH,
        interpolation: img.Interpolation.cubic);

    final plane = targetH * targetW;
    final data = Float32List(3 * plane);
    for (int y = 0; y < targetH; y++) {
      for (int x = 0; x < targetW; x++) {
        final p = resized.getPixel(x, y);
        final idx = y * targetW + x;
        data[idx] = ((p.b / 255.0) - 0.5) / 0.5;
        data[plane + idx] = ((p.g / 255.0) - 0.5) / 0.5;
        data[2 * plane + idx] = ((p.r / 255.0) - 0.5) / 0.5;
      }
    }
    return _PreparedInput(data, targetW);
  }

  @visibleForTesting
  static List<String> get charset => _charset;
}

class _PreparedInput {
  final Float32List data;
  final int width;
  const _PreparedInput(this.data, this.width);
}
