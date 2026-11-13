import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/a11y/accessibility_service.dart';
import '../../../services/diagnostics_service.dart';
import '../../../services/native_bridge_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/tts/espeak_dictionary_service.dart';
import '../../../services/tts/espeak_tts_service.dart';
import '../../widgets/settings_rows.dart';
import '../widgets/settings_page.dart';
import 'espeak_punctuation_screen.dart';
import 'espeak_advanced_reading_screen.dart';
import 'espeak_voice_characteristics_screen.dart';
import 'espeak_voice_language_screen.dart';

class EspeakSettingsScreen extends StatelessWidget {
  const EspeakSettingsScreen({super.key});

  Future<void> _importDictionary(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final settings = context.read<SettingsService>();
    var busy = false;
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty || !context.mounted) return;
      final file = files.first;
      final bytes = await file.readAsBytes();
      if (!context.mounted) return;
      if (!EspeakDictionaryService.isValid(file.name, bytes)) {
        AccessibilityService.announceAndNotify(
            context,
            l.tx(
                'This is not a compatible voice dictionary. Choose an eSpeak dictionary file ending in _dict.',
                'این فایل واژه‌نامهٔ سازگار نیست. فایل واژه‌نامهٔ eSpeak با نامی که به _dict ختم می‌شود انتخاب کنید.'));
        return;
      }
      busy = true;
      unawaited(showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PopScope(
              canPop: false,
              child: AlertDialog(
                  content: Row(children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                    child: Text(
                        l.tx('Adding dictionary…', 'در حال افزودن واژه‌نامه…')))
              ])))));
      final path = await EspeakDictionaryService.importDictionary(
          file.name, bytes,
          previousDataDirectory: settings.espeakDataDirectory);
      await settings.setEspeakDataDirectory(path);
      if (Platform.isWindows) {
        NativeBridgeService.espeakDataOverride = path;
        await EspeakTtsService.restartEngine();
      }
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      busy = false;
      AccessibilityService.announceAndNotify(
          context,
          Platform.isAndroid
              ? l.tx('Dictionary added. Close and reopen Scanora to use it.',
                  'واژه‌نامه اضافه شد. برای استفاده، اسکنورا را ببندید و دوباره باز کنید.')
              : l.tx('Dictionary added.', 'واژه‌نامه اضافه شد.'));
    } catch (error, stack) {
      DiagnosticsService.record('voice.dictionary', error, stack);
      if (!context.mounted) return;
      if (busy) Navigator.of(context, rootNavigator: true).pop();
      AccessibilityService.announceAndNotify(
          context,
          l.tx('The dictionary could not be added.',
              'افزودن واژه‌نامه انجام نشد.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = context.watch<SettingsService>();
    return SettingsPage(title: 'eSpeak-NG', children: [
      const EspeakReadingLanguageRow(),
      SettingsRow(
          icon: Icons.file_open_outlined,
          title: l.tx('Import dictionary', 'افزودن واژه‌نامه'),
          onTap: () => _importDictionary(context)),
      const EspeakVoiceVariantRow(),
      SettingsRow(
          icon: Icons.format_quote_outlined,
          title: l.tx('Speak punctuation', 'خواندن علائم نگارشی'),
          value: espeakPunctuationLabel(l, s.ttsPunctuation),
          onTap: () => editEspeakPunctuation(context)),
      SettingsSwitchRow(
          icon: Icons.spellcheck_outlined,
          title: l.tx('Normalize text', 'یکسان‌سازی متن'),
          description: l.tx('Read decorative letters as ordinary letters.',
              'حروف تزئینی را مانند حروف معمولی بخواند.'),
          value: s.ttsUnicodeNormalization,
          onChanged: s.setTtsUnicodeNormalization),
      SettingsRow(
          icon: Icons.graphic_eq,
          title: l.tx('Voice settings', 'تنظیمات صدا'),
          description: l.tx('Rate, pitch, pitch range and volume.',
              'سرعت، زیر و بمی، دامنهٔ زیر و بمی و بلندی صدا.'),
          onTap: () => editEspeakVoice(context)),
      SettingsRow(
          icon: Icons.volume_up_outlined,
          title: l.tx('Listen to a sample', 'شنیدن نمونه'),
          showChevron: false,
          onTap: () => EspeakTtsService.speakSample(s)),
      SettingsRow(
          icon: Icons.tune,
          title: l.tx('Advanced reading options', 'گزینه‌های پیشرفتهٔ خواندن'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const EspeakAdvancedReadingScreen()))),
    ]);
  }
}
