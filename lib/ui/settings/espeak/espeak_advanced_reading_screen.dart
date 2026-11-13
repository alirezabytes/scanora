import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/a11y/accessibility_service.dart';
import '../../../services/settings_service.dart';
import '../../widgets/settings_rows.dart';
import '../widgets/settings_page.dart';

import '../widgets/accessible_slider_row.dart';

class EspeakAdvancedReadingScreen extends StatelessWidget {
  const EspeakAdvancedReadingScreen({super.key});

  // Capital letter indication values (eSpeak-NG `-k`): 0 none, 1 sound, 2 spoken, >=3 pitch raise.
  static const int _capNone = 0;
  static const int _capBeep = 1;
  static const int _capSpoken = 2;
  static const int _capPitch = 20;

  String _capitalLabel(AppLocalizations l10n, int mode) {
    if (mode >= 3) return l10n.tx('Raise pitch', 'افزایش زیر و بمی صدا');
    switch (mode) {
      case _capBeep:
        return l10n.tx('Beep', 'بوق صوتی');
      case _capSpoken:
        return l10n.tx('Say "Cap"', 'اعلام صوتی «Cap»');
      default:
        return l10n.tx('Silent', 'بی‌صدا');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final l10n = AppLocalizations.of(context);
    return SettingsPage(
        title: l10n.tx('Advanced reading options', 'گزینه‌های پیشرفتهٔ خواندن'),
        children: [
          SettingsSwitchRow(
            icon: Icons.swap_horiz,
            title: l10n.tx('Switch between Persian and English',
                'تغییر خودکار میان فارسی و انگلیسی'),
            value: settings.ttsAutoBilingual,
            onChanged: settings.setTtsAutoBilingual,
          ),
          AccessibleSliderRow(
            icon: Icons.space_bar_rounded,
            title: l10n.tx('Pause between words', 'مکث بین کلمات'),
            value: settings.ttsWordGap,
            min: 0,
            max: 50,
            // eSpeak-NG expresses the word gap in units of 10 ms.
            format: (v) =>
                l10n.tx('${v * 10} milliseconds', '${v * 10} میلی‌ثانیه'),
            onChanged: settings.setTtsWordGap,
            onReset: () => settings.setTtsWordGap(5),
          ),
          SettingsRow(
            icon: Icons.text_fields_rounded,
            title: l10n.tx('Capital letters', 'حروف بزرگ انگلیسی'),
            value: _capitalLabel(l10n, settings.ttsCapitalsMode),
            description: l10n.tx(
              'How a capital letter is indicated: beep, the word "Cap", higher pitch, or silent.',
              'نحوه اعلام حرف بزرگ: بوق صوتی، گفتن «Cap»، افزایش زیر و بمی یا بی‌صدا.',
            ),
            onTap: () async {
              final normalized = settings.ttsCapitalsMode >= 3
                  ? _capPitch
                  : settings.ttsCapitalsMode;
              final chosen = await showChoiceDialog<int>(
                context,
                title: l10n.tx('Capital letters', 'حروف بزرگ انگلیسی'),
                current: normalized,
                cancelLabel: l10n.translate('cancel'),
                options: [
                  ChoiceOption(_capNone, _capitalLabel(l10n, _capNone)),
                  ChoiceOption(_capBeep, _capitalLabel(l10n, _capBeep)),
                  ChoiceOption(_capSpoken, _capitalLabel(l10n, _capSpoken)),
                  ChoiceOption(_capPitch, _capitalLabel(l10n, _capPitch)),
                ],
              );
              if (chosen == null || !context.mounted) return;
              await settings.setTtsCapitalsMode(chosen);
              if (!context.mounted) return;
              AccessibilityService.announceAndNotify(
                context,
                l10n.tx(
                  'Capital letters: ${_capitalLabel(l10n, chosen)}.',
                  'حروف بزرگ: ${_capitalLabel(l10n, chosen)}.',
                ),
              );
            },
          ),
          SettingsRow(
            icon: Icons.pin_rounded,
            title: l10n.tx('Reading numbers', 'خوانش اعداد'),
            value: settings.ttsDigitMode == 1
                ? l10n.tx('Digit by digit', 'رقم به رقم')
                : l10n.tx('As a whole number', 'به‌صورت عدد کامل'),
            description: l10n.tx(
              'Read numbers as a mathematical number or one digit at a time.',
              'اعداد را به‌صورت یک عدد ریاضی یا رقم به رقم بخوان.',
            ),
            onTap: () async {
              final chosen = await showChoiceDialog<int>(
                context,
                title: l10n.tx('Reading numbers', 'خوانش اعداد'),
                current: settings.ttsDigitMode,
                cancelLabel: l10n.translate('cancel'),
                options: [
                  ChoiceOption(
                      0, l10n.tx('As a whole number', 'به‌صورت عدد کامل')),
                  ChoiceOption(1, l10n.tx('Digit by digit', 'رقم به رقم')),
                ],
              );
              if (chosen == null || !context.mounted) return;
              await settings.setTtsDigitMode(chosen);
              if (!context.mounted) return;
              AccessibilityService.announceAndNotify(
                context,
                chosen == 1
                    ? l10n.tx('Numbers are read digit by digit.',
                        'اعداد رقم به رقم خوانده می‌شوند.')
                    : l10n.tx('Numbers are read as whole numbers.',
                        'اعداد به‌صورت عدد کامل خوانده می‌شوند.'),
              );
            },
          ),
        ]);
  }
}
