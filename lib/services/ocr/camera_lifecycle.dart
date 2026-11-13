import 'dart:async';
import 'dart:ui' show Offset;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show PlatformException;
import '../diagnostics_service.dart';
import '../native_bridge_service.dart';
import 'camera_diagnostics.dart';

/// Serializes opening and closing a camera, including across app suspension.
class DocumentCameraSession {
  CameraController? controller;
  Future<void> _pending = Future<void>.value();
  int _generation = 0;
  bool _starting = false;
  bool _suspended = false;
  bool _reopen = false;
  bool _waitingForAccess = false;
  bool get willReopen => _reopen;

  bool beginStartup() {
    if (_starting || _suspended) return false;
    _starting = true;
    _reopen = false;
    _waitingForAccess = false;
    return true;
  }

  bool finishStartup() {
    _starting = false;
    return _reopen && !_suspended;
  }

  /// Only a suspension that interrupted camera use should trigger a reopen.
  /// Android's permission window can emit a resume without a suspension.
  bool suspend({bool reopen = true}) {
    if (_suspended) return false;
    _suspended = true;
    _reopen = reopen && (_starting || controller != null);
    return true;
  }

  Future<bool> resume() async {
    final checkAccess = _suspended && _waitingForAccess;
    _suspended = false;
    if (_starting) return false;
    if (_reopen) return true;
    if (!checkAccess) return false;
    final CameraAccessStatus status;
    try {
      status = await NativeBridgeService.cameraPermission(request: false);
    } on PlatformException {
      return false;
    }
    return !_suspended &&
        !_starting &&
        _waitingForAccess &&
        status == CameraAccessStatus.allowed;
  }

  Future<CameraController?> open(
    CameraDescription camera, {
    required List<ResolutionPreset> presets,
    required FlashMode flashMode,
    int? jpegQuality,
    bool allowPermissionPrompt = true,
  }) async {
    final closing = close();
    final generation = _generation;
    final opening = closing.then((_) async {
      if (generation != _generation) return null;
      // Wait for the permission decision separately from the hardware timeout.
      final status = await NativeBridgeService.cameraPermission(
          request: allowPermissionPrompt);
      if (generation != _generation) return null;
      if (status != CameraAccessStatus.allowed) {
        _waitingForAccess = true;
        throw CameraException(
            status == CameraAccessStatus.blocked
                ? 'CameraAccessBlocked'
                : 'CameraAccessDenied',
            'Camera access is ${status.name}');
      }
      for (final preset in presets) {
        if (generation != _generation) return null;
        final candidate = CameraController(camera, preset, enableAudio: false);
        var keep = false;
        try {
          await candidate.initialize().timeout(const Duration(seconds: 12));
          if (generation != _generation) return null;
          Future<void> configure(Future<void> Function() setting) async {
            try {
              await setting().timeout(const Duration(seconds: 2));
            } catch (_) {
              // Some webcams and fixed-focus mobile lenses lack these controls.
            }
          }

          if (jpegQuality != null) {
            await configure(() => candidate.setJpegImageQuality(jpegQuality));
          }
          await configure(() => candidate.setFlashMode(flashMode));
          await configure(() => candidate.setFocusMode(FocusMode.auto));
          await configure(() => candidate.setExposureMode(ExposureMode.auto));
          // CameraX metering may need preview frames to complete. Waiting here
          // keeps CameraPreview out of the widget tree and stalls startup.
          unawaited(focusDocumentCamera(candidate));
          CameraDiagnostics.event('camera.open', {
            'name': camera.name,
            'lens': camera.lensDirection.name,
            'sensorOrientation': camera.sensorOrientation,
            'preset': preset.name,
            'previewWidth': candidate.value.previewSize?.width,
            'previewHeight': candidate.value.previewSize?.height,
            'deviceOrientation': candidate.value.deviceOrientation.name,
          });
          if (generation != _generation) return null;
          controller = candidate;
          keep = true;
          return candidate;
        } catch (error) {
          if (preset == presets.last || isCameraPermissionError(error)) {
            rethrow;
          }
        } finally {
          if (!keep) await releaseCamera(candidate);
        }
      }
      return null;
    });
    _pending =
        opening.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return opening;
  }

  Future<void> close() {
    _generation++;
    final previous = controller;
    controller = null;
    return _pending = _pending.then((_) => releaseCamera(previous));
  }
}

bool isCameraPermissionError(Object error) =>
    error is CameraException &&
    const {
      'CameraAccessDenied',
      'CameraAccessDeniedWithoutPrompt',
      'CameraAccessRestricted',
      'CameraAccessBlocked'
    }.contains(error.code);

String cameraPermissionMessage(bool isPersian, Object error) {
  if (error is CameraException &&
      (error.code == 'CameraAccessBlocked' ||
          error.code == 'CameraAccessRestricted')) {
    return isPersian
        ? 'دستگاه استفاده از دوربین را مسدود کرده است. وضعیت دسترسی دوربین را در تنظیمات دستگاه بررسی کنید.'
        : 'The device is blocking camera use. Check camera access in device settings.';
  }
  return isPersian
      ? 'مجوز دوربین برای این نسخه از اسکنورا داده نشده است. مجوز دوربین همین نسخه را در تنظیمات دستگاه فعال کنید.'
      : 'Camera access was not granted for this copy of Scanora. Allow camera access for this copy in device settings.';
}

Future<void> focusDocumentCamera(CameraController controller) async {
  if (controller.value.focusPointSupported) {
    try {
      await controller
          .setFocusPoint(const Offset(.5, .5))
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
  if (controller.value.exposurePointSupported) {
    try {
      await controller
          .setExposurePoint(const Offset(.5, .5))
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

Future<void> releaseCamera(CameraController? controller) async {
  if (controller == null) return;
  if (controller.value.isStreamingImages) {
    try {
      await controller.stopImageStream();
    } catch (error, stack) {
      DiagnosticsService.record('camera.stopStream', error, stack);
    }
  }
  try {
    await controller.dispose();
  } catch (error, stack) {
    DiagnosticsService.record('camera.release', error, stack);
  }
}
