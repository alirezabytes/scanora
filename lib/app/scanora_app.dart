import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/app_language.dart';
import '../services/settings_service.dart';
import '../ui/hub/adaptive_hub_screen.dart';
import '../ui/onboarding/first_launch_screen.dart';
import '../ui/theme/app_theme.dart';
import '../ui/widgets/demo_license_overlay.dart';

/// Root widget of Scanora (Material 3).
class ScanoraApp extends StatelessWidget {
  const ScanoraApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations(settings.locale);

    return MaterialApp(
      restorationScopeId: 'scanora',
      // Used by the OS / screen readers as the application name.
      title: l10n.tx('Scanora', 'اسکنورا'),
      debugShowCheckedModeBanner: false,
      locale: settings.locale,
      supportedLocales: [for (final l in AppLanguage.all) Locale(l.code)],
      localizationsDelegates: const [
        AppLocalizationsDelegate(),
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme:
          settings.isDarkTheme ? AppTheme.darkTheme() : AppTheme.lightTheme(),
      home: DemoLicenseOverlay(
        child: settings.isFirstLaunch
            ? const FirstLaunchScreen()
            : const AdaptiveHubScreen(),
      ),
    );
  }
}
