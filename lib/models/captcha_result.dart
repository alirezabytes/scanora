import 'dart:typed_data';

class CaptchaResult {
  final String text;
  final bool isMath;
  final String? mathEquation;
  final String? calculatedAnswer;
  final double? confidence;
  final int elapsedMilliseconds;
  final bool isOffline;
  final String providerName;
  final String modelName;
  final Uint8List? processedImageBytes;
  final DateTime timestamp;

  CaptchaResult({
    required this.text,
    this.isMath = false,
    this.mathEquation,
    this.calculatedAnswer,
    this.confidence,
    required this.elapsedMilliseconds,
    required this.isOffline,
    required this.providerName,
    required this.modelName,
    this.processedImageBytes,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  String get displayText => finalClipboardValue;

  /// Gets the final text intended for clipboard pasting:
  /// If it is a math captcha, returns the numeric answer (e.g. "21").
  /// Otherwise, returns the clean text (e.g. "4K8Z" or "۳۸۴۲").
  String get finalClipboardValue {
    if (isMath && calculatedAnswer != null && calculatedAnswer!.isNotEmpty) {
      return calculatedAnswer!.trim();
    }
    return text.trim();
  }
}
