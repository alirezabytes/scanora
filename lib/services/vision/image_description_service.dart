import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import '../../models/ai_provider.dart';
import '../ai/ai_service.dart';
import '../ocr/offline_ocr_engine.dart';
import 'onnx_vision_classifier_service.dart';

/// A reliable on-device label for something that is visible in a picture.
class LocalImageLabel {
  final String name;
  final double confidence;
  const LocalImageLabel(this.name, this.confidence);
}

/// Result of describing an image.
class ImageDescriptionResult {
  final String description;
  final String engineName;
  final bool isOffline;

  /// Text read from the picture by the offline OCR engine (offline mode only).
  final String? extractedText;

  /// True when the offline result is deliberately basic and the screen should offer
  /// the "Switch to Online" helper button.
  final bool offerOnlineSwitch;
  final VisionSceneAnalysis? scene;

  const ImageDescriptionResult({
    required this.description,
    required this.engineName,
    required this.isOffline,
    this.extractedText,
    this.offerOnlineSwitch = false,
    this.scene,
  });
}

/// On-device image labelling (bundled with the app).
///
/// Only labels the model reports with high confidence are returned, so the offline
/// report lists what is certainly there and never composes sentences out of guesses.
class LocalImageLabeler {
  LocalImageLabeler._();

  /// Labels below this confidence are never reported.
  static const double minimumConfidence = 0.65;
  static const int maximumLabels = 6;

  static Future<List<LocalImageLabel>> label(Uint8List imageBytes) async {
    if (!Platform.isAndroid || imageBytes.isEmpty) return const [];
    File? tempFile;
    ImageLabeler? labeler;
    try {
      tempFile = File(
        '${Directory.systemTemp.path}/scanora_label_${DateTime.now().microsecondsSinceEpoch}.img',
      );
      await tempFile.writeAsBytes(imageBytes, flush: true);
      labeler = ImageLabeler(
        options: ImageLabelerOptions(confidenceThreshold: minimumConfidence),
      );
      final labels = await labeler.processImage(
        InputImage.fromFilePath(tempFile.path),
      );
      labels.sort((a, b) => b.confidence.compareTo(a.confidence));
      return [
        for (final l in labels.take(maximumLabels))
          LocalImageLabel(l.label, l.confidence),
      ];
    } catch (_) {
      return const [];
    } finally {
      try {
        await labeler?.close();
        if (tempFile != null && tempFile.existsSync()) tempFile.deleteSync();
      } catch (_) {}
    }
  }
}

/// Smart Image Description & Visual Q&A Service:
///
/// * **Offline Engine:** Completely eliminates the false face detection (`detectFacesAndroid`)
///   and uses `OnnxVisionClassifierService` (`YOLOv8n.onnx` / `MobileNetV4.onnx` with strict
///   confidence threshold `> 0.65` under `flutter_onnxruntime`) alongside the bilingual OCR
///   engine (`RapidOCR DBNet .onnx` + `Tesseract 5 tessdata_best fas+eng`) for zero-hallucination
///   reporting of real objects and text.
/// * **Online Engine:** Uses the selected provider, with access checked before
///   image preparation. Connection errors remain visible to the user.
class ImageDescriptionService {
  ImageDescriptionService._();

  static String switchToOnlineNotice(bool isPersian) => isPersian
      ? 'برای توصیف تفصیلی صحنه و جزئیات دقیق، لطفاً به حالت آنلاین سوییچ نمایید.'
      : 'For a detailed scene description and precise details, please switch to Online mode.';

