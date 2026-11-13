import 'package:flutter/material.dart';
import '../../services/a11y/accessibility_service.dart';

/// Keep the field's name on the same accessibility node as its current choice
/// and expanded state, including when its visible floating label is separate.
class AccessibleDropdownField<T> extends StatelessWidget {
  final T? initialValue;
  final InputDecoration decoration;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final bool isExpanded;
  final Widget? hint;
  const AccessibleDropdownField(
      {super.key,
      this.initialValue,
      this.decoration = const InputDecoration(),
      this.items,
      this.onChanged,
      this.isExpanded = false,
      this.hint});
  @override
  Widget build(BuildContext context) {
    final label = decoration.labelText ?? '';
    return MergeSemantics(
        child: Semantics(
            label: label,
            child: DropdownButtonFormField<T>(
              initialValue: initialValue,
              items: items,
              onChanged: onChanged == null
                  ? null
                  : (value) {
                      onChanged!(value);
                      if (!context.mounted) return;
                      for (final item in items ?? <DropdownMenuItem<T>>[]) {
                        if (item.value == value && item.child is Text) {
                          final text = (item.child as Text).data;
                          if (text != null) {
                            AccessibilityService.announce(
                                context, '$label: $text');
                          }
                          break;
                        }
                      }
                    },
              isExpanded: isExpanded,
              hint: hint,
              decoration: InputDecoration(
                  label: label.isEmpty
                      ? decoration.label
                      : ExcludeSemantics(child: Text(label)),
                  border: decoration.border,
                  prefixIcon: decoration.prefixIcon,
                  suffixIcon: decoration.suffixIcon,
                  helperText: decoration.helperText,
                  contentPadding: decoration.contentPadding,
                  floatingLabelBehavior: FloatingLabelBehavior.always),
            )));
  }
}
