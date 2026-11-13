import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as image;

import '../ocr/camera_lighting.dart';

enum CenterColor {
  lowLight('Low light', 'نور کم'),
  mixed('Mixed colors', 'چند رنگ'),
  black('Black', 'سیاه'),
  white('White', 'سفید'),
  gray('Gray', 'خاکستری'),
  red('Red', 'قرمز'),
  orange('Orange', 'نارنجی'),
  brown('Brown', 'قهوه‌ای'),
  yellow('Yellow', 'زرد'),
  green('Green', 'سبز'),
  cyan('Cyan', 'فیروزه‌ای'),
  blue('Blue', 'آبی'),
  purple('Purple', 'بنفش'),
  pink('Pink', 'صورتی');

  const CenterColor(this.en, this.fa);
  final String en;
  final String fa;

  static CenterColor? fromCamera(CameraImage frame,
      {void Function(Uint8List)? onSample}) {
    final planes = frame.planes;
    if (frame.format.group == ImageFormatGroup.yuv420 && planes.length == 3) {
      final y = planes[0], u = planes[1], v = planes[2];
      return _sample(frame.width, frame.height, (column, row) {
        final luma = _channel(y, column, row, 1);
        final cb = _channel(u, column ~/ 2, row ~/ 2, 1) - 128;
        final cr = _channel(v, column ~/ 2, row ~/ 2, 1) - 128;
        final intensity = (luma - 16) * 1.164;
        return (
          (intensity + 1.596 * cr).round().clamp(0, 255),
          (intensity - .392 * cb - .813 * cr).round().clamp(0, 255),
          (intensity + 2.017 * cb).round().clamp(0, 255),
        );
      }, onSample: onSample);
    }
    if (frame.format.group == ImageFormatGroup.bgra8888 && planes.length == 1) {
      final plane = planes.single;
      return _sample(frame.width, frame.height, (x, y) {
        final offset = y * plane.bytesPerRow + x * (plane.bytesPerPixel ?? 4);
        return (
          plane.bytes[offset + 2],
          plane.bytes[offset + 1],
          plane.bytes[offset],
        );
      }, onSample: onSample);
    }
    return null;
  }

  static int _channel(Plane plane, int x, int y, int stride) =>
      plane.bytes[y * plane.bytesPerRow + x * (plane.bytesPerPixel ?? stride)];

  static CenterColor? fromPhoto(Uint8List bytes) {
    final decoded = image.decodeImage(bytes);
    if (decoded == null) return null;
    return _sample(decoded.width, decoded.height, (x, y) {
      final pixel = decoded.getPixel(x, y);
      return (pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());
    });
  }

  static CenterColor _sample(
      int width, int height, (int, int, int) Function(int, int) pixel,
      {void Function(Uint8List)? onSample}) {
    final luma = Uint8List(81);
    for (var y = 0; y < 9; y++) {
      for (var x = 0; x < 9; x++) {
        final (r, g, b) =
            pixel((2 * x + 1) * width ~/ 18, (2 * y + 1) * height ~/ 18);
        luma[y * 9 + x] = (r * 299 + g * 587 + b * 114) ~/ 1000;
      }
    }
    final low = CameraLighting.isLowLight(luma);
    if (low && onSample == null) return lowLight;
    final votes = <CenterColor, int>{};
    final evidence = onSample == null ? null : image.Image(width: 7, height: 7);
    for (var y = 0; y < 7; y++) {
      for (var x = 0; x < 7; x++) {
        final (r, g, b) =
            pixel((44 + x * 2) * width ~/ 100, (44 + y * 2) * height ~/ 100);
        evidence?.setPixelRgb(x, y, r, g, b);
        final color =
            _classify(HSLColor.fromColor(Color.fromARGB(255, r, g, b)));
        votes.update(color, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    if (evidence != null) onSample!(image.encodePng(evidence));
    if (low) return lowLight;
    return votes.entries.where((entry) => entry.value >= 30).firstOrNull?.key ??
        mixed;
  }

  static CenterColor _classify(HSLColor color) {
    final light = color.lightness;
    final hue = color.hue;
    if (light < .14) return black;
    if (light > .86 && color.saturation < .42) return white;
    if (color.saturation < .19) return gray;
    if (hue < 18 || hue >= 345) return light > .66 ? pink : red;
    if (hue < 47) return light < .4 ? brown : orange;
    if (hue < 69) return yellow;
    if (hue < 166) return green;
    if (hue < 198) return cyan;
    if (hue < 255) return blue;
    if (hue < 305) return purple;
    return pink;
  }
}
