import '../widgets/accessible_dropdown_field.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/a11y/reader_feedback.dart';
import '../../models/note_item.dart';
import '../../services/pdf/document_formats.dart';
import '../../services/export/docx_exporter.dart';
import '../../services/ocr/ocr_service.dart';
import '../../services/ocr/camera_diagnostics.dart';
import '../../services/settings_service.dart';
import '../../services/storage/app_storage_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/accessible_output_text.dart';
import '../widgets/in_app_camera_screen.dart';
import '../widgets/online_access_guard.dart';
import '../widgets/output_file_name_field.dart';
import '../widgets/tts_playback_bar.dart';

class ImageToTextScreen extends StatefulWidget {
  final GlobalKey<ImageToTextScreenState>? customKey;
  final void Function(Uint8List imageBytes)? onSendToCaptchaSolver;
  final void Function(Uint8List imageBytes)? onSendToImageDescription;
  final void Function(Uint8List imageBytes)? onImageChanged;

  const ImageToTextScreen({
    Key? key,
    this.customKey,
    this.onSendToCaptchaSolver,
    this.onSendToImageDescription,
    this.onImageChanged,
  }) : super(key: key ?? customKey);

  @override
  State<ImageToTextScreen> createState() => ImageToTextScreenState();
}

class ImageToTextScreenState extends State<ImageToTextScreen> {
  static const _ocrTask = OnlineTask.ocr;

  Uint8List? _selectedImageBytes;
  String? _sourceFileName;
  String _extractedText = '';
  String _errorMessage = '';
  ScanRecognitionResult? _scanResult;
  bool _isProcessing = false;
  int _ocrProgressPercent = 0;

  bool get hasActiveContent =>
      _selectedImageBytes != null ||
      _extractedText.isNotEmpty ||
      _errorMessage.isNotEmpty;
  Uint8List? get currentImageBytes => _selectedImageBytes;

  Future<void> loadExternalImage(Uint8List bytes, {String? sourceName}) async {
    if (!mounted || bytes.isEmpty) return;
    if (_selectedImageBytes != null &&
        _selectedImageBytes!.length == bytes.length &&
        _extractedText.isNotEmpty) {
      return;
    }
    final settings = Provider.of<SettingsService>(context, listen: false);
    final l10n = AppLocalizations.of(context);
    setState(() {
      _selectedImageBytes = bytes;
      _sourceFileName = sourceName;
    });
    widget.onImageChanged?.call(bytes);
    await _extractText(settings, l10n);
  }

  void resetScreen() {
    EspeakTtsService.stop();
    setState(() {
      _selectedImageBytes = null;
      _sourceFileName = null;
      _extractedText = '';
      _errorMessage = '';
      _scanResult = null;
      _isProcessing = false;
      _ocrProgressPercent = 0;
    });
  }

  void _announce(AppLocalizations l10n, String message) {
    if (!mounted) return;
    try {
      AccessibilityService.announce(context, message,
          textDirection: l10n.textDirection, diagnosticSource: 'image-to-text');
    } catch (_) {}
  }

