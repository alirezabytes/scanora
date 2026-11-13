import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' show Rect;
import '../../models/ai_provider.dart';
import '../ai/ai_service.dart';
import '../ai/ai_access.dart';
import '../cloud/scanora_cloud_ocr_service.dart';
import 'offline_ocr_engine.dart';
import 'onnx_text_detector_service.dart';
import 'reading_layout.dart';
import 'camera_diagnostics.dart';
import 'camera_scene_ocr.dart' show CameraTextEdge;
import 'automatic_handwriting.dart';
import '../native_bridge_service.dart';

enum CameraOcrMode { live, book }

enum HandwritingLanguage { english, persian }

/// Result of one text-extraction run.
class ScanRecognitionResult {
  final String text;
  final bool isOffline;

  /// Human readable name of the engine that produced the text (shown in the UI).
  final String engine;
  final String? errorMessage;
  final double? confidence;
  final int? detectedTextRegions;
  final CameraTextEdge? clippedEdge;

  /// A service/engine error, as distinct from a valid image with no readable text.
  final bool didFail;

  /// True when the offline engine found no text, so the screen can offer the
  /// "Switch to Online" helper button.
  final bool offerOnlineSwitch;

  const ScanRecognitionResult({
    required this.text,
    required this.isOffline,
    required this.engine,
    this.errorMessage,
    this.confidence,
    this.detectedTextRegions,
    this.clippedEdge,
    this.didFail = false,
    this.offerOnlineSwitch = false,
  });

  bool get hasText => text.trim().isNotEmpty;
}

/// Text extraction from images:
/// * Offline: `RapidOCR (PP-OCRv4 DBNet .onnx)` + `Tesseract 5 (tessdata_best - "fas+eng")` + `PP-OCRv4 Rec (.onnx)`.
/// * Online: the user's selected Scanora Cloud or AI provider, without changing
///   providers when a request fails.
class OcrService {
  OcrService._();

  static const String offlineEngineName =
      'Tesseract 5 + PP-OCRv5 (Persian + English, offline)';
  static const String smartCloudEngineName = 'Google Docs OCR (Drive v3)';

  static const String _transcriptionPrompt = '''
Transcribe ALL visible printed and handwritten text in this image exactly as written. Preserve Persian and English even when both occur on the same line, keeping the natural reading order.
Keep paragraph breaks. If there is a table or multi-column layout, write each row or section on its own line so it reads logically from top to bottom.
Do not translate, summarise, correct or guess obscured text. Mark an unreadable portion as [unreadable]. Output ONLY the transcribed text, without introductions or markdown fences.
If there is no readable text, reply with exactly [NO_TEXT].
''';

  static const String _cameraTranscriptionPrompt = '''
Transcribe clearly legible printed and handwritten text in this camera image in reading order.
Preserve the original Persian and English words, spelling, numbers and line breaks.
Skip blurred or obscured characters instead of guessing them. Return only the text.
If nothing is clearly legible, return exactly [NO_TEXT].
''';

