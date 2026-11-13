import 'package:flutter_test/flutter_test.dart';
import 'package:scanora/services/vision/image_description_service.dart';
import 'package:scanora/services/vision/onnx_vision_classifier_service.dart';

void main() {
  test('An offline count answers for the object asked about', () {
    const result = ImageDescriptionResult(
      description: '',
      engineName: '',
      isOffline: true,
      scene: VisionSceneAnalysis(
        width: 810,
        height: 1080,
        orientationEn: 'Portrait',
        orientationFa: 'عمودی',
        brightnessEn: 'Balanced',
        brightnessFa: 'متعادل',
        dominantColorEn: 'Gray',
        dominantColorFa: 'خاکستری',
        detectedObjects: [
          DetectedVisionElement(
              labelEn: 'Bus', labelFa: 'اتوبوس', confidence: .9),
          DetectedVisionElement(
            labelEn: 'Person',
            labelFa: 'انسان / شخص',
            confidence: .9,
            count: 3,
          ),
        ],
      ),
    );
    String answer(String question, {bool persian = false}) =>
        ImageDescriptionService.answerOfflineQuestion(
          question: question,
          result: result,
          isPersian: persian,
        );
    expect(answer('How many buses are there?'), contains('1 Bus'));
    expect(answer('How many buses are there?'), isNot(contains('3 Person')));
    expect(answer('How many dogs are there?'), contains('did not detect'));
    expect(answer('Where are the dogs?'), isNot(contains('Bus')));
    expect(answer('چند نفر در تصویرند؟', persian: true), contains('3 انسان'));
    expect(answer('How many objects are there?'), contains('1 Bus, 3 Person'));
  });
}
