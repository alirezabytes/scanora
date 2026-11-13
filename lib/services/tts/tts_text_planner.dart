import 'dart:math' as math;
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'tts_models.dart';

/// Turns plain text into timed [TtsChunk]s.
///
/// * Sentences / clauses of at most ~24 words give smooth seeking.
/// * Bilingual text is handled by eSpeak-NG itself: Latin runs inside Persian text
///   (and vice versa) are wrapped in SSML `<voice>` tags, so the voice switches
///   inside ONE synthesis call, with no pause between languages.
/// * Script detection is based on Unicode blocks only.
class TtsTextPlanner {
  TtsTextPlanner._();

  static const int _scriptNeutral = 0;
  static const int _scriptArabic = 1;
  static const int _scriptLatin = 2;

  static int _scriptOf(int rune) {
    if ((rune >= 0x0600 && rune <= 0x06FF && !_isArabicIndicDigit(rune)) ||
        (rune >= 0x0750 && rune <= 0x077F) ||
        (rune >= 0xFB50 && rune <= 0xFDFF) ||
        (rune >= 0xFE70 && rune <= 0xFEFF)) {
      return _scriptArabic;
    }
    if ((rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        (rune >= 0xC0 && rune <= 0x24F)) {
      return _scriptLatin;
    }
    return _scriptNeutral;
  }

  static bool _isArabicIndicDigit(int rune) =>
      (rune >= 0x660 && rune <= 0x669) || (rune >= 0x6F0 && rune <= 0x6F9);

  /// `fa` when the text is mainly Arabic-script, otherwise `en-us`.
  static String detectPrimaryLanguageCode(String text) {
    int rtl = 0;
    int latin = 0;
    for (final rune in text.runes) {
      final s = _scriptOf(rune);
      if (s == _scriptArabic) {
        rtl++;
      } else if (s == _scriptLatin) {
        latin++;
      }
    }
    if (rtl > 0 && rtl >= latin * 0.4) return 'fa';
    return 'en-us';
  }

  /// Inserts a space between consecutive digits so the engine reads digit by digit.
  static String spaceDigits(String text) {
    final sb = StringBuffer();
    int? prev;
    for (final rune in text.runes) {
      final isDigit =
          (rune >= 0x30 && rune <= 0x39) || _isArabicIndicDigit(rune);
      if (isDigit && prev != null) {
        sb.write(' ');
      }
      sb.writeCharCode(rune);
      prev = isDigit ? rune : null;
    }
    return sb.toString();
  }

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Wraps runs of [altScript] text in `<voice name="altVoice">`.
  static String _wrapAlternateScript(
      String text, int baseScript, String altVoice) {
    final altScript =
        baseScript == _scriptArabic ? _scriptLatin : _scriptArabic;
    final segments = <MapEntry<int, StringBuffer>>[];
    int current = _scriptNeutral;
    StringBuffer buf = StringBuffer();
    segments.add(MapEntry(current, buf));

    for (final rune in text.runes) {
      final s = _scriptOf(rune);
      if (s != _scriptNeutral && s != current) {
        if (current == _scriptNeutral && buf.isEmpty) {
          // Leading neutral-only buffer is empty: re-label it instead of adding a segment.
          segments.removeLast();
        }
        current = s;
        buf = StringBuffer();
        segments.add(MapEntry(current, buf));
      }
      buf.writeCharCode(rune);
    }

    final out = StringBuffer();
    for (final seg in segments) {
      final raw = seg.value.toString();
      if (raw.isEmpty) continue;
      if (seg.key == altScript) {
        // Keep surrounding whitespace outside the tag to avoid audible gaps.
        final trimmed = raw.trim();
        final lead = raw.substring(0, raw.length - raw.trimLeft().length);
        final trail = raw.substring(raw.trimRight().length);
        out
          ..write(_escapeXml(lead))
          ..write('<voice name="$altVoice">')
          ..write(_escapeXml(trimmed))
          ..write('</voice>')
          ..write(_escapeXml(trail));
      } else {
        out.write(_escapeXml(raw));
      }
    }
    return out.toString();
  }

  static String _voiceSpec(String voice, String variant) {
    final clean = voice == 'auto' ? 'en-us' : voice;
    if (variant.isEmpty || variant == 'none') return clean;
    return '$clean+$variant';
  }

  /// Resolves the voice used as the base voice for [segment].
  static String resolveBaseVoice(String segment, String configuredVoice) {
    if (configuredVoice == 'auto') return detectPrimaryLanguageCode(segment);
    return configuredVoice;
  }

  static TtsChunk _buildChunk(
    String text, {
    required String configuredVoice,
    required String variant,
    required bool bilingual,
    required bool digitByDigit,
    required bool normalizeUnicode,
    required int startSecond,
    required int durationSeconds,
  }) {
    final spokenText = normalizeUnicode ? unorm.nfkc(text) : text;
    final baseVoice = resolveBaseVoice(spokenText, configuredVoice);
    var engineText = digitByDigit ? spaceDigits(spokenText) : spokenText;
    var useSsml = false;

    final isPersianBase = baseVoice == 'fa' || baseVoice == 'fa-latn';
    final isEnglishBase = baseVoice.startsWith('en');
    final switching = (bilingual || configuredVoice == 'auto') &&
        (isPersianBase || isEnglishBase);

    if (switching) {
      final hasArabic =
          spokenText.runes.any((r) => _scriptOf(r) == _scriptArabic);
      final hasLatin =
          spokenText.runes.any((r) => _scriptOf(r) == _scriptLatin);
      if (hasArabic && hasLatin) {
        final altVoice = _voiceSpec(isPersianBase ? 'en-us' : 'fa', variant);
        engineText = _wrapAlternateScript(
          engineText,
          isPersianBase ? _scriptArabic : _scriptLatin,
          altVoice,
        );
        useSsml = true;
      }
    }

    return TtsChunk(
      displayText: text,
      voiceSpec: _voiceSpec(baseVoice, variant),
      engineText: engineText,
      ssml: useSsml,
      startSecond: startSecond,
      durationSeconds: durationSeconds,
    );
  }

  /// Splits [text] into timed chunks.
  static List<TtsChunk> plan(
    String text, {
    required String configuredVoice,
    String variant = 'none',
    bool bilingual = false,
    bool digitByDigit = false,
    bool normalizeUnicode = true,
    required int rateWpm,
  }) {
    final paragraphs = text
        .split(RegExp(r'(\r?\n)+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    final pieces = <String>[];
    for (final p in paragraphs) {
      final parts = p
          .split(RegExp(r'(?<=[.!?؟؛])\s+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      for (final part in parts) {
        final words = part.split(RegExp(r'\s+'));
        if (words.length <= 24) {
          pieces.add(part);
        } else {
          for (int i = 0; i < words.length; i += 20) {
            pieces.add(
                words.sublist(i, math.min(i + 20, words.length)).join(' '));
          }
        }
      }
    }
    if (pieces.isEmpty && text.trim().isNotEmpty) pieces.add(text.trim());

    final wpm = rateWpm.clamp(80, 1350);
    final chunks = <TtsChunk>[];
    int running = 0;
    for (final piece in pieces) {
      final wordCount = math.max(1, piece.split(RegExp(r'\s+')).length);
      final dur = math.max(1, ((wordCount * 60.0) / wpm).ceil());
      chunks.add(_buildChunk(
        piece,
        configuredVoice: configuredVoice,
        variant: variant,
        bilingual: bilingual,
        digitByDigit: digitByDigit,
        normalizeUnicode: normalizeUnicode,
        startSecond: running,
        durationSeconds: dur,
      ));
      running += dur;
    }
    return chunks;
  }

  /// Builds a single chunk (no splitting) for short utterances such as guidance prompts.
  static TtsChunk single(
    String text, {
    required String configuredVoice,
    String variant = 'none',
    bool bilingual = false,
    bool digitByDigit = false,
    bool normalizeUnicode = true,
  }) {
    return _buildChunk(
      text.trim(),
      configuredVoice: configuredVoice,
      variant: variant,
      bilingual: bilingual,
      digitByDigit: digitByDigit,
      normalizeUnicode: normalizeUnicode,
      startSecond: 0,
      durationSeconds: 1,
    );
  }

  /// Total duration estimate in seconds.
  static int estimateSeconds(String text, int rateWpm) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return 0;
    final chunks = plan(cleaned, configuredVoice: 'auto', rateWpm: rateWpm);
    if (chunks.isEmpty) return 1;
    return math.max(1, chunks.last.startSecond + chunks.last.durationSeconds);
  }
}
