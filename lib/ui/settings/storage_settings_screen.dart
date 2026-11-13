import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/settings_service.dart';
import '../../services/storage/app_storage_service.dart';
import '../theme/app_theme.dart';

/// 4. Dedicated Sub-Screen for File Path & Storage Settings
class StorageSettingsScreen extends StatelessWidget {
  const StorageSettingsScreen({super.key});

  void _announceAndSnack(
      BuildContext context, AppLocalizations l10n, String message) {
    try {
      SemanticsService.sendAnnouncement(
          View.of(context), message, l10n.textDirection);
    } catch (_) {}
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: l10n.translate('back'),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          l10n.isPersian ? 'مسیر فایل و ذخیره‌سازی' : 'File Path & Storage',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
      body: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: FutureBuilder<List<Directory>>(
                future: Future.wait([
                  AppStorageService.getExportDirectory(null),
                  AppStorageService.getExportDirectory(
                      settings.exportDirectoryPath),
                ]),
                builder: (ctx, snapshot) {
                  final defaultPath =
                      snapshot.data != null && snapshot.data!.isNotEmpty
                          ? snapshot.data![0].path
                          : '...';
                  final currentPath =
                      snapshot.data != null && snapshot.data!.length > 1
                          ? snapshot.data![1].path
                          : defaultPath;
                  final isCustom = settings.exportDirectoryPath != null &&
                      settings.exportDirectoryPath!.trim().isNotEmpty;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.isPersian
                            ? 'پوشه فعال ذخیره‌سازی فایل‌ها:'
                            : 'Current Active Export Directory:',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        label: l10n.isPersian
                            ? 'مسیر فعلی ذخیره‌سازی فایل'
                            : 'Current export path',
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppTheme.primaryCyan
                                    .withValues(alpha: 0.4)),
                          ),
                          child: SelectableText(
                            currentPath,
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              color: AppTheme.primaryCyan,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        l10n.isPersian
                            ? 'مسیر پیش‌فرض برنامه (Default Path):'
                            : 'Default Application Export Path:',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.grey.withValues(alpha: 0.25)),
                        ),
                        child: SelectableText(
                          defaultPath,
                          textDirection: TextDirection.ltr,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 48,
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.folder_open_rounded, size: 20),
                          label: Text(
                            l10n.isPersian
                                ? 'باز کردن پوشه ذخیره‌سازی'
                                : 'Open Export Folder',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: () =>
                              AppStorageService.openDirectory(currentPath),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 48,
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.edit_location_alt_rounded,
                              size: 20),
                          label: Text(
                            l10n.isPersian
                                ? 'انتخاب و تغییر مسیر پوشه'
                                : 'Change Export Folder',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          onPressed: () async {
                            final selectedDir =
                                await FilePicker.getDirectoryPath();
                            if (selectedDir != null &&
                                selectedDir.trim().isNotEmpty) {
                              await settings
                                  .setExportDirectoryPath(selectedDir.trim());
                              if (!context.mounted) return;
                              _announceAndSnack(
                                context,
                                l10n,
                                l10n.isPersian
                                    ? 'مسیر ذخیره‌سازی تغییر یافت: $selectedDir'
                                    : 'Export directory updated: $selectedDir',
                              );
                            }
                          },
                        ),
                      ),
                      if (isCustom) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 48,
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.restore_rounded, size: 20),
                            label: Text(
                              l10n.isPersian
                                  ? 'بازگردانی به مسیر پیش‌فرض'
                                  : 'Reset to Default Path',
                            ),
                            onPressed: () async {
                              await settings.setExportDirectoryPath(null);
                              if (!context.mounted) return;
                              _announceAndSnack(
                                context,
                                l10n,
                                l10n.isPersian
                                    ? 'مسیر ذخیره‌سازی به حالت پیش‌فرض بازگردانی شد.'
                                    : 'Export directory reset to default.',
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
