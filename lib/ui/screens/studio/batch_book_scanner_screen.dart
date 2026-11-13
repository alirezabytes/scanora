import 'dart:async';
import 'dart:isolate';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/a11y/reader_feedback.dart';
import '../../../services/a11y/accessibility_service.dart';
import '../../../services/ocr/camera_frame_capture.dart';
import '../../../services/ocr/camera_diagnostics.dart';
import '../../../services/ocr/camera_scene_ocr.dart' show CameraTextEdge;
import '../../../services/ocr/camera_lifecycle.dart';
import '../../../services/diagnostics_service.dart';
import '../../../services/ocr/captured_page_store.dart';
import '../../../services/ocr/document_frame_analysis.dart';
import '../../../services/ocr/ocr_service.dart';
import '../../../services/ocr/page_turn_tracker.dart';
import '../../../services/native_bridge_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/ai/ai_access.dart';
import '../../../services/ai/online_access_service.dart';
import '../../widgets/online_access_guard.dart';
import '../../../services/tts/espeak_tts_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/camera_light_button.dart';

class _EscapeBackIntent extends Intent {
  const _EscapeBackIntent();
}

/// Captures framed, settled pages locally. OCR runs after the scan session,
/// keeping framing guidance and page registration independent of the network.
class BatchBookScannerScreen extends StatefulWidget {
  const BatchBookScannerScreen({super.key, this.singlePage = false});

  final bool singlePage;

  @override
  State<BatchBookScannerScreen> createState() => _BatchBookScannerScreenState();
}

