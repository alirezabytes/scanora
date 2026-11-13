import 'dart:async';
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/a11y/accessibility_service.dart';
import '../../theme/app_theme.dart';

/// A labelled slider exposed to screen readers as ONE adjustable node.
///
/// Screen-reader gestures and arrow keys adjust the value. The spoken text
/// is `"<title>, <formatted value>"` - there are no separate +/- buttons or duplicated
/// text nodes.
class AccessibleSliderRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final int value;
  final int min;
  final int max;
  final int step;
  final String Function(int value) format;
  final ValueChanged<int> onChanged;
  final FutureOr<void> Function()? onReset;

  const AccessibleSliderRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    this.step = 1,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(min, max);
    final divisions = ((max - min) / step).round().clamp(1, 1000);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Row(
              children: [
                Icon(icon, color: AppTheme.primaryCyan, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                Flexible(
                  child: Text(
                    format(clamped),
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryCyan,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Semantics(
            label: title,
            child: Slider(
              value: clamped.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: divisions,
              activeColor: AppTheme.primaryCyan,
              semanticFormatterCallback: (v) => format(v.round()),
              onChanged: (v) {
                final snapped =
                    (min + ((v - min) / step).round() * step).clamp(min, max);
                if (snapped != clamped) onChanged(snapped);
              },
            ),
          ),
          if (onReset != null)
            Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                    onPressed: () async {
                      await onReset!();
                      if (!context.mounted) return;
                      AccessibilityService.announce(
                          context,
                          AppLocalizations.of(context).tx(
                              '$title set to default.',
                              '$title به مقدار پیش‌فرض برگشت.'));
                    },
                    child: Text(AppLocalizations.of(context)
                        .tx('Reset $title', 'بازنشانی $title')))),
        ],
      ),
    );
  }
}
