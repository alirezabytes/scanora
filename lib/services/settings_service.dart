import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../models/ai_provider.dart';
import '../models/bookmark_item.dart';
import '../models/note_item.dart';
import '../models/scan_history_item.dart';
import 'tts/tts_models.dart';

class _LocalPreferences {
  Future<void> _pendingSave = Future<void>.value();
  final Map<String, dynamic> _data = {};
  File? _file;

  static Future<_LocalPreferences> getInstance(
      {String fileName = 'scanora_prefs.json'}) async {
    final instance = _LocalPreferences();
    await instance._load(fileName);
    return instance;
  }

  Future<void> _load(String fileName) async {
    try {
      Directory dir;
      if (Platform.isAndroid) {
        final candidates = [
          Directory('/data/user/0/com.scanora.app/files'),
          Directory('/data/data/com.scanora.app/files'),
        ];
        Directory? resolved;
        for (final c in candidates) {
          try {
            if (!c.existsSync()) {
              c.createSync(recursive: true);
            }
            if (c.existsSync()) {
              resolved = c;
              break;
            }
          } catch (_) {}
        }
        dir = resolved ?? Directory.systemTemp;
      } else if (Platform.isWindows) {
        final appData = Platform.environment['APPDATA'] ?? '.';
        dir = Directory('$appData/Scanora');
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
      } else {
        dir = Directory.systemTemp;
      }
      _file = File('${dir.path}/$fileName');

      if (_file!.existsSync()) {
        final content = await _file!.readAsString();
        if (content.isNotEmpty) {
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          _data.addAll(decoded);
        }
      }
    } catch (_) {}
  }

  Future<void> _save() {
    final path = _file?.path;
    if (path == null) return Future<void>.value();
    final snapshot = Map<String, dynamic>.of(_data);
    _pendingSave = _pendingSave
        .then((_) => _writeSnapshot(path, snapshot))
        .catchError((Object _) {});
    return _pendingSave;
  }

  static Future<void> _writeSnapshot(
          String path, Map<String, dynamic> snapshot) =>
      Isolate.run(() {
        final temporary = File('$path.pending');
        temporary.writeAsStringSync(jsonEncode(snapshot), flush: true);
        temporary.renameSync(path);
      });

  String? getString(String key) => _data[key]?.toString();
  bool? getBool(String key) => _data[key] is bool ? _data[key] as bool : null;
  int? getInt(String key) => _data[key] is int ? _data[key] as int : null;
  double? getDouble(String key) =>
      (_data[key] is num) ? (_data[key] as num).toDouble() : null;

  Future<bool> setString(String key, String value) async {
    _data[key] = value;
    await _save();
    return true;
  }

  Future<bool> setBool(String key, bool value) async {
    _data[key] = value;
    await _save();
    return true;
  }

  Future<bool> setInt(String key, int value) async {
    _data[key] = value;
    await _save();
    return true;
  }

  Future<bool> remove(String key) async {
    _data.remove(key);
    await _save();
    return true;
  }

  Future<void> update(Map<String, Object?> changes) {
    for (final entry in changes.entries) {
      if (entry.value == null) {
        _data.remove(entry.key);
      } else {
        _data[entry.key] = entry.value;
      }
    }
    return _save();
  }
}

class SettingsService extends ChangeNotifier {
  static const _readingHistoryKey = 'reading_time_by_day';
  static const _documentLayoutKey = 'document_layout';

  bool get documentLayout => _prefs.getBool(_documentLayoutKey) ?? false;
  bool get showReaderText => _prefs.getBool('show_reader_text') ?? true;

  Future<void> setShowReaderText(bool value) async {
    await _prefs.setBool('show_reader_text', value);
    notifyListeners();
  }

  Future<void> setDocumentLayout(bool value) async {
    await _prefs.setBool(_documentLayoutKey, value);
    notifyListeners();
  }

  List<({String day, String title, int milliseconds, int audioMilliseconds})>
      get readingTimeHistory {
    final encoded = _prefs.getString(_readingHistoryKey);
    if (encoded == null) return [];
    try {
      final days = jsonDecode(encoded) as Map<String, dynamic>;
      return [
        for (final day in days.entries)
          for (final entry in (day.value as Map<String, dynamic>).entries)
            (
              day: day.key,
              title: entry.key,
              milliseconds: (entry.value as List)[0] as int,
              audioMilliseconds: (entry.value as List)[1] as int,
            ),
      ]..sort((a, b) => b.day.compareTo(a.day));
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    }
  }

