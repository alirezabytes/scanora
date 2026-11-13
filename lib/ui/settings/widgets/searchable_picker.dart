import '../../../services/a11y/accessibility_service.dart';
import 'package:flutter/material.dart';

class PickerItem {
  final String value;
  final String title;
  final String? group;
  const PickerItem(this.value, this.title, [this.group]);
}

/// Searchable single-choice picker used for long lists (131 eSpeak-NG languages,
/// 90+ voice variants). Each row is one merged node; the search box has the focus
/// when the dialog opens.
Future<String?> showSearchablePicker(
  BuildContext context, {
  required String title,
  required List<PickerItem> items,
  required String current,
  required String cancelLabel,
  required String searchLabel,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _SearchablePickerDialog(
      title: title,
      items: items,
      current: current,
      cancelLabel: cancelLabel,
      searchLabel: searchLabel,
    ),
  );
}

class _SearchablePickerDialog extends StatefulWidget {
  final String title;
  final List<PickerItem> items;
  final String current;
  final String cancelLabel;
  final String searchLabel;

  const _SearchablePickerDialog({
    required this.title,
    required this.items,
    required this.current,
    required this.cancelLabel,
    required this.searchLabel,
  });

  @override
  State<_SearchablePickerDialog> createState() =>
      _SearchablePickerDialogState();
}

class _SearchablePickerDialogState extends State<_SearchablePickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.items
        : widget.items
            .where((i) =>
                i.title.toLowerCase().contains(q) ||
                i.value.toLowerCase().contains(q) ||
                (i.group ?? '').toLowerCase().contains(q))
            .toList();

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        height: 460,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                labelText: widget.searchLabel,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final item = filtered[index];
                  final selected = item.value == widget.current;
                  return MergeSemantics(
                    child: ListTile(
                      selected: selected,
                      title: Text(item.title),
                      subtitle: item.group == null ? null : Text(item.group!),
                      trailing:
                          selected ? const Icon(Icons.check_rounded) : null,
                      onTap: () {
                        AccessibilityService.announce(
                            context, '${widget.title}: ${item.title}');
                        Navigator.of(context).pop(item.value);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
      ],
    );
  }
}
