import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:image/image.dart' as img;
import '../../models/ai_provider.dart';
import 'offline_ocr_engine.dart';
import 'ocr_service.dart';
import 'camera_lifecycle.dart';
import 'camera_diagnostics.dart';
import 'camera_scene_ocr.dart';
import '../diagnostics_service.dart';

/// An upright luminance image from the analysis stream, without JPEG or disk I/O.
class CameraLumaFrame {
  final Uint8List pixels;
  final int width;
  final int height;
  const CameraLumaFrame(this.pixels, this.width, this.height);

  static CameraLumaFrame? fromCamera(CameraImage frame,
      CameraDescription camera, DeviceOrientation orientation,
      {int maxDimension = 1280}) {
    if (frame.format.group != ImageFormatGroup.yuv420 || frame.planes.isEmpty) {
      return null;
    }
    final plane = frame.planes.first;
    final stride = plane.bytesPerPixel ?? 1;
    if (frame.width < 16 ||
        frame.height < 16 ||
        (frame.height - 1) * plane.bytesPerRow + (frame.width - 1) * stride >=
            plane.bytes.length) {
      return null;
    }
    final device = switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final rotation = (camera.sensorOrientation +
            (camera.lensDirection == CameraLensDirection.front
                ? device
                : -device)) %
        360;
    final scale =
        math.min(1.0, maxDimension / math.max(frame.width, frame.height));
    final sourceWidth = (frame.width * scale).round();
    final sourceHeight = (frame.height * scale).round();
    final sideways = rotation == 90 || rotation == 270;
    final width = sideways ? sourceHeight : sourceWidth;
    final height = sideways ? sourceWidth : sourceHeight;
    final pixels = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final (sx, sy) = switch (rotation) {
          90 => (y, sourceHeight - 1 - x),
          180 => (sourceWidth - 1 - x, sourceHeight - 1 - y),
          270 => (sourceWidth - 1 - y, x),
          _ => (x, y),
        };
        pixels[y * width + x] = plane.bytes[
            (sy * frame.height ~/ sourceHeight) * plane.bytesPerRow +
                (sx * frame.width ~/ sourceWidth) * stride];
      }
    }
    return CameraLumaFrame(pixels, width, height);
  }

  Uint8List encodePng() => img.encodePng(
      img.Image.fromBytes(
          width: width, height: height, bytes: pixels.buffer, numChannels: 1),
      level: 1);
}

/// Keeps only the latest preview. A slow reader never builds a frame queue.
class CameraPreviewSampler {
  final _clock = Stopwatch()..start();
  Uint8List? _latest;
  int _sampledAt = -1000;
  CameraImage? _image;
  CameraDescription? _camera;
  DeviceOrientation _orientation = DeviceOrientation.portraitUp;

  Uint8List? get latest =>
      _clock.elapsedMilliseconds - _sampledAt < 1200 ? _latest : null;

  Future<CameraLumaFrame?> sampleFrame({int maxDimension = 1920}) async {
    final image = _image;
    final camera = _camera;
    if (image == null || camera == null || latest == null) return null;
    if (maxDimension <= 480) {
      // Framing needs a small image. Avoid copying the full sensor frame and
      // its chroma planes into a new isolate for each guidance update.
      return CameraLumaFrame.fromCamera(image, camera, _orientation,
          maxDimension: maxDimension);
    }
    return _copyFrame(image, camera, _orientation, maxDimension);
  }

  static Future<CameraLumaFrame?> _copyFrame(
          CameraImage image,
          CameraDescription camera,
          DeviceOrientation orientation,
          int maxDimension) =>
      Isolate.run(() => CameraLumaFrame.fromCamera(image, camera, orientation,
          maxDimension: maxDimension));

  Future<void> pause(CameraController controller) async {
    if (!controller.value.isStreamingImages) return;
    try {
      await controller.stopImageStream();
    } on CameraException {
      // Closing a camera may already have stopped its analysis stream.
    }
  }

