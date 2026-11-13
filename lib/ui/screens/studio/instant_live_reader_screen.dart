import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/a11y/reader_feedback.dart';
import '../../../services/ocr/camera_frame_capture.dart';
import '../../../services/ocr/camera_diagnostics.dart';
import '../../../services/ocr/camera_scene_ocr.dart';
import '../../../services/ocr/camera_lighting.dart';
import '../../../services/ocr/onnx_text_detector_service.dart';
import '../../../services/ocr/ocr_service.dart';
import '../../../services/ocr/page_turn_tracker.dart';
import '../../../services/ocr/live_text_tracker.dart';
import '../../../services/ocr/camera_lifecycle.dart';
import '../../../services/diagnostics_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/ai/ai_access.dart';
import '../../../services/ai/online_access_service.dart';
import '../../widgets/online_access_guard.dart';
import '../../../services/tts/espeak_tts_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/accessible_output_text.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/camera_light_button.dart';
import '../../widgets/in_app_camera_screen.dart';
import '../../widgets/tts_playback_bar.dart';

class _EscapeBackIntent extends Intent {
  const _EscapeBackIntent();
}

/// Camera reader using the user-selected online or offline recognition service.
/// Feedback respects internal TTS settings and otherwise uses the screen reader.
class InstantLiveReaderScreen extends StatefulWidget {
  final void Function(String detectedText)? onSaveToNotes;

  const InstantLiveReaderScreen({
    super.key,
    this.onSaveToNotes,
  });

  @override
  State<InstantLiveReaderScreen> createState() =>
      _InstantLiveReaderScreenState();
}

