import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/settings_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../widgets/settings_rows.dart';
import 'widgets/settings_page.dart';

/// Reading & audio playback preferences. Every entry is one merged row.
class ReadingPlaybackSettingsScreen extends StatelessWidget {
  const ReadingPlaybackSettingsScreen({super.key});

  static const List<int> _seekPresets = [
    5,
    10,
    15,
    20,
    30,
    45,
    60,
    90,
    120,
    180,
    300
  ];

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);

    final presets = <int>{..._seekPresets, settings.ttsSeekSeconds}.toList()
      ..sort();

    return SettingsPage(
      title: l10n.tx('Reading & Playback', 'خوانش و پخش صوتی'),
      children: [
        SettingsSwitchRow(
          icon: Icons.article_outlined,
          title: l10n.tx('Show book text', 'نمایش متن کتاب'),
          description: l10n.tx(
            'Show the page text when the built-in audio reader is enabled.',
            'وقتی خوانش صوتی داخلی روشن است، متن صفحه را نمایش بده.',
          ),
          value: settings.showReaderText,
          onChanged: settings.setShowReaderText,
        ),
        SettingsSwitchRow(
          icon: Icons.view_column_rounded,
          title: l10n.tx(
              'Detect columns and headings', 'تشخیص ستون‌ها و عنوان‌ها'),
          description: l10n.tx(
            'Use column reading order and announce headings when opening a new document.',
            'هنگام باز کردن سند تازه، ستون‌ها را به‌ترتیب بخوان و عنوان‌ها را اعلام کن.',
          ),
          value: settings.documentLayout,
          onChanged: settings.setDocumentLayout,
        ),
        SettingsSwitchRow(
            icon: Icons.percent_rounded,
            title: l10n.tx('Announce progress', 'اعلام درصد پیشرفت'),
            description: l10n.tx(
                'Read progress updates aloud. Completion and errors are always announced.',
                'درصد پیشرفت خوانده شود. پایان کار و خطاها همیشه اعلام می‌شوند.'),
            value: settings.announceProgress,
            onChanged: settings.setAnnounceProgress),
        SettingsSwitchRow(
          icon: Icons.record_voice_over_rounded,
          title: l10n.tx('Built-in audio reader', 'خوانش صوتی داخلی برنامه'),
          description: l10n.tx(
            'Shows the audio player bar under texts and documents.',
            'نوار پخش صوتی را زیر متن‌ها و اسناد نمایش می‌دهد.',
          ),
          value: settings.enableInternalTts,
          onChanged: (v) async {
            if (!v) await EspeakTtsService.stop();
            await settings.setEnableInternalTts(v);
          },
        ),
        SettingsRow(
          icon: Icons.play_circle_outline_rounded,
          title: l10n.tx('Playback start mode', 'نحوه شروع خوانش'),
          value: settings.autoReadOnOpen
              ? l10n.tx('Read automatically', 'خوانش خودکار')
              : l10n.tx('Wait for the Play button', 'منتظر دکمه پخش'),
          description: l10n.tx(
            'Whether a text is read as soon as it opens.',
            'اینکه متن به محض باز شدن خوانده شود یا نه.',
          ),
          onTap: () async {
            final chosen = await showChoiceDialog<bool>(
              context,
              title: l10n.tx('Playback start mode', 'نحوه شروع خوانش'),
              current: settings.autoReadOnOpen,
              cancelLabel: l10n.translate('cancel'),
              options: [
                ChoiceOption(false,
                    l10n.tx('Wait for the Play button', 'منتظر دکمه پخش')),
                ChoiceOption(
                    true, l10n.tx('Read automatically', 'خوانش خودکار')),
              ],
            );
            if (chosen == null) return;
            await settings.setAutoReadOnOpen(chosen);
          },
        ),
        SettingsSwitchRow(
          icon: Icons.skip_next_rounded,
          title: l10n.tx(
            'Auto-advance to next page',
            'رفتن خودکار به صفحه بعد پس از اتمام صفحه',
          ),
          description: l10n.tx(
            'When enabled, automatically moves to the next page when the current page finishes reading. When off, stays on the current page.',
            'در صورت فعال بودن، پس از پایان خوانش صفحه فعلی به طور خودکار به صفحه بعد می‌رود؛ در غیر این صورت روی همان صفحه باقی می‌ماند.',
          ),
          value: settings.autoAdvancePage,
          onChanged: settings.setAutoAdvancePage,
        ),
        SettingsSwitchRow(
          icon: Icons.menu_book_outlined,
          title: l10n.tx('Page-turn sound', 'صدای ورق زدن'),
          value: settings.playPageFlipSound,
          onChanged: settings.setPlayPageFlipSound,
        ),
        SettingsRow(
          icon: Icons.fast_forward_rounded,
          title: l10n.tx('Skip step', 'گام پرش زمانی'),
          value: l10n.tx('${settings.ttsSeekSeconds} seconds',
              '${settings.ttsSeekSeconds} ثانیه'),
          description: l10n.tx(
            'How far the forward and rewind buttons jump.',
            'میزان پرش دکمه‌های جلو و عقب.',
          ),
          onTap: () async {
            final chosen = await showChoiceDialog<int>(
              context,
              title: l10n.tx('Skip step', 'گام پرش زمانی'),
              current: settings.ttsSeekSeconds,
              cancelLabel: l10n.translate('cancel'),
              options: [
                for (final s in presets)
                  ChoiceOption(s, l10n.tx('$s seconds', '$s ثانیه')),
              ],
            );
            if (chosen == null) return;
            await settings.setTtsSeekSeconds(chosen);
            if (!context.mounted) return;
            AccessibilityService.announceAndNotify(
              context,
              l10n.tx('Skip step: $chosen seconds.', 'گام پرش: $chosen ثانیه.'),
            );
          },
        ),
        SettingsSwitchRow(
          icon: Icons.numbers_rounded,
          title: l10n.tx('Announce page numbers', 'اعلام شماره صفحه'),
          description: l10n.tx(
            'Adds "Page X" at the start of every page when reading and exporting.',
            'هنگام خوانش و خروجی گرفتن، عبارت «صفحه X» در ابتدای هر صفحه می‌آید.',
          ),
          value: settings.includePageNumbersInOutput,
          onChanged: settings.setIncludePageNumbersInOutput,
        ),
      ],
    );
  }
}
