import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:scanora/services/ocr/camera_frame_capture.dart';
import 'package:scanora/services/ocr/document_frame_analysis.dart';
import 'package:scanora/services/ocr/live_text_tracker.dart';
import 'package:scanora/services/ocr/page_turn_tracker.dart';
import 'package:scanora/services/ocr/camera_lighting.dart';
import 'package:scanora/services/ocr/camera_scene_ocr.dart';
import 'package:scanora/services/ocr/automatic_handwriting.dart';

CameraLumaFrame pageFrame({int shift = 0, bool clipped = false, int page = 1}) {
  const width = 320, height = 400;
  final pixels = Uint8List(width * height)..fillRange(0, width * height, 35);
  final left = clipped ? 0 : 45 + shift;
  final right = clipped ? width : 275 + shift;
  for (var y = 35; y < 365; y++) {
    for (var x = left; x < right; x++) {
      pixels[y * width + x] = 235;
    }
  }
  for (var row = 0; row < 18; row++) {
    final y = 65 + row * 15;
    final end = 195 + (row * (page == 1 ? 7 : 17) % 60);
    for (var yy = y; yy < y + 3; yy++) {
      for (var x = 72 + shift; x < end + shift; x++) {
        if (x >= 0 && x < width) pixels[yy * width + x] = 45;
      }
    }
  }
  return CameraLumaFrame(pixels, width, height);
}

