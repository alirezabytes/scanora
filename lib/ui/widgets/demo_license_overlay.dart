import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/license/demo_license_service.dart';
import '../theme/app_theme.dart';

class DemoLicenseOverlay extends StatelessWidget {
  final Widget child;

  const DemoLicenseOverlay({
    super.key,
    required this.child,
  });

  static void showActivationDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const _DemoActivationDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!DemoLicenseService.isDemoBuildCompiled) {
      return child;
    }

    return Consumer<DemoLicenseService>(
      builder: (context, license, _) {
        if (!license.isDemoActive) {
          return child;
        }

        if (license.isExpired) {
          return const _DemoExpiredLockScreen();
        }

        final l10n = AppLocalizations.of(context);
        final remText = license.formatRemainingTime(isPersian: l10n.isPersian);

        return Column(
          children: [
            Material(
              color: AppTheme.warningAmber.withValues(alpha: 0.18),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.timer_outlined,
                          color: AppTheme.warningAmber, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.isPersian
                              ? 'نسخه دمو | زمان باقی‌مانده: $remText'
                              : 'Demo Version | Remaining: $remText',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.vpn_key_rounded,
                            size: 16, color: AppTheme.primaryCyan),
                        label: Text(
                          l10n.isPersian
                              ? 'تمدید / فعال‌سازی دائمی'
                              : 'Extend / Activate',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryCyan,
                          ),
                        ),
                        onPressed: () => showActivationDialog(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

class _DemoActivationDialog extends StatefulWidget {
  const _DemoActivationDialog();

  @override
  State<_DemoActivationDialog> createState() => _DemoActivationDialogState();
}

class _DemoActivationDialogState extends State<_DemoActivationDialog> {
  final TextEditingController _codeController = TextEditingController();
  String? _statusMessage;
  bool _isSuccess = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _announce(AppLocalizations l10n, String msg) {
    if (!mounted) return;
    try {
      SemanticsService.sendAnnouncement(
          View.of(context), msg, l10n.textDirection);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final license = Provider.of<DemoLicenseService>(context);
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      title: Text(
        l10n.isPersian
            ? 'تمدید زمان دمو یا فعال‌سازی دائمی برنامه'
            : 'Extend Demo Time or Activate Permanently',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.isPersian
                  ? 'کد اختصاصی دستگاه شما (این کد را برای دریافت کلید تمدید یا خرید دائمی ارسال کنید):'
                  : 'Your Device Code (send this code to receive an extension or permanent key):',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppTheme.primaryCyan.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SelectableText(
                    license.deviceCode,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      letterSpacing: 1.5,
                      color: AppTheme.primaryCyan,
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: Text(l10n.isPersian ? 'کپی کد دستگاه' : 'Copy ID'),
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: license.deviceCode));
                      final msg = l10n.isPersian
                          ? 'کد دستگاه کپی شد: ${license.deviceCode}'
                          : 'Device ID copied: ${license.deviceCode}';
                      _announce(l10n, msg);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _codeController,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: l10n.isPersian
                    ? 'کلید تمدید یا فعال‌سازی دائمی (SCAN-...)'
                    : 'Extension or Permanent License Key (SCAN-...)',
                hintText: 'SCAN-PRO-... / SCAN-EXT-...',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.content_paste_rounded, size: 18),
              label: Text(
                l10n.isPersian
                    ? 'جای‌گذاری کلید از کلیپ‌بورد (Paste)'
                    : 'Paste Key from Clipboard',
              ),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  setState(() {
                    _codeController.text = data!.text!.trim();
                  });
                }
              },
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _statusMessage!,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color:
                        _isSuccess ? AppTheme.successGreen : AppTheme.errorRed,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.translate('close')),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.verified_rounded),
          label:
              Text(l10n.isPersian ? 'تایید و اعمال کلید' : 'Verify & Activate'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryCyan,
            foregroundColor: Colors.black,
          ),
          onPressed: () async {
            final res = await license.redeemLicenseKey(
              _codeController.text,
              isPersian: l10n.isPersian,
            );
            setState(() {
              _isSuccess = res.$1;
              _statusMessage = res.$2;
            });
            _announce(l10n, res.$2);
            if (res.$1 && mounted) {
              await Future<void>.delayed(const Duration(seconds: 1));
              if (!context.mounted) return;
              Navigator.pop(context);
            }
          },
        ),
      ],
    );
  }
}

