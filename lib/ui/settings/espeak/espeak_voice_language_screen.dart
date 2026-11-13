import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/a11y/accessibility_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/tts/espeak_tts_service.dart';
import '../../widgets/settings_rows.dart';
import '../widgets/searchable_picker.dart';

List<PickerItem> _items(
  List<EspeakVoiceOption> source,
  bool persian,
) {
  final seen = <String>{};
  final out = <PickerItem>[];
  for (final v in source) {
    if (seen.add(v.code)) {
      out.add(PickerItem(v.code, persian ? v.nameFa : v.nameEn, v.group));
    }
  }
  return out;
}

String _nameOf(List<EspeakVoiceOption> source, String code, bool persian) {
  for (final v in source) {
    if (v.code == code) return persian ? v.nameFa : v.nameEn;
  }
  return code;
}

class EspeakReadingLanguageRow extends StatelessWidget {
  const EspeakReadingLanguageRow({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final l10n = AppLocalizations.of(context);
    final fa = l10n.isPersian;
    return SettingsRow(
      icon: Icons.translate_rounded,
      title: l10n.tx('Reading language', 'زبان خواندن'),
      value: _nameOf(EspeakTtsService.supportedVoices, settings.ttsVoice, fa),
      description: l10n.tx(
        'Language the voice speaks. "Auto-detect" picks Persian or English for each sentence.',
        'زبانی که صدا با آن سخن می‌گوید. «تشخیص خودکار» برای هر جمله فارسی یا انگلیسی را انتخاب می‌کند.',
      ),
      onTap: () async {
        final chosen = await showSearchablePicker(
          context,
          title: l10n.tx('Reading language', 'زبان خواندن'),
          items: _items(EspeakTtsService.supportedVoices, fa),
          current: settings.ttsVoice,
          cancelLabel: l10n.translate('cancel'),
          searchLabel: l10n.tx('Search languages', 'جستجوی زبان'),
        );
        if (chosen == null || !context.mounted) return;
        await settings.setTtsVoice(chosen);
        if (!context.mounted) return;
        AccessibilityService.announceAndNotify(
          context,
          l10n.tx(
            'Language set to ${_nameOf(EspeakTtsService.supportedVoices, chosen, false)}.',
            'زبان صدا روی ${_nameOf(EspeakTtsService.supportedVoices, chosen, true)} تنظیم شد.',
          ),
        );
      },
    );
  }
}

class EspeakVoiceVariantRow extends StatelessWidget {
  const EspeakVoiceVariantRow({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final l10n = AppLocalizations.of(context);
    final fa = l10n.isPersian;
    return SettingsRow(
      icon: Icons.record_voice_over_rounded,
      title: l10n.tx('Voice variant', 'نوع صدا'),
      value: _nameOf(EspeakTtsService.voiceVariants, settings.ttsVariant, fa),
      description: l10n.tx(
        'Choose the character of the voice.',
        'مردانه، زنانه، نجوا، پیر، جوان و سایر رنگ‌های صدا.',
      ),
      onTap: () async {
        final chosen = await showSearchablePicker(
          context,
          title: l10n.tx('Voice variant', 'نوع صدا'),
          items: _items(EspeakTtsService.voiceVariants, fa),
          current: settings.ttsVariant,
          cancelLabel: l10n.translate('cancel'),
          searchLabel: l10n.tx('Search voices', 'جستجوی صدا'),
        );
        if (chosen == null || !context.mounted) return;
        await settings.setTtsVariant(chosen);
        if (!context.mounted) return;
        AccessibilityService.announceAndNotify(
          context,
          l10n.tx(
            'Voice variant set to ${_nameOf(EspeakTtsService.voiceVariants, chosen, false)}.',
            'نوع صدا روی ${_nameOf(EspeakTtsService.voiceVariants, chosen, true)} تنظیم شد.',
          ),
        );
      },
    );
  }
}
