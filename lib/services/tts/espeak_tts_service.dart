import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../native_bridge_service.dart';
import '../ocr/camera_diagnostics.dart';
import '../settings_service.dart';
import 'espeak_voices.dart';
import 'tts_models.dart';
import 'tts_text_planner.dart';
import 'tts_worker.dart';
import 'tts_worker_protocol.dart';

export 'espeak_voices.dart' show EspeakVoiceOption;
export 'tts_models.dart' show TtsPlaybackState, TtsEngineStatus;

/// UI-isolate facade of the bundled eSpeak-NG engine.
///
/// It owns only lightweight state (play / pause / position). Synthesis and audio output
/// run in a separate background isolate ([ttsWorkerMain]); this class talks to it
/// through typed messages.
class EspeakTtsService {
  EspeakTtsService._();

  static const String engineVersion = '1.52.0';

  static List<EspeakVoiceOption> get supportedVoices => EspeakVoices.languages;
  static List<EspeakVoiceOption> get voiceVariants => EspeakVoices.variants;

  // ---------------------------------------------------------------- UI state
  static final ValueNotifier<bool> isSpeakingNotifier =
      ValueNotifier<bool>(false);
  static final ValueNotifier<TtsPlaybackState> playbackState =
      ValueNotifier<TtsPlaybackState>(const TtsPlaybackState());
  static final ValueNotifier<TtsEngineStatus> engineStatus =
      ValueNotifier<TtsEngineStatus>(TtsEngineStatus.starting);
  static final ValueNotifier<int> sessionCompletedTick = ValueNotifier<int>(0);
  static String _spokenText = '';
  static bool isPlayingText(String text) =>
      playbackState.value.isPlaying && _spokenText == text.trim();
  static bool isActiveText(String text) =>
      playbackState.value.isActive && _spokenText == text.trim();
  static String lastCompletedText = '';

  static bool get isSpeaking => _isSpeaking;
  static bool get isPaused => _isPaused;

  static List<TtsChunk> _chunks = const [];
  static int _currentChunkIdx = 0;
  static int _currentElapsedSec = 0;
  static int _totalDurationSec = 0;
  static String _title = '';
  static bool _isSpeaking = false;
  static bool _isPaused = false;
  static int _session = 0;
  static int _chunkDurationMs = 0;
  static int _chunkStartedAtMs = 0;
  static Timer? _progressTimer;
  static TtsEngineParams? _params;

  // ---------------------------------------------------------------- worker
  static Isolate? _isolate;
  static SendPort? _commandPort;
  static ReceivePort? _eventPort;
  static ReceivePort? _errorPort;
  static ReceivePort? _exitPort;
  static int _workerGeneration = 0;
  static Future<bool>? _starting;
  static int _requestSeq = 0;
  static final Map<int, Completer<Uint8List>> _wavRequests = {};
  static final Map<int, void Function(double)> _wavProgress = {};

  static void _failPendingSynthesis() {
    for (final request in _wavRequests.values) {
      if (!request.isCompleted) {
        request.completeError(StateError(
            'The speech engine stopped before audio export completed.'));
      }
    }
    _wavRequests.clear();
    _wavProgress.clear();
  }

  /// Starts the worker isolate (idempotent). Safe to call during app start-up.
  static Future<bool> ensureEngine() {
    if (_commandPort != null) {
      engineStatus.value = TtsEngineStatus.ready;
      return Future<bool>.value(true);
    }
    final pending = _starting;
    if (pending != null) return pending;
    late final Future<bool> next;
    next = _spawnWorker().whenComplete(() {
      if (identical(_starting, next)) _starting = null;
    });
    _starting = next;
    return next;
  }

