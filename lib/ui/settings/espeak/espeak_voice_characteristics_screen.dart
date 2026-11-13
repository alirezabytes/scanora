import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/settings_service.dart';
import '../../../services/tts/espeak_tts_service.dart';
import '../../widgets/settings_rows.dart';
import '../widgets/accessible_slider_row.dart';
import '../../../services/tts/tts_models.dart';

Future<void> editEspeakVoice(BuildContext context) async {
  final settings = context.read<SettingsService>();
  final l10n = AppLocalizations.of(context);
  const defaultWpm = 175;
  var rate = settings.ttsRate;
  var pitch = settings.ttsPitch;
  var pitchRange = settings.ttsPitchRange;
  var volume = settings.ttsVolume;
  var rateBoost = settings.ttsRateBoost;

  TtsVoiceControls controls() => (
        rate: rate,
        pitch: pitch,
        pitchRange: pitchRange,
        volume: volume,
        rateBoost: rateBoost
      );

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(l10n.tx('Voice settings', 'تنظیمات صدا')),
        scrollable: true,
        content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AccessibleSliderRow(
                icon: Icons.speed_rounded,
                title: l10n.tx('Speech rate', 'سرعت گفتار'),
                value: rate,
                min: 80,
                max: 450,
                format: (v) {
                  final wpm = v * (rateBoost ? ttsRateBoostMultiplier : 1);
                  final pct = ((wpm * 100) / defaultWpm).round();
                  return l10n.tx('$wpm words per minute, $pct percent',
                      '$wpm کلمه در دقیقه، $pct درصد');
                },
                onChanged: (value) => setState(() => rate = value),
              ),
              SettingsSwitchRow(
                  icon: Icons.fast_forward_rounded,
                  title: l10n.tx('Rate boost', 'تقویت سرعت'),
                  description: l10n.tx('Read at three times the chosen speed.',
                      'سرعت خواندن را سه برابر می‌کند.'),
                  value: rateBoost,
                  onChanged: (value) => setState(() => rateBoost = value)),
              AccessibleSliderRow(
                icon: Icons.graphic_eq_rounded,
                title: l10n.tx('Base pitch', 'زیر و بمی صدا'),
                value: pitch,
                min: 0,
                max: 100,
                format: (v) => l10n.tx('$v percent', '$v درصد'),
                onChanged: (value) => setState(() => pitch = value),
              ),
              AccessibleSliderRow(
                icon: Icons.multiline_chart_rounded,
                title: l10n.tx('Pitch range', 'دامنهٔ زیر و بمی'),
                value: pitchRange,
                min: 0,
                max: 100,
                format: (v) => l10n.tx('$v percent', '$v درصد'),
                onChanged: (value) => setState(() => pitchRange = value),
              ),
              AccessibleSliderRow(
                icon: Icons.volume_up_rounded,
                title: l10n.tx('Volume', 'بلندی صدا'),
                value: volume,
                min: 0,
                max: 200,
                format: (v) => l10n.tx('$v percent', '$v درصد'),
                onChanged: (value) => setState(() => volume = value),
              ),
              TextButton(
                onPressed: () => EspeakTtsService.speakSample(settings,
                    voiceControls: controls()),
                child: Text(l10n.tx('Listen to a sample', 'شنیدن نمونه')),
              ),
              TextButton(
                onPressed: () => setState(() {
                  rate = defaultWpm;
                  pitch = 50;
                  pitchRange = 50;
                  volume = 100;
                  rateBoost = false;
                }),
                child:
                    Text(l10n.tx('Restore defaults', 'بازگرداندن پیش‌فرض‌ها')),
              ),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.translate('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.tx('Save', 'ذخیره'))),
        ],
      ),
    ),
  );
  if (saved != true || !context.mounted) return;
  if (settings.ttsRate != rate) await settings.setTtsRate(rate);
  if (settings.ttsPitch != pitch) await settings.setTtsPitch(pitch);
  if (settings.ttsPitchRange != pitchRange) {
    await settings.setTtsPitchRange(pitchRange);
  }
  if (settings.ttsVolume != volume) await settings.setTtsVolume(volume);
  if (settings.ttsRateBoost != rateBoost) {
    await settings.setTtsRateBoost(rateBoost);
  }
}