  Future<void> addReadingTime(
      String day, String title, int milliseconds, int audioMilliseconds) async {
    final days = <String, Map<String, List<int>>>{};
    for (final row in readingTimeHistory) {
      (days[row.day] ??= {})[row.title] = [
        row.milliseconds,
        row.audioMilliseconds
      ];
    }
    final files = days[day] ??= {};
    final time = files[title] ?? [0, 0];
    files[title] = [time[0] + milliseconds, time[1] + audioMilliseconds];
    await _prefs.setString(_readingHistoryKey, jsonEncode(days));
  }

  ({int reading, int listening}) readingTimeForBook(String title, String key) {
    var reading = 0;
    var listening = 0;
    for (final row in readingTimeHistory) {
      if (row.title == title || row.title == key) {
        reading += row.milliseconds;
        listening += row.audioMilliseconds;
      }
    }
    return (reading: reading ~/ 1000, listening: listening ~/ 1000);
  }

  Future<void> clearReadingTime() => _prefs.remove(_readingHistoryKey);

  SettingsService();
  SettingsService.memory();
  static const String _kLanguage = 'app_language';
  static const String _kFirstLaunch = 'is_first_launch';
  static const String _kOfflineMode = 'is_offline_mode';
  static const String _kAutoCopy = 'auto_copy_result_v2';
  static const String _kActiveProvider = 'active_provider';
  static const String _kActiveProviderName = 'active_provider_name';
  static const String _kScanoraCloudOcr = 'scanora_cloud_ocr_enabled';
  static const String _kCaptchaHotkeyEnabled = 'captcha_hotkey_enabled';
  static const String _kCaptchaHotkey = 'captcha_hotkey_combo';
  static const String _kThinkingEffort = 'thinking_effort';
  static const String _kCustomBaseUrl = 'custom_base_url';
  static const String _kDarkTheme = 'dark_theme';
  static const String _kHistory = 'scan_history';
  static const String _kBookmarks = 'bookmarks';
  static const String _kNotes = 'smart_notes';
  static const String _kExportDirectory = 'export_directory_path';

  // eSpeak-NG TTS & Reader Keys
  static const String _kEnableInternalTts = 'tts_enable_internal_espeak_v2';
  static const String _kAutoReadOnOpen = 'tts_auto_read_on_open_v2';
  static const String _kTtsSeekSeconds = 'tts_seek_seconds';
  static const String _kTtsVoice = 'tts_espeak_voice';
  static const String _kTtsVariant = 'tts_espeak_variant';
  static const String _kTtsRate = 'tts_espeak_rate';
  static const String _kTtsPitch = 'tts_espeak_pitch';
  static const String _kTtsPitchRange = 'tts_espeak_pitch_range';
  static const String _kTtsVolume = 'tts_espeak_volume';
  static const String _kTtsWordGap = 'tts_espeak_word_gap';
  static const String _kTtsPunctuation = 'tts_espeak_punctuation';
  static const String _kTtsCapitalsMode = 'tts_espeak_capitals_mode';
  static const String _kTtsDigitMode = 'tts_espeak_digit_mode';
  static const String _kTtsAutoBilingual = 'tts_espeak_auto_bilingual_v2';
  static const String _kIncludePageNumbers = 'reader_include_page_numbers';
  static const String _kPlayPageFlipSound = 'reader_play_page_flip_sound';
  static const String _kAutoAdvancePage = 'reader_auto_advance_page';

  _LocalPreferences _prefs = _LocalPreferences();
  _LocalPreferences _sessionPrefs = _LocalPreferences();

  String? get resumeTool => _sessionPrefs.getString('tool');

  Future<void> rememberTool(String? name) =>
      _sessionPrefs.update({'tool': name});

  Map<String, dynamic>? readerSession(String key) {
    final value = _sessionPrefs._data[key];
    return value is Map<String, dynamic> ? value : null;
  }

  Future<void> rememberReaderSession(String key, Map<String, dynamic>? state) =>
      _sessionPrefs.update({key: state});

  Map<String, dynamic>? bookPosition(String key) =>
      readerSession('book-position:$key');

  Future<void> rememberBookPosition(String key, Map<String, dynamic> state) =>
      rememberReaderSession('book-position:$key', state);
  bool _isInitialized = false;

