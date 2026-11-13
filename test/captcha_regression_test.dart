import 'package:scanora/services/captcha/math_evaluator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanora/services/native_bridge_service.dart';
import 'package:scanora/services/ocr/paddle_arabic_text.dart';

void main() {
  test('Arabic model output restores Persian letters without reversing numbers',
      () {
    expect(PaddleArabicText.logicalOrder('مالس'), 'سلام');
    expect(
        PaddleArabicText.logicalOrder('Hello World مالس'), 'سلام Hello World');
    expect(
        PaddleArabicText.logicalOrder('مالس Hello World'), 'Hello World سلام');
    expect(PaddleArabicText.logicalOrder('ABC123'), 'ABC123');
    expect(PaddleArabicText.logicalOrder('٣٨٤٢'), '٣٨٤٢');
    expect(PaddleArabicText.logicalOrder('۳۸۴۲'), '۳۸۴۲');
    expect(PaddleArabicText.logicalOrder('14+7=?'), '14+7=?');
  });
  test('Tesseract fallback uses actual TSV confidence and ignores layout rows',
      () {
    const tsv =
        'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n'
        '4\t1\t1\t1\t1\t0\t0\t0\t100\t20\t-1\t\n'
        '5\t1\t1\t1\t1\t1\t0\t0\t30\t20\t80\tABC\n'
        '5\t1\t1\t1\t1\t2\t40\t0\t30\t20\t60\t123\n';
    final result = NativeBridgeService.parseTesseractTsv(tsv);
    expect(result.text, 'ABC 123');
    expect(result.confidence, closeTo(0.7, 0.001));
    expect(NativeBridgeService.parseTesseractTsv('').confidence, 0);
  });
  test(
      'Persian arithmetic resolves visually identical numerals without changing ordinary codes',
      () {
    expect(MathEvaluator.recoverPersianMath('|۴+V=?'), '14+7=?');
    expect(MathEvaluator.recoverPersianMath('سلامV۴'), isNull);
    expect(MathEvaluator.recoverPersianMath('ABV+X=?'), isNull);
  });
}
