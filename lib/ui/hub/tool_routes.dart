import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/captcha_result.dart';
import '../../services/settings_service.dart';
import '../screens/captcha_solver_screen.dart';
import '../screens/format_converter_screen.dart';
import '../screens/image_description_screen.dart';
import '../screens/image_to_text_screen.dart';
import '../screens/notes_screen.dart';
import '../screens/pdf_viewer_screen.dart';
import '../settings/settings_screen.dart';
import 'tool_host.dart';

/// Identifiers of the tools and sections reachable from the Scanora home menu.
enum ToolId {
  imageToText,
  captcha,
  imageDescription,
  readingStudio,
  converter,
  notes,
  settings,
}

class _EscapeBackIntent extends Intent {
  const _EscapeBackIntent();
}

/// Central place that knows how to open each tool inside a [ToolHost] or Escape-enabled page.
@pragma('vm:entry-point')
class ToolRoutes {
  ToolRoutes._();

  /// Pushes the tool on top of the current screen. [image] is delivered to image tools after
  /// the first frame.
  static Future<void> open(BuildContext context, ToolId tool,
      {Uint8List? image,
      CaptchaResult? captchaResult,
      List<String>? sharedFiles,
      String? sourceName,
      bool resumeSession = false}) async {
    if (image == null && captchaResult == null && sharedFiles == null) {
      final settings = context.read<SettingsService>();
      final previous = resumeSession ? null : settings.resumeTool;
      if (settings.resumeTool != tool.name) settings.rememberTool(tool.name);
      Navigator.of(context).restorablePush(_restoreTool, arguments: {
        'tool': tool.name,
        'previous': previous,
        'resume': resumeSession,
      });
      return;
    }
    final route = _route(tool, image, captchaResult, sharedFiles, sourceName);
    await Navigator.of(context).push<void>(route);
    if (sharedFiles != null) await route.completed;
  }

  @pragma('vm:entry-point')
  static Route<void> _restoreTool(BuildContext context, Object? arguments) {
    final data = arguments is Map ? arguments : {'tool': arguments};
    final tool = ToolId.values.byName(data['tool'] as String);
    final settings = context.read<SettingsService>();
    final route = _route(tool, null, null, null, null, data['resume'] == true);
    route.popped.then((_) {
      if (settings.resumeTool == tool.name) {
        settings.rememberTool(data['previous'] as String?);
      }
    });
    return route;
  }

  /// Replaces the current tool (used by "send this image to ..." actions) so the
  /// back stack stays shallow.
  static Future<void> replaceWith(BuildContext context, ToolId tool,
      {Uint8List? image}) {
    return Navigator.of(context)
        .pushReplacement<void, void>(_route(tool, image));
  }

  static MaterialPageRoute<void> _route(ToolId tool, Uint8List? image,
      [CaptchaResult? captchaResult,
      List<String>? sharedFiles,
      String? sourceName,
      bool resumeSession = false]) {
    return MaterialPageRoute<void>(
      builder: (context) {
        final l10n = AppLocalizations.of(context);
        switch (tool) {
          case ToolId.imageToText:
            return ToolHost<ImageToTextScreenState>(
              title: l10n.tx('Image to Text', 'استخراج متن از تصویر'),
              initialImage: image,
              onLoadImage: (s, b) =>
                  s.loadExternalImage(b, sourceName: sourceName),
              hasActiveContent: (s) => s.hasActiveContent,
              onReset: (s) => s.resetScreen(),
              builder: (key) => ImageToTextScreen(
                customKey: key,
                onSendToCaptchaSolver: (b) =>
                    ToolRoutes.replaceWith(context, ToolId.captcha, image: b),
                onSendToImageDescription: (b) => ToolRoutes.replaceWith(
                    context, ToolId.imageDescription,
                    image: b),
              ),
            );
          case ToolId.captcha:
            return ToolHost<CaptchaSolverScreenState>(
              title: l10n.tx('Captcha Solver', 'حل‌کننده کپچا'),
              initialImage: image,
              onLoadImage: (s, b) =>
                  s.loadExternalImage(b, solved: captchaResult),
              hasActiveContent: (s) => s.hasActiveContent,
              onReset: (s) => s.resetScreen(),
              builder: (key) => CaptchaSolverScreen(
                customKey: key,
                onSendToImageToText: (b) => ToolRoutes.replaceWith(
                    context, ToolId.imageToText,
                    image: b),
                onSendToImageDescription: (b) => ToolRoutes.replaceWith(
                    context, ToolId.imageDescription,
                    image: b),
              ),
            );
          case ToolId.imageDescription:
            return ToolHost<ImageDescriptionScreenState>(
              title: l10n.tx(
                  'Image Description & Visual Q&A', 'توصیف صحنه و تصویر'),
              initialImage: image,
              onLoadImage: (s, b) => s.loadExternalImage(b),
              hasActiveContent: (s) => s.hasActiveContent,
              onReset: (s) => s.resetScreen(),
              builder: (key) => ImageDescriptionScreen(
                customKey: key,
                onSendToImageToText: (b) => ToolRoutes.replaceWith(
                    context, ToolId.imageToText,
                    image: b),
                onSendToCaptchaSolver: (b) =>
                    ToolRoutes.replaceWith(context, ToolId.captcha, image: b),
              ),
            );
          case ToolId.readingStudio:
            return ToolHost<PdfViewerScreenState>(
              title: l10n.tx('Reading & Documents', 'مطالعه و اسناد'),
              hasActiveContent: (s) => s.hasActiveContent,
              onReset: (s) => s.resetScreen(),
              builder: (key) => PdfViewerScreen(
                  customKey: key,
                  sharedFiles: sharedFiles,
                  resumeSession: resumeSession),
            );
          case ToolId.converter:
            return ToolHost<FormatConverterScreenState>(
              title: l10n.tx('Document Converter', 'مبدل فرمت فایل‌ها'),
              hasActiveContent: (s) => s.hasActiveContent,
              onReset: (s) => s.resetScreen(),
              builder: (key) => FormatConverterScreen(
                  customKey: key, resumeSession: resumeSession),
            );
          case ToolId.notes:
            return ToolHost<NotesScreenState>(
              title: l10n.tx('Smart Notes', 'یادداشت‌های هوشمند'),
              hasActiveContent: (s) => s.hasActiveContent,
              onReset: (s) => s.resetScreen(),
              builder: (key) => NotesScreen(customKey: key),
            );
          case ToolId.settings:
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
                          l10n.tx('Settings', 'تنظیمات'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 18),
                        ),
                      ),
                    ),
                    body: const SafeArea(child: SettingsScreen()),
                  ),
                ),
              ),
            );
        }
      },
    );
  }
}
