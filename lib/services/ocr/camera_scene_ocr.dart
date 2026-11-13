import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'paddle_arabic_text.dart';

enum CameraTextEdge { left, right, both }

class CameraSceneRead {
  final String text;
  final double confidence;
  final int detectedLines;
  final List<(String, double)?> lines;
  final CameraTextEdge? clippedEdge;
  const CameraSceneRead(this.text, this.confidence, this.detectedLines,
      {this.lines = const [], this.clippedEdge});
}

/// Read text-shaped regions, rather than asking a document recognizer to read
/// the monitor bezel, keyboard and room as if they were printed characters.
class CameraSceneOcr {
  static Future<CameraSceneRead> recognize({
    required OrtSession detector,
    required OrtSession recognizer,
    required List<String> charset,
    Uint8List? imageBytes,
    Uint8List? pixels,
    int width = 0,
    int height = 0,
    bool live = false,
    bool checkClipping = false,
    int? fixedLineWidth,
    double? minimumLineConfidence,
    void Function(CameraSceneRead)? onPartial,
  }) async {
    final source = await _decodeSource(imageBytes, pixels, width, height);
    final (probabilities, detectorWidth, detectorHeight) =
        await _detect(detector, source);
    final crops = await _extractLines(source, probabilities, detectorWidth,
        detectorHeight, live ? 32 : 100, fixedLineWidth);
    final clippedEdge = live || checkClipping
        ? horizontalClip(crops.map((crop) => crop.$4), source.width)
        : null;
    final rows = <int, List<String>>{};
    final lines = <(String, double)?>[];
    var weightedConfidence = 0.0, characters = 0;
    var deliveredPartial = false;
    for (final crop in crops) {
      final read = await _runRecognizer(
          recognizer, charset, crop.$1, crop.$2, minimumLineConfidence);
      lines.add(read);
      if (read == null) continue;
      (rows[crop.$3] ??= []).add(read.$1);
      final count = read.$1.runes.length;
      characters += count;
      weightedConfidence += count * read.$2;
      if (clippedEdge == null && !deliveredPartial && characters >= 60) {
        deliveredPartial = true;
        onPartial?.call(CameraSceneRead(
            _joinRows(rows), weightedConfidence / characters, crops.length));
      }
    }
    return CameraSceneRead(_joinRows(rows),
        characters == 0 ? 0 : weightedConfidence / characters, crops.length,
        lines: lines, clippedEdge: characters == 0 ? null : clippedEdge);
  }

  static CameraTextEdge? horizontalClip(Iterable<Rect> lines, int width) {
    final wide = lines.where((line) => line.width >= width * .15);
    bool clips(Iterable<double> margins) {
      // A cut line can end slightly before the edge when the cut crosses
      // whitespace. Require one edge-touching line and corroborating geometry.
      return margins.any((margin) => margin <= width * .02) &&
          margins.where((margin) => margin <= width * .05).length >= 2;
    }

    final left = clips(wide.map((line) => line.left));
    final right = clips(wide.map((line) => width - line.right));
    if (left && right) return CameraTextEdge.both;
    if (left) return CameraTextEdge.left;
    if (right) return CameraTextEdge.right;
    return null;
  }

  static Future<List<Rect>> locateLines(
      OrtSession detector, Uint8List imageBytes) async {
    final source = await _decodeSource(imageBytes, null, 0, 0);
    final (probabilities, width, height) = await _detect(detector, source);
    return _lineBounds(source, probabilities, width, height);
  }

  static Future<List<Rect>> _lineBounds(
          img.Image source, Float32List probability, int width, int height) =>
      Isolate.run(() => [
            for (final box
                in _findLineBoxes(source, probability, width, height).take(100))
              if (box.width >= box.height * 1.8) box.bounds,
          ]);