  // Default language is English ('en'), and Auto-Copy is OFF (false) by default
  Locale _locale = const Locale('en');
  bool _isFirstLaunch = true;
  bool _isOfflineMode = true;
  bool _autoCopyCaptcha = false;
  AIProviderType _activeProvider = AIProviderType.gemini;
  final Map<String, String> _modelEfforts = {};
  ThinkingEffort _thinkingEffort = ThinkingEffort.none;
  final Map<AIProviderType, String> _apiKeys = {};
  final Map<AIProviderType, String> _selectedModels = {};
  final Map<AIProviderType, List<String>> _discoveredModels = {};
  final Map<AIProviderType, String> _modelFingerprints = {};
  String _customBaseUrl = '';
  bool _isDarkTheme = true;
  bool _useScanoraCloudOcr = false;
  bool _captchaHotkeyEnabled = true;
  String _captchaHotkey = 'ctrl+shift+c';
  List<ScanHistoryItem> _history = [];
  List<BookmarkItem> _bookmarks = [];
  List<NoteItem> _notes = [];
  String? _exportDirectoryPath;

  // eSpeak-NG TTS and reader state.
  bool _enableInternalTts = true;
  bool _autoReadOnOpen = true;
  int _ttsSeekSeconds = 10;
  String _ttsVoice = 'auto';
  String _ttsVariant = 'none';
  int _ttsRate = 175;
  int _ttsPitch = 50;
  int _ttsPitchRange = 50;
  int _ttsVolume = 100;
  int _ttsWordGap = 5;
  TtsPunctuation _ttsPunctuation = TtsPunctuation.some;
  int _ttsCapitalsMode = 0;
  int _ttsDigitMode = 0;
  bool _ttsAutoBilingual = true;
  bool _includePageNumbersInOutput = true;
  bool _playPageFlipSound = true;
  bool _autoAdvancePage = false;
  bool _announceProgress = true;
  String? _espeakDataDirectory;
  String? get espeakDataDirectory => _espeakDataDirectory;
  Future<void> setEspeakDataDirectory(String path) async {
    _espeakDataDirectory = path;
    await _prefs.setString('espeak_data_directory', path);
    notifyListeners();
  }

  bool get announceProgress => _announceProgress;
  Future<void> setAnnounceProgress(bool value) async {
    _announceProgress = value;
    await _prefs.setBool('announce_progress', value);
    notifyListeners();
  }

  bool _ttsRateBoost = false;
  bool get ttsRateBoost => _ttsRateBoost;
  int get effectiveTtsRate =>
      _ttsRate * (_ttsRateBoost ? ttsRateBoostMultiplier : 1);
  Future<void> setTtsRateBoost(bool value) async {
    _ttsRateBoost = value;
    await _prefs.setBool('tts_rate_boost', value);
    notifyListeners();
  }

  bool _ttsUnicodeNormalization = true;
  bool get ttsUnicodeNormalization => _ttsUnicodeNormalization;
  Future<void> setTtsUnicodeNormalization(bool value) async {
    _ttsUnicodeNormalization = value;
    await _prefs.setBool('tts_unicode_normalization', value);
    notifyListeners();
  }

  bool _accurateSpeech = true;
  bool get accurateSpeech => _accurateSpeech;
  Future<void> setAccurateSpeech(bool value) async {
    _accurateSpeech = value;
    await _prefs.setBool('speech_accurate_small', value);
    notifyListeners();
  }

  bool get isInitialized => _isInitialized;
  Locale get locale => _locale;
  bool get isFirstLaunch => _isFirstLaunch;
  bool get isOfflineMode => _isOfflineMode;
  bool get autoCopyCaptcha => _autoCopyCaptcha;
  AIProviderType get activeProvider => _activeProvider;
  String _effortKey(AIProviderType provider, String model) =>
      '${provider.name}:$model';

  ThinkingEffort get thinkingEffort {
    final model = getSelectedModel(activeProvider);
    final name = _modelEfforts[_effortKey(activeProvider, model)] ??
        _thinkingEffort.name;
    return ThinkingEffort.supportedBy(activeProvider, model).firstWhere(
        (level) => level.name == name,
        orElse: () => ThinkingEffort.none);
  }

  String get customBaseUrl => _customBaseUrl;
  bool get isDarkTheme => _isDarkTheme;

  /// When enabled, document OCR in online mode uses the built-in Scanora Smart Cloud
  /// service (Google account authorization required; no AI API key).
  bool get useScanoraCloudOcr => _useScanoraCloudOcr;

  /// Windows global hotkey that solves the captcha image found in the clipboard.
  bool get captchaHotkeyEnabled => _captchaHotkeyEnabled;

