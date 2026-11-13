import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show CharacterBoundary;
import 'package:http/http.dart' as http;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../../models/ai_provider.dart';
import '../../models/pdf_document.dart';
import '../ocr/reading_layout.dart';
import 'document_text_decoder.dart';
import 'document_batch_processor.dart';
import 'spreadsheet_reader.dart';
import 'document_image_loader.dart';

class PdfService {
  /// Extracts text from a PDF file page-by-page inside a background Isolate
  /// so large PDF files never freeze the UI or cause Android "Not Responding" (ANR).
  /// Pages that are scanned images (or lack embedded text) are flagged with `needsOcr: true`
  /// so the viewer automatically renders and OCRs them in Online or Offline mode.
  static Future<ProcessedPdfDocument> extractPdfPages({
    required Uint8List pdfBytes,
    required String fileName,
    required bool isOfflineMode,
    AIProviderType? activeProvider,
    String? apiKey,
    String? modelName,
    String? customBaseUrl,
    void Function(int percent)? onProgress,
    Future<void>? cancelled,
    String? layoutHeading,
  }) =>
      _extractPdfSource(pdfBytes, null, fileName, isOfflineMode, onProgress,
          cancelled, layoutHeading);

  static Future<ProcessedPdfDocument> extractPdfFile({
    required String path,
    required String fileName,
    required bool isOfflineMode,
    void Function(int percent)? onProgress,
    Future<void>? cancelled,
    String? layoutHeading,
  }) =>
      _extractPdfSource(null, path, fileName, isOfflineMode, onProgress,
          cancelled, layoutHeading);

  static Future<ProcessedPdfDocument> _extractPdfSource(
    Uint8List? pdfBytes,
    String? path,
    String fileName,
    bool isOfflineMode,
    void Function(int percent)? onProgress,
    Future<void>? cancelled,
    String? layoutHeading,
  ) async {
    final progress = ReceivePort();
    final subscription =
        progress.listen((value) => onProgress?.call(value as int));
    try {
      return await _startPdfExtraction((
        pdfBytes,
        path,
        fileName,
        isOfflineMode,
        progress.sendPort,
        layoutHeading
      ), cancelled);
    } finally {
      await subscription.cancel();
      progress.close();
    }
  }

