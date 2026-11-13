import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/captcha/captcha_hotkey_service.dart';
import '../../services/cloud/scanora_cloud_ocr_service.dart';
import '../../services/native_bridge_service.dart';
import '../../services/settings_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/confirm_dialog.dart';
import 'tool_routes.dart';
import 'tools_hub_screen.dart';

/// Main Home Screen for Scanora on Android and Windows.
///
/// Displays a clean, tab-free vertical menu ([ToolsHubScreen]) with 4 main destinations:
/// 1. Image & Camera Tools
/// 2. Reading & Documents
/// 3. Smart Notes
/// 4. Settings
class AdaptiveHubScreen extends StatefulWidget {
  const AdaptiveHubScreen({super.key});

  @override
  State<AdaptiveHubScreen> createState() => _AdaptiveHubScreenState();
}

class _AdaptiveHubScreenState extends State<AdaptiveHubScreen> {
  final FocusNode _firstItemFocus =
      FocusNode(debugLabel: 'scanora-main-first-item');
  DateTime _lastCloudAuthAnnouncedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _openingSharedFiles = false;

  @override
  void initState() {
    super.initState();
    NativeBridgeService.initSharedImageListener();
    NativeBridgeService.onSharedImageReceived = _handleIncomingSharedImage;
    NativeBridgeService.onSharedFilesAvailable = _openPendingSharedFiles;
    ScanoraCloudOcrService.authorizationSuccessNotifier
        .addListener(_onCloudAuthSuccess);
    CaptchaHotkeyService.onHotkeyCaptchaSolved = (bytes, result) {
      if (!mounted || bytes.isEmpty) return;
      ToolRoutes.open(context, ToolId.captcha,
          image: bytes, captchaResult: result);
    };

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _firstItemFocus.requestFocus();
      final image = await NativeBridgeService.getInitialSharedImage();
      if (image != null && mounted) {
        await _handleIncomingSharedImage(image.bytes, sourceName: image.name);
      }
      if (mounted && image == null && ModalRoute.isCurrentOf(context) == true) {
        final name = context.read<SettingsService>().resumeTool;
        final tool =
            ToolId.values.where((tool) => tool.name == name).firstOrNull;
        if (tool != null) {
          await ToolRoutes.open(context, tool, resumeSession: true);
        }
      }
      if (mounted) await _openPendingSharedFiles();
    });
  }

  void _onCloudAuthSuccess() {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastCloudAuthAnnouncedAt) <
        const Duration(seconds: 3)) {
      return;
    }
    _lastCloudAuthAnnouncedAt = now;
    final l10n = AppLocalizations.of(context);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final syncInfo = ScanoraCloudOcrService.syncStatusNotifier.value;
    final email = syncInfo.accountEmail?.trim() ?? '';
    final msg = email.isNotEmpty
        ? l10n.tx(
            'Scanora Smart Cloud synchronization with Google ($email) succeeded and has been registered in the app.',
            'همگام‌سازی ابر هوشمند اسکنورا با حساب گوگل ($email) با موفقیت انجام شد و در برنامه ثبت گردید.',
          )
        : l10n.tx(
            'Scanora Smart Cloud synchronization with Google succeeded and has been registered in the app.',
            'همگام‌سازی ابر هوشمند اسکنورا با گوگل با موفقیت انجام شد و در برنامه ثبت گردید.',
          );
    AccessibilityService.announceAndNotify(context, msg);
    EspeakTtsService.speak(
      msg,
      settings: settings,
    );
  }

  @override
  void dispose() {
    ScanoraCloudOcrService.authorizationSuccessNotifier
        .removeListener(_onCloudAuthSuccess);
    NativeBridgeService.onSharedImageReceived = null;
    NativeBridgeService.onSharedFilesAvailable = null;
    CaptchaHotkeyService.onHotkeyCaptchaSolved = null;
    _firstItemFocus.dispose();
    super.dispose();
  }

  Future<void> _openPendingSharedFiles() async {
    if (!mounted || _openingSharedFiles) return;
    _openingSharedFiles = true;
    try {
      while (mounted) {
        final batches = await NativeBridgeService.takeSharedFiles();
        if (batches.isEmpty) break;
        for (final paths in batches) {
          try {
            if (!mounted) continue;
            final l10n = AppLocalizations.of(context);
            if (paths.isEmpty) {
              AccessibilityService.announceAndNotify(
                  context,
                  l10n.tx('Could not read the shared files.',
                      'خواندن فایل‌های اشتراکی ممکن نبود.'));
              continue;
            }
            final open = await showSafeConfirmDialog(
              context,
              title: l10n.tx('Open shared files', 'باز کردن فایل‌های اشتراکی'),
              message: paths.length == 1
                  ? File(paths.single).uri.pathSegments.last
                  : l10n.tx('Open ${paths.length} shared images in the reader?',
                      '${paths.length} تصویر اشتراکی در کتاب‌خوان باز شود؟'),
              confirmLabel: l10n.tx('Open', 'باز کردن'),
            );
            if (open && mounted) {
              await ToolRoutes.open(context, ToolId.readingStudio,
                  sharedFiles: paths);
            }
          } finally {
            await NativeBridgeService.releaseSharedFiles(paths);
          }
        }
      }
    } on PlatformException {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        AccessibilityService.announceAndNotify(
            context,
            l10n.tx('Could not read the shared files.',
                'خواندن فایل‌های اشتراکی ممکن نبود.'));
      }
    } finally {
      _openingSharedFiles = false;
    }
  }

  /// An image shared from another app: ask what to do with it (no guessing).
  Future<void> _handleIncomingSharedImage(Uint8List bytes,
      {String? sourceName}) async {
    if (!mounted || bytes.isEmpty) return;
    final l10n = AppLocalizations.of(context);
    final choice = await showDialog<ToolId>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.tx('What do you want to do with this image?',
              'با این تصویر چه کاری انجام شود؟')),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          content: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                autofocus: true,
                leading: const Icon(Icons.document_scanner_rounded,
                    color: AppTheme.primaryCyan),
                title: Text(l10n.tx('Image to Text', 'استخراج متن از تصویر')),
                onTap: () => Navigator.pop(ctx, ToolId.imageToText),
              ),
              ListTile(
                leading: const Icon(Icons.security_rounded,
                    color: AppTheme.warningAmber),
                title: Text(l10n.tx('Captcha Solver', 'حل‌کننده سریع کپچا')),
                onTap: () => Navigator.pop(ctx, ToolId.captcha),
              ),
              ListTile(
                leading: const Icon(Icons.image_search_rounded,
                    color: AppTheme.accentIndigo),
                title: Text(l10n.tx(
                    'Image Description & Visual Q&A', 'توصیف صحنه و تصویر')),
                onTap: () => Navigator.pop(ctx, ToolId.imageDescription),
              ),
            ],
          )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.translate('cancel')))
          ],
        );
      },
    );
    if (choice == null || !mounted) return;
    await ToolRoutes.open(context, choice,
        image: bytes, sourceName: sourceName);
  }

  Future<void> _handleBack() async {
    final l10n = AppLocalizations.of(context);
    final shouldExit = await showSafeConfirmDialog(
      context,
      title: l10n.translate('confirm_exit_title'),
      message: l10n.translate('confirm_exit_message'),
      confirmLabel: l10n.translate('confirm_exit_btn'),
      destructive: true,
    );
    if (shouldExit) {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Semantics(
            header: true,
            child: Text(
              l10n.translate('app_title'),
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
            ),
          ),
        ),
        body: SafeArea(
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: ToolsHubScreen(firstItemFocusNode: _firstItemFocus),
          ),
        ),
      ),
    );
  }
}
