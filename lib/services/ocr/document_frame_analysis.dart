import 'dart:math' as math;
import 'dart:typed_data';

import 'camera_frame_capture.dart';
import 'camera_lighting.dart';
import 'page_turn_tracker.dart';

enum FrameGuidanceCue {
  moveRight,
  moveLeft,
  moveUp,
  moveDown,
  moveFurther,
  moveCloser,
  findPage,
  checkingText,
  unreadablePage,
  holdSteady,
  tooDark,
  framedAndReady,
}

class DocumentFrameAnalysis {
  final FrameGuidanceCue cue;
  final Uint8List grayThumbnail64;
  final Uint8List? pageFingerprint;

  const DocumentFrameAnalysis(this.cue, this.grayThumbnail64,
      [this.pageFingerprint]);

  bool get isReady => cue == FrameGuidanceCue.framedAndReady;

  /// Detect a light page against its surroundings. A page must have four
  /// supported borders, rather than merely contain strong text-like edges.
  static DocumentFrameAnalysis analyze(CameraLumaFrame frame) {
    const width = 160;
    final height = (frame.height * width / frame.width).round().clamp(48, 240);
    final gray = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        gray[y * width + x] = frame.pixels[
            (y * frame.height ~/ height) * frame.width +
                x * frame.width ~/ width];
      }
    }
    final thumb = _sample(frame.pixels, frame.width, frame.height);
    DocumentFrameAnalysis result(FrameGuidanceCue cue) =>
        DocumentFrameAnalysis(cue, thumb);
    if (CameraLighting.isLowLight(gray)) {
      return result(FrameGuidanceCue.tooDark);
    }

    final smooth = Uint8List.fromList(gray);
    final histogram = List<int>.filled(256, 0);
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        var sum = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            sum += gray[(y + dy) * width + x + dx];
          }
        }
        smooth[y * width + x] = sum ~/ 9;
      }
    }
    for (final pixel in smooth) {
      histogram[pixel]++;
    }
    final threshold = _otsu(histogram, smooth.length);
    final visited = Uint8List(gray.length);
    final queue = Int32List(gray.length);
    _PageRegion? best;
    var bestArea = 0.0;
    _PageRegion? clipped;
    var clippedArea = 0.0;
    for (var seed = 0; seed < gray.length; seed++) {
      if (visited[seed] != 0 || smooth[seed] <= threshold) continue;
      var head = 0, tail = 1;
      queue[0] = seed;
      visited[seed] = 1;
      var tl = const math.Point<int>(10000, 10000);
      var tr = const math.Point<int>(-10000, 10000);
      var br = const math.Point<int>(-10000, -10000);
      var bl = const math.Point<int>(10000, -10000);
      var touches = false;
      while (head < tail) {
        final pixel = queue[head++];
        final x = pixel % width, y = pixel ~/ width;
        if (x + y < tl.x + tl.y) tl = math.Point(x, y);
        if (x - y > tr.x - tr.y) tr = math.Point(x, y);
        if (x + y > br.x + br.y) br = math.Point(x, y);
        if (x - y < bl.x - bl.y) bl = math.Point(x, y);
        touches |= x < 2 || x >= width - 2 || y < 2 || y >= height - 2;
        for (final neighbor in [
          if (x > 0) pixel - 1,
          if (x + 1 < width) pixel + 1,
          if (y > 0) pixel - width,
          if (y + 1 < height) pixel + width,
        ]) {
          if (visited[neighbor] != 0 || smooth[neighbor] <= threshold) continue;
          visited[neighbor] = 1;
          queue[tail++] = neighbor;
        }
      }
      if (tail < gray.length * .12) continue;
      final region = _PageRegion(tl, tr, br, bl);
      final area = region.area;
      if (area < gray.length * .12 || tail / area < .68 || area < bestArea) {
        continue;
      }
      final borders = region.supportedBorders(smooth, width, height);
      if (touches) {
        // A bright table or wall can fill the frame. Only partial page borders
        // support an instruction to move away.
        if (borders >= 2 && area > clippedArea) {
          clipped = region;
          clippedArea = area;
        }
        continue;
      }
      if (borders < 4) continue;
      best = region;
      bestArea = area;
    }
    final page = best ?? clipped;
    if (page == null) return result(FrameGuidanceCue.findPage);
    // Directions describe moving the PHONE toward the page, not moving paper.
    final centerX = (page.tl.x + page.tr.x + page.br.x + page.bl.x) / 4 / width;
    final centerY =
        (page.tl.y + page.tr.y + page.br.y + page.bl.y) / 4 / height;
    if (centerX < .36) return result(FrameGuidanceCue.moveLeft);
    if (centerX > .64) return result(FrameGuidanceCue.moveRight);
    if (centerY < .33) return result(FrameGuidanceCue.moveUp);
    if (centerY > .67) return result(FrameGuidanceCue.moveDown);
    if (best == null) {
      return result(clippedArea >= gray.length * .45
          ? FrameGuidanceCue.moveFurther
          : FrameGuidanceCue.findPage);
    }
    if (bestArea < gray.length * .23) {
      return result(FrameGuidanceCue.moveCloser);
    }

    return DocumentFrameAnalysis(FrameGuidanceCue.framedAndReady, thumb,
        best.fingerprint(smooth, width));
  }

  static Uint8List _sample(Uint8List pixels, int width, int height) {
    final sample = Uint8List(64 * 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        var sum = 0;
        for (var dy = 0; dy < 2; dy++) {
          for (var dx = 0; dx < 2; dx++) {
            final sx =
                ((x * 4 + dx * 2 + 1) * width ~/ 256).clamp(0, width - 1);
            final sy =
                ((y * 4 + dy * 2 + 1) * height ~/ 256).clamp(0, height - 1);
            sum += pixels[sy * width + sx];
          }
        }
        sample[y * 64 + x] = sum ~/ 4;
      }
    }
    return sample;
  }

  static int _otsu(List<int> histogram, int count) {
    var total = 0.0;
    for (var i = 0; i < 256; i++) {
      total += i * histogram[i];
    }
    var background = 0, sum = 0.0, variance = -1.0, threshold = 127;
    for (var i = 0; i < 255; i++) {
      background += histogram[i];
      sum += i * histogram[i];
      final foreground = count - background;
      if (background == 0 || foreground == 0) continue;
      final difference = sum / background - (total - sum) / foreground;
      final score = background * foreground * difference * difference;
      if (score > variance) {
        variance = score;
        threshold = i;
      }
    }
    return threshold;
  }
}

