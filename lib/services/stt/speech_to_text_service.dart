import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../models/ai_provider.dart';
import '../ai/ai_service.dart';
import '../ai/ai_access.dart';
import '../ai/online_access_service.dart';
import '../settings_service.dart';
import 'whisper_onnx_service.dart';

class SpeechTranscriptionResult {
  final String text, engine;
  final bool isOffline;
  const SpeechTranscriptionResult(this.text, this.engine, this.isOffline);
}

class SpeechToTextService {
  static Future<SpeechTranscriptionResult> transcribeWavBytes(
    Uint8List bytes, {
    required SettingsService settings,
    String? preferredLanguage,
    void Function(int percent)? onProgress,
    void Function(String engine)? onEngine,
  }) async {
    final provider = settings.activeProvider;
    final key = settings.getApiKey(provider);
    if (!settings.isOfflineMode) {
      try {
        await OnlineAccessService.ensure(settings, task: OnlineTask.speech);
        final engine = provider == AIProviderType.openai
            ? 'OpenAI gpt-transcribe'
            : 'Gemini ${settings.getSelectedModel(provider)}';
        onEngine?.call(engine);
        final text = provider == AIProviderType.openai
            ? await transcribeOpenAI(bytes,
                key: key, language: preferredLanguage)
            : await AIService.transcribeGeminiAudio(
                apiKey: key,
                modelName: settings.getSelectedModel(provider),
                thinkingEffort: settings.thinkingEffort,
                wavBytes: bytes);
        onProgress?.call(100);
        return SpeechTranscriptionResult(
            text.trim() == '[NO_SPEECH]' ? '' : text.trim(), engine, false);
      } catch (error) {
        throw AiServiceException.fromError(error)
            .localized(settings.locale.languageCode == 'fa');
      }
    }
    final engine = settings.accurateSpeech
        ? 'Whisper Small (offline)'
        : 'Whisper Base (offline)';
    onEngine?.call(engine);
    final result = await WhisperOnnxService.transcribeWavBytes(bytes,
        preferredLanguage: preferredLanguage,
        accurate: settings.accurateSpeech,
        onProgress: onProgress);
    return SpeechTranscriptionResult(result.text, engine, true);
  }

  static Future<String> transcribeOpenAI(Uint8List bytes,
      {required String key, String? language}) async {
    await AiAccess.ensure(
        provider: AIProviderType.openai,
        apiKey: key,
        model: 'gpt-transcribe',
        baseUrl: '');
    if (bytes.length > 25 * 1024 * 1024) {
      throw const AiServiceException(AiFailureKind.inputTooLarge);
    }
    final client = http.Client();
    try {
      final request = http.MultipartRequest(
          'POST', Uri.https('api.openai.com', '/v1/audio/transcriptions'))
        ..headers['Authorization'] =
            'Bearer ${SettingsService.sanitizeKey(key)}'
        ..fields['model'] = 'gpt-transcribe'
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: 'scanora_recording.wav'));
      if (language == 'fa' || language == 'en') {
        request.fields['languages[]'] = language!;
      }
      final response = await http.Response.fromStream(
          await client.send(request).timeout(const Duration(seconds: 90)));
      if (response.statusCode != 200) {
        AiAccess.invalidate(
            provider: AIProviderType.openai,
            apiKey: key,
            model: 'gpt-transcribe',
            baseUrl: '');
        throw AiServiceException.fromResponse(
            response.statusCode, utf8.decode(response.bodyBytes));
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map || data['text'] is! String) {
        throw const FormatException(
            'No transcript returned by the online service.');
      }
      return data['text'] as String;
    } finally {
      client.close();
    }
  }
}
