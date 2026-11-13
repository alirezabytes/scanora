import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';
import '../theme/app_theme.dart';

/// Shows a confirmation dialog designed for screen-reader users (screen reader).
///
/// Safety rules:
/// * Announces the exact section title and confirmation question via `SemanticsService`.
/// * The **Cancel** button is listed first and owns `autofocus: true`, so both the
///   hardware keyboard focus and the screen reader focus start on "Cancel".
/// * Dismissing the dialog by tapping outside or pressing Back is treated as Cancel.
Future<bool> showSafeConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? dismissLabel,
  bool destructive = false,
}) async {
  final l10n = AppLocalizations.of(context);
  AccessibilityService.announce(context, '$title. $message');

  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return Semantics(
        namesRoute: true,
        scopesRoute: true,
        explicitChildNodes: true,
        label: '$title. $message',
        child: AlertDialog(
          title: Semantics(
            header: true,
            child: Text(title),
          ),
          content: Text(message),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(dismissLabel ?? l10n.translate('cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    destructive ? AppTheme.errorRed : AppTheme.warningAmber,
                foregroundColor: destructive ? Colors.white : Colors.black,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
    },
  );
  return result == true;
}

Future<bool> confirmCancelOperation(BuildContext context, {String? message}) {
  final l10n = AppLocalizations.of(context);
  return showSafeConfirmDialog(
    context,
    title: l10n.tx('Cancel operation?', 'لغو عملیات؟'),
    message: message ??
        l10n.tx('Are you sure you want to cancel this operation?',
            'مطمئن هستید که می‌خواهید این عملیات را لغو کنید؟'),
    confirmLabel: l10n.tx('Yes, cancel', 'بله، لغو شود'),
    dismissLabel: l10n.tx('Continue working', 'ادامهٔ کار'),
    destructive: true,
  );
}
