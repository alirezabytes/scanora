import 'dart:typed_data';
import '../../models/pdf_document.dart';
import '../ocr/ocr_service.dart';

class DocumentProgress {
  final int completed, total, extracted, recognized, failed;
  const DocumentProgress(
      this.completed, this.total, this.extracted, this.recognized, this.failed);
  int get percent => total == 0 ? 0 : (completed * 100 / total).round();
  int get successful => extracted + recognized;
}

class DocumentBatchResult {
  final List<PdfPageInfo> pages;
  final DocumentProgress progress;
  const DocumentBatchResult(this.pages, this.progress);
}

/// A page is complete only after extraction or awaited OCR. A rendering/API
/// error affects that page, and cannot silently count as a successful scan.
class DocumentBatchProcessor {
  static Future<DocumentBatchResult> process({
    required List<PdfPageInfo> pages,
    required Future<Uint8List?> Function(int sourcePageIndex) render,
    required Future<ScanRecognitionResult> Function(Uint8List bytes) recognize,
    required void Function(DocumentProgress progress) onProgress,
    bool Function()? isCancelled,
  }) async {
    var extracted = 0, recognized = 0, failed = 0;
    final output = <PdfPageInfo>[];
    onProgress(DocumentProgress(0, pages.length, 0, 0, 0));
    for (final page in pages) {
      if (isCancelled?.call() ?? false) {
        throw const DocumentProcessingCancelled();
      }
      var updated = page;
      if (page.needsOcr && !page.ocrCompleted) {
        try {
          final bytes = await render(page.sourcePageIndex);
          if (bytes == null || bytes.isEmpty) {
            throw StateError('Page image could not be rendered.');
          }
          if (isCancelled?.call() ?? false) {
            throw const DocumentProcessingCancelled();
          }
          final result = await recognize(bytes);
          if (result.didFail && !result.isOffline) {
            throw DocumentOnlineFailure(result.errorMessage ??
                'The online service could not process this document.');
          }
          if (!result.hasText) {
            throw StateError(
                result.errorMessage ?? 'No readable text was found.');
          }
          updated = page.copyWith(
              text: result.text.trim(), needsOcr: false, ocrCompleted: true);
          recognized++;
        } on DocumentProcessingCancelled {
          rethrow;
        } on DocumentOnlineFailure {
          rethrow;
        } catch (error) {
          updated = page.copyWith(text: '', ocrError: error.toString());
          failed++;
        }
      } else if (page.text.trim().isNotEmpty) {
        extracted++;
      } else {
        failed++;
        updated = page.copyWith(ocrError: 'No readable text was found.');
      }
      output.add(PdfPageInfo(
          pageNumber: output.length + 1,
          text: updated.text,
          needsOcr: updated.needsOcr,
          ocrCompleted: updated.ocrCompleted,
          ocrError: updated.ocrError,
          sourcePageIndex: page.sourcePageIndex));
      onProgress(DocumentProgress(
          output.length, pages.length, extracted, recognized, failed));
      await Future<void>.delayed(Duration.zero);
    }
    if (isCancelled?.call() ?? false) throw const DocumentProcessingCancelled();
    return DocumentBatchResult(
        output,
        DocumentProgress(
            output.length, pages.length, extracted, recognized, failed));
  }
}

class DocumentProcessingCancelled implements Exception {
  const DocumentProcessingCancelled();
}

/// Stop a document job after a service error; do not upload its other pages.
class DocumentOnlineFailure implements Exception {
  final String message;
  const DocumentOnlineFailure(this.message);
  @override
  String toString() => message;
}
