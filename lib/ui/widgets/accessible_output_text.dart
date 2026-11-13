import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/a11y/reader_feedback.dart';
import '../../services/settings_service.dart';
import 'accessible_dropdown_field.dart';

enum _ReadingUnit { text, character, word, line, sentence, paragraph }

/// Keep results in a single read-only field so screen readers retain their
/// normal text navigation. The reading controls provide the same steps on
/// touch screens and with a keyboard.
class AccessibleOutputText extends StatefulWidget {
  final String text;
  final String? label;
  final TextStyle? style;
  final bool liveRegion;
  final FocusNode? focusNode;
  final bool showLabel;
  final int? maxLines;
  final ValueChanged<TextSelection>? onSkipSelection;

  const AccessibleOutputText({
    super.key,
    required this.text,
    this.label,
    this.style,
    this.liveRegion = true,
    this.focusNode,
    this.showLabel = true,
    this.maxLines = 12,
    this.onSkipSelection,
  });

  @override
  State<AccessibleOutputText> createState() => _AccessibleOutputTextState();
}

class _AccessibleOutputTextState extends State<AccessibleOutputText> {
  late final TextEditingController _controller;
  _ReadingUnit _unit = _ReadingUnit.text;
  final _visited = <TextRange>[];
  Iterator<TextRange>? _remaining;
  TextRange? _next;
  int _position = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.text);
  }

  @override
  void didUpdateWidget(covariant AccessibleOutputText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    _controller.value = TextEditingValue(
      text: widget.text,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _resetUnits();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _resetUnits() {
    _visited.clear();
    _position = -1;
    _remaining = _unit == _ReadingUnit.text
        ? null
        : _readingRanges(widget.text, _unit).iterator;
    _readAhead();
  }

  void _readAhead() {
    final iterator = _remaining;
    _next = iterator != null && iterator.moveNext() ? iterator.current : null;
  }

  void _chooseUnit(_ReadingUnit? unit) {
    if (unit == null || unit == _unit) return;
    setState(() {
      _unit = unit;
      _resetUnits();
    });
    if (_next != null) _move(1);
  }

  void _move(int direction) {
    final target = _position + direction;
    if (target < 0) return;
    if (target == _visited.length) {
      final next = _next;
      if (next == null) return;
      _visited.add(next);
      _readAhead();
    }
    final range = _visited[target];
    setState(() => _position = target);
    _controller.selection =
        TextSelection(baseOffset: range.start, extentOffset: range.end);
    final l = AppLocalizations.of(context);
    final text = range.textInside(widget.text);
    final message = switch (text) {
      ' ' => l.tx('Space', 'فاصله'),
      '\t' => l.tx('Tab', 'تب'),
      '\n' || '\r' || '\r\n' => l.tx('New line', 'خط جدید'),
      _ => text,
    };
    final settings = context.read<SettingsService?>();
    if (settings != null) {
      ReaderFeedback.speak(context, message, settings, assertive: true);
    } else {
      AccessibilityService.announce(context, message, assertive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final direction = AccessibilityService.directionOf(widget.text);
    final label = widget.label ?? l.tx('Output text', 'متن خروجی');
    final longText = widget.text.length > 6000;
    final unitLabels = {
      _ReadingUnit.text: l.tx('Full text', 'متن کامل'),
      _ReadingUnit.character: l.tx('Character', 'حرف'),
      _ReadingUnit.word: l.tx('Word', 'کلمه'),
      _ReadingUnit.line: l.tx('Line', 'خط'),
      _ReadingUnit.sentence: l.tx('Sentence', 'جمله'),
      _ReadingUnit.paragraph: l.tx('Paragraph', 'پاراگراف'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: widget.showLabel ? null : label,
          liveRegion: widget.liveRegion && !longText,
          child: TextField(
            controller: _controller,
            focusNode: widget.focusNode,
            readOnly: true,
            maxLines: widget.maxLines,
            minLines: 1,
            textDirection: direction,
            style: widget.style ?? const TextStyle(fontSize: 16, height: 1.65),
            decoration: InputDecoration(
              labelText: widget.showLabel ? label : null,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
        ),
        if (widget.text.isNotEmpty) ...[
          if (widget.onSkipSelection != null)
            TextButton(
              onPressed: () {
                final selection = _controller.selection;
                if (!selection.isValid || selection.isCollapsed) {
                  AccessibilityService.announce(
                      context,
                      l.tx('Select some text first.',
                          'ابتدا بخشی از متن را انتخاب کنید.'));
                  return;
                }
                widget.onSkipSelection!(selection);
              },
              child: Text(l.tx('Skip selected text in audio',
                  'نخواندن متن انتخاب‌شده در پخش صوتی')),
            ),
          const SizedBox(height: 8),
          AccessibleDropdownField<_ReadingUnit>(
            initialValue: _unit,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l.tx('Read by', 'واحد خواندن'),
              isDense: true,
            ),
            items: [
              for (final entry in unitLabels.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: _chooseUnit,
          ),
          if (_unit != _ReadingUnit.text)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _position > 0 ? () => _move(-1) : null,
                  child: Text(l.tx('Previous', 'قبلی')),
                ),
                TextButton(
                  onPressed: _next != null || _position + 1 < _visited.length
                      ? () => _move(1)
                      : null,
                  child: Text(l.tx('Next', 'بعدی')),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

Iterable<TextRange> _readingRanges(String text, _ReadingUnit unit) sync* {
  if (unit == _ReadingUnit.character) {
    final boundary = CharacterBoundary(text);
    for (var offset = 0; offset < text.length;) {
      final range = boundary.getTextBoundaryAt(offset);
      yield range;
      offset = range.end;
    }
    return;
  }
  if (unit == _ReadingUnit.word) {
    for (final word in RegExp(r'\S+').allMatches(text)) {
      yield TextRange(start: word.start, end: word.end);
    }
    return;
  }
  final separator = switch (unit) {
    _ReadingUnit.line => RegExp(r'\r\n|[\r\n]'),
    _ReadingUnit.sentence => RegExp(r'(?<=[.!?؟。…])\s+'),
    _ReadingUnit.paragraph => RegExp(r'(?:\r?\n)[\t ]*(?:\r?\n)+'),
    _ => null,
  };
  var start = 0;
  for (final match in separator?.allMatches(text) ?? const <RegExpMatch>[]) {
    if (match.start > start &&
        text.substring(start, match.start).trim().isNotEmpty) {
      yield TextRange(start: start, end: match.start);
    }
    start = match.end;
  }
  if (start < text.length && text.substring(start).trim().isNotEmpty) {
    yield TextRange(start: start, end: text.length);
  }
}