void main() {
  test('Live reader guides toward the edge clipping multiple lines', () {
    const first = Rect.fromLTRB(240, 120, 971, 165);
    const second = Rect.fromLTRB(260, 220, 994, 268);
    expect(CameraSceneOcr.horizontalClip([first], 1000), isNull);
    expect(CameraSceneOcr.horizontalClip([first, second], 1000),
        CameraTextEdge.right);
    expect(
        CameraSceneOcr.horizontalClip(
            [first.translate(-175, 0), second.translate(-255, 0)], 1000),
        isNull);
    expect(
        CameraSceneOcr.horizontalClip(
            [first.translate(-240, 0), second.translate(-255, 0)], 1000),
        CameraTextEdge.left);
  });

  test('Automatic handwriting combines scripts in order and marks ambiguity',
      () {
    const persian = CameraSceneRead('', 0, 4, lines: [
      ('این نوشته فارسی است', .96),
      null,
      ('نسخه PDF آماده است', .93),
      ('متن مشکوک', .87),
    ]);
    const english = CameraSceneRead('', 0, 4, lines: [
      null,
      ('The next line is English', .94),
      ('PDF', .93),
      ('other guess', .90),
    ]);
    final result = AutomaticHandwriting.combine(persian, english,
        unreadable: '[unreadable]');
    expect(result.text,
        'این نوشته فارسی است\nThe next line is English\nنسخه PDF آماده است\n[unreadable]');
  });
  test('Low-light guidance distinguishes darkness from readable dark themes',
      () {
    final gray = Uint8List(4096)..fillRange(0, 4096, 12);
    expect(CameraLighting.isLowLight(gray), isTrue);
    for (var i = 0; i < 100; i++) {
      gray[i * 37] = 220;
    }
    expect(CameraLighting.isLowLight(gray), isFalse);
    gray.fillRange(0, gray.length, 230);
    expect(CameraLighting.isLowLight(gray), isFalse);
  });

  test('A replacement view interrupts old speech; a partial view retains it',
      () {
    const page = 'Scanora reads your documents and books without internet';
    expect(LiveTextTracker.replacesView(page, 'reads your documents'), isFalse);
    expect(
        LiveTextTracker.replacesView(page, 'Today the office closes at five'),
        isTrue);
    expect(LiveTextTracker.replacesView('Monday', 'Tuesday'), isTrue);
  });

  test(
      'Neural line decoding collapses CTC repeats and rejects uncertain guesses',
      () {
    final read = CameraSceneOcr.decodeLine(
        [
          .01,
          .98,
          .01,
          .01,
          .98,
          .01,
          .98,
          .01,
          .01,
          .01,
          .01,
          .98,
        ],
        3,
        ['', 'A', 'B']);
    expect(read?.$1, 'AB');
    expect(
        CameraSceneOcr.decodeLine([.2, .45, .35], 3, ['', 'A', 'B']), isNull);
  });

  test('Automatic book capture needs four actual page borders', () {
    final page = DocumentFrameAnalysis.analyze(pageFrame());
    expect(page.cue, FrameGuidanceCue.framedAndReady);
    expect(page.pageFingerprint, isNotNull);
    final clipped = DocumentFrameAnalysis.analyze(pageFrame(clipped: true));
    expect(clipped.isReady, isFalse);
    expect(clipped.pageFingerprint, isNull);
    final dark = DocumentFrameAnalysis.analyze(
        CameraLumaFrame(Uint8List(320 * 400), 320, 400));
    expect(dark.cue, FrameGuidanceCue.tooDark);
  });

  test('A white background does not produce a false move-farther instruction',
      () {
    final frame = pageFrame();
    for (var i = 0; i < frame.pixels.length; i++) {
      if (frame.pixels[i] == 35) frame.pixels[i] = 240;
    }
    final analysis = DocumentFrameAnalysis.analyze(frame);
    expect(analysis.cue, isNot(FrameGuidanceCue.moveFurther));
    final gate = BookCaptureGate();
    gate.observe(analysis, Duration.zero);
    expect(gate.shouldProbeText, isFalse);
    gate.observe(analysis, const Duration(seconds: 2));
    expect(gate.shouldProbeText, isTrue);
    gate.probedText(const Duration(seconds: 2));
    gate.observe(analysis, const Duration(seconds: 3));
    expect(gate.shouldProbeText, isFalse);
    gate.observe(analysis, const Duration(seconds: 7));
    expect(gate.shouldProbeText, isTrue);
    gate.captured(analysis.grayThumbnail64, view: analysis.grayThumbnail64);
    gate.observe(analysis, const Duration(seconds: 20));
    expect(gate.shouldProbeText, isFalse);
  });

  test('Book scanner waits for stability and saves each settled page once', () {
    final gate = BookCaptureGate();
    final first = DocumentFrameAnalysis.analyze(pageFrame());
    expect(gate.observe(first, Duration.zero), isFalse);
    expect(gate.observe(first, const Duration(milliseconds: 500)), isFalse);
    expect(gate.observe(first, const Duration(milliseconds: 800)), isTrue);
    gate.captured(first.pageFingerprint!);
    expect(gate.observe(first, const Duration(seconds: 2)), isFalse);
    for (final shift in [1, 3, 8]) {
      final shifted = DocumentFrameAnalysis.analyze(pageFrame(shift: shift));
      expect(shifted.isReady, isTrue);
      expect(
          PageTurnTracker.imageDifference(
              first.pageFingerprint!, shifted.pageFingerprint!),
          lessThan(.008),
          reason: 'Phone movement of $shift pixels is not a new page.');
    }
    final translated = DocumentFrameAnalysis.analyze(pageFrame(shift: 8));
    expect(gate.observe(translated, const Duration(seconds: 3)), isFalse);
    final second = DocumentFrameAnalysis.analyze(pageFrame(page: 2));
    gate.observe(second, const Duration(seconds: 4));
    gate.observe(second, const Duration(seconds: 5));
    expect(gate.observe(second, const Duration(seconds: 6)), isTrue);
  });

  test('Live speech keeps additions without repeating or dropping queued lines',
      () {
    final text = LiveTextTracker();
    expect(text.takeUnread('The central hallway'), 'The central hallway');
    expect(text.takeUnread('The central hallway leads to room 214'),
        'leads to room 214');
    expect(text.takeUnread('The central hallway leads to room 214'), isEmpty);
    final lines = List.generate(
            10,
            (i) =>
                'Line $i contains enough new text to test speech backpressure.')
        .join('\n');
    final first = text.takeUnread(lines);
    final second = text.takeUnread(lines);
    expect(first, isNotEmpty);
    expect(second, isNotEmpty);
    for (final line in first.split('\n')) {
      expect(second.split('\n'), isNot(contains(line)));
    }
    text.reset();
    expect(text.takeUnread('The central hallway'), 'The central hallway');
  });
}
