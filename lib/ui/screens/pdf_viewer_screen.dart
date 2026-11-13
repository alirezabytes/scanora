import '../widgets/accessible_dropdown_field.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/app_localizations.dart';
import '../../models/bookmark_item.dart';
import '../../models/note_item.dart';
import '../../models/pdf_document.dart';
import '../../models/scan_history_item.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/export/docx_exporter.dart';
import '../../services/native_bridge_service.dart';
import '../../services/ocr/ocr_service.dart';
import '../../services/ocr/camera_frame_capture.dart';
import '../../services/ocr/captured_page_store.dart';
import '../../services/pdf/pdf_service.dart';
import '../../services/pdf/document_formats.dart';
import '../../services/pdf/document_image_loader.dart';
import '../../services/pdf/document_batch_processor.dart';
import '../../services/pdf/document_work.dart';
import '../../services/settings_service.dart';
import '../../services/storage/app_storage_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../hub/tool_routes.dart';
import '../theme/app_theme.dart';
import '../settings/reading_playback_settings_screen.dart';
import '../widgets/accessible_output_text.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/document_page_range_dialog.dart';
import '../widgets/accessible_page_number_field.dart';
import '../widgets/in_app_camera_screen.dart';
import '../widgets/online_access_guard.dart';
import '../widgets/output_file_name_field.dart';
import '../widgets/tts_playback_bar.dart';
import 'books_manager_screen.dart';
import 'studio/batch_book_scanner_screen.dart';
import 'studio/instant_live_reader_screen.dart';

typedef _StudioFile = ({
  String name,
  String? path,
  Future<Uint8List> Function() readAsBytes,
});

enum _ReaderAction {
  library,
  search,
  addBookmark,
  bookmarks,
  saveNote,
  copy,
  share,
  ocr,
  export,
  close
}

class PdfViewerScreen extends StatefulWidget {
  final GlobalKey<PdfViewerScreenState>? customKey;
  final List<String>? sharedFiles;
  final bool resumeSession;
  const PdfViewerScreen(
      {Key? key, this.customKey, this.sharedFiles, this.resumeSession = false})
      : super(key: key ?? customKey);

  @override
  State<PdfViewerScreen> createState() => PdfViewerScreenState();
}

