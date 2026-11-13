import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/app_language.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/captcha/captcha_hotkey_service.dart';
import '../../services/cloud/scanora_cloud_ocr_service.dart';
import '../../services/settings_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/settings_rows.dart';
import 'ai_api_settings_screen.dart';
import 'captcha_hotkey_settings_screen.dart';
import 'general_settings_screen.dart';
import 'reading_playback_settings_screen.dart';
import 'storage_settings_screen.dart';
import 'about_settings_screen.dart';
import 'help_screen.dart';
import 'privacy_policy_screen.dart';
import 'espeak/espeak_settings_screen.dart';

/// Settings screen.
///
/// Every entry is a single merged row: title, current value and description are read
/// in one step and one tap / double-tap opens the page or toggles the option.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _showSmartCloudAuthDialog(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final initialInfo = await ScanoraCloudOcrService.refreshSyncStatus();
    if (!context.mounted) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final initialReport = initialInfo.fullReport(isPersian: l10n.isPersian);
    AccessibilityService.announce(context, initialReport);
    EspeakTtsService.speak(
      initialReport,
      settings: settings,
    );

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return ValueListenableBuilder<ScanoraCloudSyncInfo>(
          valueListenable: ScanoraCloudOcrService.syncStatusNotifier,
          builder: (dialogCtx, syncInfo, _) {
            final isSynced = syncInfo.isSynced;
            final statusReport = syncInfo.fullReport(isPersian: l10n.isPersian);
            final statusColor = isSynced
                ? AppTheme.successGreen
                : (syncInfo.stage == CloudSyncStage.pendingBrowser ||
                        syncInfo.stage == CloudSyncStage.checking
                    ? AppTheme.primaryCyan
                    : Colors.orangeAccent);

            return AlertDialog(
              title: Text(
                l10n.tx(
                  'Scanora Smart Cloud & Google Sync Status',
                  'وضعیت همگام‌سازی با گوگل (ابر هوشمند اسکنورا)',
                ),
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      container: true,
                      liveRegion: true,
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.6),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ExcludeSemantics(
                              child: Icon(
                                isSynced
                                    ? Icons.cloud_done_rounded
                                    : (syncInfo.stage ==
                                            CloudSyncStage.pendingBrowser
                                        ? Icons.hourglass_top_rounded
                                        : Icons.cloud_off_rounded),
                                color: statusColor,
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                statusReport,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      isSynced
                          ? l10n.tx(
                              'Your Google account is synced with Scanora Smart Cloud. You can check the sync status, switch to another Google account in the browser, or disconnect.',
                              'حساب گوگل شما با ابر هوشمند اسکنورا همگام‌سازی شده است. می‌توانید وضعیت همگام‌سازی را مجدداً بررسی کنید، حساب گوگل دیگری را در مرورگر انتخاب نمایید، یا همگام‌سازی را لغو کنید.',
                            )
                          : l10n.tx(
                              'Select "Choose Google Account" to open the Google account selector for Scanora and complete synchronization.',
                              'با انتخاب «انتخاب حساب گوگل»، صفحه انتخاب حساب گوگل ویژه اسکنورا باز می‌شود تا حساب خود را انتخاب و همگام‌سازی کنید.',
                            ),
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.translate('cancel')),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.sync_rounded),
                  label: Text(
                    l10n.tx(
                      'Check Sync Status',
                      'بررسی وضعیت همگام‌سازی',
                    ),
                  ),
                  onPressed: () async {
                    final refreshed =
                        await ScanoraCloudOcrService.refreshSyncStatus();
                    if (!context.mounted) return;
                    final msg = refreshed.fullReport(isPersian: l10n.isPersian);
                    AccessibilityService.announceAndNotify(context, msg);
                    EspeakTtsService.speak(
                      msg,
                      settings: settings,
                    );
                  },
                ),
                if (isSynced)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.logout_rounded),
                    label: Text(
                      l10n.tx(
                        'Disconnect Account',
                        'لغو همگام‌سازی حساب',
                      ),
                    ),
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      await ScanoraCloudOcrService.disconnectGoogleAccount();
                      if (!context.mounted) return;
                      final msg = l10n.tx(
                        'Google Sync Status: Disconnected from Google account.',
                        'وضعیت همگام‌سازی با گوگل: همگام‌سازی حساب لغو شد.',
                      );
                      AccessibilityService.announceAndNotify(context, msg);
                      EspeakTtsService.speak(
                        msg,
                        settings: settings,
                      );
                    },
                  ),
                FilledButton.icon(
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: Text(
                    isSynced
                        ? l10n.tx(
                            'Switch Google Account',
                            'تغییر حساب گوگل',
                          )
                        : l10n.tx(
                            'Choose Google Account',
                            'انتخاب حساب گوگل',
                          ),
                  ),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    final pendingMsg = l10n.tx(
                      'Google Sync Status: Pending — Opening Google sign-in for Scanora...',
                      'وضعیت همگام‌سازی با گوگل: در انتظار انجام — در حال باز کردن ورود گوگل برای اسکنورا...',
                    );
                    AccessibilityService.announceAndNotify(context, pendingMsg);
                    EspeakTtsService.speak(
                      pendingMsg,
                      settings: settings,
                    );
                    final ok =
                        await ScanoraCloudOcrService.authorizeWithBrowser(
                      isPersian: l10n.isPersian,
                    );
                    if (!context.mounted) return;
                    if (!ok) {
                      final info =
                          ScanoraCloudOcrService.syncStatusNotifier.value;
                      final resultMsg = info.fullReport(
                        isPersian: l10n.isPersian,
                      );
                      AccessibilityService.announceAndNotify(
                        context,
                        resultMsg,
                      );
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);
    final lang = AppLanguage.byCode(settings.locale.languageCode);

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        SettingsSectionHeader(l10n.tx('General', 'عمومی')),
        SettingsRow(
          icon: Icons.tune_rounded,
          title: l10n.tx('General settings', 'تنظیمات عمومی'),
          value: l10n.tx(
            '${lang.displayName}, ${settings.isOfflineMode ? "offline engine" : "online engine"}',
            '${lang.displayName}، ${settings.isOfflineMode ? "موتور آفلاین" : "موتور آنلاین"}',
          ),
          description: l10n.tx(
            'Language, work offline, default online service, auto-copy and theme.',
            'زبان، حالت آفلاین، سرویس پیش‌فرض آنلاین، کپی خودکار و تم.',
          ),
          onTap: () => _open(context, const GeneralSettingsScreen()),
        ),
        SettingsSectionHeader(l10n.tx('Speech & reading', 'صدا و مطالعه')),
        SettingsRow(
            icon: Icons.record_voice_over_rounded,
            title: 'eSpeak-NG',
            description: l10n.tx('Reading language, voice and punctuation.',
                'زبان خواندن، صدا و علائم نگارشی.'),
            onTap: () => _open(context, const EspeakSettingsScreen())),
        SettingsRow(
          icon: Icons.play_lesson_rounded,
          title: l10n.tx('Reading & Playback', 'خوانش و پخش صوتی'),
          value: settings.enableInternalTts
              ? l10n.tx('Built-in reader on', 'خوانش داخلی روشن')
              : l10n.tx('Built-in reader off', 'خوانش داخلی خاموش'),
          description: l10n.tx(
            'Audio player bar, start mode, auto-advance page, skip step and page numbers.',
            'نوار پخش، نحوه شروع، رفتن خودکار به صفحه بعد، گام پرش و شماره صفحه.',
          ),
          onTap: () => _open(context, const ReadingPlaybackSettingsScreen()),
        ),
        SettingsSectionHeader(l10n.tx('Recognition', 'تشخیص')),
        SettingsSwitchRow(
            icon: Icons.mic_rounded,
            title:
                l10n.tx('More accurate offline speech', 'گفتار آفلاین دقیق‌تر'),
            description: l10n.tx(
                'Turn off for lighter processing on devices with less memory.',
                'برای پردازش سبک‌تر در دستگاه‌های با حافظهٔ کمتر، این گزینه را خاموش کنید.'),
            value: settings.accurateSpeech,
            onChanged: settings.setAccurateSpeech),
        SettingsSectionHeader(
            l10n.tx('Connections', 'کلیدهای ارتباطی و ابر هوشمند')),
        ValueListenableBuilder<ScanoraCloudSyncInfo>(
          valueListenable: ScanoraCloudOcrService.syncStatusNotifier,
          builder: (context, syncInfo, _) {
            final shortSyncText = syncInfo.shortStatus(
              isPersian: l10n.isPersian,
            );
            final fullSyncText = syncInfo.fullReport(
              isPersian: l10n.isPersian,
            );
            return Column(
              children: [
                SettingsRow(
                  icon: syncInfo.isSynced
                      ? Icons.verified_user_rounded
                      : (syncInfo.stage == CloudSyncStage.pendingBrowser
                          ? Icons.sync_rounded
                          : Icons.cloud_sync_rounded),
                  title: l10n.tx(
                    'Scanora Cloud — Google account',
                    'ابر اسکنورا — حساب گوگل',
                  ),
                  value: shortSyncText,
                  description: fullSyncText,
                  onTap: () => _showSmartCloudAuthDialog(context, l10n),
                ),
              ],
            );
          },
        ),
        SettingsRow(
          icon: Icons.key_rounded,
          title: l10n.tx('Connection keys (AI providers)',
              'کلیدهای ارتباطی (سرویس‌های هوش مصنوعی)'),
          description: l10n.tx(
            'Add or update your connection key and refresh its model list.',
            'کلید ارتباطی را وارد یا به‌روز کنید و فهرست مدل‌ها را دریافت کنید.',
          ),
          onTap: () => _open(context, const AiApiSettingsScreen()),
        ),
        if (CaptchaHotkeyService.isSupported) ...[
          SettingsSectionHeader(l10n.tx('Windows', 'ویندوز')),
          SettingsRow(
            icon: Icons.keyboard_rounded,
            title: l10n.tx('Captcha Hotkey', 'کلید میانبر کپچا'),
            value: settings.captchaHotkeyEnabled
                ? CaptchaHotkeyService.describe(settings.captchaHotkey)
                : l10n.tx('Off', 'خاموش'),
            description: l10n.tx(
              'Solve a labelled captcha image in the active window.',
              'حل تصویر کپچا در پنجرهٔ فعال.',
            ),
            onTap: () => _open(context, const CaptchaHotkeySettingsScreen()),
          ),
        ],
        SettingsSectionHeader(l10n.tx('Storage', 'ذخیره‌سازی')),
        SettingsRow(
          icon: Icons.folder_special_rounded,
          title: l10n.tx(
              'File location & Storage', 'مسیر ذخیره فایل‌ها و ذخیره‌سازی'),
          description: l10n.tx(
            'View or change the folder used for exported files.',
            'مشاهده یا تغییر پوشه فایل‌های خروجی.',
          ),
          onTap: () => _open(context, const StorageSettingsScreen()),
        ),
        SettingsSectionHeader(
            l10n.tx('Help & information', 'راهنما و اطلاعات')),
        SettingsRow(
            icon: Icons.help_outline_rounded,
            title: l10n.tx('Help & FAQ', 'راهنما و پرسش‌های رایج'),
            description: l10n.tx(
                'Using Scanora offline, reading with a screen reader, and getting help with photos, cameras and books.',
                'کار بدون اینترنت، استفاده از صفحه‌خوان و راهنمای خواندن عکس، کار با دوربین و باز کردن کتاب.'),
            onTap: () => _open(context, const HelpScreen())),
        SettingsRow(
          icon: Icons.privacy_tip_outlined,
          title: l10n.tx('Privacy Policy', 'سیاست حریم خصوصی'),
          description: l10n.tx(
            'Where your photos, files and recordings go when you use Scanora.',
            'عکس‌ها، فایل‌ها و صداهای ضبط‌شده هنگام استفاده از اسکنورا کجا می‌روند.',
          ),
          onTap: () => _open(context, const PrivacyPolicyScreen()),
        ),
        SettingsRow(
          icon: Icons.info_outline_rounded,
          title: l10n.translate('about_section'),
          value: l10n.translate('version'),
          description: l10n.tx(
            'Application version, built-in AI engines and accessibility details.',
            'نسخه برنامه، موتورهای هوش مصنوعی توکار و مشخصات دسترسی‌پذیری.',
          ),
          onTap: () => _open(context, const AboutSettingsScreen()),
        ),
      ],
    );
  }
}
