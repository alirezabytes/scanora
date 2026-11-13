import '../../services/a11y/accessibility_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_language.dart';
import '../../services/settings_service.dart';
import '../theme/app_theme.dart';

/// First-launch screen: English-only prompt with "English (Default)" and "Persian"
/// as two merged radio rows so a blind user is never lost on first entry.
class FirstLaunchScreen extends StatefulWidget {
  const FirstLaunchScreen({super.key});

  @override
  State<FirstLaunchScreen> createState() => _FirstLaunchScreenState();
}

class _FirstLaunchScreenState extends State<FirstLaunchScreen> {
  String _selected = AppLanguage.english.code;

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context, listen: false);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ExcludeSemantics(
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  AppTheme.primaryCyan,
                                  AppTheme.accentIndigo
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(
                              Icons.remove_red_eye_rounded,
                              size: 38,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Semantics(
                        header: true,
                        child: const Text(
                          'Choose your language',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w900),
                        ),
                      ),
                      const SizedBox(height: 16),
                      RadioGroup<String>(
                        groupValue: _selected,
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _selected = v);
                            AccessibilityService.announce(
                                context,
                                v == 'fa'
                                    ? 'فارسی انتخاب شد'
                                    : 'English selected');
                          }
                        },
                        child: Column(
                          children: [
                            MergeSemantics(
                              child: RadioListTile<String>(
                                autofocus: true,
                                value: AppLanguage.english.code,
                                title: const Text(
                                  'English (Default)',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            MergeSemantics(
                              child: RadioListTile<String>(
                                value: AppLanguage.persian.code,
                                title: const Text(
                                  'Persian',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 50,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.check_rounded, size: 20),
                          onPressed: () => settings.setLanguage(_selected),
                          label: const Text(
                            'Continue',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
