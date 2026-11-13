import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../l10n/app_localizations.dart';

class _EscapeBackIntent extends Intent {
  const _EscapeBackIntent();
}

/// Standard scaffold for every settings sub-page: back button, Escape key support,
/// heading semantics and a scrolling list of merged rows.
class SettingsPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsPage({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _EscapeBackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _EscapeBackIntent: CallbackAction<_EscapeBackIntent>(
            onInvoke: (_) {
              Navigator.of(context).maybePop();
              return null;
            },
          ),
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: l10n.translate('back'),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Semantics(
                header: true,
                child: Text(
                  title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
