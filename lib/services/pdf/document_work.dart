import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'document_batch_processor.dart';

/// A user-started file operation with a cancellation boundary before saving.
class DocumentWork {
  static const _channel = MethodChannel('com.scanora.app/native');
  static int _nextId = 0;
  final int _id = ++_nextId;
  final bool isPersian;
  bool _foreground = false;
  bool _committing = false;
  bool _cancelled = false;
  final _cancellation = Completer<void>();

  DocumentWork({required this.isPersian});

  bool get isCancelled => _cancelled;
  bool get canCancel => !_committing && !_cancelled;
  Future<void> get whenCancelled => _cancellation.future;

  void cancel() {
    if (!canCancel) return;
    _cancelled = true;
    _cancellation.complete();
  }

  void checkpoint() {
    if (_cancelled) throw const DocumentProcessingCancelled();
  }

  void beginCommit() {
    checkpoint();
    _committing = true;
  }

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      _foreground = await _channel.invokeMethod<bool>(
              'beginDocumentProcessing', {'id': _id, 'persian': isPersian}) ??
          false;
    } on PlatformException {
      // A device can refuse foreground service starts. Keep the open app usable.
    } on MissingPluginException {
      // Also permits Flutter-only tests.
    }
  }

  Future<void> finish() async {
    if (!_foreground) return;
    _foreground = false;
    try {
      await _channel
          .invokeMethod<void>('finishDocumentProcessing', {'id': _id});
    } on PlatformException {
      // Android also stops the service if the activity/task is destroyed.
    } on MissingPluginException {
      // The channel can disappear with the Flutter engine.
    }
  }
}