class _InstantLiveReaderScreenState extends State<InstantLiveReaderScreen>
    with WidgetsBindingObserver {
  static const _unconfirmedPreviewConfidence = .94;
  int _cameraGeneration = 0;
  int _scanGeneration = 0;
  Timer? _recoveryTimer;
  int _cameraFailures = 0;
  final _cameraSession = DocumentCameraSession();
  CameraPreviewSampler? _previewSampler;
  bool _isOpeningSnapshot = false;
  DateTime _screenReaderReadingUntil = DateTime.fromMillisecondsSinceEpoch(0);
  CameraController? _cameraController;
  final _frameCapture = CameraFrameCapture();
  final _spokenText = LiveTextTracker();
  String? _queuedText;
  bool _startingSpeech = false;
  bool _isRefiningOnline = false;
  String? _nextReadAnnouncement;
  String? _pendingWorkStatus;
  bool _announcedText = false;
  bool _announcedWaiting = false;
  Timer? _recognitionProgressTimer;
  int _previewMisses = 0;
  DateTime? _lastQualityRead;
  DateTime _lastOnlineAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isInitializingCamera = true;
  bool _cameraPermissionBlocked = false;

  Timer? _scanTimer;
  bool _isScanningFrame = false;
  bool _isPaused = false;
  bool _isReadingDetectedText = false;

  String _lastDetectedText = '';
  String _lastSpokenSignature = '';
  String? _unconfirmedText;
  String? _replacementText;
  String _currentGuidanceMessage = '';
  DateTime _lastGuidanceSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastErrorSpokenAt;
  String? _lastSpokenGuidance;
  Uint8List? _prevThumb64;
  Duration _retryDelay = Duration.zero;
  Uint8List? _lastProcessedThumbnail;
  DateTime _lastRecognitionAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  Uint8List? _lastReadThumbnail;
  DateTime _lastReadAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    EspeakTtsService.isSpeakingNotifier.addListener(_onTtsSpeakingChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initLiveCamera();
    });
  }

  void _onTtsSpeakingChanged() {
    if (!EspeakTtsService.isSpeakingNotifier.value) {
      _isReadingDetectedText = false;
      if (mounted) _flushSpeech();
    }
  }

  void _flushSpeech() {
    if (!mounted ||
        _isPaused ||
        _startingSpeech ||
        (_queuedText == null && _pendingWorkStatus == null) ||
        EspeakTtsService.isSpeakingNotifier.value ||
        DateTime.now().isBefore(_screenReaderReadingUntil)) {
      return;
    }
    final workStatus = _pendingWorkStatus;
    _pendingWorkStatus = null;
    String? utterance;
    if (_queuedText == null) {
      utterance = workStatus;
    } else {
      final text = _spokenText.takeUnread(_queuedText!);
      if (text.isEmpty) {
        _queuedText = null;
        _nextReadAnnouncement = null;
        if (!_announcedWaiting || workStatus != null) {
          _announcedWaiting = true;
          final isFa = AppLocalizations.of(context).isPersian;
          final waiting = _isRefiningOnline
              ? (isFa
                  ? 'خواندن تمام شد. منتظر پاسخ هوش مصنوعی هستم.'
                  : 'Reading complete. Waiting for the AI response.')
              : (isFa
                  ? 'خواندن تمام شد. منتظر متن جدید هستم.'
                  : 'Reading complete. Waiting for new text.');
          utterance = workStatus == null ? waiting : '$workStatus $waiting';
          setState(() => _currentGuidanceMessage = utterance!);
        }
      } else {
        final prefix = [_nextReadAnnouncement, workStatus]
            .whereType<String>()
            .toSet()
            .join(' ');
        _nextReadAnnouncement = null;
        _announcedWaiting = false;
        utterance = prefix.isEmpty ? text : '$prefix $text';
      }
    }
    if (utterance == null || utterance.isEmpty) return;
    _startingSpeech = true;
    unawaited(_speakFeedback(utterance, isDetectedText: true)
        .whenComplete(() => _startingSpeech = false));
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    _recognitionProgressTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _cameraGeneration++;
    EspeakTtsService.isSpeakingNotifier.removeListener(_onTtsSpeakingChanged);
    _scanTimer?.cancel();
    unawaited(_cameraSession.close());
    EspeakTtsService.stop();
    super.dispose();
  }

  Future<void> _speakFeedback(String message,
      {bool isDetectedText = false}) async {
    if (!mounted || message.trim().isEmpty) return;
    final settings = context.read<SettingsService>();
    if (isDetectedText && !settings.enableInternalTts) {
      final seconds = (message.split(RegExp(r'\s+')).length * 60 / 160)
          .ceil()
          .clamp(2, 120);
      _screenReaderReadingUntil =
          DateTime.now().add(Duration(seconds: seconds));
    }
    await ReaderFeedback.speak(context, message, settings,
            assertive: isDetectedText, diagnosticSource: 'live-reader')
        .then((_) {
      if (mounted) {
        _isReadingDetectedText =
            isDetectedText && EspeakTtsService.isSpeakingNotifier.value;
      }
    });
  }

  bool get _onAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (!_cameraSession.suspend(reopen: !_isOpeningSnapshot)) return;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
      _cameraGeneration++;
      _scanTimer?.cancel();
      _unconfirmedText = null;
      _cameraController = null;
      _previewSampler = null;
      _prevThumb64 = null;
      unawaited(_cameraSession.close());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_cameraSession.resume().then<void>((reopen) async {
        if (reopen && mounted && !_isOpeningSnapshot) {
          await _initLiveCamera(allowPermissionPrompt: false);
        }
      }));
    }
  }

  Future<void> _handleBack() async {
    final l10n = AppLocalizations.of(context);
    final sectionName =
        l10n.isPersian ? 'خوانش زنده دوربین' : 'Instant Live Camera Reader';
    final confirmed = await showSafeConfirmDialog(
      context,
      title: l10n.isPersian ? 'خروج از $sectionName' : 'Exit from $sectionName',
      message: l10n.isPersian
          ? 'آیا می‌خواهید از بخش «$sectionName» خارج شوید؟'
          : 'Are you sure you want to exit from "$sectionName"?',
      confirmLabel: l10n.translate('exit_section_btn'),
    );
    if (confirmed && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _initLiveCamera(
      {bool accessAlreadyChecked = false,
      bool allowPermissionPrompt = true}) async {
    if (!mounted || !_cameraSession.beginStartup()) return;
    final l10n = AppLocalizations.of(context);
    final settings = context.read<SettingsService>();
    setState(() {
      _cameraPermissionBlocked = false;
      _isInitializingCamera = settings.isOfflineMode || accessAlreadyChecked;
      _currentGuidanceMessage = _isInitializingCamera
          ? l10n.tx('Starting Instant Live Camera Reader...',
              'در حال راه‌اندازی دوربین خوانش زنده...')
          : l10n.tx('Checking online access.', 'در حال بررسی دسترسی آنلاین.');
    });

    final generation = ++_cameraGeneration;
    try {
      if (!accessAlreadyChecked &&
          !await OnlineAccessGuard.require(context, settings,
              task: OnlineTask.ocr)) {
        if (!mounted || generation != _cameraGeneration) return;
        setState(() {
          _isInitializingCamera = false;
          _isPaused = true;
          _currentGuidanceMessage = OnlineAccessGuard.failureFor(context) ??
              l10n.tx('Online access check cancelled. Resume to try again.',
                  'بررسی دسترسی آنلاین لغو شد. برای تلاش دوباره خوانش را از سر بگیرید.');
        });
        return;
      }
      if (!mounted || generation != _cameraGeneration) return;
      setState(() {
        _isInitializingCamera = true;
        _currentGuidanceMessage = l10n.tx(
            'Starting Instant Live Camera Reader...',
            'در حال راه‌اندازی دوربین خوانش زنده...');
      });
      final cameras = await availableCameras();
      if (!mounted || generation != _cameraGeneration) return;
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _isInitializingCamera = false;
          _currentGuidanceMessage = l10n.isPersian
              ? 'دوربینی روی این دستگاه یافت نشد. می‌توانید تصویر مورد نظر را از فایل‌ها انتخاب کنید تا بلافاصله خوانده شود.'
              : 'No camera detected on this device. Select an image from your files to read it immediately.';
        });
        _speakFeedback(_currentGuidanceMessage);
        return;
      }

      final selectedCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = await _cameraSession.open(
        selectedCamera,
        presets: _onAndroid
            ? const [ResolutionPreset.veryHigh, ResolutionPreset.high]
            : const [ResolutionPreset.high, ResolutionPreset.medium],
        flashMode: FlashMode.off,
        allowPermissionPrompt: allowPermissionPrompt,
      );
      if (controller == null || !mounted || generation != _cameraGeneration) {
        return;
      }
      if (_onAndroid && settings.isOfflineMode) {
        unawaited(OnnxTextDetectorService.ensureInitialized());
      }
      final sampler = _onAndroid ? CameraPreviewSampler() : null;
      await sampler?.start(controller);
      if (!mounted || generation != _cameraGeneration) return;
      _previewSampler = sampler;

      final readyMsg = l10n.isPersian
          ? 'خوانش زنده فعال شد. دوربین را مقابل متن بگیرید.'
          : 'Live Camera Reader active. Point the camera at any text.';

      setState(() {
        _cameraController = controller;
        _isInitializingCamera = false;
        _currentGuidanceMessage = readyMsg;
      });

      _lastGuidanceSpokenAt = DateTime.now();
      _lastSpokenGuidance = readyMsg;
      if (!_isPaused) _speakFeedback(readyMsg);
      _startPeriodicLiveScan();
    } catch (error) {
      if (!mounted || generation != _cameraGeneration) return;
      _cameraController = null;
      _previewSampler = null;
      await _cameraSession.close();
      if (!mounted || generation != _cameraGeneration) return;
      if (isCameraPermissionError(error)) {
        _reportCameraPermissionError(error, l10n.isPersian);
        return;
      }
      debugPrint('Live camera initialization: $error');
      final fallbackMsg = l10n.isPersian
          ? 'دسترسی به دوربین زنده امکان‌پذیر نشد. می‌توانید تصویر را از دستگاه انتخاب کنید تا فوراً خوانده شود.'
          : 'Live camera could not be started on this device. You can select an image file to read immediately.';
      setState(() {
        _isInitializingCamera = false;
        _currentGuidanceMessage = fallbackMsg;
      });
      _speakFeedback('$fallbackMsg ($error)');
    } finally {
      if (_cameraSession.finishStartup() && mounted) {
        unawaited(_initLiveCamera(allowPermissionPrompt: false));
      }
    }
  }

  void _startPeriodicLiveScan() {
    _scanTimer?.cancel();
    final streaming = _cameraController?.value.isStreamingImages ?? false;
    _scanTimer = Timer.periodic(
      Duration(milliseconds: streaming ? 450 : 1500),
      (_) {
        _flushSpeech();
        final thumb = _previewSampler?.latest;
        if (!_isPaused && thumb != null && CameraLighting.isLowLight(thumb)) {
          final isFa = AppLocalizations.of(context).isPersian;
          _showGuidance(isFa
              ? 'نور کم است. چراغ دوربین را روشن کنید یا نور محیط را بیشتر کنید.'
              : 'Low light. Turn on the camera light or increase room lighting.');
        }
        _captureAndRecognizeLiveFrame();
      },
    );
  }

  Future<void> _captureAndRecognizeLiveFrame(
      {bool manualTrigger = false}) async {
    if (!mounted || (_isPaused && !manualTrigger) || _isScanningFrame) return;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      if (manualTrigger) {
        await _pickFallbackImage();
      }
      return;
    }

    _isScanningFrame = true;
    final generation = _cameraGeneration;
    final scanGeneration = _scanGeneration;
    final settings = context.read<SettingsService>();
    final offline = settings.isOfflineMode;
    final isFa = AppLocalizations.of(context).isPersian;
    bool current() =>
        mounted &&
        generation == _cameraGeneration &&
        scanGeneration == _scanGeneration;
    try {
      if (!offline) {
        if (!manualTrigger &&
            DateTime.now().difference(_lastOnlineAttempt).inSeconds < 4) {
          return;
        }
        try {
          await OnlineAccessService.ensure(settings, task: OnlineTask.ocr);
        } catch (error) {
          if (current()) {
            await _pauseForOnlineError(
                AiServiceException.fromError(error).message(isFa));
          }
          return;
        }
        if (!current() || settings.isOfflineMode) return;
      }
      final preview = manualTrigger ? null : _previewSampler?.latest;
      final frame = offline && !manualTrigger
          ? await _previewSampler?.sampleFrame()
          : null;
      if (!current()) return;
      Uint8List? bytes;
      Future<Uint8List> capture() async {
        final photo = await CameraFrameCapture.capture(controller);
        if (current()) {
          _cameraFailures = 0;
          _recoveryTimer?.cancel();
          _recoveryTimer = null;
        }
        return photo;
      }

      if (preview == null) bytes = await capture();
      if (!current()) return;
      await _processFrame(
        preview: preview,
        bytes: bytes,
        capture: capture,
        forceSpeak: manualTrigger,
        isCurrent: current,
        frame: frame,
      );
    } catch (error) {
      if (generation == _cameraGeneration &&
          scanGeneration == _scanGeneration) {
        _reportError(error);
      }
    } finally {
      _recognitionProgressTimer?.cancel();
      _isScanningFrame = false;
    }
  }

  Future<void> _processFrame({
    Uint8List? preview,
    Uint8List? bytes,
    Future<Uint8List> Function()? capture,
    bool forceSpeak = false,
    bool Function()? isCurrent,
    CameraLumaFrame? frame,
  }) async {
    bool current() => mounted && (isCurrent?.call() ?? true);
    if (!current()) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final l10n = AppLocalizations.of(context);
    final isFa = l10n.isPersian;
    final offline = settings.isOfflineMode;

    if (!offline) {
      try {
        await OnlineAccessService.ensure(settings, task: OnlineTask.ocr);
      } catch (error) {
        if (current()) {
          await _pauseForOnlineError(
              AiServiceException.fromError(error).message(isFa));
        }
        return;
      }
      if (!current() || settings.isOfflineMode) return;
    }

    final prev = _prevThumb64;
    final thumb = preview ?? await CameraFrameCapture.analyzePhoto(bytes!);
    if (!current()) return;
    if (thumb == null) {
      throw const FormatException('The camera image could not be decoded.');
    }
    final guidance = _evaluateLiveFrameCue(thumb, prev, isFa);
    CameraDiagnostics.event('live.guidance', {
      'message': guidance.message,
      'meanLuma': thumb.fold<int>(0, (a, b) => a + b) / thumb.length,
      'offline': settings.isOfflineMode,
      'hasVideoFrame': frame != null,
    });
    if (!forceSpeak) _prevThumb64 = thumb;

    final moving =
        prev != null && PageTurnTracker.imageDifference(prev, thumb) > .12;
    final elapsed = DateTime.now().difference(_lastRecognitionAttempt);
    if (!forceSpeak && moving && elapsed < const Duration(milliseconds: 900)) {
      _showGuidance(guidance.message);
      return;
    }
    final lastRead = _lastReadThumbnail;
    if (!forceSpeak &&
        lastRead != null &&
        !moving &&
        PageTurnTracker.imageDifference(lastRead, thumb) > .2) {
      _spokenText.reset();
      _lastSpokenSignature = '';
      _queuedText = null;
    }
    if (!forceSpeak &&
        lastRead != null &&
        DateTime.now().difference(_lastReadAt).inMilliseconds < 700 &&
        PageTurnTracker.imageDifference(lastRead, guidance.thumb64) < 0.012) {
      return;
    }

    final processed = _lastProcessedThumbnail;
    if (!forceSpeak &&
        processed != null &&
        PageTurnTracker.imageDifference(processed, guidance.thumb64) < 0.009 &&
        DateTime.now().difference(_lastRecognitionAttempt) < _retryDelay) {
      return;
    }
    if (_lastDetectedText.isEmpty && !forceSpeak) {
      _showGuidance(guidance.message);
    }
    if (offline && frame == null) bytes ??= await capture!();
    if (!current()) return;
    _lastProcessedThumbnail = guidance.thumb64;
    _lastRecognitionAttempt = DateTime.now();
    late ScanRecognitionResult result;
    CameraTextEdge? clippedText;
    if (!offline) {
      _isRefiningOnline = true;
      _lastOnlineAttempt = DateTime.now();
      _reportWork(
          l10n.tx('Sending the image to AI. Please wait for the response.',
              'تصویر برای هوش مصنوعی ارسال می‌شود. لطفاً منتظر پاسخ بمانید.'),
          announcement: l10n.tx('Reading with AI. Please wait.',
              'در حال خواندن با هوش مصنوعی. لطفاً منتظر بمانید.'));
      _flushSpeech();
      try {
        bytes ??= await capture!();
        result = await _recognizePhoto(bytes, settings, isFa, fast: false);
      } finally {
        _isRefiningOnline = false;
      }
      if (!current() || settings.isOfflineMode) return;
      if (result.didFail) {
        await _pauseForOnlineError(result.errorMessage ??
            l10n.tx('The selected AI service could not read this image.',
                'سرویس هوش مصنوعی انتخاب‌شده نتوانست این تصویر را بخواند.'));
        return;
      }
    } else {
      _recognitionProgressTimer?.cancel();
      _recognitionProgressTimer = Timer(const Duration(seconds: 3), () {
        if (!current() ||
            _isPaused ||
            _isReadingDetectedText ||
            DateTime.now().isBefore(_screenReaderReadingUntil)) {
          return;
        }
        final message = isFa
            ? 'در حال تشخیص متن روی گوشی هستم. دوربین را ثابت نگه دارید.'
            : 'Recognizing text on this device. Hold the camera steady.';
        _showGuidance(message,
            forceSpeak: _lastSpokenGuidance != message &&
                DateTime.now().difference(_lastGuidanceSpokenAt).inSeconds >=
                    3);
      });
      result = frame != null
          ? await CameraFrameCapture.recognizePreview(frame,
              onClippedText: (edge) => clippedText = edge,
              onPartial: (partial) {
                if (!current() ||
                    _isPaused ||
                    _lastDetectedText.isNotEmpty ||
                    (partial.confidence ?? 0) < _unconfirmedPreviewConfidence ||
                    !settings.isOfflineMode) {
                  return;
                }
                _announcedText = true;
                _nextReadAnnouncement = l10n.tx('Text found.', 'متن پیدا شد.');
                setState(() {
                  _lastDetectedText = partial.text;
                  _currentGuidanceMessage = l10n.tx(
                      'Reading the text. Checking the remaining lines.',
                      'متن در حال خواندن است. خط‌های بعدی هم بررسی می‌شوند.');
                });
                _queuedText = partial.text;
                _flushSpeech();
              })
          : await _recognizePhoto(bytes!, settings, isFa, fast: !forceSpeak);
      _recognitionProgressTimer?.cancel();
      if (!current() || !settings.isOfflineMode) return;
    }
    final latestAfterRead = _previewSampler?.latest;
    if (frame != null &&
        latestAfterRead != null &&
        PageTurnTracker.imageDifference(thumb, latestAfterRead) > .15) {
      return;
    }
    if (clippedText != null) {
      _previewMisses = 0;
      _unconfirmedText = null;
      final message = switch (clippedText!) {
        CameraTextEdge.left => l10n.tx(
            'Text is cut off on the left. Move the phone a little left.',
            'نوشته از چپ بریده شده است. گوشی را کمی به چپ ببرید.'),
        CameraTextEdge.right => l10n.tx(
            'Text is cut off on the right. Move the phone a little right.',
            'نوشته از راست بریده شده است. گوشی را کمی به راست ببرید.'),
        CameraTextEdge.both => l10n.tx(
            'Text is cut off on both sides. Move the phone a little farther away.',
            'نوشته از دو طرف بریده شده است. گوشی را کمی دورتر ببرید.'),
      };
      _showGuidance(message);
      return;
    }
    var usedQualityPhoto = false;
    if (frame != null && offline) {
      _previewMisses = result.hasText ? 0 : _previewMisses + 1;
      final lastQuality = _lastQualityRead;
      if ((_previewMisses >= 2 || result.didFail) &&
          (lastQuality == null ||
              DateTime.now().difference(lastQuality).inSeconds >= 4)) {
        _showGuidance(
          l10n.tx(
            'Checking a focused, full-resolution photo. Hold still.',
            'در حال بررسی عکس اصلی با فوکوس دقیق‌تر. گوشی را ثابت نگه دارید.',
          ),
          forceSpeak: !_isReadingDetectedText &&
              !DateTime.now().isBefore(_screenReaderReadingUntil),
        );
        final photo =
            await CameraFrameCapture.capture(_cameraController!, refocus: true);
        if (!current()) return;
        _cameraFailures = 0;
        _recoveryTimer?.cancel();
        _recoveryTimer = null;
        result = await _recognizePhoto(photo, settings, isFa,
            fast: false, offline: true);
        _lastQualityRead = DateTime.now();
        usedQualityPhoto = true;
        final latest = _previewSampler?.latest;
        if (!current() ||
            offline != settings.isOfflineMode ||
            (latest != null &&
                PageTurnTracker.imageDifference(thumb, latest) > .15)) {
          return;
        }
      }
    }
    _lastRecognitionAttempt = DateTime.now();
    _retryDelay = result.hasText
        ? const Duration(milliseconds: 650)
        : const Duration(milliseconds: 900);
    final recognizedText = result.text;
    if (!result.hasText && result.didFail) {
      _unconfirmedText = null;
      _reportError(result.errorMessage ?? StateError('Recognition failed.'));
      return;
    }

    final cleaned = recognizedText.trim();

    if (!RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(cleaned)) {
      _unconfirmedText = null;
      final message = CameraLighting.isLowLight(thumb)
          ? guidance.message
          : (result.detectedTextRegions ?? 0) > 0
              ? l10n.tx(
                  'Text is in view, but not clear enough yet. Hold still or move a little closer.',
                  'نوشته در تصویر دیده می‌شود، ولی هنوز خوانا نیست. گوشی را ثابت نگه دارید یا کمی نزدیک‌تر ببرید.')
              : l10n.tx(
                  'No readable text in view yet. Move the phone slowly to find the text.',
                  'هنوز نوشتهٔ خوانایی در تصویر نیست. گوشی را به‌آرامی جابه‌جا کنید تا نوشته پیدا شود.');
      _showGuidance(message, forceSpeak: forceSpeak);
      return;
    }

    final signature = _normalizeSignature(cleaned);
    if (!forceSpeak &&
        PageTurnTracker.sameText(signature, _lastSpokenSignature)) {
      _unconfirmedText = null;
      return;
    }

    final confidence = result.confidence;
    final minimumConfidence =
        offline && frame != null ? _unconfirmedPreviewConfidence : .68;
    if (!forceSpeak &&
        !usedQualityPhoto &&
        confidence != null &&
        confidence < minimumConfidence &&
        (_unconfirmedText == null ||
            !PageTurnTracker.sameText(signature, _unconfirmedText!,
                minimumSimilarity: .86))) {
      _unconfirmedText = signature;
      _retryDelay = Duration.zero;
      final checking =
          l10n.tx('Checking the text again…', 'در حال بررسی دوبارهٔ متن…');
      if (_currentGuidanceMessage != checking) {
        setState(() => _currentGuidanceMessage = checking);
      }
      return;
    }
    _unconfirmedText = null;
    if (!forceSpeak &&
        LiveTextTracker.replacesView(_lastDetectedText, cleaned)) {
      if (offline &&
          (_replacementText == null ||
              !PageTurnTracker.sameText(signature, _replacementText!,
                  minimumSimilarity: .8))) {
        _replacementText = signature;
        _retryDelay = Duration.zero;
        return;
      }
      _spokenText.reset();
      _nextReadAnnouncement = l10n.tx('New text found.', 'متن جدید پیدا شد.');
      _queuedText = null;
      _screenReaderReadingUntil = DateTime.fromMillisecondsSinceEpoch(0);
      _isReadingDetectedText = false;
      await EspeakTtsService.stop();
      if (!current()) return;
    }
    _replacementText = null;
    if (!_announcedText) {
      _announcedText = true;
      _nextReadAnnouncement = l10n.tx('Text found.', 'متن پیدا شد.');
    }
    _lastSpokenGuidance = null;
    _lastSpokenSignature = signature;
    _lastReadThumbnail = guidance.thumb64;
    _lastReadAt = DateTime.now();
    setState(() {
      _lastDetectedText = cleaned;
      _currentGuidanceMessage = isFa
          ? 'متن شناسایی شد و در حال خوانش است.'
          : 'Text detected and reading aloud.';
    });

    try {
      await HapticFeedback.selectionClick();
    } catch (_) {}

    if (!current()) {
      return;
    }
    if (forceSpeak) _spokenText.reset();
    _queuedText = cleaned;
    _flushSpeech();
  }

  Future<ScanRecognitionResult> _recognizePhoto(
          Uint8List bytes, SettingsService settings, bool isFa,
          {required bool fast, bool? offline}) =>
      _frameCapture.recognize(
        imageBytes: bytes,
        isOfflineMode: offline ?? settings.isOfflineMode,
        activeProvider: settings.activeProvider,
        apiKey: settings.getApiKey(settings.activeProvider),
        modelName: settings.getSelectedModel(settings.activeProvider),
        customBaseUrl: settings.customBaseUrl,
        thinkingEffort: settings.thinkingEffort,
        isPersian: isFa,
        useScanoraCloud: settings.useScanoraCloudOcr,
        useFastModel: fast,
        cameraMode: CameraOcrMode.live,
        allowInteractiveBrowserAuth: false,
      );

  void _reportWork(String message, {String? announcement}) {
    if (!mounted) return;
    if (_currentGuidanceMessage != message) {
      setState(() => _currentGuidanceMessage = message);
    }
    _pendingWorkStatus = announcement ?? message;
  }

  Future<void> _pauseForOnlineError(String message) async {
    if (!mounted) return;
    _recognitionProgressTimer?.cancel();
    _scanTimer?.cancel();
    _cameraGeneration++;
    _queuedText = null;
    _pendingWorkStatus = null;
    _nextReadAnnouncement = null;
    _screenReaderReadingUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _cameraController = null;
    _previewSampler = null;
    setState(() {
      _isPaused = true;
      _isInitializingCamera = false;
      _currentGuidanceMessage = message;
    });
    unawaited(_cameraSession.close());
    await EspeakTtsService.stop();
    if (mounted) await _speakFeedback(message, isDetectedText: true);
  }

  String _normalizeSignature(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void _showGuidance(String message, {bool forceSpeak = false}) {
    if (_currentGuidanceMessage != message) {
      setState(() => _currentGuidanceMessage = message);
    }
    final now = DateTime.now();
    if (forceSpeak ||
        ((message != _lastSpokenGuidance ||
                now.difference(_lastGuidanceSpokenAt).inSeconds >= 10) &&
            !_isReadingDetectedText &&
            !now.isBefore(_screenReaderReadingUntil) &&
            now.difference(_lastGuidanceSpokenAt) >=
                const Duration(seconds: 6))) {
      _lastGuidanceSpokenAt = now;
      _lastSpokenGuidance = message;
      _speakFeedback(message);
    }
  }

  void _reportError(Object error) {
    if (!mounted) return;
    if (isCameraPermissionError(error)) {
      _reportCameraPermissionError(
          error, AppLocalizations.of(context).isPersian);
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
        _scanTimer?.cancel();
        _cameraController = null;
        _previewSampler = null;
        _prevThumb64 = null;
        unawaited(_cameraSession.close());
        await _initLiveCamera(allowPermissionPrompt: false);
      });
    }
    DiagnosticsService.record('camera.live', error, StackTrace.current);
    final isFa = AppLocalizations.of(context).isPersian;
    final message = isFa
        ? 'خواندن تصویر انجام نشد. دوربین، اتصال اینترنت و سرویس انتخابی را بررسی کنید.'
        : 'The image could not be read. Check your camera, internet connection and selected service.';
    setState(() => _currentGuidanceMessage = message);
    final now = DateTime.now();
    final lastError = _lastErrorSpokenAt;
    if (lastError == null ||
        now.difference(lastError) >= const Duration(seconds: 6)) {
      _lastErrorSpokenAt = now;
      _speakFeedback(message);
    }
  }

  void _reportCameraPermissionError(Object error, bool isPersian) {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _scanTimer?.cancel();
    _recognitionProgressTimer?.cancel();
    _queuedText = null;
    _pendingWorkStatus = null;
    _nextReadAnnouncement = null;
    _cameraGeneration++;
    _cameraController = null;
    _previewSampler = null;
    unawaited(_cameraSession.close());
    final message = cameraPermissionMessage(isPersian, error);
    setState(() {
      _cameraPermissionBlocked = true;
      _isInitializingCamera = false;
      _currentGuidanceMessage = message;
    });
    unawaited(_speakFeedback(message, isDetectedText: true));
  }

  Future<void> _pickFallbackImage() async {
    if (_isScanningFrame) return;
    _isScanningFrame = true;
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result.isEmpty || !mounted) return;
      final bytes = await result.first.readAsBytes();
      if (bytes.isNotEmpty && mounted) {
        await _processFrame(bytes: bytes, forceSpeak: true);
      }
    } catch (error) {
      _reportError(error);
    } finally {
      _isScanningFrame = false;
    }
  }

  Future<void> _openInAppCameraSnapshot(AppLocalizations l10n) async {
    if (_cameraController != null) {
      await _captureAndRecognizeLiveFrame(manualTrigger: true);
      return;
    }
    if (_isScanningFrame || _isInitializingCamera) return;
    _isScanningFrame = true;
    _isOpeningSnapshot = true;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    try {
      final bytes = await InAppCameraScreen.capture(context,
          title: l10n.isPersian
              ? 'ثبت عکس برای خوانش فوری'
              : 'Capture Frame for Instant Reading');
      if (bytes != null && bytes.isNotEmpty && mounted) {
        await _processFrame(bytes: bytes, forceSpeak: true);
      }
    } catch (error) {
      _reportError(error);
    } finally {
      _isOpeningSnapshot = false;
      _isScanningFrame = false;
    }
  }

  Future<void> _togglePause(AppLocalizations l10n) async {
    if (_isPaused &&
        !await OnlineAccessGuard.require(
            context, context.read<SettingsService>(),
            task: OnlineTask.ocr)) {
      return;
    }
    if (!mounted) return;
    _scanGeneration++;
    _spokenText.reset();
    _queuedText = null;
    _pendingWorkStatus = null;
    _nextReadAnnouncement = null;
    _announcedText = false;
    _announcedWaiting = false;
    _recognitionProgressTimer?.cancel();
    _unconfirmedText = null;
    final paused = l10n.tx('Live reading paused.', 'خوانش زنده متوقف شد.');
    final resumed =
        l10n.tx('Live reading resumed.', 'خوانش زنده از سر گرفته شد.');
    setState(() {
      _isPaused = !_isPaused;
      _currentGuidanceMessage = _isPaused ? paused : resumed;
    });
    if (_isPaused) {
      _screenReaderReadingUntil = DateTime.fromMillisecondsSinceEpoch(0);
      EspeakTtsService.stop();
      _speakFeedback(paused);
    } else {
      _lastOnlineAttempt = DateTime.fromMillisecondsSinceEpoch(0);
      _lastSpokenSignature = '';
      _lastProcessedThumbnail = null;
      if (_cameraController == null) {
        await _initLiveCamera(accessAlreadyChecked: true);
        return;
      }
      _speakFeedback(resumed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFa = l10n.isPersian;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
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
                    isFa ? 'خوانش زنده دوربین' : 'Instant Live Camera Reader',
                  ),
                ),
                actions: [
                  if (_onAndroid)
                    CameraLightButton(controller: _cameraController),
                  if (!_cameraPermissionBlocked)
                    IconButton(
                      icon: Icon(_isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded),
                      tooltip: _isPaused
                          ? (isFa ? 'ادامه خوانش زنده' : 'Resume Live Scan')
                          : (isFa ? 'مکث خوانش زنده' : 'Pause Live Scan'),
                      onPressed: () => _togglePause(l10n),
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
                      // Live Audio Guidance & Status Card
                      Semantics(
                        container: true,
                        child: Card(
                          color: _isPaused
                              ? Colors.orange.withValues(alpha: 0.14)
                              : AppTheme.primaryCyan.withValues(alpha: 0.12),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                ExcludeSemantics(
                                  child: Icon(
                                    _isPaused
                                        ? Icons.pause_circle_filled_rounded
                                        : Icons.sensors_rounded,
                                    color: _isPaused
                                        ? Colors.orangeAccent
                                        : AppTheme.primaryCyan,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _currentGuidanceMessage.isNotEmpty
                                            ? _currentGuidanceMessage
                                            : (isFa
                                                ? 'دوربین زنده و راهنمای صوتی فعال است'
                                                : 'Live Camera & Audio Guidance Active'),
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        isFa
                                            ? 'برای خواندن فوری تابلوها، برچسب‌ها، مانیتور، نامه‌ها یا صفحات کتاب.'
                                            : 'For instant reading of signs, screens, labels, letters, or book pages.',
                                        style: TextStyle(
                                          fontSize: 12,
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

                      // Live Camera Preview or Fallback
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
                                height: 240,
                                width: double.infinity,
                                child: Center(
                                  child: CameraPreview(_cameraController!),
                                ),
                              ),
                            ),
                          ),
                        )
                      else if (!_cameraPermissionBlocked)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              children: [
                                const ExcludeSemantics(
                                  child: Icon(
                                    Icons.videocam_off_rounded,
                                    size: 42,
                                    color: Colors.orangeAccent,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  isFa
                                      ? 'دوربین زنده روی این دستگاه در دسترس نیست. می‌توانید تصویر مورد نظر را انتخاب کنید تا بلافاصله خوانده شود.'
                                      : 'Live camera unavailable on this device. Select an image file to read it immediately.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 14),

                      // Action & Control Buttons
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          if (!_cameraPermissionBlocked)
                            OutlinedButton.icon(
                              icon: Icon(_isPaused
                                  ? Icons.play_arrow_rounded
                                  : Icons.pause_rounded),
                              label: Text(
                                _isPaused
                                    ? (isFa
                                        ? 'ادامه خوانش خودکار'
                                        : 'Resume Auto Reading')
                                    : (isFa
                                        ? 'مکث خوانش خودکار'
                                        : 'Pause Auto Reading'),
                              ),
                              onPressed: () => _togglePause(l10n),
                            ),
                          if (!_cameraPermissionBlocked)
                            OutlinedButton.icon(
                              icon: const Icon(Icons.camera_alt_rounded),
                              label: Text(
                                isFa
                                    ? 'دوربین داخلی استاندارد'
                                    : 'Standard In-App Camera',
                              ),
                              onPressed: () => _openInAppCameraSnapshot(l10n),
                            ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.image_search_rounded),
                            label: Text(
                              isFa
                                  ? 'انتخاب تصویر از دستگاه'
                                  : 'Select Image from Device',
                            ),
                            onPressed: _pickFallbackImage,
                          ),
                          if (_lastDetectedText.isNotEmpty &&
                              widget.onSaveToNotes != null)
                            OutlinedButton.icon(
                              icon: const Icon(Icons.bookmark_add_rounded),
                              label: Text(
                                isFa
                                    ? 'ذخیره در یادداشت‌های هوشمند'
                                    : 'Save to Smart Notes',
                              ),
                              onPressed: () {
                                widget.onSaveToNotes!(_lastDetectedText);
                              },
                            ),
                          if (_lastDetectedText.isNotEmpty)
                            OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.check_circle_outline_rounded),
                              label: Text(
                                isFa
                                    ? 'باز کردن این متن در بخش مطالعه'
                                    : 'Open Text in Reader',
                              ),
                              onPressed: () {
                                Navigator.of(context).pop(_lastDetectedText);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Latest Detected Text & Unified Audio Controller
                      if (_lastDetectedText.isNotEmpty) ...[
                        TtsPlaybackBar(
                          textToSpeak: _lastDetectedText,
                          title: isFa
                              ? 'متن تشخیص داده شده در لحظه'
                              : 'Live Detected Text',
                        ),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  isFa
                                      ? 'آخرین متن شناسایی‌شده'
                                      : 'Latest Detected Text',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: AppTheme.primaryCyan,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                AccessibleOutputText(
                                  text: _lastDetectedText,
                                  liveRegion: false,
                                  style: const TextStyle(
                                      fontSize: 16, height: 1.75),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              isFa
                                  ? 'دوربین را ثابت به سمت متن بگیرید. متن به‌صورت خودکار خوانده می‌شود.'
                                  : 'Hold the camera steady over the text. Reading starts automatically.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color,
                              ),
                            ),
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

  static _LiveGuidanceResult _evaluateLiveFrameCue(
    Uint8List gray,
    Uint8List? prevThumb64,
    bool isFa,
  ) {
    final lowLight = CameraLighting.isLowLight(gray);
    if (lowLight) {
      return _LiveGuidanceResult(
        message: isFa
            ? 'نور کم است. چراغ دوربین را روشن کنید یا نور محیط را بیشتر کنید.'
            : 'Low light. Turn on the camera light or increase room lighting.',
        thumb64: gray,
        hasStrongTextEdges: false,
      );
    }
    if (prevThumb64 != null &&
        PageTurnTracker.imageDifference(gray, prevThumb64) > .16) {
      return _LiveGuidanceResult(
        message: isFa ? 'دوربین را ثابت نگه دارید' : 'Hold camera steady',
        thumb64: gray,
        hasStrongTextEdges: false,
      );
    }

    return _LiveGuidanceResult(
      message: isFa
          ? 'دوربین فعال است؛ در حال جست‌وجوی نوشته. گوشی را به‌آرامی جابه‌جا کنید.'
          : 'Camera active. Looking for text. Move the phone slowly.',
      thumb64: gray,
      hasStrongTextEdges: false,
    );
  }
}

class _LiveGuidanceResult {
  final String message;
  final Uint8List thumb64;
  final bool hasStrongTextEdges;

  const _LiveGuidanceResult({
    required this.message,
    required this.thumb64,
    required this.hasStrongTextEdges,
  });
}
