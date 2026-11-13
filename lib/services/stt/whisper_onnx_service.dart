import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Result of offline speech-to-text transcription powered by `sherpa_onnx`.
class WhisperTranscriptionResult {
  final String text;
  final String language;
  final double durationSeconds;

  const WhisperTranscriptionResult({
    required this.text,
    required this.language,
    required this.durationSeconds,
  });

  bool get hasText => text.trim().isNotEmpty;
}

class _SherpaModelPaths {
  final String encoderPath;
  final String decoderPath;
  final String tokensPath;
  final String sileroVadPath;

  const _SherpaModelPaths({
    required this.encoderPath,
    required this.decoderPath,
    required this.tokensPath,
    required this.sileroVadPath,
  });
}

/// 100% Offline Bilingual (Persian + English) Speech-to-Text Engine powered by
/// **`sherpa_onnx`** (`OfflineRecognizer`, `OfflineModelConfig`, `OfflineWhisperModelConfig`)
/// with **`VoiceActivityDetector` (`SileroVadModelConfig`)** and **`Chunked Float32 Stream`**
/// processing inside a background Isolate.
class WhisperOnnxService {
  WhisperOnnxService._();

  static const String _encoderAsset = 'assets/models/whisper/encoder.int8.onnx';
  static const String _decoderAsset = 'assets/models/whisper/decoder.int8.onnx';
  static const String _tokensAsset = 'assets/models/whisper/tokens.txt';
  static const String _sileroVadAsset = 'assets/models/whisper/silero_vad.onnx';

  static final Map<bool, _SherpaModelPaths> _cachedPaths = {};
  static final Map<bool, Future<_SherpaModelPaths>> _loadingFutures = {};

  static AudioRecorder? _activeRecorder;
  static String? _activeRecordingPath;
  static StreamSubscription<Uint8List>? _pcmStreamSub;
  static final List<double> _liveChunkedFloat32Buffer = <double>[];

  static bool get isRecording => _activeRecorder != null;

  /// Extracts the bundled `sherpa_onnx` Whisper INT8 models and `silero_vad.onnx`
  /// to the application support directory and initializes `sherpa_onnx` bindings.
  static Future<void> ensureLoaded({bool accurate = true}) async {
    await _ensureModelPaths(accurate);
  }

  static Future<_SherpaModelPaths> _ensureModelPaths(bool accurate) {
    final cached = _cachedPaths[accurate];
    if (cached != null) return Future.value(cached);
    return _loadingFutures[accurate] ??=
        _extractModelsInternal(accurate).whenComplete(() {
      // Returning remove() here returns this same Future and waits on itself.
      _loadingFutures.remove(accurate);
    });
  }

