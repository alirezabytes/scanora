import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/captcha_result.dart';
import '../../services/pdf/document_formats.dart';
import '../../services/captcha/captcha_solver_service.dart';
import '../../services/settings_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/accessible_output_text.dart';
import '../widgets/in_app_camera_screen.dart';
import '../widgets/online_access_guard.dart';
import '../widgets/tts_playback_bar.dart';

class CaptchaSolverScreen extends StatefulWidget {
  final GlobalKey<CaptchaSolverScreenState>? customKey;
  final void Function(Uint8List imageBytes)? onSendToImageToText;
  final void Function(Uint8List imageBytes)? onSendToImageDescription;
  final void Function(Uint8List imageBytes)? onImageChanged;

  const CaptchaSolverScreen({
    Key? key,
    this.customKey,
    this.onSendToImageToText,
    this.onSendToImageDescription,
    this.onImageChanged,
  }) : super(key: key ?? customKey);

  @override
  State<CaptchaSolverScreen> createState() => CaptchaSolverScreenState();
}

class CaptchaSolverScreenState extends State<CaptchaSolverScreen> {
  Uint8List? _selectedImageBytes;
  bool _isSolving = false;
  CaptchaResult? _latestResult;

  bool get hasActiveContent =>
      _selectedImageBytes != null || _latestResult != null;
  Uint8List? get currentImageBytes => _selectedImageBytes;

  Future<void> loadExternalImage(Uint8List bytes,
      {CaptchaResult? solved}) async {
    if (!mounted || bytes.isEmpty) return;
    if (_selectedImageBytes != null &&
        _selectedImageBytes!.length == bytes.length &&
        _latestResult != null) {
      return;
    }
    final settings = Provider.of<SettingsService>(context, listen: false);
    final l10n = AppLocalizations.of(context);
    setState(() {
      _selectedImageBytes = bytes;
      _latestResult = solved;
    });
    widget.onImageChanged?.call(bytes);
    if (solved == null) await _solve(settings, l10n);
  }

  void resetScreen() {
    EspeakTtsService.stop();
    setState(() {
      _selectedImageBytes = null;
      _latestResult = null;
      _isSolving = false;
    });
  }

  void _announce(AppLocalizations l10n, String text) {
    if (!mounted) return;
    try {
      SemanticsService.sendAnnouncement(
          View.of(context), text, l10n.textDirection);
    } catch (_) {}
  }

  Future<void> _solve(SettingsService settings, AppLocalizations l10n) async {
    if (_selectedImageBytes == null) return;
    if (!await OnlineAccessGuard.require(context, settings) || !mounted) return;

    setState(() {
      _isSolving = true;
      _latestResult = null;
    });
    if (settings.isOfflineMode) {
      _announce(l10n, l10n.translate('solving_captcha'));
    } else {
      OnlineAccessGuard.announceProcessing(context, settings);
    }

    try {
      final result = await CaptchaSolverService.solve(
        imageBytes: _selectedImageBytes!,
        isOfflineMode: settings.isOfflineMode,
        activeProvider: settings.activeProvider,
        apiKey: settings.getApiKey(settings.activeProvider),
        modelName: settings.getSelectedModel(settings.activeProvider),
        customBaseUrl: settings.customBaseUrl,
        thinkingEffort: settings.thinkingEffort,
        isPersian: l10n.isPersian,
      );

      if (mounted) {
        setState(() {
          _latestResult = result;
          _isSolving = false;
        });

        _announce(
          l10n,
          l10n.isPersian
              ? 'پاسخ کپچا: ${result.displayText}'
              : 'Captcha solved: ${result.displayText}',
        );
        if (settings.enableInternalTts && settings.autoReadOnOpen) {
          EspeakTtsService.speak(result.displayText, settings: settings);
        }

        if (settings.autoCopyCaptcha) {
          Clipboard.setData(ClipboardData(text: result.finalClipboardValue));
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.translate('result_copied')),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSolving = false;
        });
        final err = l10n.translate('error_general', {'error': e.toString()});
        _announce(l10n, err);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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
            setState(() => _selectedImageBytes = bytes);
            widget.onImageChanged?.call(bytes);
            await _solve(settings, l10n);
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
          setState(() => _selectedImageBytes = bytes);
          widget.onImageChanged?.call(bytes);
          await _solve(settings, l10n);
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

  /// Uses the standard In-App Camera (`InAppCameraScreen`) instead of launching the external OS camera.
  Future<void> _pickFromCamera(
      SettingsService settings, AppLocalizations l10n) async {
    final bytes = await InAppCameraScreen.capture(
      context,
      onlineTask: OnlineTask.vision,
      title: l10n.translate('source_camera'),
    );
    if (bytes != null && bytes.isNotEmpty && mounted) {
      setState(() {
        _selectedImageBytes = bytes;
      });
      widget.onImageChanged?.call(bytes);
      await _solve(settings, l10n);
    }
  }

  void _copyResult(AppLocalizations l10n) {
    if (_latestResult == null) return;
    Clipboard.setData(ClipboardData(text: _latestResult!.finalClipboardValue));
    final msg = l10n.translate('result_copied');
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
              // 1. Clean Action Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.translate('captcha_title'),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.translate('captcha_desc'),
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
                              const Icon(Icons.photo_library_rounded, size: 22),
                          label: Text(
                            l10n.isPersian
                                ? 'انتخاب تصویر کپچا'
                                : 'Select Captcha Image',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _isSolving
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
                          onPressed: _isSolving
                              ? null
                              : () => _pickFromCamera(settings, l10n),
                        ),
                      ),
                      if (_selectedImageBytes != null && !_isSolving) ...[
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
                      if (hasActiveContent && !_isSolving) ...[
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

              // 2. Solving Progress Indicator
              if (_isSolving)
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
                            l10n.translate('solving_captcha'),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // 3. Solved Result Card
              if (!_isSolving && _latestResult != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 18, horizontal: 14),
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: AppTheme.primaryCyan
                                    .withValues(alpha: 0.4)),
                          ),
                          child: Center(
                            child: AccessibleOutputText(
                              text: _latestResult!.displayText,
                              label: l10n.tx('Captcha answer', 'پاسخ کپچا'),
                              showLabel: false,
                              liveRegion: false,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 2.0,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TtsPlaybackBar(
                          textToSpeak: _latestResult!.displayText,
                          title: l10n.isPersian
                              ? 'پخش کد کپچا'
                              : 'Captcha Code Audio',
                        ),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            ElevatedButton.icon(
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: Text(l10n.translate('copy_result')),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryCyan,
                                foregroundColor: Colors.black,
                              ),
                              onPressed: () => _copyResult(l10n),
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: Text(l10n.translate('clear')),
                              onPressed: resetScreen,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 4. Image Preview
              if (_selectedImageBytes != null) ...[
                ExcludeSemantics(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 160),
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

              // 5. Empty state
              if (!_isSolving &&
                  _latestResult == null &&
                  _selectedImageBytes == null)
                Container(
                  margin: const EdgeInsets.only(top: 24),
                  padding: const EdgeInsets.all(32),
                  alignment: Alignment.center,
                  child: Column(
                    children: [
                      Icon(
                        Icons.security_rounded,
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