  static Future<(Float32List, int, int)> _detect(
      OrtSession detector, img.Image source) async {
    final (tensor, width, height) = await _prepareInput(source);
    final input = await OrtValue.fromList(tensor, [1, 3, height, width]);
    try {
      final outputs = await detector.run({detector.inputNames.first: input});
      try {
        final flat = await outputs.values.first.asFlattenedList();
        return (
          Float32List.fromList(
              flat.map((value) => (value as num).toDouble()).toList()),
          width,
          height
        );
      } finally {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    } finally {
      await input.dispose();
    }
  }

  static Future<CameraSceneRead> recognizeLine({
    required Uint8List imageBytes,
    required OrtSession recognizer,
    required List<String> charset,
    int? fixedLineWidth,
    double? minimumLineConfidence,
  }) async {
    final source = await _decodeSource(imageBytes, null, 0, 0);
    final width = fixedLineWidth ??
        (source.width * 48 / source.height).ceil().clamp(32, 2048);
    final tensor = await _resizeLine(source, width);
    final read = await _runRecognizer(
        recognizer, charset, tensor, width, minimumLineConfidence);
    return CameraSceneRead(read?.$1 ?? '', read?.$2 ?? 0, 1, lines: [read]);
  }

  static Future<Float32List> _resizeLine(img.Image source, int width) =>
      Isolate.run(() => _lineTensor(img.copyResize(source,
          width: width, height: 48, interpolation: img.Interpolation.linear)));

  static Future<(String, double)?> _runRecognizer(
      OrtSession recognizer,
      List<String> charset,
      Float32List tensor,
      int width,
      double? threshold) async {
    final input = await OrtValue.fromList(tensor, [1, 3, 48, width]);
    try {
      final outputs =
          await recognizer.run({recognizer.inputNames.first: input});
      try {
        final output = outputs.values.first;
        return decodeLine(
            await output.asFlattenedList(), output.shape.last, charset,
            minimumConfidence: threshold);
      } finally {
        for (final output in outputs.values) {
          await output.dispose();
        }
      }
    } finally {
      await input.dispose();
    }
  }

  static String _joinRows(Map<int, List<String>> rows) =>
      rows.values.map((parts) {
        final arabic = RegExp(r'[\u0621-\u06D3]').hasMatch(parts.join());
        return (arabic ? parts : parts.reversed).join(' ');
      }).join('\n');

  // Keep native session handles out of the contexts copied to worker isolates.
  static Future<img.Image> _decodeSource(
          Uint8List? imageBytes, Uint8List? pixels, int width, int height) =>
      Isolate.run(() {
        if (pixels != null) {
          return img.Image.fromBytes(
                  width: width,
                  height: height,
                  bytes: pixels.buffer,
                  bytesOffset: pixels.offsetInBytes,
                  numChannels: 1)
              .convert(numChannels: 3);
        }
        final decoded = img.decodeImage(imageBytes!);
        if (decoded == null) {
          throw const FormatException('Invalid camera image');
        }
        final upright = img.bakeOrientation(decoded);
        return upright.numChannels < 3
            ? upright.convert(numChannels: 3)
            : upright;
      });
  static Future<(Float32List, int, int)> _prepareInput(img.Image source) =>
      Isolate.run(() => _prepareDetector(source));

  static Future<List<(Float32List, int, int, Rect)>> _extractLines(
          img.Image source,
          Float32List probability,
          int width,
          int height,
          int limit,
          int? fixedLineWidth) =>
      Isolate.run(() => _prepareLines(
          source, probability, width, height, limit, fixedLineWidth));

  /// CTC confidence belongs to each real text line. Do not average it with
  /// guesses from unrelated objects elsewhere in the camera view.
  static (String, double)? decodeLine(
      List<dynamic> raw, int classes, List<String> charset,
      {double? minimumConfidence}) {
    if (classes < 2 || raw.length % classes != 0) return null;
    var previous = 0, count = 0;
    var confidence = 0.0;
    final text = StringBuffer();
    for (var base = 0; base < raw.length; base += classes) {
      var index = 0;
      var score = -double.infinity;
      for (var c = 0; c < classes; c++) {
        final candidate = (raw[base + c] as num).toDouble();
        if (candidate > score) {
          score = candidate;
          index = c;
        }
      }
      if (index != 0 && index != previous && index < charset.length) {
        text.write(charset[index]);
        confidence += score.clamp(0, 1);
        count++;
      }
      previous = index;
    }
    if (count == 0) return null;
    final result = PaddleArabicText.logicalOrder(text.toString())
        .trim()
        .replaceAll('ي', 'ی')
        .replaceAll('ى', 'ی')
        .replaceAll('ك', 'ک');
    final letters =
        RegExp(r'[\p{L}\p{N}]', unicode: true).allMatches(result).length;
    final mean = confidence / count;
    if (letters == 0 ||
        mean < (minimumConfidence ?? (letters < 4 ? .92 : .80))) {
      return null;
    }
    return (result, mean);
  }

  static (Float32List, int, int) _prepareDetector(img.Image source) {
    final scale = math.min(1.0, 1280 / math.max(source.width, source.height));
    final width = math.max(32, (source.width * scale / 32).round() * 32);
    final height = math.max(32, (source.height * scale / 32).round() * 32);
    final resized = img.copyResize(source,
        width: width, height: height, interpolation: img.Interpolation.linear);
    final size = width * height;
    final data = Float32List(size * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final p = resized.getPixel(x, y);
        final i = y * width + x;
        data[i] = (p.b / 255 - .485) / .229;
        data[size + i] = (p.g / 255 - .456) / .224;
        data[size * 2 + i] = (p.r / 255 - .406) / .225;
      }
    }
    return (data, width, height);
  }