  static Future<ImageDescriptionResult> describeImage({
    required Uint8List imageBytes,
    required bool isOfflineMode,
    required AIProviderType activeProvider,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    required bool isPersian,
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
  }) async {
    if (isOfflineMode) {
      return describeOffline(imageBytes: imageBytes, isPersian: isPersian);
    }

    final config = AIProviderConfig.getByType(activeProvider);
    final normalizedModel = AIProviderConfig.normalizeModel(
      activeProvider,
      modelName,
    );
    final hasKey = apiKey.trim().isNotEmpty;
    final engineLabel = hasKey
        ? '${config.displayName} ($normalizedModel)'
        : (isPersian ? 'سرویس بینایی آنلاین' : 'Online vision provider');

    final prompt = isPersian
        ? '''
شما دستیار بینایی دقیق و واقع‌بین برای افراد نابینا و کم‌بینا هستید.
تصویر را فقط بر اساس آنچه واقعاً دیده می‌شود و بدون هیچ حدس یا توهم، به فارسی روان توصیف کنید:
۱. در یک یا دو جمله: موضوع اصلی و نوع تصویر.
۲. اشیا، افراد، رنگ‌ها و جای هر کدام در کادر (بالا، پایین، چپ، راست، مرکز).
۳. وضوح، نور و اینکه سوژه کامل در کادر است یا نه.
۴. هر نوشته، قیمت، تاریخ، شماره یا کد قابل خواندن را عیناً بنویسید.
'''
        : '''
You are an accurate, factual visual assistant for blind and low-vision users.
Describe the image strictly from what is visibly present, with no guessing or invention:
1. One or two sentences: the main subject and the kind of image.
2. Objects, people, real colours and where each one is in the frame (top, bottom, left, right, centre).
3. Sharpness, lighting and whether the subject is fully inside the frame.
4. Transcribe any readable text, price, date, number or code exactly.
''';

    final response = await AIService.callVisionModel(
      providerType: activeProvider,
      apiKey: apiKey,
      modelName: normalizedModel,
      customBaseUrl: customBaseUrl,
      imageBytes: imageBytes,
      prompt: prompt,
      thinkingEffort: thinkingEffort,
      isPersian: isPersian,
    );
    final text = response.trim();
    if (text.isEmpty) {
      throw Exception(
        isPersian
            ? 'سرویس آنلاین توصیفی برنگرداند.'
            : 'The online service returned no description.',
      );
    }
    return ImageDescriptionResult(
      description: text,
      engineName: engineLabel,
      isOffline: false,
    );
  }

