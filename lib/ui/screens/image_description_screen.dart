import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../l10n/app_localizations.dart';
import '../../models/note_item.dart';
import '../../services/pdf/document_formats.dart';
import '../../services/ai/ai_service.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/a11y/reader_feedback.dart';
import '../../services/ocr/camera_diagnostics.dart';
import '../../services/settings_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../../services/vision/image_description_service.dart';
import '../theme/app_theme.dart';
import '../widgets/accessible_output_text.dart';
import '../widgets/in_app_camera_screen.dart';
import '../widgets/online_access_guard.dart';
import '../widgets/tts_playback_bar.dart';

class ImageDescriptionScreen extends StatefulWidget {
  final GlobalKey<ImageDescriptionScreenState>? customKey;
  final void Function(Uint8List imageBytes)? onSendToImageToText;
  final void Function(Uint8List imageBytes)? onSendToCaptchaSolver;
  final void Function(Uint8List imageBytes)? onImageChanged;

  const ImageDescriptionScreen({
    Key? key,
    this.customKey,
    this.onSendToImageToText,
    this.onSendToCaptchaSolver,
    this.onImageChanged,
  }) : super(key: key ?? customKey);

  @override
  State<ImageDescriptionScreen> createState() => ImageDescriptionScreenState();
}

class ImageDescriptionScreenState extends State<ImageDescriptionScreen> {
  Uint8List? _selectedImageBytes;
  ImageDescriptionResult? _result;
  bool _isDescribing = false;
  bool _isAskingQuestion = false;
  final TextEditingController _questionController = TextEditingController();
  final List<Map<String, String>> _chatHistory = [];
  final _diagnosticImages = Expando<Future<String?>>();

  bool get hasActiveContent => _selectedImageBytes != null || _result != null;
  Uint8List? get currentImageBytes => _selectedImageBytes;

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  Future<void> loadExternalImage(Uint8List bytes) async {
    if (!mounted || bytes.isEmpty) return;
    if (_selectedImageBytes != null &&
        _selectedImageBytes!.length == bytes.length &&
        _result != null) {
      return;
    }
    final settings = Provider.of<SettingsService>(context, listen: false);
    final l10n = AppLocalizations.of(context);
    setState(() {
      _selectedImageBytes = bytes;
      _chatHistory.clear();
    });
    widget.onImageChanged?.call(bytes);
    await _describeImage(settings, l10n);
  }

  void resetScreen() {
    EspeakTtsService.stop();
    setState(() {
      _selectedImageBytes = null;
      _result = null;
      _isDescribing = false;
      _isAskingQuestion = false;
      _chatHistory.clear();
      _questionController.clear();
    });
  }

  void _announce(AppLocalizations l10n, String message) {
    if (!mounted) return;
    try {
      AccessibilityService.announce(context, message,
          textDirection: l10n.textDirection,
          diagnosticSource: 'image-description');
    } catch (_) {}
  }

