import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../native_bridge_service.dart';
import 'camera_diagnostics.dart';
import 'camera_scene_ocr.dart';
import 'onnx_text_detector_service.dart';

/// Local document OCR with geometric deskew, bilingual Tesseract models,
/// orientation detection on full scans, and a neural single-line fallback.
/// Live previews use tessdata_fast; saved documents use tessdata_best.
class OfflineOcrEngine {
  OfflineOcrEngine._();

  /// Combined Persian + English recognition language (permanent `"fas+eng"`).
  static const String language = 'fas+eng';

  /// Automatic layout with orientation detection using the bundled OSD model.
  static const int pageSegmentationMode = 1;

  /// Unicode bidirectional formatting characters that are invisible in print but
  /// confuse screen readers (LRM, RLM, ALM, embeddings, overrides, isolates).
  static const Set<int> _invisibleControlMarks = <int>{
    0x200E,
    0x200F,
    0x061C,
    0x202A,
    0x202B,
    0x202C,
    0x202D,
    0x202E,
    0x2066,
    0x2067,
    0x2068,
    0x2069,
    0xFEFF,
  };

  /// True when an offline engine exists on this platform.
  static bool get isSupported => Platform.isAndroid || Platform.isWindows;

  static Future<TesseractRead> recognizeLivePixels(
      Uint8List pixels, int width, int height,
      {void Function(TesseractRead)? onPartial,
      void Function(CameraTextEdge)? onClippedText}) async {
    if (!Platform.isAndroid) {
      final bytes = await _encodeLuma(pixels, width, height);
      return recognizeLiveImage(bytes);
    }
    final input = await CameraDiagnostics.luma(pixels, width, height);
    final scene = await OnnxTextDetectorService.recognizeCameraScene(
        pixels: pixels,
        width: width,
        height: height,
        live: true,
        onPartial: (partial) {
          CameraDiagnostics.event('live.ocr.partial', {
            'input': input,
            'text': partial.text,
            'confidence': partial.confidence,
          });
          onPartial?.call(TesseractRead(tidy(partial.text), partial.confidence,
              detectedTextRegions: partial.detectedLines));
        });
    if (scene != null) {
      CameraDiagnostics.event('live.ocr.result', {
        'input': input,
        'text': scene.text,
        'confidence': scene.confidence,
        'lines': scene.detectedLines,
        'clippedEdge': scene.clippedEdge?.name,
      });
      final edge = scene.clippedEdge;
      if (edge != null) onClippedText?.call(edge);
      return TesseractRead(tidy(scene.text), scene.confidence,
          detectedTextRegions: scene.detectedLines);
    }
    final timer = Stopwatch()..start();
    final read =
        await NativeBridgeService.recognizeCameraLuma(pixels, width, height);
    _recordCameraRead('preview', input, read, timer.elapsedMilliseconds);
    return isReadableCameraText(read)
        ? TesseractRead(tidy(read.text), read.confidence)
        : const TesseractRead('', 0);
  }

  static Future<Uint8List> _encodeLuma(
          Uint8List pixels, int width, int height) =>
      Isolate.run(() => img.encodePng(
          img.Image.fromBytes(
              width: width,
              height: height,
              bytes: pixels.buffer,
              numChannels: 1),
          level: 1));

  /// One pass with the small bilingual models for the continuous video reader.
  /// Full document layout and quality retries belong to deliberate photo scans.
  static Future<TesseractRead> recognizeLiveImage(Uint8List bytes) async {
    final input = await CameraDiagnostics.image('live_photo', bytes);
    final timer = Stopwatch()..start();
    final read = await NativeBridgeService.recognizeTesseractWithConfidence(
      bytes,
      language: language,
      psm: 11,
      fast: true,
    );
    _recordCameraRead('live_photo', input, read, timer.elapsedMilliseconds);
    return isReadableCameraText(read)
        ? TesseractRead(tidy(read.text), read.confidence)
        : const TesseractRead('', 0);
  }