  /// On-device object and text report using `OnnxVisionClassifierService`
  /// (`YOLOv8n.onnx` / `MobileNetV4.onnx` with confidence > 0.65) + `OfflineOcrEngine`
  /// (`RapidOCR DBNet .onnx` + `Tesseract 5 tessdata_best fas+eng`).
  /// Never runs or reports false face detection on text/document images.
  static Future<ImageDescriptionResult> describeOffline({
    required Uint8List imageBytes,
    required bool isPersian,
  }) async {
    final onnxSceneFuture =
        OnnxVisionClassifierService.analyzeScene(imageBytes);
    var ocrUnavailable = false;
    final textFuture = () async {
      try {
        return await OfflineOcrEngine.recognizeVerifiedSceneText(imageBytes);
      } catch (_) {
        ocrUnavailable = true;
        return '';
      }
    }();

    final onnxScene = await onnxSceneFuture;
    if (onnxScene.width == 0) {
      throw FormatException(isPersian
          ? 'تصویر قابل خواندن نیست.'
          : 'The image could not be decoded.');
    }
    final text = await textFuture;

    // Use localized detections for object counts. A classifier can give the
    // same object several labels, such as Bus, Car and Van.
    final isPredominantlyTextDocument = text.length >= 25;
    final detectedElements = <String>[];

    for (final obj in onnxScene.objects) {
      if (obj.confidence < OnnxVisionClassifierService.confidenceThreshold) {
        continue;
      }
      if (isPredominantlyTextDocument &&
          (obj.labelEn.toLowerCase() == 'person' ||
              obj.labelFa.contains('شخص'))) {
        continue;
      }
      final name = isPersian ? obj.labelFa : obj.labelEn;
      final pos = isPersian ? obj.regionFa : obj.regionEn;
      detectedElements.add('${obj.count} $name ($pos)');
    }

    final sceneLabels = <String>[];
    final mlLabels = detectedElements.isEmpty
        ? await LocalImageLabeler.label(imageBytes)
        : const <LocalImageLabel>[];
    for (final l in mlLabels) {
      if (l.confidence < OnnxVisionClassifierService.confidenceThreshold) {
        continue;
      }
      final lower = l.name.toLowerCase();
      if (isPredominantlyTextDocument &&
          (lower.contains('person') ||
              lower.contains('face') ||
              lower.contains('selfie') ||
              lower.contains('portrait') ||
              lower.contains('smile') ||
              lower.contains('eyelash') ||
              lower.contains('skin'))) {
        continue;
      }
      sceneLabels.add(l.name);
    }

    final sb = StringBuffer();
    if (ocrUnavailable) {
      sb.writeln(isPersian
          ? 'خواندن متن تصویر اجرا نشد؛ اطلاعات اشیا و تصویر در ادامه آمده است.'
          : 'Text recognition could not run; object and image results follow.');
    }

    // 1. Scene characteristics (dimensions, orientation, lighting, dominant colors)
    if (onnxScene.width > 0 && onnxScene.height > 0) {
      final orient =
          isPersian ? onnxScene.orientationFa : onnxScene.orientationEn;
      final light = isPersian ? onnxScene.lightingFa : onnxScene.lightingEn;
      final colors = isPersian
          ? onnxScene.dominantColorsFa.join('، ')
          : onnxScene.dominantColorsEn.join(', ');
      sb.writeln(
        isPersian
            ? 'مشخصات تصویر: ابعاد ${onnxScene.width} در ${onnxScene.height} پیکسل ($orient)، وضعیت روشنایی: $light، رنگ‌های غالب: $colors.'
            : 'Image properties: ${onnxScene.width}x${onnxScene.height} px ($orient), lighting: $light, dominant colors: $colors.',
      );
    }

    // 2. High-confidence detected objects (> 0.65)
    if (detectedElements.isNotEmpty) {
      final joined = detectedElements.join(isPersian ? '، ' : ', ');
      sb.writeln(
        isPersian
            ? 'اشیای شناسایی‌شده و تعداد تقریبی: $joined.'
            : 'Detected objects and approximate counts: $joined.',
      );
    } else if (sceneLabels.isNotEmpty) {
      final joined = sceneLabels.join(isPersian ? '، ' : ', ');
      sb.writeln(isPersian
          ? 'برچسب‌های احتمالی تصویر: $joined.'
          : 'Possible image labels: $joined.');
    }

    if (text.isNotEmpty) {
      sb.writeln();
      sb.writeln(
        isPersian ? 'متن خوانده‌شده در تصویر:' : 'Text read from the image:',
      );
      sb.writeln(text);
    }

    if (detectedElements.isEmpty && sceneLabels.isEmpty && text.isEmpty) {
      sb.writeln(
        isPersian
            ? 'شیء یا نوشته‌ای با آستانه اطمینان بالای ۶۵ درصد در این تصویر شناسایی نشد.'
            : 'No object or text above the 65% confidence threshold was detected in this image.',
      );
    }

    sb.writeln();
    sb.write(switchToOnlineNotice(isPersian));

    return ImageDescriptionResult(
      description: sb.toString().trim(),
      engineName: isPersian
          ? 'بینایی آفلاین (YOLOv8n + Tesseract 5 best)'
          : 'Offline vision (YOLOv8n + Tesseract 5 best)',
      isOffline: true,
      extractedText: text,
      offerOnlineSwitch: true,
      scene: onnxScene,
    );
  }

