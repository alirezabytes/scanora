import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/captcha/captcha_hotkey_service.dart';
import '../../services/settings_service.dart';
import '../widgets/settings_rows.dart';
import 'widgets/settings_page.dart';

/// Windows-only: global captcha hotkey settings.
class CaptchaHotkeySettingsScreen extends StatelessWidget {
  const CaptchaHotkeySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);
    final combo = CaptchaHotkeyService.describe(settings.captchaHotkey);

    return SettingsPage(
      title: l10n.tx('Captcha Hotkey', 'کلید میانبر کپچا'),
      children: [
        SettingsSwitchRow(
          icon: Icons.keyboard_rounded,
          title: l10n.tx('Global captcha hotkey', 'کلید میانبر سراسری کپچا'),
          description: l10n.tx(
            'Press the hotkey in the active window to read and copy the answer to a labelled captcha image.',
            'در پنجرهٔ فعال، این کلید تصویر دارای برچسب کپچا را پیدا می‌کند و پاسخ را می‌خواند و کپی می‌کند.',
          ),
          value: settings.captchaHotkeyEnabled,
          onChanged: (v) async {
            await settings.setCaptchaHotkeyEnabled(v);
            await CaptchaHotkeyService.apply(settings);
            if (!context.mounted) return;
            AccessibilityService.announceAndNotify(
              context,
              l10n.tx(
                v ? 'Captcha hotkey on.' : 'Captcha hotkey off.',
                v
                    ? 'کلید میانبر کپچا فعال شد.'
                    : 'کلید میانبر کپچا غیرفعال شد.',
              ),
            );
          },
        ),
        SettingsRow(
          icon: Icons.edit_rounded,
          title: l10n.tx('Hotkey combination', 'ترکیب کلید میانبر'),
          value: combo,
          description: l10n.tx(
            'Press the row, then press the new key combination.',
            'روی این گزینه بزنید و سپس ترکیب کلید جدید را فشار دهید.',
          ),
          onTap: () async {
            final newCombo = await showDialog<String>(
              context: context,
              builder: (_) => const _RecordHotkeyDialog(),
            );
            if (newCombo == null || !context.mounted) return;
            await settings.setCaptchaHotkey(newCombo);
            final ok = await CaptchaHotkeyService.apply(settings);
            if (!context.mounted) return;
            final shown = CaptchaHotkeyService.describe(newCombo);
            AccessibilityService.announceAndNotify(
              context,
              ok
                  ? l10n.tx('Hotkey set to $shown.',
                      'کلید میانبر روی $shown تنظیم شد.')
                  : l10n.tx(
                      'This combination is already used by another program.',
                      'این ترکیب توسط برنامه دیگری استفاده می‌شود.',
                    ),
            );
          },
        ),
        SettingsRow(
          icon: Icons.restart_alt_rounded,
          title: l10n.tx('Restore default hotkey', 'بازگرداندن کلید پیش‌فرض'),
          value: 'Ctrl+Shift+C',
          showChevron: false,
          onTap: () async {
            await settings.setCaptchaHotkey(CaptchaHotkeyService.defaultCombo);
            await CaptchaHotkeyService.apply(settings);
            if (!context.mounted) return;
            AccessibilityService.announceAndNotify(
              context,
              l10n.tx('Hotkey restored to Ctrl+Shift+C.',
                  'کلید میانبر به Ctrl+Shift+C برگشت.'),
            );
          },
        ),
      ],
    );
  }
}

class _RecordHotkeyDialog extends StatefulWidget {
  const _RecordHotkeyDialog();

  @override
  State<_RecordHotkeyDialog> createState() => _RecordHotkeyDialogState();
}

class _RecordHotkeyDialogState extends State<_RecordHotkeyDialog> {
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.tx(
          'Press the new key combination', 'ترکیب کلید جدید را فشار دهید')),
      content: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          final combo = CaptchaHotkeyService.comboFromKeyEvent(event);
          if (combo != null) {
            Navigator.of(context).pop(combo);
          }
          return KeyEventResult.handled;
        },
        child: Text(
          l10n.tx(
            'Hold Ctrl, Shift, Alt or Windows together with a letter, digit or F-key. Press Escape to cancel.',
            'کلید Ctrl، Shift، Alt یا Windows را همراه با یک حرف، رقم یا کلید F نگه دارید. برای انصراف Escape را بزنید.',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.translate('cancel')),
        ),
      ],
    );
  }
}