  static Future<ScanRecognitionResult> processImage({
    required Uint8List imageBytes,
    required bool isOfflineMode,
    required AIProviderType activeProvider,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
    bool isPersian = false,
    bool useScanoraCloud = false,
    bool useFastModel = false,
    CameraOcrMode? cameraMode,
    bool preferResponsiveDocumentOcr = false,
    bool detectLayout = false,
    HandwritingLanguage? handwriting,
    bool allowInteractiveBrowserAuth = true,
    void Function(int percent)? onProgress,
  }) async {
    final useCloud = handwriting == null && useScanoraCloud;
    if (!isOfflineMode) {
      try {
        if (useCloud) {
          await ScanoraCloudOcrService.checkAccess();
        } else {
          await AiAccess.ensure(
              provider: activeProvider,
              apiKey: apiKey,
              model: modelName,
              baseUrl: customBaseUrl);
        }
      } catch (error) {
        return ScanRecognitionResult(
            text: '',
            isOffline: false,
            engine: '',
            didFail: true,
            errorMessage:
                AiServiceException.fromError(error).message(isPersian));
      }
    }
    final diagnosticInput = await CameraDiagnostics.image(
        'ocr_request', imageBytes,
        extension:
            imageBytes.length > 4 && imageBytes[0] == 0x89 ? 'png' : 'jpg');
    onProgress?.call(10);
    if (isOfflineMode) {
      final result = await _processOffline(
        imageBytes,
        isPersian: isPersian,
        useFastModel: useFastModel,
        cameraMode: cameraMode,
        preferResponsiveDocumentOcr: preferResponsiveDocumentOcr,
        detectLayout: detectLayout,
        handwriting: handwriting,
        onProgress: onProgress,
      );
      CameraDiagnostics.event('ocr.result', {
        'input': diagnosticInput,
        'text': result.text,
        'engine': result.engine,
        'error': result.errorMessage,
        'didFail': result.didFail,
        'confidence': result.confidence,
        'lines': result.detectedTextRegions,
        'clippedEdge': result.clippedEdge?.name,
      });
      return result;
    }

    if (useCloud) {
      try {
        final text = await ScanoraCloudOcrService.recognize(
          imageBytes,
          isPersian: isPersian,
          allowInteractiveBrowserAuth: allowInteractiveBrowserAuth,
          onProgress: onProgress,
        );
        CameraDiagnostics.event('ocr.result', {
          'input': diagnosticInput,
          'text': text,
          'engine': smartCloudEngineName
        });
        if (text.isNotEmpty) {
          onProgress?.call(100);
          return ScanRecognitionResult(
            text: text,
            isOffline: false,
            engine: smartCloudEngineName,
          );
        }
        return ScanRecognitionResult(
            text: '',
            isOffline: false,
            engine: smartCloudEngineName,
            errorMessage: isPersian
                ? 'گوگل متنی در تصویر تشخیص نداد.'
                : 'Google Docs found no readable text.');
      } catch (error) {
        return ScanRecognitionResult(
            didFail: true,
            text: '',
            isOffline: false,
            engine: smartCloudEngineName,
            errorMessage: error.toString());
      }
    }

    final config = AIProviderConfig.getByType(activeProvider);
    final normalizedModel =
        AIProviderConfig.normalizeModel(activeProvider, modelName);
    final hasKey = apiKey.trim().isNotEmpty;
    final engineLabel = hasKey
        ? '${config.displayName} ($normalizedModel)'
        : (isPersian ? 'سرویس بینایی آنلاین' : 'Online vision provider');

    try {
      onProgress?.call(45);
      final response = await AIService.callVisionModel(
        providerType: activeProvider,
        apiKey: apiKey,
        modelName: normalizedModel,
        customBaseUrl: customBaseUrl,
        imageBytes: imageBytes,
        prompt: handwriting != null
            ? '''
Transcribe the ${handwriting == HandwritingLanguage.persian ? 'Persian (Farsi)' : 'English'} handwritten text exactly as written.
Preserve original spelling, numbers, line breaks and reading order. Mark an illegible word with [؟].
Do not translate, summarize, fill in missing words, or add commentary.
If no handwriting is legible, return exactly [NO_TEXT].
'''
            : detectLayout
                ? '''
Transcribe visible printed and handwritten text in its original language, preserving Persian and English in mixed lines and marking unreadable portions as [unreadable]. Preserve paragraph breaks.
Read each entire column before continuing to the next. For right-to-left documents start with the right column.
Include full-width text where it occurs. For headings, prefix the actual heading with "${isPersian ? 'عنوان' : 'Heading'}. ".
Do not insert, translate or guess any other text. If no text is readable, return [NO_TEXT].
'''
                : cameraMode == CameraOcrMode.live
                    ? _cameraTranscriptionPrompt
                    : _transcriptionPrompt,
        thinkingEffort: thinkingEffort,
        isPersian: isPersian,
      );
      onProgress?.call(100);

      final extracted =
          response.replaceAll('```text', '').replaceAll('```', '').trim();
      CameraDiagnostics.event('ocr.result',
          {'input': diagnosticInput, 'text': extracted, 'engine': engineLabel});
      if (extracted.isEmpty || extracted == '[NO_TEXT]') {
        return ScanRecognitionResult(
          text: '',
          isOffline: false,
          engine: engineLabel,
          errorMessage: isPersian
              ? 'متنی در این تصویر یافت نشد.'
              : 'No readable text found in this image.',
        );
      }
      return ScanRecognitionResult(
        text: extracted,
        isOffline: false,
        engine: engineLabel,
      );
    } catch (e) {
      final cleanError = e.toString().replaceFirst('Exception: ', '');
      return ScanRecognitionResult(
        didFail: true,
        text: '',
        isOffline: false,
        engine: engineLabel,
        errorMessage: isPersian
            ? 'خطا در ارتباط با سرویس آنلاین ($engineLabel): $cleanError'
            : 'Online service error ($engineLabel): $cleanError',
      );
    }
  }