  /// Live camera text is spoken automatically, so a nonempty guess is not
  /// enough. Use the quality models and retry a different layout when needed.
  static Future<TesseractRead> recognizeCameraText(Uint8List bytes,
      {bool bookPage = false}) async {
    await CameraDiagnostics.image(
        bookPage ? 'book_input' : 'photo_input', bytes);
    if (Platform.isAndroid) {
      final scene = await OnnxTextDetectorService.recognizeCameraScene(
          imageBytes: bytes, checkClipping: bookPage);
      if (scene != null) {
        return TesseractRead(tidy(scene.text), scene.confidence,
            detectedTextRegions: scene.detectedLines,
            clippedEdge: scene.clippedEdge);
      }
    }
    final timer = Stopwatch()..start();
    final detection = await OnnxTextDetectorService.detectAndDeskew(
      bytes,
      fastLiveMode: true,
      maxImageDimension: bookPage ? 3200 : 2400,
    );
    CameraDiagnostics.event('preprocessing', {
      'ms': timer.elapsedMilliseconds,
      'boxes': detection.boxes.length,
      'skew': detection.correctedSkewDegrees,
      'book': bookPage,
    });
    final prepared = detection.deskewedPngBytes;
    Future<TesseractRead> read(int psm,
        {String lang = language,
        bool adaptive = false,
        Uint8List? input}) async {
      final file = await CameraDiagnostics.image('ocr_input', input ?? prepared,
          extension: 'png', metadata: {'psm': psm, 'adaptive': adaptive});
      final timer = Stopwatch()..start();
      final result = await NativeBridgeService.recognizeTesseractWithConfidence(
        input ?? prepared,
        language: lang,
        psm: psm,
        adaptiveThreshold: adaptive,
      );
      _recordCameraRead(
          'photo_psm_$psm', file, result, timer.elapsedMilliseconds);
      return result;
    }

    var best = await read(6);
    final lines = best.text.trim().split('\n').where((line) => line.isNotEmpty);
    if (best.confidence < .83 ||
        (bookPage && lines.length + 1 < detection.boxes.length)) {
      final alternative = await read(bookPage ? 3 : 11, adaptive: true);
      if (_betterCameraReading(alternative, best)) best = alternative;
    }
    if (!isReadableCameraText(best)) {
      final crop = bookPage
          ? null
          : await Isolate.run(() => _cropCameraTextRegion(detection));
      final retry = await read(6, adaptive: true, input: crop);
      if (_betterCameraReading(retry, best)) best = retry;
    }
    final initial = tidy(best.text);
    final persian =
        RegExp(r'[\u0621-\u063A\u0641-\u06D3]').allMatches(initial).length;
    final latin = RegExp(r'[A-Za-z]').allMatches(initial).length;
    // Isolated Latin fragments in Persian text are sometimes lookalike
    // words. Preserve bilingual output when it includes whole English words.
    final tryPersian = persian >= 12 &&
        latin > 0 &&
        persian > latin * 5 &&
        !RegExp(r'[A-Z]{2,}|[A-Za-z]{4,}').hasMatch(initial);
    if (tryPersian) {
      final alternative = await read(6, lang: 'fas');
      if (_betterCameraReading(alternative, best)) best = alternative;
    }
    return isReadableCameraText(best)
        ? TesseractRead(tidy(best.text), best.confidence)
        : const TesseractRead('', 0);
  }

  static void _recordCameraRead(
      String stage, String? input, TesseractRead read, int elapsedMs) {
    CameraDiagnostics.event('ocr', {
      'stage': stage,
      'input': input,
      'text': read.text,
      'confidence': read.confidence,
      'accepted': isReadableCameraText(read),
      'ms': elapsedMs,
    });
  }

