import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import 'accessible_page_number_field.dart';
import '../../services/a11y/accessibility_service.dart';

class PageRangeSelection {
  final int start, end;
  final bool forceOcr;
  final bool processAll;
  const PageRangeSelection(this.start, this.end, this.forceOcr,
      {this.processAll = true});
}

class DocumentPageRangeDialog extends StatefulWidget {
  final int totalPages;
  final bool allowForceOcr;
  final bool allowLazyOpen;
  const DocumentPageRangeDialog(
      {super.key,
      required this.totalPages,
      this.allowForceOcr = false,
      this.allowLazyOpen = false});
  @override
  State<DocumentPageRangeDialog> createState() =>
      _DocumentPageRangeDialogState();
}

class _DocumentPageRangeDialogState extends State<DocumentPageRangeDialog> {
  final _form = GlobalKey<FormState>();
  final _start = TextEditingController(text: '1');
  late final TextEditingController _end;
  bool _force = false;
  @override
  void initState() {
    super.initState();
    _end = TextEditingController(text: '${widget.totalPages}');
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _submit({bool processAll = true}) {
    if (_form.currentState!.validate()) {
      Navigator.pop(
          context,
          PageRangeSelection(
              int.parse(_start.text), int.parse(_end.text), _force,
              processAll: processAll));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    String? validate(String? value) {
      final number = int.tryParse(value ?? '');
      if (number == null || number < 1 || number > widget.totalPages) {
        return l.tx('Enter 1 to ${widget.totalPages}.',
            'عددی از ۱ تا ${widget.totalPages} وارد کنید.');
      }
      if ((int.tryParse(_start.text) ?? 0) >
          (int.tryParse(_end.text) ?? widget.totalPages)) {
        return l.tx('Start page must not exceed end page.',
            'صفحهٔ شروع نباید از صفحهٔ پایان بزرگ‌تر باشد.');
      }
      return null;
    }

    return AlertDialog(
        title: Text(l.tx('Choose pages (${widget.totalPages} total)',
            'انتخاب صفحات (مجموع: ${widget.totalPages})')),
        content: SingleChildScrollView(
            child: Form(
                key: _form,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(l.tx('Choose the pages to read or export.',
                          'محدودهٔ صفحه‌هایی را که می‌خواهید بخوانید یا ذخیره کنید انتخاب کنید.')),
                      const SizedBox(height: 16),
                      AccessiblePageNumberField(
                          key: const ValueKey('start-page'),
                          controller: _start,
                          label: l.tx('Start Page', 'صفحهٔ شروع'),
                          validator: validate),
                      const SizedBox(height: 16),
                      AccessiblePageNumberField(
                          key: const ValueKey('end-page'),
                          controller: _end,
                          label: l.tx('End Page', 'صفحهٔ پایان'),
                          validator: validate),
                      if (widget.allowForceOcr)
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l.tx('Read every selected page again',
                                'خواندن دوبارهٔ تمام صفحات انتخاب‌شده')),
                            subtitle: Text(l.tx(
                                'Choose this if the page text is incomplete. Reading takes longer.',
                                'اگر متن صفحه ناقص است، این گزینه را روشن کنید. خواندن زمان بیشتری می‌برد.')),
                            value: _force,
                            onChanged: (v) {
                              setState(() => _force = v ?? false);
                              AccessibilityService.announce(
                                  context,
                                  l.tx(
                                      _force
                                          ? 'Read every selected page again: selected'
                                          : 'Read every selected page again: not selected',
                                      _force
                                          ? 'خواندن دوبارهٔ همهٔ صفحات: علامت‌دار'
                                          : 'خواندن دوبارهٔ همهٔ صفحات: بدون علامت'));
                            }),
                    ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.translate('cancel'))),
          if (widget.allowLazyOpen)
            TextButton(
              onPressed: () => _submit(processAll: false),
              child: Text(l.tx('Open in Reader', 'باز کردن در کتاب‌خوان')),
            ),
          FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.play_arrow),
              label: Text(l.tx('Start Processing', 'شروع پردازش')))
        ]);
  }
}
