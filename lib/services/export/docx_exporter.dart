import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'text_direction.dart';

class DocxExporter {
  /// Generates a genuine, valid OpenXML Microsoft Word document (.docx)
  /// Supporting both LTR and RTL languages (Persian, Arabic, English, etc.)
  static Uint8List createDocx({
    required String title,
    required List<String> paragraphs,
    bool isRtl = false,
  }) {
    final archive = Archive();

    const contentTypes =
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';

    const rootRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

    final StringBuffer bodyBuffer = StringBuffer();

    // Document Title Heading
    final titleRtl = textIsRtl(title, fallback: isRtl);
    final safeTitle = _escapeXml(title);
    bodyBuffer.write('''
    <w:p>
      <w:pPr>
        <w:jc w:val="${titleRtl ? 'right' : 'left'}"/>
        ${titleRtl ? '<w:bidi/>' : ''}
      </w:pPr>
      <w:r>
        <w:rPr>
          <w:b/>
          <w:sz w:val="36"/>
          ${titleRtl ? '<w:rtl/>' : ''}
        </w:rPr>
        <w:t>$safeTitle</w:t>
      </w:r>
    </w:p>
''');

    // Paragraphs
    for (final p in paragraphs) {
      final lines = p.split('\n');
      for (final line in lines) {
        final lineRtl = textIsRtl(line, fallback: isRtl);
        final safeLine = _escapeXml(line.trim());
        if (safeLine.isEmpty) {
          bodyBuffer.write(
              '<w:p><w:pPr><w:jc w:val="${lineRtl ? 'right' : 'left'}"/>${lineRtl ? '<w:bidi/>' : ''}</w:pPr></w:p>\n');
        } else {
          bodyBuffer.write('''
    <w:p>
      <w:pPr>
        <w:jc w:val="${lineRtl ? 'right' : 'left'}"/>
        ${lineRtl ? '<w:bidi/>' : ''}
      </w:pPr>
      <w:r>
        <w:rPr>
          <w:sz w:val="24"/>
          ${lineRtl ? '<w:rtl/>' : ''}
        </w:rPr>
        <w:t xml:space="preserve">$safeLine</w:t>
      </w:r>
    </w:p>
''');
        }
      }
    }

    final documentXml =
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
$bodyBuffer
    <w:sectPr/>
  </w:body>
</w:document>''';

    final ctBytes = utf8.encode(contentTypes);
    final relsBytes = utf8.encode(rootRels);
    final docBytes = utf8.encode(documentXml);

    archive
        .addFile(ArchiveFile('[Content_Types].xml', ctBytes.length, ctBytes));
    archive.addFile(ArchiveFile('_rels/.rels', relsBytes.length, relsBytes));
    archive
        .addFile(ArchiveFile('word/document.xml', docBytes.length, docBytes));

    final zipBytes = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipBytes);
  }

  /// Compatibility entry point. The returned document is genuine RTF; callers
  /// must use the .rtf extension.
  static Uint8List createDoc({
    required String title,
    required List<String> paragraphs,
    bool isRtl = false,
  }) =>
      createRtf(title: title, paragraphs: paragraphs, isRtl: isRtl);

  static Uint8List createRtf(
      {required String title,
      required List<String> paragraphs,
      bool isRtl = false}) {
    String escape(String value) {
      final out = StringBuffer();
      for (final code in value.codeUnits) {
        if (code == 92 || code == 123 || code == 125) {
          out.write('\\${String.fromCharCode(code)}');
        } else if (code == 10) {
          out.write('\\line ');
        } else if (code == 13) {
          continue;
        } else if (code == 9) {
          out.write('\\tab ');
        } else if (code > 127) {
          out.write('\\u${code > 32767 ? code - 65536 : code}?');
        } else {
          out.writeCharCode(code);
        }
      }
      return out.toString();
    }

    final body = StringBuffer(
        '{\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0{\\fonttbl{\\f0 Tahoma;}}\n');
    body.writeln(
        '\\${isRtl ? 'rtlpar' : 'ltrpar'}\\f0\\fs36\\b ${escape(title)}\\b0\\par\\fs24');
    for (final paragraph in paragraphs) {
      final rtl = textIsRtl(paragraph, fallback: isRtl);
      body.writeln('\\${rtl ? 'rtlpar' : 'ltrpar'} ${escape(paragraph)}\\par');
    }
    body.write('}');
    return Uint8List.fromList(ascii.encode(body.toString()));
  }

  /// HTML export retained separately for callers that explicitly request HTML.
  static Uint8List createHtml(
      {required String title,
      required List<String> paragraphs,
      bool isRtl = false}) {
    final sb = StringBuffer();
    sb.writeln(
        "<html xmlns:o='urn:schemas-microsoft-com:office:office' xmlns:w='urn:schemas-microsoft-com:office:word' xmlns='http://www.w3.org/TR/REC-html40'>");
    sb.writeln(
        "<head><meta charset='utf-8'><title>${_escapeXml(title)}</title>");
    sb.writeln(
        "<!--[if gte mso 9]><xml><w:WordDocument><w:View>Print</w:View><w:Zoom>100</w:Zoom></w:WordDocument></xml><![endif]-->");
    sb.writeln("<style>");
    sb.writeln(
        "body { font-family: 'Calibri', 'Vazirmatn', 'Tahoma', sans-serif; font-size: 13pt; direction: ${isRtl ? 'rtl' : 'ltr'}; text-align: ${isRtl ? 'right' : 'left'}; }");
    sb.writeln(
        "h1 { font-size: 19pt; color: #2B579A; margin-bottom: 12pt; border-bottom: 2px solid #2B579A; padding-bottom: 4pt; }");
    sb.writeln("p { margin: 6pt 0; line-height: 1.6; }");
    sb.writeln("</style></head><body>");
    sb.writeln("<h1>${_escapeXml(title)}</h1>");

    for (final p in paragraphs) {
      final lines = p.split('\n');
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          sb.writeln("<p>&nbsp;</p>");
        } else {
          sb.writeln("<p>${_escapeXml(trimmed)}</p>");
        }
      }
    }

    sb.writeln("</body></html>");
    return Uint8List.fromList(utf8.encode(sb.toString()));
  }

  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
