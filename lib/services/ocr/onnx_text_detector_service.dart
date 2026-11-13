import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'paddle_arabic_text.dart';
import 'camera_scene_ocr.dart';
import 'camera_diagnostics.dart';
import 'automatic_handwriting.dart';

/// Represents a detected text line or text block bounding box in normalized `[0..1]`
/// and pixel coordinates, along with detection confidence and estimated skew angle.
class DetectedTextBox {
  final int x;
  final int y;
  final int width;
  final int height;
  final double confidence;
  final double skewDegrees;

  const DetectedTextBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.confidence,
    this.skewDegrees = 0.0,
  });
}

/// Result of Step 1 (`RapidOCR PP-OCRv4 DBNet` text detection & `Geometric Auto-Deskew`).
class TextDetectionAndDeskewResult {
  /// Deskewed and contrast-normalized full document image (PNG bytes) ready for
  /// `Tesseract 5 (tessdata_best - "fas+eng")` and `PP-OCRv4 Rec (.onnx)`.
  final Uint8List deskewedPngBytes;

  /// Detected text line / block bounding boxes sorted in reading order (top-to-bottom).
  final List<DetectedTextBox> boxes;

  /// Estimated geometric skew angle (in degrees) that was corrected.
  final double correctedSkewDegrees;

  /// Normalized bounding margins `[left, top, right, bottom]` of all detected text
  /// in `[0..1]` relative to the frame (used for Audio Edge Guidance in Book Scan).
  final double leftMarginRatio;
  final double topMarginRatio;
  final double rightMarginRatio;
  final double bottomMarginRatio;

  /// Sharpness / focus score of the frame (`0.0 .. 1.0`).
  final double sharpnessScore;

  /// Whether meaningful text regions were detected in the frame.
  bool get hasText => boxes.isNotEmpty && textCoverageRatio >= 0.008;

  /// Fraction of the image area covered by detected text boxes.
  final double textCoverageRatio;

  /// Independent text-shape evidence from DBNet, when the model ran.
  final bool? hasNeuralTextEvidence;

  const TextDetectionAndDeskewResult({
    required this.deskewedPngBytes,
    required this.boxes,
    required this.correctedSkewDegrees,
    required this.leftMarginRatio,
    required this.topMarginRatio,
    required this.rightMarginRatio,
    required this.bottomMarginRatio,
    required this.sharpnessScore,
    required this.textCoverageRatio,
    this.hasNeuralTextEvidence,
  });
}

/// On-Device `RapidOCR (PP-OCRv4 DBNet .onnx)` Text Region Detector, Geometric Auto-Deskew,
/// and `PP-OCRv4 Arabic/Persian Rec (.onnx)` Recognition Engine under `flutter_onnxruntime`.
class OnnxTextDetectorService {
  OnnxTextDetectorService._();

  static const String _dbnetAsset = 'assets/models/ch_PP-OCRv4_det_infer.onnx';
  static const String _recFaAsset =
      'assets/models/arabic_PP-OCRv5_mobile_rec.onnx';
  static const String _recFaDictAsset = 'assets/models/arabic_v5_dict.txt';
  static const String _recEnAsset = 'assets/models/en_PP-OCRv5_mobile_rec.onnx';
  static const String _recEnDictAsset = 'assets/models/en_v5_dict.txt';
  static const String _binaAsset = 'assets/models/bina_0_2_rizehpizeh.onnx';
  static const String _binaDictAsset =
      'assets/models/bina_0_2_persian_dict.txt';

  static OrtSession? _dbnetSession;
  static OrtSession? _recFaSession;
  static List<String> _recFaCharset = const [];
  static bool _checkedModels = false;
  static Future<void>? _initFuture;
  static final _handwritingModels =
      <String, Future<({OrtSession session, List<String> charset})>>{};