  /// Answers questions in offline mode using the extracted OCR text and detected scene facts,
  /// and advises switching to Online mode for deeper visual reasoning.
  static String answerOfflineQuestion({
    required String question,
    required ImageDescriptionResult? result,
    required bool isPersian,
  }) {
    if (result != null) {
      final qLower = question.toLowerCase();
      final scene = result.scene;
      if (scene != null) {
        final objects = scene.objects;
        final namedObjects = objects.where((object) {
          final english = RegExp.escape(object.labelEn.toLowerCase());
          final person = object.labelEn == 'Person' &&
              RegExp(r'\bpeople\b|افراد|نفر|انسان|آدم').hasMatch(qLower);
          return person ||
              RegExp('\\b$english(?:es|s)?\\b').hasMatch(qLower) ||
              object.labelFa.split(' / ').any(qLower.contains);
        }).toList();
        final genericQuestion = RegExp(
                r'\b(?:how many|number of) (?:objects|items|things)\b|\b(?:count|locate|list|where are) (?:all |the )?(?:objects|items|things)\b|چند شیء|تعداد اشیا|موقعیت اشیا|اشیا کجا')
            .hasMatch(qLower);
        final selected = genericQuestion ? objects : namedObjects;
        if (RegExp(r'how many|count|number of|چند|تعداد').hasMatch(qLower)) {
          if (selected.isEmpty) {
            return isPersian
                ? 'مدل آفلاین شیء مورد سؤال را برای شمارش تشخیص نداد.'
                : 'The offline model did not detect the requested object.';
          }
          final counts = selected
              .map((o) => '${o.count} ${isPersian ? o.labelFa : o.labelEn}')
              .join(isPersian ? '، ' : ', ');
          return isPersian
              ? 'تعداد تقریبی اشیای تشخیص‌داده‌شده: $counts. اشیای کوچک یا پوشیده ممکن است تشخیص داده نشوند.'
              : 'Approximate detected counts: $counts. Small or hidden objects may be missed.';
        }
        if (RegExp(r'where|position|location|کجا|موقعیت|سمت')
            .hasMatch(qLower)) {
          if (selected.isEmpty) {
            return isPersian
                ? 'مدل آفلاین موقعیت شیء مورد سؤال را تشخیص نداد.'
                : 'The offline model did not detect the location of the requested object.';
          }
          return selected
              .map((o) =>
                  '${isPersian ? o.labelFa : o.labelEn}: ${isPersian ? o.regionFa : o.regionEn}')
              .join('\n');
        }
        if (RegExp(r'colou?r|رنگ').hasMatch(qLower)) {
          return isPersian
              ? 'رنگ غالب کل تصویر: ${scene.dominantColorFa}. رنگ هر شیء جداگانه اندازه‌گیری نشده است.'
              : 'Dominant color of the whole image: ${scene.dominantColorEn}. Individual object colors were not measured.';
        }
      }
      if (qLower.contains('متن') ||
          qLower.contains('نوشته') ||
          qLower.contains('بخوان') ||
          qLower.contains('text') ||
          qLower.contains('read') ||
          qLower.contains('written')) {
        final ext = result.extractedText?.trim() ?? '';
        if (ext.isNotEmpty) {
          return isPersian
              ? 'متن استخراج‌شده از تصویر:\n$ext'
              : 'Extracted text from the image:\n$ext';
        }
        return isPersian
            ? 'متنی در این تصویر توسط موتور آفلاین شناسایی نشد.'
            : 'No text was detected in this image by the offline engine.';
      }
      return isPersian
          ? 'خلاصه اطلاعات آفلاین تصویر:\n${result.description}'
          : 'Offline image summary:\n${result.description}';
    }
    return isPersian
        ? 'در حالت آفلاین امکان پاسخ تفصیلی به پرسش آزاد درباره تصویر وجود ندارد. برای پرسش و پاسخ تصویری هوشمند، لطفاً به حالت آنلاین سوییچ نمایید.'
        : 'Detailed free-form visual Q&A requires Online mode. Please switch to Online mode for interactive visual questions and answers.';
  }
}