  static Uint8List? _cropCameraTextRegion(TextDetectionAndDeskewResult frame) {
    if (frame.boxes.isEmpty || frame.correctedSkewDegrees.abs() >= 1.5) {
      return null;
    }
    final image = img.decodeImage(frame.deskewedPngBytes);
    if (image == null) return null;
    const margin = .035;
    final left = ((frame.leftMarginRatio - margin) * image.width)
        .floor()
        .clamp(0, image.width - 1);
    final top = ((frame.topMarginRatio - margin) * image.height)
        .floor()
        .clamp(0, image.height - 1);
    final right = ((1 - frame.rightMarginRatio + margin) * image.width)
        .ceil()
        .clamp(left + 1, image.width);
    final bottom = ((1 - frame.bottomMarginRatio + margin) * image.height)
        .ceil()
        .clamp(top + 1, image.height);
    final width = right - left, height = bottom - top;
    if (width * height > image.width * image.height * .72) return null;
    final crop =
        img.copyCrop(image, x: left, y: top, width: width, height: height);
    final upscaled = width <= 1000 && height <= 700
        ? img.copyResize(crop,
            width: width * 2, interpolation: img.Interpolation.cubic)
        : crop;
    return img.encodePng(upscaled, level: 3);
  }

  static bool _betterCameraReading(
      TesseractRead candidate, TesseractRead current) {
    if (!isReadableCameraText(candidate)) return false;
    if (!isReadableCameraText(current)) return true;
    final candidateCount = _countMeaningfulLetters(candidate.text);
    final currentCount = _countMeaningfulLetters(current.text);
    return (candidateCount >= currentCount * .8 &&
            candidate.confidence > current.confidence + .01) ||
        (candidateCount >= currentCount * 1.2 &&
            candidate.confidence >= current.confidence - .025);
  }

  /// A scene can contain lettering, but object edges can also resemble
  /// letters. Require both a text region and corroborated whole words.
  static Future<String> recognizeVerifiedSceneText(Uint8List bytes) async {
    final detection = await OnnxTextDetectorService.detectAndDeskew(
      bytes,
      maxImageDimension: 2400,
    );
    if (detection.hasNeuralTextEvidence == false) return '';
    Future<TesseractRead> read(int layout, {bool adaptive = false}) =>
        NativeBridgeService.recognizeTesseractWithConfidence(
          detection.deskewedPngBytes,
          language: language,
          psm: layout,
          adaptiveThreshold: adaptive,
        );
    final sparse = await read(11);
    final block = await read(6, adaptive: true);
    final verified = _corroboratedSceneLines(sparse, block);
    if (verified.isNotEmpty) return verified;
    if (sparse.confidence < .78 && block.confidence < .78) return '';
    final page = await read(3);
    return _corroboratedSceneLines(
        sparse.confidence >= .78 ? sparse : block, page);
  }