  static Future<CameraSceneRead> recognizeHandwriting(Uint8List imageBytes,
      {required bool persian,
      bool singleLine = false,
      double? minimumLineConfidence}) async {
    if (!singleLine) await ensureInitialized();
    final asset = persian ? _binaAsset : _recEnAsset;
    final model = await _handwritingModels.putIfAbsent(asset, () {
      return _loadHandwritingModel(
              asset, persian ? _binaDictAsset : _recEnDictAsset)
          .onError<Object>((error, stack) {
        _handwritingModels.remove(asset);
        Error.throwWithStackTrace(error, stack);
      });
    });
    if (singleLine) {
      return CameraSceneOcr.recognizeLine(
          imageBytes: imageBytes,
          recognizer: model.session,
          charset: model.charset,
          fixedLineWidth: persian ? 768 : null,
          minimumLineConfidence:
              minimumLineConfidence ?? (persian ? .70 : null));
    }
    final detector = _dbnetSession;
    if (detector == null) {
      throw StateError('Text line detector is unavailable.');
    }
    return CameraSceneOcr.recognize(
      detector: detector,
      recognizer: model.session,
      charset: model.charset,
      imageBytes: imageBytes,
      fixedLineWidth: persian ? 768 : null,
      minimumLineConfidence: minimumLineConfidence ?? (persian ? .70 : null),
    );
  }

  static Future<CameraSceneRead> recognizeMixedHandwriting(Uint8List imageBytes,
      {required String unreadable, bool singleLine = false}) async {
    Object? failure;
    Future<CameraSceneRead?> read(bool persian) async {
      try {
        return await recognizeHandwriting(imageBytes,
            persian: persian, singleLine: singleLine);
      } catch (error) {
        failure = error;
        CameraDiagnostics.event('handwriting.model.error', {
          'language': persian ? 'fa' : 'en',
          'type': error.runtimeType.toString(),
        });
        return null;
      }
    }

    final persian = await read(true);
    final english = await read(false);
    if (persian == null && english == null) throw failure!;
    final count =
        math.max(persian?.detectedLines ?? 0, english?.detectedLines ?? 0);
    final empty = CameraSceneRead('', 0, count,
        lines: List<(String, double)?>.filled(count, null));
    return AutomaticHandwriting.combine(persian ?? empty, english ?? empty,
        unreadable: unreadable);
  }

  static Future<({OrtSession session, List<String> charset})>
      _loadHandwritingModel(String asset, String dictionaryAsset) async {
    final dictionary = await rootBundle.loadString(dictionaryAsset);
    final options = OrtSessionOptions(intraOpNumThreads: 2);
    final session =
        await OnnxRuntime().createSessionFromAsset(asset, options: options);
    return (
      session: session,
      charset: [
        '',
        ...dictionary
            .split(RegExp(r'\r?\n'))
            .where((value) => value.isNotEmpty),
        ' '
      ],
    );
  }

  static Future<List<Rect>> locateTextLines(Uint8List imageBytes) async {
    await ensureInitialized();
    final detector = _dbnetSession;
    if (detector == null) return const [];
    return CameraSceneOcr.locateLines(detector, imageBytes);
  }

  static bool get cameraModelsReady =>
      _dbnetSession != null &&
      _recFaSession != null &&
      _recFaCharset.isNotEmpty;

  /// The camera path uses neural line detection and rectification directly;
  /// scene texture must never be merged into the neural probability mask.
  static Future<CameraSceneRead?> recognizeCameraScene({
    Uint8List? imageBytes,
    Uint8List? pixels,
    int width = 0,
    int height = 0,
    bool live = false,
    bool checkClipping = false,
    void Function(CameraSceneRead)? onPartial,
  }) async {
    await ensureInitialized();
    if (_dbnetSession == null ||
        _recFaSession == null ||
        _recFaCharset.isEmpty) {
      return null;
    }
    final timer = Stopwatch()..start();
    try {
      final read = await CameraSceneOcr.recognize(
          detector: _dbnetSession!,
          recognizer: _recFaSession!,
          charset: _recFaCharset,
          imageBytes: imageBytes,
          pixels: pixels,
          width: width,
          height: height,
          live: live,
          checkClipping: checkClipping,
          onPartial: (partial) {
            CameraDiagnostics.event('neural.partial', {
              'ms': timer.elapsedMilliseconds,
              'characters': partial.text.length,
            });
            onPartial?.call(partial);
          });
      CameraDiagnostics.event('neural.ocr', {
        'text': read.text,
        'confidence': read.confidence,
        'lines': read.detectedLines,
        'ms': timer.elapsedMilliseconds,
        'live': live,
      });
      return read;
    } catch (error, stack) {
      CameraDiagnostics.event('neural.error', {
        'type': error.runtimeType.toString(),
        'details': error.toString(),
        'stack': stack.toString().split('\n').take(8).join('\n'),
      });
      return null;
    }
  }

