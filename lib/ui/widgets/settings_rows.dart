import 'dart:async';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';
import '../theme/app_theme.dart';

/// A single, fully merged settings entry.
///
/// Title, current value and description are exposed to the screen reader as **one**
/// node and a single tap / double-tap opens the page or dialog. There is no separate
/// "open" button next to a descriptive text.
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? value;
  final String? description;
  final VoidCallback onTap;
  final bool showChevron;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.value,
    this.description,
    this.showChevron = true,
  });

  String get _subtitleText {
    final parts = <String>[
      if (value != null && value!.trim().isNotEmpty) value!.trim(),
      if (description != null && description!.trim().isNotEmpty)
        description!.trim(),
    ];
    return parts.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitleText;
    return MergeSemantics(
      child: ListTile(
        leading: Icon(icon, color: AppTheme.primaryCyan),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        isThreeLine: subtitle.contains('\n'),
        trailing: showChevron ? const Icon(Icons.chevron_right_rounded) : null,
        onTap: onTap,
      ),
    );
  }
}

/// Merged on/off settings entry (switch included in the same semantic node).
class SettingsSwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? description;
  final bool value;
  final FutureOr<void> Function(bool) onChanged;

  const SettingsSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    Future<void> change(bool next) async {
      await onChanged(next);
      if (context.mounted) {
        AccessibilityService.announce(context,
            '$title: ${next ? l.tx('On', 'روشن') : l.tx('Off', 'خاموش')}');
      }
    }

    return MergeSemantics(
      child: Semantics(
        label: title,
        hint: description,
        value: value ? l.tx('On', 'روشن') : l.tx('Off', 'خاموش'),
        child: SwitchListTile.adaptive(
          secondary: Icon(icon, color: AppTheme.primaryCyan),
          title: ExcludeSemantics(
            child: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          subtitle: (description == null || description!.isEmpty)
              ? null
              : ExcludeSemantics(child: Text(description!)),
          value: value,
          onChanged: change,
        ),
      ),
    );
  }
}

/// Section heading marked as a semantic header for fast heading navigation.
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  const SettingsSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: AppTheme.primaryCyan,
          ),
        ),
      ),
    );
  }
}

/// Dialog that lets the user choose exactly one option from a short list.
/// Each option is a single merged radio row. Returns the chosen value or `null`.
Future<T?> showChoiceDialog<T>(
  BuildContext context, {
  required String title,
  required List<ChoiceOption<T>> options,
  required T current,
  required String cancelLabel,
}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              RadioGroup<T>(
                groupValue: current,
                onChanged: (v) {
                  if (v != null) {
                    final selected =
                        options.firstWhere((option) => option.value == v);
                    AccessibilityService.announce(
                        context, '$title: ${selected.title}');
                    Navigator.of(ctx).pop(v);
                  }
                },
                child: Column(
                  children: [
                    for (final o in options)
                      MergeSemantics(
                        child: RadioListTile<T>(
                          value: o.value,
                          title: Text(o.title),
                          subtitle:
                              o.subtitle == null ? null : Text(o.subtitle!),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(cancelLabel),
          ),
        ],
      );
    },
  );
}

class ChoiceOption<T> {
  final T value;
  final String title;
  final String? subtitle;
  const ChoiceOption(this.value, this.title, [this.subtitle]);
}
