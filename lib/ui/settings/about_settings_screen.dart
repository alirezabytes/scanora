import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'help_screen.dart';
import 'privacy_policy_screen.dart';

/// Dedicated Sub-Screen for About Scanora (separated from Storage)
class AboutSettingsScreen extends StatelessWidget {
  const AboutSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isFa = l10n.isPersian;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: l10n.translate('back'),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          isFa ? 'درباره اسکنورا' : 'About Scanora',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
      body: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryCyan.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.document_scanner_rounded,
                          color: AppTheme.primaryCyan,
                          size: 36,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.translate('app_title'),
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.translate('version'),
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.primaryCyan,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  Semantics(
                      header: true,
                      child: Text(
                          isFa
                              ? 'بنیان‌گذار و توسعه‌دهنده'
                              : 'Founder & developer',
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                  const SizedBox(height: 8),
                  Text(isFa ? 'علیرضا مرزبان' : 'alireza marzbn',
                      style: const TextStyle(fontSize: 20)),
                  const SizedBox(height: 20),
                  Text(
                    isFa
                        ? 'اسکنورا به شما کمک می‌کند متن عکس و کتاب را بخوانید، به نوشته‌ها گوش دهید و یادداشت صوتی خود را به متن تبدیل کنید. امکانات برنامه برای استفاده با صفحه‌خوان طراحی شده‌اند.'
                        : 'Scanora helps you read photos and books, listen to text and turn voice notes into writing. Its controls are designed for use with a screen reader.',
                    style: const TextStyle(fontSize: 14, height: 1.65),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isFa
                        ? 'کارهایی که می‌توانید انجام دهید:'
                        : 'What you can do:',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  _buildFeatureRow(
                    Icons.text_fields_rounded,
                    isFa
                        ? 'خواندن نوشته‌های انگلیسی، فارسی و ترکیبی'
                        : 'Read English, Persian and mixed text',
                  ),
                  _buildFeatureRow(
                    Icons.shield_rounded,
                    isFa
                        ? 'خواندن کدهای امنیتی متنی و محاسبات ساده'
                        : 'Read text security codes and simple calculations',
                  ),
                  _buildFeatureRow(
                    Icons.visibility_rounded,
                    isFa
                        ? 'پرسیدن دربارهٔ اشیا و نوشته‌های تصویر'
                        : 'Ask about objects and writing in pictures',
                  ),
                  _buildFeatureRow(
                    Icons.mic_rounded,
                    isFa
                        ? 'تبدیل یادداشت صوتی به متن، با اینترنت یا بدون آن'
                        : 'Turn voice notes into text, online or offline',
                  ),
                  _buildFeatureRow(
                    Icons.record_voice_over_rounded,
                    isFa
                        ? 'گوش‌دادن به متن با صدای داخلی یا صفحه‌خوان'
                        : 'Listen with the built-in voice or your screen reader',
                  ),
                  const Divider(height: 28),
                  Text(
                      isFa
                          ? 'بسیاری از امکانات بدون اینترنت کار می‌کنند. برای استفاده از خدمات آنلاین، حالت آنلاین و سرویس دلخواه را در تنظیمات انتخاب کنید.'
                          : 'Many features work without internet. To use online services, choose online mode and your preferred service in Settings.',
                      style: const TextStyle(height: 1.65)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                      icon: const Icon(Icons.help_outline),
                      label:
                          Text(isFa ? 'راهنما و پرسش‌های رایج' : 'Help & FAQ'),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => const HelpScreen()))),
                  OutlinedButton.icon(
                      icon: const Icon(Icons.privacy_tip_outlined),
                      label:
                          Text(l10n.tx('Privacy Policy', 'سیاست حریم خصوصی')),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => const PrivacyPolicyScreen()))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppTheme.primaryCyan),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
