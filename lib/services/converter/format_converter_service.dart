import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../export/docx_exporter.dart';
import '../export/text_direction.dart';
import '../native_bridge_service.dart';
import '../ocr/ocr_service.dart';
import '../pdf/pdf_service.dart';
import '../pdf/document_image_loader.dart';
import '../pdf/document_batch_processor.dart';
import '../pdf/document_formats.dart';
import '../pdf/document_work.dart';
import '../../models/pdf_document.dart';
import '../settings_service.dart';
import '../ai/online_access_service.dart';
import '../storage/app_storage_service.dart';

enum TargetFormat {
  docx,
  rtf,
  pdf,
  txt,
  md,
  html,
  json,
}

extension TargetFormatExtension on TargetFormat {
  String get extensionName {
    switch (this) {
      case TargetFormat.docx:
        return 'docx';
      case TargetFormat.rtf:
        return 'rtf';
      case TargetFormat.pdf:
        return 'pdf';
      case TargetFormat.txt:
        return 'txt';
      case TargetFormat.md:
        return 'md';
      case TargetFormat.html:
        return 'html';
      case TargetFormat.json:
        return 'json';
    }
  }

  String get label {
    switch (this) {
      case TargetFormat.docx:
        return 'Microsoft Word (.docx)';
      case TargetFormat.rtf:
        return 'Rich Text (.rtf)';
      case TargetFormat.pdf:
        return 'PDF Document (.pdf)';
      case TargetFormat.txt:
        return 'Plain Text (.txt)';
      case TargetFormat.md:
        return 'Markdown (.md)';
      case TargetFormat.html:
        return 'HTML Webpage (.html)';
      case TargetFormat.json:
        return 'Structured JSON (.json)';
    }
  }

  IconData get icon {
    switch (this) {
      case TargetFormat.docx:
      case TargetFormat.rtf:
        return Icons.description_rounded;
      case TargetFormat.pdf:
        return Icons.picture_as_pdf_rounded;
      case TargetFormat.txt:
      case TargetFormat.md:
        return Icons.article_rounded;
      case TargetFormat.html:
        return Icons.language_rounded;
      case TargetFormat.json:
        return Icons.data_object_rounded;
    }
  }
}

class FormatConverterResult {
  final String originalFileName;
  final String outputFilePath;
  final String targetFormat;
  final int fileSizeBytes;
  final int wordCount;
  final String previewText;

  FormatConverterResult({
    required this.originalFileName,
    required this.outputFilePath,
    required this.targetFormat,
    required this.fileSizeBytes,
    required this.wordCount,
    required this.previewText,
  });
}