  static Future<bool> _spawnWorker() async {
    final generation = ++_workerGeneration;
    engineStatus.value = TtsEngineStatus.starting;
    try {
      String? exe;
      String? data;
      if (Platform.isWindows) {
        exe = _findWindowsEspeakExe();
        if (exe == null) {
          engineStatus.value = TtsEngineStatus.error;
          return false;
        }
      } else if (Platform.isAndroid) {
        data = await NativeBridgeService.ensureEspeakDataExtracted();
      }
      if (generation != _workerGeneration) return false;

      final events = ReceivePort();
      final ready = Completer<SendPort>();
      events.listen((message) {
        if (generation != _workerGeneration) return;
        if (message is TtsReadyEvent) {
          if (!ready.isCompleted) ready.complete(message.commandPort);
        } else if (message is TtsEvent) {
          _onEvent(message);
        }
      });

      final errors = ReceivePort();
      _errorPort = errors;
      errors.listen((dynamic _) {
        if (generation != _workerGeneration) return;
        engineStatus.value = TtsEngineStatus.error;
        _failPendingSynthesis();
      });
      final exits = ReceivePort();
      _exitPort = exits;
      exits.listen((_) {
        if (generation != _workerGeneration) return;
        _commandPort = null;
        _isolate = null;
        _failPendingSynthesis();
        if (_isSpeaking) _resetPlaybackAfterEngineLoss();
      });

      _eventPort = events;
      final isolate = await Isolate.spawn<TtsWorkerBootstrap>(
        ttsWorkerMain,
        TtsWorkerBootstrap(
          mainPort: events.sendPort,
          rootToken: RootIsolateToken.instance,
          windowsExePath: exe,
          windowsDataPath: NativeBridgeService.espeakDataOverride,
          androidDataPath: data,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
        debugName: 'eSpeakNgWorker',
      );
      if (generation != _workerGeneration) {
        isolate.kill(priority: Isolate.immediate);
        return false;
      }
      _isolate = isolate;

      final commandPort =
          await ready.future.timeout(const Duration(seconds: 15));
      if (generation != _workerGeneration) return false;
      _commandPort = commandPort;
      engineStatus.value = TtsEngineStatus.ready;
      return true;
    } catch (_) {
      if (generation != _workerGeneration) return false;
      engineStatus.value = TtsEngineStatus.error;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _commandPort = null;
      return false;
    }
  }

  /// Stops everything and starts a fresh worker isolate.
  static Future<bool> restartEngine() async {
    await stop();
    _workerGeneration++;
    _failPendingSynthesis();
    final port = _commandPort;
    port?.send(const TtsShutdownCommand());
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _commandPort = null;
    _eventPort?.close();
    _eventPort = null;
    _errorPort?.close();
    _errorPort = null;
    _exitPort?.close();
    _exitPort = null;
    _starting = null;
    return ensureEngine();
  }

  static void _resetPlaybackAfterEngineLoss() {
    _isSpeaking = false;
    _isPaused = false;
    isSpeakingNotifier.value = false;
    _progressTimer?.cancel();
    _publish();
  }

  static void _onEvent(TtsEvent e) {
    switch (e) {
      case TtsReadyEvent():
        break;
      case TtsChunkStartedEvent():
        if (e.session != _session || !_isSpeaking) return;
        if (CameraDiagnostics.enabled) {
          CameraDiagnostics.event('tts.chunk.started', {
            'session': e.session,
            'chunk': e.index,
            'text': _chunks[e.index].displayText,
            'engineText': _chunks[e.index].engineText,
          });
        }
        _currentChunkIdx = e.index;
        _currentElapsedSec = _chunks[e.index].startSecond;
        _chunkDurationMs = e.durationMs > 0
            ? e.durationMs
            : _chunks[e.index].durationSeconds * 1000;
        _chunkStartedAtMs = DateTime.now().millisecondsSinceEpoch;
        _publish();
      case TtsSessionCompletedEvent():
        if (e.session != _session || !_isSpeaking) return;
        CameraDiagnostics.event('tts.completed', {'session': e.session});
        lastCompletedText = _spokenText;
        _isSpeaking = false;
        _isPaused = false;
        _currentChunkIdx = 0;
        _currentElapsedSec = 0;
        isSpeakingNotifier.value = false;
        _progressTimer?.cancel();
        _publish();
        sessionCompletedTick.value++;
      case TtsWavEvent():
        final c = _wavRequests.remove(e.requestId);
        if (c != null && !c.isCompleted) {
          c.complete(materializeWav(e) ?? Uint8List(0));
        }
      case TtsSynthesisProgressEvent():
        _wavProgress[e.requestId]
            ?.call(e.total == 0 ? 0 : e.completed / e.total);
      case TtsErrorEvent():
        debugPrint(e.message);
        engineStatus.value = TtsEngineStatus.error;
    }
  }

  // ---------------------------------------------------------------- helpers

  static TtsEngineParams _paramsFrom(SettingsService s,
      [TtsVoiceControls? controls]) {
    final punctuation = s.ttsPunctuation;
    return TtsEngineParams(
      rate: controls == null
          ? s.effectiveTtsRate
          : controls.rate * (controls.rateBoost ? ttsRateBoostMultiplier : 1),
      pitch: controls?.pitch ?? s.ttsPitch,
      pitchRange: controls?.pitchRange ?? s.ttsPitchRange,
      volume: controls?.volume ?? s.ttsVolume,
      wordGap: s.ttsWordGap,
      punctuation: punctuation.engineMode,
      punctChars: punctuation.characters,
      capitalsMode: s.ttsCapitalsMode,
    );
  }

  static List<TtsChunk> _plan(
      String text, SettingsService s, String? overrideVoice) {
    return TtsTextPlanner.plan(
      text,
      configuredVoice: overrideVoice ?? s.ttsVoice,
      variant: s.ttsVariant,
      bilingual: s.ttsAutoBilingual,
      digitByDigit: s.ttsDigitMode == 1,
      normalizeUnicode: s.ttsUnicodeNormalization,
      rateWpm: s.effectiveTtsRate,
    );
  }

  static String detectPrimaryLanguageCode(String text) =>
      TtsTextPlanner.detectPrimaryLanguageCode(text);

  static int estimateTotalSeconds(String text, int rateWpm) =>
      TtsTextPlanner.estimateSeconds(text, rateWpm);

  static void _publish() {
    final hasChunk = _chunks.isNotEmpty && _currentChunkIdx < _chunks.length;
    playbackState.value = TtsPlaybackState(
      isPlaying: _isSpeaking,
      isPaused: _isPaused,
      currentSeconds: _currentElapsedSec.clamp(0, _totalDurationSec),
      totalSeconds: _totalDurationSec,
      currentChunkIndex: _currentChunkIdx,
      totalChunks: _chunks.length,
      title: _title,
      currentChunkText: hasChunk ? _chunks[_currentChunkIdx].displayText : '',
      currentChunkDurationMs: _chunkDurationMs,
      currentChunkStartedAtMs: _chunkStartedAtMs,
    );
  }

  // ---------------------------------------------------------------- playback API

  /// Speaks [text] with the bundled eSpeak-NG voice (Play / Pause / Seek capable).
  static Future<void> speak(
    String text, {
    required SettingsService settings,
    String? overrideVoice,
    String title = '',
    bool forceSpeak = false,
    TtsVoiceControls? voiceControls,
  }) async {
    if (!forceSpeak && !settings.enableInternalTts) return;
    final cleaned = text.trim();
    if (cleaned.isEmpty) return;

    await stop();
    final chunks = _plan(cleaned, settings, overrideVoice);
    if (chunks.isEmpty) return;

    _chunks = chunks;
    _spokenText = cleaned;
    _params = _paramsFrom(settings, voiceControls);
    _currentChunkIdx = 0;
    _currentElapsedSec = 0;
    _totalDurationSec = chunks.last.startSecond + chunks.last.durationSeconds;
    _title = title;
    await _startFrom(0);
  }

  static Future<void> _startFrom(int chunkIndex) async {
    if (!await ensureEngine()) {
      _resetPlaybackAfterEngineLoss();
      return;
    }
    _isPaused = false;
    _isSpeaking = true;
    isSpeakingNotifier.value = true;
    _currentChunkIdx = chunkIndex;
    _currentElapsedSec = _chunks[chunkIndex].startSecond;
    _chunkDurationMs = _chunks[chunkIndex].durationSeconds * 1000;
    _chunkStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _session++;
    _startProgressTimer(_session);
    _publish();
    if (CameraDiagnostics.enabled) {
      CameraDiagnostics.event('tts.dispatch', {
        'session': _session,
        'chunk': chunkIndex,
        'text': _spokenText,
      });
    }
    _commandPort!.send(TtsPlayCommand(_session, _chunks, chunkIndex, _params!));
  }

  static void _startProgressTimer(int session) {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isSpeaking &&
          session == _session &&
          _currentElapsedSec < _totalDurationSec) {
        _currentElapsedSec++;
        _publish();
      }
    });
  }

  static Future<void> togglePlayPause(SettingsService settings) async {
    if (_chunks.isEmpty) return;
    if (_isSpeaking) {
      _session++;
      _isSpeaking = false;
      _isPaused = true;
      isSpeakingNotifier.value = false;
      _progressTimer?.cancel();
      _commandPort?.send(const TtsStopCommand());
      _publish();
    } else if (_isPaused) {
      await _startFrom(_currentChunkIdx);
    }
  }

  static Future<void> seekBySeconds(
      int deltaSeconds, SettingsService settings) async {
    if (_chunks.isEmpty) return;
    await seekToSecond(_currentElapsedSec + deltaSeconds, settings);
  }

  static Future<void> seekToSecond(
    int targetSecond,
    SettingsService settings, {
    String? fallbackText,
    String title = '',
  }) async {
    final cleaned = (fallbackText ?? '').trim();
    if (_chunks.isEmpty || (cleaned.isNotEmpty && cleaned != _spokenText)) {
      if (cleaned.isEmpty) return;
      final chunks = _plan(cleaned, settings, null);
      if (chunks.isEmpty) return;
      _chunks = chunks;
      _spokenText = cleaned;
      _params = _paramsFrom(settings);
      _totalDurationSec = chunks.last.startSecond + chunks.last.durationSeconds;
      _title = title;
      _isPaused = true;
      _isSpeaking = false;
      isSpeakingNotifier.value = false;
    }

    final wasPlaying = _isSpeaking;
    _session++;
    _progressTimer?.cancel();
    _commandPort?.send(const TtsStopCommand());

    final clamped = targetSecond.clamp(0, _totalDurationSec);
    int idx = 0;
    for (int i = 0; i < _chunks.length; i++) {
      if (clamped >= _chunks[i].startSecond) {
        idx = i;
      } else {
        break;
      }
    }
    _currentChunkIdx = idx;
    _currentElapsedSec = _chunks[idx].startSecond;
    _publish();
    if (wasPlaying) await _startFrom(idx);
  }

  /// Jumps to a chunk index (used by sentence-level reader navigation).
  static Future<void> seekToChunk(int index, SettingsService settings) async {
    if (_chunks.isEmpty) return;
    final i = index.clamp(0, _chunks.length - 1);
    await seekToSecond(_chunks[i].startSecond, settings);
  }

  /// Immediately stops speech and resets the position.
  static Future<void> stop() async {
    _session++;
    _isSpeaking = false;
    _isPaused = false;
    _currentChunkIdx = 0;
    _currentElapsedSec = 0;
    isSpeakingNotifier.value = false;
    _progressTimer?.cancel();
    _commandPort?.send(const TtsStopCommand());
    _publish();
  }

  /// Speaks a short sample so the user can judge the current voice settings.
  static String sampleText(SettingsService settings,
      {bool includePronunciationDemo = false}) {
    final isFa = settings.locale.languageCode == 'fa';
    final base = isFa
        ? 'این یک نمونه صدای اسکنورا است. متن شما آمادهٔ خواندن است.'
        : 'This is a sample of the Scanora voice. Your text is ready to be read.';
    final demo = includePronunciationDemo
        ? (isFa
            ? ' علامت‌ها: سلام! (۱۲۳۴) و نشانی ایمیل.'
            : ' Symbols: Hello! (1234) and test@example.com. Capital Letters.')
        : '';
    return '$base$demo';
  }

  static Future<void> speakSample(SettingsService settings,
          {bool includePronunciationDemo = false,
          TtsVoiceControls? voiceControls}) =>
      speak(
          sampleText(settings,
              includePronunciationDemo: includePronunciationDemo),
          settings: settings,
          forceSpeak: true,
          voiceControls: voiceControls);

  /// Synthesizes [text] (bilingual aware) into one WAV file in the worker isolate.
  static Future<Uint8List> synthesizeToWavBytes(
    String text, {
    required SettingsService settings,
    void Function(double progress)? onProgress,
    Future<void>? cancelled,
  }) async {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return Uint8List(0);
    if (!await ensureEngine()) {
      throw StateError('The speech engine is unavailable.');
    }
    final chunks = _plan(cleaned, settings, null);
    if (chunks.isEmpty) return Uint8List(0);

    final id = ++_requestSeq;
    final completer = Completer<Uint8List>();
    _wavRequests[id] = completer;
    if (onProgress != null) _wavProgress[id] = onProgress;
    onProgress?.call(0);
    _commandPort!.send(TtsSynthesizeCommand(id, chunks, _paramsFrom(settings)));
    cancelled?.then((_) {
      if (_wavRequests.containsKey(id)) {
        _commandPort?.send(TtsCancelSynthesisCommand(id));
      }
    });
    try {
      final result = await completer.future
          .timeout(Duration(seconds: 60 + chunks.length * 35));
      if (result.length <= 44) {
        throw StateError(
            'The speech engine did not produce a complete audio file.');
      }
      onProgress?.call(1.0);
      return result;
    } finally {
      _wavRequests.remove(id);
      _wavProgress.remove(id);
    }
  }

  static String? _findWindowsEspeakExe() {
    if (!Platform.isWindows) return null;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir\\espeak-ng\\espeak-ng.exe',
      '${Directory.current.path}\\Scanora-Windows\\espeak-ng\\espeak-ng.exe',
      '${Directory.current.path}\\espeak-ng\\espeak-ng.exe',
      r'C:\Program Files\eSpeak NG\espeak-ng.exe',
      r'C:\Program Files (x86)\eSpeak NG\espeak-ng.exe',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }
}
