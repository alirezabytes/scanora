import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import '../../services/settings_service.dart';
import 'online_access_guard.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/a11y/reader_feedback.dart';
import '../../services/ocr/camera_frame_capture.dart';
import '../../services/ocr/camera_diagnostics.dart';
import '../../services/ocr/camera_lifecycle.dart';
import '../../services/ocr/captured_page_store.dart';
import '../../services/vision/center_color_reader.dart';
import 'confirm_dialog.dart';

/// Standard Accessible In-App Camera Screen using `CameraPreview` with
/// automatic focus, flash control, camera switching, keyboard shortcuts,
/// and screen reader announcements.
class InAppCameraScreen extends StatefulWidget {
  final String? title;
  final bool allowMultiple;
  final bool offline;
  final OnlineTask onlineTask;
  final bool readColors;

  const InAppCameraScreen({
    super.key,
    this.title,
    this.allowMultiple = false,
    this.offline = true,
    this.onlineTask = OnlineTask.ocr,
    this.readColors = false,
  });

  /// Opens the In-App Camera to capture a single image and returns the captured [Uint8List] bytes.
  static Future<Uint8List?> capture(
    BuildContext context, {
    String? title,
    OnlineTask onlineTask = OnlineTask.ocr,
  }) async {
    return Navigator.of(context).push<Uint8List?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => InAppCameraScreen(
          title: title,
          allowMultiple: false,
          offline: context.read<SettingsService>().isOfflineMode,
          onlineTask: onlineTask,
        ),
      ),
    );
  }

  /// Opens the In-App Camera to capture one or more pages and returns the list of [Uint8List] bytes.
  static Future<List<Uint8List>> captureMultiple(
    BuildContext context, {
    String? title,
    required bool offline,
  }) async {
    final result = await Navigator.of(context).push<List<Uint8List>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => InAppCameraScreen(
          title: title,
          allowMultiple: true,
          offline: offline,
        ),
      ),
    );
    return result ?? const [];
  }

  @override
  State<InAppCameraScreen> createState() => _InAppCameraScreenState();
}

