import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'tts_models.dart';
import 'tts_worker_protocol.dart';

/// Entry point of the eSpeak-NG background worker isolate.
///
/// All synthesis and audio output happen here, so widget builds, animations and
/// screen-reader traffic on the UI isolate can never interrupt or stutter the voice.
///
/// Windows: chunk N + 1 is synthesized to WAV while chunk N is playing (prefetch), and
/// the WAV is played from memory through `winmm!PlaySoundW`, so sentences follow each
/// other without audible gaps.
/// Android: the native JNI engine is driven through the platform channel
/// (`BackgroundIsolateBinaryMessenger`), directly from this isolate.
@pragma('vm:entry-point')
void ttsWorkerMain(TtsWorkerBootstrap boot) {
  final worker = _TtsWorker(boot);
  worker.start();
}

class _TtsWorker {
  final TtsWorkerBootstrap boot;
  final ReceivePort _commands = ReceivePort();
  static const MethodChannel _channel = MethodChannel('com.scanora.app/native');

  int _activeSession = -1;
  Completer<void>? _wake;
  Process? _runningProcess;
  final _activeSynthesis = <int>{};

  _TtsWorker(this.boot);

  void start() {
    if (Platform.isAndroid && boot.rootToken != null) {
      BackgroundIsolateBinaryMessenger.ensureInitialized(boot.rootToken!);
    }
    _commands.listen((message) {
      if (message is TtsCommand) _handle(message);
    });
    boot.mainPort.send(TtsReadyEvent(_commands.sendPort));
  }

  void _handle(TtsCommand cmd) {
    switch (cmd) {
      case TtsPlayCommand():
        _activeSession = cmd.session;
        unawaited(_play(cmd));
      case TtsStopCommand():
        _activeSession = -1;
        unawaited(_stopOutput());
      case TtsSynthesizeCommand():
        unawaited(_synthesizeAll(cmd));
      case TtsCancelSynthesisCommand():
        _activeSynthesis.remove(cmd.requestId);
      case TtsShutdownCommand():
        _activeSession = -1;
        unawaited(_stopOutput().whenComplete(() {
          _commands.close();
          Isolate.exit();
        }));
    }
  }

  // ------------------------------------------------------------------ playback

  Future<void> _play(TtsPlayCommand cmd) async {
    final session = cmd.session;
    try {
      if (Platform.isWindows) {
        await _playWindows(cmd);
      } else if (Platform.isAndroid) {
        await _playAndroid(cmd);
      }
      if (_activeSession == session) {
        boot.mainPort.send(TtsSessionCompletedEvent(session));
      }
    } catch (e) {
      boot.mainPort.send(TtsErrorEvent('Playback failed: $e'));
      if (_activeSession == session) {
        boot.mainPort.send(TtsSessionCompletedEvent(session));
      }
    }
  }

  Future<void> _playAndroid(TtsPlayCommand cmd) async {
    for (int i = cmd.startIndex; i < cmd.chunks.length; i++) {
      if (_activeSession != cmd.session) return;
      final c = cmd.chunks[i];
      boot.mainPort.send(TtsChunkStartedEvent(cmd.session, i, 0));
      final spoken = await _channel.invokeMethod<bool>(
          'espeakSpeak', _androidArgs(c, cmd.params));
      if (spoken != true) {
        throw StateError('Android speech engine could not play the text.');
      }
    }
  }

  Map<String, Object?> _androidArgs(TtsChunk c, TtsEngineParams p) => {
        'dataPath': boot.androidDataPath,
        'text': c.engineText,
        'ssml': c.ssml,
        'voice': c.voiceSpec,
        'rate': p.rate,
        'pitch': p.pitch,
        'pitchRange': p.pitchRange,
        'volume': p.volume,
        'wordGap': p.wordGap,
        'punctuation': p.punctuation,
        'capitalsMode': p.capitalsMode,
        'customPunctChars': p.punctChars,
      };