class PdfViewerScreenState extends State<PdfViewerScreen>
    with RestorationMixin, WidgetsBindingObserver {
  SettingsService? _sessionSettings;
  final _savedBook = RestorableStringN(null);
  final _openPath = RestorableStringN(null);
  final _openPage = RestorableInt(0);
  final _openStart = RestorableInt(1);
  final _openEnd = RestorableInt(0);
  final _openAudioSecond = RestorableInt(0);
  bool _restoringBook = false;
  final _bookKeys = Expando<String>();
  final _pageWordCounts = Expando<int>();
  ProcessedPdfDocument? _finishedDocument;
  static final _words = RegExp(r'\S+');
  final _skippedText = Expando<List<TextRange>>();
  Timer? _readingClock;
  SettingsService? _readingSettings;
  String? _readingTitle;
  String? _readingDay;
  int _readingMilliseconds = 0;
  int _audioMilliseconds = 0;
  ProcessedPdfDocument? _document;
  ({String? path, Uint8List? bytes})? _pdfSource;
  List<Uint8List>? _photoPages;
  final _cameraOcr = CameraFrameCapture();
  List<Uint8List>? get _photoPagesBytes => _photoPages;
  set _photoPagesBytes(List<Uint8List>? value) {
    final previous = _photoPages;
    _photoPages = value;
    if (previous is CapturedPageStore && !identical(previous, value)) {
      unawaited(previous.close());
    }
  }

  bool _isLoading = false;
  bool _isOcringPage = false;
  double _processingProgress = 0.0;
  String _processingStatusText = '';
  int _currentPageIndex = 0; // 0-based
  int _operationGeneration = 0;
  DocumentWork? _work;
  int _lastPreparationPercent = -10;
  DateTime _lastProgressAnnouncement = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastProgressRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  void _preparationProgress(int percent) {
    if (!mounted || !_isLoading || _work?.isCancelled == true) return;
    final fa = AppLocalizations.of(context).isPersian;
    final message =
        fa ? 'آماده‌سازی صفحات: $percent درصد' : 'Preparing pages: $percent%';
    final now = DateTime.now();
    if (percent == 100 ||
        now.difference(_lastProgressRefresh).inMilliseconds >= 120) {
      _lastProgressRefresh = now;
      setState(() {
        _processingProgress = percent / 100;
        _processingStatusText = message;
      });
    }
    if (percent == 100 ||
        (percent >= _lastPreparationPercent + 10 &&
            now.difference(_lastProgressAnnouncement).inMilliseconds >= 1000)) {
      _lastPreparationPercent = percent;
      _lastProgressAnnouncement = now;
      _announceToScreenReader(message, progress: true);
    }
  }

  Future<Uint8List?> _renderPageImage(int index) async {
    final photos = _photoPagesBytes;
    if (photos != null && index < photos.length) {
      if (photos is CapturedPageStore) return photos.readPage(index);
      return photos[index];
    }
    final source = _pdfSource;
    if (source == null) return null;
    final path = source.path;
    return path != null
        ? NativeBridgeService.renderPdfPageAsPng(
            pdfPath: path, pageIndex: index)
        : NativeBridgeService.renderPdfPageToPng(source.bytes!, index);
  }

  Future<ScanRecognitionResult> _recognizePageImage(
    Uint8List bytes,
    SettingsService settings,
    AppLocalizations l10n, {
    required bool allowInteractiveBrowserAuth,
    void Function(int percent)? onProgress,
  }) {
    final provider = settings.activeProvider;
    final offline = settings.isOfflineMode;
    final key = settings.getApiKey(provider);
    final model = settings.getSelectedModel(provider);
    if (_photoPages is CapturedPageStore && !settings.documentLayout) {
      return _cameraOcr.recognize(
        imageBytes: bytes,
        isOfflineMode: offline,
        activeProvider: provider,
        apiKey: key,
        modelName: model,
        customBaseUrl: settings.customBaseUrl,
        thinkingEffort: settings.thinkingEffort,
        isPersian: l10n.isPersian,
        useScanoraCloud: settings.useScanoraCloudOcr,
        useFastModel: false,
        cameraMode: CameraOcrMode.book,
        allowInteractiveBrowserAuth: false,
        onProgress: onProgress,
      );
    }
    return OcrService.processImage(
      imageBytes: bytes,
      isOfflineMode: offline,
      activeProvider: provider,
      apiKey: key,
      modelName: model,
      customBaseUrl: settings.customBaseUrl,
      thinkingEffort: settings.thinkingEffort,
      isPersian: l10n.isPersian,
      useScanoraCloud: settings.useScanoraCloudOcr,
      preferResponsiveDocumentOcr: true,
      detectLayout: settings.documentLayout,
      allowInteractiveBrowserAuth: allowInteractiveBrowserAuth,
      onProgress: onProgress,
    );
  }

  static Future<String> _serializeBookPages(List<PdfPageInfo> pages) async {
    if (pages.fold(0, (size, page) => size + page.text.length) < 65536) {
      return _joinBookPages(pages);
    }
    return Isolate.run(() => _joinBookPages(pages));
  }

  static String _joinBookPages(List<PdfPageInfo> pages) => pages
      .map((page) => page.text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n\n--- [Page Break] ---\n\n');

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final List<int> _searchMatchingPages = [];

  final ValueNotifier<int> _highlightTick = ValueNotifier<int>(0);
  Timer? _highlightTimer;

  bool get hasActiveContent => _document != null || _work != null;

  Future<void> _finishDocumentWork(DocumentWork work) async {
    await work.finish();
    if (identical(_work, work)) _work = null;
  }

  Future<void> _cancelDocumentWork() async {
    final work = _work;
    if (work?.canCancel == false) return;
    final generation = _operationGeneration;
    if (!await confirmCancelOperation(context) ||
        !mounted ||
        generation != _operationGeneration ||
        !identical(_work, work)) {
      return;
    }
    if (work == null) {
      if (_isLoading) resetScreen();
      return;
    }
    if (!work.canCancel) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      work.cancel();
      _processingStatusText = l10n.tx('Cancelling…', 'در حال لغو…');
    });
  }

  @override
  String get restorationId => 'reader';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_savedBook, 'book');
    registerForRestoration(_openPath, 'path');
    registerForRestoration(_openPage, 'page');
    registerForRestoration(_openStart, 'start');
    registerForRestoration(_openEnd, 'end');
    registerForRestoration(_openAudioSecond, 'audioSecond');
    _sessionSettings = context.read<SettingsService>();
    if (!initialRestore || widget.sharedFiles != null) return;
    if (widget.resumeSession &&
        _savedBook.value == null &&
        _openPath.value == null) {
      final state = _sessionSettings?.readerSession('reader');
      if (state != null) {
        _savedBook.value = state['book'] as String?;
        _openPath.value = state['path'] as String?;
        _openPage.value = state['page'] as int? ?? 0;
        _openStart.value = state['start'] as int? ?? 1;
        _openEnd.value = state['end'] as int? ?? 0;
        _openAudioSecond.value = state['audioSecond'] as int? ?? 0;
      }
    }
    final book = _savedBook.value;
    final path = _openPath.value;
    if (book == null && path == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _document != null || _work != null) return;
      final settings = context.read<SettingsService>();
      final l10n = AppLocalizations.of(context);
      final item =
          settings.history.where((item) => item.id == book).firstOrNull;
      final second = _openAudioSecond.value;
      _restoringBook = true;
      try {
        if (item != null) {
          await _openSavedBook(item, settings, l10n, page: _openPage.value);
        } else if (path != null) {
          await _openFileFromPath(path, settings, l10n,
              page: _openPage.value,
              start: _openStart.value,
              end: _openEnd.value);
        }
        if (!mounted || _document == null) return;
        final page = _document!.pages[_currentPageIndex];
        if (second > 0 && settings.enableInternalTts && page.text.isNotEmpty) {
          await EspeakTtsService.stop();
          if (!mounted) return;
          await EspeakTtsService.seekToSecond(second, settings,
              fallbackText: _spokenPageText(page, settings, l10n),
              title: _document!.fileName);
        }
      } finally {
        _restoringBook = false;
      }
    });
  }

  void _storeReaderSession() {
    final settings = _sessionSettings;
    if (settings == null || widget.sharedFiles != null) return;
    final book = _savedBook.value;
    final path = _openPath.value;
    unawaited(settings.rememberReaderSession(
        'reader',
        book == null && path == null
            ? null
            : {
                'book': book,
                'path': path,
                'page': _openPage.value,
                'start': _openStart.value,
                'end': _openEnd.value,
                'audioSecond': _openAudioSecond.value,
              }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _storeReaderSession();
      _rememberBookPosition();
      _flushReadingTime();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    EspeakTtsService.playbackState.addListener(_onPlaybackStateChanged);
    EspeakTtsService.sessionCompletedTick.addListener(_onSessionCompleted);
    _readingClock = Timer.periodic(const Duration(seconds: 1), _trackReading);
    final paths = widget.sharedFiles;
    if (paths != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final files = paths.map((path) {
          final file = File(path);
          return (
            name: file.uri.pathSegments.last,
            path: path,
            readAsBytes: file.readAsBytes
          );
        }).toList(growable: false);
        _processStudioFiles(
          files,
          context.read<SettingsService>(),
          AppLocalizations.of(context),
          useRangeAndExportWizard: false,
        );
      });
    }
  }

  void _trackReading(Timer timer) {
    final document = _document;
    if (document == null ||
        _isLoading ||
        _isOcringPage ||
        document.pages[_currentPageIndex].text.trim().isEmpty) {
      _flushReadingTime();
      return;
    }
    final settings = _readingSettings ??= context.read<SettingsService>();
    final visible = ModalRoute.isCurrentOf(context) != false &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final listening = EspeakTtsService.playbackState.value.isPlaying &&
        EspeakTtsService.isPlayingText(_spokenPageText(
            document.pages[_currentPageIndex],
            settings,
            AppLocalizations.of(context)));
    if (!visible && !listening) {
      _flushReadingTime();
      return;
    }
    final now = DateTime.now();
    final day = DateUtils.dateOnly(now).toIso8601String().split('T').first;
    final bookKey = _bookKeys[document] ?? document.fileName;
    if (_readingTitle != bookKey || _readingDay != day) {
      _flushReadingTime();
      _readingTitle = bookKey;
      _readingDay = day;
    }
    if (visible) _readingMilliseconds += 1000;
    if (listening) _audioMilliseconds += 1000;
    if (math.max(_readingMilliseconds, _audioMilliseconds) >= 15000) {
      if (listening) _rememberBookPosition();
      _flushReadingTime();
    }
  }

  void _flushReadingTime() {
    if (_readingMilliseconds == 0 && _audioMilliseconds == 0) return;
    unawaited(_readingSettings!.addReadingTime(_readingDay!, _readingTitle!,
        _readingMilliseconds, _audioMilliseconds));
    _readingMilliseconds = 0;
    _audioMilliseconds = 0;
  }

  void _rememberBookPosition({bool finished = false}) {
    final settings = _sessionSettings;
    final document = _document;
    if (settings == null || document == null) return;
    final key = _bookKeys[document];
    if (key == null) return;
    if (finished) _finishedDocument = document;
    final completed = identical(_finishedDocument, document);
    var remainingWords = 0;
    var unreadPages = 0;
    for (var i = _currentPageIndex; i < document.pages.length; i++) {
      final page = document.pages[i];
      if (page.needsOcr && !page.ocrCompleted) unreadPages++;
      final count =
          _pageWordCounts[page] ??= _words.allMatches(page.text).length;
      if (i == _currentPageIndex) {
        remainingWords += completed
            ? 0
            : math.max(
                0,
                count -
                    _openAudioSecond.value * settings.effectiveTtsRate ~/ 60);
      } else {
        remainingWords += count;
      }
    }
    unawaited(settings.rememberBookPosition(key, {
      'page': _currentPageIndex,
      'second': _openAudioSecond.value,
      'rate': settings.effectiveTtsRate,
      'remainingWords': remainingWords,
      'unreadPages': unreadPages,
      'finished': completed,
    }));
  }

  void _onSessionCompleted() {
    if (!mounted || _document == null || _isLoading || _isOcringPage) return;
    final l10n = AppLocalizations.of(context);
    final readerSettings = Provider.of<SettingsService>(context, listen: false);
    if (!readerSettings.enableInternalTts ||
        EspeakTtsService.lastCompletedText !=
            _spokenPageText(
                    _document!.pages[_currentPageIndex], readerSettings, l10n)
                .trim()) {
      return;
    }
    if (readerSettings.autoAdvancePage &&
        _currentPageIndex < _document!.totalPages - 1) {
      _navigateToPage(_currentPageIndex + 1, continuePlayback: true);
    } else if (_currentPageIndex == _document!.totalPages - 1) {
      _rememberBookPosition(finished: true);
    }
  }

  void _onPlaybackStateChanged() {
    final state = EspeakTtsService.playbackState.value;
    final document = _document;
    if (mounted && document != null && state.isActive) {
      final text = _spokenPageText(document.pages[_currentPageIndex],
          context.read<SettingsService>(), AppLocalizations.of(context));
      if (EspeakTtsService.isActiveText(text)) {
        if (state.isPlaying && identical(_finishedDocument, document)) {
          _finishedDocument = null;
        }
        _openAudioSecond.value = state.currentSeconds;
      }
    }
    if (state.isPlaying && !state.isPaused) {
      _highlightTimer ??= Timer.periodic(
        const Duration(milliseconds: 90),
        (_) {
          if (mounted) {
            _highlightTick.value++;
          }
        },
      );
    } else {
      _highlightTimer?.cancel();
      _highlightTimer = null;
    }
    if (mounted) {
      _highlightTick.value++;
    }
  }

  void _announceToScreenReader(String message, {bool progress = false}) {
    if (!mounted || message.trim().isEmpty) return;
    if (progress && !context.read<SettingsService>().announceProgress) return;
    try {
      final direction = Directionality.of(context);
      AccessibilityService.announce(context, message,
          textDirection: direction, diagnosticSource: 'document-reader');
    } catch (_) {}
  }

  void resetScreen() {
    _rememberBookPosition();
    _flushReadingTime();
    _savedBook.value = null;
    _openPath.value = null;
    _openPage.value = 0;
    _openAudioSecond.value = 0;
    _openStart.value = 1;
    _openEnd.value = 0;
    _storeReaderSession();
    _work?.cancel();
    _work = null;
    _operationGeneration++;
    EspeakTtsService.stop();
    setState(() {
      _document = null;
      _pdfSource = null;
      _photoPagesBytes = null;
      _currentPageIndex = 0;

      _searchQuery = '';
      _searchController.clear();
      _searchMatchingPages.clear();
      _isLoading = false;
      _isOcringPage = false;
      _processingProgress = 0.0;
      _processingStatusText = '';
    });
  }

  String _formatPageWithNumber(
      PdfPageInfo page, SettingsService settings, AppLocalizations l10n) {
    final raw = page.text.trim();
    if (!settings.includePageNumbersInOutput) return raw;
    final header =
        l10n.isPersian ? 'صفحه ${page.pageNumber}' : 'Page ${page.pageNumber}';
    if (raw.startsWith('Page ${page.pageNumber}') ||
        raw.startsWith('صفحه ${page.pageNumber}')) {
      return raw;
    }
    return '$header\n\n$raw';
  }

  String _spokenPageText(
      PdfPageInfo page, SettingsService settings, AppLocalizations l10n) {
    final formatted = _formatPageWithNumber(page, settings, l10n);
    final skipped = _skippedText[page];
    if (skipped == null) return formatted;
    final raw = page.text.trim();
    final offset = formatted.length - raw.length;
    final output = StringBuffer(formatted.substring(0, offset));
    var cursor = 0;
    for (final range in skipped) {
      if (range.end <= cursor) continue;
      if (range.start > cursor) {
        output.write(raw.substring(cursor, range.start));
      }
      output.write(' ');
      cursor = range.end;
    }
    output.write(raw.substring(cursor));
    return output.toString();
  }

  void _skipSelectedText(PdfPageInfo page, TextSelection selection,
      String formatted, AppLocalizations l10n) {
    final offset = formatted.length - page.text.trim().length;
    final range = TextRange(
        start: math.max(0, selection.start - offset),
        end: selection.end - offset);
    if (range.end <= range.start) return;
    EspeakTtsService.stop();
    setState(() {
      final ranges = (_skippedText[page] ??= [])..add(range);
      ranges.sort((a, b) => a.start.compareTo(b.start));
    });
    _announceToScreenReader(l10n.tx(
        'Selection will be skipped in audio playback.',
        'بخش انتخاب‌شده در پخش صوتی خوانده نمی‌شود.'));
  }

  Future<void> _navigateToPage(int pageIndex,
      {bool playSound = true, bool continuePlayback = false}) async {
    final document = _document;
    if (document == null || pageIndex < 0 || pageIndex >= document.totalPages) {
      return;
    }

    EspeakTtsService.stop();
    final settings = Provider.of<SettingsService>(context, listen: false);
    final l10n = AppLocalizations.of(context);

    setState(() {
      _finishedDocument = null;
      _currentPageIndex = pageIndex;
      _openPage.value = pageIndex;
      _openAudioSecond.value = 0;
    });
    _storeReaderSession();
    _rememberBookPosition();

    final page = document.pages[pageIndex];
    final pageAnnouncement =
        l10n.isPersian ? 'صفحه ${page.pageNumber}' : 'Page ${page.pageNumber}';

    if (playSound && settings.playPageFlipSound) {
      await NativeBridgeService.playPageFlipSound();
    }
    bool onPage() =>
        mounted &&
        identical(_document, document) &&
        _currentPageIndex == pageIndex;
    if (!onPage()) return;
    final playText = !_restoringBook &&
        settings.enableInternalTts &&
        (continuePlayback || settings.autoReadOnOpen);
    if (!playText ||
        !settings.includePageNumbersInOutput ||
        page.text.isEmpty) {
      _announceToScreenReader(pageAnnouncement);
    }

    if (page.needsOcr && !page.ocrCompleted && page.ocrError == null) {
      await _ocrCurrentPdfPage(
          automatic: true, continuePlayback: continuePlayback);
    } else if (playText && page.text.trim().isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (onPage()) {
        final formatted = _spokenPageText(page, settings, l10n);
        EspeakTtsService.speak(formatted, settings: settings);
      }
    }
  }

  void _checkAndAutoOcrCurrentPage() {
    if (_document == null || _isOcringPage || _work != null) return;
    final page = _document!.pages[_currentPageIndex];
    if (page.needsOcr && !page.ocrCompleted && page.ocrError == null) {
      _ocrCurrentPdfPage(automatic: true);
    } else {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final l10n = AppLocalizations.of(context);
      if (page.text.trim().isNotEmpty &&
          !_restoringBook &&
          settings.enableInternalTts &&
          settings.autoReadOnOpen) {
        final formatted = _spokenPageText(page, settings, l10n);
        EspeakTtsService.speak(formatted, settings: settings);
      }
    }
  }

  /// Renders the current PDF page (or photo page) and runs OCR (Online or Offline) automatically
  Future<void> _ocrCurrentPdfPage(
      {bool automatic = true, bool continuePlayback = false}) async {
    if (_document == null || _isOcringPage || _work != null) return;
    if (_pdfSource == null && _photoPagesBytes == null) return;

    final int targetPageIndex = _currentPageIndex;
    final targetDocument = _document!;
    final operation = _operationGeneration;
    final sourceIndex = targetDocument.pages[targetPageIndex].sourcePageIndex;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final l10n = AppLocalizations.of(context);
    if (!await OnlineAccessGuard.require(context, settings,
            task: OnlineTask.ocr) ||
        !mounted ||
        operation != _operationGeneration ||
        _work != null) {
      return;
    }
    final work = DocumentWork(isPersian: l10n.isPersian);
    _work = work;
    String? speakAfterOcr;

    setState(() {
      _isOcringPage = true;
    });

    _announceToScreenReader(
      automatic
          ? l10n.translate('scanned_page_detected')
          : l10n.translate('ocring_page'),
    );
    OnlineAccessGuard.announceProcessing(context, settings,
        task: OnlineTask.ocr);

    try {
      await work.start();
      work.checkpoint();
      final pagePng = await _renderPageImage(sourceIndex);
      work.checkpoint();

      if (pagePng == null || pagePng.isEmpty) {
        throw StateError(l10n.tx(
            'Page image could not be rendered.', 'تصویر صفحه آماده نشد.'));
      }

      int lastAnnouncedStep = 0;
      final ocrRes = await _recognizePageImage(
        pagePng,
        settings,
        l10n,
        allowInteractiveBrowserAuth: true,
        onProgress: (pct) {
          if (!mounted || work.isCancelled) return;
          if (pct >= lastAnnouncedStep + 25 && pct < 100) {
            lastAnnouncedStep = pct;
            _announceToScreenReader(
              l10n.isPersian
                  ? 'در حال استخراج متن: $pct درصد'
                  : 'Extracting text: $pct%',
            );
          }
        },
      );

      work.checkpoint();
      if (!mounted ||
          operation != _operationGeneration ||
          !identical(_document, targetDocument)) {
        return;
      }

      if (ocrRes.hasText) {
        final oldPage = _document!.pages[targetPageIndex];
        final String updatedText = ocrRes.text.trim();
        final newPage = oldPage.copyWith(
          text: updatedText,
          needsOcr: false,
          ocrCompleted: true,
        );
        _document!.pages[targetPageIndex] = newPage;
        _rememberBookPosition();
        setState(() {});

        if (!_restoringBook &&
            settings.enableInternalTts &&
            (continuePlayback || settings.autoReadOnOpen) &&
            _currentPageIndex == targetPageIndex) {
          speakAfterOcr = _spokenPageText(newPage, settings, l10n);
        } else {
          _announceToScreenReader(
            l10n.isPersian
                ? 'صفحه ${targetPageIndex + 1}: $updatedText'
                : 'Page ${targetPageIndex + 1}: $updatedText',
          );
        }
      } else if (ocrRes.errorMessage != null &&
          ocrRes.errorMessage!.isNotEmpty) {
        _document!.pages[targetPageIndex] = _document!.pages[targetPageIndex]
            .copyWith(ocrError: ocrRes.errorMessage);
        _announceToScreenReader(ocrRes.errorMessage!);
        if (settings.enableInternalTts) {
          EspeakTtsService.speak(ocrRes.errorMessage!, settings: settings);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ocrRes.errorMessage!),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } on DocumentProcessingCancelled {
      // Leave any previously read text intact.
    } catch (error) {
      if (mounted &&
          !work.isCancelled &&
          operation == _operationGeneration &&
          identical(_document, targetDocument)) {
        targetDocument.pages[targetPageIndex] = targetDocument
            .pages[targetPageIndex]
            .copyWith(ocrError: error.toString());
        _announceToScreenReader(error.toString());
      }
    } finally {
      await _finishDocumentWork(work);
      if (mounted && operation == _operationGeneration) {
        setState(() {
          _isOcringPage = false;
        });
        if (targetPageIndex != _currentPageIndex &&
            identical(_document, targetDocument)) {
          _checkAndAutoOcrCurrentPage();
        } else if (speakAfterOcr != null &&
            !work.isCancelled &&
            identical(_document, targetDocument)) {
          unawaited(EspeakTtsService.speak(speakAfterOcr,
              settings: settings, title: targetDocument.fileName));
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _readingClock?.cancel();
    _rememberBookPosition();
    _flushReadingTime();
    _work?.cancel();
    _photoPagesBytes = null;
    _operationGeneration++;
    EspeakTtsService.stop();
    EspeakTtsService.playbackState.removeListener(_onPlaybackStateChanged);
    EspeakTtsService.sessionCompletedTick.removeListener(_onSessionCompleted);
    _highlightTimer?.cancel();
    _highlightTick.dispose();
    _searchController.dispose();
    _savedBook.dispose();
    _openPath.dispose();
    _openPage.dispose();
    _openStart.dispose();
    _openEnd.dispose();
    _openAudioSecond.dispose();
    super.dispose();
  }

  void _performSearch(String query) {
    setState(() {
      _searchQuery = query.trim();
      _searchMatchingPages.clear();

      if (_document != null && _searchQuery.isNotEmpty) {
        final lower = _searchQuery.toLowerCase();
        for (int i = 0; i < _document!.pages.length; i++) {
          if (_document!.pages[i].text.toLowerCase().contains(lower)) {
            _searchMatchingPages.add(i);
          }
        }
      }
    });
  }

  void _goToPageDialog(BuildContext context, AppLocalizations l10n) {
    if (_document == null) return;
    final controller = TextEditingController(text: '${_currentPageIndex + 1}');

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.translate('go_to_page')),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.translate(
                  'page_number_prompt', {'total': '${_document!.totalPages}'}),
              hintText: '1 - ${_document!.totalPages}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel')),
            ),
            ElevatedButton(
              onPressed: () {
                final pageNum = int.tryParse(controller.text.trim());
                if (pageNum != null &&
                    pageNum >= 1 &&
                    pageNum <= _document!.totalPages) {
                  Navigator.pop(ctx);
                  _navigateToPage(pageNum - 1);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.translate('invalid_page_number')),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
              child: Text(l10n.translate('go_to_page')),
            ),
          ],
        );
      },
    );
  }

  void _addBookmarkDialog(
      BuildContext context, AppLocalizations l10n, SettingsService settings) {
    if (_document == null) return;
    final controller = TextEditingController();
    final currentPage = _currentPageIndex + 1;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('${l10n.translate('add_bookmark')} ($currentPage)'),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText:
                  l10n.isPersian ? 'عنوان یا برچسب نشانک' : 'Bookmark Label',
              hintText: l10n.translate('bookmark_label_placeholder'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel')),
            ),
            ElevatedButton(
              onPressed: () {
                final label = controller.text.trim().isNotEmpty
                    ? controller.text.trim()
                    : 'Page $currentPage';
                final snippet =
                    _document!.pages[_currentPageIndex].text.length > 80
                        ? _document!.pages[_currentPageIndex].text
                            .substring(0, 80)
                        : _document!.pages[_currentPageIndex].text;

                settings.addBookmark(BookmarkItem(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  documentName: _document!.fileName,
                  pageNumber: currentPage,
                  label: label,
                  snippet: snippet,
                ));

                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.translate('bookmark_added')),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              child: Text(l10n.translate('add_bookmark')),
            ),
          ],
        );
      },
    );
  }

  void _savePageAsNote(
      BuildContext context, SettingsService settings, AppLocalizations l10n) {
    if (_document == null) return;
    final page = _document!.pages[_currentPageIndex];
    if (page.text.trim().isEmpty) return;

    final title = '${_document!.fileName} - ${l10n.translate('page_stats', {
          'current': '${page.pageNumber}',
          'total': '${_document!.totalPages}'
        })}';
    settings.addNote(NoteItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      content: page.text.trim(),
      source: 'pdf_reader',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      tags: ['quote'],
    ));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.isPersian
            ? 'این صفحه در یادداشت‌ها ذخیره شد!'
            : 'Page saved to Notes successfully!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showBookmarksModal(
      BuildContext context, AppLocalizations l10n, SettingsService settings) {
    if (_document == null) return;
    final bookmarks = settings.getBookmarksForDocument(_document!.fileName);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l10n.translate('bookmarks'),
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    Row(
                      children: [
                        if (bookmarks.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.delete_sweep_rounded,
                                color: Colors.redAccent, size: 20),
                            tooltip: l10n.isPersian
                                ? 'پاکسازی نشانک‌ها'
                                : 'Clear Bookmarks',
                            onPressed: () {
                              if (_document != null) {
                                settings.clearBookmarksForDocument(
                                    _document!.fileName);
                              } else {
                                settings.clearAllBookmarks();
                              }
                              Navigator.pop(ctx);
                              _showBookmarksModal(context, l10n, settings);
                            },
                          ),
                        IconButton(
                          tooltip: l10n.translate('close'),
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ],
                ),
                const Divider(),
                if (bookmarks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      l10n.translate('no_bookmarks'),
                      style: TextStyle(
                          color: Theme.of(context).textTheme.bodySmall?.color),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: bookmarks.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (c, idx) {
                        final b = bookmarks[idx];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                            child: Text('${b.pageNumber}'),
                          ),
                          title: Text(b.label,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                            b.snippet,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            tooltip: l10n.isPersian
                                ? 'حذف نشانک'
                                : 'Delete Bookmark',
                            icon: const Icon(Icons.delete_outline_rounded,
                                color: Colors.red),
                            onPressed: () {
                              settings.removeBookmark(b.id);
                              Navigator.pop(ctx);
                              _showBookmarksModal(context, l10n, settings);
                            },
                          ),
                          onTap: () {
                            Navigator.pop(ctx);
                            _navigateToPage(b.pageNumber - 1);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Shows the Choose Pages dialog (Start Page & End Page in two editable text boxes,
  /// defaulting to 1 and totalPages), then runs 0%..100% processing and asks for Export/Action!
  Future<void> _showChoosePagesAndProcessDialog({
    required ProcessedPdfDocument loadedDoc,
    required SettingsService settings,
    required AppLocalizations l10n,
  }) async {
    final operation = _operationGeneration;
    if (loadedDoc.totalPages == 0) {
      throw const FormatException('The document has no pages.');
    }
    final rangeResult = await showDialog<PageRangeSelection>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DocumentPageRangeDialog(
            totalPages: loadedDoc.totalPages,
            allowLazyOpen: true,
            allowForceOcr:
                _pdfSource != null || _photoPages is CapturedPageStore));
    if (rangeResult == null || !mounted || operation != _operationGeneration) {
      return;
    }
    final startPage = rangeResult.start;
    final endPage = rangeResult.end;
    final totalSelected = endPage - startPage + 1;

    _openStart.value = startPage;
    _openEnd.value = endPage;
    _openPage.value = 0;
    _openAudioSecond.value = 0;
    _storeReaderSession();
    if (!rangeResult.processAll && !rangeResult.forceOcr) {
      final document = _pageSubset(loadedDoc, startPage, endPage);
      setState(() {
        _document = document;
        _currentPageIndex = 0;
      });
      final path = _openPath.value;
      if (path != null) {
        final id = DateTime.now().microsecondsSinceEpoch.toString();
        _savedBook.value = id;
        _bookKeys[document] = 'book:$id';
        _storeReaderSession();
        unawaited(settings.addHistoryItem(ScanHistoryItem(
          id: id,
          type: ScanType.pdf,
          title: document.fileName,
          content: '',
          isOffline: document.isOffline,
          modelOrEngine: '${document.totalPages} Pages',
          sourcePath: path,
          startPage: startPage,
          endPage: endPage,
        )));
      }
      _checkAndAutoOcrCurrentPage();
      return;
    }

    bool anySelectedPageNeedsOcr = false;
    for (int i = 0; i < totalSelected; i++) {
      final p = loadedDoc.pages[(startPage - 1) + i];
      if (rangeResult.forceOcr || p.needsOcr && !p.ocrCompleted) {
        anySelectedPageNeedsOcr = true;
        break;
      }
    }

    if (anySelectedPageNeedsOcr &&
        !await OnlineAccessGuard.require(context, settings,
            task: OnlineTask.ocr)) {
      return;
    }

    if (!mounted || operation != _operationGeneration || _work != null) return;
    final work = DocumentWork(isPersian: l10n.isPersian);
    _work = work;
    setState(() {
      _isLoading = true;
      _processingProgress = 0.0;
      _processingStatusText = l10n.isPersian
          ? 'در حال پردازش صفحات (0%)...'
          : 'Processing pages (0%)...';
    });
    _announceToScreenReader(
      l10n.isPersian
          ? 'شروع پردازش و استخراج متن: ۰ درصد'
          : 'Starting OCR processing: 0%',
    );
    if (anySelectedPageNeedsOcr) {
      OnlineAccessGuard.announceProcessing(context, settings,
          task: OnlineTask.ocr);
    }

    final selected = loadedDoc.pages
        .sublist(startPage - 1, endPage)
        .map((page) => rangeResult.forceOcr
            ? page.copyWith(needsOcr: true, ocrCompleted: false)
            : page)
        .toList();
    String? summary;
    try {
      await work.start();
      work.checkpoint();
      final batch = await DocumentBatchProcessor.process(
          pages: selected,
          isCancelled: () =>
              work.isCancelled || !mounted || operation != _operationGeneration,
          render: _renderPageImage,
          recognize: (bytes) => _recognizePageImage(bytes, settings, l10n,
              allowInteractiveBrowserAuth: false),
          onProgress: (p) {
            if (!mounted ||
                work.isCancelled ||
                operation != _operationGeneration) {
              return;
            }
            final message = l10n.isPersian
                ? '${p.percent} درصد — ${p.completed} از ${p.total} صفحه؛ موفق ${p.successful}، ناموفق ${p.failed}؛ متن آماده ${p.extracted}، خواندن تصویر ${p.recognized}'
                : '${p.percent}% — ${p.completed} of ${p.total} pages; ${p.successful} successful, ${p.failed} failed; ${p.extracted} ready text, ${p.recognized} read from images';
            final now = DateTime.now();
            if (p.completed == 0 ||
                p.completed == p.total ||
                now.difference(_lastProgressRefresh).inMilliseconds >= 120) {
              _lastProgressRefresh = now;
              setState(() {
                _processingProgress = p.percent / 100;
                _processingStatusText = message;
              });
            }
            if (p.completed == 0 ||
                p.completed == p.total ||
                now.difference(_lastProgressAnnouncement).inMilliseconds >=
                    1500) {
              _lastProgressAnnouncement = now;
              _announceToScreenReader(message, progress: true);
            }
          });
      final selectedPagesList = batch.pages;
      final completedSummary = l10n.isPersian
          ? 'پردازش کامل شد: ${batch.progress.successful} صفحه موفق، ${batch.progress.failed} صفحه ناموفق. ${batch.progress.extracted} صفحه متن آماده داشت و متن ${batch.progress.recognized} صفحه از تصویر خوانده شد.'
          : 'Processing complete: ${batch.progress.successful} successful, ${batch.progress.failed} failed. ${batch.progress.extracted} pages already had text; ${batch.progress.recognized} pages read from images.';

      final finalDoc = ProcessedPdfDocument(
        fileName: loadedDoc.fileName,
        totalPages: selectedPagesList.length,
        pages: selectedPagesList,
        isOffline: loadedDoc.isOffline,
      );

      // Persist processed book content in history so Books Manager can reopen it anytime
      final serializedPages = await _serializeBookPages(selectedPagesList);
      work.beginCommit();
      if (!mounted || operation != _operationGeneration) return;
      setState(() {
        _processingStatusText =
            l10n.tx('Saving processed pages…', 'در حال ذخیرهٔ صفحات…');
      });
      if (serializedPages.isNotEmpty) {
        final id = DateTime.now().millisecondsSinceEpoch.toString();
        await settings.addHistoryItem(
          ScanHistoryItem(
            id: id,
            type: ScanType.pdf,
            title: finalDoc.fileName,
            content: serializedPages,
            isOffline: finalDoc.isOffline,
            modelOrEngine: '${finalDoc.totalPages} Pages',
          ),
        );
        if (mounted && operation == _operationGeneration) {
          _savedBook.value = id;
          _bookKeys[finalDoc] = 'book:$id';
          _storeReaderSession();
        }
      }
      if (!mounted || operation != _operationGeneration) return;
      setState(() {
        _document = finalDoc;
        _currentPageIndex = 0;
        _processingProgress = 1.0;
      });
      summary = completedSummary;
    } on DocumentProcessingCancelled {
      // Discard pages from this cancelled run.
    } catch (error) {
      if (mounted && operation == _operationGeneration && !work.isCancelled) {
        _announceToScreenReader(error.toString());
      }
    } finally {
      await _finishDocumentWork(work);
      if (mounted && operation == _operationGeneration) {
        setState(() => _isLoading = false);
      }
    }
    if (summary != null && mounted && operation == _operationGeneration) {
      _announceToScreenReader(summary);
      _checkAndAutoOcrCurrentPage();
    }
  }

  ProcessedPdfDocument _pageSubset(
      ProcessedPdfDocument document, int start, int end) {
    if (start == 1 && end == document.totalPages) return document;
    final pages = document.pages.sublist(start - 1, end);
    return ProcessedPdfDocument(
      fileName: document.fileName,
      totalPages: pages.length,
      isOffline: document.isOffline,
      pages: [
        for (final (index, page) in pages.indexed)
          PdfPageInfo(
            pageNumber: index + 1,
            sourcePageIndex: page.sourcePageIndex,
            text: page.text,
            needsOcr: page.needsOcr,
            ocrCompleted: page.ocrCompleted,
            ocrError: page.ocrError,
          ),
      ],
    );
  }

  Future<void> _rememberTextBook(
      ProcessedPdfDocument document, SettingsService settings) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    _savedBook.value = id;
    _openPath.value = null;
    _openPage.value = 0;
    _openAudioSecond.value = 0;
    _bookKeys[document] = 'book:$id';
    final content = await _serializeBookPages(document.pages);
    if (content.isNotEmpty) {
      await settings.addHistoryItem(ScanHistoryItem(
        id: id,
        type: ScanType.pdf,
        title: document.fileName,
        content: content,
        isOffline: document.isOffline,
        modelOrEngine: '${document.totalPages} Pages',
      ));
      if (mounted && _savedBook.value == id) _storeReaderSession();
    }
  }

  void _showExportDialog(BuildContext context, AppLocalizations l10n) {
    if (_document == null || _work != null) return;

    String? selectedFormat;
    var outputStem = AppStorageService.sourceStem(_document!.fileName);
    bool exportAll = true;
    final fromController = TextEditingController(text: '1');
    final toController =
        TextEditingController(text: '${_document!.totalPages}');

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              title: Text(l10n.translate('export_options')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutputFileNameField(
                      initialName: outputStem,
                      extension: selectedFormat,
                      onChanged: (value) =>
                          setDialogState(() => outputStem = value),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.translate('select_format'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    AccessibleDropdownField<String>(
                      initialValue: selectedFormat,
                      hint: Text(
                        l10n.isPersian
                            ? 'یک فرمت خروجی انتخاب کنید...'
                            : 'Select an export format...',
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.translate('select_format'),
                        border: const OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'wav',
                            child: Text('🎧  Audio WAV - eSpeak-NG (.wav)')),
                        DropdownMenuItem(
                            value: 'zip',
                            child: Text('📦  Scanora Audiobook ZIP (.zip)')),
                        DropdownMenuItem(
                            value: 'docx',
                            child: Text('📘  Microsoft Word (.docx)')),
                        DropdownMenuItem(
                            value: 'rtf', child: Text('📄  Rich Text (.rtf)')),
                        DropdownMenuItem(
                            value: 'txt', child: Text('📄  Plain Text (.txt)')),
                        DropdownMenuItem(
                            value: 'md', child: Text('📝  Markdown (.md)')),
                        DropdownMenuItem(
                            value: 'html',
                            child: Text('🌐  HTML Document (.html)')),
                        DropdownMenuItem(
                            value: 'json',
                            child: Text('📊  Structured JSON (.json)')),
                      ],
                      onChanged: (val) {
                        setDialogState(() => selectedFormat = val);
                      },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.translate('page_range'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    RadioGroup<bool>(
                      groupValue: exportAll,
                      onChanged: (val) =>
                          setDialogState(() => exportAll = val ?? true),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RadioListTile<bool>(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l10n.translate('all_pages',
                                {'total': '${_document!.totalPages}'})),
                            value: true,
                          ),
                          RadioListTile<bool>(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l10n.translate('custom_range')),
                            value: false,
                          ),
                        ],
                      ),
                    ),
                    if (!exportAll) ...[
                      Row(
                        children: [
                          Expanded(
                            child: AccessiblePageNumberField(
                                controller: fromController,
                                label: l10n.tx('Start Page', 'صفحهٔ شروع')),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: AccessiblePageNumberField(
                                controller: toController,
                                label: l10n.tx('End Page', 'صفحهٔ پایان')),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l10n.translate('cancel')),
                ),
                ElevatedButton(
                  onPressed: selectedFormat == null || outputStem.trim().isEmpty
                      ? null
                      : () async {
                          final chosenFormat = selectedFormat!;
                          int start = 1;
                          int end = _document!.totalPages;
                          if (!exportAll) {
                            start =
                                int.tryParse(fromController.text.trim()) ?? 1;
                            end = int.tryParse(toController.text.trim()) ??
                                _document!.totalPages;
                            if (start < 1) start = 1;
                            if (end > _document!.totalPages) {
                              end = _document!.totalPages;
                            }
                            if (start > end) start = end;
                          }

                          Navigator.pop(ctx);
                          await _executeExport(
                              chosenFormat, start, end, outputStem, l10n);
                        },
                  child: Text(l10n.translate('export_confirm')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _executeExport(
    String format,
    int startPage,
    int endPage,
    String outputStem,
    AppLocalizations l10n,
  ) async {
    final document = _document;
    if (document == null || _work != null) return;
    final operation = _operationGeneration;
    final settings = context.read<SettingsService>();
    var selectedPages = document.pages
        .where((p) => p.pageNumber >= startPage && p.pageNumber <= endPage)
        .toList();
    final needsOcr =
        selectedPages.any((page) => page.needsOcr && !page.ocrCompleted);
    if (needsOcr &&
        !await OnlineAccessGuard.require(context, settings,
            task: OnlineTask.ocr)) {
      return;
    }
    if (!mounted ||
        operation != _operationGeneration ||
        !identical(_document, document) ||
        _work != null) {
      return;
    }
    final work = DocumentWork(isPersian: l10n.isPersian);
    _work = work;
    bool isCurrent() =>
        mounted &&
        !work.isCancelled &&
        operation == _operationGeneration &&
        identical(_document, document);
    setState(() {
      _isLoading = true;
      _processingProgress = 0;
      _processingStatusText =
          l10n.tx('Preparing export…', 'در حال آماده‌سازی خروجی…');
    });
    try {
      await work.start();
      work.checkpoint();
      final baseName =
          document.fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
      if (needsOcr) {
        final batch = await DocumentBatchProcessor.process(
          pages: selectedPages,
          render: _renderPageImage,
          recognize: (bytes) => _recognizePageImage(bytes, settings, l10n,
              allowInteractiveBrowserAuth: false),
          onProgress: (progress) {
            if (!isCurrent()) return;
            _preparationProgress(progress.percent);
          },
          isCancelled: () => !isCurrent(),
        );
        work.checkpoint();
        for (var i = 0; i < selectedPages.length; i++) {
          final original = selectedPages[i];
          final result = batch.pages[i];
          final updated = original.copyWith(
            text: result.text,
            needsOcr: result.needsOcr,
            ocrCompleted: result.ocrCompleted,
            ocrError: result.ocrError,
          );
          document.pages[original.pageNumber - 1] = updated;
          selectedPages[i] = updated;
        }
        if (batch.progress.failed > 0) {
          throw FormatException(l10n.tx(
              '${batch.progress.failed} pages could not be read. Choose a readable range or retry.',
              'متن ${batch.progress.failed} صفحه خوانده نشد. محدوده را تغییر دهید یا دوباره تلاش کنید.'));
        }
      }
      final outFileName = AppStorageService.outputName(outputStem, format);
      File outFile;
      Future<File> saveOutput(Uint8List bytes) {
        work.beginCommit();
        if (!isCurrent()) throw const DocumentProcessingCancelled();
        setState(() {
          _processingStatusText =
              l10n.tx('Saving file…', 'در حال ذخیرهٔ فایل…');
        });
        return AppStorageService.saveFile(
          fileName: outFileName,
          bytes: bytes,
          customDirectory: settings.exportDirectoryPath,
        );
      }

      if (format == 'wav' || format == 'zip') {
        setState(() {
          _isLoading = true;
          _processingProgress = 0.0;
          _processingStatusText = l10n.isPersian
              ? 'در حال تولید فایل صوتی با موتور eSpeak-NG (0%)...'
              : 'Synthesizing audio with eSpeak-NG (0%)...';
        });

        final combinedText = selectedPages
            .map((p) => _formatPageWithNumber(p, settings, l10n))
            .join('\n\n');
        int lastAudioAnnouncedBucket = 0;
        final wavBytes = await EspeakTtsService.synthesizeToWavBytes(
          combinedText,
          settings: settings,
          cancelled: work.whenCancelled,
          onProgress: (p) {
            if (isCurrent()) {
              final pct = (p * 100).round();
              setState(() {
                _processingProgress = p;
                _processingStatusText = l10n.isPersian
                    ? 'در حال ساخت فایل صوتی ($pct%)...'
                    : 'Generating audio ($pct%)...';
              });
              final bucket = (pct ~/ 10) * 10;
              if (bucket >= 10 && bucket > lastAudioAnnouncedBucket) {
                lastAudioAnnouncedBucket = bucket;
                _announceToScreenReader(
                  l10n.isPersian
                      ? 'تبدیل به فایل صوتی: $bucket درصد'
                      : 'Audio conversion: $bucket%',
                  progress: true,
                );
              }
            }
          },
        );

        if (!isCurrent()) return;

        if (format == 'zip') {
          final archive = Archive();
          final jsonManifest = utf8.encode(
            jsonEncode({
              'title': baseName,
              'totalPages': selectedPages.length,
              'pages': selectedPages
                  .map((p) => {
                        'page': p.pageNumber,
                        'text': _formatPageWithNumber(p, settings, l10n),
                      })
                  .toList(),
            }),
          );
          archive.addFile(
              ArchiveFile('audiobook.json', jsonManifest.length, jsonManifest));
          final txtBytes = utf8.encode(combinedText);
          archive
              .addFile(ArchiveFile('$baseName.txt', txtBytes.length, txtBytes));
          if (wavBytes.isNotEmpty) {
            archive.addFile(
                ArchiveFile('$baseName.wav', wavBytes.length, wavBytes));
          }
          final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
          outFile = await saveOutput(zipBytes);
        } else {
          outFile = await saveOutput(wavBytes);
        }
      } else if (format == 'docx') {
        final paragraphs = selectedPages
            .expand((p) => [
                  if (settings.includePageNumbersInOutput)
                    (l10n.isPersian
                        ? 'صفحه ${p.pageNumber}'
                        : 'Page ${p.pageNumber}'),
                  p.text,
                  '',
                ])
            .toList();
        final bytes = DocxExporter.createDocx(
          title: '$baseName (Pages $startPage-$endPage)',
          paragraphs: paragraphs,
          isRtl: l10n.isPersian || l10n.isRtl,
        );
        outFile = await saveOutput(bytes);
      } else if (format == 'rtf') {
        final paragraphs = selectedPages
            .expand((p) => [
                  if (settings.includePageNumbersInOutput)
                    (l10n.isPersian
                        ? 'صفحه ${p.pageNumber}'
                        : 'Page ${p.pageNumber}'),
                  p.text,
                  '',
                ])
            .toList();
        final bytes = DocxExporter.createRtf(
          title: '$baseName (Pages $startPage-$endPage)',
          paragraphs: paragraphs,
          isRtl: l10n.isPersian || l10n.isRtl,
        );
        outFile = await saveOutput(bytes);
      } else {
        String outputContent = '';
        if (format == 'txt') {
          outputContent = selectedPages
              .map((p) => _formatPageWithNumber(p, settings, l10n))
              .join('\n\n');
        } else if (format == 'md') {
          outputContent = selectedPages
              .map((p) => settings.includePageNumbersInOutput
                  ? '## ${l10n.isPersian ? "صفحه ${p.pageNumber}" : "Page ${p.pageNumber}"}\n\n${p.text}'
                  : p.text)
              .join('\n\n---\n\n');
        } else if (format == 'html') {
          final pageHtml = selectedPages
              .map((p) => settings.includePageNumbersInOutput
                  ? '<section><h2>${l10n.isPersian ? "صفحه ${p.pageNumber}" : "Page ${p.pageNumber}"}</h2><p>${const HtmlEscape().convert(p.text).replaceAll('\n', '<br>')}</p></section>'
                  : '<section><p>${const HtmlEscape().convert(p.text).replaceAll('\n', '<br>')}</p></section>')
              .join('\n<hr>\n');
          outputContent =
              '<!DOCTYPE html><html><head><meta charset="utf-8"><title>${const HtmlEscape().convert(baseName)}</title></head><body>$pageHtml</body></html>';
        } else if (format == 'json') {
          outputContent = jsonEncode({
            'fileName': document.fileName,
            'startPage': startPage,
            'endPage': endPage,
            'pages': selectedPages
                .map((p) => {'page': p.pageNumber, 'text': p.text})
                .toList(),
          });
        }
        outFile =
            await saveOutput(Uint8List.fromList(utf8.encode(outputContent)));
      }

      if (!mounted || !isCurrent()) return;
      final successMsg =
          l10n.translate('export_success', {'path': outFile.path});
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(successMsg),
            persist: false,
            action: SnackBarAction(
              label: l10n.isPersian ? 'باز کردن پوشه' : 'Open Folder',
              onPressed: () {
                AppStorageService.highlightFile(outFile.path);
              },
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } on DocumentProcessingCancelled {
      // Cancellation leaves the source document open.
    } catch (e) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(l10n.translate('error_general', {'error': e.toString()})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      await _finishDocumentWork(work);
      if (mounted && operation == _operationGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Universal File Loader supporting PDF, Photos, DOCX/DOC, TXT/MD, PPTX/PPT, XLSX/CSV, and Audiobook ZIP!
  Future<void> _pickAndProcessStudioFile(
    SettingsService settings,
    AppLocalizations l10n, {
    required bool useRangeAndExportWizard,
  }) async {
    if (_work != null) return;
    try {
      final files = await FilePicker.pickFiles(
        type: Platform.isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isAndroid ? null : DocumentFormats.all,
      );
      await _processStudioFiles(
        [
          for (final file in files)
            (name: file.name, path: file.path, readAsBytes: file.readAsBytes),
        ],
        settings,
        l10n,
        useRangeAndExportWizard: useRangeAndExportWizard,
      );
    } catch (error) {
      if (!mounted) return;
      AccessibilityService.announceAndNotify(context,
          l10n.translate('error_general', {'error': error.toString()}));
    }
  }

  Future<void> _processStudioFiles(
    List<_StudioFile> result,
    SettingsService settings,
    AppLocalizations l10n, {
    required bool useRangeAndExportWizard,
  }) async {
    DocumentWork? work;
    try {
      if (result.isEmpty || !mounted || _work != null) return;
      final operation = ++_operationGeneration;
      await EspeakTtsService.stop();
      if (!mounted || operation != _operationGeneration || _work != null) {
        return;
      }
      _lastPreparationPercent = -10;

      final job = DocumentWork(isPersian: l10n.isPersian);
      work = job;
      _work = job;
      final openingMessage =
          l10n.tx('Opening document…', 'در حال باز کردن سند…');
      setState(() {
        _isLoading = true;
        _processingProgress = 0.0;
        _processingStatusText = openingMessage;
      });
      _announceToScreenReader(openingMessage, progress: true);
      if (Platform.isWindows) {
        await WidgetsBinding.instance.endOfFrame
            .timeout(const Duration(milliseconds: 120), onTimeout: () {});
      }
      await job.start();
      job.checkpoint();

      final firstFile = result.first;
      final firstExt = DocumentFormats.extension(firstFile.name);
      if (!DocumentFormats.all.contains(firstExt)) {
        throw UnsupportedError('Unsupported file format: $firstExt');
      }
      _savedBook.value = null;
      _openPath.value = result.length == 1 ? firstFile.path : null;
      _openPage.value = 0;
      _openAudioSecond.value = 0;
      _openStart.value = 1;
      _openEnd.value = 0;
      _storeReaderSession();
      final archivePhotos = ['zip', 'cbz'].contains(firstExt)
          ? await DocumentImageLoader.load(
              await firstFile.readAsBytes(), firstFile.name)
          : null;
      job.checkpoint();
      final isImageSelection =
          DocumentFormats.images.contains(firstExt) || archivePhotos != null;

      ProcessedPdfDocument processed;
      String engineName = 'Smart Studio Reader';

      if (isImageSelection) {
        // User selected 1 or multiple photos! Each photo becomes a page that is OCR'd during processing!
        final photoBytesList = <Uint8List>[];
        final pages = <PdfPageInfo>[];
        for (int i = 0; i < result.length; i++) {
          job.checkpoint();
          final f = result[i];
          Uint8List? b;
          try {
            b = await f.readAsBytes();
          } catch (_) {
            if (f.path != null) {
              b = await File(f.path!).readAsBytes();
            }
          }
          if (b != null && b.isNotEmpty) {
            final frames = i == 0 && archivePhotos != null
                ? archivePhotos
                : await DocumentImageLoader.load(b, f.name);
            if (frames == null) {
              throw const FormatException('Select only image files together.');
            }
            for (final frame in frames) {
              photoBytesList.add(frame);
              pages.add(PdfPageInfo(
                  pageNumber: pages.length + 1, text: '', needsOcr: true));
            }
          }
        }
        _pdfSource = null;
        _photoPagesBytes = photoBytesList;
        processed = ProcessedPdfDocument(
          fileName: result.length == 1
              ? firstFile.name
              : 'Photos_Book (${result.length} images)',
          totalPages: pages.length,
          pages: pages,
          isOffline: settings.isOfflineMode,
        );
        engineName = 'Photo Book OCR';
      } else if (firstExt == 'pdf') {
        _photoPagesBytes = null;
        final selectedPath = firstFile.path;
        final path = selectedPath != null && await File(selectedPath).exists()
            ? selectedPath
            : null;
        final bytes = path == null ? await firstFile.readAsBytes() : null;
        job.checkpoint();
        if (!mounted || operation != _operationGeneration) return;
        _pdfSource = (path: path, bytes: bytes);
        void reportProgress(int percent) {
          if (operation == _operationGeneration) _preparationProgress(percent);
        }

        processed = path != null
            ? await PdfService.extractPdfFile(
                path: path,
                fileName: firstFile.name,
                isOfflineMode: settings.isOfflineMode,
                onProgress: reportProgress,
                cancelled: job.whenCancelled,
                layoutHeading: settings.documentLayout
                    ? l10n.tx('Heading', 'عنوان')
                    : null,
              )
            : await PdfService.extractPdfPages(
                pdfBytes: bytes!,
                fileName: firstFile.name,
                isOfflineMode: settings.isOfflineMode,
                onProgress: reportProgress,
                cancelled: job.whenCancelled,
                layoutHeading: settings.documentLayout
                    ? l10n.tx('Heading', 'عنوان')
                    : null,
              );
        engineName =
            settings.isOfflineMode ? 'Offline PDF Engine' : 'AI Vision';
      } else if (firstExt == 'txt' && firstFile.path != null) {
        _photoPagesBytes = null;
        _pdfSource = null;
        processed = await PdfService.extractTextFileAsync(
            path: firstFile.path!, fileName: firstFile.name);
        engineName = 'Text Document Reader';
      } else {
        _photoPagesBytes = null;
        _pdfSource = null;
        final bytes = firstFile.path != null
            ? await File(firstFile.path!).readAsBytes()
            : await firstFile.readAsBytes();

        if (firstExt == 'epub') {
          processed = await PdfService.extractEpubDocumentAsync(
            fileBytes: bytes,
            fileName: firstFile.name,
          );
          engineName = 'EPUB E-Book Reader';
        } else if (firstExt == 'odt' ||
            firstExt == 'odp' ||
            firstExt == 'ods') {
          processed = await PdfService.extractOpenDocumentAsync(
            fileBytes: bytes,
            fileName: firstFile.name,
          );
          engineName = 'OpenDocument Reader';
        } else if (['docx', 'doc', 'docm', 'dotx'].contains(firstExt)) {
          processed = await PdfService.extractWordDocumentAsync(
            fileBytes: bytes,
            fileName: firstFile.name,
          );
          engineName = 'Word Document Reader';
        } else if (['pptx', 'ppt', 'pptm', 'ppsx'].contains(firstExt)) {
          processed = await PdfService.extractPowerPointDocumentAsync(
            fileBytes: bytes,
            fileName: firstFile.name,
          );
          engineName = 'PowerPoint Slide Reader';
        } else if (['xlsx', 'xls', 'xlsm', 'xltx', 'csv', 'tsv']
            .contains(firstExt)) {
          processed = await PdfService.extractExcelDocumentAsync(
            fileBytes: bytes,
            fileName: firstFile.name,
          );
          engineName = 'Excel Spreadsheet Reader';
        } else if (firstExt == 'zip') {
          processed = await PdfService.extractAudiobookZipAsync(
            fileBytes: bytes,
            fileName: firstFile.name,
          );
          engineName = 'Audiobook ZIP Reader';
        } else {
          processed = await PdfService.extractTextDocumentAsync(
            fileBytes: bytes,
            fileName: firstFile.name,
          );
          engineName = 'Text Document Reader';
        }
      }

      job.checkpoint();
      if (!mounted || operation != _operationGeneration) return;
      await _finishDocumentWork(job);
      work = null;
      job.checkpoint();
      if (!mounted || operation != _operationGeneration) return;
      _preparationProgress(100);
      setState(() => _isLoading = false);

      if (useRangeAndExportWizard || isImageSelection) {
        await _showChoosePagesAndProcessDialog(
          loadedDoc: processed,
          settings: settings,
          l10n: l10n,
        );
      } else {
        setState(() {
          _document = processed;
          _currentPageIndex = 0;
          _searchQuery = '';
          _searchController.clear();
        });
        _checkAndAutoOcrCurrentPage();
        final serializedPages = await _serializeBookPages(processed.pages);
        if (!mounted || operation != _operationGeneration) return;
        final id = DateTime.now().millisecondsSinceEpoch.toString();
        await settings.addHistoryItem(
          ScanHistoryItem(
            id: id,
            type: ScanType.pdf,
            title: processed.fileName,
            content: serializedPages.isNotEmpty
                ? serializedPages
                : '${processed.totalPages} pages',
            isOffline: settings.isOfflineMode,
            modelOrEngine: engineName,
          ),
        );
        if (mounted && operation == _operationGeneration) {
          _savedBook.value = id;
          _bookKeys[processed] = 'book:$id';
          _storeReaderSession();
        }
      }
    } on DocumentProcessingCancelled {
      if (mounted && identical(_work, work)) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted && (work == null || identical(_work, work))) {
        setState(() => _isLoading = false);
        if (work?.isCancelled == true) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(l10n.translate('error_general', {'error': e.toString()})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (work != null) await _finishDocumentWork(work);
    }
  }

  /// Open a converted book or exported file from BooksManagerScreen
  Future<void> _openBookManager(
    SettingsService settings,
    AppLocalizations l10n,
  ) async {
    _rememberBookPosition();
    _flushReadingTime();
    final selection = await Navigator.of(context).push<BookManagerSelection>(
      MaterialPageRoute(builder: (_) => const BooksManagerScreen()),
    );
    if (selection == null || !mounted) return;

    final item = selection.historyItem;
    final path = selection.filePath;
    if (item == null && path == null) return;
    final position =
        settings.bookPosition(item != null ? 'book:${item.id}' : 'file:$path');
    final finished = position?['finished'] == true;
    final page = finished ? 0 : position?['page'] as int? ?? 0;
    final seconds = finished ? 0 : position?['second'] as int? ?? 0;
    final rate = position?['rate'] as int? ?? settings.effectiveTtsRate;
    final previousDocument = _document;
    _restoringBook = true;
    _openAudioSecond.value =
        (seconds * rate / settings.effectiveTtsRate).round();
    try {
      if (item != null) {
        await _openSavedBook(item, settings, l10n, page: page);
      } else {
        await _openFileFromPath(path!, settings, l10n, page: page);
      }
    } finally {
      _restoringBook = false;
    }
    final document = _document;
    if (!mounted || document == null || identical(document, previousDocument)) {
      return;
    }
    _storeReaderSession();
    _rememberBookPosition();
    final current = document.pages[_currentPageIndex];
    if (!settings.enableInternalTts || current.text.trim().isEmpty) return;
    final spoken = _spokenPageText(current, settings, l10n);
    if (_openAudioSecond.value > 0) {
      await EspeakTtsService.stop();
      await EspeakTtsService.seekToSecond(_openAudioSecond.value, settings,
          fallbackText: spoken, title: document.fileName);
      if (mounted && settings.autoReadOnOpen) {
        await EspeakTtsService.togglePlayPause(settings);
      }
    } else if (settings.autoReadOnOpen) {
      await EspeakTtsService.speak(spoken,
          settings: settings, title: document.fileName);
    }
  }

  Future<void> _openSavedBook(
      ScanHistoryItem item, SettingsService settings, AppLocalizations l10n,
      {int page = 0}) async {
    final path = item.sourcePath;
    if (path != null) {
      await _openFileFromPath(path, settings, l10n,
          page: page,
          start: item.startPage,
          end: item.endPage,
          bookId: item.id);
      return;
    }
    final rawContent = item.content.trim();
    final chunks = rawContent.contains('--- [Page Break] ---')
        ? rawContent
            .split('--- [Page Break] ---')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList()
        : <String>[rawContent];
    final pages = <PdfPageInfo>[];
    for (int i = 0; i < chunks.length; i++) {
      pages.add(
        PdfPageInfo(
          pageNumber: i + 1,
          text: chunks[i],
          needsOcr: false,
          ocrCompleted: true,
        ),
      );
    }
    if (pages.isEmpty) {
      pages.add(
        PdfPageInfo(
          pageNumber: 1,
          text: item.title,
          needsOcr: false,
          ocrCompleted: true,
        ),
      );
    }
    final selectedPage = page.clamp(0, pages.length - 1);
    _savedBook.value = item.id;
    _openPath.value = null;
    _openPage.value = selectedPage;
    if (!_restoringBook) _openAudioSecond.value = 0;
    _storeReaderSession();
    setState(() {
      _pdfSource = null;
      _photoPagesBytes = null;
      _document = ProcessedPdfDocument(
        fileName: item.title,
        totalPages: pages.length,
        pages: pages,
        isOffline: item.isOffline,
      );
      _currentPageIndex = selectedPage;
      _bookKeys[_document!] = 'book:${item.id}';
    });
    _checkAndAutoOcrCurrentPage();
  }

  Future<void> _openFileFromPath(
    String filePath,
    SettingsService settings,
    AppLocalizations l10n, {
    int page = 0,
    int start = 1,
    int end = 0,
    String? bookId,
  }) async {
    if (_work != null) return;
    final work = DocumentWork(isPersian: l10n.isPersian);
    _work = work;
    final operation = ++_operationGeneration;
    try {
      final file = File(filePath);
      final exists = await file.exists();
      if (!mounted || work.isCancelled) return;
      if (!exists) {
        _openPath.value = null;
        _savedBook.value = null;
        _storeReaderSession();
        throw FileSystemException(l10n.tx(
            'The original file is unavailable. Select it again.',
            'فایل اصلی در دسترس نیست. دوباره آن را انتخاب کنید.'));
      }
      _savedBook.value = bookId;
      _openPath.value = filePath;
      _openPage.value = page;
      _openStart.value = start;
      _openEnd.value = end;
      if (!_restoringBook) _openAudioSecond.value = 0;
      _storeReaderSession();
      final fileName = filePath.split(Platform.pathSeparator).last;
      final ext = fileName.contains('.')
          ? fileName.split('.').last.toLowerCase()
          : 'txt';

      setState(() {
        _isLoading = true;
        _processingProgress = 0.0;
        _processingStatusText = l10n.translate('processing');
      });
      await work.start();
      work.checkpoint();
      late final Uint8List bytes;
      if (ext != 'pdf') {
        bytes = await file.readAsBytes();
        work.checkpoint();
        if (bytes.isEmpty) return;
      }

      ProcessedPdfDocument processed;
      _photoPagesBytes = null;
      if (DocumentFormats.images.contains(ext) || ext == 'cbz') {
        _pdfSource = null;
        _photoPagesBytes = await DocumentImageLoader.load(bytes, fileName);
        final photos = _photoPagesBytes ?? [];
        processed = ProcessedPdfDocument(
            fileName: fileName,
            totalPages: photos.length,
            pages: [
              for (var i = 0; i < photos.length; i++)
                PdfPageInfo(pageNumber: i + 1, text: '', needsOcr: true)
            ],
            isOffline: settings.isOfflineMode);
      } else if (ext == 'pdf') {
        _pdfSource = (path: filePath, bytes: null);
        processed = await PdfService.extractPdfFile(
          path: filePath,
          fileName: fileName,
          isOfflineMode: settings.isOfflineMode,
          onProgress: _preparationProgress,
          cancelled: work.whenCancelled,
          layoutHeading:
              settings.documentLayout ? l10n.tx('Heading', 'عنوان') : null,
        );
      } else if (ext == 'epub') {
        _pdfSource = null;
        processed = await PdfService.extractEpubDocumentAsync(
          fileBytes: bytes,
          fileName: fileName,
        );
      } else if (['odt', 'odp', 'ods'].contains(ext)) {
        _pdfSource = null;
        processed = await PdfService.extractOpenDocumentAsync(
            fileBytes: bytes, fileName: fileName);
      } else if (['docx', 'doc', 'docm', 'dotx'].contains(ext)) {
        _pdfSource = null;
        processed = await PdfService.extractWordDocumentAsync(
          fileBytes: bytes,
          fileName: fileName,
        );
      } else if (['pptx', 'ppt', 'pptm', 'ppsx'].contains(ext)) {
        _pdfSource = null;
        processed = await PdfService.extractPowerPointDocumentAsync(
          fileBytes: bytes,
          fileName: fileName,
        );
      } else if (['xlsx', 'xls', 'xlsm', 'xltx', 'csv', 'tsv'].contains(ext)) {
        _pdfSource = null;
        processed = await PdfService.extractExcelDocumentAsync(
          fileBytes: bytes,
          fileName: fileName,
        );
      } else if (ext == 'zip') {
        _pdfSource = null;
        processed = await PdfService.extractAudiobookZipAsync(
          fileBytes: bytes,
          fileName: fileName,
        );
      } else {
        _pdfSource = null;
        processed = await PdfService.extractTextDocumentAsync(
          fileBytes: bytes,
          fileName: fileName,
        );
      }

      work.checkpoint();
      if (!mounted || operation != _operationGeneration) return;
      if (processed.totalPages == 0) {
        throw const FormatException('The document has no pages.');
      }
      final lastPage =
          end == 0 ? processed.totalPages : end.clamp(1, processed.totalPages);
      processed = _pageSubset(processed, start.clamp(1, lastPage), lastPage);
      setState(() {
        _document = processed;
        _currentPageIndex = page.clamp(0, processed.totalPages - 1);
        _openPage.value = _currentPageIndex;
        _bookKeys[processed] =
            bookId == null ? 'file:$filePath' : 'book:$bookId';
      });
    } on DocumentProcessingCancelled {
      // Keep any previous document available.
    } catch (e) {
      if (mounted && !work.isCancelled && operation == _operationGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(l10n.translate('error_general', {'error': e.toString()})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      await _finishDocumentWork(work);
      if (mounted && operation == _operationGeneration) {
        setState(() => _isLoading = false);
      }
    }
    if (!work.isCancelled && mounted && operation == _operationGeneration) {
      _checkAndAutoOcrCurrentPage();
    }
  }

  /// Take Photo from Built-in In-App Camera & Open / Convert to Audiobook
  Future<void> _takePhotoFromCameraForReader(
    SettingsService settings,
    AppLocalizations l10n,
  ) async {
    try {
      final automatic = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: Text(l10n.tx('Document photo', 'عکس از سند')),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.tx(
                  'Scan one page automatically', 'اسکن خودکار یک صفحه')),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(
                  l10n.tx('Take photos manually', 'گرفتن عکس به‌صورت دستی')),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.translate('cancel')),
            ),
          ],
        ),
      );
      if (!mounted || automatic == null) return;
      if (automatic) {
        await _openBatchBookScanner(settings, l10n, singlePage: true);
        return;
      }
      final capturedPages = await InAppCameraScreen.captureMultiple(
        context,
        offline: settings.isOfflineMode,
        title: l10n.isPersian
            ? 'عکس‌برداری با دوربین داخلی و مطالعه'
            : 'Take Photo with In-App Camera',
      );
      if (!mounted) {
        if (capturedPages is CapturedPageStore) await capturedPages.close();
        return;
      }
      if (capturedPages.isEmpty) return;

      _pdfSource = null;
      _photoPagesBytes = capturedPages;
      final pages = <PdfPageInfo>[];
      for (int i = 0; i < capturedPages.length; i++) {
        pages.add(
          PdfPageInfo(
            pageNumber: i + 1,
            text: '',
            needsOcr: true,
            ocrCompleted: false,
          ),
        );
      }

      final doc = ProcessedPdfDocument(
        fileName: 'Camera_Capture_${DateTime.now().millisecondsSinceEpoch}.jpg',
        totalPages: pages.length,
        pages: pages,
        isOffline: settings.isOfflineMode,
      );

      await _showChoosePagesAndProcessDialog(
        loadedDoc: doc,
        settings: settings,
        l10n: l10n,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(l10n.translate('error_general', {'error': e.toString()})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  /// Read from Web Page Link (URL) Dialog
  Future<void> _readFromWebUrlDialog(
    SettingsService settings,
    AppLocalizations l10n,
  ) async {
    final urlCtrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            l10n.isPersian
                ? 'خواندن از لینک صفحه وب (URL)'
                : 'Read from Web Page Link (URL)',
          ),
          content: TextField(
            controller: urlCtrl,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText:
                  l10n.isPersian ? 'آدرس اینترنتی صفحه وب' : 'Web Page URL',
              hintText: 'https://example.com/article',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(l10n.translate('cancel')),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.public_rounded),
              label: Text(
                  l10n.isPersian ? 'دریافت و مطالعه صفحه' : 'Fetch & Read'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryCyan,
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.pop(ctx, urlCtrl.text.trim()),
            ),
          ],
        );
      },
    );

    if (url == null || url.isEmpty || !mounted || _work != null) return;

    final work = DocumentWork(isPersian: l10n.isPersian);
    _work = work;
    final operation = ++_operationGeneration;
    setState(() {
      _isLoading = true;
      _processingProgress = 0.3;
      _processingStatusText = l10n.isPersian
          ? 'در حال دریافت و استخراج متن صفحه وب...'
          : 'Fetching and extracting web page content...';
    });

    try {
      await work.start();
      work.checkpoint();
      final doc = await PdfService.extractFromWebUrl(url);
      work.checkpoint();
      if (!mounted || operation != _operationGeneration) return;
      _pdfSource = null;
      _photoPagesBytes = null;
      setState(() {
        _document = doc;
        _currentPageIndex = 0;
      });
      unawaited(_rememberTextBook(doc, settings));
    } on DocumentProcessingCancelled {
      // Ignore a completed web response after cancellation.
    } catch (e) {
      if (!mounted || work.isCancelled || operation != _operationGeneration) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(l10n.translate('error_general', {'error': e.toString()})),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      await _finishDocumentWork(work);
      if (mounted && operation == _operationGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Read / Paste Direct Text Dialog
  Future<void> _readDirectTextDialog(
    SettingsService settings,
    AppLocalizations l10n,
  ) async {
    final titleCtrl = TextEditingController(
      text: l10n.isPersian ? 'متن من' : 'My Text Document',
    );
    final textCtrl = TextEditingController();

    final submitted = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            l10n.isPersian
                ? 'خواندن و تبدیل مستقیم متن به کتاب صوتی'
                : 'Read & Convert Direct Text',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleCtrl,
                    decoration: InputDecoration(
                      labelText: l10n.isPersian
                          ? 'عنوان متن یا کتاب'
                          : 'Document Title',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: textCtrl,
                    maxLines: 7,
                    decoration: InputDecoration(
                      labelText: l10n.isPersian
                          ? 'متن خود را اینجا بنویسید یا جای‌گذاری (Paste) کنید'
                          : 'Type or paste your text here',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel')),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.volume_up_rounded),
              label: Text(l10n.isPersian
                  ? 'باز کردن در کتاب‌خوان و پخش'
                  : 'Open in Reader'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryCyan,
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        );
      },
    );

    if (submitted != true || textCtrl.text.trim().isEmpty || !mounted) return;
    final doc = PdfService.createFromDirectText(
      text: textCtrl.text,
      title: titleCtrl.text.trim().isNotEmpty
          ? titleCtrl.text.trim()
          : 'Direct Text',
    );
    _pdfSource = null;
    _photoPagesBytes = null;
    setState(() {
      _document = doc;
      _currentPageIndex = 0;
    });
    unawaited(_rememberTextBook(doc, settings));
    _checkAndAutoOcrCurrentPage();
  }

  Future<void> _openInstantLiveReader(
    SettingsService settings,
    AppLocalizations l10n,
  ) async {
    EspeakTtsService.stop();
    final returnedText = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => InstantLiveReaderScreen(
          onSaveToNotes: (detectedText) {
            settings.addNote(
              NoteItem(
                id: DateTime.now().millisecondsSinceEpoch.toString(),
                title: l10n.isPersian
                    ? 'متن خوانش فوری زنده'
                    : 'Instant Live Reader Text',
                content: detectedText.trim(),
                source: 'ocr',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
                tags: const ['ocr'],
              ),
            );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  l10n.isPersian
                      ? 'متن در یادداشت‌های هوشمند ذخیره شد.'
                      : 'Saved to Smart Notes.',
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        ),
      ),
    );

    if (returnedText != null && returnedText.trim().isNotEmpty && mounted) {
      final doc = PdfService.createFromDirectText(
        text: returnedText.trim(),
        title: l10n.isPersian ? 'خوانش زنده دوربین' : 'Instant Live Reader',
      );
      _pdfSource = null;
      _photoPagesBytes = null;
      setState(() {
        _document = doc;
        _currentPageIndex = 0;
      });
      unawaited(_rememberTextBook(doc, settings));
      _checkAndAutoOcrCurrentPage();
    }
  }

  Future<void> _openBatchBookScanner(
    SettingsService settings,
    AppLocalizations l10n, {
    bool singlePage = false,
  }) async {
    EspeakTtsService.stop();
    final capturedPages = await Navigator.of(context).push<List<Uint8List>>(
      MaterialPageRoute(
        builder: (_) => BatchBookScannerScreen(singlePage: singlePage),
      ),
    );

    if (!mounted) {
      if (capturedPages is CapturedPageStore) await capturedPages.close();
      return;
    }
    if (capturedPages == null || capturedPages.isEmpty) return;

    _pdfSource = null;
    _photoPagesBytes = capturedPages;
    final pages = <PdfPageInfo>[];
    for (int i = 0; i < capturedPages.length; i++) {
      pages.add(
        PdfPageInfo(
          pageNumber: i + 1,
          text:
              capturedPages is CapturedPageStore ? capturedPages.textAt(i) : '',
          needsOcr: capturedPages is! CapturedPageStore ||
              capturedPages.textAt(i).isEmpty,
          ocrCompleted: capturedPages is CapturedPageStore &&
              capturedPages.textAt(i).isNotEmpty,
        ),
      );
    }

    final doc = ProcessedPdfDocument(
      fileName: singlePage
          ? 'Camera_Capture_${DateTime.now().millisecondsSinceEpoch}.jpg'
          : 'Batch_Book_${DateTime.now().millisecondsSinceEpoch} (${capturedPages.length} pages)',
      totalPages: pages.length,
      pages: pages,
      isOffline: settings.isOfflineMode,
    );

    await _showChoosePagesAndProcessDialog(
      loadedDoc: doc,
      settings: settings,
      l10n: l10n,
    );
  }

  Future<void> _confirmAndReset(
      BuildContext context, AppLocalizations l10n) async {
    final docName = _document?.fileName ??
        (l10n.isPersian ? 'مطالعه و اسناد' : 'Reading & Documents');
    final shouldExit = await showSafeConfirmDialog(
      context,
      title:
          l10n.isPersian ? 'خروج از مطالعه «$docName»' : 'Exit from "$docName"',
      message: l10n.isPersian
          ? 'آیا مطمئن هستید که می‌خواهید از مطالعه «$docName» خارج شوید؟'
          : 'Are you sure you want to exit from "$docName"?',
      confirmLabel: l10n.translate('exit_section_btn'),
    );
    if (shouldExit) {
      resetScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);
    if (_document != null && !_isLoading) {
      return _buildReader(settings, l10n);
    }
    final canTakePhoto = const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
    }.contains(Theme.of(context).platform);

    return Scaffold(
      body: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Reading & Documents Options when no document is open
              if (!hasActiveContent && !_isLoading) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. Instant Live Camera Reader
                        SizedBox(
                          height: 52,
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            autofocus: true,
                            icon: const Icon(Icons.sensors_rounded, size: 22),
                            label: Text(
                              l10n.isPersian
                                  ? 'خوانش زنده دوربین با راهنمای صوتی (Instant Live Camera Reader)'
                                  : 'Instant Live Camera Reader',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.successGreen,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: () =>
                                _openInstantLiveReader(settings, l10n),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // 2. Smart Batch Book Scan (Audio Edge Guidance & Auto Page-Turn)
                        SizedBox(
                          height: 52,
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.center_focus_strong_rounded,
                                size: 22),
                            label: Text(
                              l10n.isPersian
                                  ? 'اسکن هوشمند کتاب با راهنمای صوتی کادر و ورق‌زن خودکار'
                                  : 'Smart Batch Book Scan (Audio Edge Guidance & Auto Page-Turn)',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryCyan,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: () =>
                                _openBatchBookScanner(settings, l10n),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // 3. Unified Open Document or Create Audiobook from File
                        SizedBox(
                          height: 52,
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.file_open_rounded, size: 22),
                            label: Text(
                              l10n.isPersian
                                  ? 'باز کردن سند یا ساخت کتاب صوتی (PDF، EPUB، عکس، Word، PPT، اکسل، متن، ZIP)'
                                  : 'Open Document or Create Audiobook (PDF, EPUB, Photos, DOCX, TXT, PPTX, Excel, ZIP)',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.accentIndigo,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => _pickAndProcessStudioFile(
                              settings,
                              l10n,
                              useRangeAndExportWizard: true,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // 4. Take Photo from Camera
                        if (canTakePhoto) ...[
                          SizedBox(
                            height: 46,
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.camera_alt_rounded,
                                  size: 20),
                              label: Text(
                                l10n.isPersian
                                    ? 'عکس‌برداری با دوربین و مطالعه'
                                    : 'Take Photo from Camera',
                              ),
                              onPressed: () =>
                                  _takePhotoFromCameraForReader(settings, l10n),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],

                        // 5. Read from Web Page Link (URL)
                        SizedBox(
                          height: 46,
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.link_rounded, size: 20),
                            label: Text(
                              l10n.isPersian
                                  ? 'خواندن از لینک صفحه وب (Read from Web Page Link)'
                                  : 'Read from Web Page Link',
                            ),
                            onPressed: () =>
                                _readFromWebUrlDialog(settings, l10n),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // 6. Read / Paste Direct Text
                        SizedBox(
                          height: 46,
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.edit_note_rounded, size: 22),
                            label: Text(
                              l10n.isPersian
                                  ? 'خواندن و چسباندن مستقیم متن (Read / Paste Text Directly)'
                                  : 'Read / Paste Text Directly',
                            ),
                            onPressed: () =>
                                _readDirectTextDialog(settings, l10n),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // 7. Document Converter
                        SizedBox(
                          height: 46,
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.transform_rounded, size: 20),
                            label: Text(
                              l10n.isPersian
                                  ? 'مبدل فرمت فایل‌ها و اسناد (Document Converter)'
                                  : 'Document Converter',
                            ),
                            onPressed: () =>
                                ToolRoutes.open(context, ToolId.converter),
                          ),
                        ),
                        const SizedBox(height: 10),

                        // 8. Main Books & Files Management Section
                        SizedBox(
                          height: 50,
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.library_books_rounded,
                                size: 22),
                            label: Text(
                              l10n.isPersian
                                  ? 'مدیریت کتاب‌ها و فایل‌های تبدیل‌شده و خروجی‌ها (Books & Files Manager)'
                                  : 'Books & Files Manager (Converted, Saved & Exported)',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  AppTheme.primaryCyan.withValues(alpha: 0.18),
                              foregroundColor: AppTheme.primaryCyan,
                              side: const BorderSide(
                                  color: AppTheme.primaryCyan, width: 1.4),
                            ),
                            onPressed: () => _openBookManager(settings, l10n),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // Processing / Percentage Progress Indicator
              if (_isLoading)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Semantics(
                      liveRegion: settings.announceProgress,
                      child: Column(
                        children: [
                          CircularProgressIndicator(
                            value: _processingProgress > 0
                                ? _processingProgress
                                : null,
                            color: AppTheme.primaryCyan,
                          ),
                          const SizedBox(height: 16),
                          if (_processingProgress > 0) ...[
                            Text(
                              '${(_processingProgress * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                color: AppTheme.primaryCyan,
                              ),
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: _processingProgress,
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(8),
                              color: AppTheme.primaryCyan,
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextButton.icon(
                              onPressed: _work?.canCancel == false
                                  ? null
                                  : _cancelDocumentWork,
                              icon: const Icon(Icons.cancel_outlined),
                              label: Text(l10n.translate('cancel'))),
                          Text(
                            _processingStatusText.isNotEmpty
                                ? _processingStatusText
                                : l10n.translate('processing_pdf'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReader(SettingsService settings, AppLocalizations l10n) {
    final document = _document!;
    final page = document.pages[_currentPageIndex];
    final text = _formatPageWithNumber(page, settings, l10n);
    final showText = !settings.enableInternalTts || settings.showReaderText;
    final labels = <_ReaderAction, String>{
      _ReaderAction.library:
          l10n.tx('Books & Files Manager', 'مدیریت کتاب‌ها و فایل‌ها'),
      _ReaderAction.search:
          l10n.tx('Search in Document Pages', 'جستجو در صفحات سند'),
      _ReaderAction.addBookmark: l10n.translate('add_bookmark'),
      _ReaderAction.bookmarks: l10n.translate('bookmarks'),
      _ReaderAction.saveNote:
          l10n.tx('Save page to Notes', 'ذخیرهٔ صفحه در یادداشت‌ها'),
      _ReaderAction.copy: l10n.translate('copy_page'),
      _ReaderAction.share: l10n.translate('share_text'),
      if (_pdfSource != null || _photoPagesBytes != null)
        _ReaderAction.ocr:
            l10n.tx('Read Page Again', 'استخراج دوبارهٔ متن صفحه'),
      _ReaderAction.export: l10n.translate('export_btn'),
      _ReaderAction.close: l10n.tx('Close document', 'بستن سند'),
    };
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  '${document.fileName}\n${l10n.translate('page_stats', {
                        'current': '${_currentPageIndex + 1}',
                        'total': '${document.totalPages}',
                      })}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _goToPageDialog(context, l10n),
                      icon: const Icon(Icons.find_in_page_outlined),
                      label: Text(l10n.translate('go_to_page')),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.tx('Reading settings', 'تنظیمات خواندن'),
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                          builder: (_) =>
                              const ReadingPlaybackSettingsScreen()),
                    ),
                  ),
                  PopupMenuButton<_ReaderAction>(
                    tooltip: l10n.tx('Reader tools', 'ابزارهای کتاب‌خوان'),
                    icon: const Icon(Icons.build_outlined),
                    itemBuilder: (_) => [
                      for (final entry in labels.entries)
                        PopupMenuItem(
                            value: entry.key, child: Text(entry.value)),
                    ],
                    onSelected: (action) =>
                        _readerAction(action, text, settings, l10n),
                  ),
                ],
              ),
              if (_isOcringPage)
                LinearProgressIndicator(
                    value:
                        _processingProgress == 0 ? null : _processingProgress),
              if (_isOcringPage && _work?.canCancel == true)
                TextButton(
                    onPressed: _cancelDocumentWork,
                    child: Text(l10n.translate('cancel'))),
              if (page.ocrError != null)
                Text(l10n.tx('This page could not be read. ${page.ocrError}',
                    'متن این صفحه خوانده نشد. ${page.ocrError}')),
              Expanded(
                child: TtsPlaybackBar(
                  title: document.fileName,
                  textToSpeak: _spokenPageText(page, settings, l10n),
                  previousPage: _currentPageIndex > 0
                      ? () => _navigateToPage(_currentPageIndex - 1)
                      : null,
                  nextPage: _currentPageIndex + 1 < document.totalPages
                      ? () => _navigateToPage(_currentPageIndex + 1)
                      : null,
                  bookBody: showText
                      ? ListView(
                          key: ValueKey('page-scroll-$_currentPageIndex'),
                          children: [
                            ValueListenableBuilder<int>(
                              valueListenable: _highlightTick,
                              builder: (_, __, ___) =>
                                  _buildActiveSpokenWordBanner(),
                            ),
                            AccessibleOutputText(
                              key: ValueKey('document-page-$_currentPageIndex'),
                              text: text,
                              liveRegion: false,
                              label: l10n.tx('Page text', 'متن صفحه'),
                              maxLines: null,
                              style:
                                  const TextStyle(fontSize: 20, height: 1.65),
                              onSkipSelection: (selection) => _skipSelectedText(
                                  page, selection, text, l10n),
                            ),
                            if (_skippedText[page] != null)
                              TextButton(
                                onPressed: () {
                                  EspeakTtsService.stop();
                                  setState(() => _skippedText[page] = null);
                                },
                                child: Text(l10n.tx('Read all text again',
                                    'دوباره همهٔ متن خوانده شود')),
                              ),
                          ],
                        )
                      : const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _readerAction(_ReaderAction action, String text,
      SettingsService settings, AppLocalizations l10n) async {
    switch (action) {
      case _ReaderAction.library:
        await _openBookManager(settings, l10n);
      case _ReaderAction.search:
        await _showReaderSearch(l10n);
      case _ReaderAction.addBookmark:
        _addBookmarkDialog(context, l10n, settings);
      case _ReaderAction.bookmarks:
        _showBookmarksModal(context, l10n, settings);
      case _ReaderAction.saveNote:
        _savePageAsNote(context, settings, l10n);
      case _ReaderAction.copy:
        await Clipboard.setData(ClipboardData(text: text));
        _announceToScreenReader(l10n.tx('Page copied.', 'متن صفحه کپی شد.'));
      case _ReaderAction.share:
        await SharePlus.instance.share(ShareParams(
          text: text,
          subject: _document?.fileName,
        ));
      case _ReaderAction.ocr:
        await _ocrCurrentPdfPage(automatic: false);
      case _ReaderAction.export:
        _showExportDialog(context, l10n);
      case _ReaderAction.close:
        await _confirmAndReset(context, l10n);
    }
  }

  Future<void> _showReaderSearch(AppLocalizations l10n) async {
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title:
              Text(l10n.tx('Search in Document Pages', 'جستجو در صفحات سند')),
          content: SizedBox(
            width: 420,
            height: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                      labelText: l10n.tx('Search text', 'متن جستجو')),
                  onChanged: (value) {
                    _performSearch(value);
                    update(() {});
                  },
                ),
                Expanded(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final index in _searchMatchingPages)
                        ListTile(
                          title: Text(l10n.tx(
                              'Page ${index + 1}', 'صفحهٔ ${index + 1}')),
                          onTap: () => Navigator.pop(dialogContext, index),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.translate('cancel'))),
          ],
        ),
      ),
    );
    if (mounted && result != null) await _navigateToPage(result);
  }

  Widget _buildActiveSpokenWordBanner() {
    final playback = EspeakTtsService.playbackState.value;
    String? activeSpokenWord;

    if (playback.isPlaying && playback.currentChunkText.trim().isNotEmpty) {
      final needle = playback.currentChunkText.trim();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final elapsedMs = math.max(0, nowMs - playback.currentChunkStartedAtMs);
      final durationMs = math.max(1, playback.currentChunkDurationMs);
      final ratio = (elapsedMs / durationMs).clamp(0.0, 0.999);

      final wordMatches = RegExp(r'\S+').allMatches(needle).toList();
      if (wordMatches.isNotEmpty) {
        final targetCharInChunk = (ratio * needle.length).floor();
        RegExpMatch chosen = wordMatches.first;
        for (final m in wordMatches) {
          if (m.start <= targetCharInChunk) {
            chosen = m;
          } else {
            break;
          }
        }
        activeSpokenWord = chosen.group(0);
      }
    }

    if (activeSpokenWord == null || activeSpokenWord.isEmpty) {
      return const SizedBox.shrink();
    }

    return ExcludeSemantics(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.primaryCyan.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppTheme.primaryCyan.withValues(alpha: 0.45),
          ),
        ),
        child: Text(
          activeSpokenWord,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: AppTheme.primaryCyan,
          ),
        ),
      ),
    );
  }
}
