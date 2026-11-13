import 'dart:ffi';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _CryptNative = Int32 Function(Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptDart = int Function(Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

/// Windows DPAPI encrypts OAuth tokens for the current Windows user. Android
/// tokens stay with Google's native SDK and never enter this store.
class DesktopTokenStore {
  static Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File(
        '${directory.path}${Platform.pathSeparator}google_oauth_v6.dpapi');
  }

  static Uint8List protect(Uint8List bytes, {bool decrypt = false}) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows DPAPI is required.');
    }
    final crypt = DynamicLibrary.open('crypt32.dll')
        .lookupFunction<_CryptNative, _CryptDart>(
            decrypt ? 'CryptUnprotectData' : 'CryptProtectData');
    final free = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
    final source = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    source.ref.length = bytes.length;
    source.ref.data = calloc<Uint8>(bytes.length);
    source.ref.data.asTypedList(bytes.length).setAll(0, bytes);
    try {
      final ok = crypt(source, nullptr, nullptr, nullptr, nullptr, 1, output);
      if (ok == 0) {
        throw StateError(
            'Windows could not ${decrypt ? 'decrypt' : 'encrypt'} the Google session. Sign in again.');
      }
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      source.ref.data
          .asTypedList(source.ref.length)
          .fillRange(0, source.ref.length, 0);
      if (output.ref.data != nullptr) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
        free(output.ref.data.cast());
      }
      calloc.free(source.ref.data);
      calloc.free(source);
      calloc.free(output);
    }
  }

  static Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    return utf8.decode(protect(await file.readAsBytes(), decrypt: true));
  }

  static Future<void> write(String value) async {
    await (await _file()).writeAsBytes(
        protect(Uint8List.fromList(utf8.encode(value))),
        flush: true);
  }

  static Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
