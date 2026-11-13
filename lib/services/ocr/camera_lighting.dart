import 'dart:typed_data';

class CameraLighting {
  /// Look at the actual image. A dark theme with visible bright lettering is
  /// readable even when most of the view is black.
  static bool isLowLight(Uint8List luma) {
    if (luma.isEmpty) return false;
    var sum = 0, bright = 0;
    for (final pixel in luma) {
      sum += pixel;
      if (pixel > 110) bright++;
    }
    return sum / luma.length < 35 && bright / luma.length < .01;
  }
}
