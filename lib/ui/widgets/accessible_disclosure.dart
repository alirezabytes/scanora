import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';

class AccessibleDisclosure extends StatefulWidget {
  final String title;
  final Widget child;
  const AccessibleDisclosure(
      {super.key, required this.title, required this.child});
  @override
  State<AccessibleDisclosure> createState() => _AccessibleDisclosureState();
}

class _AccessibleDisclosureState extends State<AccessibleDisclosure> {
  bool _expanded = false;
  void _toggle() {
    setState(() => _expanded = !_expanded);
    // Android receives the expanded state on the question's existing node.
    // A separate announcement can interrupt its normal swipe navigation.
    if (defaultTargetPlatform == TargetPlatform.android) return;
    final l = AppLocalizations.of(context);
    AccessibilityService.announce(context,
        '${widget.title}: ${_expanded ? l.tx('Expanded', 'باز شد') : l.tx('Collapsed', 'بسته شد')}');
  }

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        explicitChildNodes: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MergeSemantics(
              child: Semantics(
                sortKey: const OrdinalSortKey(0),
                button: true,
                expanded: _expanded,
                child: ListTile(
                  title: Text(widget.title),
                  onTap: _toggle,
                  trailing:
                      Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ),
              ),
            ),
            if (_expanded)
              Semantics(
                container: true,
                sortKey: const OrdinalSortKey(1),
                child: Padding(
                    padding: const EdgeInsets.all(16), child: widget.child),
              ),
          ],
        ),
      );
}
