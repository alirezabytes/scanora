import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Uses the documented Drive import/export API. No alternate OCR provider is
/// contacted, so a successful result really came from Google Docs.
class GoogleDriveOcrClient {
  final http.Client client;
  final Future<void> Function(Duration) delay;
  final void Function(String operation, int httpStatus)? onTrace;
  GoogleDriveOcrClient(this.client,
      {Future<void> Function(Duration)? delay, this.onTrace})
      : delay = delay ?? Future<void>.delayed;

  Future<String> recognize({
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
    required String accessToken,
    required String language,
    void Function(int)? onProgress,
  }) async {
    final auth = {'Authorization': 'Bearer $accessToken'};
    final boundary = 'scanora_${DateTime.now().microsecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': fileName,
      'mimeType': 'application/vnd.google-apps.document',
      'appProperties': {'scanoraTemporaryOcr': 'true'},
    });
    final body = BytesBuilder()
      ..add(utf8.encode(
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n--$boundary\r\nContent-Type: $mimeType\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    String? fileId;
    try {
      final upload = await client
          .post(
            Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
              'uploadType': 'multipart',
              'ocrLanguage': language,
              'fields': 'id,mimeType',
            }),
            headers: {
              ...auth,
              'Content-Type': 'multipart/related; boundary=$boundary'
            },
            body: body.takeBytes(),
          )
          .timeout(const Duration(seconds: 90));
      onTrace?.call('import', upload.statusCode);
      if (upload.statusCode != 200 && upload.statusCode != 201) {
        throw StateError(
            'Google Drive import failed (HTTP ${upload.statusCode}). Check Drive API access and storage quota.');
      }
      final data =
          jsonDecode(utf8.decode(upload.bodyBytes)) as Map<String, dynamic>;
      fileId = data['id'] as String?;
      if (fileId == null || fileId.isEmpty) {
        throw StateError('Google Drive returned no document ID.');
      }
      if (data['mimeType'] != 'application/vnd.google-apps.document') {
        throw StateError(
            'Google Drive did not convert the image to a Google document.');
      }
      onProgress?.call(75);
      for (var attempt = 0; attempt < 4; attempt++) {
        final export = await client
            .get(
              Uri.https('www.googleapis.com', '/drive/v3/files/$fileId/export',
                  {'mimeType': 'text/plain'}),
              headers: auth,
            )
            .timeout(const Duration(seconds: 45));
        onTrace?.call('export', export.statusCode);
        if (export.statusCode == 200) {
          final text = utf8.decode(export.bodyBytes);
          if (text.trim().isNotEmpty || attempt == 3) return text;
        } else if (![404, 429, 500, 502, 503].contains(export.statusCode) ||
            attempt == 3) {
          throw StateError(
              'Google Docs text export failed (HTTP ${export.statusCode}).');
        }
        await delay(Duration(seconds: attempt + 1));
      }
      return '';
    } finally {
      if (fileId != null && fileId.isNotEmpty) {
        // Cleanup failure must not discard a successfully exported transcript.
        try {
          final deletion = await client
              .delete(
                  Uri.https('www.googleapis.com', '/drive/v3/files/$fileId'),
                  headers: auth)
              .timeout(const Duration(seconds: 15));
          onTrace?.call('delete', deletion.statusCode);
        } catch (_) {}
      }
    }
  }
}
