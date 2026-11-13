import 'dart:isolate';
import 'package:flutter/services.dart';
import 'tts_models.dart';

/// Messages exchanged between the UI isolate and the eSpeak-NG worker isolate.
/// Only plain, sendable data is used.

class TtsWorkerBootstrap {
  final SendPort mainPort;
  final RootIsolateToken? rootToken;

  /// Windows: absolute path of `espeak-ng.exe`. Android: null.
  final String? windowsExePath;
  final String? windowsDataPath;

  /// Android: parent directory that contains `espeak-ng-data`.
  final String? androidDataPath;

  const TtsWorkerBootstrap({
    required this.mainPort,
    required this.rootToken,
    required this.windowsExePath,
    this.windowsDataPath,
    required this.androidDataPath,
  });
}

// ---------------------------------------------------------------- UI -> worker

sealed class TtsCommand {
  const TtsCommand();
}

class TtsPlayCommand extends TtsCommand {
  final int session;
  final List<TtsChunk> chunks;
  final int startIndex;
  final TtsEngineParams params;
  const TtsPlayCommand(this.session, this.chunks, this.startIndex, this.params);
}

class TtsStopCommand extends TtsCommand {
  const TtsStopCommand();
}

class TtsSynthesizeCommand extends TtsCommand {
  final int requestId;
  final List<TtsChunk> chunks;
  final TtsEngineParams params;
  const TtsSynthesizeCommand(this.requestId, this.chunks, this.params);
}

class TtsCancelSynthesisCommand extends TtsCommand {
  final int requestId;
  const TtsCancelSynthesisCommand(this.requestId);
}

class TtsShutdownCommand extends TtsCommand {
  const TtsShutdownCommand();
}

// ---------------------------------------------------------------- worker -> UI

sealed class TtsEvent {
  const TtsEvent();
}

class TtsReadyEvent extends TtsEvent {
  final SendPort commandPort;
  const TtsReadyEvent(this.commandPort);
}

class TtsChunkStartedEvent extends TtsEvent {
  final int session;
  final int index;

  /// Real duration when known (Windows WAV pipeline), otherwise 0.
  final int durationMs;
  const TtsChunkStartedEvent(this.session, this.index, this.durationMs);
}

class TtsSessionCompletedEvent extends TtsEvent {
  final int session;
  const TtsSessionCompletedEvent(this.session);
}

class TtsWavEvent extends TtsEvent {
  final int requestId;
  final TransferableTypedData? wav;
  const TtsWavEvent(this.requestId, this.wav);
}

class TtsSynthesisProgressEvent extends TtsEvent {
  final int requestId, completed, total;
  const TtsSynthesisProgressEvent(this.requestId, this.completed, this.total);
}

class TtsErrorEvent extends TtsEvent {
  final String message;
  const TtsErrorEvent(this.message);
}

/// Helper so the UI isolate can read a WAV event payload.
Uint8List? materializeWav(TtsWavEvent e) => e.wav?.materialize().asUint8List();