class _BatchBookScannerScreenState extends State<BatchBookScannerScreen>
    with WidgetsBindingObserver {
  int _cameraGeneration = 0;
  int _autoGeneration = 0;
  Timer? _recoveryTimer;
  int _cameraFailures = 0;
  final _cameraSession = DocumentCameraSession();
  CameraPreviewSampler? _previewSampler;
  String? _errorMessage;
  final _captureGate = BookCaptureGate();
  final _clock = Stopwatch()..start();
  final _frameCapture = CameraFrameCapture();
  bool _isProbingText = false;
  String _lastCapturedText = '';
  int? _lastReferencePage;
  CameraController? _cameraController;
  bool _isInitializingCamera = true;
  bool _cameraPermissionBlocked = false;
  bool _isAnalyzing = false;
  bool _capturingPage = false;
  bool _autoCaptureEnabled = true;
  bool _finishingBook = false;

  Timer? _guidanceTimer;
  bool _waitingForPageTurn = false;

  FrameGuidanceCue _currentCue = FrameGuidanceCue.holdSteady;
  FrameGuidanceCue? _clippedPageCue;
  Uint8List? _clippedPageView;
  DateTime _lastSpokenGuidanceAt = DateTime.fromMillisecondsSinceEpoch(0);
  FrameGuidanceCue? _lastSpokenCue;
  Duration? _lastDiagnosticFrame;

  late final CapturedPageStore _capturedPages;

  @override
  void initState() {
    super.initState();
    _capturedPages = CapturedPageStore(
        offline: context.read<SettingsService>().isOfflineMode);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initCamera();
    });
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _cameraGeneration++;
    _guidanceTimer?.cancel();
    if (!_capturedPages.transferred) unawaited(_capturedPages.close());
    unawaited(_cameraSession.close());
    EspeakTtsService.stop();
    super.dispose();
  }

  Future<void> _initCamera(
      {bool accessAlreadyChecked = false,
      bool allowPermissionPrompt = true}) async {
    if (!mounted || !_cameraSession.beginStartup()) return;
    final l10n = AppLocalizations.of(context);
    final settings = context.read<SettingsService>();
    setState(() {
      _cameraPermissionBlocked = false;
      _isInitializingCamera = settings.isOfflineMode || accessAlreadyChecked;
    });

    final generation = ++_cameraGeneration;
    try {
      if (!accessAlreadyChecked &&
          !await OnlineAccessGuard.require(context, settings,
              task: OnlineTask.ocr)) {
        if (!mounted || generation != _cameraGeneration) return;
        setState(() {
          _isInitializingCamera = false;
          _autoCaptureEnabled = false;
          _errorMessage = OnlineAccessGuard.failureFor(context);
        });
        return;
      }
      if (!mounted || generation != _cameraGeneration) return;
      setState(() => _isInitializingCamera = true);
      final cameras = await availableCameras();
      if (!mounted || generation != _cameraGeneration) return;
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _isInitializingCamera = false;
        });
        _speakGuidanceText(
          l10n.isPersian
              ? 'دوربینی روی این دستگاه یافت نشد. می‌توانید تصاویر صفحات کتاب را از فایل‌های دستگاه انتخاب کنید.'
              : 'No camera detected on this device. You can add book page images from your device files.',
        );
        return;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final android = defaultTargetPlatform == TargetPlatform.android;
      final controller = await _cameraSession.open(
        camera,
        presets: android
            ? const [
                ResolutionPreset.ultraHigh,
                ResolutionPreset.veryHigh,
                ResolutionPreset.high
              ]
            : const [ResolutionPreset.veryHigh, ResolutionPreset.high],
        flashMode: FlashMode.off,
        allowPermissionPrompt: allowPermissionPrompt,
      );
      if (controller == null || !mounted || generation != _cameraGeneration) {
        return;
      }
      final sampler = android ? CameraPreviewSampler() : null;
      await sampler?.start(controller);
      if (!mounted || generation != _cameraGeneration) return;
      _previewSampler = sampler;

      setState(() {
        _cameraController = controller;
        _isInitializingCamera = false;
        _errorMessage = null;
      });

      _speakGuidanceText(
        l10n.isPersian
            ? 'اسکن هوشمند کتاب فعال شد. دوربین را مقابل صفحه نگه دارید تا به صورت خودکار عکس بگیرد.'
            : 'Smart Book Scanner active. Hold the camera in front of the page for automatic capture.',
      );

      _guidanceTimer = Timer.periodic(
        Duration(milliseconds: controller.value.isStreamingImages ? 250 : 1200),
        (_) => _evaluateLiveFrame(),
      );
    } catch (error) {
      if (!mounted || generation != _cameraGeneration) return;
      _cameraController = null;
      _previewSampler = null;
      await _cameraSession.close();
      if (!mounted || generation != _cameraGeneration) return;
      _reportError(error);
      setState(() {
        _isInitializingCamera = false;
      });
    } finally {
      if (_cameraSession.finishStartup() && mounted && !_finishingBook) {
        unawaited(_initCamera(allowPermissionPrompt: false));
      }
    }
  }

  String _cueMessage(FrameGuidanceCue cue, bool isFa) {
    switch (cue) {
      case FrameGuidanceCue.moveRight:
        return isFa ? 'کمی به راست ببرید' : 'Move slightly right';
      case FrameGuidanceCue.moveLeft:
        return isFa ? 'کمی به چپ ببرید' : 'Move slightly left';
      case FrameGuidanceCue.moveUp:
        return isFa ? 'کمی بالاتر ببرید' : 'Move slightly up';
      case FrameGuidanceCue.moveDown:
        return isFa ? 'کمی پایین‌تر ببرید' : 'Move slightly down';
      case FrameGuidanceCue.moveCloser:
        return isFa ? 'گوشی را کمی نزدیک‌تر ببرید' : 'Move the phone closer';
      case FrameGuidanceCue.findPage:
        return isFa
            ? 'هنوز صفحه پیدا نشده. دوربین را به سمت وسط صفحه بگیرید و آرام حرکت دهید.'
            : 'Page not in view yet. Aim at the middle of the page and move the phone slowly.';
      case FrameGuidanceCue.checkingText:
        return isFa
            ? 'در حال خواندن عکس صفحه. گوشی را ثابت نگه دارید.'
            : 'Reading the page photo. Hold the phone steady.';
      case FrameGuidanceCue.moveFurther:
        return isFa
            ? 'گوشی را دورتر ببرید تا چهار گوشهٔ صفحه دیده شود'
            : 'Move the phone farther away to include all four corners';
      case FrameGuidanceCue.unreadablePage:
        return isFa
            ? 'هنوز متن صفحه واضح نیست. کادر و بازتاب نور را بررسی کنید.'
            : 'The page text is unclear. Check the framing and glare.';
      case FrameGuidanceCue.holdSteady:
        return isFa ? 'کادر را ثابت نگه دارید' : 'Hold steady';
      case FrameGuidanceCue.tooDark:
        return isFa
            ? 'نور کم است. چراغ دوربین را روشن کنید یا نور محیط را بیشتر کنید.'
            : 'Low light. Turn on the camera light or increase room lighting.';
      case FrameGuidanceCue.framedAndReady:
        return isFa
            ? 'چهار گوشهٔ صفحه پیدا شد. گوشی را ثابت نگه دارید.'
            : 'All four page corners found. Hold the phone steady.';
    }
  }

  void _speakGuidanceText(String message) {
    if (!mounted || message.trim().isEmpty) return;
    unawaited(ReaderFeedback.speak(
        context, message, context.read<SettingsService>(),
        diagnosticSource: 'batch-book'));
  }

  void _reportError(Object error) {
    if (!mounted) return;
    if (isCameraPermissionError(error)) {
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      _guidanceTimer?.cancel();
      _cameraController = null;
      _previewSampler = null;
      unawaited(_cameraSession.close());
      final message = cameraPermissionMessage(
          AppLocalizations.of(context).isPersian, error);
      setState(() {
        _cameraPermissionBlocked = true;
        _autoCaptureEnabled = false;
        _errorMessage = message;
      });
      _speakGuidanceText(message);
      return;
    }
    if ((error is CameraException || error is TimeoutException) &&
        _cameraFailures < 3 &&
        _recoveryTimer == null) {
      _cameraFailures++;
      _recoveryTimer = Timer(Duration(seconds: 2 * _cameraFailures), () async {
        _recoveryTimer = null;
        if (!mounted) return;
        _cameraGeneration++;
        _guidanceTimer?.cancel();
        _cameraController = null;
        _previewSampler = null;
        _captureGate.resetStability();
        unawaited(_cameraSession.close());
        await _initCamera(allowPermissionPrompt: false);
      });
    }
    DiagnosticsService.record('camera.book', error, StackTrace.current);
    final isFa = AppLocalizations.of(context).isPersian;
    final message = isFa
        ? 'این صفحه خوانده نشد. دوربین، اتصال اینترنت و سرویس انتخابی را بررسی کنید.'
        : 'This page could not be read. Check your camera, internet connection and selected service.';
    setState(() => _errorMessage = message);
    final now = DateTime.now();
    if (now.difference(_lastSpokenGuidanceAt) >= const Duration(seconds: 6)) {
      _lastSpokenGuidanceAt = now;
      _speakGuidanceText(message);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (!_cameraSession.suspend(reopen: !_finishingBook)) return;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      _cameraGeneration++;
      _guidanceTimer?.cancel();
      _cameraController = null;
      _previewSampler = null;
      _captureGate.resetStability();
      unawaited(_cameraSession.close());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_cameraSession.resume().then<void>((reopen) async {
        if (reopen && mounted && !_finishingBook) {
          await _initCamera(allowPermissionPrompt: false);
        }
      }));
    }
  }

  Future<void> _evaluateLiveFrame() async {
    if (!mounted ||
        _isAnalyzing ||
        _capturingPage ||
        !_autoCaptureEnabled ||
        _finishingBook) {
      return;
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    _isAnalyzing = true;
    final generation = _cameraGeneration;
    final autoGeneration = _autoGeneration;
    final isFa = AppLocalizations.of(context).isPersian;
    final settings = context.read<SettingsService>();
    bool current() =>
        mounted &&
        generation == _cameraGeneration &&
        autoGeneration == _autoGeneration &&
        _autoCaptureEnabled &&
        !_finishingBook;
    var ownsCapture = false;
    try {
      await OnlineAccessService.ensure(settings, task: OnlineTask.ocr);
      if (!current()) return;
      var frame = await _previewSampler?.sampleFrame(maxDimension: 480);
      Uint8List? photo;
      if (frame == null) {
        ownsCapture = true;
        setState(() => _capturingPage = true);
        photo = await CameraFrameCapture.capture(controller);
        frame = await CameraFrameCapture.decodePhoto(photo);
      }
      if (!current() || frame == null) return;
      final analysis = await _analyze(frame);
      if (!current()) return;
      final ready = _captureGate.observe(analysis, _clock.elapsed);
      if (CameraDiagnostics.enabled &&
          (_lastDiagnosticFrame == null ||
              _clock.elapsed - _lastDiagnosticFrame! >=
                  const Duration(seconds: 3))) {
        _lastDiagnosticFrame = _clock.elapsed;
        unawaited(CameraDiagnostics.luma(
                frame.pixels, frame.width, frame.height,
                stage: 'book_preview')
            .then((input) {
          CameraDiagnostics.event('book.frame', {
            'input': input,
            'cue': analysis.cue.name,
            'ready': ready,
          });
        }));
      }
      CameraDiagnostics.event('book.guidance', {
        'cue': analysis.cue.name,
        'ready': ready,
        'meanLuma': analysis.grayThumbnail64.fold<int>(0, (a, b) => a + b) /
            analysis.grayThumbnail64.length,
        'probingText': _isProbingText,
      });
      final clippedView = _clippedPageView;
      if (clippedView != null &&
          (analysis.isReady ||
              PageTurnTracker.imageDifference(
                      clippedView, analysis.grayThumbnail64) >
                  .07)) {
        _clippedPageCue = null;
        _clippedPageView = null;
      }
      final cue = _clippedPageCue ??
          (_isProbingText ? FrameGuidanceCue.checkingText : analysis.cue);
      if (_currentCue != cue || _errorMessage != null) {
        setState(() {
          _errorMessage = null;
          _currentCue = cue;
        });
      }
      if (_isProbingText) return;
      if (!ready) {
        if (_captureGate.shouldProbeText) {
          _captureGate.probedText(_clock.elapsed);
          unawaited(_captureReadablePage(controller, analysis, isFa, current,
              photo: photo));
          return;
        }
        if (!_waitingForPageTurn || !analysis.isReady) {
          _announceCueIfNeeded(cue, isFa);
        }
        return;
      }
      if (settings.isOfflineMode && _capturedPages.isNotEmpty) {
        _captureGate.probedText(_clock.elapsed);
        unawaited(_captureReadablePage(controller, analysis, isFa, current,
            photo: photo, acceptFramedPage: true));
        return;
      }
      // Save the still now. A cloud request or OCR retry cannot hold up scanning.
      ownsCapture = true;
      setState(() => _capturingPage = true);
      photo ??= await CameraFrameCapture.capture(controller);
      if (!current()) return;
      final latest = _previewSampler?.latest;
      if (latest != null &&
          PageTurnTracker.imageDifference(latest, analysis.grayThumbnail64) >
              .08) {
        _captureGate.resetStability();
        return;
      }
      _cameraFailures = 0;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      await _registerCapturedPage(photo, analysis.pageFingerprint!, isFa,
          view: analysis.grayThumbnail64);
    } catch (error) {
      if (current()) _reportAutoCaptureError(error, isFa);
    } finally {
      _isAnalyzing = false;
      if (mounted && ownsCapture) setState(() => _capturingPage = false);
    }
  }

  static Future<DocumentFrameAnalysis> _analyze(CameraLumaFrame frame) =>
      Isolate.run(() => DocumentFrameAnalysis.analyze(frame));

  Future<void> _captureReadablePage(CameraController controller,
      DocumentFrameAnalysis analysis, bool isFa, bool Function() current,
      {Uint8List? photo, bool acceptFramedPage = false}) async {
    _isProbingText = true;
    final settings = context.read<SettingsService>();
    final offline = settings.isOfflineMode;
    setState(() {
      _capturingPage = true;
      _currentCue = FrameGuidanceCue.checkingText;
    });
    _announceCueIfNeeded(FrameGuidanceCue.checkingText, isFa);
    var ownsCapture = true;
    try {
      await OnlineAccessService.ensure(settings, task: OnlineTask.ocr);
      if (!current()) return;
      final bytes =
          photo ?? await CameraFrameCapture.capture(controller, refocus: true);
      if (!current()) return;
      _cameraFailures = 0;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      setState(() => _capturingPage = false);
      ownsCapture = false;
      Future<ScanRecognitionResult> read(Uint8List input) =>
          _frameCapture.recognize(
            imageBytes: input,
            isOfflineMode: offline,
            activeProvider: settings.activeProvider,
            apiKey: settings.getApiKey(settings.activeProvider),
            modelName: settings.getSelectedModel(settings.activeProvider),
            customBaseUrl: settings.customBaseUrl,
            thinkingEffort: settings.thinkingEffort,
            isPersian: isFa,
            useScanoraCloud: settings.useScanoraCloudOcr,
            useFastModel: false,
            cameraMode: CameraOcrMode.book,
            allowInteractiveBrowserAuth: false,
          );
      if (!mounted || !current()) return;
      OnlineAccessGuard.announceProcessing(context, settings,
          task: OnlineTask.ocr);
      final result = await read(bytes);
      if (!current() || offline != settings.isOfflineMode) return;
      if (result.didFail && !offline) {
        final message = result.errorMessage ??
            (isFa
                ? 'سرویس آنلاین نتوانست صفحه را بخواند.'
                : 'The online service could not read this page.');
        setState(() {
          _autoCaptureEnabled = false;
          _errorMessage = message;
        });
        _speakGuidanceText(message);
        return;
      }
      if (!current() || offline != settings.isOfflineMode) return;
      final latest = _previewSampler?.latest;
      if (latest != null &&
          PageTurnTracker.imageDifference(latest, analysis.grayThumbnail64) >
              .10) {
        return;
      }
      final clippedEdge = result.clippedEdge;
      if (clippedEdge != null) {
        final cue = switch (clippedEdge) {
          CameraTextEdge.left => FrameGuidanceCue.moveLeft,
          CameraTextEdge.right => FrameGuidanceCue.moveRight,
          CameraTextEdge.both => FrameGuidanceCue.moveFurther,
        };
        _clippedPageCue = cue;
        _clippedPageView = analysis.grayThumbnail64;
        setState(() => _currentCue = cue);
        _announceCueIfNeeded(cue, isFa);
        return;
      }
      final readableWords = RegExp(r'[\p{L}\p{N}]{2,}', unicode: true)
          .allMatches(result.text.replaceAll(RegExp(r'\[[^\]]*\]'), ''))
          .take(4)
          .length;
      if ((!acceptFramedPage || result.didFail) &&
          (!result.hasText || readableWords < 4)) {
        if (result.didFail) {
          _reportError(
              result.errorMessage ?? StateError('Page recognition failed.'));
        } else {
          setState(() => _currentCue = FrameGuidanceCue.unreadablePage);
          _announceCueIfNeeded(FrameGuidanceCue.unreadablePage, isFa);
        }
        return;
      }
      final pageCount = _capturedPages.length;
      if (offline &&
          result.hasText &&
          pageCount > 0 &&
          _lastCapturedText.isEmpty &&
          _lastReferencePage != pageCount) {
        final prior = await read(await _capturedPages.readPage(pageCount - 1));
        if (!current() || !settings.isOfflineMode) return;
        _lastReferencePage = pageCount;
        if (prior.clippedEdge == null) _lastCapturedText = prior.text;
      }
      if (_lastCapturedText.isNotEmpty &&
          PageTurnTracker.sameText(result.text, _lastCapturedText)) {
        _captureGate.captured(
            analysis.pageFingerprint ?? analysis.grayThumbnail64,
            view: analysis.grayThumbnail64);
        return;
      }
      await _registerCapturedPage(
          bytes, analysis.pageFingerprint ?? analysis.grayThumbnail64, isFa,
          view: analysis.grayThumbnail64,
          previewText: result.text,
          cacheText: offline || !result.isOffline);
    } catch (error) {
      if (current()) _reportAutoCaptureError(error, isFa);
    } finally {
      _isProbingText = false;
      _captureGate.probedText(_clock.elapsed);
      if (mounted && ownsCapture) setState(() => _capturingPage = false);
    }
  }

  void _reportAutoCaptureError(Object error, bool isFa) {
    if (error is AiServiceException) {
      final message = error.message(isFa);
      setState(() {
        _autoCaptureEnabled = false;
        _errorMessage = message;
      });
      _speakGuidanceText(message);
    } else {
      _reportError(error);
    }
  }

  void _announceCueIfNeeded(FrameGuidanceCue cue, bool isFa) {
    final now = DateTime.now();
    final minGap = cue == _lastSpokenCue
        ? const Duration(milliseconds: 3500)
        : const Duration(milliseconds: 2200);
    if (now.difference(_lastSpokenGuidanceAt) < minGap) return;

    _lastSpokenGuidanceAt = now;
    _lastSpokenCue = cue;
    _speakGuidanceText(_cueMessage(cue, isFa));
  }

  Future<void> _registerCapturedPage(
    Uint8List imageBytes,
    Uint8List thumbnail64,
    bool isFa, {
    String previewText = '',
    Uint8List? view,
    bool cacheText = true,
  }) async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    try {
      await HapticFeedback.mediumImpact();
    } catch (_) {}
    if (!mounted || _finishingBook) return;
    await _capturedPages.append(imageBytes,
        text: cacheText && !settings.documentLayout ? previewText : '');
    if (!mounted || _finishingBook) return;
    if (widget.singlePage) {
      AccessibilityService.announce(
          context, isFa ? 'صفحه ثبت شد.' : 'Page captured.');
      await _finishBook();
      return;
    }
    setState(() {
      _captureGate.captured(thumbnail64, view: view);
      _lastCapturedText = previewText;
      _waitingForPageTurn = true;
    });

    if (settings.playPageFlipSound) {
      unawaited(NativeBridgeService.playPageFlipSound());
    }
    final count = _capturedPages.length;
    _speakGuidanceText(isFa
        ? 'صفحه $count ثبت شد. صفحهٔ بعدی را ورق بزنید.'
        : 'Page $count captured. Turn to the next page.');
  }

  Future<void> _capturePageManually() async {
    if (_capturingPage || _finishingBook) return;
    if (!await OnlineAccessGuard.require(
            context, context.read<SettingsService>(),
            task: OnlineTask.ocr) ||
        !mounted) {
      return;
    }
    final isFa = AppLocalizations.of(context).isPersian;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      if (!widget.singlePage) await _pickPagesFromFiles();
      return;
    }
    final generation = _cameraGeneration;
    _autoGeneration++;
    setState(() => _capturingPage = true);
    try {
      final bytes = await CameraFrameCapture.capture(controller);
      if (!mounted || generation != _cameraGeneration || _finishingBook) return;
      _cameraFailures = 0;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      final frame = await CameraFrameCapture.decodePhoto(bytes);
      if (!mounted || generation != _cameraGeneration || _finishingBook) return;
      if (frame == null) {
        throw const FormatException('The camera image could not be decoded.');
      }
      final analysis = await _analyze(frame);
      if (!mounted || generation != _cameraGeneration || _finishingBook) return;
      final thumb = analysis.pageFingerprint ?? analysis.grayThumbnail64;
      await _registerCapturedPage(bytes, thumb, isFa);
    } catch (error) {
      if (generation == _cameraGeneration) _reportError(error);
    } finally {
      if (mounted) setState(() => _capturingPage = false);
    }
  }

  Future<void> _pickPagesFromFiles() async {
    if (_capturingPage || _finishingBook) return;
    if (!await OnlineAccessGuard.require(
            context, context.read<SettingsService>(),
            task: OnlineTask.ocr) ||
        !mounted) {
      return;
    }
    _autoGeneration++;
    setState(() => _capturingPage = true);
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      var added = 0;
      for (final file in files) {
        if (!mounted || _finishingBook) return;
        final bytes = await file.readAsBytes();
        if (!mounted || _finishingBook) return;
        if (bytes.isEmpty) continue;
        await _capturedPages.append(bytes);
        if (!mounted || _finishingBook) return;
        setState(() {});
        added++;
      }
      if (!mounted || added == 0) return;
      final l = AppLocalizations.of(context);
      _speakGuidanceText(l.tx(
        '$added pages added. Total pages: ${_capturedPages.length}',
        '$added صفحه اضافه شد. مجموع صفحات: ${_capturedPages.length}',
      ));
    } catch (error) {
      _reportError(error);
    } finally {
      if (mounted) setState(() => _capturingPage = false);
    }
  }

  Future<void> _finishBook() async {
    if (_finishingBook || _capturedPages.isEmpty) return;
    setState(() {
      _finishingBook = true;
      _autoCaptureEnabled = false;
    });
    _guidanceTimer?.cancel();
    await _capturedPages.waitForWrites();
    if (!mounted) return;
    _capturedPages.transferred = true;
    Navigator.of(context).pop<List<Uint8List>>(_capturedPages);
  }

  Future<void> _handleBack() async {
    final l10n = AppLocalizations.of(context);
    final isFa = l10n.isPersian;
    final sectionName =
        isFa ? 'اسکن هوشمند کتاب با راهنمای صوتی' : 'Smart Batch Book Scan';

    if (_capturedPages.isEmpty) {
      final confirmed = await showSafeConfirmDialog(
        context,
        title: isFa ? 'خروج از $sectionName' : 'Exit from $sectionName',
        message: isFa
            ? 'آیا می‌خواهید از بخش «$sectionName» خارج شوید؟'
            : 'Are you sure you want to exit from "$sectionName"?',
        confirmLabel: l10n.translate('exit_section_btn'),
      );
      if (confirmed && mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            isFa
                ? 'خروج از $sectionName (${_capturedPages.length} صفحه ثبت‌شده)'
                : 'Exit from $sectionName (${_capturedPages.length} Pages Captured)',
          ),
          content: Text(
            isFa
                ? 'آیا می‌خواهید از بخش «$sectionName» خارج شوید یا صفحات ثبت‌شده را در بخش مطالعه و ساخت کتاب صوتی باز کنید؟'
                : 'Would you like to exit from "$sectionName" or open the captured pages in the Reader & Audiobook Studio?',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: Text(
                  isFa ? 'انصراف و ادامه اسکن' : 'Cancel & Continue Scanning'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: Text(
                isFa ? 'حذف و خروج' : 'Discard & Exit',
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_stories_rounded),
              label: Text(
                isFa ? 'باز کردن و مطالعه صفحات' : 'Open & Read Pages',
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.successGreen,
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.pop(ctx, 'open'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (action == 'open') {
      await _finishBook();
    } else if (action == 'discard') {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFa = l10n.isPersian;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): _EscapeBackIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _EscapeBackIntent: CallbackAction<_EscapeBackIntent>(
              onInvoke: (_) {
                _handleBack();
                return null;
              },
            ),
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            includeSemantics: false,
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: l10n.translate('back'),
                  onPressed: _handleBack,
                ),
                title: Semantics(
                  header: true,
                  child: Text(
                    widget.singlePage
                        ? l10n.tx('Scan one page', 'اسکن یک صفحه')
                        : isFa
                            ? 'اسکن هوشمند کتاب با راهنمای صوتی'
                            : 'Smart Batch Book Scan',
                  ),
                ),
                actions: [
                  if (defaultTargetPlatform == TargetPlatform.android)
                    CameraLightButton(controller: _cameraController),
                  if (!_cameraPermissionBlocked)
                    IconButton(
                      icon: Icon(
                        _autoCaptureEnabled
                            ? Icons.hdr_auto_rounded
                            : Icons.hdr_auto_outlined,
                      ),
                      tooltip: _autoCaptureEnabled
                          ? (isFa ? 'عکاسی خودکار فعال است' : 'Auto-Capture On')
                          : (isFa
                              ? 'عکاسی خودکار غیرفعال است'
                              : 'Auto-Capture Off'),
                      onPressed: () async {
                        if (!_autoCaptureEnabled) {
                          if (!await OnlineAccessGuard.require(
                                  context, context.read<SettingsService>(),
                                  task: OnlineTask.ocr) ||
                              !mounted) {
                            return;
                          }
                          if (_cameraController == null) {
                            await _initCamera(accessAlreadyChecked: true);
                            if (!mounted || _cameraController == null) return;
                          }
                        }
                        setState(() {
                          _autoGeneration++;
                          _captureGate.resetStability();
                          _autoCaptureEnabled = !_autoCaptureEnabled;
                        });
                        _speakGuidanceText(
                          _autoCaptureEnabled
                              ? (isFa
                                  ? 'عکاسی خودکار فعال شد'
                                  : 'Auto-capture enabled')
                              : (isFa
                                  ? 'عکاسی خودکار متوقف شد'
                                  : 'Auto-capture paused'),
                        );
                      },
                    ),
                ],
              ),
              body: FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_errorMessage != null)
                        Semantics(
                            child: Text(_errorMessage!,
                                style: const TextStyle(
                                    color: Colors.orangeAccent))),
                      // Live Audio Edge Guidance Status Card
                      Semantics(
                        container: true,
                        child: Card(
                          color: _currentCue == FrameGuidanceCue.framedAndReady
                              ? AppTheme.successGreen.withValues(alpha: 0.16)
                              : AppTheme.primaryCyan.withValues(alpha: 0.12),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                ExcludeSemantics(
                                  child: Icon(
                                    _currentCue ==
                                            FrameGuidanceCue.framedAndReady
                                        ? Icons.check_circle_rounded
                                        : Icons.center_focus_strong_rounded,
                                    size: 32,
                                    color: _currentCue ==
                                            FrameGuidanceCue.framedAndReady
                                        ? AppTheme.successGreen
                                        : AppTheme.primaryCyan,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _waitingForPageTurn &&
                                                _currentCue ==
                                                    FrameGuidanceCue
                                                        .framedAndReady
                                            ? (isFa
                                                ? 'در انتظار ورق زدن به صفحه بعد...'
                                                : 'Waiting for page turn...')
                                            : _cueMessage(_currentCue, isFa),
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        isFa
                                            ? 'صفحات ثبت‌شده: ${_capturedPages.length} صفحه — راهنمای صوتی لبه‌های صفحه و تشخیص خودکار ورق زدن'
                                            : 'Captured Pages: ${_capturedPages.length} — Audio page edge guidance & auto page-turn detection',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.color,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Camera Preview or Desktop File Picker Fallback
                      if (_isInitializingCamera)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        )
                      else if (_cameraController != null &&
                          _cameraController!.value.isInitialized)
                        ExcludeSemantics(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: ColoredBox(
                              color: Colors.black,
                              child: SizedBox(
                                height: 260,
                                width: double.infinity,
                                child: Center(
                                  child: CameraPreview(_cameraController!),
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              children: [
                                const ExcludeSemantics(
                                  child: Icon(
                                    Icons.menu_book_rounded,
                                    size: 42,
                                    color: AppTheme.primaryCyan,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  isFa
                                      ? 'می‌توانید صفحات کتاب را به صورت دسته‌ای انتخاب کنید تا به پروژه مطالعه و کتاب صوتی تبدیل شوند.'
                                      : 'Select multiple book page images to build a multi-page reading & audiobook project.',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),

                      // Action Buttons
                      if (_capturedPages.isNotEmpty) ...[
                        SizedBox(
                          height: 52,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.auto_stories_rounded),
                            label: Text(
                              isFa
                                  ? 'پایان اسکن و باز کردن کتاب (${_capturedPages.length} صفحه)'
                                  : 'Finish & Open Book Project (${_capturedPages.length} Pages)',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.successGreen,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: _finishingBook ? null : _finishBook,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      SizedBox(
                        height: 50,
                        child: ElevatedButton.icon(
                          autofocus: true,
                          icon: const Icon(Icons.camera_rounded),
                          label: Text(
                            isFa ? 'ثبت دستی این صفحه' : 'Capture Page Now',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _isInitializingCamera ||
                                  _capturingPage ||
                                  (widget.singlePage &&
                                      _cameraController == null)
                              ? null
                              : _capturePageManually,
                        ),
                      ),
                      if (!widget.singlePage) const SizedBox(height: 10),
                      if (!widget.singlePage)
                        SizedBox(
                          height: 46,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.add_photo_alternate_rounded),
                            label: Text(
                              isFa
                                  ? 'افزودن صفحات کتاب از فایل‌های دستگاه'
                                  : 'Add Book Pages from Device Files',
                            ),
                            onPressed:
                                _capturingPage ? null : _pickPagesFromFiles,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