  static Future<ScanRecognitionResult> _processOffline(
    Uint8List imageBytes, {
    required bool isPersian,
    required bool useFastModel,
    required CameraOcrMode? cameraMode,
    required bool preferResponsiveDocumentOcr,
    required bool detectLayout,
    required HandwritingLanguage? handwriting,
    void Function(int percent)? onProgress,
  }) async {
    final engine = switch (handwriting) {
      HandwritingLanguage.english => 'PP-OCRv5 English (offline)',
      HandwritingLanguage.persian => 'Bina 0.2 RizehPizeh (offline)',
      null => offlineEngineName,
    };
    if (!OfflineOcrEngine.isSupported) {
      return ScanRecognitionResult(
        didFail: true,
        text: '',
        isOffline: true,
        engine: engine,
        errorMessage: isPersian
            ? 'استخراج آفلاین در این دستگاه پشتیبانی نمی‌شود.'
            : 'Offline extraction is not supported on this device.',
        offerOnlineSwitch: true,
      );
    }

    onProgress?.call(40);
    var text = '';
    double? confidence;
    int? detectedTextRegions;
    CameraTextEdge? clippedEdge;
    Object? engineFailure;
    try {
      if (handwriting != null) {
        final read = await OnnxTextDetectorService.recognizeHandwriting(
            imageBytes,
            persian: handwriting == HandwritingLanguage.persian,
            minimumLineConfidence:
                handwriting == HandwritingLanguage.persian ? .85 : .88);
        text = read.text.trim();
        confidence = read.confidence;
        detectedTextRegions = read.detectedLines;
      } else if (detectLayout || (cameraMode == null && !useFastModel)) {
        final prepared = await OnnxTextDetectorService.detectAndDeskew(
            imageBytes,
            fastLiveMode: !detectLayout,
            maxImageDimension: 3600);
        final read = await NativeBridgeService.recognizeTesseractWithConfidence(
          prepared.deskewedPngBytes,
          language: OfflineOcrEngine.language,
          psm: OfflineOcrEngine.pageSegmentationMode,
          includeLayout: true,
        );
        final repaired =
            await _repairWeakLines(read, prepared.deskewedPngBytes, isPersian);
        final lines = repaired ?? read.lines;
        final ordered = lines.isEmpty || (!detectLayout && repaired == null)
            ? read.text
            : detectLayout
                ? ReadingLayout.format(lines,
                    heading: isPersian ? 'عنوان' : 'Heading')
                : lines.map((line) => line.text).join('\n');
        text = OfflineOcrEngine.tidy(ordered);
        confidence = repaired == null ? read.confidence : .82;
        detectedTextRegions = lines.isEmpty ? null : lines.length;
      } else if (cameraMode != null) {
        final read = await OfflineOcrEngine.recognizeCameraText(imageBytes,
            bookPage: cameraMode == CameraOcrMode.book);
        // Camera output is spoken automatically. A failed quality check must
        // never fall through to an unverified document transcription.
        text = read.text;
        confidence = read.confidence;
        detectedTextRegions = read.detectedTextRegions;
        clippedEdge = read.clippedEdge;
      } else {
        text = await OfflineOcrEngine.recognizeText(imageBytes,
            fast: useFastModel, preferResponsive: preferResponsiveDocumentOcr);
      }
    } catch (error) {
      engineFailure = error;
      CameraDiagnostics.event(
          'ocr.offline.error', {'type': error.runtimeType.toString()});
    }
    if (clippedEdge == null &&
        handwriting == null &&
        !useFastModel &&
        (text.isEmpty || (confidence ?? 0) < .82)) {
      final read = await _tryHandwriting(imageBytes, isPersian);
      if (!read.didFail) engineFailure = null;
      if (read.hasText) {
        text = read.text;
        confidence = read.confidence;
        detectedTextRegions = read.detectedTextRegions;
      } else if ((confidence ?? 0) < .67) {
        text = '';
        detectedTextRegions =
            math.max(read.detectedTextRegions ?? 0, detectedTextRegions ?? 0);
      }
    }
    if (engineFailure != null) {
      return ScanRecognitionResult(
          didFail: true,
          text: '',
          isOffline: true,
          engine: engine,
          errorMessage: isPersian
              ? 'پردازش آفلاین این تصویر کامل نشد. تصویر را دوباره انتخاب کنید و تلاش کنید.'
              : 'Offline processing did not complete. Select the image again and retry.');
    }
    onProgress?.call(100);
    if (text.isEmpty) {
      return ScanRecognitionResult(
        text: '',
        isOffline: true,
        engine: engine,
        errorMessage: handwriting != null
            ? (isPersian
                ? 'دست‌خط با اطمینان کافی خوانده نشد. اگر می‌توانید، عکس نزدیک‌تر و واضح‌تری از خود نوشته بگیرید.'
                : 'The handwriting could not be read reliably. If possible, take a closer, clearer photo of the writing.')
            : (detectedTextRegions ?? 0) > 0
                ? (isPersian
                    ? 'نوشته در تصویر دیده شد، اما خوانا نبود.'
                    : 'Text was detected but could not be read reliably.')
                : isPersian
                    ? 'متن خوانایی در این تصویر پیدا نشد.'
                    : 'No readable text was found in this image.',
        offerOnlineSwitch: true,
        detectedTextRegions: detectedTextRegions,
      );
    }
    return ScanRecognitionResult(
      text: text,
      isOffline: true,
      engine: engine,
      confidence: confidence,
      detectedTextRegions: detectedTextRegions,
      clippedEdge: clippedEdge,
    );
  }