  /// Hotkey combination stored as lower-case tokens joined by '+', e.g. 'ctrl+shift+c'.
  String get captchaHotkey => _captchaHotkey;
  List<ScanHistoryItem> get history => List.unmodifiable(_history);
  List<BookmarkItem> get bookmarks => List.unmodifiable(_bookmarks);
  List<NoteItem> get notes => List.unmodifiable(_notes);
  String? get exportDirectoryPath => _exportDirectoryPath;

  // eSpeak-NG & Reader Getters
  bool get enableInternalTts => _enableInternalTts;
  bool get autoReadOnOpen => _autoReadOnOpen;
  int get ttsSeekSeconds => _ttsSeekSeconds;
  String get ttsVoice => _ttsVoice;
  String get ttsVariant => _ttsVariant;
  int get ttsRate => _ttsRate;
  int get ttsPitch => _ttsPitch;
  int get ttsPitchRange => _ttsPitchRange;
  int get ttsVolume => _ttsVolume;
  int get ttsWordGap => _ttsWordGap;
  TtsPunctuation get ttsPunctuation => _ttsPunctuation;
  int get ttsCapitalsMode => _ttsCapitalsMode;

  /// 0 = read numbers as whole numbers, 1 = read digit by digit.
  int get ttsDigitMode => _ttsDigitMode;
  bool get ttsAutoBilingual => _ttsAutoBilingual;
  bool get includePageNumbersInOutput => _includePageNumbersInOutput;
  bool get playPageFlipSound => _playPageFlipSound;
  bool get autoAdvancePage => _autoAdvancePage;

  /// Removes invisible directional marks, zero-width spaces, quotes, and whitespace from API keys.
  static String sanitizeKey(String rawKey) {
    return rawKey
        .replaceAll(
          RegExp(r'[\s"\x27\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]'),
          '',
        )
        .trim();
  }