class _DemoExpiredLockScreen extends StatefulWidget {
  const _DemoExpiredLockScreen();

  @override
  State<_DemoExpiredLockScreen> createState() => _DemoExpiredLockScreenState();
}

class _DemoExpiredLockScreenState extends State<_DemoExpiredLockScreen> {
  final TextEditingController _keyController = TextEditingController();
  String? _statusMessage;
  bool _isSuccess = false;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  void _announce(AppLocalizations l10n, String msg) {
    if (!mounted) return;
    try {
      SemanticsService.sendAnnouncement(
          View.of(context), msg, l10n.textDirection);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final license = Provider.of<DemoLicenseService>(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      body: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(
                        Icons.lock_clock_rounded,
                        size: 64,
                        color: AppTheme.warningAmber,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.isPersian
                            ? 'مهلت استفاده از نسخه آزمایشی (دمو) به پایان رسیده است'
                            : 'Demo Trial Period Has Expired',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.isPersian
                            ? 'برای تمدید زمان تست و یا فعال‌سازی دائمی نسخه کامل (بدون نیاز به نصب مجدد)، کد دستگاه زیر را برای توسعه‌دهنده ارسال کنید و کلید فعال‌سازی دریافتی را در کادر زیر وارد نمایید:'
                            : 'To extend your trial time or permanently unlock the full version (without reinstalling), send your Device Code below to the developer and enter your activation key:',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                      const SizedBox(height: 18),

                      // Device Code Display + Copy Button
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color:
                                  AppTheme.primaryCyan.withValues(alpha: 0.5)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              l10n.isPersian
                                  ? 'کد اختصاصی دستگاه شما:'
                                  : 'Your Device Code:',
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              license.deviceCode,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 2.0,
                                color: AppTheme.primaryCyan,
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 42,
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                label: Text(
                                  l10n.isPersian
                                      ? 'کپی کد دستگاه (Copy Device Code)'
                                      : 'Copy Device Code',
                                ),
                                onPressed: () {
                                  Clipboard.setData(
                                      ClipboardData(text: license.deviceCode));
                                  final msg = l10n.isPersian
                                      ? 'کد دستگاه در کلیپ‌بورد کپی شد: ${license.deviceCode}'
                                      : 'Device code copied: ${license.deviceCode}';
                                  _announce(l10n, msg);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(msg),
                                        behavior: SnackBarBehavior.floating),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Activation Key Input
                      TextField(
                        controller: _keyController,
                        textDirection: TextDirection.ltr,
                        decoration: InputDecoration(
                          labelText: l10n.isPersian
                              ? 'کلید تمدید زمان یا فعال‌سازی دائمی'
                              : 'Time-Extension or Permanent Activation Key',
                          hintText: 'SCAN-PRO-... / SCAN-EXT-...',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.vpn_key_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 44,
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon:
                              const Icon(Icons.content_paste_rounded, size: 18),
                          label: Text(
                            l10n.isPersian
                                ? 'جای‌گذاری کلید از کلیپ‌بورد (Paste Key)'
                                : 'Paste Key from Clipboard',
                          ),
                          onPressed: () async {
                            final data =
                                await Clipboard.getData(Clipboard.kTextPlain);
                            if (data?.text != null) {
                              setState(() {
                                _keyController.text = data!.text!.trim();
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 50,
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.lock_open_rounded, size: 22),
                          label: Text(
                            l10n.isPersian
                                ? 'تایید کلید و بازگشایی برنامه'
                                : 'Verify Key & Unlock Scanora',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryCyan,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: () async {
                            final res = await license.redeemLicenseKey(
                              _keyController.text,
                              isPersian: l10n.isPersian,
                            );
                            setState(() {
                              _isSuccess = res.$1;
                              _statusMessage = res.$2;
                            });
                            _announce(l10n, res.$2);
                          },
                        ),
                      ),
                      if (_statusMessage != null) ...[
                        const SizedBox(height: 14),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _statusMessage!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _isSuccess
                                  ? AppTheme.successGreen
                                  : AppTheme.errorRed,
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
