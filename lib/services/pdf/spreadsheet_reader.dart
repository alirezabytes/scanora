import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import '../../models/pdf_document.dart';

class SpreadsheetReader {
  static ProcessedPdfDocument read(Uint8List bytes, String name) {
    final archive = ZipDecoder().decodeBytes(bytes);
    XmlDocument? xml(String path) {
      final file = archive.findFile(path);
      return file == null ? null : XmlDocument.parse(utf8.decode(file.content));
    }

    final workbook = xml('xl/workbook.xml');
    if (workbook == null) {
      throw const FormatException('No XLSX workbook found.');
    }
    final rels = xml('xl/_rels/workbook.xml.rels');
    final targets = <String, String>{
      for (final r in rels?.findAllElements('Relationship') ?? <XmlElement>[])
        r.getAttribute('Id') ?? '': r.getAttribute('Target') ?? ''
    };
    final shared = [
      for (final si in xml('xl/sharedStrings.xml')?.findAllElements('si') ??
          <XmlElement>[])
        si.findAllElements('t').map((t) => t.innerText).join()
    ];
    final styles = xml('xl/styles.xml');
    final customFormats = <int, String>{
      for (final f in styles?.findAllElements('numFmt') ?? <XmlElement>[])
        int.tryParse(f.getAttribute('numFmtId') ?? '') ?? -1:
            f.getAttribute('formatCode') ?? ''
    };
    final cellStyles = styles
            ?.findAllElements('cellXfs')
            .firstOrNull
            ?.findElements('xf')
            .toList() ??
        <XmlElement>[];
    final date1904 = workbook
        .findAllElements('workbookPr')
        .firstOrNull
        ?.getAttribute('date1904');
    final pages = <PdfPageInfo>[];
    for (final sheet in workbook.findAllElements('sheet')) {
      final id = sheet.attributes
          .where((a) => a.name.local == 'id')
          .firstOrNull
          ?.value;
      final target = targets[id];
      if (target == null) continue;
      final path = target.startsWith('/')
          ? target.substring(1)
          : Uri.parse('xl/').resolve(target).path;
      final data = xml(path);
      if (data == null) continue;
      final rows = <String>[];
      for (final row in data.findAllElements('row')) {
        final values = <String>[];
        for (final cell in row.findElements('c')) {
          final type = cell.getAttribute('t');
          final raw = cell.getElement('v')?.innerText ?? '';
          var value = raw;
          if (type == 's') {
            final index = int.tryParse(raw);
            value = index != null && index >= 0 && index < shared.length
                ? shared[index]
                : '';
          } else if (type == 'inlineStr') {
            value = cell.findAllElements('t').map((t) => t.innerText).join();
          } else if (type == 'b') {
            value = raw == '1' ? 'true' : 'false';
          } else if (value.isNotEmpty) {
            final style = int.tryParse(cell.getAttribute('s') ?? '');
            final numberFormat = style != null &&
                    style >= 0 &&
                    style < cellStyles.length
                ? int.tryParse(cellStyles[style].getAttribute('numFmtId') ?? '')
                : null;
            final format = customFormats[numberFormat] ?? '';
            if (numberFormat != null &&
                (_dateFormatIds.contains(numberFormat) ||
                    RegExp(r'[dy]', caseSensitive: false).hasMatch(
                        format.replaceAll(RegExp(r'"[^"]*"|\\.'), '')))) {
              final serial = double.tryParse(raw);
              if (serial != null && serial >= 0 && serial < 2958466) {
                final epoch = date1904 == '1' || date1904 == 'true'
                    ? DateTime.utc(1904, 1, 1)
                    : (serial < 60
                        ? DateTime.utc(1899, 12, 31)
                        : DateTime.utc(1899, 12, 30));
                final date = epoch.add(Duration(
                    milliseconds:
                        (serial * Duration.millisecondsPerDay).round()));
                value = date
                    .toIso8601String()
                    .substring(0, serial % 1 == 0 ? 10 : 19)
                    .replaceAll('T', ' ');
              }
            }
          }
          if (value.isEmpty && cell.getElement('f') != null) {
            value = '=${cell.getElement('f')!.innerText}';
          }
          if (value.trim().isNotEmpty) {
            values.add('${cell.getAttribute('r') ?? ''}: ${value.trim()}');
          }
        }
        if (values.isNotEmpty) rows.add(values.join(' | '));
      }
      pages.add(PdfPageInfo(
          pageNumber: pages.length + 1,
          text: rows.isEmpty
              ? ''
              : '${sheet.getAttribute('name') ?? ''}\n\n${rows.join('\n')}'));
    }
    if (pages.isEmpty) {
      throw const FormatException('No readable worksheets found.');
    }
    return ProcessedPdfDocument(
        fileName: name,
        totalPages: pages.length,
        pages: pages,
        isOffline: true);
  }

  static const _dateFormatIds = {
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    27,
    28,
    29,
    30,
    31,
    32,
    33,
    34,
    35,
    36,
    45,
    46,
    47,
    50,
    51,
    52,
    53,
    54,
    55,
    56,
    57,
    58
  };
}