class _InAppCameraScreenState extends State<InAppCameraScreen>
    with WidgetsBindingObserver {
  final _session = DocumentCameraSession();
  int _generation = 0;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;
  CameraController? _controller;
  bool _isInitializing = true;
  bool _cameraPermissionBlocked = false;
  bool _isCapturing = false;
  Future<bool>? _cancelConfirmation;
  bool _cancelled = false;
  String? _errorMessage;
  FlashMode _flashMode = FlashMode.off;
  String? _captureError;
  Timer? _colorTimer;
  final _colorClock = Stopwatch()..start();
  int _lastColorSampleAt = -1000;
  CenterColor? _candidateColor;
  int _candidateFrames = 0;
  CenterColor? _color;
  late final _capturedPages = CapturedPageStore(offline: widget.offline);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller == null && _generation == 0) _initCameras();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (!_session.suspend(reopen: !_cancelled)) return;
      _generation++;
      _colorTimer?.cancel();
      setState(() {
        _controller = null;
        _isCapturing = false;
        _isInitializing = _session.willReopen;
      });
      unawaited(_session.close());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_session.resume().then<void>((reopen) async {
        if (reopen && mounted && !_cancelled) {
          await _initCameras(allowPermissionPrompt: false);
        }
      }));
    }
  }

  Future<void> _initCameras(
      {bool switchCamera = false, bool allowPermissionPrompt = true}) async {
    if (!mounted || _cancelled || !_session.beginStartup()) return;
    final generation = ++_generation;
    _colorTimer?.cancel();
    _candidateColor = null;
    _candidateFrames = 0;
    _color = null;
    final l = AppLocalizations.of(context);
    final settings = context.read<SettingsService>();
    try {
      if (!widget.readColors && !settings.isOfflineMode) {
        setState(() => _isInitializing = false);
      }
      if ((!widget.readColors &&
              !await OnlineAccessGuard.require(context, settings,
                  task: widget.onlineTask)) ||
          !mounted ||
          generation != _generation) {
        if (mounted && generation == _generation) {
          setState(() {
            _isInitializing = false;
            _errorMessage = OnlineAccessGuard.failureFor(context) ??
                l.tx('Online access check cancelled.',
                    'بررسی دسترسی آنلاین لغو شد.');
          });
        }
        return;
      }
      setState(() {
        _isInitializing = true;
        _controller = null;
        _cameraPermissionBlocked = false;
        _errorMessage = null;
        _captureError = null;
      });
      if (_cameras.isEmpty) {
        final cameras = await availableCameras();
        if (!mounted || generation != _generation) return;
        if (cameras.isEmpty) {
          throw StateError(l.tx(
            'No camera was detected on this device.',
            'هیچ دوربینی روی این دستگاه شناسایی نشد.',
          ));
        }
        _cameras = cameras;
        final back = cameras.indexWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
        );
        _selectedCameraIndex = back < 0 ? 0 : back;
      }
      if (switchCamera) {
        _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
      }

      final android = defaultTargetPlatform == TargetPlatform.android;
      final controller = await _session.open(
        _cameras[_selectedCameraIndex],
        presets: widget.readColors
            ? const [ResolutionPreset.medium, ResolutionPreset.low]
            : android
                ? const [
                    ResolutionPreset.max,
                    ResolutionPreset.veryHigh,
                    ResolutionPreset.high
                  ]
                : const [
                    ResolutionPreset.veryHigh,
                    ResolutionPreset.high,
                    ResolutionPreset.medium
                  ],
        flashMode: _flashMode,
        jpegQuality: android ? 97 : null,
        allowPermissionPrompt: allowPermissionPrompt,
      );
      if (!mounted || generation != _generation || controller == null) return;
      setState(() {
        _controller = controller;
        _isInitializing = false;
      });
      AccessibilityService.announce(
          context,
          widget.readColors
              ? l.tx('Camera ready. Point the center at a color.',
                  'دوربین آماده است. مرکز کادر را به سمت رنگ بگیرید.')
              : l.tx(
                  'Camera ready. Activate Capture Photo to take a picture.',
                  'دوربین آماده است. برای گرفتن عکس دکمهٔ ثبت تصویر را بزنید.',
                ));
      if (widget.readColors) {
        unawaited(_startColorReader(controller, generation));
      }
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final permissionBlocked = isCameraPermissionError(error);
      final message = permissionBlocked
          ? cameraPermissionMessage(l.isPersian, error)
          : l.tx(
              'Could not start the camera. Check camera access and try again. $error',
              'دوربین راه‌اندازی نشد. دسترسی به دوربین را بررسی و دوباره تلاش کنید. $error',
            );
      setState(() {
        _isInitializing = false;
        _cameraPermissionBlocked = permissionBlocked;
        _errorMessage = message;
      });
      AccessibilityService.announce(context, message, assertive: true);
    } finally {
      if (_session.finishStartup() && mounted && !_cancelled) {
        unawaited(_initCameras(allowPermissionPrompt: false));
      }
    }
  }

  Future<void> _startColorReader(
      CameraController controller, int generation) async {
    await WidgetsBinding.instance.endOfFrame;
    bool active() => mounted && generation == _generation && !_cancelled;
    if (!active()) return;
    if (controller.supportsImageStreaming()) {
      try {
        await controller.startImageStream((frame) {
          if (!active()) return;
          final elapsed = _colorClock.elapsedMilliseconds;
          if (elapsed - _lastColorSampleAt < 400) return;
          _lastColorSampleAt = elapsed;
          Uint8List? evidence;
          final color = CenterColor.fromCamera(frame,
              onSample: CameraDiagnostics.enabled
                  ? (bytes) => evidence = bytes
                  : null);
          if (color != null) _acceptColor(color, evidence: evidence);
        });
        return;
      } on CameraException {
        if (!active()) return;
      }
    }

    var reading = false;
    _colorTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) async {
      if (!active() || reading || _cancelConfirmation != null) return;
      reading = true;
      try {
        final bytes = await CameraFrameCapture.capture(controller);
        if (!active()) return;
        final color = await Isolate.run(() => CenterColor.fromPhoto(bytes));
        if (active() && color != null) _acceptColor(color);
      } on CameraException {
        // Retry on the next sample if the webcam was temporarily busy.
      } finally {
        reading = false;
      }
    });
  }

  void _acceptColor(CenterColor color, {Uint8List? evidence}) {
    if (_cancelConfirmation != null || _cancelled) return;
    if (_candidateColor != color) {
      _candidateColor = color;
      _candidateFrames = 1;
      return;
    }
    if (++_candidateFrames < 2 || _color == color) return;
    setState(() => _color = color);
    if (evidence != null) {
      unawaited(CameraDiagnostics.image('color_center', evidence,
          extension: 'png', metadata: {'color': color.name}));
    }
    _announceColor();
  }

  void _announceColor() {
    final l10n = AppLocalizations.of(context);
    final color = _color;
    final message = color == null
        ? l10n.tx('Waiting for a stable color.', 'در انتظار رنگ پایدار.')
        : l10n.tx(color.en, color.fa);
    ReaderFeedback.speak(context, message, context.read<SettingsService>(),
        diagnosticSource: 'live-color');
  }

  Future<void> _triggerAutoFocus() async {
    final ctrl = _controller;
    if (ctrl == null || _isCapturing) return;
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    try {
      await ctrl.setFocusMode(FocusMode.auto);
      await ctrl.setFocusPoint(const Offset(0.5, 0.5));
      await ctrl.setExposurePoint(const Offset(0.5, 0.5));
      if (!mounted) return;
      AccessibilityService.announce(
        context,
        isFa
            ? 'درخواست فوکوس روی مرکز تصویر انجام شد.'
            : 'Requested focus at the center.',
      );
    } catch (_) {}
  }

  Future<void> _toggleFlash() async {
    final ctrl = _controller;
    if (ctrl == null || _isCapturing) return;
    final isFa = Localizations.localeOf(context).languageCode == 'fa';

    final nextMode = widget.readColors
        ? (_flashMode == FlashMode.torch ? FlashMode.off : FlashMode.torch)
        : switch (_flashMode) {
            FlashMode.off => FlashMode.auto,
            FlashMode.auto => FlashMode.always,
            FlashMode.always => FlashMode.torch,
            FlashMode.torch => FlashMode.off,
          };

    try {
      await ctrl.setFlashMode(nextMode);
      if (!mounted) return;
      setState(() => _flashMode = nextMode);
      final modeLabel = switch (nextMode) {
        FlashMode.off => isFa ? 'فلاش خاموش' : 'Flash Off',
        FlashMode.auto => isFa ? 'فلاش خودکار' : 'Flash Auto',
        FlashMode.always => isFa ? 'فلاش روشن هنگام عکس' : 'Flash Always On',
        FlashMode.torch => isFa ? 'چراغ‌قوه روشن' : 'Torch On',
      };
      AccessibilityService.announce(context, modeLabel);
    } catch (_) {
      if (!mounted) return;
      AccessibilityService.announce(
        context,
        isFa
            ? 'این دوربین از تغییر وضعیت فلاش پشتیبانی نمی‌کند.'
            : 'Flash control is not supported on this camera.',
      );
    }
  }

  void _switchCamera() {
    if (_cameras.length < 2 || _isInitializing || _isCapturing) return;
    _initCameras(switchCamera: true);
  }

  Future<void> _capturePhoto() async {
    final ctrl = _controller;
    if (ctrl == null || _isCapturing || _cancelConfirmation != null) return;

    final l = AppLocalizations.of(context);
    final generation = _generation;
    setState(() {
      _isCapturing = true;
      _captureError = null;
    });
    AccessibilityService.announce(
        context,
        l.tx('Taking a photo. Hold the camera steady.',
            'در حال گرفتن عکس. گوشی را ثابت نگه دارید.'));

    try {
      final bytes = await CameraFrameCapture.capture(ctrl, refocus: true);
      if (await _cancelConfirmation == true ||
          !mounted ||
          _cancelled ||
          generation != _generation) {
        return;
      }

      if (widget.allowMultiple) {
        await _capturedPages.append(bytes);
        if (!mounted || _cancelled || generation != _generation) return;
        AccessibilityService.announce(
            context,
            l.tx(
              'Page ${_capturedPages.length} captured. Take another photo or press Done.',
              'صفحهٔ ${_capturedPages.length} ثبت شد. صفحهٔ بعدی را عکس بگیرید یا دکمهٔ اتمام را بزنید.',
            ));
      } else {
        AccessibilityService.announce(
            context, l.tx('Photo captured.', 'تصویر ثبت شد.'));
        Navigator.of(context).pop(bytes);
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _captureError = l.tx(
            'Photo capture failed. Try again.',
            'ثبت تصویر انجام نشد. دوباره تلاش کنید.',
          ));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _isCapturing = false);
      }
    }
  }

  void _finishMultiCapture() {
    if (_isCapturing || _cancelConfirmation != null) return;
    _capturedPages.transferred = true;
    Navigator.of(context).pop<List<Uint8List>>(_capturedPages);
  }

  Future<void> _cancelCapture() async {
    if (_cancelConfirmation != null) return;
    final l10n = AppLocalizations.of(context);
    final confirmation = confirmCancelOperation(
      context,
      message: _capturedPages.isEmpty
          ? null
          : l10n.tx(
              'Cancel the camera session and discard the photos you took?',
              'می‌خواهید عکاسی را لغو کنید و عکس‌های گرفته‌شده را کنار بگذارید؟'),
    );
    _cancelConfirmation = confirmation;
    final confirmed = await confirmation;
    _cancelConfirmation = null;
    if (!confirmed || !mounted) return;
    _cancelled = true;
    if (widget.allowMultiple) {
      Navigator.of(context).pop(<Uint8List>[]);
    } else {
      Navigator.of(context).pop(null);
    }
  }

  @override
  void dispose() {
    _colorTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    unawaited(_session.close());
    if (!_capturedPages.transferred) unawaited(_capturedPages.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    final headerTitle = widget.title ??
        (isFa ? 'دوربین داخلی اسکنورا' : 'Scanora In-App Camera');

    final flashLabel = switch (_flashMode) {
      FlashMode.off => isFa ? 'فلاش: خاموش' : 'Flash: Off',
      FlashMode.auto => isFa ? 'فلاش: خودکار' : 'Flash: Auto',
      FlashMode.always => isFa ? 'فلاش: روشن' : 'Flash: On',
      FlashMode.torch => isFa ? 'چراغ‌قوه: روشن' : 'Torch: On',
    };

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelCapture();
      },
      child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _cancelCapture,
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              leading: Semantics(
                button: true,
                label:
                    isFa ? 'بستن دوربین و انصراف' : 'Close camera and cancel',
                child: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: loc.translate('cancel'),
                  onPressed: _cancelCapture,
                ),
              ),
              title: Semantics(
                header: true,
                child: Text(headerTitle),
              ),
              actions: [
                Semantics(
                  button: true,
                  label: isFa ? 'فوکوس خودکار مجدد' : 'Refocus camera',
                  child: IconButton(
                    icon: const Icon(Icons.center_focus_strong),
                    tooltip: isFa ? 'فوکوس خودکار' : 'Auto Focus',
                    onPressed: _controller == null || _isCapturing
                        ? null
                        : _triggerAutoFocus,
                  ),
                ),
                Semantics(
                  button: true,
                  label: flashLabel,
                  child: IconButton(
                    icon: Icon(
                      _flashMode == FlashMode.off
                          ? Icons.flash_off
                          : (_flashMode == FlashMode.torch
                              ? Icons.highlight
                              : Icons.flash_on),
                    ),
                    tooltip: flashLabel,
                    onPressed: _controller == null || _isCapturing
                        ? null
                        : _toggleFlash,
                  ),
                ),
                if (_cameras.length > 1)
                  Semantics(
                    button: true,
                    label: isFa ? 'تغییر دوربین جلو و عقب' : 'Switch camera',
                    child: IconButton(
                      icon: const Icon(Icons.cameraswitch),
                      tooltip: isFa ? 'تغییر دوربین' : 'Switch Camera',
                      onPressed: _isInitializing || _isCapturing
                          ? null
                          : _switchCamera,
                    ),
                  ),
              ],
            ),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _isInitializing
                        ? Center(
                            child: Semantics(
                              liveRegion: true,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(
                                    color: Colors.white,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    isFa
                                        ? 'در حال راه‌اندازی دوربین داخلی...'
                                        : 'Initializing in-app camera...',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : _errorMessage != null
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.videocam_off,
                                        color: Colors.redAccent,
                                        size: 64,
                                      ),
                                      const SizedBox(height: 16),
                                      Semantics(
                                        liveRegion: true,
                                        child: Text(
                                          _errorMessage!,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 24),
                                      if (!_cameraPermissionBlocked)
                                        ElevatedButton.icon(
                                          icon: const Icon(Icons.refresh),
                                          label: Text(
                                            isFa ? 'تلاش مجدد' : 'Retry',
                                          ),
                                          onPressed: _initCameras,
                                        ),
                                    ],
                                  ),
                                ),
                              )
                            : _controller == null
                                ? const SizedBox.shrink()
                                : GestureDetector(
                                    onTap: _triggerAutoFocus,
                                    child: Semantics(
                                      label: isFa
                                          ? 'پیش‌نمایش زنده دوربین. با ضربه زدن فوکوس خودکار انجام می‌شود.'
                                          : 'Live camera preview. Double tap to autofocus.',
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          Center(
                                            child: CameraPreview(_controller!),
                                          ),
                                          IgnorePointer(
                                            child: Container(
                                              margin: const EdgeInsets.all(24),
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: Colors.tealAccent
                                                      .withValues(
                                                    alpha: 0.6,
                                                  ),
                                                  width: 2,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                  ),
                  Container(
                    color: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 20,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_captureError case final message?)
                          Semantics(
                            liveRegion: true,
                            child: Text(message,
                                style: const TextStyle(color: Colors.white)),
                          ),
                        if (widget.allowMultiple &&
                            _capturedPages.isNotEmpty) ...[
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              isFa
                                  ? 'تعداد صفحات ثبت‌شده: ${_capturedPages.length}'
                                  : 'Captured pages: ${_capturedPages.length}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.tealAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Row(
                          children: [
                            Expanded(
                              child: Semantics(
                                button: true,
                                label: isFa
                                    ? 'انصراف و بستن دوربین'
                                    : 'Cancel and close camera',
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.close),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    side:
                                        const BorderSide(color: Colors.white54),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 18,
                                    ),
                                  ),
                                  label: Text(loc.translate('cancel')),
                                  onPressed: _cancelCapture,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: Semantics(
                                button: true,
                                label: widget.readColors
                                    ? loc.tx('Repeat current color',
                                        'تکرار رنگ فعلی')
                                    : isFa
                                        ? 'ثبت عکس با دوربین داخلی'
                                        : 'Capture photo with in-app camera',
                                child: ElevatedButton.icon(
                                  autofocus: true,
                                  icon: _isCapturing
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.black,
                                          ),
                                        )
                                      : const Icon(Icons.camera_alt, size: 28),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.tealAccent,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 18,
                                    ),
                                    textStyle: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  label: Text(widget.readColors
                                      ? (_color == null
                                          ? loc.tx('Repeat current color',
                                              'تکرار رنگ فعلی')
                                          : loc.tx(_color!.en, _color!.fa))
                                      : isFa
                                          ? 'ثبت تصویر'
                                          : 'Capture Photo'),
                                  onPressed: _controller == null || _isCapturing
                                      ? null
                                      : widget.readColors
                                          ? _announceColor
                                          : _capturePhoto,
                                ),
                              ),
                            ),
                            if (widget.allowMultiple &&
                                _capturedPages.isNotEmpty) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  label: isFa
                                      ? 'اتمام و پردازش ${_capturedPages.length} صفحه'
                                      : 'Done and process ${_capturedPages.length} pages',
                                  child: ElevatedButton.icon(
                                    icon: const Icon(Icons.check_circle),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.greenAccent,
                                      foregroundColor: Colors.black,
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 18,
                                      ),
                                    ),
                                    label: Text(
                                      isFa
                                          ? 'اتمام (${_capturedPages.length})'
                                          : 'Done (${_capturedPages.length})',
                                    ),
                                    onPressed: _isCapturing
                                        ? null
                                        : _finishMultiCapture,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          )),
    );
  }
}
