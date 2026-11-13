import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

class OutputFileNameField extends StatelessWidget {
  const OutputFileNameField({
    super.key,
    required this.initialName,
    required this.onChanged,
    this.extension,
  });

  final String initialName;
  final String? extension;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextFormField(
      initialValue: initialName,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: l10n.tx('Output file name', 'نام فایل خروجی'),
        suffixText: extension == null ? null : '.$extension',
        border: const OutlineInputBorder(),
      ),
    );
  }
}
