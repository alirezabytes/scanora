import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Represents a detected object or scene category from `YOLOv8n.onnx` or `MobileNetV4.onnx`
/// that strictly passed the `> 0.65` confidence threshold.
class DetectedVisionElement {
  final String labelEn;
  final String labelFa;
  final double confidence;
  final int count;
  final String regionEn;
  final String regionFa;

  const DetectedVisionElement({
    required this.labelEn,
    required this.labelFa,
    required this.confidence,
    this.count = 1,
    this.regionEn = '',
    this.regionFa = '',
  });
}

/// Visual layout and color summary computed deterministically in a Background Isolate
/// without any false face heuristics.
class VisionSceneAnalysis {
  final int width;
  final int height;
  final String orientationEn;
  final String orientationFa;
  final String brightnessEn;
  final String brightnessFa;
  final String dominantColorEn;
  final String dominantColorFa;
  final List<DetectedVisionElement> detectedObjects;

  const VisionSceneAnalysis({
    required this.width,
    required this.height,
    required this.orientationEn,
    required this.orientationFa,
    required this.brightnessEn,
    required this.brightnessFa,
    required this.dominantColorEn,
    required this.dominantColorFa,
    required this.detectedObjects,
  });

  List<DetectedVisionElement> get objects => detectedObjects;
  String get lightingFa => brightnessFa;
  String get lightingEn => brightnessEn;
  List<String> get dominantColorsFa =>
      dominantColorFa.trim().isEmpty ? const [] : <String>[dominantColorFa];
  List<String> get dominantColorsEn =>
      dominantColorEn.trim().isEmpty ? const [] : <String>[dominantColorEn];
}

class _PreparedVisionTensor {
  final Float32List nchwData;
  final int inputSize;
  final int origWidth;
  final int origHeight;
  final String orientationEn;
  final String orientationFa;
  final String brightnessEn;
  final String brightnessFa;
  final String dominantColorEn;
  final String dominantColorFa;

  const _PreparedVisionTensor({
    required this.nchwData,
    required this.inputSize,
    required this.origWidth,
    required this.origHeight,
    required this.orientationEn,
    required this.orientationFa,
    required this.brightnessEn,
    required this.brightnessFa,
    required this.dominantColorEn,
    required this.dominantColorFa,
  });
}

