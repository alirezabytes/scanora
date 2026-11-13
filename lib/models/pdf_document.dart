class PdfPageInfo {
  final int pageNumber;
  final String text;
  final int wordCount;
  final int charCount;
  final bool needsOcr;
  final bool ocrCompleted;
  final String? ocrError;
  final int sourcePageIndex;

  PdfPageInfo({
    required this.pageNumber,
    required this.text,
    this.needsOcr = false,
    this.ocrCompleted = false,
    this.ocrError,
    int? sourcePageIndex,
  })  : sourcePageIndex = sourcePageIndex ?? pageNumber - 1,
        wordCount =
            text.trim().isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length,
        charCount = text.length;

  PdfPageInfo copyWith({
    String? text,
    bool? needsOcr,
    bool? ocrCompleted,
    String? ocrError,
  }) {
    return PdfPageInfo(
      pageNumber: pageNumber,
      text: text ?? this.text,
      needsOcr: needsOcr ?? this.needsOcr,
      ocrCompleted: ocrCompleted ?? this.ocrCompleted,
      ocrError: ocrError,
      sourcePageIndex: sourcePageIndex,
    );
  }
}

class ProcessedPdfDocument {
  final String fileName;
  final int totalPages;
  final List<PdfPageInfo> pages;
  final bool isOffline;
  final DateTime processedAt;

  ProcessedPdfDocument({
    required this.fileName,
    required this.totalPages,
    required this.pages,
    required this.isOffline,
    DateTime? processedAt,
  }) : processedAt = processedAt ?? DateTime.now();

  /// Produces clear, formatted output showing page dividers and page counts:
  /// e.g.
  /// ====================================================
  /// 📄 صفحه ۱ از ۳ | Page 1 of 3 (تعداد کلمات: 124)
  /// ====================================================
  /// [Content of Page 1]
  String getFormattedDocument({bool isPersian = true}) {
    final buffer = StringBuffer();
    for (final page in pages) {
      final headerTitle = isPersian
          ? '📄 صفحه ${page.pageNumber} از $totalPages (واژگان: ${page.wordCount})'
          : '📄 Page ${page.pageNumber} of $totalPages (Words: ${page.wordCount})';

      buffer.writeln('====================================================');
      buffer.writeln(headerTitle);
      buffer.writeln('====================================================');
      buffer.writeln(page.text.trim());
      buffer.writeln('\n');
    }
    return buffer.toString();
  }
}