  Future<void> _describeImage(
      SettingsService settings, AppLocalizations l10n) async {
    if (_selectedImageBytes == null) return;
    if (!await OnlineAccessGuard.require(context, settings) || !mounted) return;

    setState(() {
      _isDescribing = true;
      _result = null;
    });

    if (settings.isOfflineMode) {
      _announce(
          l10n,
          l10n.tx('Analyzing and describing image...',
              'در حال تحلیل و توصیف تصویر...'));
    } else {
      OnlineAccessGuard.announceProcessing(context, settings);
    }

    try {
      final bytes = _selectedImageBytes!;
      final diagnostic = CameraDiagnostics.enabled
          ? await (_diagnosticImages[bytes] ??= CameraDiagnostics.image(
              'description_input', bytes,
              extension: 'img'))
          : null;
      final res = await ImageDescriptionService.describeImage(
        imageBytes: bytes,
        isOfflineMode: settings.isOfflineMode,
        activeProvider: settings.activeProvider,
        apiKey: settings.getApiKey(settings.activeProvider),
        modelName: settings.getSelectedModel(settings.activeProvider),
        customBaseUrl: settings.customBaseUrl,
        isPersian: l10n.isPersian,
        thinkingEffort: settings.thinkingEffort,
      );
      CameraDiagnostics.event('description.result', {
        'input': diagnostic,
        'text': res.description,
        'offline': settings.isOfflineMode,
      });

      if (!mounted) return;
      setState(() {
        _result = res;
        _isDescribing = false;
      });

      if (settings.enableInternalTts && settings.autoReadOnOpen) {
        ReaderFeedback.speak(context, res.description, settings,
            diagnosticSource: 'image-description');
      } else {
        _announce(
          l10n,
          l10n.isPersian
              ? 'توصیف تصویر آماده شد: ${res.description}'
              : 'Image description ready: ${res.description}',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDescribing = false;
      });
      final err = e.toString().replaceFirst('Exception: ', '');
      _announce(l10n, err);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _askQuestion(
    SettingsService settings,
    AppLocalizations l10n, [
    String? presetQuestion,
  ]) async {
    if (_selectedImageBytes == null || _isAskingQuestion) return;
    final question = (presetQuestion ?? _questionController.text).trim();
    if (question.isEmpty) return;
    if (!await OnlineAccessGuard.require(context, settings) || !mounted) return;

    if (presetQuestion == null) {
      _questionController.clear();
    }

    setState(() {
      _isAskingQuestion = true;
      _chatHistory.add({'role': 'user', 'text': question});
    });

    if (!settings.isOfflineMode) {
      OnlineAccessGuard.announceProcessing(context, settings);
    }

    try {
      final bytes = _selectedImageBytes!;
      final diagnostic = CameraDiagnostics.enabled
          ? await (_diagnosticImages[bytes] ??= CameraDiagnostics.image(
              'description_input', bytes,
              extension: 'img'))
          : null;
      String answer;
      if (settings.isOfflineMode) {
        answer = ImageDescriptionService.answerOfflineQuestion(
          question: question,
          result: _result,
          isPersian: l10n.isPersian,
        );
      } else {
        final historyWithoutLatest =
            _chatHistory.sublist(0, _chatHistory.length - 1);
        answer = await AIService.callChatWithImage(
          providerType: settings.activeProvider,
          apiKey: settings.getApiKey(settings.activeProvider),
          modelName: settings.getSelectedModel(settings.activeProvider),
          customBaseUrl: settings.customBaseUrl,
          imageBytes: bytes,
          initialDescription: _result?.description ?? '',
          chatHistory: historyWithoutLatest,
          userQuestion: question,
          isPersian: l10n.isPersian,
          thinkingEffort: settings.thinkingEffort,
        );
      }
      CameraDiagnostics.event('description.answer', {
        'input': diagnostic,
        'question': question,
        'text': answer,
        'offline': settings.isOfflineMode,
      });

      if (!mounted) return;
      setState(() {
        _chatHistory.add({'role': 'assistant', 'text': answer});
        _isAskingQuestion = false;
      });

      if (settings.enableInternalTts && settings.autoReadOnOpen) {
        ReaderFeedback.speak(context, answer, settings,
            diagnosticSource: 'image-description');
      } else {
        _announce(l10n, answer);
      }
    } catch (e) {
      if (!mounted) return;
      final errText = e.toString().replaceFirst('Exception: ', '');
      final msg = l10n.isPersian
          ? 'خطا در دریافت پاسخ: $errText'
          : 'Error getting answer: $errText';
      setState(() {
        _chatHistory.add({'role': 'assistant', 'text': msg});
        _isAskingQuestion = false;
      });
      _announce(l10n, msg);
    }
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
              _chatHistory.clear();
            });
            widget.onImageChanged?.call(bytes);
            await _describeImage(settings, l10n);
          }
        }
      } else {
        Uint8List? bytes;
        try {
          final picker = ImagePicker();
          final picked = await picker.pickImage(source: ImageSource.gallery);
          if (picked != null) {
            bytes = await picked.readAsBytes();
          }
        } catch (_) {
          final result = await FilePicker.pickFiles(type: FileType.image);
          if (result.isNotEmpty) {
            bytes = await result.first.readAsBytes();
          }
        }
        if (bytes != null && bytes.isNotEmpty && mounted) {
          setState(() {
            _selectedImageBytes = bytes;
            _chatHistory.clear();
          });
          widget.onImageChanged?.call(bytes);
          await _describeImage(settings, l10n);
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
  /// the external OS camera.
  Future<void> _takePhotoFromCamera(
      SettingsService settings, AppLocalizations l10n) async {
    try {
      final bytes = await InAppCameraScreen.capture(
        context,
        onlineTask: OnlineTask.vision,
        title: l10n.translate('source_camera'),
      );
      if (bytes != null && bytes.isNotEmpty && mounted) {
        setState(() {
          _selectedImageBytes = bytes;
          _chatHistory.clear();
        });
        widget.onImageChanged?.call(bytes);
        await _describeImage(settings, l10n);
      }
    } catch (_) {}
  }

  void _saveAsNote(SettingsService settings, AppLocalizations l10n) {
    if (_result == null || _result!.description.trim().isEmpty) return;
    final fullContent = StringBuffer(_result!.description);
    if (_chatHistory.isNotEmpty) {
      fullContent.writeln('\n\n--- Q&A ---');
      for (final msg in _chatHistory) {
        final prefix = msg['role'] == 'user'
            ? (l10n.isPersian ? 'سوال: ' : 'Q: ')
            : (l10n.isPersian ? 'پاسخ: ' : 'A: ');
        fullContent.writeln('$prefix${msg['text']}');
      }
    }

    settings.addNote(
      NoteItem(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: l10n.isPersian ? 'توصیف تصویر' : 'Image Description',
        content: fullContent.toString(),
        source: 'image_description',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        tags: ['vision', 'description'],
      ),
    );

    final msg = l10n.isPersian
        ? 'توصیف تصویر در یادداشت‌ها ذخیره شد.'
        : 'Image description saved to Notes.';
    _announce(l10n, msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);

    final presetQuestions = l10n.isPersian
        ? [
            'چه نوشته‌ها یا اعدادی در این عکس دیده می‌شود؟',
            'رنگ‌ها، اشیاء و جزئیات صحنه را دقیق‌تر بگو',
            'آیا عکس واضح و در مرکز کادر است؟',
            'اگر فردی در تصویر هست، ظاهر و حالتش چطور است؟',
          ]
        : [
            'What text or numbers are visible in this image?',
            'Describe the colors, objects, and layout in detail',
            'Is this photo clear, sharp, and well-centered?',
            'Are there any people in the photo? Describe them',
          ];

    return Scaffold(
      body: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Input & Mode Switch Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.isPersian
                            ? 'توصیف هوشمند تصویر و پرسش و پاسخ بصری'
                            : 'Smart Image Description & Visual Q&A',
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.isPersian
                            ? 'توصیف دقیق صحنه، اشیاء، رنگ‌ها و متون تصویر ویژه نابینایان + امکان گفتگو و سوال درباره عکس'
                            : 'Detailed scene, object, color & text description for blind users + interactive visual Q&A chat',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 50,
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon:
                              const Icon(Icons.image_search_rounded, size: 22),
                          label: Text(
                            l10n.isPersian
                                ? 'انتخاب تصویر برای توصیف (Select Image)'
                                : 'Select Image to Describe',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _isDescribing
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
                          onPressed: _isDescribing
                              ? null
                              : () => _takePhotoFromCamera(settings, l10n),
                        ),
                      ),
                      if (_selectedImageBytes != null && !_isDescribing) ...[
                        if (widget.onSendToImageToText != null) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 46,
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.document_scanner_rounded,
                                  size: 20, color: AppTheme.accentIndigo),
                              label: Text(
                                l10n.isPersian
                                    ? 'سوییچ همین تصویر به بخش تبدیل عکس به متن (Image to Text)'
                                    : 'Switch This Image to Image to Text',
                              ),
                              onPressed: () {
                                if (_selectedImageBytes != null) {
                                  widget.onSendToImageToText!(
                                      _selectedImageBytes!);
                                }
                              },
                            ),
                          ),
                        ],
                        if (widget.onSendToCaptchaSolver != null) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 46,
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.security_rounded,
                                  size: 20, color: AppTheme.warningAmber),
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
                      ],
                      if (hasActiveContent && !_isDescribing) ...[
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

              // 2. Loading Indicator
              if (_isDescribing)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 28, horizontal: 16),
                    child: Semantics(
                      liveRegion: true,
                      child: Column(
                        children: [
                          const CircularProgressIndicator(
                              color: AppTheme.primaryCyan),
                          const SizedBox(height: 16),
                          Text(
                            l10n.isPersian
                                ? 'در حال بررسی تصویر...'
                                : 'Analyzing the image...',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 3. Description Result Card
              if (!_isDescribing && _result != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10n.tx('Image Description', 'توصیف تصویر'),
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold),
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
                            text: _result!.description,
                            style: const TextStyle(fontSize: 15, height: 1.75),
                          ),
                        ),
                        if (_result!.offerOnlineSwitch &&
                            settings.isOfflineMode) ...[
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.wifi_rounded, size: 18),
                            label: Text(l10n.translate('switch_to_online')),
                            onPressed: () async {
                              await settings.toggleOfflineMode(false);
                              if (!mounted) return;
                              await _describeImage(settings, l10n);
                            },
                          ),
                        ],
                        const SizedBox(height: 16),
                        TtsPlaybackBar(
                          textToSpeak: _result!.description,
                          title: l10n.isPersian
                              ? 'پخش توصیف تصویر'
                              : 'Image Description Audio',
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
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: _result!.description));
                                final msg = l10n.translate('text_copied');
                                _announce(l10n, msg);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                      content: Text(msg),
                                      behavior: SnackBarBehavior.floating),
                                );
                              },
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
                              onPressed: () => _saveAsNote(settings, l10n),
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.share_rounded, size: 18),
                              label: Text(l10n.translate('share_text')),
                              onPressed: () => SharePlus.instance.share(
                                ShareParams(text: _result!.description),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // 4. Interactive Visual Q&A Chat Card
                Card(
                  semanticContainer: false,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.question_answer_rounded,
                                color: AppTheme.primaryCyan, size: 22),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.isPersian
                                    ? 'پرسش و پاسخ هوشمند درباره این تصویر (چت با هوش مصنوعی)'
                                    : 'Ask AI Questions About This Image (Visual Chat)',
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: presetQuestions.map((q) {
                            return ActionChip(
                              label:
                                  Text(q, style: const TextStyle(fontSize: 12)),
                              onPressed: _isAskingQuestion
                                  ? null
                                  : () => _askQuestion(settings, l10n, q),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 14),
                        if (_chatHistory.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Colors.grey.withValues(alpha: 0.25)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _chatHistory.map((msg) {
                                final isUser = msg['role'] == 'user';
                                final text = msg['text'] ?? '';
                                return Semantics(
                                  liveRegion: !isUser,
                                  container: true,
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: isUser
                                          ? AppTheme.accentIndigo
                                              .withValues(alpha: 0.15)
                                          : AppTheme.primaryCyan
                                              .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              isUser
                                                  ? (l10n.isPersian
                                                      ? 'سوال شما:'
                                                      : 'Your Question:')
                                                  : (l10n.isPersian
                                                      ? 'پاسخ هوش مصنوعی:'
                                                      : 'AI Answer:'),
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                                color: isUser
                                                    ? AppTheme.accentIndigo
                                                    : AppTheme.primaryCyan,
                                              ),
                                            ),
                                            if (!isUser)
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (settings
                                                      .enableInternalTts)
                                                    IconButton(
                                                      icon: const Icon(
                                                          Icons
                                                              .volume_up_rounded,
                                                          size: 18),
                                                      tooltip: l10n.isPersian
                                                          ? 'خواندن پاسخ با eSpeak-NG'
                                                          : 'Read Answer Aloud (eSpeak-NG)',
                                                      onPressed: () =>
                                                          EspeakTtsService
                                                              .speak(
                                                        text,
                                                        settings: settings,
                                                      ),
                                                    ),
                                                  IconButton(
                                                    icon: const Icon(
                                                        Icons.copy_rounded,
                                                        size: 18),
                                                    tooltip: l10n
                                                        .translate('copy_text'),
                                                    onPressed: () {
                                                      Clipboard.setData(
                                                          ClipboardData(
                                                              text: text));
                                                      _announce(
                                                          l10n,
                                                          l10n.translate(
                                                              'text_copied'));
                                                    },
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        AccessibleOutputText(
                                          text: text,
                                          liveRegion: false,
                                          style: const TextStyle(
                                              fontSize: 14, height: 1.6),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (_isAskingQuestion)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Semantics(
                              liveRegion: true,
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.5),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    l10n.isPersian
                                        ? 'هوش مصنوعی در حال بررسی تصویر و نگارش پاسخ است...'
                                        : 'AI is inspecting the image and writing an answer...',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _questionController,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) =>
                                    _askQuestion(settings, l10n),
                                decoration: InputDecoration(
                                  labelText: l10n.isPersian
                                      ? 'سوال خود را درباره این عکس بنویسید...'
                                      : 'Type your question about this image...',
                                  hintText: l10n.isPersian
                                      ? 'مثلاً: روی برچسب چه قیمتی نوشته شده؟'
                                      : 'e.g., What price is written on the label?',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              height: 52,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.send_rounded, size: 18),
                                label: Text(
                                    l10n.isPersian ? 'ارسال سوال' : 'Ask AI'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryCyan,
                                  foregroundColor: Colors.black,
                                ),
                                onPressed: _isAskingQuestion
                                    ? null
                                    : () => _askQuestion(settings, l10n),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 5. Image Preview
              if (_selectedImageBytes != null) ...[
                ExcludeSemantics(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 190),
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
              if (!_isDescribing &&
                  _result == null &&
                  _selectedImageBytes == null)
                Container(
                  margin: const EdgeInsets.only(top: 24),
                  padding: const EdgeInsets.all(32),
                  alignment: Alignment.center,
                  child: Column(
                    children: [
                      Icon(
                        Icons.image_search_rounded,
                        size: 60,
                        color: Colors.grey.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        l10n.translate('no_image_selected'),
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