  static List<_LineBox> _findLineBoxes(
      img.Image source, Float32List probability, int width, int height) {
    if (probability.length != width * height) return [];
    final visited = Uint8List(probability.length);
    final queue = Int32List(probability.length);
    final boxes = <_LineBox>[];
    for (var seed = 0; seed < probability.length; seed++) {
      if (visited[seed] != 0 || probability[seed] <= .3) continue;
      var head = 0, tail = 1;
      queue[0] = seed;
      visited[seed] = 1;
      var sx = 0.0, sy = 0.0, xx = 0.0, yy = 0.0, xy = 0.0, score = 0.0;
      while (head < tail) {
        final i = queue[head++];
        final x = i % width, y = i ~/ width;
        sx += x;
        sy += y;
        xx += x * x;
        yy += y * y;
        xy += x * y;
        score += probability[i];
        for (final next in [
          if (x > 0) i - 1,
          if (x + 1 < width) i + 1,
          if (y > 0) i - width,
          if (y + 1 < height) i + width,
        ]) {
          if (visited[next] != 0 || probability[next] <= .3) continue;
          visited[next] = 1;
          queue[tail++] = next;
        }
      }
      if (tail < 8 || score / tail < .6) continue;
      final cx = sx / tail, cy = sy / tail;
      final angle = .5 *
          math.atan2(2 * (xy / tail - cx * cy),
              xx / tail - cx * cx - yy / tail + cy * cy);
      final ax = math.cos(angle), ay = math.sin(angle);
      if (ay.abs() > .87) continue;
      var minU = double.infinity, minV = double.infinity;
      var maxU = -double.infinity, maxV = -double.infinity;
      for (var j = 0; j < tail; j++) {
        final dx = queue[j] % width - cx, dy = queue[j] ~/ width - cy;
        final u = dx * ax + dy * ay, v = -dx * ay + dy * ax;
        minU = math.min(minU, u);
        maxU = math.max(maxU, u);
        minV = math.min(minV, v);
        maxV = math.max(maxV, v);
      }
      final w = maxU - minU, h = maxV - minV;
      if (h < 2 || w / h < 1.3) continue;
      final pad = w * h * 1.5 / (2 * (w + h));
      img.Point point(double u, double v) => img.Point(
          ((cx + ax * u - ay * v) * source.width / width)
              .clamp(0, source.width - 1),
          ((cy + ay * u + ax * v) * source.height / height)
              .clamp(0, source.height - 1));
      final tl = point(minU - pad, minV - pad);
      final tr = point(maxU + pad, minV - pad);
      final br = point(maxU + pad, maxV + pad);
      final bl = point(minU - pad, maxV + pad);
      boxes.add(_LineBox(tl, tr, br, bl));
    }
    // Group pieces on the same baseline before sorting right-to-left.
    boxes.sort((a, b) => a.top.compareTo(b.top));
    final rows = <List<_LineBox>>[];
    for (final box in boxes) {
      if (rows.isEmpty ||
          (box.top - rows.last.first.top).abs() >
              math.min(box.height, rows.last.first.height) * .45) {
        rows.add([box]);
      } else {
        rows.last.add(box);
      }
    }
    // Read split components on the same baseline as a complete line.
    return rows.map(_LineBox.enclose).toList(growable: false);
  }

