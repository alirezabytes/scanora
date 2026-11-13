import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:camera/camera.dart';

import 'camera_diagnostics.dart';
import 'onnx_text_detector_service.dart';
import 'camera_lifecycle.dart';
import 'camera_frame_capture.dart';

/// Replays locally recorded evidence on the actual Android runtime. Disabled
/// in ordinary builds, and never reads unrelated photos or user files.
class CameraDiagnosticReplay {
  static const enabled = bool.fromEnvironment('SCANORA_CAMERA_REPLAY');

  static Future<void> run() async {
    if (!enabled || !CameraDiagnostics.enabled || !Platform.isAndroid) return;
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return;
      final directory = Directory('${base.path}/camera_diagnostics');
      if (!await directory.exists()) return;
      final request = File('${directory.path}/replay.request');
      if (!await request.exists()) return;
      final target = (await request.readAsString()).trim();
      final benchmarkStream = target == 'stream-pressure';
      await request.delete();
      final files = await directory
          .list()
          .where((entry) =>
              entry is File &&
              (entry.path.endsWith('_preview.png') ||
                  entry.path.endsWith('_original_photo.jpg')))
          .cast<File>()
          .toList();
      String order(File file) => file.uri.pathSegments.last.replaceFirstMapped(
          RegExp(r'_(\d+)_'), (match) => '_${match[1]!.padLeft(4, '0')}_');
      files.sort((a, b) => order(a).compareTo(order(b)));
      final photo = files.where((f) => f.path.endsWith('_original_photo.jpg'));
      final preview = files.where((f) => f.path.endsWith('_preview.png'));
      if (benchmarkStream && photo.isNotEmpty) {
        await _benchmarkStream(photo.first);
        CameraDiagnostics.event('replay.complete', {});
        return;
      }
      final selection = RegExp(r'^\d+_\d+_(preview\.png|original_photo\.jpg)$')
              .hasMatch(target)
          ? files.where((file) => file.uri.pathSegments.last == target)
          : [
              if (photo.isNotEmpty) photo.first,
              if (preview.isNotEmpty) preview.first,
            ];
      for (final file in selection) {
        final timer = Stopwatch()..start();
        CameraDiagnostics.event(
            'replay.start', {'file': file.uri.pathSegments.last});
        final read = await OnnxTextDetectorService.recognizeCameraScene(
            imageBytes: await file.readAsBytes(), live: true);
        CameraDiagnostics.event('replay.result', {
          'file': file.uri.pathSegments.last,
          'text': read?.text,
          'confidence': read?.confidence,
          'lines': read?.detectedLines,
          'clippedEdge': read?.clippedEdge?.name,
          'ms': timer.elapsedMilliseconds,
        });
      }
      CameraDiagnostics.event('replay.complete', {});
    } catch (error) {
      CameraDiagnostics.event(
          'replay.error', {'type': error.runtimeType.toString()});
    }
  }

  static Future<void> _benchmarkStream(File photo) async {
    final cameras = await availableCameras();
    final back = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back);
    final session = DocumentCameraSession();
    final sampler = CameraPreviewSampler();
    final bytes = await photo.readAsBytes();
    Future<void> measure(String stage) async {
      final timer = Stopwatch()..start();
      final result = await OnnxTextDetectorService.recognizeCameraScene(
          imageBytes: bytes, live: true);
      CameraDiagnostics.event('benchmark.stream', {
        'stage': stage,
        'ms': timer.elapsedMilliseconds,
        'hasText': result?.text.isNotEmpty,
      });
    }

    try {
      await measure('camera_closed');
      final controller = await session.open(back,
          presets: [ResolutionPreset.veryHigh], flashMode: FlashMode.off);
      if (controller == null) return;
      await sampler.start(controller, waitForFirstFrame: true);
      await measure('continuous_analysis');
      await sampler.pause(controller);
      await measure('analysis_paused_preview_running');
    } finally {
      await session.close();
    }
  }
}