  Future<void> _playWindows(TtsPlayCommand cmd) async {
    Future<Uint8List>? prefetched;
    for (int i = cmd.startIndex; i < cmd.chunks.length; i++) {
      if (_activeSession != cmd.session) return;

      final current = prefetched ?? _synthWindows(cmd.chunks[i], cmd.params);
      prefetched = null;
      final wav = await current;
      if (_activeSession != cmd.session) return;

      // Start synthesizing the next sentence while this one is playing.
      if (i + 1 < cmd.chunks.length) {
        prefetched = _synthWindows(cmd.chunks[i + 1], cmd.params);
      }

      final durationMs = _wavDurationMs(wav);
      boot.mainPort.send(TtsChunkStartedEvent(cmd.session, i, durationMs));
      if (wav.length <= 44) {
        throw StateError('Speech engine produced no audio.');
      }

      _WinAudio.playMemory(wav);
      await _interruptibleDelay(Duration(milliseconds: durationMs + 15));
    }
  }

  Future<void> _interruptibleDelay(Duration d) {
    final wake = Completer<void>();
    _wake = wake;
    final timer = Timer(d, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(timer.cancel);
  }

  Future<void> _stopOutput() async {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
    if (Platform.isWindows) {
      _WinAudio.stop();
      try {
        _runningProcess?.kill();
      } catch (_) {}
      _runningProcess = null;
    } else if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('espeakStop');
      } catch (_) {}
    }
  }

  // ----------------------------------------------------------------- synthesis

  Future<void> _synthesizeAll(TtsSynthesizeCommand cmd) async {
    _activeSynthesis.add(cmd.requestId);
    try {
      final pcm = BytesBuilder(copy: false);
      int sampleRate = 22050;
      var completed = 0;
      for (final c in cmd.chunks) {
        Uint8List wav;
        if (Platform.isWindows) {
          wav = await _synthWindows(c, cmd.params);
        } else if (Platform.isAndroid) {
          final res = await _channel
              .invokeMethod<Uint8List>(
                'espeakSynthesizeToWav',
                _androidArgs(c, cmd.params),
              )
              .timeout(const Duration(seconds: 30));
          wav = res ?? Uint8List(0);
        } else {
          wav = Uint8List(0);
        }
        if (!_activeSynthesis.contains(cmd.requestId)) {
          boot.mainPort.send(TtsWavEvent(cmd.requestId, null));
          return;
        }
        if (wav.length <= 44) {
          throw StateError(
              'Speech segment ${completed + 1} could not be synthesized.');
        }
        if (wav.length > 44) {
          final sr =
              ByteData.sublistView(wav, 0, 44).getUint32(24, Endian.little);
          if (sr >= 8000 && sr <= 48000) sampleRate = sr;
          pcm.add(Uint8List.sublistView(wav, 44));
        }
        completed++;
        boot.mainPort.send(TtsSynthesisProgressEvent(
            cmd.requestId, completed, cmd.chunks.length));
      }
      final data = pcm.takeBytes();
      if (data.isEmpty) {
        boot.mainPort.send(TtsWavEvent(cmd.requestId, null));
        return;
      }
      final out = Uint8List(44 + data.length)
        ..setRange(0, 44, _wavHeader(data.length, sampleRate))
        ..setRange(44, 44 + data.length, data);
      boot.mainPort.send(
          TtsWavEvent(cmd.requestId, TransferableTypedData.fromList([out])));
    } catch (e) {
      if (_activeSynthesis.contains(cmd.requestId)) {
        boot.mainPort.send(TtsErrorEvent('Synthesis failed: $e'));
      }
      boot.mainPort.send(TtsWavEvent(cmd.requestId, null));
    } finally {
      _activeSynthesis.remove(cmd.requestId);
    }
  }

  Future<Uint8List> _synthWindows(TtsChunk c, TtsEngineParams p) async {
    final exe = boot.windowsExePath;
    if (exe == null) return Uint8List(0);
    final exeDir = File(exe).parent.path;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final txt = File('${Directory.systemTemp.path}\\scanora_ttsin_$stamp.txt');
    final wav = File('${Directory.systemTemp.path}\\scanora_ttsout_$stamp.wav');
    try {
      await txt.writeAsString(c.engineText, encoding: utf8, flush: true);
      final args = <String>[
        '-v',
        c.voiceSpec,
        '-s',
        '${p.rate}',
        '-p',
        '${p.pitch}',
        '-P',
        '${p.pitchRange}',
        '-a',
        '${p.volume}',
        '-g',
        '${p.wordGap}',
        '-b',
        '1',
        if (c.ssml) '-m',
        if (p.capitalsMode > 0) ...['-k', '${p.capitalsMode}'],
        if (p.punctuation == 1) '--punct',
        if (p.punctuation == 2 && p.punctChars.isNotEmpty)
          '--punct=${p.punctChars}',
        '-f',
        txt.path,
        '-w',
        wav.path,
      ];
      final proc = await Process.start(
        exe,
        args,
        workingDirectory: exeDir,
        environment: {'ESPEAK_DATA_PATH': boot.windowsDataPath ?? exeDir},
      );
      _runningProcess = proc;
      // Drain pipes so the child can never block on a full buffer.
      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.drain<void>());
      final code = await proc.exitCode.timeout(const Duration(seconds: 30),
          onTimeout: () {
        proc.kill();
        throw StateError('Speech synthesis timed out.');
      });
      _runningProcess = null;
      if (code == 0 && wav.existsSync()) return await wav.readAsBytes();
    } catch (_) {
      // Returned empty below; the caller skips silent chunks.
    } finally {
      try {
        if (txt.existsSync()) txt.deleteSync();
        if (wav.existsSync()) wav.deleteSync();
      } catch (_) {}
    }
    return Uint8List(0);
  }

  static int _wavDurationMs(Uint8List wav) {
    if (wav.length <= 44) return 0;
    final bd = ByteData.sublistView(wav, 0, 44);
    final sampleRate = bd.getUint32(24, Endian.little);
    final byteRate = bd.getUint32(28, Endian.little);
    if (sampleRate == 0 || byteRate == 0) return 0;
    return (((wav.length - 44) * 1000) / byteRate).round();
  }

  static Uint8List _wavHeader(int pcmLen, int sampleRate) {
    final bd = ByteData(44);
    void tag(int offset, String s) {
      for (int i = 0; i < 4; i++) {
        bd.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    bd.setUint32(4, pcmLen + 36, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, 1, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    bd.setUint32(40, pcmLen, Endian.little);
    return bd.buffer.asUint8List();
  }
}

/// Minimal winmm binding used to play a WAV that lives in memory.
class _WinAudio {
  static const int _sndAsync = 0x0001;
  static const int _sndNoDefault = 0x0002;
  static const int _sndMemory = 0x0004;

  static final DynamicLibrary _winmm = DynamicLibrary.open('winmm.dll');
  static final int Function(Pointer<Void>, int, int) _playSound =
      _winmm.lookupFunction<Int32 Function(Pointer<Void>, IntPtr, Uint32),
          int Function(Pointer<Void>, int, int)>('PlaySoundW');

  /// Buffer must stay valid while the sound plays; it is freed on the next call.
  static Pointer<Uint8>? _buffer;

  static void playMemory(Uint8List wav) {
    final fresh = calloc<Uint8>(wav.length);
    fresh.asTypedList(wav.length).setAll(0, wav);
    final played = _playSound(
        fresh.cast<Void>(), 0, _sndMemory | _sndAsync | _sndNoDefault);
    if (played == 0) {
      _playSound(nullptr, 0, 0);
      calloc.free(fresh);
      throw StateError('Windows could not play the generated speech audio.');
    }
    final old = _buffer;
    _buffer = fresh;
    if (old != null) calloc.free(old);
  }

  static void stop() {
    _playSound(nullptr, 0, 0);
    final old = _buffer;
    _buffer = null;
    if (old != null) calloc.free(old);
  }
}