  Future<void> init() async {
    final preferences = await Future.wait([
      _LocalPreferences.getInstance(),
      _LocalPreferences.getInstance(fileName: 'scanora_session.json'),
    ]);
    _prefs = preferences[0];
    _sessionPrefs = preferences[1];
    _accurateSpeech = _prefs.getBool('speech_accurate_small') ?? true;
    _announceProgress = _prefs.getBool('announce_progress') ?? true;
    _espeakDataDirectory = _prefs.getString('espeak_data_directory');
    _ttsUnicodeNormalization =
        _prefs.getBool('tts_unicode_normalization') ?? true;
    _ttsRateBoost = _prefs.getBool('tts_rate_boost') ?? false;

    final savedLang = _prefs.getString(_kLanguage);
    if (savedLang != null && savedLang.isNotEmpty) {
      _locale = Locale(savedLang);
    } else {
      _locale = const Locale('en');
    }
    _isFirstLaunch = _prefs.getBool(_kFirstLaunch) ?? true;
    _isOfflineMode = _prefs.getBool(_kOfflineMode) ?? true;
    _autoCopyCaptcha = _prefs.getBool(_kAutoCopy) ?? false;
    _customBaseUrl = _prefs.getString(_kCustomBaseUrl) ?? '';
    _isDarkTheme = _prefs.getBool(_kDarkTheme) ?? true;
    _useScanoraCloudOcr = _prefs.getBool(_kScanoraCloudOcr) ?? false;
    _captchaHotkeyEnabled = _prefs.getBool(_kCaptchaHotkeyEnabled) ?? true;
    _captchaHotkey = _prefs.getString(_kCaptchaHotkey) ?? 'ctrl+shift+c';
    _exportDirectoryPath = _prefs.getString(_kExportDirectory);

    // Load eSpeak-NG & Reader settings
    _enableInternalTts = _prefs.getBool(_kEnableInternalTts) ?? true;
    _autoReadOnOpen = _prefs.getBool(_kAutoReadOnOpen) ?? true;
    _ttsSeekSeconds = (_prefs.getInt(_kTtsSeekSeconds) ?? 10).clamp(1, 300);
    _ttsVoice = _prefs.getString(_kTtsVoice) ?? 'auto';
    _ttsVariant = _prefs.getString(_kTtsVariant) ?? 'none';
    _ttsRate = (_prefs.getInt(_kTtsRate) ?? 175).clamp(80, 450);
    _ttsPitch = (_prefs.getInt(_kTtsPitch) ?? 50).clamp(0, 100);
    _ttsPitchRange = (_prefs.getInt(_kTtsPitchRange) ?? 50).clamp(0, 100);
    _ttsVolume = (_prefs.getInt(_kTtsVolume) ?? 100).clamp(0, 200);
    _ttsWordGap = (_prefs.getInt(_kTtsWordGap) ?? 5).clamp(0, 50);
    _ttsPunctuation =
        TtsPunctuation.fromPreference(_prefs.getInt(_kTtsPunctuation));
    _ttsCapitalsMode = _prefs.getInt(_kTtsCapitalsMode) ?? 0;
    _ttsDigitMode = (_prefs.getInt(_kTtsDigitMode) ?? 0).clamp(0, 1);
    _ttsAutoBilingual = _prefs.getBool(_kTtsAutoBilingual) ?? true;
    _includePageNumbersInOutput = _prefs.getBool(_kIncludePageNumbers) ?? true;
    _playPageFlipSound = _prefs.getBool(_kPlayPageFlipSound) ?? true;
    _autoAdvancePage = _prefs.getBool(_kAutoAdvancePage) ?? false;

    final providerName = _prefs.getString(_kActiveProviderName);
    if (providerName != null) {
      for (final p in AIProviderType.values) {
        if (p.name == providerName) _activeProvider = p;
      }
    } else {
      // Migration from the legacy index-based key (a removed provider used to sit at index 5).
      const legacyOrder = <String>[
        'gemini',
        'openai',
        'anthropic',
        'groq',
        'openrouter',
        '_removed',
        'custom',
      ];
      final providerIdx = _prefs.getInt(_kActiveProvider);
      if (providerIdx != null &&
          providerIdx >= 0 &&
          providerIdx < legacyOrder.length) {
        for (final p in AIProviderType.values) {
          if (p.name == legacyOrder[providerIdx]) _activeProvider = p;
        }
      }
    }

    try {
      final stored =
          jsonDecode(_prefs.getString('model_thinking_efforts') ?? '{}');
      if (stored is Map) {
        for (final entry in stored.entries) {
          if (entry.key is String && entry.value is String) {
            _modelEfforts[entry.key as String] = entry.value as String;
          }
        }
      }
    } catch (_) {}
    final effortIdx = _prefs.getInt(_kThinkingEffort);
    if (effortIdx != null &&
        effortIdx >= 0 &&
        effortIdx < ThinkingEffort.values.length) {
      _thinkingEffort = ThinkingEffort.values[effortIdx];
    }

    for (final provider in AIProviderType.values) {
      final rawKey = _prefs.getString('api_key_${provider.name}') ?? '';
      _apiKeys[provider] = sanitizeKey(rawKey);

      _modelFingerprints[provider] =
          _prefs.getString('models_fingerprint_v2_${provider.name}') ?? '';
      final savedModel = _prefs.getString('model_${provider.name}');
      _selectedModels[provider] =
          (savedModel != null && savedModel.trim().isNotEmpty)
              ? savedModel.trim()
              : '';

      final discoveredJson =
          _prefs.getString('discovered_models_${provider.name}');
      if (discoveredJson != null && discoveredJson.isNotEmpty) {
        try {
          final list = (jsonDecode(discoveredJson) as List<dynamic>)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          if (list.isNotEmpty) {
            _discoveredModels[provider] = list;
          }
        } catch (_) {}
      }
    }

    final historyJson = _prefs.getString(_kHistory);
    if (historyJson != null) {
      try {
        final decoded = jsonDecode(historyJson) as List<dynamic>;
        _history = decoded
            .map((item) =>
                ScanHistoryItem.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    final bookmarksJson = _prefs.getString(_kBookmarks);
    if (bookmarksJson != null) {
      try {
        final decoded = jsonDecode(bookmarksJson) as List<dynamic>;
        _bookmarks = decoded
            .map((item) => BookmarkItem.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    final notesJson = _prefs.getString(_kNotes);
    if (notesJson != null) {
      try {
        final decoded = jsonDecode(notesJson) as List<dynamic>;
        _notes = decoded
            .map((item) => NoteItem.fromMap(item as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    _isInitialized = true;
    notifyListeners();
  }

  Future<void> setLanguage(String languageCode) async {
    _locale = Locale(languageCode);
    await _prefs.setString(_kLanguage, languageCode);
    _isFirstLaunch = false;
    await _prefs.setBool(_kFirstLaunch, false);
    notifyListeners();
  }

  Future<void> toggleOfflineMode(bool offline) async {
    _isOfflineMode = offline;
    await _prefs.setBool(_kOfflineMode, offline);
    notifyListeners();
  }

  Future<void> setUseScanoraCloudOcr(bool enable) async {
    _useScanoraCloudOcr = enable;
    await _prefs.setBool(_kScanoraCloudOcr, enable);
    notifyListeners();
  }

  Future<void> setCaptchaHotkeyEnabled(bool enable) async {
    _captchaHotkeyEnabled = enable;
    await _prefs.setBool(_kCaptchaHotkeyEnabled, enable);
    notifyListeners();
  }

  Future<void> setCaptchaHotkey(String combo) async {
    _captchaHotkey = combo.trim().toLowerCase();
    await _prefs.setString(_kCaptchaHotkey, _captchaHotkey);
    notifyListeners();
  }

  Future<void> setAutoCopyCaptcha(bool enable) async {
    _autoCopyCaptcha = enable;
    await _prefs.setBool(_kAutoCopy, enable);
    notifyListeners();
  }

  Future<void> setActiveProvider(AIProviderType provider) async {
    _activeProvider = provider;
    await _prefs.setString(_kActiveProviderName, provider.name);
    notifyListeners();
  }

  Future<void> setThinkingEffort(ThinkingEffort effort) async {
    final model = getSelectedModel(activeProvider);
    if (!ThinkingEffort.supportedBy(activeProvider, model).contains(effort)) {
      return;
    }
    _modelEfforts[_effortKey(activeProvider, model)] = effort.name;
    await _prefs.setString('model_thinking_efforts', jsonEncode(_modelEfforts));
    notifyListeners();
  }

  String getApiKey(AIProviderType provider) {
    return _apiKeys[provider] ?? '';
  }

  Future<void> setApiKey(AIProviderType provider, String key,
      {bool notify = true}) async {
    final cleaned = sanitizeKey(key);
    final changed = cleaned != getApiKey(provider);
    if (changed || cleaned.isEmpty) {
      _modelFingerprints.remove(provider);
      _discoveredModels.remove(provider);
      _selectedModels.remove(provider);
    }
    _apiKeys[provider] = cleaned;
    await _prefs.update({
      'api_key_${provider.name}': cleaned.isEmpty ? null : cleaned,
      if (changed || cleaned.isEmpty) ...{
        'models_fingerprint_v2_${provider.name}': null,
        'discovered_models_${provider.name}': null,
        'model_${provider.name}': null,
      },
    });
    if (notify) {
      notifyListeners();
    }
  }

  String modelAccessFingerprint(AIProviderType provider) => sha256
      .convert(utf8.encode(
          '${provider.name}|${getApiKey(provider)}|${provider == AIProviderType.custom ? _customBaseUrl.trim() : ''}'))
      .toString();

  String getSelectedModel(AIProviderType provider) {
    final saved = _selectedModels[provider] ?? '';
    return getEffectiveModels(provider).contains(saved) ? saved : '';
  }

  Future<void> setSelectedModel(AIProviderType provider, String model,
      {bool notify = true}) async {
    final trimmed = model.trim();
    if (!getEffectiveModels(provider).contains(trimmed)) return;
    _selectedModels[provider] = trimmed;
    await _prefs.setString('model_${provider.name}', trimmed);
    if (notify) notifyListeners();
  }

  List<String> getDiscoveredModels(AIProviderType provider) =>
      getEffectiveModels(provider);

  /// Only authenticated server results for this exact key and endpoint.
  List<String> getEffectiveModels(AIProviderType provider) {
    if (_modelFingerprints[provider] != modelAccessFingerprint(provider)) {
      return const [];
    }
    return List.unmodifiable(_discoveredModels[provider] ?? const []);
  }

  Future<void> setDiscoveredModels(AIProviderType provider, List<String> models,
      {bool notify = true, String? expectedFingerprint}) async {
    final fingerprint = modelAccessFingerprint(provider);
    if (expectedFingerprint != null && expectedFingerprint != fingerprint) {
      return;
    }
    final cleaned =
        models.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    _discoveredModels[provider] = cleaned;
    _modelFingerprints[provider] = fingerprint;
    if (!cleaned.contains(_selectedModels[provider])) {
      _selectedModels[provider] = '';
      await _prefs.remove('model_${provider.name}');
    }
    await _prefs.setString(
        'discovered_models_${provider.name}', jsonEncode(cleaned));
    await _prefs.setString(
        'models_fingerprint_v2_${provider.name}', fingerprint);
    if (notify) notifyListeners();
  }

  Future<void> setCustomBaseUrl(String url, {bool notify = true}) async {
    final cleaned = url.trim();
    if (cleaned != _customBaseUrl) {
      _modelFingerprints.remove(AIProviderType.custom);
      _discoveredModels.remove(AIProviderType.custom);
      _selectedModels.remove(AIProviderType.custom);
      await _prefs.remove('models_fingerprint_v2_custom');
      await _prefs.remove('discovered_models_custom');
      await _prefs.remove('model_custom');
    }
    _customBaseUrl = cleaned;
    await _prefs.setString(_kCustomBaseUrl, _customBaseUrl);
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> toggleDarkTheme(bool isDark) async {
    _isDarkTheme = isDark;
    await _prefs.setBool(_kDarkTheme, isDark);
    notifyListeners();
  }

  // eSpeak-NG & Reader Setters
  Future<void> setEnableInternalTts(bool enabled) async {
    _enableInternalTts = enabled;
    await _prefs.setBool(_kEnableInternalTts, enabled);
    notifyListeners();
  }

  Future<void> setAutoReadOnOpen(bool enabled) async {
    _autoReadOnOpen = enabled;
    await _prefs.setBool(_kAutoReadOnOpen, enabled);
    notifyListeners();
  }

  Future<void> setTtsSeekSeconds(int seconds) async {
    _ttsSeekSeconds = seconds.clamp(1, 300);
    await _prefs.setInt(_kTtsSeekSeconds, _ttsSeekSeconds);
    notifyListeners();
  }

  Future<void> setTtsVoice(String voice) async {
    _ttsVoice = voice;
    await _prefs.setString(_kTtsVoice, voice);
    notifyListeners();
  }

  Future<void> setTtsVariant(String variant) async {
    _ttsVariant = variant;
    await _prefs.setString(_kTtsVariant, variant);
    notifyListeners();
  }

  Future<void> setTtsRate(int rate) async {
    _ttsRate = rate.clamp(80, 450);
    await _prefs.setInt(_kTtsRate, _ttsRate);
    notifyListeners();
  }

  Future<void> setTtsPitch(int pitch) async {
    _ttsPitch = pitch.clamp(0, 100);
    await _prefs.setInt(_kTtsPitch, _ttsPitch);
    notifyListeners();
  }

  Future<void> setTtsPitchRange(int range) async {
    _ttsPitchRange = range.clamp(0, 100);
    await _prefs.setInt(_kTtsPitchRange, _ttsPitchRange);
    notifyListeners();
  }

  Future<void> setTtsVolume(int volume) async {
    _ttsVolume = volume.clamp(0, 200);
    await _prefs.setInt(_kTtsVolume, _ttsVolume);
    notifyListeners();
  }

  Future<void> setTtsWordGap(int wordGap) async {
    _ttsWordGap = wordGap.clamp(0, 50);
    await _prefs.setInt(_kTtsWordGap, _ttsWordGap);
    notifyListeners();
  }

  Future<void> setTtsPunctuation(TtsPunctuation mode) async {
    _ttsPunctuation = mode;
    await _prefs.setInt(_kTtsPunctuation, mode.preferenceValue);
    notifyListeners();
  }

  Future<void> setTtsCapitalsMode(int mode) async {
    _ttsCapitalsMode = mode;
    await _prefs.setInt(_kTtsCapitalsMode, mode);
    notifyListeners();
  }

  Future<void> setTtsDigitMode(int mode) async {
    _ttsDigitMode = mode.clamp(0, 1);
    await _prefs.setInt(_kTtsDigitMode, _ttsDigitMode);
    notifyListeners();
  }

  /// Restores every acoustic voice characteristic to its default value.
  Future<void> resetTtsVoiceCharacteristics() async {
    _ttsRate = 175;
    _ttsRateBoost = false;
    await _prefs.setBool('tts_rate_boost', false);
    _ttsPitch = 50;
    _ttsPitchRange = 50;
    _ttsVolume = 100;
    _ttsWordGap = 5;
    await _prefs.setInt(_kTtsRate, _ttsRate);
    await _prefs.setInt(_kTtsPitch, _ttsPitch);
    await _prefs.setInt(_kTtsPitchRange, _ttsPitchRange);
    await _prefs.setInt(_kTtsVolume, _ttsVolume);
    await _prefs.setInt(_kTtsWordGap, _ttsWordGap);
    notifyListeners();
  }

  Future<void> setTtsAutoBilingual(bool enabled) async {
    _ttsAutoBilingual = enabled;
    await _prefs.setBool(_kTtsAutoBilingual, enabled);
    notifyListeners();
  }

  Future<void> setIncludePageNumbersInOutput(bool enabled) async {
    _includePageNumbersInOutput = enabled;
    await _prefs.setBool(_kIncludePageNumbers, enabled);
    notifyListeners();
  }

  Future<void> setPlayPageFlipSound(bool enabled) async {
    _playPageFlipSound = enabled;
    await _prefs.setBool(_kPlayPageFlipSound, enabled);
    notifyListeners();
  }

  Future<void> setAutoAdvancePage(bool enabled) async {
    _autoAdvancePage = enabled;
    await _prefs.setBool(_kAutoAdvancePage, enabled);
    notifyListeners();
  }

  // Bookmarking methods
  Future<void> addBookmark(BookmarkItem item) async {
    _bookmarks.removeWhere(
      (b) =>
          b.documentName == item.documentName &&
          b.pageNumber == item.pageNumber,
    );
    _bookmarks.insert(0, item);
    await _saveBookmarks();
    notifyListeners();
  }

  Future<void> removeBookmark(String id) async {
    _bookmarks.removeWhere((b) => b.id == id);
    await _saveBookmarks();
    notifyListeners();
  }

  List<BookmarkItem> getBookmarksForDocument(String docName) {
    return _bookmarks.where((b) => b.documentName == docName).toList();
  }

  Future<void> _saveBookmarks() async {
    await _prefs.setString(
      _kBookmarks,
      jsonEncode(_bookmarks.map((b) => b.toJson()).toList()),
    );
  }

  Future<void> setExportDirectoryPath(String? path) async {
    _exportDirectoryPath = path;
    if (path != null) {
      await _prefs.setString(_kExportDirectory, path);
    } else {
      await _prefs.remove(_kExportDirectory);
    }
    notifyListeners();
  }

  // Bookmark Management
  Future<void> deleteBookmark(String id) async {
    _bookmarks.removeWhere((b) => b.id == id);
    await _saveBookmarks();
    notifyListeners();
  }

  Future<void> clearBookmarksForDocument(String docName) async {
    _bookmarks.removeWhere((b) => b.documentName == docName);
    await _saveBookmarks();
    notifyListeners();
  }

  Future<void> clearAllBookmarks() async {
    _bookmarks.clear();
    await _saveBookmarks();
    notifyListeners();
  }

  // Smart Notes methods
  Future<void> addNote(NoteItem item) async {
    _notes.insert(0, item);
    await _saveNotes();
    notifyListeners();
  }

  Future<void> updateNote(NoteItem item) async {
    final idx = _notes.indexWhere((n) => n.id == item.id);
    if (idx != -1) {
      _notes[idx] = item;
      await _saveNotes();
      notifyListeners();
    }
  }

  Future<void> deleteNote(String id) async {
    _notes.removeWhere((n) => n.id == id);
    await _saveNotes();
    notifyListeners();
  }

  Future<void> duplicateNote(String id) async {
    final original =
        _notes.firstWhere((n) => n.id == id, orElse: () => _notes.first);
    final copy = NoteItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: '${original.title} (Copy)',
      content: original.content,
      source: original.source,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      tags: List.from(original.tags),
    );
    _notes.insert(0, copy);
    await _saveNotes();
    notifyListeners();
  }

  Future<void> clearAllNotes() async {
    _notes.clear();
    await _saveNotes();
    notifyListeners();
  }

  Future<void> _saveNotes() async {
    await _prefs.setString(
      _kNotes,
      jsonEncode(_notes.map((n) => n.toMap()).toList()),
    );
  }

  // History Management
  Future<void> addHistoryItem(ScanHistoryItem item) async {
    _history.insert(0, item);
    if (_history.length > 50) {
      _history = _history.sublist(0, 50);
    }
    await _saveHistory();
    notifyListeners();
  }

  Future<void> deleteHistoryItem(String id) async {
    _history.removeWhere((h) => h.id == id);
    await _saveHistory();
    notifyListeners();
  }

  Future<void> clearPdfHistory() async {
    _history.removeWhere((h) => h.type == ScanType.pdf);
    await _saveHistory();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    _history.clear();
    await _saveHistory();
    notifyListeners();
  }

  Future<void> _pendingHistorySave = Future<void>.value();

  Future<void> _saveHistory() {
    final snapshot = List<ScanHistoryItem>.of(_history);
    final pending = _pendingHistorySave.then((_) async {
      final encoded = await _encodeHistory(snapshot);
      await _prefs.setString(_kHistory, encoded);
    });
    _pendingHistorySave = pending.catchError((Object _) {});
    return pending;
  }

  static Future<String> _encodeHistory(List<ScanHistoryItem> history) =>
      history.fold(0, (size, item) => size + item.content.length) < 65536
          ? Future.value(_historyJson(history))
          : Isolate.run(() => _historyJson(history));

  static String _historyJson(List<ScanHistoryItem> history) =>
      jsonEncode(history.map((item) => item.toJson()).toList());
}
