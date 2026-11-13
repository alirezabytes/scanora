import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/app_language.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/cloud/scanora_cloud_ocr_service.dart';
import '../../services/settings_service.dart';
import '../widgets/settings_rows.dart';
import 'widgets/settings_page.dart';

/// General settings: interface language, online/offline engine, default online service,
/// auto-copy, theme.
class GeneralSettingsScreen extends StatelessWidget {
  const GeneralSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);
    final current = AppLanguage.byCode(settings.locale.languageCode);

    return SettingsPage(
      title: l10n.tx('General', 'تنظیمات عمومی'),
      children: [
        SettingsRow(
          icon: Icons.language_rounded,
          title: l10n.tx('Language', 'زبان برنامه'),
          value: current.displayName,
          description: l10n.tx(
            'Language of menus and messages.',
            'زبان منوها و پیام‌های برنامه.',
          ),
          onTap: () async {
            final chosen = await showChoiceDialog<String>(
              context,
              title: l10n.tx('Language', 'زبان برنامه'),
              current: current.code,
              cancelLabel: l10n.translate('cancel'),
              options: [
                for (final lang in AppLanguage.all)
                  ChoiceOption(lang.code, lang.displayName),
              ],
            );
            if (chosen == null || chosen == current.code) return;
            await settings.setLanguage(chosen);
            if (!context.mounted) return;
            final next = AppLocalizations(Locale(chosen));
            AccessibilityService.announceAndNotify(
              context,
              next.tx('Application language updated.',
                  'زبان برنامه به فارسی تغییر یافت.'),
            );
          },
        ),
        SettingsSwitchRow(
          icon: Icons.wifi_off_rounded,
          title: l10n.translate('work_offline_label'),
          description: l10n.translate('work_offline_desc'),
          value: settings.isOfflineMode,
          onChanged: settings.toggleOfflineMode,
        ),
        if (!settings.isOfflineMode)
          ValueListenableBuilder<ScanoraCloudSyncInfo>(
            valueListenable: ScanoraCloudOcrService.syncStatusNotifier,
            builder: (context, syncInfo, _) {
              final syncLabel = syncInfo.shortStatus(isPersian: l10n.isPersian);
              return SettingsRow(
                icon: Icons.cloud_sync_rounded,
                title: l10n.tx(
                  'Default Online Service',
                  'سرویس پیش‌فرض حالت آنلاین',
                ),
                value: settings.useScanoraCloudOcr
                    ? l10n.tx(
                        'Scanora Smart Cloud ($syncLabel)',
                        'ابر هوشمند اسکنورا ($syncLabel)',
                      )
                    : l10n.tx(
                        'Connection Keys (AI Providers)',
                        'کلیدهای ارتباطی (سرویس‌های هوش مصنوعی)',
                      ),
                description: l10n.tx(
                  'Choose whether Online mode uses Scanora Smart Cloud or your AI provider connection keys by default.',
                  'انتخاب کنید که در حالت آنلاین، به طور پیش‌فرض از «ابر هوشمند اسکنورا» استفاده شود یا از «کلیدهای ارتباطی».',
                ),
                onTap: () async {
                  final chosen = await showChoiceDialog<bool>(
                    context,
                    title: l10n.tx(
                      'Default Online Service',
                      'سرویس پیش‌فرض حالت آنلاین',
                    ),
                    current: settings.useScanoraCloudOcr,
                    cancelLabel: l10n.translate('cancel'),
                    options: [
                      ChoiceOption(
                        true,
                        l10n.tx(
                          'Scanora Smart Cloud (No API key needed)',
                          'ابر هوشمند اسکنورا (بدون نیاز به کلید ارتباطی)',
                        ),
                      ),
                      ChoiceOption(
                        false,
                        l10n.tx(
                          'Connection Keys (AI Providers)',
                          'کلیدهای ارتباطی (سرویس‌های هوش مصنوعی)',
                        ),
                      ),
                    ],
                  );
                  if (chosen == null || chosen == settings.useScanoraCloudOcr) {
                    return;
                  }
                  await settings.setUseScanoraCloudOcr(chosen);
                  if (!context.mounted) return;
                  AccessibilityService.announceAndNotify(
                    context,
                    chosen
                        ? l10n.tx(
                            'Default online service set to Scanora Smart Cloud ($syncLabel).',
                            'سرویس پیش‌فرض حالت آنلاین روی ابر هوشمند اسکنورا ($syncLabel) تنظیم شد.',
                          )
                        : l10n.tx(
                            'Default online service set to Connection Keys.',
                            'سرویس پیش‌فرض حالت آنلاین روی کلیدهای ارتباطی تنظیم شد.',
                          ),
                  );
                },
              );
            },
          ),
        SettingsSwitchRow(
          icon: Icons.copy_all_rounded,
          title: l10n.translate('auto_copy_label'),
          description: l10n.tx(
            'Copies the result to the clipboard right after text extraction or captcha solving.',
            'نتیجه بلافاصله پس از استخراج متن یا حل کپچا در کلیپ‌بورد کپی می‌شود.',
          ),
          value: settings.autoCopyCaptcha,
          onChanged: settings.setAutoCopyCaptcha,
        ),
        SettingsSwitchRow(
          icon: Icons.dark_mode_rounded,
          title: l10n.translate('dark_theme'),
          value: settings.isDarkTheme,
          onChanged: settings.toggleDarkTheme,
        ),
      ],
    );
  }
}