  Future<void> start(CameraController controller,
      {bool waitForFirstFrame = false}) async {
    if (!controller.supportsImageStreaming()) return;
    try {
      if (controller.value.isStreamingImages) return;
      final firstFrame = Completer<void>();
      _sampledAt = -1000;
      var loggedFormat = false;
      await controller.startImageStream((frame) {
        if (CameraDiagnostics.enabled && !loggedFormat) {
          loggedFormat = true;
          CameraDiagnostics.event('stream.format', {
            'width': frame.width,
            'height': frame.height,
            'format': frame.format.group.name,
            'planes': frame.planes.length,
            'rowStride':
                frame.planes.isEmpty ? null : frame.planes.first.bytesPerRow,
            'pixelStride':
                frame.planes.isEmpty ? null : frame.planes.first.bytesPerPixel,
          });
        }
        final now = _clock.elapsedMilliseconds;
        if (now - _sampledAt < 220) return;
        _sampledAt = now;
        _image = frame;
        _camera = controller.description;
        _orientation = controller.value.deviceOrientation;
        _latest = thumbnail(
            frame, controller.description, controller.value.deviceOrientation);
        if (!firstFrame.isCompleted) firstFrame.complete();
      });
      if (waitForFirstFrame) {
        await firstFrame.future
            .timeout(const Duration(milliseconds: 500), onTimeout: () {});
      }
    } on CameraException {
      // Cameras without a usable analysis stream can still sample stills.
    }
  }

  static Uint8List? thumbnail(CameraImage frame, CameraDescription camera,
      DeviceOrientation orientation) {
    if (frame.format.group != ImageFormatGroup.yuv420 ||
        frame.planes.isEmpty ||
        frame.width < 64 ||
        frame.height < 64) {
      return null;
    }
    final plane = frame.planes.first;
    final stride = plane.bytesPerPixel ?? 1;
    if ((frame.height - 1) * plane.bytesPerRow + (frame.width - 1) * stride >=
        plane.bytes.length) {
      return null;
    }
    final deviceRotation = switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final front = camera.lensDirection == CameraLensDirection.front;
    final rotation = (camera.sensorOrientation +
            (front ? deviceRotation : -deviceRotation)) %
        360;
    final gray = Uint8List(64 * 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final u = front ? 63 - x : x;
        final (column, row) = switch (rotation) {
          90 => (y, 63 - u),
          180 => (63 - u, 63 - y),
          270 => (63 - y, u),
          _ => (u, y),
        };
        // Average four samples inside each cell to reduce moiré and noise.
        final x1 = (4 * column + 1) * frame.width ~/ 256 * stride;
        final x2 = (4 * column + 3) * frame.width ~/ 256 * stride;
        final y1 = (4 * row + 1) * frame.height ~/ 256 * plane.bytesPerRow;
        final y2 = (4 * row + 3) * frame.height ~/ 256 * plane.bytesPerRow;
        final pixels = plane.bytes;
        gray[y * 64 + x] = (pixels[y1 + x1] +
                pixels[y1 + x2] +
                pixels[y2 + x1] +
                pixels[y2 + x2]) ~/
            4;
      }
    }
    return gray;
  }
}

class CameraFrameCapture {
  static Future<ScanRecognitionResult> recognizePreview(CameraLumaFrame frame,
      {void Function(ScanRecognitionResult)? onPartial,
      void Function(CameraTextEdge)? onClippedText}) async {
    try {
      final read = await OfflineOcrEngine.recognizeLivePixels(
          frame.pixels, frame.width, frame.height,
          onClippedText: onClippedText,
          onPartial: (partial) => onPartial?.call(ScanRecognitionResult(
              text: partial.text,
              confidence: partial.confidence,
              detectedTextRegions: partial.detectedTextRegions,
              isOffline: true,
              engine: 'On-device live text')));
      return ScanRecognitionResult(
        text: read.text,
        confidence: read.confidence,
        detectedTextRegions: read.detectedTextRegions,
        isOffline: true,
        engine: 'On-device live text',
      );
    } catch (error, stack) {
      CameraDiagnostics.event(
          'preview.error', {'type': error.runtimeType.toString()});
      DiagnosticsService.record('camera.preview.ocr', error, stack);
      return const ScanRecognitionResult(
        text: '',
        isOffline: true,
        engine: 'On-device live text',
        didFail: true,
        errorMessage: 'Preview text recognition failed.',
      );
    }
  }

