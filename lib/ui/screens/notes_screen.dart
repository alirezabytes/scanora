import '../widgets/accessible_dropdown_field.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/note_item.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/export/docx_exporter.dart';
import '../../services/settings_service.dart';
import '../widgets/online_access_guard.dart';
import '../../services/storage/app_storage_service.dart';
import '../../services/stt/whisper_onnx_service.dart';
import '../../services/stt/speech_to_text_service.dart';
import '../../services/tts/espeak_tts_service.dart';
import '../theme/app_theme.dart';
import '../widgets/accessible_output_text.dart';
import '../widgets/output_file_name_field.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/tts_playback_bar.dart';

class NotesScreen extends StatefulWidget {
  final GlobalKey<NotesScreenState>? customKey;
  const NotesScreen({Key? key, this.customKey}) : super(key: key ?? customKey);

  @override
  State<NotesScreen> createState() => NotesScreenState();
}

class NotesScreenState extends State<NotesScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  String _selectedFilter = 'all'; // 'all', 'quote', 'image', 'personal'
  bool _isEditing = false;

  bool get hasActiveContent => _isEditing;

  void resetScreen() {
    setState(() {
      _searchQuery = '';
      _searchController.clear();
      _selectedFilter = 'all';
      _isEditing = false;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<String?> _openVoiceToTextDialog(
    BuildContext context,
    AppLocalizations l10n,
    SettingsService settings, {
    required bool saveDirectlyAsNote,
  }) async {
    if (!await OnlineAccessGuard.require(context, settings,
            task: OnlineTask.speech) ||
        !context.mounted) {
      return null;
    }
    bool isRecording = false;
    bool isTranscribing = false;
    bool discardRequested = false;
    Future<bool>? cancelConfirmation;
    int recordingSeconds = 0;
    Timer? recordingTimer;
    // Pre-initialize Whisper ONNX models in the background while the user speaks
    if (settings.isOfflineMode) {
      unawaited(
          WhisperOnnxService.ensureLoaded(accurate: settings.accurateSpeech)
              .catchError((Object _) {}));
    }

    String statusText = l10n.isPersian
        ? 'آماده ضبط صدا یا انتخاب فایل صوتی'
        : 'Ready to record voice or select an audio file';
    String preferredLang = 'auto';
    String transcriptionEngine = '';

    String formatDuration(int totalSeconds) {
      final mins = (totalSeconds ~/ 60).toString().padLeft(2, '0');
      final secs = (totalSeconds % 60).toString().padLeft(2, '0');
      return '$mins:$secs';
    }

    final transcribed = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            Future<void> acceptTranscript(String text) async {
              final pending = cancelConfirmation;
              if (pending != null && await pending) return;
              if (dialogCtx.mounted && !discardRequested) {
                Navigator.pop(dialogCtx, text);
              }
            }

            Future<void> cancelVoiceNote() async {
              if (cancelConfirmation != null || discardRequested) return;
              if (isRecording || isTranscribing) {
                final confirmation = confirmCancelOperation(dialogCtx);
                cancelConfirmation = confirmation;
                final confirmed = await confirmation;
                cancelConfirmation = null;
                if (!confirmed || !dialogCtx.mounted) return;
              }
              discardRequested = true;
              recordingTimer?.cancel();
              recordingTimer = null;
              if (WhisperOnnxService.isRecording) {
                await WhisperOnnxService.stopMicrophoneRecording(
                    deleteTemp: true);
              }
              if (dialogCtx.mounted) Navigator.pop(dialogCtx);
            }

            Future<void> toggleMicRecording() async {
              if (isTranscribing) return;
              if (!isRecording) {
                if (!await OnlineAccessGuard.require(dialogCtx, settings,
                        task: OnlineTask.speech) ||
                    !dialogCtx.mounted) {
                  return;
                }
                try {
                  unawaited(SystemSound.play(SystemSoundType.click));
                  unawaited(HapticFeedback.mediumImpact());
                  final started =
                      await WhisperOnnxService.startMicrophoneRecording();
                  if (!dialogCtx.mounted || discardRequested) {
                    if (started) {
                      await WhisperOnnxService.stopMicrophoneRecording(
                          deleteTemp: true);
                    }
                    return;
                  }
                  if (!started) {
                    final msg = l10n.isPersian
                        ? 'دسترسی به میکروفون امکان‌پذیر نیست یا میکروفون فعالی یافت نشد.'
                        : 'Microphone permission unavailable or no active microphone found.';
                    setDialogState(() {
                      statusText = msg;
                    });
                    AccessibilityService.announce(dialogCtx, msg);
                    return;
                  }
                  final msg = l10n.isPersian
                      ? 'در حال ضبط صدا... صحبت کنید و پس از اتمام دکمه توقف را بزنید.'
                      : 'Recording voice... Speak now and press Stop when finished.';
                  recordingTimer?.cancel();
                  recordingSeconds = 0;
                  setDialogState(() {
                    isRecording = true;
                    statusText = msg;
                  });
                  recordingTimer = Timer.periodic(
                    const Duration(seconds: 1),
                    (_) {
                      if (dialogCtx.mounted && isRecording) {
                        setDialogState(() {
                          recordingSeconds++;
                        });
                      }
                    },
                  );
                  AccessibilityService.announce(dialogCtx, msg);
                } catch (e) {
                  recordingTimer?.cancel();
                  recordingTimer = null;
                  if (!dialogCtx.mounted) return;
                  final msg = l10n.translate(
                    'error_general',
                    {'error': e.toString()},
                  );
                  setDialogState(() {
                    isRecording = false;
                    statusText = msg;
                  });
                  AccessibilityService.announce(dialogCtx, msg);
                }
              } else {
                recordingTimer?.cancel();
                recordingTimer = null;
                unawaited(SystemSound.play(SystemSoundType.click));
                final processingMsg = l10n.isPersian
                    ? 'در حال تبدیل گفتار به متن...'
                    : 'Converting speech to text...';
                setDialogState(() {
                  isRecording = false;
                  isTranscribing = true;
                  statusText = processingMsg;
                });
                AccessibilityService.announce(dialogCtx, processingMsg);
                OnlineAccessGuard.announceProcessing(dialogCtx, settings,
                    task: OnlineTask.speech);
                final wavBytes =
                    await WhisperOnnxService.stopMicrophoneRecording();
                if (!dialogCtx.mounted) return;
                if (wavBytes == null || wavBytes.isEmpty) {
                  final emptyMsg = l10n.isPersian
                      ? 'صدایی ضبط نشد.'
                      : 'No audio was recorded.';
                  setDialogState(() {
                    isTranscribing = false;
                    statusText = emptyMsg;
                  });
                  AccessibilityService.announce(dialogCtx, emptyMsg);
                  return;
                }
                try {
                  final res = await SpeechToTextService.transcribeWavBytes(
                    wavBytes,
                    settings: settings,
                    onEngine: (engine) {
                      transcriptionEngine = engine.contains('offline')
                          ? l10n.tx('without internet', 'بدون اینترنت')
                          : l10n.tx('online', 'آنلاین');
                      if (dialogCtx.mounted) {
                        setDialogState(() => statusText = l10n.tx(
                            engine.contains('offline')
                                ? 'Reading recording without internet…'
                                : 'Reading recording online…',
                            engine.contains('offline')
                                ? 'در حال خواندن صدای ضبط‌شده بدون اینترنت…'
                                : 'در حال خواندن آنلاین صدای ضبط‌شده…'));
                        AccessibilityService.announce(dialogCtx, statusText);
                      }
                    },
                    onProgress: (percent) {
                      if (dialogCtx.mounted) {
                        setDialogState(() {
                          statusText = l10n.tx('Transcribing: $percent%',
                              'تبدیل گفتار: $percent درصد');
                        });
                      }
                    },
                    preferredLanguage:
                        preferredLang == 'auto' ? null : preferredLang,
                  );
                  if (!dialogCtx.mounted) return;
                  if (res.text.trim().isEmpty) {
                    final noSpeechMsg = l10n.isPersian
                        ? 'گفتاری در فایل صوتی تشخیص داده نشد.'
                        : 'No speech detected in the recording.';
                    setDialogState(() {
                      isTranscribing = false;
                      statusText = noSpeechMsg;
                    });
                    AccessibilityService.announce(dialogCtx, noSpeechMsg);
                  } else {
                    await acceptTranscript(res.text.trim());
                  }
                } catch (e) {
                  if (!dialogCtx.mounted) return;
                  final errMsg = l10n.translate(
                    'error_general',
                    {'error': e.toString()},
                  );
                  setDialogState(() {
                    isTranscribing = false;
                    statusText = errMsg;
                  });
                  AccessibilityService.announce(dialogCtx, errMsg);
                }
              }
            }

            Future<void> pickAudioFile() async {
              if (isRecording || isTranscribing) return;
              if (!await OnlineAccessGuard.require(dialogCtx, settings,
                      task: OnlineTask.speech) ||
                  !dialogCtx.mounted) {
                return;
              }
              try {
                final picked = await FilePicker.pickFiles(
                  type: Platform.isAndroid ? FileType.any : FileType.custom,
                  allowedExtensions: Platform.isAndroid ? null : const ['wav'],
                );
                if (picked.isEmpty) return;
                final fileObj = picked.first;
                Uint8List? audioBytes;
                try {
                  audioBytes = await fileObj.readAsBytes();
                } catch (_) {
                  if (fileObj.path != null) {
                    audioBytes = await File(fileObj.path!).readAsBytes();
                  }
                }
                if (audioBytes == null || audioBytes.isEmpty) return;
                if (!dialogCtx.mounted) return;
                setDialogState(() {
                  isTranscribing = true;
                  statusText = l10n.isPersian
                      ? 'در حال تبدیل فایل صوتی به متن...'
                      : 'Converting audio file to text...';
                });
                OnlineAccessGuard.announceProcessing(dialogCtx, settings,
                    task: OnlineTask.speech);
                final res = await SpeechToTextService.transcribeWavBytes(
                  audioBytes,
                  settings: settings,
                  onEngine: (engine) {
                    transcriptionEngine = engine.contains('offline')
                        ? l10n.tx('without internet', 'بدون اینترنت')
                        : l10n.tx('online', 'آنلاین');
                    if (dialogCtx.mounted) {
                      setDialogState(() => statusText = l10n.tx(
                          'Reading recording…', 'در حال خواندن صدای ضبط‌شده…'));
                      AccessibilityService.announce(dialogCtx, statusText);
                    }
                  },
                  onProgress: (percent) {
                    if (dialogCtx.mounted) {
                      setDialogState(() {
                        statusText = l10n.tx('Transcribing: $percent%',
                            'تبدیل گفتار: $percent درصد');
                      });
                    }
                  },
                  preferredLanguage:
                      preferredLang == 'auto' ? null : preferredLang,
                );
                if (!dialogCtx.mounted) return;
                if (res.text.trim().isEmpty) {
                  setDialogState(() {
                    isTranscribing = false;
                    statusText = l10n.isPersian
                        ? 'گفتاری در فایل صوتی تشخیص داده نشد.'
                        : 'No speech detected in audio file.';
                  });
                } else {
                  await acceptTranscript(res.text.trim());
                }
              } catch (e) {
                if (!dialogCtx.mounted) return;
                setDialogState(() {
                  isTranscribing = false;
                  statusText =
                      l10n.translate('error_general', {'error': e.toString()});
                });
              }
            }

            return PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) cancelVoiceNote();
              },
              child: AlertDialog(
                title: Text(
                  l10n.isPersian ? 'یادداشت صوتی' : 'Voice Note',
                ),
                content: SizedBox(
                  width: 460,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        liveRegion: settings.announceProgress ||
                            !RegExp(r'%|درصد').hasMatch(statusText),
                        child: Text(
                          statusText,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const SizedBox(height: 14),
                      AccessibleDropdownField<String>(
                        initialValue: preferredLang,
                        decoration: InputDecoration(
                          labelText:
                              l10n.isPersian ? 'زبان گفتار' : 'Speech Language',
                          border: const OutlineInputBorder(),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'en',
                            child: Text(l10n.isPersian ? 'انگلیسی' : 'English'),
                          ),
                          DropdownMenuItem(
                            value: 'fa',
                            child: Text(l10n.isPersian ? 'فارسی' : 'Persian'),
                          ),
                          DropdownMenuItem(
                            value: 'auto',
                            child: Text(
                              l10n.isPersian
                                  ? 'تشخیص خودکار زبان'
                                  : 'Auto-Detect Language',
                            ),
                          ),
                        ],
                        onChanged: (isRecording || isTranscribing)
                            ? null
                            : (val) {
                                if (val != null) {
                                  setDialogState(() => preferredLang = val);
                                }
                              },
                      ),
                      const SizedBox(height: 16),
                      if (isTranscribing)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: CircularProgressIndicator(
                                color: AppTheme.primaryCyan),
                          ),
                        )
                      else ...[
                        SizedBox(
                          height: 50,
                          child: ElevatedButton.icon(
                            icon: Icon(
                              isRecording
                                  ? Icons.stop_circle_rounded
                                  : Icons.mic_rounded,
                            ),
                            label: Text(
                              isRecording
                                  ? (l10n.isPersian
                                      ? 'توقف ضبط و تبدیل به متن (${formatDuration(recordingSeconds)})'
                                      : 'Stop Recording & Transcribe (${formatDuration(recordingSeconds)})')
                                  : (l10n.isPersian
                                      ? 'شروع ضبط یادداشت صوتی'
                                      : 'Start Voice Recording'),
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isRecording
                                  ? AppTheme.errorRed
                                  : AppTheme.primaryCyan,
                              foregroundColor:
                                  isRecording ? Colors.white : Colors.black,
                            ),
                            onPressed: toggleMicRecording,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 46,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.audio_file_rounded),
                            label: Text(
                              l10n.isPersian
                                  ? 'انتخاب فایل صوتی از دستگاه'
                                  : 'Select Audio File from Device',
                            ),
                            onPressed: isRecording ? null : pickAudioFile,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    autofocus: true,
                    onPressed: cancelVoiceNote,
                    child: Text(l10n.translate('cancel')),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    recordingTimer?.cancel();
    if (WhisperOnnxService.isRecording) {
      await WhisperOnnxService.stopMicrophoneRecording(deleteTemp: true);
    }

    if (transcribed != null && transcribed.isNotEmpty && context.mounted) {
      if (saveDirectlyAsNote) {
        final title = transcribed.length > 32
            ? '${transcribed.substring(0, 32)}...'
            : transcribed;
        settings.addNote(
          NoteItem(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            title: title,
            content: transcribed,
            source: 'manual',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            tags: const ['personal'],
          ),
        );
        AccessibilityService.announce(
          context,
          l10n.isPersian
              ? 'یادداشت صوتی تبدیل و ذخیره شد ($transcriptionEngine): $transcribed'
              : 'Voice note transcribed and saved ($transcriptionEngine): $transcribed',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.isPersian
                  ? 'یادداشت صوتی با موفقیت به متن تبدیل و ذخیره شد!'
                  : 'Voice note transcribed and saved!',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
    return transcribed;
  }

  void _openNoteEditor(
    BuildContext context,
    AppLocalizations l10n,
    SettingsService settings, {
    NoteItem? existingNote,
  }) {
    final titleController =
        TextEditingController(text: existingNote?.title ?? '');
    final contentController =
        TextEditingController(text: existingNote?.content ?? '');
    String selectedTag = existingNote?.tags.isNotEmpty == true
        ? existingNote!.tags.first
        : 'personal';

    setState(() => _isEditing = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              title: Text(
                existingNote == null
                    ? (l10n.isPersian ? 'یادداشت جدید' : 'New Note')
                    : (l10n.isPersian ? 'ویرایش یادداشت' : 'Edit Note'),
              ),
              content: SizedBox(
                width: 550,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: titleController,
                        decoration: InputDecoration(
                          labelText:
                              l10n.isPersian ? 'عنوان یادداشت' : 'Note Title',
                          hintText: l10n.isPersian
                              ? 'مثلاً جمله جالب کتاب...'
                              : 'e.g. Interesting quote...',
                          prefixIcon: const Icon(Icons.title_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      AccessibleDropdownField<String>(
                        initialValue: selectedTag,
                        decoration: InputDecoration(
                          labelText: l10n.isPersian
                              ? 'دسته‌بندی / موضوع'
                              : 'Category / Tag',
                          prefixIcon: const Icon(Icons.label_outline_rounded),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'quote',
                            child: Text(
                              l10n.isPersian
                                  ? '📖 نقل‌قول و بریده کتاب'
                                  : '📖 Book Quote',
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'personal',
                            child: Text(
                              l10n.isPersian
                                  ? '✍️ یادداشت شخصی'
                                  : '✍️ Personal Note',
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'work',
                            child: Text(
                              l10n.isPersian
                                  ? '💼 کاری و پژوهشی'
                                  : '💼 Work & Research',
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'idea',
                            child: Text(
                              l10n.isPersian
                                  ? '💡 ایده و نکته مهم'
                                  : '💡 Idea & Insight',
                            ),
                          ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() => selectedTag = val);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            l10n.isPersian ? 'متن یادداشت:' : 'Note Content:',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Wrap(
                            spacing: 6,
                            children: [
                              TextButton.icon(
                                icon: const Icon(Icons.mic_rounded, size: 16),
                                label: Text(
                                  l10n.isPersian
                                      ? 'تایپ صوتی'
                                      : 'Voice Dictation',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () async {
                                  final text = await _openVoiceToTextDialog(
                                    dialogCtx,
                                    l10n,
                                    settings,
                                    saveDirectlyAsNote: false,
                                  );
                                  if (text != null && text.isNotEmpty) {
                                    contentController.text =
                                        '${contentController.text}\n$text'
                                            .trim();
                                  }
                                },
                              ),
                              TextButton.icon(
                                icon: const Icon(Icons.paste_rounded, size: 16),
                                label: Text(
                                  l10n.isPersian
                                      ? 'پیست از کلیپ‌بورد'
                                      : 'Paste from Clipboard',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () async {
                                  final clip =
                                      await Clipboard.getData('text/plain');
                                  if (clip?.text != null &&
                                      clip!.text!.isNotEmpty) {
                                    contentController.text =
                                        '${contentController.text}\n${clip.text}'
                                            .trim();
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: contentController,
                        maxLines: 8,
                        minLines: 4,
                        decoration: InputDecoration(
                          labelText:
                              l10n.isPersian ? 'متن یادداشت' : 'Note Content',
                          hintText: l10n.isPersian
                              ? 'متن یادداشت را اینجا بنویسید یا پیست کنید...'
                              : 'Write or paste your note here...',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() => _isEditing = false);
                  },
                  child: Text(l10n.translate('cancel')),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.save_rounded, size: 18),
                  label: Text(l10n.isPersian ? 'ذخیره یادداشت' : 'Save Note'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryCyan,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () {
                    final content = contentController.text.trim();
                    if (content.isEmpty) return;

                    final title = titleController.text.trim().isNotEmpty
                        ? titleController.text.trim()
                        : (content.length > 30
                            ? '${content.substring(0, 30)}...'
                            : content);

                    if (existingNote == null) {
                      settings.addNote(
                        NoteItem(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          title: title,
                          content: content,
                          source: 'manual',
                          createdAt: DateTime.now(),
                          updatedAt: DateTime.now(),
                          tags: [selectedTag],
                        ),
                      );
                    } else {
                      settings.updateNote(
                        existingNote.copyWith(
                          title: title,
                          content: content,
                          updatedAt: DateTime.now(),
                          tags: [selectedTag],
                        ),
                      );
                    }

                    Navigator.pop(ctx);
                    setState(() => _isEditing = false);

                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          l10n.isPersian
                              ? 'یادداشت با موفقیت ذخیره شد!'
                              : 'Note saved successfully!',
                        ),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Export dialog with NO default format selected (`String? format = null`),
  /// requiring the user to explicitly choose their desired export format.
  void _exportNoteDialog(
      BuildContext context, AppLocalizations l10n, NoteItem note) {
    String? format;
    var outputStem = note.title;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              title: Text(
                l10n.isPersian
                    ? 'خروجی صوتی و متنی یادداشت'
                    : 'Export Note (Audio & Text)',
              ),
              content: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OutputFileNameField(
                    initialName: outputStem,
                    extension: format,
                    onChanged: (value) =>
                        setDialogState(() => outputStem = value),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.translate('select_format'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: EdgeInsets.zero,
                    child: AccessibleDropdownField<String>(
                      initialValue: format,
                      hint: Text(
                        l10n.isPersian
                            ? 'یک فرمت خروجی انتخاب کنید...'
                            : 'Select an export format...',
                      ),
                      decoration: InputDecoration(
                        labelText: l10n.translate('select_format'),
                        border: const OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'wav',
                          child: Text('🎧  Audio WAV - eSpeak-NG (.wav)'),
                        ),
                        DropdownMenuItem(
                          value: 'docx',
                          child: Text('📘  Microsoft Word (.docx)'),
                        ),
                        DropdownMenuItem(
                          value: 'rtf',
                          child: Text('📄  Rich Text (.rtf)'),
                        ),
                        DropdownMenuItem(
                          value: 'txt',
                          child: Text('📄  Plain Text (.txt)'),
                        ),
                        DropdownMenuItem(
                          value: 'md',
                          child: Text('📝  Markdown (.md)'),
                        ),
                        DropdownMenuItem(
                          value: 'html',
                          child: Text('🌐  HTML Document (.html)'),
                        ),
                        DropdownMenuItem(
                          value: 'json',
                          child: Text('📊  JSON (.json)'),
                        ),
                      ],
                      onChanged: (val) {
                        setDialogState(() => format = val);
                      },
                    ),
                  ),
                ],
              )),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l10n.translate('cancel')),
                ),
                ElevatedButton(
                  onPressed: format == null || outputStem.trim().isEmpty
                      ? null
                      : () async {
                          final chosen = format!;
                          Navigator.pop(ctx);
                          await _executeNoteExport(
                              chosen, note, outputStem, l10n);
                        },
                  child: Text(l10n.translate('export_confirm')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _executeNoteExport(
    String format,
    NoteItem note,
    String outputStem,
    AppLocalizations l10n,
  ) async {
    try {
      final fileName = AppStorageService.outputName(outputStem, format);
      final settings = Provider.of<SettingsService>(context, listen: false);
      File savedFile;

      if (format == 'wav') {
        final wavBytes = await EspeakTtsService.synthesizeToWavBytes(
          '${note.title}.\n\n${note.content}',
          settings: settings,
        );
        savedFile = await AppStorageService.saveFile(
          fileName: fileName,
          bytes: wavBytes,
          customDirectory: settings.exportDirectoryPath,
        );
      } else if (format == 'docx') {
        final paragraphs = <String>[
          l10n.isPersian
              ? 'تاریخ: ${_formatDate(note.createdAt)}'
              : 'Date: ${_formatDate(note.createdAt)}',
          if (note.tags.isNotEmpty)
            (l10n.isPersian
                ? 'دسته‌بندی: ${note.tags.join(", ")}'
                : 'Tags: ${note.tags.join(", ")}'),
          '',
          note.content,
        ];
        final bytes = DocxExporter.createDocx(
          title: note.title,
          paragraphs: paragraphs,
          isRtl: l10n.isPersian || l10n.isRtl,
        );
        savedFile = await AppStorageService.saveFile(
          fileName: fileName,
          bytes: bytes,
          customDirectory: settings.exportDirectoryPath,
        );
      } else if (format == 'rtf') {
        final paragraphs = <String>[
          l10n.isPersian
              ? 'تاریخ: ${_formatDate(note.createdAt)}'
              : 'Date: ${_formatDate(note.createdAt)}',
          if (note.tags.isNotEmpty)
            (l10n.isPersian
                ? 'دسته‌بندی: ${note.tags.join(", ")}'
                : 'Tags: ${note.tags.join(", ")}'),
          '',
          note.content,
        ];
        final bytes = DocxExporter.createRtf(
          title: note.title,
          paragraphs: paragraphs,
          isRtl: l10n.isPersian || l10n.isRtl,
        );
        savedFile = await AppStorageService.saveFile(
          fileName: fileName,
          bytes: bytes,
          customDirectory: settings.exportDirectoryPath,
        );
      } else {
        String outContent = '';
        if (format == 'txt') {
          outContent =
              '${note.title}\n${'=' * note.title.length}\n${l10n.tx('Date', 'تاریخ')}: ${note.createdAt}\n\n${note.content}';
        } else if (format == 'md') {
          outContent =
              '# ${note.title}\n\n*Created: ${note.createdAt}*\n\n---\n\n${note.content}';
        } else if (format == 'html') {
          outContent =
              '<!DOCTYPE html><html><head><meta charset="utf-8"><title>${const HtmlEscape().convert(note.title)}</title></head><body><h1>${const HtmlEscape().convert(note.title)}</h1><small>${note.createdAt}</small><hr><p>${const HtmlEscape().convert(note.content).replaceAll('\n', '<br>')}</p></body></html>';
        } else if (format == 'json') {
          outContent = jsonEncode(note.toMap());
        }
        savedFile = await AppStorageService.saveString(
          fileName: fileName,
          content: outContent,
          customDirectory: settings.exportDirectoryPath,
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
                l10n.translate('export_success', {'path': savedFile.path})),
            persist: false,
            action: SnackBarAction(
              label: l10n.isPersian ? 'باز کردن پوشه' : 'Open Folder',
              onPressed: () => AppStorageService.highlightFile(savedFile.path),
            ),
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(l10n.translate('error_general', {'error': e.toString()})),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _confirmDeleteAll(
    BuildContext context,
    AppLocalizations l10n,
    SettingsService settings,
  ) async {
    final confirmed = await showSafeConfirmDialog(
      context,
      title: l10n.isPersian ? 'پاکسازی تمام یادداشت‌ها' : 'Delete All Notes',
      message: l10n.isPersian
          ? 'آیا از حذف تمام یادداشت‌ها (${settings.notes.length} یادداشت) اطمینان دارید؟ این عملیات غیرقابل بازگشت است.'
          : 'Are you sure you want to delete all ${settings.notes.length} notes? This cannot be undone.',
      confirmLabel: l10n.isPersian ? 'حذف همه' : 'Delete All',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    settings.clearAllNotes();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.isPersian
              ? 'همه یادداشت‌ها پاکسازی شدند.'
              : 'All notes have been cleared.',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppLocalizations l10n,
    SettingsService settings,
    NoteItem note,
  ) async {
    final confirmed = await showSafeConfirmDialog(
      context,
      title: l10n.isPersian ? 'حذف یادداشت' : 'Delete Note',
      message: l10n.isPersian
          ? 'آیا از حذف یادداشت «${note.title}» اطمینان دارید؟'
          : 'Are you sure you want to delete "${note.title}"?',
      confirmLabel: l10n.isPersian ? 'حذف' : 'Delete',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    settings.deleteNote(note.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.isPersian ? 'یادداشت حذف شد.' : 'Note deleted.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final l10n = AppLocalizations.of(context);

    final filteredNotes = settings.notes.where((n) {
      if (_selectedFilter != 'all') {
        if (_selectedFilter == 'quote' &&
            !n.tags.contains('quote') &&
            n.source != 'pdf_reader') {
          return false;
        }
        if (_selectedFilter == 'image' &&
            n.source != 'image_to_text' &&
            n.source != 'ocr' &&
            !n.tags.contains('ocr')) {
          return false;
        }
        if (_selectedFilter == 'personal' &&
            !n.tags.contains('personal') &&
            n.source != 'manual') {
          return false;
        }
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchTitle = n.title.toLowerCase().contains(q);
        final matchContent = n.content.toLowerCase().contains(q);
        return matchTitle || matchContent;
      }
      return true;
    }).toList();

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.isPersian
                          ? 'دفترچه یادداشت‌های هوشمند'
                          : 'Smart Notes & Quotes',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      l10n.isPersian
                          ? 'فیلتر موضوعی، خروجی متنی/صوتی و یادداشت صوتی'
                          : 'Topic filters, text/audio export & voice notes',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (settings.notes.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_rounded,
                            color: Colors.redAccent),
                        tooltip: l10n.isPersian
                            ? 'پاکسازی همه یادداشت‌ها'
                            : 'Clear All Notes',
                        onPressed: () =>
                            _confirmDeleteAll(context, l10n, settings),
                      ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.mic_rounded,
                          size: 18, color: AppTheme.primaryCyan),
                      label: Text(
                        l10n.isPersian
                            ? 'یادداشت صوتی (گفتار به متن)'
                            : 'Voice Note (Audio to Text)',
                      ),
                      onPressed: () => _openVoiceToTextDialog(
                        context,
                        l10n,
                        settings,
                        saveDirectlyAsNote: true,
                      ),
                    ),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: Text(l10n.isPersian ? 'یادداشت جدید' : 'New Note'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryCyan,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () => _openNoteEditor(context, l10n, settings),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText:
                    l10n.isPersian ? 'جستجو در یادداشت‌ها' : 'Search Notes',
                hintText: l10n.isPersian
                    ? 'جستجو در یادداشت‌ها و نقل‌قول‌ها...'
                    : 'Search inside notes & quotes...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        tooltip: l10n.translate('clear'),
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
              ),
              onChanged: (val) => setState(() => _searchQuery = val.trim()),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    label: Text(
                      l10n.isPersian
                          ? 'همه (${settings.notes.length})'
                          : 'All (${settings.notes.length})',
                    ),
                    selected: _selectedFilter == 'all',
                    onSelected: (_) => setState(() => _selectedFilter = 'all'),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: Text(
                        l10n.isPersian ? '📖 نقل‌قول کتاب' : '📖 Book Quotes'),
                    selected: _selectedFilter == 'quote',
                    onSelected: (_) =>
                        setState(() => _selectedFilter = 'quote'),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: Text(
                        l10n.isPersian ? '📷 متن اسکن‌شده' : '📷 Scanned Text'),
                    selected: _selectedFilter == 'image',
                    onSelected: (_) =>
                        setState(() => _selectedFilter = 'image'),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: Text(l10n.isPersian ? '✍️ شخصی' : '✍️ Personal'),
                    selected: _selectedFilter == 'personal',
                    onSelected: (_) =>
                        setState(() => _selectedFilter = 'personal'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (settings.enableInternalTts)
              ValueListenableBuilder<bool>(
                valueListenable: EspeakTtsService.isSpeakingNotifier,
                builder: (context, speaking, _) {
                  if (!speaking) return const SizedBox.shrink();
                  return TtsPlaybackBar(
                    textToSpeak: filteredNotes.isNotEmpty
                        ? '${filteredNotes.first.title}.\n${filteredNotes.first.content}'
                        : '',
                    title: l10n.isPersian
                        ? 'پخش صوتی یادداشت'
                        : 'Note Audio Playback',
                  );
                },
              ),
            if (filteredNotes.isEmpty)
              Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
                  child: Column(
                    children: [
                      Icon(
                        Icons.note_alt_outlined,
                        size: 64,
                        color: Colors.grey.withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        l10n.isPersian
                            ? 'هنوز یادداشتی ثبت نشده است.'
                            : 'No notes saved yet.',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.isPersian
                            ? 'می‌توانید یادداشت متنی یا صوتی جدید ثبت کنید، یا از بخش تبدیل عکس و کتاب‌خوان، متن‌های دلخواه را با یک کلیک اینجا ذخیره نمایید.'
                            : 'Create text or voice notes directly, or save excerpts from Image-to-Text and Document Reader in 1 tap.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            icon: const Icon(Icons.add_rounded),
                            label: Text(
                              l10n.isPersian
                                  ? 'ایجاد اولین یادداشت'
                                  : 'Create First Note',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryCyan,
                              foregroundColor: Colors.black,
                            ),
                            onPressed: () =>
                                _openNoteEditor(context, l10n, settings),
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.mic_rounded),
                            label: Text(
                              l10n.isPersian
                                  ? 'ثبت یادداشت صوتی'
                                  : 'Record Voice Note',
                            ),
                            onPressed: () => _openVoiceToTextDialog(
                              context,
                              l10n,
                              settings,
                              saveDirectlyAsNote: true,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: filteredNotes.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (ctx, idx) {
                  final note = filteredNotes[idx];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  note.title,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppTheme.accentIndigo
                                      .withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  note.tags.isNotEmpty
                                      ? note.tags.first
                                      : note.source,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.primaryCyan,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _formatDate(note.updatedAt),
                            style: TextStyle(
                              fontSize: 11,
                              color:
                                  Theme.of(context).textTheme.bodySmall?.color,
                            ),
                          ),
                          const Divider(height: 16),
                          AccessibleOutputText(
                            text: note.content,
                            liveRegion: false,
                            style: const TextStyle(fontSize: 14, height: 1.6),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              if (settings.enableInternalTts) ...[
                                IconButton.outlined(
                                  icon: const Icon(
                                    Icons.volume_up_rounded,
                                    size: 18,
                                    color: AppTheme.primaryCyan,
                                  ),
                                  tooltip: l10n.isPersian
                                      ? 'خواندن با eSpeak-NG'
                                      : 'Read Aloud (eSpeak-NG)',
                                  onPressed: () {
                                    EspeakTtsService.speak(
                                      '${note.title}.\n${note.content}',
                                      settings: settings,
                                    );
                                  },
                                ),
                                const SizedBox(width: 6),
                              ],
                              IconButton.outlined(
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                tooltip: l10n.translate('copy_text'),
                                onPressed: () {
                                  Clipboard.setData(
                                      ClipboardData(text: note.content));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content:
                                          Text(l10n.translate('text_copied')),
                                      duration: const Duration(seconds: 2),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 6),
                              IconButton.outlined(
                                icon: const Icon(Icons.edit_note_rounded,
                                    size: 18),
                                tooltip: l10n.isPersian ? 'ویرایش' : 'Edit',
                                onPressed: () => _openNoteEditor(
                                    context, l10n, settings,
                                    existingNote: note),
                              ),
                              const SizedBox(width: 6),
                              IconButton.outlined(
                                icon: const Icon(Icons.copy_all_rounded,
                                    size: 18),
                                tooltip: l10n.isPersian
                                    ? 'تکثیر یادداشت'
                                    : 'Duplicate',
                                onPressed: () {
                                  settings.duplicateNote(note.id);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        l10n.isPersian
                                            ? 'یادداشت تکثیر شد.'
                                            : 'Note duplicated.',
                                      ),
                                      duration: const Duration(seconds: 2),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 6),
                              IconButton.outlined(
                                icon: const Icon(Icons.download_rounded,
                                    size: 18),
                                tooltip: l10n.translate('export_btn'),
                                onPressed: () =>
                                    _exportNoteDialog(context, l10n, note),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: Colors.redAccent,
                                  size: 20,
                                ),
                                tooltip: l10n.isPersian ? 'حذف' : 'Delete',
                                onPressed: () => _confirmDelete(
                                    context, l10n, settings, note),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