  Future<void> _extractText(SettingsService settings, AppLocalizations l10n,
      {HandwritingLanguage? handwriting}) async {
    if (_selectedImageBytes == null || _isProcessing) return;
    if (!await OnlineAccessGuard.require(context, settings, task: _ocrTask) ||
        !mounted) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _ocrProgressPercent = 0;
      _extractedText = '';
      _errorMessage = '';
      _scanResult = null;
    });

    if (settings.isOfflineMode) {
      _announce(l10n, l10n.translate('extracting_text'));
    } else {
      OnlineAccessGuard.announceProcessing(context, settings, task: _ocrTask);
    }

    try {
      int lastAnnouncedPct = 0;
      final result = await OcrService.processImage(
        imageBytes: _selectedImageBytes!,
        isOfflineMode: settings.isOfflineMode,
        activeProvider: settings.activeProvider,
        apiKey: settings.getApiKey(settings.activeProvider),
        modelName: settings.getSelectedModel(settings.activeProvider),
        customBaseUrl: settings.customBaseUrl,
        thinkingEffort: settings.thinkingEffort,
        isPersian: l10n.isPersian,
        useScanoraCloud: settings.useScanoraCloudOcr,
        handwriting: handwriting,
        onProgress: (pct) {
          if (!mounted) return;
          setState(() => _ocrProgressPercent = pct);
          if (settings.announceProgress &&
              pct >= lastAnnouncedPct + 25 &&
              pct <= 100) {
            lastAnnouncedPct = pct;
            _announce(
              l10n,
              l10n.isPersian
                  ? 'در حال استخراج متن: $pct درصد'
                  : 'Extracting text: $pct%',
            );
          }
        },
      );

      if (!mounted) return;

      String formattedText = result.text.trim();
      if (formattedText.isNotEmpty && settings.includePageNumbersInOutput) {
        final header = l10n.isPersian ? 'صفحه 1' : 'Page 1';
        if (!formattedText.startsWith('Page ') &&
            !formattedText.startsWith('صفحه ')) {
          formattedText = '$header\n\n$formattedText';
        }
      }

      setState(() {
        _scanResult = result;
        _extractedText = formattedText;
        _errorMessage = result.errorMessage ?? '';
        _isProcessing = false;
      });

      if (formattedText.isNotEmpty) {
        if (settings.autoCopyCaptcha) {
          await Clipboard.setData(ClipboardData(text: formattedText));
        }
        if (settings.enableInternalTts && settings.autoReadOnOpen) {
          CameraDiagnostics.event('speech.request', {
            'source': 'image-to-text',
            'output': 'built-in',
            'text': formattedText
          });
          EspeakTtsService.speak(formattedText, settings: settings);
        } else {
          final message = settings.enableInternalTts
              ? l10n.tx('Text extracted.', 'متن تصویر استخراج شد.')
              : l10n.tx('Text extracted. $formattedText',
                  'متن تصویر استخراج شد. $formattedText');
          CameraDiagnostics.event('speech.request', {
            'source': 'image-to-text',
            'output': 'screen-reader',
            'text': message
          });
          _announce(l10n, message);
        }
      } else if (result.errorMessage != null &&
          result.errorMessage!.isNotEmpty) {
        ReaderFeedback.speak(context, result.errorMessage!, settings,
            diagnosticSource: 'image-to-text');
      }
    } catch (e) {
      if (mounted) {
        final err = l10n.translate('error_general', {'error': e.toString()});
        setState(() {
          _errorMessage = err;
          _isProcessing = false;
        });
        _announce(l10n, err);
      }
    }
  }

  Future<void> _chooseHandwriting(
      SettingsService settings, AppLocalizations l10n) async {
    final language = await showDialog<HandwritingLanguage>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.tx('Handwriting language', 'زبان دست‌خط')),
        children: [
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, HandwritingLanguage.persian),
            child: Text(l10n.tx('Persian handwriting', 'دست‌خط فارسی')),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, HandwritingLanguage.english),
            child: Text(l10n.tx('English handwriting', 'دست‌خط انگلیسی')),
          ),
        ],
      ),
    );
    if (!mounted || language == null) return;
    await _extractText(settings, l10n, handwriting: language);
  }

  Future<void> _selectImageFromDevice(
      SettingsService settings, AppLocalizations l10n) async {
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: DocumentFormats.images,
        );
        if (result.isNotEmpty && result.first.path != null) {
          final bytes = await File(result.first.path!).readAsBytes();
          if (bytes.isNotEmpty && mounted) {
            setState(() {
              _selectedImageBytes = bytes;
              _sourceFileName = result.first.name;
            });
            widget.onImageChanged?.call(bytes);
            await _extractText(settings, l10n);
          }
        }
      } else {
        Uint8List? bytes;
        String? name;
        try {
          final picker = ImagePicker();
          final picked = await picker.pickImage(source: ImageSource.gallery);
          if (picked != null) {
            bytes = await picked.readAsBytes();
            name = picked.name;
          }
        } catch (_) {
          final result = await FilePicker.pickFiles(type: FileType.image);
          if (result.isNotEmpty) {
            bytes = await result.first.readAsBytes();
            name = result.first.name;
          }
        }
        if (bytes != null && bytes.isNotEmpty && mounted) {
          setState(() {
            _selectedImageBytes = bytes;
            _sourceFileName = name;
          });
          widget.onImageChanged?.call(bytes);
          await _extractText(settings, l10n);
        }
      }
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

  /// Opens the standard built-in In-App Camera (`InAppCameraScreen`) instead of launching
  /// the external OS camera app.
  Future<void> _takePhotoFromCamera(
      SettingsService settings, AppLocalizations l10n) async {
    try {
      final bytes = await InAppCameraScreen.capture(
        context,
        title: l10n.translate('source_camera'),
        onlineTask: _ocrTask,
      );
      if (bytes != null && bytes.isNotEmpty && mounted) {
        setState(() {
          _selectedImageBytes = bytes;
          _sourceFileName = l10n.tx('Camera capture', 'عکس دوربین');
        });
        widget.onImageChanged?.call(bytes);
        await _extractText(settings, l10n);
      }
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

  void _copyToClipboard(AppLocalizations l10n, {String? customText}) {
    final textToCopy = customText ?? _extractedText;
    if (textToCopy.isEmpty) return;
    Clipboard.setData(ClipboardData(text: textToCopy));
    final msg = l10n.translate('text_copied');
    _announce(l10n, msg);
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareText(AppLocalizations l10n, {String? customText}) async {
    final textToShare = customText ?? _extractedText;
    if (textToShare.isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(text: textToShare, subject: 'Scanora Text'),
      );
    } catch (e) {
      Clipboard.setData(ClipboardData(text: textToShare));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.isPersian
                ? 'متن در کلیپ‌بورد کپی شد.'
                : 'Text copied to clipboard.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _saveAsNote(
      BuildContext context, SettingsService settings, AppLocalizations l10n) {
    if (_extractedText.trim().isEmpty) return;
    final snippet = _extractedText.trim();
    final title =
        snippet.length > 30 ? '${snippet.substring(0, 30)}...' : snippet;

    settings.addNote(NoteItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      content: snippet,
      source: 'image_to_text',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      tags: ['image'],
    ));

    final msg = l10n.isPersian
        ? 'متن به یادداشت‌ها اضافه شد!'
        : 'Saved to Notes successfully!';
    _announce(l10n, msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Export dialog with NO default format selected (`String? format = null`),
  /// requiring the user to explicitly choose their desired export format.
  void _exportExtractedText(BuildContext context, AppLocalizations l10n) {
    if (_extractedText.trim().isEmpty) return;
    String? format;
    var outputStem = AppStorageService.sourceStem(
        _sourceFileName ?? l10n.tx('Extracted text', 'متن استخراج‌شده'));

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
                    extension: format,
                    onChanged: (value) =>
                        setDialogState(() => outputStem = value),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.translate('select_format'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: EdgeInsets.zero,
                    child: AccessibleDropdownField<String>(
                      initialValue: format,
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
                            value: 'docx',
                            child: Text('📘  Microsoft Word (.docx)')),
                        DropdownMenuItem(
                            value: 'wav',
                            child: Text('🎧  Audio WAV - eSpeak-NG (.wav)')),
                        DropdownMenuItem(
                            value: 'rtf', child: Text('📄  Rich Text (.rtf)')),
                        DropdownMenuItem(
                            value: 'txt', child: Text('📄  Plain Text (.txt)')),
                        DropdownMenuItem(
                            value: 'md', child: Text('📝  Markdown (.md)')),
                        DropdownMenuItem(
                            value: 'html',
                            child: Text('🌐  HTML Document (.html)')),
                      ],
                      onChanged: (val) {
                        setDialogState(() => format = val);
                      },
                    ),
                  ),
                ],
              )),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l10n.translate('cancel')),
                ),
                ElevatedButton(
                  onPressed: format == null || outputStem.trim().isEmpty
                      ? null
                      : () async {
                          final chosen = format!;
                          Navigator.pop(ctx);
                          await _executeExport(chosen, outputStem, l10n);
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
      String format, String outputStem, AppLocalizations l10n) async {
    try {
      final title = l10n.isPersian ? 'متن استخراج شده' : 'Extracted Text';
      final fileName = AppStorageService.outputName(outputStem, format);
      final settings = Provider.of<SettingsService>(context, listen: false);
      File file;

      if (format == 'wav') {
        final audioBytes = await EspeakTtsService.synthesizeToWavBytes(
          _extractedText,
          settings: settings,
        );
        file = await AppStorageService.saveFile(
          fileName: fileName,
          bytes: audioBytes,
          customDirectory: settings.exportDirectoryPath,
        );
      } else if (format == 'docx') {
        final bytes = DocxExporter.createDocx(
          title: title,
          paragraphs: _extractedText.split('\n'),
          isRtl: l10n.isPersian || l10n.isRtl,
        );
        file = await AppStorageService.saveFile(
          fileName: fileName,
          bytes: bytes,
          customDirectory: settings.exportDirectoryPath,
        );
      } else if (format == 'rtf') {
        final bytes = DocxExporter.createRtf(
          title: title,
          paragraphs: _extractedText.split('\n'),
          isRtl: l10n.isPersian || l10n.isRtl,
        );
        file = await AppStorageService.saveFile(
          fileName: fileName,
          bytes: bytes,
          customDirectory: settings.exportDirectoryPath,
        );
      } else if (format == 'txt') {
        file = await AppStorageService.saveString(
          fileName: fileName,
          content: _extractedText,
          customDirectory: settings.exportDirectoryPath,
        );
      } else if (format == 'md') {
        file = await AppStorageService.saveString(
          fileName: fileName,
          content: '# $title\n\n$_extractedText',
          customDirectory: settings.exportDirectoryPath,
        );
      } else {
        file = await AppStorageService.saveString(
          fileName: fileName,
          content:
              '<!DOCTYPE html><html><head><meta charset="utf-8"><title>${const HtmlEscape().convert(title)}</title></head><body><h1>${const HtmlEscape().convert(title)}</h1><p>${const HtmlEscape().convert(_extractedText).replaceAll("\n", "<br>")}</p></body></html>',
          customDirectory: settings.exportDirectoryPath,
        );
      }

      if (!mounted) return;
      final successMsg = l10n.translate('export_success', {'path': file.path});
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(successMsg),
            persist: false,
            action: SnackBarAction(
              label: l10n.isPersian ? 'باز کردن پوشه' : 'Open Folder',
              onPressed: () => AppStorageService.highlightFile(file.path),
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(l10n.translate('error_general', {'error': e.toString()})),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Clean, Logically Ordered Input Buttons Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.translate('image_to_text_title'),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.translate('image_to_text_desc'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 50,
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon:
                              const Icon(Icons.photo_library_rounded, size: 22),
                          label: Text(
                            l10n.isPersian
                                ? 'انتخاب تصویر (Select Image)'
                                : 'Select Image',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _isProcessing
                              ? null
                              : () => _selectImageFromDevice(settings, l10n),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 46,
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.camera_alt_rounded, size: 20),
                          label: Text(l10n.translate('source_camera')),
                          onPressed: _isProcessing
                              ? null
                              : () => _takePhotoFromCamera(settings, l10n),
                        ),
                      ),
                      if (_selectedImageBytes != null && !_isProcessing) ...[
                        TextButton(
                          onPressed: () => _extractText(settings, l10n),
                          child: Text(l10n.tx('Read this image again',
                              'خواندن دوبارهٔ همین تصویر')),
                        ),
                        if (widget.onSendToCaptchaSolver != null) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 46,
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.security_rounded,
                                  size: 20, color: AppTheme.accentIndigo),
                              label: Text(
                                l10n.isPersian
                                    ? 'سوییچ همین تصویر به بخش حل کد امنیتی (Captcha Solver)'
                                    : 'Switch This Image to Captcha Solver',
                              ),
                              onPressed: () {
                                if (_selectedImageBytes != null) {
                                  widget.onSendToCaptchaSolver!(
                                      _selectedImageBytes!);
                                }
                              },
                            ),
                          ),
                        ],
                        if (widget.onSendToImageDescription != null) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 46,
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.image_search_rounded,
                                  size: 20, color: AppTheme.primaryCyan),
                              label: Text(
                                l10n.isPersian
                                    ? 'سوییچ همین تصویر به بخش توصیف هوشمند تصویر (Image Description)'
                                    : 'Switch This Image to Image Description',
                              ),
                              onPressed: () {
                                if (_selectedImageBytes != null) {
                                  widget.onSendToImageDescription!(
                                      _selectedImageBytes!);
                                }
                              },
                            ),
                          ),
                        ],
                      ],
                      if (hasActiveContent && !_isProcessing) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 44,
                          width: double.infinity,
                          child: TextButton.icon(
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 20, color: AppTheme.errorRed),
                            label: Text(
                              l10n.translate('clear'),
                              style: const TextStyle(
                                  color: AppTheme.errorRed,
                                  fontWeight: FontWeight.bold),
                            ),
                            onPressed: resetScreen,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // 2. Processing Indicator
              if (_isProcessing)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 28, horizontal: 16),
                    child: Semantics(
                      liveRegion: settings.announceProgress,
                      child: Column(
                        children: [
                          const CircularProgressIndicator(
                              color: AppTheme.primaryCyan),
                          const SizedBox(height: 16),
                          Text(
                            '${l10n.translate('extracting_text')} ($_ocrProgressPercent%)',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                            value: _ocrProgressPercent / 100.0,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 3. Error Banner (if an error occurred)
              if (_errorMessage.isNotEmpty && !_isProcessing) ...[
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: Card(
                    color: Colors.red.withValues(alpha: 0.15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side:
                          BorderSide(color: Colors.red.withValues(alpha: 0.5)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.error_outline_rounded,
                                  color: Colors.redAccent, size: 24),
                              const SizedBox(width: 10),
                              Expanded(
                                child: AccessibleOutputText(
                                  text: _errorMessage,
                                  liveRegion: false,
                                  style: const TextStyle(
                                      fontSize: 13, height: 1.5),
                                ),
                              ),
                            ],
                          ),
                          if (settings.isOfflineMode &&
                              _selectedImageBytes != null) ...[
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.draw_outlined),
                              label: Text(
                                  l10n.tx('Read handwriting', 'خواندن دست‌خط')),
                              onPressed: () =>
                                  _chooseHandwriting(settings, l10n),
                            ),
                          ],
                          if (settings.isOfflineMode &&
                              (_scanResult?.offerOnlineSwitch ?? false)) ...[
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.wifi_rounded, size: 18),
                              label: Text(l10n.translate('switch_to_online')),
                              onPressed: () {
                                settings.toggleOfflineMode(false);
                                _extractText(settings, l10n);
                              },
                            ),
                          ] else if (!settings.isOfflineMode &&
                              settings.useScanoraCloudOcr) ...[
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.verified_user_rounded,
                                  size: 18),
                              label: Text(
                                l10n.isPersian
                                    ? 'تایید مجوز دسترسی در مرورگر و تلاش مجدد'
                                    : 'Approve Access Permission in Browser & Retry',
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryCyan,
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () => _extractText(settings, l10n),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 4. Extracted Text Result Card
              if (!_isProcessing && _extractedText.isNotEmpty) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                l10n.tx('Extracted Text', 'متن استخراج‌شده'),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Text(
                              (_scanResult?.isOffline ?? settings.isOfflineMode)
                                  ? l10n.tx('Without internet', 'بدون اینترنت')
                                  : l10n.tx('Online reading', 'خواندن آنلاین'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: settings.isOfflineMode
                                    ? AppTheme.warningAmber
                                    : AppTheme.primaryCyan,
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 20),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.grey.withValues(alpha: 0.25)),
                          ),
                          child: AccessibleOutputText(
                            text: _extractedText,
                            style: const TextStyle(fontSize: 15, height: 1.7),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TtsPlaybackBar(
                          textToSpeak: _extractedText,
                          title: l10n.isPersian
                              ? 'پخش متن استخراج‌شده'
                              : 'Extracted Text Audio',
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ElevatedButton.icon(
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: Text(l10n.translate('copy_text')),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryCyan,
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () => _copyToClipboard(l10n),
                            ),
                            ElevatedButton.icon(
                              icon:
                                  const Icon(Icons.note_add_rounded, size: 18),
                              label: Text(l10n.isPersian
                                  ? 'ذخیره در یادداشت'
                                  : 'Save to Notes'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.accentIndigo,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () =>
                                  _saveAsNote(context, settings, l10n),
                            ),
                            OutlinedButton.icon(
                              icon:
                                  const Icon(Icons.download_rounded, size: 18),
                              label: Text(l10n.translate('export_btn')),
                              onPressed: () =>
                                  _exportExtractedText(context, l10n),
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.share_rounded, size: 18),
                              label: Text(l10n.translate('share_text')),
                              onPressed: () => _shareText(l10n),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 5. Image Preview (if chosen)
              if (_selectedImageBytes != null) ...[
                ExcludeSemantics(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.darkBorder),
                      color: Colors.black12,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.memory(
                      _selectedImageBytes!,
                      fit: BoxFit.contain,
                      width: double.infinity,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 6. Empty State
              if (!_isProcessing &&
                  _extractedText.isEmpty &&
                  _selectedImageBytes == null &&
                  _errorMessage.isEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 24),
                  padding: const EdgeInsets.all(32),
                  alignment: Alignment.center,
                  child: Column(
                    children: [
                      Icon(
                        Icons.document_scanner_rounded,
                        size: 60,
                        color: Colors.grey.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.translate('no_text_extracted'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
