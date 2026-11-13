import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/converter/format_converter_service.dart';
import '../../services/pdf/document_batch_processor.dart';
import '../../services/pdf/document_formats.dart';
import '../../services/pdf/document_work.dart';
import '../../services/settings_service.dart';
import '../../services/storage/app_storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/accessible_output_text.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/output_file_name_field.dart';
import '../widgets/online_access_guard.dart';

class FormatConverterScreen extends StatefulWidget {
  final GlobalKey<FormatConverterScreenState>? customKey;
  final bool resumeSession;
  const FormatConverterScreen(
      {Key? key, this.customKey, this.resumeSession = false})
      : super(key: key ?? customKey);

  @override
  State<FormatConverterScreen> createState() => FormatConverterScreenState();
}

class FormatConverterScreenState extends State<FormatConverterScreen>
    with RestorationMixin {
  final _restoredPath = RestorableStringN(null);
  final _restoredTarget = RestorableStringN(null);
  final _restoredName = RestorableStringN(null);
  Future<Uint8List> Function()? _readSource;
  String? _sourceFileName;
  String? _sourceFilePath;
  String _outputStem = '';
  int _sourceFileSize = 0;
  bool _isConverting = false;
  int _progressPercent = 0;
  String _progressStatus = '';
  DocumentWork? _work;

  TargetFormat? _selectedTarget;
  FormatConverterResult? _lastResult;

  bool get hasActiveContent => _sourceFileName != null || _work != null;

  @override
  String get restorationId => 'converter';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_restoredPath, 'source');
    registerForRestoration(_restoredTarget, 'target');
    registerForRestoration(_restoredName, 'name');
    if (!initialRestore) return;
    if (widget.resumeSession && _restoredPath.value == null) {
      final state = context.read<SettingsService>().readerSession('converter');
      if (state != null) {
        _restoredPath.value = state['path'] as String?;
        _restoredTarget.value = state['target'] as String?;
        _restoredName.value = state['name'] as String?;
      }
    }
    final path = _restoredPath.value;
    if (path == null) return;
    final file = File(path);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final size = await file.exists() ? await file.length() : 0;
      if (!mounted || _readSource != null || size == 0) return;
      setState(() {
        _readSource = file.readAsBytes;
        _sourceFilePath = path;
        _sourceFileName = file.uri.pathSegments.last;
        _sourceFileSize = size;
        _selectedTarget = TargetFormat.values
            .where((format) => format.name == _restoredTarget.value)
            .firstOrNull;
        _outputStem = _restoredName.value ??
            AppStorageService.sourceStem(_sourceFileName!);
      });
    });
  }

  void _saveConverterSession() {
    final path = _restoredPath.value;
    context.read<SettingsService>().rememberReaderSession(
        'converter',
        path == null
            ? null
            : {
                'path': path,
                'target': _restoredTarget.value,
                'name': _restoredName.value,
              });
  }

  @override
  void dispose() {
    _work?.cancel();
    _restoredPath.dispose();
    _restoredTarget.dispose();
    _restoredName.dispose();
    super.dispose();
  }

  void _announce(String message) {
    if (!mounted || message.trim().isEmpty) return;
    try {
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );
    } catch (_) {}
  }

  void resetScreen() {
    _work?.cancel();
    _work = null;
    _restoredPath.value = null;
    _restoredTarget.value = null;
    _restoredName.value = null;
    _saveConverterSession();
    setState(() {
      _readSource = null;
      _sourceFileName = null;
      _sourceFilePath = null;
      _sourceFileSize = 0;
      _selectedTarget = null;
      _isConverting = false;
      _progressPercent = 0;
      _progressStatus = '';
      _lastResult = null;
    });
  }

  Future<void> _cancelWork() async {
    final work = _work;
    if (work == null || !work.canCancel) return;
    if (!await confirmCancelOperation(context) ||
        !mounted ||
        !identical(_work, work) ||
        !work.canCancel) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    setState(() {
      work.cancel();
      _progressStatus = l10n.tx('Cancelling…', 'در حال لغو…');
    });
  }

  Future<void> _finishWork(DocumentWork work) async {
    await work.finish();
    if (!mounted || !identical(_work, work)) return;
    setState(() {
      _work = null;
      _isConverting = false;
    });
  }

  Future<void> _pickFile(AppLocalizations l10n) async {
    if (_work != null) return;
    try {
      final result = await FilePicker.pickFiles(
        type: Platform.isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isAndroid ? null : DocumentFormats.all,
      );
      if (!mounted || result.isEmpty || _work != null) return;
      final file = result.first;
      if (!DocumentFormats.all.contains(DocumentFormats.extension(file.name))) {
        throw const FormatException('Unsupported file format.');
      }
      final size = await file.length();
      if (!mounted || _work != null) return;
      _restoredPath.value = file.path;
      final name = AppStorageService.sourceStem(file.name);
      _restoredName.value = name;
      _saveConverterSession();
      setState(() {
        _readSource = file.readAsBytes;
        _sourceFileName = file.name;
        _sourceFilePath = file.path;
        _sourceFileSize = size ?? 0;
        _outputStem = name;
        _lastResult = null;
      });
    } catch (error) {
      if (!mounted) return;
      final message =
          l10n.translate('error_general', {'error': error.toString()});
      _announce(message);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _startConversion(
      SettingsService settings, AppLocalizations l10n) async {
    if (_readSource == null || _sourceFileName == null || _work != null) {
      return;
    }
    if (_selectedTarget == null) {
      final msg = l10n.isPersian
          ? 'لطفاً ابتدا یک فرمت خروجی مقصد انتخاب کنید.'
          : 'Please select a target output format first.';
      _announce(msg);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
      return;
    }

    final isImage = DocumentFormats.images
        .contains(DocumentFormats.extension(_sourceFileName!));
    if (isImage &&
        !await OnlineAccessGuard.require(context, settings,
            task: OnlineTask.ocr)) {
      return;
    }
    if (!mounted || _work != null || _readSource == null) return;
    final work = DocumentWork(isPersian: l10n.isPersian);
    setState(() {
      _work = work;
      _isConverting = true;
      _progressPercent = 0;
      _progressStatus = l10n.isPersian
          ? 'شروع تبدیل فرمت (۰ درصد)...'
          : 'Starting conversion (0%)...';
    });
    _announce(l10n.tx('Processing started.', 'پردازش شروع شد.'));

    try {
      await work.start();
      work.checkpoint();
      final usePdfPath = _sourceFilePath != null &&
          DocumentFormats.extension(_sourceFileName!) == 'pdf';
      final bytes = usePdfPath ? Uint8List(0) : await _readSource!();
      work.checkpoint();
      var lastAnnouncedPct = -10;
      final result = await FormatConverterService.convertAndSave(
        sourceBytes: bytes,
        sourceFileName: _sourceFileName!,
        sourceFilePath: _sourceFilePath,
        work: work,
        targetFormat: _selectedTarget!,
        outputStem: _outputStem,
        customExportDir: settings.exportDirectoryPath,
        isRtl: l10n.isRtl,
        settings: settings,
        beforeOcr: () async {
          if (!mounted ||
              work.isCancelled ||
              (!isImage &&
                  !await OnlineAccessGuard.require(context, settings,
                      task: OnlineTask.ocr))) {
            throw const DocumentProcessingCancelled();
          }
          if (mounted) {
            OnlineAccessGuard.announceProcessing(context, settings,
                task: OnlineTask.ocr);
          }
        },
        onProgress: (pct, status) {
          if (!mounted || !identical(_work, work) || work.isCancelled) return;
          setState(() {
            _progressPercent = pct;
            _progressStatus = status;
          });
          if (settings.announceProgress && pct >= lastAnnouncedPct + 10) {
            lastAnnouncedPct = pct;
            _announce(status);
          }
        },
      );

      if (mounted && identical(_work, work)) {
        setState(() {
          _lastResult = result;
          _isConverting = false;
          _progressPercent = 100;
        });
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              persist: false,
              content: Text(
                l10n.isPersian
                    ? 'فایل با موفقیت تبدیل شد: ${File(result.outputFilePath).name}'
                    : 'Converted successfully: ${File(result.outputFilePath).name}',
              ),
              action: SnackBarAction(
                label: l10n.isPersian ? 'باز کردن پوشه' : 'Open Folder',
                onPressed: () =>
                    AppStorageService.highlightFile(result.outputFilePath),
              ),
              duration: const Duration(seconds: 5),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } on DocumentProcessingCancelled {
      // Keep the source file and format selection available for a retry.
    } catch (e) {
      if (mounted && identical(_work, work) && !work.isCancelled) {
        setState(() => _isConverting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(l10n.translate('error_general', {'error': e.toString()})),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      await _finishWork(work);
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
              // Header Bar
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.isPersian
                              ? 'تبدیل فرمت اسناد و فایل‌ها'
                              : 'Multi-Format File Converter',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          l10n.isPersian
                              ? 'تبدیل آسان بین Word، PDF، متنی، Markdown و HTML با ذخیره مستقیم در پوشه اسکنورا'
                              : 'Convert seamlessly between Word, PDF, Text, Markdown & HTML with direct storage',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasActiveContent)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(l10n.isPersian ? 'فایل جدید' : 'New File'),
                      onPressed: _work == null ? resetScreen : null,
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // If no file loaded yet
              if (_sourceFileName == null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 40, horizontal: 20),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryCyan.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.transform_rounded,
                              size: 48, color: AppTheme.primaryCyan),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          l10n.isPersian
                              ? 'فایل مورد نظر برای تبدیل را انتخاب کنید'
                              : 'Select a document to convert',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.isPersian
                              ? 'پشتیبانی از فایل‌های: PDF, DOCX, DOC, TXT, MD, HTML, JSON'
                              : 'Supported formats: PDF, DOCX, DOC, TXT, MD, HTML, JSON',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(context).textTheme.bodySmall?.color),
                        ),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.file_open_rounded),
                          label: Text(l10n.isPersian
                              ? 'انتخاب فایل از دستگاه'
                              : 'Choose File from Device'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 14),
                          ),
                          onPressed: () => _pickFile(l10n),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                // Source File Information Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppTheme.accentIndigo
                                    .withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.insert_drive_file_rounded,
                                  color: AppTheme.primaryCyan),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _sourceFileName ?? '',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    _formatBytes(_sourceFileSize),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.color),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.swap_horiz_rounded),
                              tooltip: l10n.isPersian
                                  ? 'انتخاب فایل دیگر'
                                  : 'Change File',
                              onPressed:
                                  _work == null ? () => _pickFile(l10n) : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Target Format Selection Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_work == null) ...[
                          Text(
                            l10n.isPersian
                                ? 'فرمت مقصد برای خروجی را انتخاب کنید:'
                                : 'Select Target Output Format:',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: TargetFormat.values.map((format) {
                              final isSelected = _selectedTarget == format;
                              return ChoiceChip(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(format.icon,
                                        size: 16,
                                        color: isSelected
                                            ? Colors.black
                                            : AppTheme.primaryCyan),
                                    const SizedBox(width: 6),
                                    Text(format.label),
                                  ],
                                ),
                                selected: isSelected,
                                selectedColor: AppTheme.primaryCyan,
                                onSelected: (selected) {
                                  if (!selected) return;
                                  _restoredTarget.value = format.name;
                                  _saveConverterSession();
                                  setState(() => _selectedTarget = format);
                                },
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 12),
                          OutputFileNameField(
                            key: ValueKey(_sourceFileName),
                            initialName: _outputStem,
                            extension: _selectedTarget?.extensionName,
                            onChanged: (name) {
                              _restoredName.value = name;
                              _saveConverterSession();
                              setState(() => _outputStem = name);
                            },
                          ),
                        ],
                        if (_isConverting) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            liveRegion: settings.announceProgress,
                            label: _progressStatus,
                            value: '$_progressPercent%',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                LinearProgressIndicator(
                                  value: _progressPercent / 100.0,
                                  minHeight: 8,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _progressStatus.isNotEmpty
                                      ? _progressStatus
                                      : '$_progressPercent%',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                _work?.canCancel == true ? _cancelWork : null,
                            icon: const Icon(Icons.cancel_outlined),
                            label: Text(l10n.translate('cancel')),
                          ),
                        ],
                        if (_work == null) const SizedBox(height: 18),

                        // Convert Button
                        if (_work == null)
                          ElevatedButton.icon(
                            icon: const Icon(Icons.sync_alt_rounded),
                            label: Text(
                              l10n.tx('Convert Now', 'شروع تبدیل فرمت'),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryCyan,
                              foregroundColor: Colors.black,
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: (_selectedTarget == null ||
                                    _outputStem.trim().isEmpty ||
                                    _readSource == null)
                                ? null
                                : () => _startConversion(settings, l10n),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Success Result Card
                if (_lastResult != null)
                  Card(
                    color: Colors.green.withValues(alpha: 0.1),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.check_circle_rounded,
                                  color: Colors.greenAccent, size: 28),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l10n.isPersian
                                          ? 'تبدیل با موفقیت انجام شد!'
                                          : 'Conversion Successful!',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: Colors.greenAccent),
                                    ),
                                    Text(
                                      File(_lastResult!.outputFilePath).name,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '${l10n.isPersian ? "اندازه" : "Size"}: ${_formatBytes(_lastResult!.fileSizeBytes)}',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color),
                          ),
                          const SizedBox(height: 6),
                          AccessibleOutputText(
                            text: _lastResult!.outputFilePath,
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.primaryCyan),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.folder_open_rounded,
                                      size: 18),
                                  label: Text(l10n.isPersian
                                      ? 'باز کردن پوشه'
                                      : 'Open Folder'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.accentIndigo,
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: () =>
                                      AppStorageService.highlightFile(
                                          _lastResult!.outputFilePath),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                label: Text(l10n.translate('copy_text')),
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(
                                      text: _lastResult!.outputFilePath));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(l10n.isPersian
                                          ? 'آدرس فایل کپی شد.'
                                          : 'File path copied.'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

extension FileExt on File {
  String get name => path.contains(Platform.pathSeparator)
      ? path.split(Platform.pathSeparator).last
      : (path.contains('/') ? path.split('/').last : path);
}