class FormatConverterService {
  /// Extracts all textual paragraphs and raw text from any source file, performing
  /// OCR on scanned PDF pages when [settings] is provided and reporting percentage via [onProgress].
  static Future<List<String>> extractContent({
    required Uint8List fileBytes,
    required String fileName,
    String? filePath,
    DocumentWork? work,
    SettingsService? settings,
    bool isPersian = false,
    void Function(int percent, String status)? onProgress,
    Future<void> Function()? beforeOcr,
  }) async {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    if (settings != null && DocumentFormats.images.contains(ext)) {
      await OnlineAccessService.ensure(settings, task: OnlineTask.ocr);
    }
    onProgress?.call(
      5,
      isPersian ? 'در حال بررسی فایل (۵ درصد)...' : 'Analyzing file (5%)...',
    );

    work?.checkpoint();
    final imagePages = ext == 'pdf'
        ? null
        : await DocumentImageLoader.load(fileBytes, fileName);
    work?.checkpoint();
    if (ext == 'pdf' || imagePages != null) {
      final path =
          filePath != null && await File(filePath).exists() ? filePath : null;
      void preparationProgress(int percent) => onProgress?.call(
          percent ~/ 10,
          isPersian
              ? 'آماده‌سازی صفحات: $percent درصد'
              : 'Preparing pages: $percent%');
      final processed = ext == 'pdf'
          ? path == null
              ? await PdfService.extractPdfPages(
                  pdfBytes: fileBytes,
                  fileName: fileName,
                  isOfflineMode: settings?.isOfflineMode ?? true,
                  onProgress: preparationProgress,
                  cancelled: work?.whenCancelled,
                )
              : await PdfService.extractPdfFile(
                  path: path,
                  fileName: fileName,
                  isOfflineMode: settings?.isOfflineMode ?? true,
                  onProgress: preparationProgress,
                  cancelled: work?.whenCancelled,
                )
          : ProcessedPdfDocument(
              fileName: fileName,
              totalPages: imagePages!.length,
              pages: [
                for (var i = 0; i < imagePages.length; i++)
                  PdfPageInfo(pageNumber: i + 1, text: '', needsOcr: true)
              ],
              isOffline: settings?.isOfflineMode ?? true);
      final options = settings ?? SettingsService();
      if (!options.isOfflineMode &&
          processed.pages.any((page) => page.needsOcr && !page.ocrCompleted)) {
        await beforeOcr?.call();
        await OnlineAccessService.ensure(options, task: OnlineTask.ocr);
        work?.checkpoint();
      }
      final batch = await DocumentBatchProcessor.process(
          pages: processed.pages,
          isCancelled: () => work?.isCancelled ?? false,
          render: (index) async => imagePages != null
              ? imagePages[index]
              : path != null
                  ? await NativeBridgeService.renderPdfPageAsPng(
                      pdfPath: path, pageIndex: index)
                  : await NativeBridgeService.renderPdfPageToPng(
                      fileBytes, index),
          recognize: (bytes) => OcrService.processImage(
              imageBytes: bytes,
              isOfflineMode: options.isOfflineMode,
              activeProvider: options.activeProvider,
              apiKey: options.getApiKey(options.activeProvider),
              modelName: options.getSelectedModel(options.activeProvider),
              customBaseUrl: options.customBaseUrl,
              thinkingEffort: options.thinkingEffort,
              isPersian: isPersian,
              useScanoraCloud: options.useScanoraCloudOcr,
              preferResponsiveDocumentOcr: true),
          onProgress: (p) => onProgress?.call(
              10 + p.percent * 90 ~/ 100,
              isPersian
                  ? '${p.percent} درصد؛ موفق ${p.successful}، ناموفق ${p.failed}'
                  : '${p.percent}%; ${p.successful} successful, ${p.failed} failed'));
      if (batch.progress.failed > 0) {
        throw StateError(isPersian
            ? '${batch.progress.failed} صفحه خوانده نشد. برای بازبینی از مطالعه و اسناد استفاده کنید.'
            : '${batch.progress.failed} pages could not be read. Review them in Reading & Documents before converting.');
      }
      return batch.pages.map((p) => p.text).where((t) => t.isNotEmpty).toList();
    } else if (['docx', 'doc', 'docm', 'dotx'].contains(ext)) {
      final processed = await PdfService.extractWordDocumentAsync(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      onProgress?.call(100, isPersian ? '۱۰۰ درصد' : '100%');
      return processed.pages
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .toList();
    } else if (ext == 'epub') {
      final processed = await PdfService.extractEpubDocumentAsync(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      onProgress?.call(100, isPersian ? '۱۰۰ درصد' : '100%');
      return processed.pages
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .toList();
    } else if (ext == 'odt' || ext == 'odp' || ext == 'ods') {
      final processed = await PdfService.extractOpenDocumentAsync(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      onProgress?.call(100, isPersian ? '۱۰۰ درصد' : '100%');
      return processed.pages
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .toList();
    } else if (['pptx', 'ppt', 'pptm', 'ppsx'].contains(ext)) {
      final processed = await PdfService.extractPowerPointDocumentAsync(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      onProgress?.call(100, isPersian ? '۱۰۰ درصد' : '100%');
      return processed.pages
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .toList();
    } else if (['xlsx', 'xls', 'xlsm', 'xltx', 'csv', 'tsv'].contains(ext)) {
      final processed = await PdfService.extractExcelDocumentAsync(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      onProgress?.call(100, isPersian ? '۱۰۰ درصد' : '100%');
      return processed.pages
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .toList();
    } else if (ext == 'zip') {
      final processed = await PdfService.extractAudiobookZipAsync(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      onProgress?.call(100, isPersian ? '۱۰۰ درصد' : '100%');
      return processed.pages
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .toList();
    } else {
      final processed = await PdfService.extractTextDocumentAsync(
        fileBytes: fileBytes,
        fileName: fileName,
      );
      onProgress?.call(100, isPersian ? '۱۰۰ درصد' : '100%');
      final pages = processed.pages
          .map((p) => p.text)
          .where((t) => t.isNotEmpty)
          .toList();
      if (pages.isNotEmpty) return pages;
      throw const FormatException('No readable text found.');
    }
  }

  /// Converts input content to the requested target format and saves to storage
  static Future<FormatConverterResult> convertAndSave({
    required Uint8List sourceBytes,
    required String sourceFileName,
    String? sourceFilePath,
    DocumentWork? work,
    required TargetFormat targetFormat,
    String? customExportDir,
    bool isRtl = false,
    SettingsService? settings,
    List<String>? preExtractedParagraphs,
    String? outputStem,
    Future<void> Function()? beforeOcr,
    void Function(int percent, String status)? onProgress,
  }) async {
    final baseName = sourceFileName.contains('.')
        ? sourceFileName.substring(0, sourceFileName.lastIndexOf('.'))
        : sourceFileName;

    onProgress?.call(
      10,
      isRtl
          ? 'در حال آماده‌سازی تبدیل (۱۰ درصد)...'
          : 'Preparing conversion (10%)...',
    );

    final paragraphs =
        (preExtractedParagraphs != null && preExtractedParagraphs.isNotEmpty)
            ? preExtractedParagraphs
            : await extractContent(
                fileBytes: sourceBytes,
                fileName: sourceFileName,
                filePath: sourceFilePath,
                work: work,
                settings: settings,
                beforeOcr: beforeOcr,
                isPersian: isRtl,
                onProgress: (pct, status) {
                  final scaled = 10 + ((pct * 65) ~/ 100);
                  onProgress?.call(scaled, status);
                },
              );

    work?.checkpoint();
    onProgress?.call(
      80,
      isRtl
          ? 'در حال ساخت فایل خروجی (۸۰ درصد)...'
          : 'Building output file (80%)...',
    );

    final outExt = targetFormat.extensionName;
    final outFileName =
        AppStorageService.outputName(outputStem ?? baseName, outExt);
    final fontData = targetFormat == TargetFormat.pdf
        ? await rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf')
        : null;
    work?.checkpoint();
    final font = fontData?.buffer
        .asUint8List(fontData.offsetInBytes, fontData.lengthInBytes);
    final output =
        await _prepareOutput(baseName, paragraphs, targetFormat, isRtl, font);
    work?.beginCommit();
    onProgress?.call(95, isRtl ? 'در حال ذخیرهٔ فایل…' : 'Saving file…');
    final savedFile = await AppStorageService.saveFile(
      fileName: outFileName,
      bytes: output.bytes,
      customDirectory: customExportDir,
    );

    onProgress?.call(
      100,
      isRtl ? 'تبدیل ۱۰۰ درصد کامل شد.' : 'Conversion 100% complete.',
    );

    return FormatConverterResult(
      originalFileName: sourceFileName,
      outputFilePath: savedFile.path,
      targetFormat: outExt,
      fileSizeBytes: output.bytes.length,
      wordCount: output.wordCount,
      previewText: output.preview,
    );
  }

  static Future<
      ({Uint8List bytes, int wordCount, String preview})> _prepareOutput(
          String title,
          List<String> paragraphs,
          TargetFormat format,
          bool isRtl,
          Uint8List? font) =>
      Isolate.run(() => _encodeOutput(title, paragraphs, format, isRtl, font));

  static ({Uint8List bytes, int wordCount, String preview}) _encodeOutput(
      String baseName,
      List<String> paragraphs,
      TargetFormat targetFormat,
      bool isRtl,
      Uint8List? font) {
    final fullText = paragraphs.join('\n\n');
    final wordCount = fullText.trim().isEmpty
        ? 0
        : fullText.trim().split(RegExp(r'\s+')).length;
    Uint8List outBytes;

    switch (targetFormat) {
      case TargetFormat.docx:
        outBytes = DocxExporter.createDocx(
          title: baseName,
          paragraphs: paragraphs,
          isRtl: isRtl,
        );
        break;

      case TargetFormat.rtf:
        outBytes = DocxExporter.createRtf(
          title: baseName,
          paragraphs: paragraphs,
          isRtl: isRtl,
        );
        break;

      case TargetFormat.pdf:
        outBytes = _renderPdf(baseName, paragraphs, font!, isRtl);
        break;

      case TargetFormat.txt:
        outBytes = Uint8List.fromList(utf8.encode(fullText));
        break;

      case TargetFormat.md:
        final mdContent = StringBuffer('# $baseName\n\n');
        for (final p in paragraphs) {
          mdContent.writeln(p);
          mdContent.writeln();
        }
        outBytes = Uint8List.fromList(utf8.encode(mdContent.toString()));
        break;

      case TargetFormat.html:
        final htmlContent = StringBuffer(
          '<!DOCTYPE html><html><head><meta charset="utf-8">'
          '<title>${const HtmlEscape().convert(baseName)}</title>'
          '<style>body{font-family:sans-serif;margin:40px;line-height:1.6;direction:${isRtl ? 'rtl' : 'ltr'};}'
          'h1{border-bottom:1px solid #ccc;padding-bottom:10px;}</style>'
          '</head><body><h1>${const HtmlEscape().convert(baseName)}</h1>',
        );
        for (final p in paragraphs) {
          htmlContent.writeln(
              '<p>${const HtmlEscape().convert(p).replaceAll('\n', '<br>')}</p>');
        }
        htmlContent.writeln('</body></html>');
        outBytes = Uint8List.fromList(utf8.encode(htmlContent.toString()));
        break;

      case TargetFormat.json:
        final jsonMap = {
          'title': baseName,
          'convertedAt': DateTime.now().toIso8601String(),
          'wordCount': wordCount,
          'paragraphs': paragraphs,
        };
        outBytes = Uint8List.fromList(
            utf8.encode(const JsonEncoder.withIndent('  ').convert(jsonMap)));
        break;
    }

    return (
      bytes: outBytes,
      wordCount: wordCount,
      preview:
          fullText.length > 300 ? '${fullText.substring(0, 300)}...' : fullText,
    );
  }

  static Uint8List _renderPdf(
      String title, List<String> paragraphs, Uint8List fontBytes, bool isRtl) {
    final doc = PdfDocument();
    try {
      final font = PdfTrueTypeFont(fontBytes, 12);
      var page = doc.pages.add();
      var y = 0.0;
      for (final text in [
        title,
        '',
        ...paragraphs.expand((p) => p.split('\n'))
      ]) {
        if (text.trim().isEmpty) {
          y += 10;
          continue;
        }
        if (y + 25 >= page.getClientSize().height) {
          page = doc.pages.add();
          y = 0;
        }
        final rtl = textIsRtl(text, fallback: isRtl);
        final result = PdfTextElement(
                text: text,
                font: font,
                format: PdfStringFormat(
                    textDirection: rtl
                        ? PdfTextDirection.rightToLeft
                        : PdfTextDirection.leftToRight,
                    alignment:
                        rtl ? PdfTextAlignment.right : PdfTextAlignment.left,
                    lineSpacing: 5))
            .draw(
                page: page,
                bounds: Rect.fromLTWH(0, y, page.getClientSize().width,
                    page.getClientSize().height - y),
                format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate))!;
        page = result.page;
        y = result.bounds.bottom + 8;
      }
      return Uint8List.fromList(doc.saveSync());
    } finally {
      doc.dispose();
    }
  }
}
