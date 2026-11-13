import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class CopyActionButton extends StatelessWidget {
  final String textToCopy;
  final String? label;
  final bool isPrimary;
  final VoidCallback? onCopied;

  const CopyActionButton({
    super.key,
    required this.textToCopy,
    this.label,
    this.isPrimary = true,
    this.onCopied,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final buttonLabel = label ?? l10n.translate('copy_result');

    if (isPrimary) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.copy_rounded, size: 20),
        label: Text(buttonLabel),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.successGreen,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: textToCopy.isEmpty ? null : () => _copy(context, l10n),
      );
    } else {
      return OutlinedButton.icon(
        icon: const Icon(Icons.copy_rounded, size: 18),
        label: Text(buttonLabel),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.primaryCyan,
          side: const BorderSide(color: AppTheme.primaryCyan),
        ),
        onPressed: textToCopy.isEmpty ? null : () => _copy(context, l10n),
      );
    }
  }

  void _copy(BuildContext context, AppLocalizations l10n) {
    Clipboard.setData(ClipboardData(text: textToCopy));
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(l10n.translate('result_copied')),
          ],
        ),
        backgroundColor: AppTheme.successGreen,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
    onCopied?.call();
  }
}