  static String _corroboratedSceneLines(
      TesseractRead primary, TesseractRead reference) {
    if (primary.confidence < .78 || reference.confidence < .78) return '';
    final words = RegExp(r'[\p{L}\p{N}]+', unicode: true);
    List<String> tokens(String text) => words
        .allMatches(
            tidy(text).toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک'))
        .map((match) => match[0]!)
        .toList();
    final confirmed = ' ${tokens(reference.text).join(' ')} ';
    return tidy(primary.text)
        .split('\n')
        .where((line) {
          final terms = tokens(line);
          return terms.any((term) => term.runes.length >= 3) &&
              confirmed.contains(' ${terms.join(' ')} ');
        })
        .join('\n')
        .trim();
  }

  @visibleForTesting
  static bool isReadableCameraText(TesseractRead read) {
    final text = tidy(read.text).replaceAll(RegExp(r'\s'), '');
    final count = _countMeaningfulLetters(text);
    if (count == 0 || count * 2 < text.runes.length) return false;
    if (count < 3) return read.confidence >= .85;
    return read.confidence >= (count < 12 ? .66 : .60);
  }

  /// Recognises the text in [imageBytes] (PNG / JPEG / BMP / WebP).
  ///
  /// [fast] selects the small preview models. Full scans use the quality models
  /// and can retry segmentation and orientation without network access.
  static Future<String> recognizeText(
    Uint8List imageBytes, {
    bool fast = false,
    bool skipDeskew = false,
    bool preferResponsive = false,
  }) async {
    if (imageBytes.isEmpty) return '';

    // Try the quality Tesseract models first on a clean page. Reserve the
    // heavier neural layout recovery for pages that need a second pass.
    if (preferResponsive && isSupported && !fast && !skipDeskew) {
      try {
        final prepared = await OnnxTextDetectorService.detectAndDeskew(
          imageBytes,
          fastLiveMode: true,
          maxImageDimension: 3600,
        );
        final read = await NativeBridgeService.recognizeTesseractWithConfidence(
          prepared.deskewedPngBytes,
          language: language,
          psm: pageSegmentationMode,
        );
        final text = tidy(read.text);
        final lines = text.split('\n').where((line) => line.trim().isNotEmpty);
        if (read.confidence >= .84 &&
            _countMeaningfulLetters(text) >= 24 &&
            lines.length >= prepared.boxes.length) {
          return text;
        }
      } catch (_) {
        // The full path below can still recover a page.
      }
    }

    // Step 1: RapidOCR DBNet (.onnx) + Geometric Auto-Deskew in Background Isolate
    Uint8List preparedBytes = imageBytes;
    bool wasPreparedModified = false;
    TextDetectionAndDeskewResult? frameDetection;
    if (!skipDeskew) {
      try {
        final detection = await OnnxTextDetectorService.detectAndDeskew(
          imageBytes,
          fastLiveMode: fast,
        );
        frameDetection = detection;
        if (detection.deskewedPngBytes.isNotEmpty &&
            !identical(detection.deskewedPngBytes, imageBytes)) {
          preparedBytes = detection.deskewedPngBytes;
          wasPreparedModified = true;
        }
      } catch (_) {
        preparedBytes = imageBytes;
      }
    }

    // Step 2: Bilingual recognition via Tesseract 5 (tessdata_best, "fas+eng")
    String raw = await _runTesseractPass(preparedBytes,
        fast: fast, psm: fast ? 3 : pageSegmentationMode);
    var cleaned = tidy(raw);

    // Automatic page segmentation can drop entire Persian lines on sparse
    // documents. Retry as one block when detected line bands outnumber output.
    final outputLines =
        cleaned.split('\n').where((line) => line.trim().isNotEmpty).length;
    if (frameDetection != null && frameDetection.boxes.length > outputLines) {
      final block =
          tidy(await _runTesseractPass(preparedBytes, fast: fast, psm: 6));
      if (_countMeaningfulLetters(block) >
          _countMeaningfulLetters(cleaned) * 1.2) {
        cleaned = block;
      }
    }

    // Tesseract's Persian model can return an empty result for a single line,
    // including a Persian line surrounded by correctly read English lines.
    // Read detected line crops with PP-OCRv5 and preserve matching Tesseract
    // lines instead of replacing the whole bilingual page with one language.
    if (frameDetection != null &&
        frameDetection.boxes.isNotEmpty &&
        (!fast ||
            cleaned.isEmpty ||
            frameDetection.boxes.length > outputLines ||
            frameDetection.boxes.length <= 8)) {
      final crops = await Isolate.run(
          () => _cropReadingLines(preparedBytes, fast ? 32 : 160));
      final oldLines =
          cleaned.split('\n').where((line) => line.trim().isNotEmpty).toList();
      final matched = <int>{};
      final recovered = <String>[];
      for (final crop in crops) {
        final candidate = tidy(
            await OnnxTextDetectorService.recognizeArabicLineIfAvailable(
                    crop) ??
                '');
        if (_countMeaningfulLetters(candidate) < 3) continue;
        var best = -1;
        for (var i = 0; i < oldLines.length; i++) {
          if (!matched.contains(i) &&
              _sameReadingLine(oldLines[i], candidate)) {
            best = i;
            break;
          }
        }
        if (best >= 0) {
          matched.add(best);
          String latin(String value) =>
              value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          final addedPersian = RegExp(r'[\u0621-\u06D3]').hasMatch(candidate) &&
              !RegExp(r'[\u0621-\u06D3]').hasMatch(oldLines[best]) &&
              latin(candidate) == latin(oldLines[best]);
          recovered.add(addedPersian ? candidate : oldLines[best]);
        } else {
          recovered.add(candidate);
        }
      }
      final combined = recovered.join('\n');
      if ((oldLines.isEmpty || matched.length == oldLines.length) &&
          _countMeaningfulLetters(combined) >
              _countMeaningfulLetters(cleaned)) {
        cleaned = combined;
      }
    }

    // If geometric rotation or resizing reduced recognition quality, also check original imageBytes
    if (wasPreparedModified && _countMeaningfulLetters(cleaned) < 12) {
      final origRaw = await _runTesseractPass(imageBytes, fast: fast);
      final origClean = tidy(origRaw);
      if (_countMeaningfulLetters(origClean) >
          _countMeaningfulLetters(cleaned)) {
        cleaned = origClean;
      }
    }

    // PSM 11 handles sparse signs/labels that page segmentation can overlook.
    if (_countMeaningfulLetters(cleaned) < 4) {
      final sparse =
          tidy(await _runTesseractPass(preparedBytes, fast: fast, psm: 11));
      if (_countMeaningfulLetters(sparse) > _countMeaningfulLetters(cleaned)) {
        cleaned = sparse;
      }
    }

    // Never squash an entire document into the neural line recognizer's 48px input.
    final dimensions =
        img.findDecoderForData(preparedBytes)?.startDecode(preparedBytes);
    if (!fast &&
        cleaned.isEmpty &&
        dimensions != null &&
        dimensions.width / dimensions.height >= 3) {
      final onnxLine =
          await OnnxTextDetectorService.recognizeArabicLineIfAvailable(
        preparedBytes,
      );
      if (onnxLine != null && onnxLine.trim().isNotEmpty) {
        cleaned = tidy(onnxLine);
      }
    }

    // If the scan yielded almost no readable letters on a full scan, check 90/270/180 degree orientation.
    if (!fast && _countMeaningfulLetters(cleaned) < 4) {
      const angles = <int>[90, 270, 180];
      for (final angle in angles) {
        try {
          final rotatedBytes = await Isolate.run(
            () => _rotateImageQuarterTurn(preparedBytes, angle),
          );
          if (rotatedBytes == null) continue;
          final candidateRaw = await _runTesseractPass(rotatedBytes);
          final candidateClean = tidy(candidateRaw);
          if (_countMeaningfulLetters(candidateClean) >
              _countMeaningfulLetters(cleaned) + 4) {
            cleaned = candidateClean;
            break;
          }
        } catch (_) {}
      }
    }

    // The bilingual classifier can replace a Persian word with a short Latin
    // fragment. For otherwise Persian-only pages, use the Persian model; keep
    // the bilingual result whenever actual English words are present.
    if (!fast) {
      final persian = RegExp(
              r'[\u0621-\u063A\u0641-\u064A\u067E\u0686\u0698\u06A9\u06AF\u06CC]')
          .allMatches(cleaned)
          .length;
      final latin = RegExp(r'[A-Za-z]').allMatches(cleaned).length;
      if (persian > 30 &&
          latin > 0 &&
          persian > latin * 5 &&
          !RegExp(r'[A-Za-z]{4,}').hasMatch(cleaned)) {
        final candidate =
            tidy(await _runTesseractPass(preparedBytes, psm: 6, lang: 'fas'));
        if (_countMeaningfulLetters(candidate) >=
            _countMeaningfulLetters(cleaned) * 0.9) {
          cleaned = candidate;
        }
      }
    }
    return cleaned;
  }

  static bool _sameReadingLine(String first, String second) {
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0600-\u06FF]'), '');
    final a = normalize(first), b = normalize(second);
    if (a == b) return true;
    if (a.length < 6 || b.length < 6) return false;
    Set<String> pairs(String value) =>
        {for (var i = 0; i < value.length - 1; i++) value.substring(i, i + 2)};
    final left = pairs(a), right = pairs(b);
    return 2 * left.intersection(right).length / (left.length + right.length) >=
        0.72;
  }