  static List<(Float32List, int, int, Rect)> _prepareLines(
      img.Image source,
      Float32List probability,
      int width,
      int height,
      int limit,
      int? fixedLineWidth) {
    final result = <(Float32List, int, int, Rect)>[];
    for (final (row, box) in _findLineBoxes(source, probability, width, height)
        .take(limit)
        .indexed) {
      final rw = fixedLineWidth ??
          (box.width * 48 / math.max(1, box.height)).ceil().clamp(32, 2048);
      final crop = img.copyRectify(source,
          topLeft: box.tl,
          topRight: box.tr,
          bottomRight: box.br,
          bottomLeft: box.bl,
          toImage: img.Image(width: rw, height: 48, numChannels: 3),
          interpolation: img.Interpolation.linear);
      result.add((_lineTensor(crop), rw, row, box.bounds));
    }
    return result;
  }

  static Float32List _lineTensor(img.Image crop) {
    final size = crop.width * crop.height;
    final tensor = Float32List(size * 3);
    for (var y = 0; y < crop.height; y++) {
      for (var x = 0; x < crop.width; x++) {
        final p = crop.getPixel(x, y);
        final i = y * crop.width + x;
        tensor[i] = p.b / 127.5 - 1;
        tensor[size + i] = p.g / 127.5 - 1;
        tensor[size * 2 + i] = p.r / 127.5 - 1;
      }
    }
    return tensor;
  }
}

class _LineBox {
  final img.Point tl, tr, br, bl;
  _LineBox(this.tl, this.tr, this.br, this.bl);
  static _LineBox enclose(List<_LineBox> row) {
    if (row.length == 1) return row.first;
    final dominant = row.reduce((a, b) => a.width > b.width ? a : b);
    final ax = (dominant.tr.x - dominant.tl.x) / dominant.width;
    final ay = (dominant.tr.y - dominant.tl.y) / dominant.width;
    var minU = double.infinity, minV = double.infinity;
    var maxU = -double.infinity, maxV = -double.infinity;
    for (final box in row) {
      for (final point in [box.tl, box.tr, box.br, box.bl]) {
        final u = point.x * ax + point.y * ay;
        final v = -point.x * ay + point.y * ax;
        minU = math.min(minU, u);
        maxU = math.max(maxU, u);
        minV = math.min(minV, v);
        maxV = math.max(maxV, v);
      }
    }
    img.Point point(double u, double v) =>
        img.Point(ax * u - ay * v, ay * u + ax * v);
    return _LineBox(point(minU, minV), point(maxU, minV), point(maxU, maxV),
        point(minU, maxV));
  }

  double get top => (tl.y + tr.y + br.y + bl.y) / 4;
  Rect get bounds => Rect.fromLTRB(
      math.min(tl.x, bl.x).toDouble(),
      math.min(tl.y, tr.y).toDouble(),
      math.max(tr.x, br.x).toDouble(),
      math.max(bl.y, br.y).toDouble());
  double get width =>
      math.sqrt(math.pow(tr.x - tl.x, 2) + math.pow(tr.y - tl.y, 2));
  double get height =>
      math.sqrt(math.pow(bl.x - tl.x, 2) + math.pow(bl.y - tl.y, 2));
}