  static Future<ProcessedPdfDocument> _startPdfExtraction(
    (Uint8List?, String?, String, bool, SendPort, String?) job,
    Future<void>? cancelled,
  ) async {
    if (cancelled == null) return Isolate.run(() => _extractPdf(job));
    final result = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn(_runPdfExtraction, (job, result.sendPort),
          onError: result.sendPort, onExit: result.sendPort);
      final message = await Future.any<Object?>([
        result.first,
        cancelled.then<Object?>((_) => const DocumentProcessingCancelled()),
      ]);
      if (message is ProcessedPdfDocument) return message;
      if (message is DocumentProcessingCancelled) throw message;
      if (message is List && message.length == 2) {
        throw RemoteError(message[0].toString(), message[1].toString());
      }
      throw StateError('PDF extraction stopped without a result.');
    } finally {
      worker?.kill(priority: Isolate.immediate);
      result.close();
    }
  }

  static void _runPdfExtraction(
      (
        (Uint8List?, String?, String, bool, SendPort, String?),
        SendPort
      ) request) {
    final (job, result) = request;
    Isolate.exit(result, _extractPdf(job));
  }

  static ProcessedPdfDocument _extractPdf(
      (Uint8List?, String?, String, bool, SendPort, String?) job) {
    final (pdfBytes, path, fileName, isOfflineMode, progress, layoutHeading) =
        job;
    final PdfDocument document =
        PdfDocument(inputBytes: pdfBytes ?? File(path!).readAsBytesSync());
    try {
      final int pageCount = document.pages.count;
      if (pageCount == 0) throw const FormatException('The PDF has no pages.');
      final List<PdfPageInfo> pageList = [];

      final PdfTextExtractor extractor = PdfTextExtractor(document);
      var lastPercent = -1;

      for (int i = 0; i < pageCount; i++) {
        String rawText = '';
        try {
          if (layoutHeading != null) {
            final lines =
                extractor.extractTextLines(startPageIndex: i, endPageIndex: i);
            rawText = ReadingLayout.format(
              [for (final line in lines) ..._pdfLayoutLines(line)],
              heading: layoutHeading,
            );
          }
          if (rawText.trim().isEmpty) {
            rawText = extractor.extractText(startPageIndex: i, endPageIndex: i);
          }
        } catch (_) {
          rawText = '';
        }

        final String cleaned = _cleanAndFormatPageText(rawText);
        final bool isScannedOrImagePage = !hasUsableEmbeddedText(cleaned);

        pageList.add(PdfPageInfo(
          pageNumber: i + 1,
          text: isScannedOrImagePage ? '' : cleaned,
          needsOcr: isScannedOrImagePage,
          ocrCompleted: false,
        ));
        final percent = ((i + 1) * 100 / pageCount).round();
        if (percent != lastPercent) {
          progress.send(percent);
          lastPercent = percent;
        }
      }

      return ProcessedPdfDocument(
        fileName: fileName,
        totalPages: pageCount,
        pages: pageList,
        isOffline: isOfflineMode,
      );
    } finally {
      document.dispose();
    }
  }

  static Iterable<ReadingLayoutLine> _pdfLayoutLines(TextLine line) sync* {
    if (line.text.trim().isEmpty) return;
    final words = line.wordCollection;
    final size = line.fontSize > 0 ? line.fontSize : line.bounds.height;
    final splits = <int>[0];
    for (var index = 1; index < words.length; index++) {
      final a = words[index - 1].bounds;
      final b = words[index].bounds;
      final gap = math.max(a.left - b.right, b.left - a.right);
      if (gap > math.max(14, size * 2.8)) splits.add(index);
    }
    if (splits.length == 1) {
      yield (bounds: line.bounds, text: line.text, size: size);
      return;
    }
    splits.add(words.length);
    for (var index = 1; index < splits.length; index++) {
      final group = words.sublist(splits[index - 1], splits[index]);
      yield (
        bounds: group
            .map((word) => word.bounds)
            .reduce((a, b) => a.expandToInclude(b)),
        text: group.map((word) => word.text).join(' '),
        size: size,
      );
    }
  }

  static bool hasUsableEmbeddedText(String text) {
    final compact = text.replaceAll(RegExp(r'\s'), '');
    if (compact.length < 5) return false;
    final invalid = RegExp(r'[\uFFFD\x00-\x08\x0E-\x1F\uE000-\uF8FF]')
        .allMatches(compact)
        .length;
    final letters = RegExp(
            r'[A-Za-z\u0621-\u063A\u0641-\u064A\u067E\u0686\u0698\u06A9\u06AF\u06CC0-9\u0660-\u0669\u06F0-\u06F9]')
        .allMatches(compact)
        .length;
    return invalid / compact.length < 0.05 && letters / compact.length >= 0.4;
  }

  // ===========================================================================
  // Background Isolate Async Wrappers (prevents UI lag on large documents)
  // ===========================================================================

  static Future<ProcessedPdfDocument> extractWordDocumentAsync({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    return Isolate.run(
        () => extractWordDocument(fileBytes: fileBytes, fileName: fileName));
  }

  static Future<ProcessedPdfDocument> extractPowerPointDocumentAsync({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    return Isolate.run(() =>
        extractPowerPointDocument(fileBytes: fileBytes, fileName: fileName));
  }

  static Future<ProcessedPdfDocument> extractExcelDocumentAsync({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    return Isolate.run(
        () => extractExcelDocument(fileBytes: fileBytes, fileName: fileName));
  }

  static Future<ProcessedPdfDocument> extractAudiobookZipAsync({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    return Isolate.run(
        () => extractAudiobookZip(fileBytes: fileBytes, fileName: fileName));
  }

  static Future<ProcessedPdfDocument> extractEpubDocumentAsync({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    return Isolate.run(
        () => extractEpubDocument(fileBytes: fileBytes, fileName: fileName));
  }

  static Future<ProcessedPdfDocument> extractOpenDocumentAsync({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    return Isolate.run(
        () => extractOpenDocument(fileBytes: fileBytes, fileName: fileName));
  }

  static Future<ProcessedPdfDocument> extractTextDocumentAsync({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    return Isolate.run(
        () => extractTextDocument(fileBytes: fileBytes, fileName: fileName));
  }

  /// Read and paginate in the same worker, without copying file bytes from the UI.
  static Future<ProcessedPdfDocument> extractTextFileAsync({
    required String path,
    required String fileName,
  }) =>
      Isolate.run(() => extractTextDocument(
          fileBytes: File(path).readAsBytesSync(), fileName: fileName));

  /// Normalizes PDF text layout for smooth screen-reader reading
  static String _cleanAndFormatPageText(String raw) {
    if (raw.trim().isEmpty) return '';
    String text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = text
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim())
        .toList();

    final buffer = StringBuffer();
    int consecutiveEmpty = 0;
    for (final line in lines) {
      if (line.isEmpty) {
        consecutiveEmpty++;
        if (consecutiveEmpty <= 1 && buffer.isNotEmpty) {
          buffer.writeln();
        }
      } else {
        consecutiveEmpty = 0;
        buffer.writeln(line);
      }
    }
    return buffer.toString().trim();
  }

  /// Extracts text from Microsoft Word documents (.docx, .doc)
  static ProcessedPdfDocument extractWordDocument({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    final header = String.fromCharCodes(fileBytes.take(40)).trimLeft();
    final String textContent;
    if (header.startsWith(r'{\rtf')) {
      textContent = DocumentTextDecoder.rtf(fileBytes);
    } else if (header.startsWith('<')) {
      textContent =
          _stripHtmlTagsToCleanText(DocumentTextDecoder.decode(fileBytes));
    } else if (fileBytes.length > 2 &&
        fileBytes[0] == 0x50 &&
        fileBytes[1] == 0x4B) {
      textContent = _extractDocxText(fileBytes);
    } else {
      throw UnsupportedError(
          'Legacy binary Word documents require conversion to DOCX, RTF or PDF. Binary metadata is not document text.');
    }

    return _paginateText(textContent, fileName,
        engineName: 'Word Document Reader');
  }

  /// Extracts slides from PowerPoint presentations (.pptx, .ppt), creating one page per slide!
  static ProcessedPdfDocument extractPowerPointDocument({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    try {
      final archive = ZipDecoder().decodeBytes(fileBytes);
      final slideFiles = archive.files
          .where((f) =>
              f.isFile &&
              RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
          .toList();

      if (slideFiles.isNotEmpty) {
        slideFiles.sort((a, b) {
          final numA = int.tryParse(
                  RegExp(r'\d+').firstMatch(a.name)?.group(0) ?? '0') ??
              0;
          final numB = int.tryParse(
                  RegExp(r'\d+').firstMatch(b.name)?.group(0) ?? '0') ??
              0;
          return numA.compareTo(numB);
        });

        final pages = <PdfPageInfo>[];
        final aTextRegex = RegExp(r'<a:t[^>]*>(.*?)</a:t>', dotAll: true);
        final aParagraphRegex = RegExp(r'<a:p[ >](.*?)</a:p>', dotAll: true);

        for (int i = 0; i < slideFiles.length; i++) {
          final xml = utf8.decode(slideFiles[i].content as List<int>,
              allowMalformed: true);
          final slideBuffer = StringBuffer();
          for (final pMatch in aParagraphRegex.allMatches(xml)) {
            final pXml = pMatch.group(1) ?? '';
            final lineBuf = StringBuffer();
            for (final tMatch in aTextRegex.allMatches(pXml)) {
              lineBuf.write(_decodeXmlEntities(tMatch.group(1) ?? ''));
            }
            final line = lineBuf.toString().trim();
            if (line.isNotEmpty) {
              slideBuffer.writeln(line);
            }
          }
          final slideText = slideBuffer.toString().trim();
          pages.add(
            PdfPageInfo(
              pageNumber: i + 1,
              text: slideText,
            ),
          );
        }

        return ProcessedPdfDocument(
          fileName: fileName,
          totalPages: pages.length,
          pages: pages,
          isOffline: true,
        );
      }
    } catch (_) {}

    throw const FormatException(
        'No readable slides found. Convert legacy PPT files to PPTX or PDF.');
  }

  /// Extracts sheets and rows from Excel spreadsheets (.xlsx, .xls, .csv)
  static ProcessedPdfDocument extractExcelDocument({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.csv') || lower.endsWith('.tsv')) {
      return extractTextDocument(fileBytes: fileBytes, fileName: fileName);
    }
    if (fileBytes.length >= 2 && fileBytes[0] == 0x50 && fileBytes[1] == 0x4B) {
      return SpreadsheetReader.read(fileBytes, fileName);
    }
    throw const FormatException(
        'Convert legacy XLS files to XLSX, ODS or CSV.');
  }

  /// Extracts an Audiobook / Document ZIP archive (.zip)
  static ProcessedPdfDocument extractAudiobookZip({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    try {
      final archive = ZipDecoder().decodeBytes(fileBytes);
      final manifestFile = archive.findFile('audiobook.json');
      if (manifestFile != null) {
        final jsonStr = utf8.decode(manifestFile.content as List<int>,
            allowMalformed: true);
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final pagesJson = data['pages'] as List<dynamic>? ?? [];
        if (pagesJson.isNotEmpty) {
          final pages = <PdfPageInfo>[];
          for (int i = 0; i < pagesJson.length; i++) {
            final item = pagesJson[i] as Map<String, dynamic>;
            pages.add(
              PdfPageInfo(
                pageNumber: (item['page'] as int?) ?? (i + 1),
                text: item['text']?.toString() ?? '',
              ),
            );
          }
          return ProcessedPdfDocument(
            fileName: data['title']?.toString() ?? fileName,
            totalPages: pages.length,
            pages: pages,
            isOffline: true,
          );
        }
      }

      final textFiles = archive.files
          .where((f) =>
              f.isFile &&
              (f.name.endsWith('.txt') ||
                  f.name.endsWith('.md') ||
                  f.name.endsWith('.html')))
          .toList();
      if (textFiles.isNotEmpty) {
        textFiles.sort((a, b) => naturalDocumentOrder(a.name, b.name));
        final pages = <PdfPageInfo>[];
        for (int i = 0; i < textFiles.length; i++) {
          final content = extractTextDocument(
                  fileBytes: Uint8List.fromList(textFiles[i].content),
                  fileName: textFiles[i].name)
              .pages
              .map((p) => p.text)
              .join('\n\n');
          if (content.isNotEmpty) {
            pages.add(
              PdfPageInfo(
                pageNumber: pages.length + 1,
                text: content,
              ),
            );
          }
        }
        if (pages.isNotEmpty) {
          return ProcessedPdfDocument(
            fileName: fileName,
            totalPages: pages.length,
            pages: pages,
            isOffline: true,
          );
        }
      }
    } catch (_) {}

    return _paginateText(
      '',
      fileName,
      engineName: 'Audiobook ZIP Reader',
    );
  }

  /// Fetches and extracts clean readable article/page text from a Web URL (`http://` or `https://`)
  static Future<ProcessedPdfDocument> extractFromWebUrl(String rawUrl) async {
    var urlStr = rawUrl.trim();
    if (!urlStr.startsWith('http://') && !urlStr.startsWith('https://')) {
      urlStr = 'https://$urlStr';
    }
    final uri = Uri.parse(urlStr);
    final response = await http.get(
      uri,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    ).timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} when loading $urlStr');
    }

    final bodyBytes = response.bodyBytes;
    final host = uri.host;
    return Isolate.run(() {
      final html = utf8.decode(bodyBytes, allowMalformed: true);
      final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>',
              caseSensitive: false, dotAll: true)
          .firstMatch(html);
      final pageTitle = titleMatch != null
          ? _decodeXmlEntities(
              titleMatch.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim())
          : host;

      var cleaned = html
          .replaceAll(
              RegExp(r'<(script|style|noscript|svg|head)[^>]*>.*?</\1>',
                  caseSensitive: false, dotAll: true),
              ' ')
          .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
          .replaceAll(
              RegExp(r'</(p|div|h1|h2|h3|h4|h5|h6|li|tr|br|section|article)>',
                  caseSensitive: false),
              '\n')
          .replaceAll(RegExp(r'<[^>]+>'), ' ');

      cleaned = _decodeXmlEntities(cleaned);
      cleaned = _cleanAndFormatPageText(cleaned);

      if (cleaned.isEmpty) {
        throw const FormatException(
            'No readable text was found on this web page.');
      }

      return _paginateText(
        cleaned,
        pageTitle.isNotEmpty ? pageTitle : host,
        engineName: 'Web Page Reader',
      );
    });
  }

  /// Creates a paginated document directly from user-entered or pasted text
  static ProcessedPdfDocument createFromDirectText({
    required String text,
    required String title,
  }) {
    return _paginateText(
      _cleanAndFormatPageText(text),
      title,
      engineName: 'Direct Text Reader',
    );
  }

  static String _extractDocxText(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final docFile = archive.findFile('word/document.xml');
      if (docFile == null) return '';

      final List<int> rawBytes = docFile.content as List<int>;
      final content = utf8.decode(rawBytes, allowMalformed: true);

      final StringBuffer buffer = StringBuffer();
      final pRegex = RegExp(r'<w:p[ >](.*?)</w:p>', dotAll: true);
      final tRegex = RegExp(r'<w:t[^>]*>(.*?)</w:t>', dotAll: true);

      for (final match in pRegex.allMatches(content)) {
        final pContent = match.group(1) ?? '';
        final StringBuffer pBuffer = StringBuffer();
        for (final tMatch in tRegex.allMatches(pContent)) {
          final text = tMatch.group(1) ?? '';
          pBuffer.write(_decodeXmlEntities(text));
        }
        final pText = pBuffer.toString().trim();
        if (pText.isNotEmpty) {
          buffer.writeln(pText);
        }
      }

      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }

  static String _decodeXmlEntities(String xml) {
    return xml
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll('&#8204;', '\u200C')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code != null ? String.fromCharCode(code) : '';
    }).replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      return code != null ? String.fromCharCode(code) : '';
    });
  }

  static String _stripHtmlTagsToCleanText(String html) {
    var cleaned = html
        .replaceAll(
            RegExp(r'<(script|style|noscript|svg|head)[^>]*>.*?</\1>',
                caseSensitive: false, dotAll: true),
            ' ')
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
        .replaceAll(RegExp(r'<(br|hr)\s*/?>', caseSensitive: false), '\n')
        .replaceAll(
            RegExp(
                r'</(p|div|h1|h2|h3|h4|h5|h6|li|tr|section|article|blockquote|title)>',
                caseSensitive: false),
            '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    cleaned = _decodeXmlEntities(cleaned);
    return _cleanAndFormatPageText(cleaned);
  }

  /// Extracts chapters and pages from EPUB e-book archives (.epub)
  static ProcessedPdfDocument extractEpubDocument({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    try {
      final archive = ZipDecoder().decodeBytes(fileBytes);

      String? opfPath;
      final containerFile = archive.findFile('META-INF/container.xml');
      if (containerFile != null) {
        final containerXml = utf8.decode(containerFile.content as List<int>,
            allowMalformed: true);
        final match = RegExp(r'full-path\s*=\s*"([^"]+)"', caseSensitive: false)
            .firstMatch(containerXml);
        if (match != null) {
          opfPath = match.group(1);
        }
      }
      if (opfPath == null) {
        for (final f in archive.files) {
          if (f.isFile && f.name.toLowerCase().endsWith('.opf')) {
            opfPath = f.name;
            break;
          }
        }
      }

      final orderedHtmlPaths = <String>[];
      if (opfPath != null) {
        final opfFile = archive.findFile(opfPath);
        if (opfFile != null) {
          final opfDir = opfPath.contains('/')
              ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
              : '';
          final opfXml =
              utf8.decode(opfFile.content as List<int>, allowMalformed: true);

          final manifestMap = <String, String>{};
          final itemRegex = RegExp(r'<item\b([^>]+)>', caseSensitive: false);
          for (final m in itemRegex.allMatches(opfXml)) {
            final attrs = m.group(1) ?? '';
            final idMatch =
                RegExp(r'\bid\s*=\s*"([^"]+)"', caseSensitive: false)
                    .firstMatch(attrs);
            final hrefMatch =
                RegExp(r'\bhref\s*=\s*"([^"]+)"', caseSensitive: false)
                    .firstMatch(attrs);
            if (idMatch != null && hrefMatch != null) {
              final id = idMatch.group(1)!;
              final href = Uri.decodeFull(hrefMatch.group(1)!.split('#').first);
              manifestMap[id] = '$opfDir$href';
            }
          }

          final itemrefRegex = RegExp(r'<itemref\b[^>]*\bidref\s*=\s*"([^"]+)"',
              caseSensitive: false);
          for (final m in itemrefRegex.allMatches(opfXml)) {
            final idref = m.group(1)!;
            final targetPath = manifestMap[idref];
            if (targetPath != null && !orderedHtmlPaths.contains(targetPath)) {
              orderedHtmlPaths.add(targetPath);
            }
          }
        }
      }

      if (orderedHtmlPaths.isEmpty) {
        final htmlFiles = archive.files
            .where((f) =>
                f.isFile &&
                (f.name.toLowerCase().endsWith('.xhtml') ||
                    f.name.toLowerCase().endsWith('.html') ||
                    f.name.toLowerCase().endsWith('.htm')) &&
                !f.name.toLowerCase().contains('toc') &&
                !f.name.toLowerCase().contains('nav'))
            .map((f) => f.name)
            .toList();
        htmlFiles.sort();
        orderedHtmlPaths.addAll(htmlFiles);
      }

      final pages = <PdfPageInfo>[];
      int pageNumber = 1;

      for (final htmlPath in orderedHtmlPaths) {
        ArchiveFile? file = archive.findFile(htmlPath);
        if (file == null) {
          final norm = htmlPath.replaceAll('\\', '/').toLowerCase();
          for (final f in archive.files) {
            if (f.isFile &&
                f.name.replaceAll('\\', '/').toLowerCase() == norm) {
              file = f;
              break;
            }
          }
        }
        if (file == null) continue;

        final rawHtml =
            utf8.decode(file.content as List<int>, allowMalformed: true);
        final chapterText = _stripHtmlTagsToCleanText(rawHtml);
        if (chapterText.trim().isEmpty) continue;

        final lines = chapterText.split('\n');
        final pageBuf = StringBuffer();
        for (final line in lines) {
          if (pageBuf.length + line.length > 2500 && pageBuf.isNotEmpty) {
            pages.add(PdfPageInfo(
              pageNumber: pageNumber++,
              text: pageBuf.toString().trim(),
            ));
            pageBuf.clear();
          }
          pageBuf.writeln(line);
        }
        if (pageBuf.isNotEmpty) {
          pages.add(PdfPageInfo(
            pageNumber: pageNumber++,
            text: pageBuf.toString().trim(),
          ));
        }
      }

      if (pages.isNotEmpty) {
        return ProcessedPdfDocument(
          fileName: fileName,
          totalPages: pages.length,
          pages: pages,
          isOffline: true,
        );
      }
    } catch (_) {}

    return _paginateText(
      '',
      fileName,
      engineName: 'EPUB E-Book Reader',
    );
  }

  /// Extracts text from OpenDocument files (.odt, .odp, .ods)
  static ProcessedPdfDocument extractOpenDocument({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    try {
      final archive = ZipDecoder().decodeBytes(fileBytes);
      final contentFile = archive.findFile('content.xml');
      if (contentFile != null) {
        final xml =
            utf8.decode(contentFile.content as List<int>, allowMalformed: true);
        final cleaned = xml
            .replaceAll(
                RegExp(r'</(text:p|text:h|table:table-row)>',
                    caseSensitive: false),
                '\n')
            .replaceAll(
                RegExp(r'<text:tab[^>]*/?>', caseSensitive: false), '  ')
            .replaceAll(
                RegExp(r'<text:line-break[^>]*/?>', caseSensitive: false), '\n')
            .replaceAll(RegExp(r'<[^>]+>'), '');
        final text = _cleanAndFormatPageText(_decodeXmlEntities(cleaned));
        if (text.isNotEmpty) {
          return _paginateText(text, fileName,
              engineName: 'OpenDocument Reader');
        }
      }
    } catch (_) {}

    return _paginateText(
      '',
      fileName,
      engineName: 'OpenDocument Reader',
    );
  }

  /// Extracts text from plain text and markup files (.txt, .md, .json, .csv, .log, .fb2, .rtf, .html, .htm, .xhtml, .srt)
  static ProcessedPdfDocument extractTextDocument({
    required Uint8List fileBytes,
    required String fileName,
  }) {
    String textContent = DocumentTextDecoder.decode(fileBytes);

    final lower = fileName.toLowerCase();
    if (lower.endsWith('.html') ||
        lower.endsWith('.htm') ||
        lower.endsWith('.xhtml') ||
        lower.endsWith('.fb2')) {
      textContent = _stripHtmlTagsToCleanText(textContent);
    } else if (lower.endsWith('.rtf')) {
      textContent = DocumentTextDecoder.rtf(fileBytes);
    } else if (lower.endsWith('.srt') || lower.endsWith('.vtt')) {
      final lines = textContent.replaceAll('\r\n', '\n').split('\n');
      final buf = StringBuffer();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty ||
            trimmed == 'WEBVTT' ||
            RegExp(r'^\d+$').hasMatch(trimmed) ||
            trimmed.contains('-->')) {
          continue;
        }
        buf.writeln(_stripHtmlTagsToCleanText(trimmed));
      }
      textContent = _cleanAndFormatPageText(buf.toString());
    }

    return _paginateText(textContent, fileName,
        engineName: 'Text Document Reader');
  }

  static ProcessedPdfDocument _paginateText(
    String textContent,
    String fileName, {
    String engineName = 'Document Reader',
  }) {
    if (textContent.trim().isEmpty) {
      throw const FormatException(
          'No readable text was found in this document.');
    }
    const pageSize = 2500;
    final pageList = <PdfPageInfo>[];
    final characters = CharacterBoundary(textContent);
    for (var start = 0; start < textContent.length;) {
      var end = math.min(start + pageSize, textContent.length);
      if (end < textContent.length) {
        // Keep lines together where possible. Limit the search to this page
        // so a long unbroken line cannot cause a giant page or repeated scans.
        var lineEnd = end;
        while (lineEnd > start && textContent.codeUnitAt(lineEnd - 1) != 10) {
          lineEnd--;
        }
        if (lineEnd > start) {
          end = lineEnd;
        } else {
          var wordEnd = end;
          while (wordEnd > start + pageSize ~/ 2 &&
              textContent.codeUnitAt(wordEnd - 1) != 32) {
            wordEnd--;
          }
          if (wordEnd > start + pageSize ~/ 2) {
            end = wordEnd;
          } else {
            final boundary = characters.getLeadingTextBoundaryAt(end);
            if (boundary != null && boundary > start) end = boundary;
          }
        }
      }
      final page = textContent.substring(start, end).trim();
      if (page.isNotEmpty) {
        pageList.add(PdfPageInfo(pageNumber: pageList.length + 1, text: page));
      }
      start = end;
    }

    return ProcessedPdfDocument(
      fileName: fileName,
      totalPages: pageList.length,
      pages: pageList,
      isOffline: true,
    );
  }
}