  static List<Uint8List> _cropReadingLines(Uint8List bytes, int limit) {
    final source = img.decodeImage(bytes);
    if (source == null) return [];
    final original = img.bakeOrientation(source);
    final scale =
        math.min(1.0, 1600 / math.max(original.width, original.height));
    final grid = scale == 1
        ? original
        : img.copyResize(original,
            width: (original.width * scale).round(),
            height: (original.height * scale).round());
    final active = <int>[];
    for (var y = 0; y < grid.height; y++) {
      var count = 0;
      for (var x = 0; x < grid.width; x++) {
        final p = grid.getPixel(x, y);
        if (0.299 * p.r + 0.587 * p.g + 0.114 * p.b < 190) count++;
      }
      if (count >= math.max(2, grid.width ~/ 300)) active.add(y);
    }
    final output = <Uint8List>[];
    final maxGap = math.max(3, grid.height ~/ 250);
    var cursor = 0;
    while (cursor < active.length && output.length < limit) {
      final start = active[cursor];
      var end = start;
      while (++cursor < active.length && active[cursor] - end <= maxGap) {
        end = active[cursor];
      }
      if (end - start < 3) continue;
      var left = grid.width, right = -1;
      for (var y = start; y <= end; y++) {
        for (var x = 0; x < grid.width; x++) {
          final p = grid.getPixel(x, y);
          if (0.299 * p.r + 0.587 * p.g + 0.114 * p.b < 190) {
            left = math.min(left, x);
            right = math.max(right, x);
          }
        }
      }
      if (right < left || (right - left + 1) / (end - start + 1) < 2) continue;
      final pad = math.max(3, ((end - start + 1) * 0.18).round());
      final x0 = ((left - pad) / scale).floor().clamp(0, original.width - 1);
      final y0 = ((start - pad) / scale).floor().clamp(0, original.height - 1);
      final x1 =
          ((right + pad + 1) / scale).ceil().clamp(x0 + 1, original.width);
      final y1 =
          ((end + pad + 1) / scale).ceil().clamp(y0 + 1, original.height);
      final crop =
          img.copyCrop(original, x: x0, y: y0, width: x1 - x0, height: y1 - y0);
      output.add(Uint8List.fromList(img.encodePng(crop, level: 1)));
    }
    return output;
  }

