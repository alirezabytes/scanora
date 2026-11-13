import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import '../ocr/camera_diagnostics.dart';

/// Thin, null-safe wrapper around [SemanticsService] used by every screen so that
/// the active screen reader receives consistent spoken feedback.
class AccessibilityService {
  AccessibilityService._();

  /// Speaks [message] through the active screen reader.
  ///
  /// Safe to call at any time: if no [View] is attached yet (for example while the
  /// first frame is still being built) the call is silently ignored.
  static void announce(
    BuildContext context,
    String message, {
    bool assertive = false,
    TextDirection? textDirection,
    String? diagnosticSource,
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    final direction =
        textDirection ?? Directionality.maybeOf(context) ?? TextDirection.ltr;
    if (CameraDiagnostics.enabled) {
      CameraDiagnostics.event('screen-reader.dispatch', {
        'source': diagnosticSource,
        'text': trimmed,
        'assertive': assertive,
      });
    }
    SemanticsService.sendAnnouncement(
      view,
      trimmed,
      direction,
      assertiveness: assertive ? Assertiveness.assertive : Assertiveness.polite,
    );
  }

  /// Announces [message] and shows a short floating [SnackBar] for sighted /
  /// low-vision users.
  static void announceAndNotify(BuildContext context, String message) {
    announce(context, message);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// Determines the natural text direction of [text] from its first strongly
  /// directional character, so mixed Persian/English output is laid out correctly.
  static TextDirection directionOf(String text) {
    for (final rune in text.runes) {
      final isRtl = (rune >= 0x0590 && rune <= 0x08FF) ||
          (rune >= 0xFB1D && rune <= 0xFDFF) ||
          (rune >= 0xFE70 && rune <= 0xFEFF);
      if (isRtl) return TextDirection.rtl;
      final isLatin =
          (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);
      if (isLatin) return TextDirection.ltr;
    }
    return TextDirection.ltr;
  }
}