class _PageRegion {
  final math.Point<int> tl, tr, br, bl;
  const _PageRegion(this.tl, this.tr, this.br, this.bl);
  List<math.Point<int>> get corners => [tl, tr, br, bl];
  double get area {
    var sum = 0;
    final points = corners;
    for (var i = 0; i < 4; i++) {
      final a = points[i], b = points[(i + 1) % 4];
      sum += a.x * b.y - a.y * b.x;
    }
    return sum.abs() / 2;
  }

  int supportedBorders(Uint8List gray, int width, int height) {
    final points = corners;
    final cx = points.fold<int>(0, (sum, p) => sum + p.x) / 4;
    final cy = points.fold<int>(0, (sum, p) => sum + p.y) / 4;
    var borders = 0;
    for (var side = 0; side < 4; side++) {
      final a = points[side], b = points[(side + 1) % 4];
      var supported = 0;
      for (var step = 1; step < 10; step++) {
        final t = step / 10;
        final x = a.x + (b.x - a.x) * t;
        final y = a.y + (b.y - a.y) * t;
        final distance = math.sqrt((cx - x) * (cx - x) + (cy - y) * (cy - y));
        if (distance < 1) continue;
        final dx = (cx - x) / distance * 3;
        final dy = (cy - y) / distance * 3;
        int pixel(double px, double py) =>
            gray[py.round().clamp(0, height - 1) * width +
                px.round().clamp(0, width - 1)];
        if (pixel(x + dx, y + dy) - pixel(x - dx, y - dy) >= 14) supported++;
      }
      if (supported >= 6) borders++;
    }
    return borders;
  }

  Uint8List fingerprint(Uint8List gray, int width) {
    final pixels = Uint8List(4096);
    for (var y = 0; y < 64; y++) {
      final v = .04 + y / 63 * .92;
      final leftX = tl.x + (bl.x - tl.x) * v;
      final leftY = tl.y + (bl.y - tl.y) * v;
      final rightX = tr.x + (br.x - tr.x) * v;
      final rightY = tr.y + (br.y - tr.y) * v;
      for (var x = 0; x < 64; x++) {
        final u = .04 + x / 63 * .92;
        final sx = (leftX + (rightX - leftX) * u).round();
        final sy = (leftY + (rightY - leftY) * u).round();
        pixels[y * 64 + x] = gray[sy * width + sx];
      }
    }
    final mean =
        pixels.fold<int>(0, (sum, pixel) => sum + pixel) / pixels.length;
    for (var i = 0; i < pixels.length; i++) {
      pixels[i] = pixels[i] < mean * .85 ? 0 : 255;
    }
    return pixels;
  }
}

/// A capture requires a visible, settled page. OCR and network latency have
/// no part in this decision. The page reference is normalized to its borders.
class BookCaptureGate {
  Uint8List? _previous;
  Uint8List? _captured;
  Duration? _steadySince;
  Duration? _lastTextProbe;
  Uint8List? _capturedView;
  bool shouldProbeText = false;

  bool observe(DocumentFrameAnalysis frame, Duration now) {
    shouldProbeText = false;
    final previous = _previous;
    _previous = frame.grayThumbnail64;
    if (frame.cue == FrameGuidanceCue.tooDark ||
        (previous != null &&
            PageTurnTracker.imageDifference(previous, frame.grayThumbnail64) >
                .045)) {
      _steadySince = null;
      return false;
    }
    _steadySince ??= now;
    if (!frame.isReady || frame.pageFingerprint == null) {
      final capturedView = _capturedView;
      if (capturedView != null &&
          PageTurnTracker.imageDifference(capturedView, frame.grayThumbnail64) <
              .008) {
        _steadySince = null;
        return false;
      }
      final lastProbe = _lastTextProbe;
      shouldProbeText = now - _steadySince! >= const Duration(seconds: 2) &&
          (lastProbe == null || now - lastProbe >= const Duration(seconds: 4));
      return false;
    }
    final captured = _captured;
    if (captured != null &&
        PageTurnTracker.imageDifference(captured, frame.pageFingerprint!) <
            .008) {
      _steadySince = null;
      return false;
    }
    return now - _steadySince! >= const Duration(milliseconds: 700);
  }

  void captured(Uint8List fingerprint, {Uint8List? view}) {
    _captured = Uint8List.fromList(fingerprint);
    _steadySince = null;
    _capturedView = view == null ? null : Uint8List.fromList(view);
  }

  void probedText(Duration now) {
    _lastTextProbe = now;
    shouldProbeText = false;
  }

  void resetStability() {
    _previous = null;
    _steadySince = null;
    shouldProbeText = false;
  }
}
