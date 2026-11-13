import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/captcha/math_evaluator.dart';
import '../../services/a11y/accessibility_service.dart';

class AccessiblePageNumberField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  const AccessiblePageNumberField(
      {super.key,
      required this.controller,
      required this.label,
      this.validator});

  @override
  Widget build(BuildContext context) => MergeSemantics(
          child: Semantics(
        label: label,
        // Android may treat the field name as a hint and speak just the value
        // on a swipe. Supplement that event without competing with Tab focus.
        onDidGainAccessibilityFocus: defaultTargetPlatform ==
                TargetPlatform.android
            ? () => AccessibilityService.announce(context,
                controller.text.isEmpty ? label : '$label, ${controller.text}')
            : null,
        child: TextFormField(
          controller: controller,
          validator: validator,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          inputFormatters: [
            TextInputFormatter.withFunction((oldValue, newValue) {
              final text = MathEvaluator.normalizeDigits(newValue.text)
                  .replaceAll(RegExp(r'[^0-9]'), '');
              return TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: text.length));
            })
          ],
          decoration: InputDecoration(
              label: ExcludeSemantics(child: Text(label)),
              floatingLabelBehavior: FloatingLabelBehavior.always,
              border: const OutlineInputBorder()),
        ),
      ));
}
