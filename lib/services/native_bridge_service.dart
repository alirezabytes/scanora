import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'ocr/reading_layout.dart';
import 'ocr/camera_scene_ocr.dart' show CameraTextEdge;

typedef _FindWindowWNative = ffi.IntPtr Function(
    ffi.Pointer<Utf16> lpClassName, ffi.Pointer<Utf16> lpWindowName);
typedef _FindWindowWDart = int Function(
    ffi.Pointer<Utf16> lpClassName, ffi.Pointer<Utf16> lpWindowName);

typedef _ShowWindowNative = ffi.Int32 Function(
    ffi.IntPtr hWnd, ffi.Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);

typedef _SetForegroundWindowNative = ffi.Int32 Function(ffi.IntPtr hWnd);
typedef _SetForegroundWindowDart = int Function(int hWnd);

typedef _KeybdEventNative = ffi.Void Function(
    ffi.Uint8 bVk, ffi.Uint8 bScan, ffi.Uint32 dwFlags, ffi.IntPtr dwExtraInfo);
typedef _KeybdEventDart = void Function(
    int bVk, int bScan, int dwFlags, int dwExtraInfo);

class TesseractRead {
  final String text;
  final double confidence;
  final int? detectedTextRegions;
  final List<ReadingLayoutLine> lines;
  final List<double> lineConfidences;
  final CameraTextEdge? clippedEdge;
  const TesseractRead(this.text, this.confidence,
      {this.detectedTextRegions,
      this.clippedEdge,
      this.lines = const [],
      this.lineConfidences = const []});
}

enum CameraAccessStatus { allowed, denied, blocked }

class NativeBridgeService {
  static const MethodChannel _channel = MethodChannel('com.scanora.app/native');
  static final Map<bool, String> _cachedTessDirs = {};
  static Future<CameraAccessStatus>? _cameraPermissionRequest;

  static Future<CameraAccessStatus> cameraPermission(
      {required bool request}) async {
    if (!Platform.isAndroid) return CameraAccessStatus.allowed;
    Future<CameraAccessStatus> check(bool prompt) async {
      final status = await _channel
          .invokeMethod<String>('cameraPermission', {'request': prompt});
      return CameraAccessStatus.values.byName(status ?? 'denied');
    }

    if (!request) return check(false);
    return _cameraPermissionRequest ??=
        check(true).whenComplete(() => _cameraPermissionRequest = null);
  }

  /// Exact byte sizes of the official `tessdata_best` models.
  static const int _fasBestBytes = 3325955;
  static const int _engBestBytes = 15400601;
  static String? _cachedEspeakParentDir;
  static void Function(Uint8List imageBytes, {String? sourceName})?
      onSharedImageReceived;
  static void Function()? onSharedFilesAvailable;
  static bool _listenerInitialized = false;

