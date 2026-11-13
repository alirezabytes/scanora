import 'dart:math' as math;

const int ttsRateBoostMultiplier = 3;

enum TtsPunctuation {
  none(0, 0),
  some(3, 2, '@#\$%&*+=<>٪'),
  most(4, 2, r'@#$%&*+=<>/\|~^_[]{}().,!?;:-' '"\'،؛؟٪'),
  all(1, 1);

  const TtsPunctuation(this.preferenceValue, this.engineMode,
      [this.characters = '']);

  final int preferenceValue;
  final int engineMode;
  final String characters;

  static TtsPunctuation fromPreference(int? value) => switch (value) {
        0 => none,
        1 => all,
        2 || 4 => most, // The old custom level becomes Most.
        _ => some,
      };
}

/// Immutable snapshot of the playback position shown by the audio player bar.
class TtsPlaybackState {
  final bool isPlaying;
  final bool isPaused;
  final int currentSeconds;
  final int totalSeconds;
  final int currentChunkIndex;
  final int totalChunks;
  final String title;

  /// Text of the sentence that is being spoken right now (for synchronized highlighting).
  final String currentChunkText;

  /// Estimated duration of the current chunk in milliseconds.
  final int currentChunkDurationMs;

  /// Moment (monotonic, ms) at which the current chunk started playing.
  final int currentChunkStartedAtMs;

  const TtsPlaybackState({
    this.isPlaying = false,
    this.isPaused = false,
    this.currentSeconds = 0,
    this.totalSeconds = 0,
    this.currentChunkIndex = 0,
    this.totalChunks = 0,
    this.title = '',
    this.currentChunkText = '',
    this.currentChunkDurationMs = 0,
    this.currentChunkStartedAtMs = 0,
  });

  bool get isActive => isPlaying || isPaused;

  int get progressPercent => totalSeconds > 0
      ? ((currentSeconds * 100) / totalSeconds).round().clamp(0, 100)
      : 0;

  static String formatSeconds(int s) {
    final clamped = math.max(0, s);
    final m = clamped ~/ 60;
    final sec = clamped % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String get formattedPosition =>
      '${formatSeconds(currentSeconds)} / ${formatSeconds(totalSeconds)}';
}

/// One sentence-sized unit of speech. Sendable to the worker isolate (plain fields only).
class TtsChunk {
  /// Original text, used for highlighting and display.
  final String displayText;

  /// Full eSpeak-NG voice specification, e.g. `fa+f2`.
  final String voiceSpec;

  /// Text that is really handed to the engine (digits spaced, SSML markup applied).
  final String engineText;

  /// True when [engineText] contains SSML `<voice>` tags (seamless bilingual switching).
  final bool ssml;

  final int startSecond;
  final int durationSeconds;

  const TtsChunk({
    required this.displayText,
    required this.voiceSpec,
    required this.engineText,
    required this.ssml,
    required this.startSecond,
    required this.durationSeconds,
  });
}

/// The four voice controls and the rate boost shown in the voice dialog.
typedef TtsVoiceControls = ({
  int rate,
  int pitch,
  int pitchRange,
  int volume,
  bool rateBoost,
});

/// Acoustic parameters, already mapped to what the native engine understands.
class TtsEngineParams {
  final int rate;
  final int pitch;
  final int pitchRange;
  final int volume;

  /// eSpeak-NG word gap in units of 10 ms.
  final int wordGap;

  /// 0 = none, 1 = all, 2 = only [punctChars].
  final int punctuation;
  final String punctChars;

  /// 0 = none, 1 = sound icon, 2 = spoken, >= 3 raise pitch.
  final int capitalsMode;

  const TtsEngineParams({
    required this.rate,
    required this.pitch,
    required this.pitchRange,
    required this.volume,
    required this.wordGap,
    required this.punctuation,
    required this.punctChars,
    required this.capitalsMode,
  });
}

enum TtsEngineStatus { starting, ready, error }