  static void _initSherpaBindingsSafe() {
    try {
      if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final ortDll = File('$exeDir\\onnxruntime.dll');
        if (ortDll.existsSync()) {
          try {
            ffi.DynamicLibrary.open(ortDll.path);
          } catch (_) {}
          sherpa_onnx.initBindings(exeDir);
          return;
        }
      }
      sherpa_onnx.initBindings();
    } catch (e) {
      debugPrint('WhisperOnnxService initBindings warning: $e');
    }
  }

  static Future<_SherpaModelPaths> _extractModelsInternal(bool accurate) async {
    _initSherpaBindingsSafe();

    Directory baseDir;
    try {
      baseDir = await getApplicationSupportDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    final modelDir = Directory(
      '${baseDir.path}${Platform.pathSeparator}sherpa_whisper_${accurate ? 'small' : 'base'}_int8',
    );
    if (!modelDir.existsSync()) {
      modelDir.createSync(recursive: true);
    }

    Future<String> copyAssetIfNeeded(String assetPath, String fileName) async {
      final outFile = File(
        '${modelDir.path}${Platform.pathSeparator}$fileName',
      );
      final byteData = await rootBundle.load(assetPath);
      final expectedLen = byteData.lengthInBytes;
      if (!outFile.existsSync() || outFile.lengthSync() != expectedLen) {
        final bytes = byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
        await outFile.writeAsBytes(bytes, flush: true);
      }
      return outFile.path;
    }

    final results = <String>[
      await copyAssetIfNeeded(
          accurate
              ? 'assets/models/whisper_small/encoder.int8.onnx'
              : _encoderAsset,
          'encoder.int8.onnx'),
      await copyAssetIfNeeded(
          accurate
              ? 'assets/models/whisper_small/decoder.int8.onnx'
              : _decoderAsset,
          'decoder.int8.onnx'),
      await copyAssetIfNeeded(_tokensAsset, 'tokens.txt'),
      await copyAssetIfNeeded(_sileroVadAsset, 'silero_vad.onnx'),
    ];

    final paths = _SherpaModelPaths(
      encoderPath: results[0],
      decoderPath: results[1],
      tokensPath: results[2],
      sileroVadPath: results[3],
    );
    _cachedPaths[accurate] = paths;
    return paths;
  }

  /// Starts recording 16 kHz mono audio from the device microphone as a
  /// 16 kHz mono WAV file or **Chunked Float32 Stream**.
  static Future<bool> startMicrophoneRecording() async {
    await stopMicrophoneRecording(deleteTemp: true);
    _liveChunkedFloat32Buffer.clear();

    AudioRecorder recorder = AudioRecorder();
    try {
      final hasPerm = await recorder.hasPermission();
      if (!hasPerm) {
        await recorder.dispose();
        return false;
      }
    } catch (e) {
      debugPrint('WhisperOnnxService permission check warning: $e');
    }

    // Primary cross-platform recording (Windows + Android): 16 kHz mono WAV file
    try {
      Directory tempDir;
      try {
        tempDir = await getTemporaryDirectory();
      } catch (_) {
        tempDir = Directory.systemTemp;
      }
      final outPath =
          '${tempDir.path}${Platform.pathSeparator}scanora_voice_${DateTime.now().millisecondsSinceEpoch}.wav';

      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
        ),
        path: outPath,
      );

      _activeRecorder = recorder;
      _activeRecordingPath = outPath;
      return true;
    } catch (wavErr) {
      debugPrint(
          'WhisperOnnxService WAV start fallback to PCM stream: $wavErr');
      try {
        await recorder.dispose();
      } catch (_) {}
      recorder = AudioRecorder();
      try {
        final pcmStream = await recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
          ),
        );
        _pcmStreamSub = pcmStream.listen(
          (Uint8List pcmBytes) {
            if (pcmBytes.length < 2) return;
            final bd = ByteData.sublistView(pcmBytes);
            final sampleCount = pcmBytes.length ~/ 2;
            for (int i = 0; i < sampleCount; i++) {
              final s = bd.getInt16(i * 2, Endian.little);
              _liveChunkedFloat32Buffer.add((s / 32768.0).clamp(-1.0, 1.0));
            }
          },
          onError: (Object err) {
            debugPrint('WhisperOnnxService PCM stream error: $err');
          },
        );
        _activeRecorder = recorder;
        _activeRecordingPath = null;
        return true;
      } catch (streamErr) {
        debugPrint('WhisperOnnxService PCM stream start failed: $streamErr');
        try {
          await recorder.dispose();
        } catch (_) {}
        return false;
      }
    }
  }

  /// Stops active microphone recording and returns the recorded 16 kHz mono WAV bytes.
  static Future<Uint8List?> stopMicrophoneRecording({
    bool deleteTemp = true,
  }) async {
    final recorder = _activeRecorder;
    final recordedPath = _activeRecordingPath;
    final streamSub = _pcmStreamSub;
    _activeRecorder = null;
    _activeRecordingPath = null;
    _pcmStreamSub = null;

    if (recorder == null) return null;

    try {
      if (streamSub != null) {
        await streamSub.cancel();
      }
      final stoppedPath = await recorder.stop();
      await recorder.dispose();

      if (_liveChunkedFloat32Buffer.isNotEmpty) {
        final floatSamples = Float32List.fromList(_liveChunkedFloat32Buffer);
        _liveChunkedFloat32Buffer.clear();
        return _encodeFloat32AsWav16k(floatSamples);
      }

      final finalPath = stoppedPath ?? recordedPath;
      if (finalPath == null) return null;

      final file = File(finalPath);
      if (!file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (deleteTemp) {
        try {
          await file.delete();
        } catch (_) {}
      }
      return bytes;
    } catch (e) {
      debugPrint('WhisperOnnxService stopMicrophoneRecording error: $e');
      try {
        await recorder.dispose();
      } catch (_) {}
      _liveChunkedFloat32Buffer.clear();
      return null;
    }
  }

  /// Transcribes an audio file on disk (`.wav`) using `sherpa_onnx` (`OfflineRecognizer` + `VoiceActivityDetector`).
  static Future<WhisperTranscriptionResult> transcribeAudioFile(
    String filePath, {
    String? preferredLanguage,
    bool accurate = true,
    void Function(int percent)? onProgress,
    void Function(String partialText)? onPartialResult,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return const WhisperTranscriptionResult(
        text: '',
        language: 'fa',
        durationSeconds: 0,
      );
    }
    final bytes = await file.readAsBytes();
    return transcribeWavBytes(
      bytes,
      preferredLanguage: preferredLanguage,
      accurate: accurate,
      onProgress: onProgress,
      onPartialResult: onPartialResult,
    );
  }

  /// Transcribes raw WAV bytes in a background Isolate using `sherpa_onnx`
  /// (`VoiceActivityDetector` with `SileroVadModelConfig` + `OfflineRecognizer` with `OfflineWhisperModelConfig`).
  static Future<WhisperTranscriptionResult> transcribeWavBytes(
    Uint8List wavBytes, {
    String? preferredLanguage,
    bool accurate = true,
    void Function(int percent)? onProgress,
    void Function(String partialText)? onPartialResult,
  }) async {
    if (wavBytes.length < 44 ||
        String.fromCharCodes(wavBytes.take(4)) != 'RIFF' ||
        String.fromCharCodes(wavBytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException(
          'Unsupported audio format. Select a PCM or float WAV file.');
    }
    final samples16k = await Isolate.run(
      () => _decodeAudioTo16kMonoFloat32(wavBytes),
    );
    if (samples16k.isEmpty || !hasAudibleSignal(samples16k)) {
      return const WhisperTranscriptionResult(
        text: '',
        language: 'fa',
        durationSeconds: 0,
      );
    }

    final paths = await _ensureModelPaths(accurate);
    return _runSherpaWhisperWithVadInIsolate(
      samples16k: samples16k,
      paths: paths,
      preferredLanguage: preferredLanguage,
      onProgress: onProgress,
      onPartialResult: onPartialResult,
    );
  }

  static Future<WhisperTranscriptionResult> _runSherpaWhisperWithVadInIsolate({
    required Float32List samples16k,
    required _SherpaModelPaths paths,
    String? preferredLanguage,
    void Function(int percent)? onProgress,
    void Function(String partialText)? onPartialResult,
  }) async {
    final progress = ReceivePort();
    final subscription =
        progress.listen((value) => onProgress?.call(value as int));
    try {
      onProgress?.call(0);
      final result = await _decodeWhisper(
          samples16k, paths, preferredLanguage, progress.sendPort);
      if (result.$1.isNotEmpty) onPartialResult?.call(result.$1);
      onProgress?.call(100);
      return WhisperTranscriptionResult(
          text: result.$1,
          language: result.$2,
          durationSeconds: samples16k.length / 16000.0);
    } finally {
      await subscription.cancel();
      progress.close();
    }
  }

  static Future<(String, String)> _decodeWhisper(
          Float32List samples16k,
          _SherpaModelPaths paths,
          String? preferredLanguage,
          SendPort progress) =>
      Isolate.run<(String, String)>(() {
        // Every isolate has its own FFI binding state in sherpa_onnx; preload local ORT 1.28 on Windows
        _initSherpaBindingsSafe();

        final speechSegments = <Float32List>[];
        const int maxSingleWindowSamples = 16000 * 26;
        final automaticLanguage =
            preferredLanguage != 'fa' && preferredLanguage != 'en';

        if (samples16k.length <= maxSingleWindowSamples && !automaticLanguage) {
          // For recordings <= 26 seconds, keep the full continuous utterance intact
          // (only trimming leading/trailing dead silence with 0.35s pre-pad and 0.60s post-pad)
          // so Whisper has full sentence context for Persian morphology and grammar.
          speechSegments.add(_trimAndPadUtterance(samples16k));
        } else {
          // For longer recordings (> 26s), run Silero VAD with conservative pause thresholds
          // and merge consecutive segments into ~24s windows so sentences are not chopped mid-phrase.
          final rawSegments = <Float32List>[];
          var vadSucceeded = false;
          try {
            final sileroVad = sherpa_onnx.SileroVadModelConfig(
              model: paths.sileroVadPath,
              threshold: 0.35,
              minSilenceDuration: automaticLanguage ? 0.45 : 0.80,
              minSpeechDuration: 0.20,
              windowSize: 512,
              maxSpeechDuration: automaticLanguage ? 12.0 : 24.0,
            );
            final vadConfig = sherpa_onnx.VadModelConfig(
              sileroVad: sileroVad,
              sampleRate: 16000,
              numThreads: 2,
              provider: 'cpu',
              debug: false,
            );
            final vad = sherpa_onnx.VoiceActivityDetector(
              config: vadConfig,
              bufferSizeInSeconds: 120.0,
            );

            const int windowSize = 512;
            for (int offset = 0;
                offset < samples16k.length;
                offset += windowSize) {
              final end = math.min(offset + windowSize, samples16k.length);
              final chunk = Float32List(windowSize);
              for (int i = 0; i < end - offset; i++) {
                chunk[i] = samples16k[offset + i];
              }
              vad.acceptWaveform(chunk);
              while (!vad.isEmpty()) {
                final segment = vad.front();
                vad.pop();
                if (segment.samples.isNotEmpty) {
                  rawSegments.add(segment.samples);
                }
              }
            }

            vad.flush();
            while (!vad.isEmpty()) {
              final segment = vad.front();
              vad.pop();
              if (segment.samples.isNotEmpty) {
                rawSegments.add(segment.samples);
              }
            }
            vad.free();
            vadSucceeded = true;
          } catch (_) {}

          if (vadSucceeded && rawSegments.isEmpty) {
            return ('', preferredLanguage ?? '');
          }
          if (rawSegments.isNotEmpty) {
            if (automaticLanguage) {
              // Decode each utterance with automatic language detection so a
              // Persian sentence does not force the following English sentence.
              speechSegments.addAll(rawSegments.map(_trimAndPadUtterance));
            } else {
              const int targetChunkSamples = 16000 * 24;
              const int gapPauseSamples =
                  16000 ~/ 4; // 250ms natural pause between merged segments
              final currentChunk = <double>[];
              for (final seg in rawSegments) {
                if (currentChunk.isNotEmpty &&
                    currentChunk.length + gapPauseSamples + seg.length >
                        targetChunkSamples) {
                  speechSegments.add(
                      _trimAndPadUtterance(Float32List.fromList(currentChunk)));
                  currentChunk.clear();
                }
                if (currentChunk.isNotEmpty) {
                  for (int i = 0; i < gapPauseSamples; i++) {
                    currentChunk.add(0.0);
                  }
                }
                currentChunk.addAll(seg);
              }
              if (currentChunk.isNotEmpty) {
                speechSegments.add(
                    _trimAndPadUtterance(Float32List.fromList(currentChunk)));
              }
            }
          }
        }

        // If still empty, slice in <= 25s chunks
        if (speechSegments.isEmpty) {
          const int maxSamplesPerChunk = 16000 * 25;
          for (int offset = 0;
              offset < samples16k.length;
              offset += maxSamplesPerChunk) {
            final end =
                math.min(offset + maxSamplesPerChunk, samples16k.length);
            speechSegments
                .add(_trimAndPadUtterance(samples16k.sublist(offset, end)));
          }
        }

        // 2. Configure sherpa_onnx OfflineRecognizer with OfflineWhisperModelConfig
        // Supports Persian ('fa'), English ('en'), or automatic bilingual detection ('')
        final String whisperLanguage =
            (preferredLanguage == 'fa' || preferredLanguage == 'en')
                ? preferredLanguage!
                : '';

        sherpa_onnx.OfflineRecognizer buildRecognizer(String langCode) {
          final whisperConfig = sherpa_onnx.OfflineWhisperModelConfig(
            encoder: paths.encoderPath,
            decoder: paths.decoderPath,
            language: langCode,
            task: 'transcribe',
            tailPaddings: 1200,
          );
          final modelConfig = sherpa_onnx.OfflineModelConfig(
            whisper: whisperConfig,
            tokens: paths.tokensPath,
            modelType: 'whisper',
            numThreads: 4,
            provider: 'cpu',
            debug: false,
          );
          return sherpa_onnx.OfflineRecognizer(
            sherpa_onnx.OfflineRecognizerConfig(model: modelConfig),
          );
        }

        final recognizer = buildRecognizer(whisperLanguage);
        sherpa_onnx.OfflineRecognizer? faFallbackRecognizer;
        final buffer = StringBuffer();
        String detectedLang =
            whisperLanguage.isNotEmpty ? whisperLanguage : 'fa';

        var completedSegments = 0;
        try {
          const int maxWhisperWindow =
              16000 * 28; // Safe 28s limit per Whisper stream
          for (final segment in speechSegments) {
            for (int subOffset = 0;
                subOffset < segment.length;
                subOffset += maxWhisperWindow) {
              final subEnd = math.min(
                subOffset + maxWhisperWindow,
                segment.length,
              );
              final subSamples = (subOffset == 0 && subEnd == segment.length)
                  ? segment
                  : segment.sublist(subOffset, subEnd);

              final stream = recognizer.createStream();
              try {
                stream.acceptWaveform(samples: subSamples, sampleRate: 16000);
                recognizer.decode(stream);
                final res = recognizer.getResult(stream);
                String segText = _cleanWhisperOutput(res.text);
                String segLang =
                    res.lang.trim().replaceAll('<|', '').replaceAll('|>', '');

                // If language was auto-detected as Arabic/Urdu/Pashto/etc. (common Whisper confusion for Persian)
                // or if English mode produced a foreign-language placeholder, re-decode explicitly with Persian ('fa').
                final bool confusedPersianWithRelatedScript =
                    whisperLanguage.isEmpty &&
                        segLang.isNotEmpty &&
                        segLang != 'fa' &&
                        segLang != 'en';
                final bool needsFaRetry = confusedPersianWithRelatedScript ||
                    (whisperLanguage != 'fa' &&
                        (segText.isEmpty ||
                            segText
                                .toLowerCase()
                                .contains('foreign language') ||
                            segText.toLowerCase().contains('speaking in')));

                if (needsFaRetry) {
                  faFallbackRecognizer ??= buildRecognizer('fa');
                  final faStream = faFallbackRecognizer.createStream();
                  try {
                    faStream.acceptWaveform(
                        samples: subSamples, sampleRate: 16000);
                    faFallbackRecognizer.decode(faStream);
                    final faRes = faFallbackRecognizer.getResult(faStream);
                    final faCleaned = _cleanWhisperOutput(faRes.text);
                    if (faCleaned.isNotEmpty) {
                      segText = faCleaned;
                      segLang = 'fa';
                    }
                  } finally {
                    faStream.free();
                  }
                }

                if (segText.isNotEmpty) {
                  if (buffer.isNotEmpty) buffer.write(' ');
                  buffer.write(segText);
                }
                if (segLang.isNotEmpty) {
                  detectedLang = segLang;
                }
              } finally {
                stream.free();
              }
            }
            completedSegments++;
            progress.send(
                (completedSegments * 100 / speechSegments.length).round());
          }
        } finally {
          recognizer.free();
          faFallbackRecognizer?.free();
        }

        return (_normalizePersianText(buffer.toString().trim()), detectedLang);
      });

  @visibleForTesting
  static bool hasAudibleSignal(Float32List samples) {
    if (samples.isEmpty) return false;
    var energy = 0.0, peak = 0.0;
    for (final sample in samples) {
      energy += sample * sample;
      peak = math.max(peak, sample.abs());
    }
    return math.sqrt(energy / samples.length) >= 0.002 || peak >= 0.02;
  }

  static Uint8List _encodeFloat32AsWav16k(Float32List samples) {
    final int numSamples = samples.length;
    final int dataBytes = numSamples * 2;
    final int totalBytes = 44 + dataBytes;
    final out = ByteData(totalBytes);

    // RIFF header
    out.setUint8(0, 0x52); // 'R'
    out.setUint8(1, 0x49); // 'I'
    out.setUint8(2, 0x46); // 'F'
    out.setUint8(3, 0x46); // 'F'
    out.setUint32(4, 36 + dataBytes, Endian.little);
    out.setUint8(8, 0x57); // 'W'
    out.setUint8(9, 0x41); // 'A'
    out.setUint8(10, 0x56); // 'V'
    out.setUint8(11, 0x45); // 'E'

    // fmt subchunk
    out.setUint8(12, 0x66); // 'f'
    out.setUint8(13, 0x6D); // 'm'
    out.setUint8(14, 0x74); // 't'
    out.setUint8(15, 0x20); // ' '
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little); // PCM = 1
    out.setUint16(22, 1, Endian.little); // Mono = 1
    out.setUint32(24, 16000, Endian.little);
    out.setUint32(28, 32000, Endian.little);
    out.setUint16(32, 2, Endian.little);
    out.setUint16(34, 16, Endian.little);

    // data subchunk
    out.setUint8(36, 0x64); // 'd'
    out.setUint8(37, 0x61); // 'a'
    out.setUint8(38, 0x74); // 't'
    out.setUint8(39, 0x61); // 'a'
    out.setUint32(40, dataBytes, Endian.little);

    for (int i = 0; i < numSamples; i++) {
      final s = (samples[i].clamp(-1.0, 1.0) * 32767.0).round().clamp(
            -32768,
            32767,
          );
      out.setInt16(44 + i * 2, s, Endian.little);
    }
    return out.buffer.asUint8List();
  }

  /// Decodes standard PCM 16-bit / 24-bit / 32-bit / Float32 WAV files and resamples to 16 kHz mono Float32 [-1.0, 1.0].
  static Float32List _decodeAudioTo16kMonoFloat32(Uint8List bytes) {
    if (bytes.length < 44) return Float32List(0);
    final bd = ByteData.sublistView(bytes);

    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    final wave = String.fromCharCodes(bytes.sublist(8, 12));
    if (riff != 'RIFF' || wave != 'WAVE') {
      final count = bytes.length ~/ 2;
      final out = Float32List(count);
      for (int i = 0; i < count; i++) {
        out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      return out;
    }

    int audioFormat = 1;
    int numChannels = 1;
    int sampleRate = 16000;
    int bitsPerSample = 16;
    int dataOffset = -1;
    int dataSize = 0;

    int offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = bd.getUint32(offset + 4, Endian.little);
      final chunkDataStart = offset + 8;

      if (chunkId == 'fmt ' &&
          chunkSize >= 16 &&
          chunkDataStart + 16 <= bytes.length) {
        audioFormat = bd.getUint16(chunkDataStart, Endian.little);
        numChannels =
            math.max(1, bd.getUint16(chunkDataStart + 2, Endian.little));
        sampleRate =
            math.max(1000, bd.getUint32(chunkDataStart + 4, Endian.little));
        bitsPerSample = bd.getUint16(chunkDataStart + 14, Endian.little);
        if (audioFormat == 0xFFFE &&
            chunkSize >= 40 &&
            chunkDataStart + 40 <= bytes.length) {
          audioFormat = bd.getUint16(chunkDataStart + 24, Endian.little);
        }
      } else if (chunkId == 'data') {
        dataOffset = chunkDataStart;
        dataSize = math.min(chunkSize, bytes.length - chunkDataStart);
        break;
      }

      offset = chunkDataStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }

    if (![1, 3].contains(audioFormat) ||
        (audioFormat == 3
            ? bitsPerSample != 32
            : ![8, 16, 24, 32].contains(bitsPerSample))) {
      throw const FormatException(
          'Unsupported WAV codec. Use PCM or float32 WAV.');
    }
    if (dataOffset < 0 || dataSize <= 0) return Float32List(0);

    final bytesPerSample = math.max(1, bitsPerSample ~/ 8);
    final frameSize = bytesPerSample * numChannels;
    final numFrames = dataSize ~/ frameSize;
    if (numFrames <= 0) return Float32List(0);

    final mono = Float32List(numFrames);
    for (int f = 0; f < numFrames; f++) {
      final framePos = dataOffset + f * frameSize;
      double sum = 0.0;
      for (int c = 0; c < numChannels; c++) {
        final samplePos = framePos + c * bytesPerSample;
        double sampleVal = 0.0;
        if (audioFormat == 3 && bitsPerSample == 32) {
          sampleVal = bd.getFloat32(samplePos, Endian.little);
        } else if (bitsPerSample == 16) {
          sampleVal = bd.getInt16(samplePos, Endian.little) / 32768.0;
        } else if (bitsPerSample == 24) {
          int b0 = bytes[samplePos];
          int b1 = bytes[samplePos + 1];
          int b2 = bytes[samplePos + 2];
          int val = b0 | (b1 << 8) | (b2 << 16);
          if ((val & 0x800000) != 0) val |= ~0xFFFFFF;
          sampleVal = val / 8388608.0;
        } else if (bitsPerSample == 32) {
          sampleVal = bd.getInt32(samplePos, Endian.little) / 2147483648.0;
        } else if (bitsPerSample == 8) {
          sampleVal = (bytes[samplePos] - 128) / 128.0;
        }
        sum += sampleVal;
      }
      mono[f] = (sum / numChannels).clamp(-1.0, 1.0);
    }

    if (sampleRate == 16000) return _normalizeAudioGain16k(mono);

    // Linear interpolation resample to 16000 Hz
    final outLength = ((numFrames * 16000.0) / sampleRate).round();
    if (outLength <= 0) return Float32List(0);
    final resampled = Float32List(outLength);
    final ratio = sampleRate / 16000.0;
    for (int i = 0; i < outLength; i++) {
      final srcIdx = i * ratio;
      final idx0 = srcIdx.floor().clamp(0, numFrames - 1);
      final idx1 = math.min(idx0 + 1, numFrames - 1);
      final frac = srcIdx - idx0;
      resampled[i] = (mono[idx0] * (1.0 - frac) + mono[idx1] * frac).clamp(
        -1.0,
        1.0,
      );
    }
    return _normalizeAudioGain16k(resampled);
  }

  /// Removes DC offset and normalizes peak amplitude to ~0.88 so quiet microphones
  /// on laptops and phones have full dynamic range for Persian consonants in Whisper.
  static Float32List _normalizeAudioGain16k(Float32List input) {
    if (input.isEmpty) return input;
    double sum = 0.0;
    for (int i = 0; i < input.length; i++) {
      sum += input[i];
    }
    final dcOffset = sum / input.length;

    // Skip the first 80ms (1280 samples) when measuring peak to avoid mic click transients
    final startMeasure = input.length > 3200 ? 1280 : 0;
    double peak = 0.0;
    for (int i = startMeasure; i < input.length; i++) {
      final absVal = (input[i] - dcOffset).abs();
      if (absVal > peak) peak = absVal;
    }

    final gain =
        (peak > 0.004 && peak < 0.85) ? (0.88 / peak).clamp(1.0, 18.0) : 1.0;

    final out = Float32List(input.length);
    for (int i = 0; i < input.length; i++) {
      out[i] = ((input[i] - dcOffset) * gain).clamp(-0.98, 0.98);
    }
    return out;
  }

  /// Trims leading and trailing dead air (`|s| < 0.015`) while adding 0.35s leading
  /// silence and 0.60s trailing silence so Whisper never clips initial/final Persian phonemes.
  static Float32List _trimAndPadUtterance(Float32List samples) {
    if (samples.isEmpty) return samples;
    const double threshold = 0.015;
    int firstActive = 0;
    while (firstActive < samples.length &&
        samples[firstActive].abs() < threshold) {
      firstActive++;
    }
    if (firstActive >= samples.length) {
      return samples;
    }
    int lastActive = samples.length - 1;
    while (lastActive > firstActive && samples[lastActive].abs() < threshold) {
      lastActive--;
    }

    const int prePad = 5600; // 0.35s at 16kHz
    const int postPad = 9600; // 0.60s at 16kHz
    final int startIdx = math.max(0, firstActive - prePad);
    final int endIdx = math.min(samples.length, lastActive + 1 + postPad);
    final int coreLen = endIdx - startIdx;
    final int extraLead = startIdx == 0 ? math.max(0, prePad - firstActive) : 0;
    final int extraTrail = endIdx == samples.length
        ? math.max(0, postPad - (samples.length - 1 - lastActive))
        : 0;

    final padded = Float32List(extraLead + coreLen + extraTrail);
    for (int i = 0; i < coreLen; i++) {
      padded[extraLead + i] = samples[startIdx + i];
    }
    return padded;
  }

  static String _cleanWhisperOutput(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    // Strip common Whisper non-speech hallucinations on silence
    final noisePatterns = <RegExp>[
      RegExp(r'\[BLANK_AUDIO\]', caseSensitive: false),
      RegExp(r'\[Music\]', caseSensitive: false),
      RegExp(r'\[Applause\]', caseSensitive: false),
      RegExp(r'\(Music\)', caseSensitive: false),
      RegExp(r'\(موسیقی\)'),
      RegExp(r'\[موسیقی\]'),
    ];
    for (final p in noisePatterns) {
      s = s.replaceAll(p, '');
    }
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _normalizePersianText(String text) {
    if (text.isEmpty) return text;
    return text
        .replaceAll('\u064A', '\u06CC') // Arabic Yeh -> Persian Yeh
        .replaceAll('\u0649', '\u06CC') // Alef Maksura -> Persian Yeh
        .replaceAll('\u0643', '\u06A9') // Arabic Kaf -> Persian Keheh
        .trim();
  }
}
