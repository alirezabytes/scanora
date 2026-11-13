import 'dart:async';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/ai/ai_access.dart';
import '../../services/ai/online_access_service.dart';
import '../../services/settings_service.dart';
import '../../services/a11y/reader_feedback.dart';
import '../settings/ai_api_settings_screen.dart';
export '../../services/ai/online_access_service.dart' show OnlineTask;

/// Reject invalid access before a camera, recording, or processing starts.
class OnlineAccessGuard {
  static final _active = <Object>{};
  static final _errors = Expando<String>('onlineAccessError');
  static String? failureFor(BuildContext context) => _errors[context];

  static Future<bool> require(BuildContext context, SettingsService settings,
      {OnlineTask task = OnlineTask.vision}) async {
    if (settings.isOfflineMode) return true;
    final Object operation = context;
    if (!_active.add(operation)) return false;
    _errors[context] = null;
    final l = AppLocalizations.of(context);
    DialogRoute<void>? checking;
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      OnlineAccessService.validate(settings, task: task);
      checking = DialogRoute<void>(
          context: context,
          barrierDismissible: true,
          builder: (_) => AlertDialog(
                title:
                    Text(l.tx('Checking online access', 'بررسی دسترسی آنلاین')),
                content: Row(children: [
                  const CircularProgressIndicator(),
                  const SizedBox(width: 18),
                  Expanded(
                      child: Text(l.tx(
                          'Checking the service connection and account access…',
                          'در حال بررسی اتصال سرویس و دسترسی حساب…'))),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => navigator.pop(),
                      child: Text(l.translate('cancel')))
                ],
              ));
      unawaited(navigator.push(checking));
      unawaited(ReaderFeedback.speak(
          context,
          l.tx('Checking online access.', 'در حال بررسی دسترسی آنلاین.'),
          settings));
      final verified = await Future.any<bool>([
        OnlineAccessService.ensure(settings, task: task, force: true)
            .then((_) => true),
        checking.popped.then((_) => false),
      ]);
      if (!verified) return false;
      if (!context.mounted || !checking.isActive) return false;
      navigator.removeRoute(checking);
      checking = null;
      return true;
    } catch (error) {
      if (!context.mounted) return false;
      if (checking != null && !checking.isActive) return false;
      if (checking != null) {
        navigator.removeRoute(checking);
        checking = null;
      }
      final message = AiServiceException.fromError(error).message(l.isPersian);
      _errors[context] = message;
      unawaited(
          ReaderFeedback.speak(context, message, settings, assertive: true));
      final openSettings = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
                title: Text(l.tx(
                    'Online service is not ready', 'سرویس آنلاین آماده نیست')),
                content: SelectableText(message),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: Text(l.tx('Close', 'بستن'))),
                  if (!(task == OnlineTask.ocr && settings.useScanoraCloudOcr))
                    TextButton(
                        onPressed: () => Navigator.pop(dialog, true),
                        child: Text(l.tx('AI settings', 'تنظیمات هوش مصنوعی'))),
                ],
              ));
      if (openSettings == true && context.mounted) {
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const AiApiSettingsScreen()));
      }
      return false;
    } finally {
      if (checking != null && checking.isActive) {
        navigator.removeRoute(checking);
      }
      _active.remove(operation);
    }
  }

  static void announceProcessing(BuildContext context, SettingsService settings,
      {OnlineTask task = OnlineTask.vision}) {
    if (settings.isOfflineMode) return;
    final l = AppLocalizations.of(context);
    final message = task == OnlineTask.speech
        ? l.tx('Sending the recording to AI. Please wait for the response.',
            'صدا برای هوش مصنوعی ارسال می‌شود. لطفاً منتظر پاسخ بمانید.')
        : task == OnlineTask.ocr && settings.useScanoraCloudOcr
            ? l.tx(
                'Sending the image to Google Docs OCR. Please wait for the response.',
                'تصویر برای تشخیص متن گوگل ارسال می‌شود. لطفاً منتظر پاسخ بمانید.')
            : l.tx('Sending the image to AI. Please wait for the response.',
                'تصویر برای هوش مصنوعی ارسال می‌شود. لطفاً منتظر پاسخ بمانید.');
    unawaited(ReaderFeedback.speak(context, message, settings));
  }
}