  /// Initializes ONNX Runtime sessions for bundled `RapidOCR PP-OCRv4 DBNet (.onnx)`
  /// and `PP-OCRv4 Arabic/Persian Rec (.onnx)` models.
  static Future<void> ensureInitialized() {
    final pending = _initFuture;
    if (pending != null) return pending;
    if (_checkedModels) return Future<void>.value();
    return _initFuture = _ensureInitializedInternal().whenComplete(() {
      _checkedModels = true;
      _initFuture = null;
    });
  }

  static Future<void> _ensureInitializedInternal() async {
    final ort = OnnxRuntime();
    final opts = OrtSessionOptions(intraOpNumThreads: 2);

    try {
      final dictStr = await rootBundle.loadString(_recFaDictAsset);
      _recFaCharset = [
        '',
        ...dictStr.split(RegExp(r'\r?\n')).where((s) => s.isNotEmpty),
        ' ',
      ];
    } catch (_) {}

    Directory dir;
    try {
      dir = await getApplicationSupportDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }

    try {
      final data = await rootBundle.load(_dbnetAsset);
      final detFile = File(
          '${dir.path}${Platform.pathSeparator}ch_PP-OCRv4_det_infer.onnx');
      if (!detFile.existsSync() || detFile.lengthSync() != data.lengthInBytes) {
        await detFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      if (detFile.existsSync() && detFile.lengthSync() == data.lengthInBytes) {
        _dbnetSession = await ort.createSession(detFile.path, options: opts);
      }
    } catch (error) {
      CameraDiagnostics.event(
          'neural.detector.init.error', {'details': error.toString()});
    }

    try {
      final data = await rootBundle.load(_recFaAsset);
      final recFile = File(
          '${dir.path}${Platform.pathSeparator}arabic_PP-OCRv5_mobile_rec.onnx');
      if (!recFile.existsSync() || recFile.lengthSync() != data.lengthInBytes) {
        await recFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      if (recFile.existsSync() && recFile.lengthSync() == data.lengthInBytes) {
        _recFaSession = await ort.createSession(recFile.path, options: opts);
      }
    } catch (error) {
      CameraDiagnostics.event(
          'neural.recognizer.init.error', {'details': error.toString()});
    }
  }

  /// Runs Step 1 (`RapidOCR PP-OCRv4 DBNet` text region detection + `Geometric Auto-Deskew`)
  /// inside a background Isolate so the UI thread never drops a frame.
  static Future<TextDetectionAndDeskewResult> detectAndDeskew(
    Uint8List imageBytes, {
    bool fastLiveMode = false,
    int? maxImageDimension,
  }) async {
    // Live guidance must not wait for loading two neural networks it never uses.
    if (!fastLiveMode) await ensureInitialized();
    Float32List? dbnetProbMap;
    int probW = 0;
    int probH = 0;

    if (_dbnetSession != null && !fastLiveMode) {
      try {
        final tensorInput =
            await Isolate.run(() => _prepareDbnetInput(imageBytes));
        if (tensorInput != null) {
          final ortVal = await OrtValue.fromList(
            tensorInput.$1,
            [1, 3, tensorInput.$3, tensorInput.$2],
          );
          try {
            final inName = _dbnetSession!.inputNames.first;
            final outMap = await _dbnetSession!.run({inName: ortVal});
            final outVal = outMap.values.first;
            try {
              final flat = await outVal.asFlattenedList();
              dbnetProbMap = Float32List.fromList(
                flat.map((e) => (e as num).toDouble()).toList(),
              );
              probW = tensorInput.$2;
              probH = tensorInput.$3;
            } finally {
              await outVal.dispose();
            }
          } finally {
            await ortVal.dispose();
          }
        }
      } catch (_) {}
    }

    return Isolate.run(
      () => _detectAndDeskewIsolate(
        imageBytes,
        fastLiveMode: fastLiveMode,
        maxImageDimension: maxImageDimension,
        dbnetProbMap: dbnetProbMap,
        probW: probW,
        probH: probH,
      ),
    );
  }

  /// `PP-OCRv4 Arabic/Persian Rec (.onnx)` line recognizer when ONNX rec session is active.
  static Future<String?> recognizePersianLineOnnx(Uint8List cropBytes) async {
    await ensureInitialized();
    if (_recFaSession == null || _recFaCharset.isEmpty) return null;
    try {
      final prep = await Isolate.run(() => _prepareRecInput(cropBytes));
      if (prep == null) return null;
      final ortVal = await OrtValue.fromList(prep.$1, [1, 3, 48, prep.$2]);
      try {
        final inName = _recFaSession!.inputNames.first;
        final outputs = await _recFaSession!.run({inName: ortVal});
        final outVal = outputs.values.first;
        try {
          final shape = outVal.shape;
          if (shape.length < 2) return null;
          final flat = await outVal.asFlattenedList();
          final classes = shape.last;
          final steps = flat.length ~/ classes;
          final buffer = StringBuffer();
          int lastIdx = 0;
          double confSum = 0.0;
          int confCount = 0;

          for (int t = 0; t < steps; t++) {
            final base = t * classes;
            double maxVal = -double.infinity;
            int bestIdx = 0;
            for (int c = 0; c < classes; c++) {
              final v = (flat[base + c] as num).toDouble();
              if (v > maxVal) {
                maxVal = v;
                bestIdx = c;
              }
            }
            if (bestIdx != 0 &&
                bestIdx != lastIdx &&
                bestIdx < _recFaCharset.length) {
              buffer.write(_recFaCharset[bestIdx]);
              confSum += maxVal.clamp(0.0, 1.0);
              confCount++;
            }
            lastIdx = bestIdx;
          }
          if (confCount == 0 || (confSum / confCount) < 0.55) return null;
          final recognized = PaddleArabicText.logicalOrder(buffer.toString())
              .trim()
              .replaceAll('\u064A', '\u06CC')
              .replaceAll('\u0649', '\u06CC')
              .replaceAll('\u0643', '\u06A9');
          return recognized.isEmpty ? null : recognized;
        } finally {
          await outVal.dispose();
        }
      } finally {
        await ortVal.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// Alias used by `OfflineOcrEngine` to invoke PP-OCRv4 Arabic/Persian recognition when available.
  static Future<String?> recognizeArabicLineIfAvailable(
    Uint8List cropBytes,
  ) =>
      recognizePersianLineOnnx(cropBytes);

  static (Float32List, int, int)? _prepareDbnetInput(Uint8List bytes) {
    final raw = img.decodeImage(bytes);
    final decoded = raw == null ? null : img.bakeOrientation(raw);
    if (decoded == null) return null;
    final targetW = ((decoded.width.clamp(320, 960) + 31) ~/ 32) * 32;
    final targetH = ((decoded.height.clamp(320, 960) + 31) ~/ 32) * 32;
    final resized = img.copyResize(decoded, width: targetW, height: targetH);
    final planeSize = targetW * targetH;
    final input = Float32List(3 * planeSize);
    for (int y = 0; y < targetH; y++) {
      for (int x = 0; x < targetW; x++) {
        final p = resized.getPixel(x, y);
        final idx = y * targetW + x;
        input[idx] = (p.r / 255.0 - 0.485) / 0.229;
        input[planeSize + idx] = (p.g / 255.0 - 0.456) / 0.224;
        input[2 * planeSize + idx] = (p.b / 255.0 - 0.406) / 0.225;
      }
    }
    return (input, targetW, targetH);
  }

  static (Float32List, int)? _prepareRecInput(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    const h = 48;
    final w = math.max(
        32,
        math.min(
            2048, (decoded.width * h / math.max(1, decoded.height)).round()));
    final resized = img.copyResize(decoded, width: w, height: h);
    final plane = w * h;
    final tensor = Float32List(3 * plane);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = resized.getPixel(x, y);
        final idx = y * w + x;
        tensor[idx] = (p.b / 127.5) - 1.0;
        tensor[plane + idx] = (p.g / 127.5) - 1.0;
        tensor[2 * plane + idx] = (p.r / 127.5) - 1.0;
      }
    }
    return (tensor, w);
  }

  static TextDetectionAndDeskewResult _detectAndDeskewIsolate(
    Uint8List rawBytes, {
    required bool fastLiveMode,
    int? maxImageDimension,
    Float32List? dbnetProbMap,
    int probW = 0,
    int probH = 0,
  }) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      return TextDetectionAndDeskewResult(
        deskewedPngBytes: rawBytes,
        boxes: const [],
        correctedSkewDegrees: 0.0,
        leftMarginRatio: 0.5,
        topMarginRatio: 0.5,
        rightMarginRatio: 0.5,
        bottomMarginRatio: 0.5,
        sharpnessScore: 0.0,
        textCoverageRatio: 0.0,
      );
    }

    var working = img.bakeOrientation(decoded);
    // White writing on a dark display needs the same readable foreground used
    // for paper. Keep the original bytes for the independent fallback pass.
    var dark = 0, bright = 0, samples = 0;
    final step = math.max(1, math.min(working.width, working.height) ~/ 100);
    for (var y = 0; y < working.height; y += step) {
      for (var x = 0; x < working.width; x += step) {
        final p = working.getPixel(x, y);
        final light = (p.r * 299 + p.g * 587 + p.b * 114) / 1000;
        if (light < 70) dark++;
        if (light > 165) bright++;
        samples++;
      }
    }
    final inverted =
        samples > 0 && dark / samples > 0.65 && bright / samples > 0.015;
    if (inverted) {
      working = img.invert(working);
    }

    working.backgroundColor = img.ColorRgb8(255, 255, 255);
    final maxDim = maxImageDimension ?? (fastLiveMode ? 1600 : 3600);
    if (working.width > maxDim || working.height > maxDim) {
      working = working.width >= working.height
          ? img.copyResize(
              working,
              width: maxDim,
              interpolation: img.Interpolation.cubic,
            )
          : img.copyResize(
              working,
              height: maxDim,
              interpolation: img.Interpolation.cubic,
            );
    } else if (!fastLiveMode && working.width < 900 && working.height < 900) {
      working = img.copyResize(
        working,
        width: working.width * 2,
        interpolation: img.Interpolation.cubic,
      );
    }

    // Analysis grid for DBNet probability map & morphological text-line detection
    const int analysisMax = 420;
    final double scale = math.min(
      1.0,
      analysisMax / math.max(working.width, working.height),
    );
    final int aw = math.max(32, (working.width * scale).round());
    final int ah = math.max(32, (working.height * scale).round());
    final small = img.copyResize(
      working,
      width: aw,
      height: ah,
      interpolation: img.Interpolation.average,
    );

    final luma = Uint8List(aw * ah);
    for (int y = 0; y < ah; y++) {
      for (int x = 0; x < aw; x++) {
        final p = small.getPixel(x, y);
        luma[y * aw + x] =
            ((p.r * 299 + p.g * 587 + p.b * 114) ~/ 1000).clamp(0, 255);
      }
    }

    // Compute horizontal & vertical stroke gradient density (DBNet text-region map)
    final grad = Uint8List(aw * ah);
    double gradSum = 0;
    int gradCount = 0;
    for (int y = 1; y < ah - 1; y++) {
      final row = y * aw;
      for (int x = 1; x < aw - 1; x++) {
        final idx = row + x;
        final gx = (luma[idx + 1] - luma[idx - 1]).abs();
        final gy = (luma[idx + aw] - luma[idx - aw]).abs();
        int g = (gx + (gy >> 1)).clamp(0, 255);
        if (dbnetProbMap != null && probW > 0 && probH > 0) {
          final px = (x * probW ~/ aw).clamp(0, probW - 1);
          final py = (y * probH ~/ ah).clamp(0, probH - 1);
          final pVal =
              (dbnetProbMap[py * probW + px] * 255.0).round().clamp(0, 255);
          g = math.max(g, pVal);
        }
        grad[idx] = g;
        gradSum += g;
        gradCount++;
      }
    }

    final meanGrad = gradCount > 0 ? gradSum / gradCount : 0.0;
    final sharpnessScore = (meanGrad / 28.0).clamp(0.0, 1.0);
    final threshold = math.max(24, (meanGrad * 1.85).round());

    // Morphological horizontal dilation to connect characters into text lines
    final dilated = Uint8List(aw * ah);
    const int radiusX = 4;
    for (int y = 2; y < ah - 2; y++) {
      final row = y * aw;
      for (int x = radiusX; x < aw - radiusX; x++) {
        int active = 0;
        for (int dx = -radiusX; dx <= radiusX; dx++) {
          if (grad[row + x + dx] >= threshold) {
            active++;
          }
        }
        if (active >= 3) {
          dilated[row + x] = 1;
        }
      }
    }

    // Estimate Geometric Auto-Deskew angle in range [-10° .. +10°]
    final double skewDegrees = _estimateDeskewAngle(dilated, aw, ah);

    // Apply Geometric Auto-Deskew only when skew angle is genuinely significant (>= 1.5 degrees)
    if (skewDegrees.abs() >= 1.5 && skewDegrees.abs() <= 12.0) {
      working = img.copyRotate(
        working,
        angle: -skewDegrees,
        interpolation: img.Interpolation.cubic,
      );
    }

    // Extract horizontal text line strips / bounding boxes in reading order
    final boxes = <DetectedTextBox>[];
    final invScaleX = working.width / aw;
    final invScaleY = working.height / ah;

    int inBandStartY = -1;
    int bandMinX = aw;
    int bandMaxX = 0;
    int bandActivePixels = 0;

    for (int y = 2; y < ah - 2; y++) {
      final row = y * aw;
      int rowCount = 0;
      int rowFirstX = aw;
      int rowLastX = 0;
      for (int x = 2; x < aw - 2; x++) {
        if (dilated[row + x] != 0) {
          rowCount++;
          if (x < rowFirstX) rowFirstX = x;
          if (x > rowLastX) rowLastX = x;
        }
      }

      final isTextRow = rowCount >= math.max(6, aw ~/ 28);
      if (isTextRow) {
        if (inBandStartY < 0) {
          inBandStartY = y;
          bandMinX = rowFirstX;
          bandMaxX = rowLastX;
          bandActivePixels = rowCount;
        } else {
          if (rowFirstX < bandMinX) bandMinX = rowFirstX;
          if (rowLastX > bandMaxX) bandMaxX = rowLastX;
          bandActivePixels += rowCount;
        }
      } else if (inBandStartY >= 0) {
        final bandH = y - inBandStartY;
        final bandW = bandMaxX - bandMinX + 1;
        if (bandH >= 3 && bandW >= math.max(14, aw ~/ 14)) {
          final bx = (bandMinX * invScaleX).round().clamp(0, working.width - 1);
          final by =
              (inBandStartY * invScaleY).round().clamp(0, working.height - 1);
          final bw = (bandW * invScaleX).round().clamp(1, working.width - bx);
          final bh = (bandH * invScaleY).round().clamp(1, working.height - by);
          final conf =
              (bandActivePixels / math.max(1, bandW * bandH)).clamp(0.35, 0.99);
          boxes.add(
            DetectedTextBox(
              x: bx,
              y: by,
              width: bw,
              height: bh,
              confidence: conf,
              skewDegrees: skewDegrees,
            ),
          );
        }
        inBandStartY = -1;
      }
    }

    if (inBandStartY >= 0) {
      final bandH = (ah - 2) - inBandStartY;
      final bandW = bandMaxX - bandMinX + 1;
      if (bandH >= 3 && bandW >= math.max(14, aw ~/ 14)) {
        final bx = (bandMinX * invScaleX).round().clamp(0, working.width - 1);
        final by =
            (inBandStartY * invScaleY).round().clamp(0, working.height - 1);
        final bw = (bandW * invScaleX).round().clamp(1, working.width - bx);
        final bh = (bandH * invScaleY).round().clamp(1, working.height - by);
        final conf =
            (bandActivePixels / math.max(1, bandW * bandH)).clamp(0.35, 0.99);
        boxes.add(
          DetectedTextBox(
            x: bx,
            y: by,
            width: bw,
            height: bh,
            confidence: conf,
            skewDegrees: skewDegrees,
          ),
        );
      }
    }

    // Compute overall page/text margins and coverage ratio
    double minXRatio = 0.5;
    double minYRatio = 0.5;
    double maxXRatio = 0.5;
    double maxYRatio = 0.5;
    double areaSum = 0.0;
    final totalArea = (working.width * working.height).toDouble();

    if (boxes.isNotEmpty && totalArea > 0) {
      int minX = working.width;
      int minY = working.height;
      int maxX = 0;
      int maxY = 0;
      for (final b in boxes) {
        if (b.x < minX) minX = b.x;
        if (b.y < minY) minY = b.y;
        if (b.x + b.width > maxX) maxX = b.x + b.width;
        if (b.y + b.height > maxY) maxY = b.y + b.height;
        areaSum += b.width * b.height;
      }
      minXRatio = (minX / working.width).clamp(0.0, 1.0);
      minYRatio = (minY / working.height).clamp(0.0, 1.0);
      maxXRatio = (maxX / working.width).clamp(0.0, 1.0);
      maxYRatio = (maxY / working.height).clamp(0.0, 1.0);
    }

    // Preserve crisp original image fidelity for Leptonica/Tesseract 5 adaptive thresholding
    final bool wasModified = inverted ||
        (skewDegrees.abs() >= 1.5 && skewDegrees.abs() <= 12.0) ||
        decoded.exif.imageIfd.orientation != 1 &&
            decoded.exif.imageIfd.orientation != null ||
        working.width != decoded.width ||
        working.height != decoded.height;
    final Uint8List outPng = wasModified
        ? Uint8List.fromList(img.encodePng(working, level: 3))
        : rawBytes;

    return TextDetectionAndDeskewResult(
      deskewedPngBytes: outPng,
      boxes: boxes,
      correctedSkewDegrees: skewDegrees,
      leftMarginRatio: minXRatio,
      topMarginRatio: minYRatio,
      rightMarginRatio: (1.0 - maxXRatio).clamp(0.0, 1.0),
      bottomMarginRatio: (1.0 - maxYRatio).clamp(0.0, 1.0),
      sharpnessScore: sharpnessScore,
      textCoverageRatio:
          totalArea > 0 ? (areaSum / totalArea).clamp(0.0, 1.0) : 0.0,
      hasNeuralTextEvidence: dbnetProbMap == null
          ? null
          : _hasTextActivation(dbnetProbMap, probW, probH),
    );
  }

  static bool _hasTextActivation(Float32List map, int width, int height) {
    if (width < 2 || height < 2 || map.length != width * height) return false;
    var blocks = 0;
    for (var y = 0; y < height - 1; y++) {
      for (var x = 0; x < width - 1; x++) {
        final index = y * width + x;
        if (map[index] >= .60 &&
            map[index + 1] >= .60 &&
            map[index + width] >= .60 &&
            map[index + width + 1] >= .60 &&
            ++blocks >= 6) {
          return true;
        }
      }
    }
    return false;
  }

  static double _estimateDeskewAngle(Uint8List binary, int w, int h) {
    final activePoints = <(int, int)>[];
    for (int y = 4; y < h - 4; y += 2) {
      final row = y * w;
      for (int x = 4; x < w - 4; x += 2) {
        if (binary[row + x] != 0) {
          activePoints.add((x, y));
        }
      }
    }
    if (activePoints.length < 60) return 0.0;

    final double cx = w / 2.0;
    final double cy = h / 2.0;
    double bestVariance = -1.0;
    double zeroVariance = 0.0;
    double bestAngle = 0.0;

    for (double deg = -10.0; deg <= 10.0; deg += 0.5) {
      final rad = deg * math.pi / 180.0;
      final sinA = math.sin(rad);
      final cosA = math.cos(rad);
      final hist = Int32List(h);
      for (final pt in activePoints) {
        final ry = ((pt.$1 - cx) * sinA + (pt.$2 - cy) * cosA + cy).round();
        if (ry >= 0 && ry < h) {
          hist[ry]++;
        }
      }
      double variance = 0.0;
      for (int i = 1; i < h; i++) {
        final diff = (hist[i] - hist[i - 1]).toDouble();
        variance += diff * diff;
      }
      if (deg.abs() < 0.01) {
        zeroVariance = variance;
      }
      if (variance > bestVariance) {
        bestVariance = variance;
        bestAngle = deg;
      }
    }
    if (zeroVariance > 0 && bestVariance < zeroVariance * 1.35) {
      return 0.0;
    }
    return bestAngle;
  }
}
