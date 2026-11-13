import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Keep a scanned book on disk. Retaining every full-resolution photo in the UI
/// can exhaust a phone's memory after only a few pages.
class CapturedPageStore extends ListBase<Uint8List> {
  final List<File> _files = [];
  final List<String> _texts = [];
  Future<Directory>? _directory;
  bool _closed = false;
  final bool offline;
  bool transferred = false;
  Future<void> _writes = Future<void>.value();
  CapturedPageStore({required this.offline});

  Future<void> append(Uint8List bytes, {String text = ''}) {
    if (_closed) {
      return Future<void>.error(StateError('The scan session has closed.'));
    }
    final write = _writes.then((_) => _append(bytes, text));
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> _append(Uint8List bytes, String text) async {
    final dir =
        await (_directory ??= Directory.systemTemp.createTemp('scanora_book_'));
    if (_closed) return;
    final file =
        File('${dir.path}${Platform.pathSeparator}${_files.length}.image');
    await file.writeAsBytes(bytes, flush: true);
    _files.add(file);
    _texts.add(text);
  }

  Future<void> waitForWrites() => _writes;

  String textAt(int index) => _texts[index];
  void setText(int index, String text) => _texts[index] = text;
  Future<Uint8List> readPage(int index) => _files[index].readAsBytes();
  @override
  int get length => _files.length;
  @override
  set length(int value) => throw UnsupportedError('Use append to save a page.');
  @override
  Uint8List operator [](int index) => _files[index].readAsBytesSync();
  @override
  void operator []=(int index, Uint8List value) =>
      throw UnsupportedError('Captured pages are immutable.');

  Future<void> close() async {
    _closed = true;
    await _writes;
    final pending = _directory;
    if (pending == null) return;
    final dir = await pending;
    // Delete only the dedicated temporary directory created by this store.
    if (dir.parent.absolute.path == Directory.systemTemp.absolute.path &&
        dir.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('scanora_book_') &&
        await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
