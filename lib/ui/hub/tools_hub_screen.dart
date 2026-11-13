import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/in_app_camera_screen.dart';
import 'tool_routes.dart';

class _EscapeBackIntent extends Intent {
  const _EscapeBackIntent();
}

/// Main home menu for Scanora on both Android and Windows.
///
/// Displays a clean, single-column list of selectable options without tabs or clutter:
/// 1. Image & Camera Tools (opens [ImageToolsCategoryScreen] with its 3 selectable tools)
/// 2. Reading & Documents (carries the full format description right on the option)
/// 3. Smart Notes
/// 4. Settings
@pragma('vm:entry-point')
class ToolsHubScreen extends StatelessWidget {
  final FocusNode firstItemFocusNode;

  const ToolsHubScreen({super.key, required this.firstItemFocusNode});

  void _openImageToolsCategory(BuildContext context) {
    Navigator.of(context).restorablePush(_imageToolsRoute);
  }

  @pragma('vm:entry-point')
  static Route<void> _imageToolsRoute(
          BuildContext context, Object? arguments) =>
      MaterialPageRoute<void>(builder: (_) => const ImageToolsCategoryScreen());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          children: [
            _MenuOptionCard(
              focusNode: firstItemFocusNode,
              icon: Icons.camera_enhance_rounded,
              accent: AppTheme.primaryCyan,
              title: l10n.tx('Image & Camera Tools', 'ابزارهای تصویر و دوربین'),
              description: l10n.tx(
                'Image to Text, Captcha Solver, and Image Description & Visual Q&A.',
                'استخراج متن از تصویر، حل‌کننده کپچا، و توصیف صحنه و تصویر.',
              ),
              onTap: () => _openImageToolsCategory(context),
            ),
            const SizedBox(height: 14),
            _MenuOptionCard(
              icon: Icons.auto_stories_rounded,
              accent: AppTheme.successGreen,
              title: l10n.tx('Reading & Documents', 'مطالعه و اسناد'),
              description: l10n.tx(
                'Audiobook Studio & Smart Document Reader — Supports PDF, EPUB, Photos, DOCX, ODT, TXT, PPTX, Excel, Audiobook ZIP, Web Links & eSpeak-NG Audio Synthesis',
                'استودیو کتاب صوتی و سندخوان هوشمند — پشتیبانی از PDF، EPUB، تصاویر، DOCX، ODT، TXT، PPTX، اکسل، کتاب صوتی ZIP، لینک وب و موتور صوتی eSpeak-NG',
              ),
              onTap: () => ToolRoutes.open(context, ToolId.readingStudio),
            ),
            const SizedBox(height: 14),
            _MenuOptionCard(
              icon: Icons.edit_note_rounded,
              accent: AppTheme.accentIndigo,
              title: l10n.tx('Smart Notes', 'یادداشت‌های هوشمند'),
              description: l10n.tx(
                'Write, search, organize, and export your personal notes and saved texts.',
                'نوشتن، جستجو، دسته‌بندی و خروجی گرفتن از یادداشت‌ها و متن‌های ذخیره‌شده.',
              ),
              onTap: () => ToolRoutes.open(context, ToolId.notes),
            ),
            const SizedBox(height: 14),
            _MenuOptionCard(
              icon: Icons.settings_rounded,
              accent: AppTheme.warningAmber,
              title: l10n.tx('Settings', 'تنظیمات'),
              description: l10n.tx(
                'Language, online/offline mode, default online service, voice engine (eSpeak-NG), and connection keys.',
                'زبان، حالت آنلاین و آفلاین، سرویس پیش‌فرض آنلاین، موتور صوتی eSpeak-NG و کلیدهای ارتباطی.',
              ),
              onTap: () => ToolRoutes.open(context, ToolId.settings),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dedicated sub-screen opened when the user selects "Image & Camera Tools".
///
/// Presents the three selectable vision tools with Back button and Windows Escape key support:
/// 1. Image to Text
/// 2. Captcha Solver
/// 3. Image Description & Visual Q&A
class ImageToolsCategoryScreen extends StatelessWidget {
  const ImageToolsCategoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _EscapeBackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _EscapeBackIntent: CallbackAction<_EscapeBackIntent>(
            onInvoke: (_) {
              Navigator.of(context).maybePop();
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
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Semantics(
                header: true,
                child: Text(
                  l10n.tx('Image & Camera Tools', 'ابزارهای تصویر و دوربین'),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 18),
                ),
              ),
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                    children: [
                      _MenuOptionCard(
                        autofocus: true,
                        icon: Icons.document_scanner_rounded,
                        accent: AppTheme.primaryCyan,
                        title: l10n.tx('Image to Text', 'استخراج متن از تصویر'),
                        description: l10n.tx(
                          'Read the text of a photo, document or screenshot.',
                          'خواندن متن عکس، سند یا تصویر صفحه.',
                        ),
                        onTap: () =>
                            ToolRoutes.open(context, ToolId.imageToText),
                      ),
                      const SizedBox(height: 14),
                      _MenuOptionCard(
                        icon: Icons.security_rounded,
                        accent: AppTheme.warningAmber,
                        title: l10n.tx('Captcha Solver', 'حل‌کننده سریع کپچا'),
                        description: l10n.tx(
                          'Solve security codes and simple math captchas.',
                          'حل کدهای امنیتی و کپچاهای ریاضی ساده.',
                        ),
                        onTap: () => ToolRoutes.open(context, ToolId.captcha),
                      ),
                      const SizedBox(height: 14),
                      _MenuOptionCard(
                        icon: Icons.image_search_rounded,
                        accent: AppTheme.accentIndigo,
                        title: l10n.tx(
                          'Image Description & Visual Q&A',
                          'توصیف صحنه و تصویر',
                        ),
                        description: l10n.tx(
                          'Describe a scene and ask questions about a picture.',
                          'توصیف صحنه و پرسش و پاسخ درباره تصویر.',
                        ),
                        onTap: () =>
                            ToolRoutes.open(context, ToolId.imageDescription),
                      ),
                      if (const {
                        TargetPlatform.android,
                        TargetPlatform.windows,
                      }.contains(Theme.of(context).platform)) ...[
                        const SizedBox(height: 14),
                        _MenuOptionCard(
                          icon: Icons.colorize_rounded,
                          accent: AppTheme.primaryCyan,
                          title:
                              l10n.tx('Live Color Reader', 'خواندن زندهٔ رنگ'),
                          description: l10n.tx(
                            'Announces the color at the center of the camera.',
                            'رنگ وسط کادر دوربین را اعلام می‌کند.',
                          ),
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => InAppCameraScreen(
                                title: l10n.tx(
                                    'Live Color Reader', 'خواندن زندهٔ رنگ'),
                                readColors: true,
                              ),
                            ),
                          ),
                        ),
                      ],
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

class _MenuOptionCard extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String description;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool autofocus;

  const _MenuOptionCard({
    required this.icon,
    required this.accent,
    required this.title,
    required this.description,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: accent.withValues(alpha: 0.65), width: 1.4),
          ),
          child: InkWell(
            focusNode: focusNode,
            autofocus: autofocus,
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent.withValues(alpha: 0.18),
                    accent.withValues(alpha: 0.04),
                  ],
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, size: 32, color: accent),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          description,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.4,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: accent.withValues(alpha: 0.85),
                    size: 26,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