  static Future<ScanRecognitionResult> _tryHandwriting(
      Uint8List bytes, bool isPersian,
      {bool singleLine = false}) async {
    try {
      final read = await OnnxTextDetectorService.recognizeMixedHandwriting(
          bytes,
          unreadable: _unreadable(isPersian),
          singleLine: singleLine);
      CameraDiagnostics.event('handwriting.result', {
        'lines': read.detectedLines,
        'hasText': read.text.isNotEmpty,
        'confidence': read.confidence,
        'singleLine': singleLine,
      });
      return ScanRecognitionResult(
          text: read.text,
          isOffline: true,
          engine: offlineEngineName,
          confidence: read.confidence,
          detectedTextRegions: read.detectedLines);
    } catch (error) {
      CameraDiagnostics.event(
          'handwriting.error', {'type': error.runtimeType.toString()});
      return const ScanRecognitionResult(
          text: '', isOffline: true, engine: offlineEngineName, didFail: true);
    }
  }

  static String _unreadable(bool isPersian) =>
      isPersian ? '[این بخش خوانا نبود]' : '[unreadable]';

  static Future<List<ReadingLayoutLine>?> _repairWeakLines(
      TesseractRead read, Uint8List bytes, bool isPersian) async {
    final scores = read.lineConfidences;
    if (scores.isEmpty || scores.length != read.lines.length) return null;
    final weak = <int>[
      for (var i = 0; i < scores.length; i++)
        if (scores[i] < .66) i,
    ];
    if (!scores.any((score) => score >= .82)) return null;
    var located = <Rect>[];
    try {
      located = await OnnxTextDetectorService.locateTextLines(bytes);
    } catch (error) {
      CameraDiagnostics.event(
          'handwriting.locate.error', {'type': error.runtimeType.toString()});
    }
    bool sameLine(Rect a, Rect b) {
      final overlap = a.intersect(b);
      return !overlap.isEmpty &&
          overlap.height >= math.min(a.height, b.height) * .4 &&
          overlap.width >= math.min(a.width, b.width) * .25;
    }

    final missing = <Rect>[
      for (final bounds in located)
        if (!read.lines.any((line) => sameLine(bounds, line.bounds))) bounds,
    ];
    final weakBounds = <Rect>[
      for (final i in weak) read.lines[i].bounds,
      ...missing,
    ];
    if (weakBounds.isEmpty) return null;
    final crops = await AutomaticHandwriting.cropLines(
        bytes, weakBounds.take(8).toList());
    final replacements = <Rect, String>{};
    for (var i = 0; i < crops.length; i++) {
      final result =
          await _tryHandwriting(crops[i], isPersian, singleLine: true);
      if (result.hasText) replacements[weakBounds[i]] = result.text;
    }
    final corrected = <ReadingLayoutLine>[
      for (final (i, line) in read.lines.indexed)
        if (scores[i] < .66)
          (
            bounds: line.bounds,
            size: line.size,
            text: replacements[line.bounds] ?? _unreadable(isPersian)
          )
        else
          line,
      for (final bounds in missing)
        (
          bounds: bounds,
          size: bounds.height,
          text: replacements[bounds] ?? _unreadable(isPersian)
        ),
    ];
    if (missing.isNotEmpty) {
      corrected.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    }
    return corrected;
  }
}