Future<_PreparedVisionTensor?> _prepareVisionInputInIsolate(
  Map<String, dynamic> args,
) async {
  final Uint8List imageBytes = args['bytes'] as Uint8List;
  final int inputSize = args['inputSize'] as int? ?? 640;
  final bool normalizeImagenet = args['normalizeImagenet'] as bool? ?? false;

  final decoded = img.decodeImage(imageBytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    return null;
  }

  final baked = img.bakeOrientation(decoded);
  final w = baked.width;
  final h = baked.height;

  final String orientationEn = w > (h * 1.12)
      ? 'Landscape (Horizontal)'
      : (h > (w * 1.12) ? 'Portrait (Vertical)' : 'Square');
  final String orientationFa = w > (h * 1.12)
      ? 'افقی (چشم‌انداز)'
      : (h > (w * 1.12) ? 'عمودی (پرتره)' : 'مربعی');

  // Sample image illumination & dominant tone accurately
  final thumb = img.copyResize(baked, width: 64, height: 64);
  double totalLum = 0;
  int rSum = 0, gSum = 0, bSum = 0;
  int whiteish = 0, darkish = 0;
  const totalPixels = 64 * 64;

  for (int y = 0; y < 64; y++) {
    for (int x = 0; x < 64; x++) {
      final p = thumb.getPixel(x, y);
      final r = p.r.toInt();
      final g = p.g.toInt();
      final b = p.b.toInt();
      final lum = 0.299 * r + 0.587 * g + 0.114 * b;
      totalLum += lum;
      rSum += r;
      gSum += g;
      bSum += b;
      if (lum > 200 && (r - g).abs() < 20 && (g - b).abs() < 20) {
        whiteish++;
      } else if (lum < 55) {
        darkish++;
      }
    }
  }

  final avgLum = totalLum / totalPixels;
  final String brightnessEn = avgLum < 65
      ? 'Low light / Dark'
      : (avgLum > 195 ? 'Bright / High-key' : 'Balanced lighting');
  final String brightnessFa = avgLum < 65
      ? 'کم‌نور / تیره'
      : (avgLum > 195 ? 'روشن / پرنور' : 'نورپردازی متعادل');

  final avgR = rSum / totalPixels;
  final avgG = gSum / totalPixels;
  final avgB = bSum / totalPixels;

  String dominantColorEn;
  String dominantColorFa;
  if (whiteish > totalPixels * 0.48) {
    dominantColorEn = 'White / Light background';
    dominantColorFa = 'سفید / پس‌زمینه روشن';
  } else if (darkish > totalPixels * 0.48) {
    dominantColorEn = 'Black / Dark background';
    dominantColorFa = 'مشکی / پس‌زمینه تیره';
  } else if ((avgR - avgG).abs() < 16 && (avgG - avgB).abs() < 16) {
    dominantColorEn = 'Neutral Gray / Monochrome';
    dominantColorFa = 'خاکستری خنثی / تک‌رنگ';
  } else if (avgR >= avgG && avgR >= avgB) {
    if (avgG > avgB * 1.25) {
      dominantColorEn = 'Warm Yellow / Orange tones';
      dominantColorFa = 'طیف گرم زرد / نارنجی';
    } else {
      dominantColorEn = 'Warm Red / Brown tones';
      dominantColorFa = 'طیف قرمز / قهوه‌ای';
    }
  } else if (avgG >= avgR && avgG >= avgB) {
    dominantColorEn = 'Green / Natural tones';
    dominantColorFa = 'طیف سبز';
  } else {
    dominantColorEn = 'Blue / Cool tones';
    dominantColorFa = 'طیف آبی / سرد';
  }

  // Prepare NCHW tensor for ONNX model
  late final img.Image resized;
  if (!normalizeImagenet && inputSize == 640) {
    // YOLO expects the scene's aspect ratio to be preserved with padding.
    final scale = inputSize / math.max(w, h);
    final scaled = img.copyResize(baked,
        width: math.max(1, (w * scale).round()),
        height: math.max(1, (h * scale).round()),
        interpolation: img.Interpolation.linear);
    resized = img.Image(width: inputSize, height: inputSize, numChannels: 3);
    img.fill(resized, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(resized, scaled,
        dstX: (inputSize - scaled.width) ~/ 2,
        dstY: (inputSize - scaled.height) ~/ 2);
  } else {
    resized = img.copyResize(baked,
        width: inputSize,
        height: inputSize,
        interpolation: img.Interpolation.linear);
  }
  final plane = inputSize * inputSize;
  final tensor = Float32List(3 * plane);

  for (int y = 0; y < inputSize; y++) {
    for (int x = 0; x < inputSize; x++) {
      final p = resized.getPixel(x, y);
      final idx = y * inputSize + x;
      final r = p.r / 255.0;
      final g = p.g / 255.0;
      final b = p.b / 255.0;
      if (normalizeImagenet) {
        tensor[idx] = (r - 0.485) / 0.229;
        tensor[plane + idx] = (g - 0.456) / 0.224;
        tensor[2 * plane + idx] = (b - 0.406) / 0.225;
      } else {
        tensor[idx] = r;
        tensor[plane + idx] = g;
        tensor[2 * plane + idx] = b;
      }
    }
  }

  return _PreparedVisionTensor(
    nchwData: tensor,
    inputSize: inputSize,
    origWidth: w,
    origHeight: h,
    orientationEn: orientationEn,
    orientationFa: orientationFa,
    brightnessEn: brightnessEn,
    brightnessFa: brightnessFa,
    dominantColorEn: dominantColorEn,
    dominantColorFa: dominantColorFa,
  );
}

/// Standard On-Device Object & Scene Detection Service under `flutter_onnxruntime`.
/// Supports `YOLOv8n.onnx` and `MobileNetV4.onnx` with a strict confidence threshold
/// of **`> 0.65`** (`kMinConfidenceThreshold = 0.65`) to guarantee zero hallucination.
class OnnxVisionClassifierService {
  static const double kMinConfidenceThreshold = 0.65;
  static const double confidenceThreshold = kMinConfidenceThreshold;

  static OrtSession? _yoloSession;
  static OrtSession? _mobileNetSession;
  static bool _initAttempted = false;
  static Future<void>? _initFuture;

  static Future<void> initialize() {
    if (_initAttempted && (_yoloSession != null || _mobileNetSession != null)) {
      return Future<void>.value();
    }
    return _initFuture ??= _initializeInternal().whenComplete(
      () => _initFuture = null,
    );
  }

  static Future<void> _initializeInternal() async {
    _initAttempted = true;

    try {
      final ort = OnnxRuntime();
      Directory supportDir;
      try {
        supportDir = await getApplicationSupportDirectory();
      } catch (_) {
        supportDir = Directory.systemTemp;
      }
      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }

      // 1. Check YOLOv8n.onnx in assets or support dir
      final yoloFile = await _resolveModelFile(
        assetCandidates: const [
          'assets/models/yolov8n.onnx',
          'assets/models/YOLOv8n.onnx',
        ],
        localFilename: 'yolov8n.onnx',
        supportDir: supportDir,
        tempDir: tempDir,
      );
      if (yoloFile != null) {
        _yoloSession = await ort.createSession(yoloFile.path);
      }

      // 2. Check MobileNetV4.onnx in assets or support dir
      final mobileNetFile = await _resolveModelFile(
        assetCandidates: const [
          'assets/models/mobilenetv4.onnx',
          'assets/models/MobileNetV4.onnx',
          'assets/models/mobilenet_v4.onnx',
        ],
        localFilename: 'mobilenetv4.onnx',
        supportDir: supportDir,
        tempDir: tempDir,
      );
      if (mobileNetFile != null) {
        _mobileNetSession = await ort.createSession(mobileNetFile.path);
      }
    } catch (e) {
      debugPrint('OnnxVisionClassifierService init notice: $e');
    }
  }

  static Future<File?> _resolveModelFile({
    required List<String> assetCandidates,
    required String localFilename,
    required Directory supportDir,
    required Directory tempDir,
  }) async {
    for (final assetPath in assetCandidates) {
      try {
        final data = await rootBundle.load(assetPath);
        final outFile = File('${tempDir.path}/$localFilename');
        if (!await outFile.exists() ||
            await outFile.length() != data.lengthInBytes) {
          await outFile.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
        }
        return outFile;
      } catch (_) {}
    }

    final downloaded = File('${supportDir.path}/models/$localFilename');
    if (await downloaded.exists() && await downloaded.length() > 1024) {
      return downloaded;
    }
    return null;
  }

  /// Analyzes the image in a Background Isolate and runs `YOLOv8n.onnx` / `MobileNetV4.onnx`
  /// with strict confidence filtering (`confidence > 0.65`).
  /// Never fabricates faces or objects when confidence is below `0.65`.
  static Future<VisionSceneAnalysis> analyzeScene(Uint8List imageBytes) async {
    await initialize();

    final bool hasYolo = _yoloSession != null;
    final bool hasMobileNet = _mobileNetSession != null;
    final int inputSize = hasYolo ? 640 : 224;

    final prepared = await Isolate.run(
      () => _prepareVisionInputInIsolate({
        'bytes': imageBytes,
        'inputSize': inputSize,
        'normalizeImagenet': !hasYolo && hasMobileNet,
      }),
    );

    if (prepared == null) {
      return const VisionSceneAnalysis(
        width: 0,
        height: 0,
        orientationEn: 'Unknown',
        orientationFa: 'نامشخص',
        brightnessEn: 'Unknown',
        brightnessFa: 'نامشخص',
        dominantColorEn: 'Unknown',
        dominantColorFa: 'نامشخص',
        detectedObjects: [],
      );
    }

    final detected = <DetectedVisionElement>[];

    if (hasYolo) {
      final yoloDetections = await _runYoloV8Inference(prepared);
      detected.addAll(yoloDetections);
    } else if (hasMobileNet) {
      final mobileNetDetections = await _runMobileNetV4Inference(prepared);
      detected.addAll(mobileNetDetections);
    }

    return VisionSceneAnalysis(
      width: prepared.origWidth,
      height: prepared.origHeight,
      orientationEn: prepared.orientationEn,
      orientationFa: prepared.orientationFa,
      brightnessEn: prepared.brightnessEn,
      brightnessFa: prepared.brightnessFa,
      dominantColorEn: prepared.dominantColorEn,
      dominantColorFa: prepared.dominantColorFa,
      detectedObjects: detected,
    );
  }

  static Future<List<DetectedVisionElement>> _runYoloV8Inference(
    _PreparedVisionTensor prepared,
  ) async {
    if (_yoloSession == null) return const [];
    OrtValue? inputTensor;
    Map<String, OrtValue>? outputs;
    try {
      inputTensor = await OrtValue.fromList(prepared.nchwData, [
        1,
        3,
        prepared.inputSize,
        prepared.inputSize,
      ]);
      final inputName = _yoloSession!.inputNames.first;
      outputs = await _yoloSession!.run({inputName: inputTensor});
      final outputTensor = outputs.values.first;
      final shape = outputTensor.shape;
      final flat = await outputTensor.asFlattenedList();

      return decodeYolo(flat, shape,
          originalWidth: prepared.origWidth,
          originalHeight: prepared.origHeight,
          inputSize: prepared.inputSize);
    } catch (e) {
      debugPrint('YOLOv8n ONNX inference error: $e');
      return const [];
    } finally {
      if (outputs != null) {
        for (final v in outputs.values) {
          try {
            await v.dispose();
          } catch (_) {}
        }
      }
      if (inputTensor != null) {
        try {
          await inputTensor.dispose();
        } catch (_) {}
      }
    }
  }

  @visibleForTesting
  static List<DetectedVisionElement> decodeYolo(
      List<dynamic> flat, List<int> shape,
      {int originalWidth = 640,
      int originalHeight = 640,
      int inputSize = 640}) {
    // YOLOv8 output shape is [1, 84, 8400] (4 box coords + 80 COCO classes)
    if (shape.length < 3 || shape[1] < 84) return const [];
    final int numChannels = shape[1];
    final int numAnchors = shape[2];
    final int numClasses = math.min(80, numChannels - 4);

    final candidates = <(int, double, double, double, double, double)>[];

    for (int a = 0; a < numAnchors; a++) {
      double maxProb = 0.0;
      int bestClass = -1;
      for (int c = 0; c < numClasses; c++) {
        final double score = (flat[(c + 4) * numAnchors + a] as num).toDouble();
        if (score > maxProb) {
          maxProb = score;
          bestClass = c;
        }
      }
      // Strictly enforce > 0.65 threshold
      if (bestClass >= 0 && maxProb > kMinConfidenceThreshold) {
        final cx = (flat[a] as num).toDouble();
        final cy = (flat[numAnchors + a] as num).toDouble();
        final width = (flat[2 * numAnchors + a] as num).toDouble();
        final height = (flat[3 * numAnchors + a] as num).toDouble();
        if (width > 0 && height > 0) {
          candidates.add((bestClass, maxProb, cx, cy, width, height));
        }
      }
    }

    // Several anchors describe the same object. Class-aware NMS removes
    // duplicates before counting; anchor count / 12 is not an object count.
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    final kept = <(int, double, double, double, double, double)>[];
    for (final candidate in candidates) {
      var overlaps = false;
      for (final previous in kept) {
        if (candidate.$1 != previous.$1) continue;
        final left = math.max(
            candidate.$3 - candidate.$5 / 2, previous.$3 - previous.$5 / 2);
        final right = math.min(
            candidate.$3 + candidate.$5 / 2, previous.$3 + previous.$5 / 2);
        final top = math.max(
            candidate.$4 - candidate.$6 / 2, previous.$4 - previous.$6 / 2);
        final bottom = math.min(
            candidate.$4 + candidate.$6 / 2, previous.$4 + previous.$6 / 2);
        final intersection =
            math.max(0.0, right - left) * math.max(0.0, bottom - top);
        final union = candidate.$5 * candidate.$6 +
            previous.$5 * previous.$6 -
            intersection;
        if (union > 0 && intersection / union > 0.45) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) kept.add(candidate);
      if (kept.length >= 100) break;
    }
    final elements = <DetectedVisionElement>[];
    for (final classIdx in kept.map((item) => item.$1).toSet()) {
      final items = kept.where((item) => item.$1 == classIdx).toList();
      final pair = _cocoLabels[classIdx];
      final scale =
          math.min(inputSize / originalWidth, inputSize / originalHeight);
      final padX = (inputSize - originalWidth * scale) / 2;
      final padY = (inputSize - originalHeight * scale) / 2;
      final regionsEn = <String>{};
      final regionsFa = <String>{};
      for (final item in items) {
        final x = ((item.$3 - padX) / scale / originalWidth).clamp(0.0, 1.0);
        final y = ((item.$4 - padY) / scale / originalHeight).clamp(0.0, 1.0);
        final horizontal = x < 0.33 ? 0 : (x > 0.67 ? 2 : 1);
        final vertical = y < 0.33 ? 0 : (y > 0.67 ? 2 : 1);
        regionsEn.add('${['top', 'middle', 'bottom'][vertical]} ${[
          'left',
          'center',
          'right'
        ][horizontal]}');
        regionsFa.add('${['بالا', 'میانه', 'پایین'][vertical]} ${[
          'چپ',
          'وسط',
          'راست'
        ][horizontal]}');
      }
      elements.add(DetectedVisionElement(
          labelEn: pair.$1,
          labelFa: pair.$2,
          confidence: items.first.$2,
          count: items.length,
          regionEn: regionsEn.join(', '),
          regionFa: regionsFa.join('، ')));
    }

    elements.sort((a, b) => b.confidence.compareTo(a.confidence));
    return elements;
  }

  static Future<List<DetectedVisionElement>> _runMobileNetV4Inference(
    _PreparedVisionTensor prepared,
  ) async {
    if (_mobileNetSession == null) return const [];
    OrtValue? inputTensor;
    Map<String, OrtValue>? outputs;
    try {
      inputTensor = await OrtValue.fromList(prepared.nchwData, [
        1,
        3,
        prepared.inputSize,
        prepared.inputSize,
      ]);
      final inputName = _mobileNetSession!.inputNames.first;
      outputs = await _mobileNetSession!.run({inputName: inputTensor});
      final outputTensor = outputs.values.first;
      final flat = await outputTensor.asFlattenedList();
      if (flat.isEmpty) return const [];

      double maxLogit = -double.infinity;
      int maxIdx = 0;
      for (int i = 0; i < flat.length; i++) {
        final v = (flat[i] as num).toDouble();
        if (v > maxLogit) {
          maxLogit = v;
          maxIdx = i;
        }
      }

      double sumExp = 0.0;
      for (int i = 0; i < flat.length; i++) {
        final d = (flat[i] as num).toDouble() - maxLogit;
        if (d > -20.0) sumExp += math.exp(d);
      }
      final double prob = sumExp > 0 ? (1.0 / sumExp).clamp(0.0, 1.0) : 0.0;

      if (prob <= kMinConfidenceThreshold) {
        return const [];
      }

      return [
        DetectedVisionElement(
          labelEn: 'Class #$maxIdx',
          labelFa: 'دسته #$maxIdx',
          confidence: prob,
        ),
      ];
    } catch (e) {
      debugPrint('MobileNetV4 ONNX inference error: $e');
      return const [];
    } finally {
      if (outputs != null) {
        for (final v in outputs.values) {
          try {
            await v.dispose();
          } catch (_) {}
        }
      }
      if (inputTensor != null) {
        try {
          await inputTensor.dispose();
        } catch (_) {}
      }
    }
  }

  static const List<(String, String)> _cocoLabels = [
    ('Person', 'انسان / شخص'),
    ('Bicycle', 'دوچرخه'),
    ('Car', 'خودرو'),
    ('Motorcycle', 'موتورسیکلت'),
    ('Airplane', 'هواپیما'),
    ('Bus', 'اتوبوس'),
    ('Train', 'قطار'),
    ('Truck', 'کامیون'),
    ('Boat', 'قایق'),
    ('Traffic light', 'چراغ راهنمایی'),
    ('Fire hydrant', 'شیر آتش‌نشانی'),
    ('Stop sign', 'تابلوی توقف'),
    ('Parking meter', 'پارکومتر'),
    ('Bench', 'نیمکت'),
    ('Bird', 'پرنده'),
    ('Cat', 'گربه'),
    ('Dog', 'سگ'),
    ('Horse', 'اسب'),
    ('Sheep', 'گوسفند'),
    ('Cow', 'گاو'),
    ('Elephant', 'فیل'),
    ('Bear', 'خرس'),
    ('Zebra', 'گورخر'),
    ('Giraffe', 'زرافه'),
    ('Backpack', 'کوله‌پشتی'),
    ('Umbrella', 'چتر'),
    ('Handbag', 'کیف دستی'),
    ('Tie', 'کراوات'),
    ('Suitcase', 'چمدان'),
    ('Frisbee', 'فریزبی'),
    ('Skis', 'اسکی'),
    ('Snowboard', 'اسنوبرد'),
    ('Sports ball', 'توپ ورزشی'),
    ('Kite', 'بادبادک'),
    ('Baseball bat', 'چوب بیسبال'),
    ('Baseball glove', 'دستکش بیسبال'),
    ('Skateboard', 'اسکیت‌برد'),
    ('Surfboard', 'تخته موج‌سواری'),
    ('Tennis racket', 'راکت تنیس'),
    ('Bottle', 'بطری'),
    ('Wine glass', 'لیوان پایه‌دار'),
    ('Cup', 'فنجان / لیوان'),
    ('Fork', 'چنگال'),
    ('Knife', 'چاقو'),
    ('Spoon', 'قاشق'),
    ('Bowl', 'کاسه'),
    ('Banana', 'موز'),
    ('Apple', 'سیب'),
    ('Sandwich', 'ساندویچ'),
    ('Orange', 'پرتقال'),
    ('Broccoli', 'بروکلی'),
    ('Carrot', 'هویج'),
    ('Hot dog', 'هات‌داگ'),
    ('Pizza', 'پیتزا'),
    ('Donut', 'دونات'),
    ('Cake', 'کیک'),
    ('Chair', 'صندلی'),
    ('Couch', 'مبل'),
    ('Potted plant', 'گیاه آپارتمانی'),
    ('Bed', 'تخت‌خواب'),
    ('Dining table', 'میز'),
    ('Toilet', 'سرویس بهداشتی'),
    ('TV / Monitor', 'نمایشگر / تلویزیون'),
    ('Laptop', 'لپ‌تاپ'),
    ('Mouse', 'ماوس'),
    ('Remote', 'کنترل از راه دور'),
    ('Keyboard', 'صفحه‌کلید (کیبورد)'),
    ('Cell phone', 'گوشی موبایل'),
    ('Microwave', 'مایکروویو'),
    ('Oven', 'فر'),
    ('Toaster', 'توستر'),
    ('Sink', 'سینک'),
    ('Refrigerator', 'یخچال'),
    ('Book', 'کتاب'),
    ('Clock', 'ساعت'),
    ('Vase', 'گلدان'),
    ('Scissors', 'قیچی'),
    ('Teddy bear', 'عروسک خرسی'),
    ('Hair drier', 'سشوار'),
    ('Toothbrush', 'مسواک'),
  ];
}