  static void initSharedImageListener() {
    if (_listenerInitialized) return;
    _listenerInitialized = true;

    if (Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onSharedFilesAvailable') {
          onSharedFilesAvailable?.call();
        }
        if (call.method == 'onSharedImage' && call.arguments != null) {
          final image = call.arguments as Map;
          final bytes = image['bytes'] as Uint8List;
          if (bytes.isNotEmpty && onSharedImageReceived != null) {
            onSharedImageReceived!(bytes, sourceName: image['name'] as String?);
          }
        }
      });
    }
  }

  static Future<List<List<String>>> takeSharedFiles() async {
    if (!Platform.isAndroid) return const [];
    final batches =
        await _channel.invokeListMethod<List<dynamic>>('takeSharedFiles');
    return [for (final batch in batches ?? const []) batch.cast<String>()];
  }

  static Future<void> releaseSharedFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    final root = await getTemporaryDirectory();
    final prefix = '${root.path}${Platform.pathSeparator}shared_documents'
        '${Platform.pathSeparator}';
    if (!paths.first.startsWith(prefix)) return;
    final id = paths.first.substring(prefix.length).split('/').first;
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) return;
    try {
      await Directory('$prefix$id').delete(recursive: true);
    } on FileSystemException {
      // Android may have reclaimed its cache already.
    }
  }

  /// Checks if the app was launched via Share Intent (Android) with an image
  static Future<({Uint8List bytes, String? name})?>
      getInitialSharedImage() async {
    if (Platform.isAndroid) {
      try {
        final image = await _channel
            .invokeMapMethod<String, dynamic>('getInitialSharedImage');
        final bytes = image?['bytes'] as Uint8List?;
        if (bytes != null && bytes.isNotEmpty) {
          return (bytes: bytes, name: image?['name'] as String?);
        }
      } catch (_) {}
    }
    return null;
  }

  /// Returns a stable hardware/OS device identifier for licensing/demo extensions
  static Future<String> getDeviceIdentifier() async {
    try {
      if (Platform.isAndroid) {
        final id = await _channel.invokeMethod<String>('getAndroidDeviceId');
        if (id != null && id.isNotEmpty) return id.toUpperCase();
      } else if (Platform.isWindows) {
        final host = Platform.localHostname;
        final user = Platform.environment['USERNAME'] ?? 'USER';
        return 'WIN-$host-$user'.toUpperCase();
      }
    } catch (_) {}
    return 'SCANORA-GENERIC-DEVICE';
  }

  /// Returns Android OS package `firstInstallTime` (epoch ms), which survives Clear Cache and Clear Data!
  static Future<int> getAndroidPackageFirstInstallTime() async {
    if (!Platform.isAndroid) return 0;
    try {
      final t = await _channel.invokeMethod<int>('getPackageFirstInstallTime');
      return t ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Saves encrypted license state to OS-persistent storage that survives Clear Cache and Clear Data
  static Future<void> savePersistentLicenseState(
      String fileName, String content) async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<bool>('savePersistentLicenseState', {
          'fileName': fileName,
          'content': content,
        });
      } else if (Platform.isWindows) {
        await Process.run(
          'reg',
          [
            'add',
            r'HKCU\Software\Classes\CLSID\{89A74C1E-5B29-4F02-A83C-9012E4B7C8D1}',
            '/v',
            'ConfigBlob',
            '/t',
            'REG_SZ',
            '/d',
            content,
            '/f',
          ],
        );
      }
    } catch (_) {}
  }

  /// Loads encrypted license state from OS-persistent storage (survives Clear Cache and Clear Data)
  static Future<String?> loadPersistentLicenseState(String fileName) async {
    try {
      if (Platform.isAndroid) {
        final res =
            await _channel.invokeMethod<String>('loadPersistentLicenseState', {
          'fileName': fileName,
        });
        if (res != null && res.trim().isNotEmpty) return res.trim();
      } else if (Platform.isWindows) {
        final res = await Process.run(
          'reg',
          [
            'query',
            r'HKCU\Software\Classes\CLSID\{89A74C1E-5B29-4F02-A83C-9012E4B7C8D1}',
            '/v',
            'ConfigBlob',
          ],
        );
        if (res.exitCode == 0) {
          final out = res.stdout.toString();
          final idx = out.indexOf('REG_SZ');
          if (idx != -1) {
            final val =
                out.substring(idx + 6).trim().split(RegExp(r'\s+')).first;
            if (val.isNotEmpty) return val;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Opens [url] in the system external browser on Windows or Android.
  static Future<bool> openUrlInBrowser(String url) async {
    try {
      if (Platform.isAndroid) {
        final ok = await _channel.invokeMethod<bool>('openUrlInBrowser', {
          'url': url,
        });
        return ok ?? false;
      } else if (Platform.isWindows) {
        final res = await Process.run('rundll32', [
          'url.dll,FileProtocolHandler',
          url,
        ]);
        if (res.exitCode == 0) return true;
        final fallback = await Process.run('explorer.exe', [url]);
        return fallback.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }

  /// Brings the Scanora application window to the foreground (Windows & Android),
  /// used after browser authorization completes so the user returns directly to Scanora.
  static Future<void> bringAppToFront() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<bool>('bringAppToFront');
      } else if (Platform.isWindows) {
        final user32 = ffi.DynamicLibrary.open('user32.dll');
        final findWindowW =
            user32.lookupFunction<_FindWindowWNative, _FindWindowWDart>(
                'FindWindowW');
        final showWindow = user32
            .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');
        final setForegroundWindow = user32.lookupFunction<
            _SetForegroundWindowNative,
            _SetForegroundWindowDart>('SetForegroundWindow');
        final bringWindowToTop = user32.lookupFunction<
            _SetForegroundWindowNative,
            _SetForegroundWindowDart>('BringWindowToTop');
        final keybdEvent = user32
            .lookupFunction<_KeybdEventNative, _KeybdEventDart>('keybd_event');

        final classNamePtr = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
        final titlePtr = 'Scanora'.toNativeUtf16();
        try {
          int hwnd = findWindowW(classNamePtr, titlePtr);
          if (hwnd == 0) {
            hwnd = findWindowW(ffi.nullptr, titlePtr);
          }
          if (hwnd != 0) {
            showWindow(hwnd, 9); // SW_RESTORE
            // Synthetic Alt keyup allows a background process to call SetForegroundWindow
            keybdEvent(0x12, 0, 0x0002, 0);
            setForegroundWindow(hwnd);
            bringWindowToTop(hwnd);
          }
        } finally {
          malloc.free(classNamePtr);
          malloc.free(titlePtr);
        }
      }
    } catch (_) {}
  }

  /// Plays the bundled `pageFlip.mp3` sound effect on Android or Windows
  static Future<void> playPageFlipSound() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<bool>('playPageFlipSound');
      } else if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidates = <String>[
          '$exeDir\\audio\\pageFlip.mp3',
          '$exeDir\\data\\flutter_assets\\assets\\audio\\pageFlip.mp3',
          '$exeDir\\data\\flutter_assets\\audio\\pageFlip.mp3',
          '${Directory.current.path}\\audio\\pageFlip.mp3',
          '${Directory.current.path}\\assets\\audio\\pageFlip.mp3',
        ];
        String? foundMp3;
        for (final p in candidates) {
          if (File(p).existsSync()) {
            foundMp3 = p;
            break;
          }
        }
        if (foundMp3 == null) {
          final tempMp3 =
              File('${Directory.systemTemp.path}\\scanora_pageFlip.mp3');
          if (!tempMp3.existsSync()) {
            final bd = await rootBundle.load('assets/audio/pageFlip.mp3');
            await tempMp3.writeAsBytes(
              bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
              flush: true,
            );
          }
          foundMp3 = tempMp3.path;
        }
        final escapedPath = foundMp3.replaceAll("'", "''");
        Process.start(
          'powershell',
          [
            '-NoProfile',
            '-WindowStyle',
            'Hidden',
            '-Command',
            "Add-Type -AssemblyName presentationCore; \$p = New-Object System.Windows.Media.MediaPlayer; \$p.Open([Uri]::new('$escapedPath')); \$p.Play(); Start-Sleep -Milliseconds 950",
          ],
        );
      }
    } catch (_) {}
  }

  static int _tempFileSeq = 0;
  static final Map<bool, Future<String>> _tessDataExtractFutures = {};

  /// Ensures `fas.traineddata` and `eng.traineddata` from `tessdata_best` (`assets/tessdata_best/`)
  /// are extracted into a local directory containing a `tessdata/` subfolder.
  static Future<String> ensureTessDataExtracted({bool fast = false}) {
    final cached = _cachedTessDirs[fast];
    final expectedFas = fast ? 431500 : _fasBestBytes;
    final expectedEng = fast ? 4113088 : _engBestBytes;

    if (cached != null) {
      final fasFile = File('$cached/tessdata/fas.traineddata');
      final engFile = File('$cached/tessdata/eng.traineddata');
      if (fasFile.existsSync() &&
          fasFile.lengthSync() == expectedFas &&
          engFile.existsSync() &&
          engFile.lengthSync() == expectedEng &&
          File('$cached/tessdata/osd.traineddata').existsSync()) {
        return Future<String>.value(cached);
      }
    }

    return _tessDataExtractFutures[fast] ??=
        _extractTessDataInternal(fast).whenComplete(
      () {
        _tessDataExtractFutures.remove(fast);
      },
    );
  }

  static Future<String> _extractTessDataInternal(bool fast) async {
    final expectedFas = fast ? 431500 : _fasBestBytes;
    final expectedEng = fast ? 4113088 : _engBestBytes;
    final assetFolder = fast ? 'assets/tessdata' : 'assets/tessdata_best';
    final subFolder = fast ? 'ocr_engine_fast' : 'ocr_engine';

    Directory supportDir;
    try {
      supportDir = await getApplicationSupportDirectory();
    } catch (_) {
      supportDir = Directory.systemTemp;
    }
    final baseDir = Directory(
      '${supportDir.path}${Platform.pathSeparator}$subFolder',
    );

    final tessDataDir = Directory('${baseDir.path}/tessdata');
    if (!tessDataDir.existsSync()) {
      tessDataDir.createSync(recursive: true);
    }

    final expectedSizes = <String, int>{
      'fas': expectedFas,
      'eng': expectedEng,
    };

    for (final entry in expectedSizes.entries) {
      final lang = entry.key;
      final expectedBytes = entry.value;
      final targetFile = File('${tessDataDir.path}/$lang.traineddata');
      if (!targetFile.existsSync() ||
          targetFile.lengthSync() != expectedBytes) {
        final byteData =
            await rootBundle.load('$assetFolder/$lang.traineddata');
        final bytes = byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        );
        final tmpFile = File(
          '${tessDataDir.path}/$lang.traineddata.tmp_${DateTime.now().microsecondsSinceEpoch}',
        );
        await tmpFile.writeAsBytes(bytes, flush: true);
        try {
          if (targetFile.existsSync()) {
            targetFile.deleteSync();
          }
          await tmpFile.rename(targetFile.path);
        } catch (_) {
          await targetFile.writeAsBytes(bytes, flush: true);
          try {
            if (tmpFile.existsSync()) tmpFile.deleteSync();
          } catch (_) {}
        }
      }
    }

    final osd = File('${tessDataDir.path}/osd.traineddata');
    final orientationData =
        await rootBundle.load('assets/tessdata/osd.traineddata');
    if (!osd.existsSync() ||
        osd.lengthSync() != orientationData.lengthInBytes) {
      await osd.writeAsBytes(
          orientationData.buffer.asUint8List(
              orientationData.offsetInBytes, orientationData.lengthInBytes),
          flush: true);
    }

    _cachedTessDirs[fast] = baseDir.path;
    return baseDir.path;
  }

  /// Ensures `assets/espeakdata.zip` is extracted on Android so `espeak-ng-data` is ready for JNI SpeechSynthesis.
  static Future<String> ensureEspeakDataExtracted() async {
    final custom = espeakDataOverride;
    if (custom != null && File('$custom/espeak-ng-data/phontab').existsSync()) {
      return custom;
    }
    if (_cachedEspeakParentDir != null) {
      final phontab = File('$_cachedEspeakParentDir/espeak-ng-data/phontab');
      if (phontab.existsSync()) {
        return _cachedEspeakParentDir!;
      }
    }

    Directory baseDir;
    if (Platform.isAndroid) {
      final dir = Directory('/data/user/0/com.scanora.app/files/espeak_engine');
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        baseDir = dir;
      } catch (_) {
        baseDir =
            Directory('${Directory.systemTemp.path}/scanora_espeak_engine');
      }
    } else {
      baseDir = Directory('${Directory.systemTemp.path}/scanora_espeak_engine');
    }

    final phontab = File('${baseDir.path}/espeak-ng-data/phontab');
    if (!phontab.existsSync()) {
      final byteData = await rootBundle.load('assets/espeakdata.zip');
      final zipBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final archive = ZipDecoder().decodeBytes(zipBytes);
      for (final file in archive) {
        final outPath = '${baseDir.path}/${file.name}';
        if (file.isFile) {
          final outFile = File(outPath);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(file.content as List<int>, flush: true);
        } else {
          Directory(outPath).createSync(recursive: true);
        }
      }
    }

    _cachedEspeakParentDir = baseDir.path;
    return baseDir.path;
  }

  /// Speaks text on Android via bundled eSpeak-NG JNI library
  static String? espeakDataOverride;

  static Future<bool> espeakSpeakAndroid({
    required String text,
    required String voice,
    required int rate,
    required int pitch,
    int pitchRange = 50,
    required int volume,
    required int wordGap,
    required int punctuation,
    int capitalsMode = 0,
    String customPunctChars = '',
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final dataPath = await ensureEspeakDataExtracted();
      final ok = await _channel.invokeMethod<bool>('espeakSpeak', {
        'dataPath': dataPath,
        'text': text,
        'voice': voice,
        'rate': rate,
        'pitch': pitch,
        'pitchRange': pitchRange,
        'volume': volume,
        'wordGap': wordGap,
        'punctuation': punctuation,
        'capitalsMode': capitalsMode,
        'customPunctChars': customPunctChars,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Stops ongoing Android eSpeak-NG speech immediately
  static Future<void> espeakStopAndroid() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('espeakStop');
    } catch (_) {}
  }

  /// Synthesizes text to WAV bytes on Android via bundled eSpeak-NG JNI library
  static Future<Uint8List> espeakSynthesizeToWavAndroid({
    required String text,
    required String voice,
    required int rate,
    required int pitch,
    int pitchRange = 50,
    required int volume,
    required int wordGap,
    required int punctuation,
    int capitalsMode = 0,
    String customPunctChars = '',
  }) async {
    if (!Platform.isAndroid) return Uint8List(0);
    try {
      final dataPath = await ensureEspeakDataExtracted();
      final wavBytes =
          await _channel.invokeMethod<Uint8List>('espeakSynthesizeToWav', {
        'dataPath': dataPath,
        'text': text,
        'voice': voice,
        'rate': rate,
        'pitch': pitch,
        'pitchRange': pitchRange,
        'volume': volume,
        'wordGap': wordGap,
        'punctuation': punctuation,
        'capitalsMode': capitalsMode,
        'customPunctChars': customPunctChars,
      });
      return wavBytes ?? Uint8List(0);
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// Runs Tesseract LSTM OCR (`tessdata_best` or `tessdata_fast` fas+eng) on Android via native C++ TessBaseAPI
  static Future<String> recognizeAndroidTesseract(
    Uint8List imageBytes, {
    String lang = 'fas+eng',
    int psm = 3,
    bool disableDictionary = false,
    String? charWhitelist,
    bool fast = false,
  }) async {
    return (await _readAndroidTesseract(
      imageBytes,
      lang: lang,
      psm: psm,
      disableDictionary: disableDictionary,
      charWhitelist: charWhitelist,
      fast: fast,
    ))
        .text;
  }

  static Future<TesseractRead> _readAndroidTesseract(
    Uint8List imageBytes, {
    required String lang,
    required int psm,
    bool disableDictionary = false,
    String? charWhitelist,
    bool fast = false,
    bool adaptiveThreshold = false,
    bool includeLayout = false,
  }) async {
    if (!Platform.isAndroid) return const TesseractRead('', 0);
    File? tempFile;
    try {
      final parent = await ensureTessDataExtracted(fast: fast);
      final seq = ++_tempFileSeq;
      tempFile = File(
          '${Directory.systemTemp.path}/scanora_tess_${DateTime.now().microsecondsSinceEpoch}_$seq.png');
      await tempFile.writeAsBytes(imageBytes);
      final result = await _channel.invokeMapMethod<String, dynamic>(
          'recognizeTextTesseractWithConfidence', {
        'imagePath': tempFile.path,
        'dataPath': parent,
        'language': lang,
        'pageSegMode': psm,
        'disableDictionary': disableDictionary,
        'charWhitelist': charWhitelist ?? '',
        'adaptiveThreshold': adaptiveThreshold,
        'includeLayout': includeLayout,
      });
      final lines = <ReadingLayoutLine>[];
      final confidences = <double>[];
      for (final item in (result?['lines'] as List?) ?? const []) {
        final line = item as Map;
        final bounds = (line['bounds'] as List).cast<int>();
        final rect = Rect.fromLTRB(bounds[0].toDouble(), bounds[1].toDouble(),
            bounds[2].toDouble(), bounds[3].toDouble());
        lines.add(
            (bounds: rect, text: line['text'] as String, size: rect.height));
        confidences.add((line['confidence'] as num?)?.toDouble() ?? 0);
      }
      return TesseractRead(
        (result?['text'] as String? ?? '').trim(),
        ((result?['confidence'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
        lines: lines,
        lineConfidences: confidences,
      );
    } catch (error) {
      throw StateError('Android OCR failed: $error');
    } finally {
      try {
        await tempFile?.delete();
      } catch (_) {}
    }
  }

  /// Detects human faces and their relative positions on Android using native android.media.FaceDetector
  static Future<List<Map<String, double>>> detectFacesAndroid(
      Uint8List imageBytes) async {
    if (!Platform.isAndroid) return const [];
    try {
      final rawList =
          await _channel.invokeMethod<List<dynamic>>('detectFaces', {
        'imageBytes': imageBytes,
      });
      if (rawList == null) return const [];
      final out = <Map<String, double>>[];
      for (final item in rawList) {
        if (item is Map) {
          out.add({
            'x': (item['x'] as num?)?.toDouble() ?? 0.5,
            'y': (item['y'] as num?)?.toDouble() ?? 0.5,
            'size': (item['size'] as num?)?.toDouble() ?? 0.15,
            'confidence': (item['confidence'] as num?)?.toDouble() ?? 0.5,
          });
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Runs bundled portable Tesseract LSTM (`tessdata_best` or `tessdata_fast` fas+eng) on Windows Desktop
  static Future<String> recognizeWindowsTesseract(
    Uint8List imageBytes, {
    String lang = 'fas+eng',
    int psm = 3,
    bool disableDictionary = false,
    String? charWhitelist,
    bool fast = false,
    bool outputTsv = false,
    bool adaptiveThreshold = false,
  }) async {
    if (!Platform.isWindows) return '';
    File? tempFile;
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidateExes = <String>[
        '$exeDir\\tesseract\\tesseract.exe',
        '${Directory.current.path}\\windows\\tesseract\\tesseract.exe',
        '${Directory.current.path}\\Scanora-Windows\\tesseract\\tesseract.exe',
        '${Directory.current.path}\\tesseract\\tesseract.exe',
        r'C:\Program Files\Tesseract-OCR\tesseract.exe',
        r'C:\Program Files (x86)\Tesseract-OCR\tesseract.exe',
      ];

      String? foundExe;
      for (final p in candidateExes) {
        if (File(p).existsSync()) {
          foundExe = p;
          break;
        }
      }
      if (foundExe == null) {
        throw StateError('Bundled Tesseract executable is missing.');
      }
      final extractedParent = await ensureTessDataExtracted(fast: fast);
      final tessDataDir = '$extractedParent\\tessdata';

      final seq = ++_tempFileSeq;
      final tempPath =
          '${Directory.systemTemp.path}\\scanora_wintess_${DateTime.now().microsecondsSinceEpoch}_$seq.png';
      tempFile = File(tempPath);
      await tempFile.writeAsBytes(imageBytes, flush: true);

      Future<String> runOnce(int mode) async {
        final args = <String>[
          tempFile!.path,
          'stdout',
          '--tessdata-dir',
          tessDataDir,
          '-l',
          lang,
          '--oem',
          '1',
          '--psm',
          mode.toString(),
          '--dpi',
          '300',
        ];
        if (disableDictionary) {
          args.addAll([
            '-c',
            'load_system_dawg=0',
            '-c',
            'load_freq_dawg=0',
          ]);
        }
        if (charWhitelist != null && charWhitelist.isNotEmpty) {
          args.addAll(['-c', 'tessedit_char_whitelist=$charWhitelist']);
        }
        if (adaptiveThreshold) {
          args.addAll(['-c', 'thresholding_method=2']);
        }
        if (outputTsv) {
          args.addAll(
              ['-c', 'tessedit_create_tsv=1', '-c', 'tessedit_create_txt=0']);
        }

        final process = await Process.start(
          foundExe!,
          args,
          environment: {'OMP_THREAD_LIMIT': '2'},
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        final exitCode = await process.exitCode.timeout(
          Duration(seconds: fast ? 15 : 60),
          onTimeout: () {
            process.kill();
            throw StateError('OCR timed out.');
          },
        );
        final stderr = await errors;
        final stdout = await output;
        if (exitCode == 0) {
          return stdout.trim();
        }
        throw StateError('Tesseract exited with code $exitCode: $stderr');
      }

      var text = await runOnce(psm);
      if (text.isEmpty && psm == 3) {
        text = await runOnce(6);
      }
      return text;
    } catch (error) {
      throw StateError('Windows OCR failed: $error');
    } finally {
      try {
        if (tempFile != null && tempFile.existsSync()) {
          tempFile.deleteSync();
        }
      } catch (_) {}
    }
  }

  /// Measured character-weighted word confidence, rather than a score guessed
  /// from the spelling or the apparent plausibility of an arithmetic expression.
  static TesseractRead parseTesseractTsv(String tsv,
      {bool preserveLines = false, bool includeLayout = false}) {
    final output = StringBuffer();
    String? lastLine;
    var total = 0.0;
    var characters = 0;
    final bounds = <String, Rect>{};
    final words = <String, List<String>>{};
    final scores = <String, List<double>>{};
    for (final row in tsv.split('\n').skip(1)) {
      final cells = row.trimRight().split('\t');
      if (cells.length < 11) continue;
      final line = cells.sublist(1, 5).join(':');
      if (includeLayout && cells.first == '4') {
        final coords = cells.sublist(6, 10).map(double.tryParse).toList();
        if (coords.every((value) => value != null)) {
          bounds[line] =
              Rect.fromLTWH(coords[0]!, coords[1]!, coords[2]!, coords[3]!);
        }
      }
      if (cells.length < 12 || cells.first != '5') continue;
      final confidence = double.tryParse(cells[10]);
      final text = cells.sublist(11).join('\t').trim();
      if (confidence == null ||
          !confidence.isFinite ||
          confidence < 0 ||
          text.isEmpty) {
        continue;
      }
      if (includeLayout) {
        (words[line] ??= []).add(text);
        (scores[line] ??= []).add(confidence / 100);
      }
      if (output.isNotEmpty) {
        output.write(preserveLines && line != lastLine ? '\n' : ' ');
      }
      output.write(text);
      lastLine = line;
      total += confidence * text.runes.length;
      characters += text.runes.length;
    }
    final ordered = bounds.entries
        .where((entry) => words.containsKey(entry.key) && !entry.value.isEmpty);
    return TesseractRead(output.toString(),
        characters == 0 ? 0 : (total / characters / 100).clamp(0.0, 1.0),
        lines: [
          for (final entry in ordered)
            (
              bounds: entry.value,
              text: words[entry.key]!.join(' '),
              size: entry.value.height
            ),
        ],
        lineConfidences: [
          for (final entry in ordered)
            scores[entry.key]!.reduce((a, b) => a < b ? a : b)
        ]);
  }

  static Future<TesseractRead> recognizeTesseractWithConfidence(
    Uint8List bytes, {
    required String language,
    required int psm,
    bool disableDictionary = false,
    bool adaptiveThreshold = false,
    bool fast = false,
    bool includeLayout = false,
  }) async {
    if (Platform.isWindows) {
      return parseTesseractTsv(
          await recognizeWindowsTesseract(bytes,
              lang: language,
              psm: psm,
              disableDictionary: disableDictionary,
              adaptiveThreshold: adaptiveThreshold,
              fast: fast,
              outputTsv: true),
          preserveLines: psm != 7,
          includeLayout: includeLayout);
    }
    return _readAndroidTesseract(bytes,
        lang: language,
        psm: psm,
        disableDictionary: disableDictionary,
        fast: fast,
        adaptiveThreshold: adaptiveThreshold,
        includeLayout: includeLayout);
  }

  static Future<TesseractRead> recognizeCameraLuma(
      Uint8List pixels, int width, int height) async {
    if (width < 16 || height < 16 || pixels.length != width * height) {
      throw const FormatException('Invalid camera luminance frame.');
    }
    final dataPath = await ensureTessDataExtracted(fast: true);
    final result =
        await _channel.invokeMapMethod<String, dynamic>('recognizeCameraLuma', {
      'pixels': pixels,
      'width': width,
      'height': height,
      'dataPath': dataPath,
    });
    return TesseractRead(
      (result?['text'] as String? ?? '').trim(),
      ((result?['confidence'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
    );
  }

  static Future<TesseractRead> recognizeCaptchaTesseract(Uint8List bytes,
          {required String language}) =>
      recognizeTesseractWithConfidence(bytes,
          language: language, psm: 7, disableDictionary: true);

  /// Renders a specific PDF page (0-based index) to PNG image bytes natively on Android or Windows
  static Future<Uint8List?> renderPdfPageToPng(
      Uint8List pdfBytes, int pageIndex) async {
    final stamp = '${DateTime.now().microsecondsSinceEpoch}_${++_tempFileSeq}';
    final tempPdf = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}scanora_pdf_$stamp.pdf');
    try {
      await tempPdf.writeAsBytes(pdfBytes);
      return await renderPdfPageAsPng(
          pdfPath: tempPdf.path, pageIndex: pageIndex);
    } catch (_) {
      return null;
    } finally {
      try {
        await tempPdf.delete();
      } catch (_) {}
    }
  }

  /// Renders from a file without reading or copying the entire PDF per page.
  static Future<Uint8List?> renderPdfPageAsPng({
    required String pdfPath,
    required int pageIndex,
  }) async {
    try {
      if (Platform.isAndroid) {
        return await _channel.invokeMethod<Uint8List>('renderPdfPage', {
          'pdfPath': pdfPath,
          'pageIndex': pageIndex,
        });
      }
      if (Platform.isWindows) {
        return await _renderWindowsPdfPage(pdfPath, pageIndex);
      }
    } catch (_) {}
    return null;
  }

  static Future<Uint8List?> _renderWindowsPdfPage(
      String pdfPath, int pageIndex) async {
    final stamp = '${DateTime.now().microsecondsSinceEpoch}_${++_tempFileSeq}';
    final prefix = '${Directory.systemTemp.path}\\scanora_render_$stamp';
    final tempPng = File('$prefix.png');
    final scriptFile = File('$prefix.ps1');
    const psScript = r'''
param([string]$pdfPath, [int]$pageIndex, [string]$outPngPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod } | Select-Object -First 1
$asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and -not $_.IsGenericMethod } | Select-Object -First 1

function Await-WinRT($winRtAsync, $resultType) {
    $asTaskMethod = $asTaskGeneric.MakeGenericMethod($resultType)
    $task = $asTaskMethod.Invoke($null, @($winRtAsync))
    $task.Wait()
    return $task.Result
}
function Await-WinRTAction($winRtAsync) {
    $task = $asTaskAction.Invoke($null, @($winRtAsync))
    $task.Wait()
}

[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime] | Out-Null
[Windows.UI.ColorHelper, Windows.UI, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
[Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null

$file = Await-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($pdfPath)) ([Windows.Storage.StorageFile])
$pdfDoc = Await-WinRT ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])

if ($pageIndex -lt 0 -or $pageIndex -ge $pdfDoc.PageCount) { exit 1 }
$page = $pdfDoc.GetPage([uint32]$pageIndex)
$stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
$options = New-Object Windows.Data.Pdf.PdfPageRenderOptions
$renderScale = 3200.0 / [Math]::Max($page.Size.Width, $page.Size.Height)
$options.DestinationWidth = [uint32]([Math]::Max(1, [Math]::Round($page.Size.Width * $renderScale)))
try { $options.BackgroundColor = [Windows.UI.ColorHelper]::FromArgb(255, 255, 255, 255) } catch {}
Await-WinRTAction ($page.RenderToStreamAsync($stream, $options))

$size = [uint32]$stream.Size
$inputStream = $stream.GetInputStreamAt(0)
$reader = New-Object Windows.Storage.Streams.DataReader($inputStream)
[void](Await-WinRT ($reader.LoadAsync($size)) ([uint32]))
$bytes = New-Object byte[] $size
$reader.ReadBytes($bytes)
[System.IO.File]::WriteAllBytes($outPngPath, $bytes)
$page.Dispose()
$stream.Dispose()
''';
    try {
      await scriptFile.writeAsString(psScript);
      final process = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
        File(pdfPath).absolute.path.replaceAll('/', '\\'),
        pageIndex.toString(),
        tempPng.path,
      ]);
      final output = Future.wait([
        process.stdout.drain<void>(),
        process.stderr.drain<void>(),
      ]);
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      await output;
      if (exitCode != 0 || !await tempPng.exists()) return null;
      final bytes = await tempPng.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } finally {
      for (final file in [tempPng, scriptFile]) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }
}
