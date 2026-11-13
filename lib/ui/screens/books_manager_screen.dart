import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/scan_history_item.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/settings_service.dart';
import '../../services/storage/app_storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/accessible_output_text.dart';
import '../widgets/confirm_dialog.dart';

class _EscapeBackIntent extends Intent {
  const _EscapeBackIntent();
}

/// Returned when the user selects a book or exported file to open in the Reader.
class BookManagerSelection {
  final ScanHistoryItem? historyItem;
  final String? filePath;

  const BookManagerSelection({
    this.historyItem,
    this.filePath,
  });
}

/// Main Books & Files Management Screen (`مدیریت کتاب‌ها و فایل‌های تبدیل‌شده و خروجی‌ها`).
///
/// Replaces the old inline "Recent Document Management" with a full dedicated section
/// where users can view, search, open/read, inspect, and permanently delete:
/// 1. Converted & saved books/documents in Scanora (`settings.history`).
/// 2. Exported files and audiobooks stored on disk (`AppStorageService.getExportDirectory`).
class BooksManagerScreen extends StatefulWidget {
  const BooksManagerScreen({super.key});

  @override
  State<BooksManagerScreen> createState() => _BooksManagerScreenState();
}

class _BooksManagerScreenState extends State<BooksManagerScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<File> _exportedFiles = [];
  bool _loadingFiles = true;
  String _exportDirPath = '';
  final _savedWordCounts = <String, Future<int>>{};
  final _audioDurations = <String, Future<int?>>{};
  Future<void> _wordCountQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshExportedFiles();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refreshExportedFiles() async {
    if (!mounted) return;
    setState(() {
      _loadingFiles = true;
    });
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final dir = await AppStorageService.getExportDirectory(
          settings.exportDirectoryPath);
      _exportDirPath = dir.path;
      if (await dir.exists()) {
        final entities = await dir.list().toList();
        final files = entities.whereType<File>().toList();
        files.sort((a, b) {
          DateTime ma = DateTime.fromMillisecondsSinceEpoch(0);
          DateTime mb = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            ma = a.lastModifiedSync();
          } catch (_) {}
          try {
            mb = b.lastModifiedSync();
          } catch (_) {}
          return mb.compareTo(ma);
        });
        if (mounted) {
          setState(() {
            _exportedFiles = files;
            _loadingFiles = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _exportedFiles = [];
        _loadingFiles = false;
      });
    }
  }

  Future<void> _handleBack() async {
    final l10n = AppLocalizations.of(context);
    final isFa = l10n.isPersian;
    final sectionName =
        isFa ? 'مدیریت کتاب‌ها و فایل‌ها' : 'Books & Files Manager';

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
  }

  String _formatFileSize(int bytes, bool isFa) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _remainingTime(
      SettingsService settings, AppLocalizations l10n, String key,
      {String? savedText, File? audioFile}) {
    final position = settings.bookPosition(key);
    final words = position?['remainingWords'] as int?;
    final unread = position?['unreadPages'] as int? ?? 0;
    String label(int words) {
      if (position?['finished'] == true) {
        return l10n.tx('Finished', 'خوانده شده');
      }
      final seconds = (words * 60 / settings.effectiveTtsRate).ceil();
      final duration = _duration(l10n, seconds);
      if (unread == 0) {
        return l10n.tx('About $duration left', 'حدود $duration باقی مانده');
      }
      return words == 0
          ? l10n.tx(
              'Time available after OCR', 'زمان پس از خواندن تصویر مشخص می‌شود')
          : l10n.tx('At least $duration left. $unread pages need OCR.',
              'دست‌کم $duration باقی مانده. $unread صفحه هنوز به استخراج متن نیاز دارد.');
    }

    if (words != null) return Text(label(words));
    if (audioFile != null) {
      return FutureBuilder<int?>(
        future: _audioDurations.putIfAbsent(key, () => _wavDuration(audioFile)),
        builder: (_, snapshot) {
          final seconds = snapshot.data;
          if (seconds == null) return const SizedBox.shrink();
          final duration = _duration(l10n, seconds);
          return Text(
              l10n.tx('Audio duration $duration', 'مدت فایل صوتی $duration'));
        },
      );
    }
    if (savedText != null && savedText.isEmpty) {
      return Text(l10n.tx('Time available after opening the book',
          'زمان پس از باز کردن کتاب مشخص می‌شود'));
    }
    if (savedText == null || savedText.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<int>(
      future:
          _savedWordCounts.putIfAbsent(key, () => _countSavedWords(savedText)),
      builder: (_, snapshot) => snapshot.hasData
          ? Text(label(snapshot.data!))
          : const SizedBox.shrink(),
    );
  }

  static String _duration(AppLocalizations l10n, int seconds) => [
        if (seconds >= 3600)
          l10n.tx('${seconds ~/ 3600} hours', '${seconds ~/ 3600} ساعت'),
        if (seconds ~/ 60 % 60 > 0)
          l10n.tx(
              '${seconds ~/ 60 % 60} minutes', '${seconds ~/ 60 % 60} دقیقه'),
        if (seconds % 60 > 0 || seconds == 0)
          l10n.tx('${seconds % 60} seconds', '${seconds % 60} ثانیه'),
      ].join(l10n.isPersian ? ' و ' : ' ');

  static Future<int?> _wavDuration(File file) async {
    RandomAccessFile? input;
    try {
      input = await file.open();
      final header = await input.read(12);
      if (header.length != 12 ||
          String.fromCharCodes(header.take(4)) != 'RIFF' ||
          String.fromCharCodes(header.skip(8)) != 'WAVE') {
        return null;
      }
      final length = await input.length();
      var rate = 0;
      var data = 0;
      while ((await input.position()) + 8 <= length) {
        final chunk = await input.read(8);
        if (chunk.length < 8) return null;
        final tag = String.fromCharCodes(chunk.take(4));
        final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
        final start = await input.position();
        if (start + size > length) return null;
        if (tag == 'fmt ' && size >= 16) {
          final format = await input.read(16);
          if (format.length < 16) return null;
          rate = ByteData.sublistView(format).getUint32(8, Endian.little);
        }
        if (tag == 'data') data = size;
        if (data > 0 && rate > 0) return (data / rate).round();
        await input.setPosition(start + size + (size.isOdd ? 1 : 0));
      }
    } on FileSystemException {
      return null;
    } finally {
      await input?.close();
    }
    return null;
  }

  Future<int> _countSavedWords(String text) {
    final count = _wordCountQueue.then((_) => _countWordsOffThread(text));
    _wordCountQueue = count.then<void>((_) {}, onError: (Object _) {});
    return count;
  }

  static Future<int> _countWordsOffThread(String text) =>
      Isolate.run(() => RegExp(r'\S+')
          .allMatches(text.replaceAll('--- [Page Break] ---', ''))
          .length);

  Future<void> _previewBookDialog(
      ScanHistoryItem item, AppLocalizations l10n) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(item.title),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: AccessibleOutputText(
                text: item.content,
                style: const TextStyle(fontSize: 14, height: 1.7),
              ),
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel')),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(l10n.translate('copy_text')),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.content));
                AccessibilityService.announce(
                    context, l10n.translate('text_copied'));
              },
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_stories_rounded, size: 18),
              label: Text(l10n.isPersian ? 'باز کردن و مطالعه' : 'Open & Read'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryCyan,
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.of(context)
                    .pop(BookManagerSelection(historyItem: item));
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteSavedBook(
    ScanHistoryItem item,
    SettingsService settings,
    AppLocalizations l10n,
  ) async {
    final isFa = l10n.isPersian;
    final confirmed = await showSafeConfirmDialog(
      context,
      title: isFa ? 'حذف کامل کتاب از برنامه' : 'Delete Book Completely',
      message: isFa
          ? 'آیا از حذف کامل «${item.title}» از لیست کتاب‌ها و اسناد تبدیل‌شده اطمینان دارید؟'
          : 'Are you sure you want to permanently delete "${item.title}" from your converted books?',
      confirmLabel: isFa ? 'حذف کامل' : 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await settings.deleteHistoryItem(item.id);
    if (!mounted) return;
    final msg = isFa
        ? 'کتاب «${item.title}» به طور کامل حذف شد.'
        : '"${item.title}" deleted.';
    AccessibilityService.announce(context, msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _deleteAllSavedBooks(
    SettingsService settings,
    AppLocalizations l10n,
  ) async {
    final isFa = l10n.isPersian;
    final confirmed = await showSafeConfirmDialog(
      context,
      title: isFa
          ? 'حذف تمام کتاب‌ها و اسناد تبدیل‌شده'
          : 'Delete All Converted Books',
      message: isFa
          ? 'آیا مطمئن هستید که می‌خواهید تمام کتاب‌ها و اسناد ذخیره‌شده در تاریخچه برنامه را به صورت کامل حذف کنید؟'
          : 'Are you sure you want to permanently delete all converted books and documents from history?',
      confirmLabel: isFa ? 'حذف همه' : 'Delete All',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await settings.clearHistory();
    if (!mounted) return;
    final msg = isFa
        ? 'تمامی کتاب‌ها و اسناد ذخیره‌شده حذف شدند.'
        : 'All saved books and documents have been deleted.';
    AccessibilityService.announce(context, msg);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _deleteExportedFile(File file, AppLocalizations l10n) async {
    final isFa = l10n.isPersian;
    final fileName = file.path.split(Platform.pathSeparator).last;
    final confirmed = await showSafeConfirmDialog(
      context,
      title: isFa
          ? 'حذف کامل فایل از حافظه دستگاه'
          : 'Delete Exported File from Disk',
      message: isFa
          ? 'آیا مطمئن هستید که می‌خواهید فایل «$fileName» را به طور کامل از حافظه دستگاه حذف کنید؟ این عملیات غیرقابل بازگشت است.'
          : 'Are you sure you want to permanently delete "$fileName" from your device storage? This cannot be undone.',
      confirmLabel: isFa ? 'حذف کامل فایل' : 'Delete File',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
      await _refreshExportedFiles();
      if (!mounted) return;
      final msg = isFa
          ? 'فایل «$fileName» به طور کامل از حافظه حذف شد.'
          : 'File "$fileName" permanently deleted from storage.';
      AccessibilityService.announce(context, msg);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
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

  bool _isReadableDocumentExtension(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.pdf') ||
        lower.endsWith('.epub') ||
        lower.endsWith('.docx') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.html') ||
        lower.endsWith('.htm') ||
        lower.endsWith('.pptx') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.csv') ||
        lower.endsWith('.zip') ||
        lower.endsWith('.odt') ||
        lower.endsWith('.rtf') ||
        lower.endsWith('.srt') ||
        lower.endsWith('.json');
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);
    final isFa = l10n.isPersian;

    final savedBooks = settings.history
        .where((h) => h.type == ScanType.pdf || h.type == ScanType.document)
        .where((h) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return h.title.toLowerCase().contains(q) ||
          h.content.toLowerCase().contains(q);
    }).toList();

    final filteredFiles = _exportedFiles.where((f) {
      if (_searchQuery.isEmpty) return true;
      final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();

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
                    isFa ? 'مدیریت کتاب‌ها و فایل‌ها' : 'Books & Files Manager',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded),
                    tooltip: isFa ? 'بروزرسانی لیست فایل‌ها' : 'Refresh Files',
                    onPressed: _refreshExportedFiles,
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
                      // Search Box
                      TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          labelText: isFa
                              ? 'جستجو در کتاب‌ها و فایل‌های خروجی'
                              : 'Search Books & Exported Files',
                          hintText: isFa
                              ? 'نام کتاب، فایل یا متن داخل آن را بنویسید...'
                              : 'Enter book title, file name, or text...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear_rounded),
                                  tooltip: l10n.translate('clear'),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                )
                              : null,
                        ),
                        onChanged: (val) =>
                            setState(() => _searchQuery = val.trim()),
                      ),
                      const SizedBox(height: 18),

                      // Section 1: Converted & Saved Books in App
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Semantics(
                                      header: true,
                                      child: Text(
                                        isFa
                                            ? '📚 کتاب‌ها و اسناد تبدیل‌شده در برنامه (${savedBooks.length})'
                                            : '📚 Converted & Saved Books (${savedBooks.length})',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (savedBooks.isNotEmpty)
                                    TextButton.icon(
                                      icon: const Icon(
                                        Icons.delete_sweep_rounded,
                                        color: AppTheme.errorRed,
                                        size: 18,
                                      ),
                                      label: Text(
                                        isFa
                                            ? 'حذف همه کتاب‌ها'
                                            : 'Delete All Books',
                                        style: const TextStyle(
                                          color: AppTheme.errorRed,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                      onPressed: () =>
                                          _deleteAllSavedBooks(settings, l10n),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              if (savedBooks.isEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 20),
                                  child: Text(
                                    isFa
                                        ? 'هیچ کتاب یا سند تبدیل‌شده‌ای در برنامه یافت نشد.'
                                        : 'No converted or saved books found.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color,
                                    ),
                                  ),
                                )
                              else
                                ListView.separated(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: savedBooks.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 18),
                                  itemBuilder: (ctx, idx) {
                                    final item = savedBooks[idx];
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        MergeSemantics(
                                          child: Row(
                                            children: [
                                              const ExcludeSemantics(
                                                child: Icon(
                                                  Icons.menu_book_rounded,
                                                  color: AppTheme.primaryCyan,
                                                  size: 22,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      item.title,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 15,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${_formatDate(item.timestamp)} • ${item.modelOrEngine ?? (item.isOffline ? "Offline" : "Online")}',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.color,
                                                      ),
                                                    ),
                                                    _remainingTime(settings,
                                                        l10n, 'book:${item.id}',
                                                        savedText:
                                                            item.content),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            ElevatedButton.icon(
                                              icon: const Icon(
                                                  Icons.auto_stories_rounded,
                                                  size: 18),
                                              label: Text(
                                                isFa
                                                    ? 'باز کردن و مطالعه'
                                                    : 'Open & Read',
                                              ),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    AppTheme.primaryCyan,
                                                foregroundColor: Colors.black,
                                              ),
                                              onPressed: () {
                                                Navigator.of(context).pop(
                                                  BookManagerSelection(
                                                      historyItem: item),
                                                );
                                              },
                                            ),
                                            OutlinedButton.icon(
                                              icon: const Icon(
                                                  Icons.visibility_rounded,
                                                  size: 18),
                                              label: Text(
                                                isFa
                                                    ? 'مشاهده متن کامل'
                                                    : 'Preview Text',
                                              ),
                                              onPressed: () =>
                                                  _previewBookDialog(
                                                      item, l10n),
                                            ),
                                            OutlinedButton.icon(
                                              icon: const Icon(
                                                Icons.delete_forever_rounded,
                                                size: 18,
                                                color: AppTheme.errorRed,
                                              ),
                                              label: Text(
                                                isFa ? 'حذف کامل' : 'Delete',
                                                style: const TextStyle(
                                                    color: AppTheme.errorRed),
                                              ),
                                              onPressed: () => _deleteSavedBook(
                                                  item, settings, l10n),
                                            ),
                                          ],
                                        ),
                                      ],
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Section 2: Exported Files & Audiobooks on Device Storage
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Semantics(
                                      header: true,
                                      child: Text(
                                        isFa
                                            ? '📂 فایل‌ها و کتاب‌های خروجی گرفته‌شده در دستگاه (${filteredFiles.length})'
                                            : '📂 Exported Files & Audiobooks on Device (${filteredFiles.length})',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_exportDirPath.isNotEmpty)
                                    OutlinedButton.icon(
                                      icon: const Icon(
                                          Icons.folder_open_rounded,
                                          size: 16),
                                      label: Text(
                                        isFa ? 'باز کردن پوشه' : 'Open Folder',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      onPressed: () =>
                                          AppStorageService.openDirectory(
                                              _exportDirPath),
                                    ),
                                ],
                              ),
                              if (_exportDirPath.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  _exportDirPath,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.color,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              if (_loadingFiles)
                                const Padding(
                                  padding: EdgeInsets.all(24),
                                  child: Center(
                                      child: CircularProgressIndicator()),
                                )
                              else if (filteredFiles.isEmpty)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 20),
                                  child: Text(
                                    isFa
                                        ? 'هیچ فایل خروجی در پوشه اسکنورا یافت نشد.'
                                        : 'No exported files found in the Scanora folder.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.color,
                                    ),
                                  ),
                                )
                              else
                                ListView.separated(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: filteredFiles.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 18),
                                  itemBuilder: (ctx, idx) {
                                    final file = filteredFiles[idx];
                                    final name = file.path
                                        .split(Platform.pathSeparator)
                                        .last;
                                    int bytes = 0;
                                    DateTime modified = DateTime.now();
                                    try {
                                      bytes = file.lengthSync();
                                      modified = file.lastModifiedSync();
                                    } catch (_) {}
                                    final canOpenInReader =
                                        _isReadableDocumentExtension(name);

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        MergeSemantics(
                                          child: Row(
                                            children: [
                                              ExcludeSemantics(
                                                child: Icon(
                                                  name.toLowerCase().endsWith(
                                                              '.mp3') ||
                                                          name
                                                              .toLowerCase()
                                                              .endsWith('.wav')
                                                      ? Icons.headphones_rounded
                                                      : Icons
                                                          .insert_drive_file_rounded,
                                                  color: AppTheme.accentIndigo,
                                                  size: 22,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      name,
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${_formatFileSize(bytes, isFa)} • ${_formatDate(modified)}',
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.color,
                                                      ),
                                                    ),
                                                    _remainingTime(
                                                        settings,
                                                        l10n,
                                                        'file:${file.path}',
                                                        audioFile: name
                                                                .toLowerCase()
                                                                .endsWith(
                                                                    '.wav')
                                                            ? file
                                                            : null),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            if (canOpenInReader)
                                              ElevatedButton.icon(
                                                icon: const Icon(
                                                  Icons.auto_stories_rounded,
                                                  size: 18,
                                                ),
                                                label: Text(
                                                  isFa
                                                      ? 'باز کردن در کتاب‌خوان'
                                                      : 'Open in Reader',
                                                ),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor:
                                                      AppTheme.primaryCyan,
                                                  foregroundColor: Colors.black,
                                                ),
                                                onPressed: () {
                                                  Navigator.of(context).pop(
                                                    BookManagerSelection(
                                                        filePath: file.path),
                                                  );
                                                },
                                              ),
                                            OutlinedButton.icon(
                                              icon: const Icon(
                                                  Icons.folder_open_rounded,
                                                  size: 18),
                                              label: Text(
                                                isFa
                                                    ? 'نمایش در پوشه'
                                                    : 'Show in Folder',
                                              ),
                                              onPressed: () => AppStorageService
                                                  .highlightFile(file.path),
                                            ),
                                            OutlinedButton.icon(
                                              icon: const Icon(
                                                Icons.delete_forever_rounded,
                                                size: 18,
                                                color: AppTheme.errorRed,
                                              ),
                                              label: Text(
                                                isFa
                                                    ? 'حذف کامل فایل'
                                                    : 'Delete File',
                                                style: const TextStyle(
                                                    color: AppTheme.errorRed),
                                              ),
                                              onPressed: () =>
                                                  _deleteExportedFile(
                                                      file, l10n),
                                            ),
                                          ],
                                        ),
                                      ],
                                    );
                                  },
                                ),
                            ],
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
}
