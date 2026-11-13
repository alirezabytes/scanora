import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/settings_service.dart';
import '../../../services/tts/tts_models.dart';
import '../../widgets/settings_rows.dart';

String espeakPunctuationLabel(AppLocalizations l, TtsPunctuation mode) =>
    switch (mode) {
      TtsPunctuation.none => l.tx('None', 'هیچ‌کدام'),
      TtsPunctuation.some => l.tx('Some', 'بعضی'),
      TtsPunctuation.most => l.tx('Most', 'بیشتر'),
      TtsPunctuation.all => l.tx('All', 'همه'),
    };

Future<void> editEspeakPunctuation(BuildContext context) async {
  final settings = context.read<SettingsService>();
  final l = AppLocalizations.of(context);
  final selected = await showChoiceDialog<TtsPunctuation>(
    context,
    title: l.tx('Speak punctuation', 'خواندن علائم نگارشی'),
    current: settings.ttsPunctuation,
    cancelLabel: l.translate('cancel'),
    options: [
      for (final mode in TtsPunctuation.values)
        ChoiceOption(mode, espeakPunctuationLabel(l, mode)),
    ],
  );
  if (selected != null && context.mounted) {
    await settings.setTtsPunctuation(selected);
  }
}