  static Future<Uint8List> encodePreview(CameraLumaFrame frame) =>
      Isolate.run(frame.encodePng);

  static Future<CameraLumaFrame?> decodePhoto(Uint8List bytes) =>
      Isolate.run(() {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) return null;
        var image = img.bakeOrientation(decoded);
        if (math.max(image.width, image.height) > 1280) {
          image = img.copyResize(image,
              width: image.width >= image.height ? 1280 : null,
              height: image.height > image.width ? 1280 : null);
        }
        final pixels = Uint8List(image.width * image.height);
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            final p = image.getPixel(x, y);
            pixels[y * image.width + x] =
                (299 * p.r + 587 * p.g + 114 * p.b) ~/ 1000;
          }
        }
        return CameraLumaFrame(pixels, image.width, image.height);
      });

  static Future<Uint8List?> analyzePhoto(Uint8List bytes) =>
      Isolate.run(() => grayThumbnail(bytes));

  /// Average sensor pixels to suppress display flicker and thumbnail aliasing.
  /// Called from the camera screens' background image analysis.
  static Uint8List? grayThumbnail(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width < 16 || decoded.height < 16) {
      return null;
    }
    final resized = img.copyResize(img.bakeOrientation(decoded),
        width: 64, height: 64, interpolation: img.Interpolation.average);
    final gray = Uint8List(64 * 64);
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 64; x++) {
        final p = resized.getPixel(x, y);
        gray[y * 64 + x] = (299 * p.r + 587 * p.g + 114 * p.b) ~/ 1000;
      }
    }
    return gray;
  }

  /// Capture real sensor pixels. Texture screenshots may contain black frames
  /// on Windows and must never be used as a successful OCR capture.
  static Future<Uint8List> capture(CameraController controller,
      {bool refocus = false}) async {
    if (!controller.value.isInitialized || controller.value.isTakingPicture) {
      throw StateError('Camera is not ready for capture.');
    }
    if (refocus) await focusDocumentCamera(controller);
    // Keep cleanup attached to the underlying capture even when it finishes late.
    return controller.takePicture().then((file) async {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) throw StateError('Camera returned an empty image.');
        await CameraDiagnostics.image('original_photo', bytes);
        return bytes;
      } finally {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
    }).timeout(const Duration(seconds: 15));
  }

  /// Honor the chosen mode and report online failures without a local retry.
  Future<ScanRecognitionResult> recognize({
    required Uint8List imageBytes,
    required bool isOfflineMode,
    required AIProviderType activeProvider,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    required ThinkingEffort thinkingEffort,
    required bool isPersian,
    required bool useScanoraCloud,
    required bool useFastModel,
    CameraOcrMode? cameraMode,
    required bool allowInteractiveBrowserAuth,
    void Function(int percent)? onProgress,
  }) async {
    var progress = 0;
    void report(int percent) {
      if (percent <= progress) return;
      progress = percent;
      onProgress?.call(percent);
    }

    Future<ScanRecognitionResult> read(bool offline, bool fast,
            {required void Function(int) reportProgress}) =>
        OcrService.processImage(
          imageBytes: imageBytes,
          isOfflineMode: offline,
          activeProvider: activeProvider,
          apiKey: apiKey,
          modelName: modelName,
          customBaseUrl: customBaseUrl,
          thinkingEffort: thinkingEffort,
          isPersian: isPersian,
          useScanoraCloud: useScanoraCloud,
          useFastModel: fast,
          cameraMode: cameraMode,
          allowInteractiveBrowserAuth: allowInteractiveBrowserAuth,
          onProgress: reportProgress,
        );

    Future<ScanRecognitionResult> readLocal() =>
        read(true, useFastModel, reportProgress: report);

    if (isOfflineMode) {
      return readLocal();
    }
    return read(false, false, reportProgress: report).timeout(
      Duration(
          seconds: useFastModel
              ? (thinkingEffort == ThinkingEffort.high ? 20 : 10)
              : 25),
      onTimeout: () => ScanRecognitionResult(
        text: '',
        isOffline: false,
        engine: '',
        didFail: true,
        errorMessage: isPersian
            ? 'سرویس آنلاین به‌موقع پاسخ نداد.'
            : 'The online service did not respond in time.',
      ),
    );
  }
}