  static Future<String> _runTesseractPass(Uint8List bytes,
      {bool fast = false,
      int psm = pageSegmentationMode,
      String lang = language}) async {
    if (Platform.isAndroid) {
      return NativeBridgeService.recognizeAndroidTesseract(
        bytes,
        lang: lang,
        psm: psm,
        fast: fast,
      );
    } else if (Platform.isWindows) {
      return NativeBridgeService.recognizeWindowsTesseract(
        bytes,
        lang: lang,
        psm: psm,
        fast: fast,
      );
    }
    return '';
  }

  static Uint8List? _rotateImageQuarterTurn(
      Uint8List sourceBytes, int degrees) {
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null) return null;
    final rotated = img.copyRotate(decoded, angle: degrees);
    return Uint8List.fromList(img.encodePng(rotated));
  }

  static int _countMeaningfulLetters(String text) {
    var count = 0;
    for (final r in text.runes) {
      final isAsciiAlnum = (r >= 0x30 && r <= 0x39) ||
          (r >= 0x41 && r <= 0x5A) ||
          (r >= 0x61 && r <= 0x7A);
      final isPersianArabic = r >= 0x0600 && r <= 0x06FF;
      if (isAsciiAlnum || isPersianArabic) count++;
    }
    return count;
  }

  /// Removes invisible control marks and normalises line endings; keeps every
  /// visible character exactly as Tesseract produced it.
  static String tidy(String raw) {
    final visible = String.fromCharCodes(
      raw.runes.where((r) => !_invisibleControlMarks.contains(r)),
    );
    final lines = visible
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trimRight());

    final out = <String>[];
    var blankRun = 0;
    for (final line in lines) {
      if (line.isEmpty) {
        blankRun++;
        if (blankRun > 1) continue;
      } else {
        blankRun = 0;
      }
      out.add(line);
    }
    return out.join('\n').trim();
  }
}
