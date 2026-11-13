import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../services/settings_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../theme/app_theme.dart';

/// Accessible audio playback bar (seek bar + rewind / play-pause / forward).
///
/// The bar hides itself when the built-in reader is disabled in settings.
class TtsPlaybackBar extends StatelessWidget {
  final String textToSpeak;
  final String title;
  final Widget? bookBody;
  final VoidCallback? previousPage;
  final VoidCallback? nextPage;

  const TtsPlaybackBar({
    super.key,
    required this.textToSpeak,
    this.title = '',
    this.bookBody,
    this.previousPage,
    this.nextPage,
  });

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);

    if (bookBody != null) return _buildBookPlayer(context, settings, l10n);
    if (!settings.enableInternalTts || textToSpeak.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final seekSec = settings.ttsSeekSeconds;
    final estimatedTotalSec = math.max(
      1,
      EspeakTtsService.estimateTotalSeconds(
          textToSpeak, settings.effectiveTtsRate),
    );

    return ValueListenableBuilder<TtsPlaybackState>(
      valueListenable: EspeakTtsService.playbackState,
      builder: (context, state, _) {
        final isActive = state.isActive;
        final isPlaying = state.isPlaying;
        final isPaused = state.isPaused;

        final totalSec = (isActive && state.totalSeconds > 0)
            ? state.totalSeconds
            : estimatedTotalSec;
        final currentSec =
            isActive ? state.currentSeconds.clamp(0, totalSec) : 0;
        final percent = totalSec > 0
            ? ((currentSec * 100) / totalSec).round().clamp(0, 100)
            : 0;
        final timeDisplay =
            '${TtsPlaybackState.formatSeconds(currentSec)} / ${TtsPlaybackState.formatSeconds(totalSec)}';

        final String playLabel = isPlaying
            ? l10n.tx('Pause', 'توقف موقت')
            : (isPaused
                ? l10n.tx('Resume', 'ادامه پخش')
                : l10n.tx('Play audio', 'پخش صوتی'));

        final headerTitle = title.trim().isNotEmpty
            ? title
            : l10n.tx('Audio player', 'پخش‌کننده صوتی');

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: AppTheme.primaryCyan.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: AppTheme.primaryCyan.withValues(alpha: 0.45),
              width: 1.2,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header: the title is read once; the time text is covered by the slider.
                Row(
                  children: [
                    const ExcludeSemantics(
                      child: Icon(
                        Icons.graphic_eq_rounded,
                        color: AppTheme.primaryCyan,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        headerTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                    ExcludeSemantics(
                      child: Text(
                        '$timeDisplay ($percent%)',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isPlaying
                              ? AppTheme.successGreen
                              : (isPaused
                                  ? Colors.orangeAccent
                                  : AppTheme.primaryCyan),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),

                // Seek bar: one slider node.
                Semantics(
                  label: l10n.tx('Reading progress', 'پیشرفت خوانش'),
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: Slider(
                      value: currentSec.toDouble(),
                      min: 0,
                      max: math.max(1, totalSec).toDouble(),
                      divisions: math.max(1, math.min(100, totalSec)),
                      activeColor: AppTheme.primaryCyan,
                      semanticFormatterCallback: (val) {
                        final sec = val.round();
                        final pct =
                            totalSec > 0 ? ((sec * 100) / totalSec).round() : 0;
                        return l10n.tx(
                          '$pct percent, ${TtsPlaybackState.formatSeconds(sec)} of ${TtsPlaybackState.formatSeconds(totalSec)}',
                          '$pct درصد، ${TtsPlaybackState.formatSeconds(sec)} از ${TtsPlaybackState.formatSeconds(totalSec)}',
                        );
                      },
                      onChanged: (val) {
                        EspeakTtsService.seekToSecond(
                          val.round(),
                          settings,
                          fallbackText: textToSpeak,
                          title: title,
                        );
                      },
                    ),
                  ),
                ),

                // Transport controls.
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _TransportButton(
                      semanticLabel: l10n.tx(
                        'Rewind $seekSec seconds',
                        '$seekSec ثانیه به عقب',
                      ),
                      icon: Icons.fast_rewind_rounded,
                      visibleLabel: '-$seekSec',
                      onPressed: isActive
                          ? () =>
                              EspeakTtsService.seekBySeconds(-seekSec, settings)
                          : null,
                    ),
                    ElevatedButton.icon(
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 22,
                      ),
                      label: Text(
                        playLabel,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isPlaying
                            ? Colors.amber.shade700
                            : AppTheme.primaryCyan,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                      ),
                      onPressed: () => _onPlayPressed(settings, isActive),
                    ),
                    _TransportButton(
                      semanticLabel: l10n.tx(
                        'Forward $seekSec seconds',
                        '$seekSec ثانیه به جلو',
                      ),
                      icon: Icons.fast_forward_rounded,
                      visibleLabel: '+$seekSec',
                      onPressed: isActive
                          ? () =>
                              EspeakTtsService.seekBySeconds(seekSec, settings)
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBookPlayer(
      BuildContext context, SettingsService settings, AppLocalizations l10n) {
    Widget control(IconData icon, String label, VoidCallback? onPressed) =>
        IconButton(tooltip: label, onPressed: onPressed, icon: Icon(icon));

    return ValueListenableBuilder<TtsPlaybackState>(
      valueListenable: EspeakTtsService.playbackState,
      builder: (context, state, _) {
        final available =
            settings.enableInternalTts && textToSpeak.trim().isNotEmpty;
        final active = EspeakTtsService.isActiveText(textToSpeak);
        final playing = active && state.isPlaying;
        final paused = active && state.isPaused;
        final total = math.max(
            1,
            active
                ? state.totalSeconds
                : EspeakTtsService.estimateTotalSeconds(
                    textToSpeak, settings.effectiveTtsRate));
        final position = active ? state.currentSeconds.clamp(0, total) : 0;
        final step = settings.ttsSeekSeconds;
        final playLabel = playing
            ? l10n.tx('Pause', 'توقف موقت')
            : paused
                ? l10n.tx('Resume', 'ادامهٔ پخش')
                : l10n.tx('Play audio', 'پخش صوتی');
        return Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: bookBody!),
                  if (available)
                    SizedBox(
                      width: 55,
                      child: Column(
                        children: [
                          ExcludeSemantics(
                              child: Text(
                                  TtsPlaybackState.formatSeconds(position))),
                          Expanded(
                            child: Semantics(
                              label:
                                  l10n.tx('Audio position', 'موقعیت پخش صوتی'),
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Directionality(
                                  textDirection: TextDirection.ltr,
                                  child: Slider(
                                    min: 0,
                                    max: total.toDouble(),
                                    value: position.toDouble(),
                                    divisions: math.min(100, total),
                                    semanticFormatterCallback: (value) => l10n.tx(
                                        '${TtsPlaybackState.formatSeconds(value.round())} of ${TtsPlaybackState.formatSeconds(total)}',
                                        '${TtsPlaybackState.formatSeconds(value.round())} از ${TtsPlaybackState.formatSeconds(total)}'),
                                    onChanged: (value) async {
                                      if (!active) {
                                        await EspeakTtsService.stop();
                                      }
                                      await EspeakTtsService.seekToSecond(
                                          value.round(), settings,
                                          fallbackText: textToSpeak,
                                          title: title);
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                          ExcludeSemantics(
                              child:
                                  Text(TtsPlaybackState.formatSeconds(total))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                control(Icons.skip_previous_rounded,
                    l10n.translate('prev_page'), previousPage),
                if (settings.enableInternalTts) ...[
                  control(
                      Icons.fast_rewind_rounded,
                      l10n.tx('Rewind $step seconds', '$step ثانیه به عقب'),
                      available && active
                          ? () =>
                              EspeakTtsService.seekBySeconds(-step, settings)
                          : null),
                  control(
                      Icons.replay_rounded,
                      l10n.tx('Replay page', 'پخش صفحه از ابتدا'),
                      available
                          ? () => EspeakTtsService.speak(textToSpeak,
                              settings: settings, title: title)
                          : null),
                  IconButton.filled(
                    tooltip: playLabel,
                    onPressed: available
                        ? () => _onPlayPressed(settings, active)
                        : null,
                    icon: Icon(playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                  ),
                  control(
                      Icons.fast_forward_rounded,
                      l10n.tx('Forward $step seconds', '$step ثانیه به جلو'),
                      available && active
                          ? () => EspeakTtsService.seekBySeconds(step, settings)
                          : null),
                ],
                control(Icons.skip_next_rounded, l10n.translate('next_page'),
                    nextPage),
              ],
            ),
          ],
        );
      },
    );
  }

  void _onPlayPressed(SettingsService settings, bool isActive) {
    if (isActive) {
      EspeakTtsService.togglePlayPause(settings);
    } else {
      EspeakTtsService.speak(textToSpeak, settings: settings, title: title);
    }
  }
}

class _TransportButton extends StatelessWidget {
  final String semanticLabel;
  final IconData icon;
  final String visibleLabel;
  final VoidCallback? onPressed;

  const _TransportButton({
    required this.semanticLabel,
    required this.icon,
    required this.visibleLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(
        visibleLabel,
        semanticsLabel: semanticLabel,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
      ),
      onPressed: onPressed,
    );
  }
}
