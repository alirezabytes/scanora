import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../../models/ai_provider.dart';
import '../settings_service.dart';
import 'ai_access.dart';

class AITestResult {
  final bool success;
  final String message;
  final String? modelUsed;
  final List<String> discoveredModels;

  const AITestResult({
    required this.success,
    required this.message,
    this.modelUsed,
    this.discoveredModels = const [],
  });
}

abstract class AIService {
  /// Automatically detects MIME type from image magic bytes.
  static String detectMimeType(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    return 'image/png';
  }

  /// Dynamically queries the provider's API using the user's API key (or local endpoint)
  /// to obtain models reported by that authenticated endpoint. Quotas and billing
  /// may impose additional limits which the model-list API does not publish.
  static Future<List<String>> fetchAvailableModels({
    required AIProviderType providerType,
    required String apiKey,
    required String customBaseUrl,
  }) async {
    final cleanKey = SettingsService.sanitizeKey(apiKey);
    AiAccess.validateCredentials(
        provider: providerType, apiKey: cleanKey, baseUrl: customBaseUrl);

    switch (providerType) {
      case AIProviderType.gemini:
        if (cleanKey.isEmpty) {
          throw Exception('API key is required to detect Gemini models.');
        }
        final result = <String>{};
        String? next;
        final seen = <String>{};
        do {
          final url = Uri.https(
              'generativelanguage.googleapis.com',
              '/v1beta/models',
              {'pageSize': '100', if (next != null) 'pageToken': next});
          final response = await http.get(url, headers: {
            'x-goog-api-key': cleanKey
          }).timeout(const Duration(seconds: 20));
          if (response.statusCode != 200) {
            throw AiServiceException.fromResponse(
                response.statusCode, utf8.decode(response.bodyBytes));
          }
          final data = jsonDecode(utf8.decode(response.bodyBytes))
              as Map<String, dynamic>;
          for (final item in data['models'] as List? ?? []) {
            if (item is! Map) continue;
            final methods = item['supportedGenerationMethods'] as List? ?? [];
            if (!methods.contains('generateContent')) continue;
            final id = (item['name']?.toString() ?? '')
                .replaceFirst('models/', '')
                .trim();
            final lower = id.toLowerCase();
            if (id.isEmpty ||
                ['embedding', 'aqa', 'tts', 'imagen', 'veo']
                    .any(lower.contains)) {
              continue;
            }
            result.add(id);
          }
          next = data['nextPageToken']?.toString();
          if (next != null &&
              next.isNotEmpty &&
              (!seen.add(next) || seen.length > 25)) {
            throw StateError('The service returned invalid model pagination.');
          }
        } while (next != null && next.isNotEmpty);
        return result.toList()..sort();

      case AIProviderType.openai:
        if (cleanKey.isEmpty) {
          throw Exception('API key is required to detect OpenAI models.');
        }
        return _fetchOpenAICompatibleModels(
            'https://api.openai.com/v1', cleanKey);

      case AIProviderType.groq:
        if (cleanKey.isEmpty) {
          throw Exception('API key is required to detect Groq models.');
        }
        return _fetchOpenAICompatibleModels(
            'https://api.groq.com/openai/v1', cleanKey);

      case AIProviderType.openrouter:
        final identity = await http
            .get(Uri.parse('https://openrouter.ai/api/v1/key'), headers: {
          'Authorization': 'Bearer $cleanKey'
        }).timeout(const Duration(seconds: 20));
        if (identity.statusCode != 200) {
          throw AiServiceException.fromResponse(
              identity.statusCode, utf8.decode(identity.bodyBytes));
        }
        return _fetchOpenAICompatibleModels(
            'https://openrouter.ai/api/v1', cleanKey);

      case AIProviderType.anthropic:
        if (cleanKey.isEmpty) {
          throw Exception('API key is required to detect Anthropic models.');
        }
        final models = <String>{};
        String? after;
        final seen = <String>{};
        while (true) {
          final url = Uri.https('api.anthropic.com', '/v1/models',
              {'limit': '100', if (after != null) 'after_id': after});
          final response = await http.get(url, headers: {
            'x-api-key': cleanKey,
            'anthropic-version': '2023-06-01'
          }).timeout(const Duration(seconds: 20));
          if (response.statusCode != 200) {
            throw AiServiceException.fromResponse(
                response.statusCode, utf8.decode(response.bodyBytes));
          }
          final data = jsonDecode(utf8.decode(response.bodyBytes))
              as Map<String, dynamic>;
          for (final item in data['data'] as List? ?? []) {
            if (item is Map && item['id'] is String) models.add(item['id']);
          }
          if (data['has_more'] != true) break;
          after = data['last_id']?.toString();
          if (after == null ||
              after.isEmpty ||
              !seen.add(after) ||
              seen.length > 25) {
            throw StateError('Invalid model pagination.');
          }
        }
        return models.toList()..sort();

      case AIProviderType.custom:
        final base = customBaseUrl
            .trim()
            .replaceFirst(RegExp(r'/chat/completions/?$'), '');
        return _fetchOpenAICompatibleModels(base, cleanKey);
    }
  }

  static Future<List<String>> _fetchOpenAICompatibleModels(
      String baseUrl, String apiKey) async {
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    final res = await http
        .get(Uri.parse('$cleanBase/models'), headers: headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw AiServiceException.fromResponse(
          res.statusCode, utf8.decode(res.bodyBytes));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final list = data['data'] as List<dynamic>? ?? [];
    final models = <String>[];
    for (final item in list) {
      if (item is Map<String, dynamic> && item['id'] != null) {
        final architecture = item['architecture'];
        if (architecture is Map &&
            architecture['input_modalities'] is List &&
            !(architecture['input_modalities'] as List).contains('image')) {
          continue;
        }
        final id = item['id'].toString().trim();
        final lower = id.toLowerCase();
        if (lower.contains('whisper') ||
            lower.contains('tts') ||
            lower.contains('dall-e') ||
            lower.contains('embedding') ||
            lower.contains('moderation') ||
            lower.contains('babbage') ||
            lower.contains('davinci') ||
            lower.contains('guard') ||
            lower.contains('realtime') ||
            lower.contains('transcribe')) {
          continue;
        }
        models.add(id);
      }
    }
    models.sort();
    return models.toSet().toList();
  }

  /// Sends the actual image to the selected provider. Authentication, quota and
  /// model errors remain visible; pictures never silently move to another service.
  static Future<String> callVisionModel({
    required AIProviderType providerType,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    required Uint8List imageBytes,
    required String prompt,
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
    String? mimeType,
    bool isPersian = false,
  }) async {
    final key = SettingsService.sanitizeKey(apiKey);
    try {
      await AiAccess.ensure(
          provider: providerType,
          apiKey: key,
          model: modelName,
          baseUrl: customBaseUrl);
    } catch (error) {
      throw AiServiceException.fromError(error).localized(isPersian);
    }
    final prepared = await Isolate.run(() => prepareVisionImage(imageBytes));
    final model = AIProviderConfig.normalizeModel(providerType, modelName);
    final encoded = base64Encode(prepared);
    try {
      final response = switch (providerType) {
        AIProviderType.gemini => _callGemini(
            key, model, encoded, prompt, 'image/jpeg', thinkingEffort),
        AIProviderType.openai => _callOpenAI(
            key, model, encoded, prompt, 'image/jpeg', thinkingEffort),
        AIProviderType.anthropic => _callAnthropic(
            key, model, encoded, prompt, 'image/jpeg', thinkingEffort),
        AIProviderType.groq =>
          _callGroq(key, model, encoded, prompt, 'image/jpeg'),
        AIProviderType.openrouter =>
          _callOpenRouter(key, model, encoded, prompt, 'image/jpeg'),
        AIProviderType.custom => _callOpenAICompatible(
            customBaseUrl.trim(), key, model, encoded, prompt, 'image/jpeg'),
      };
      return await response;
    } catch (error) {
      AiAccess.invalidate(
          provider: providerType,
          apiKey: key,
          model: modelName,
          baseUrl: customBaseUrl);
      throw AiServiceException.fromError(error).localized(isPersian);
    }
  }

  static Uint8List prepareVisionImage(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('The selected image could not be decoded.');
    }
    var image = img.bakeOrientation(decoded);
    if (image.hasAlpha) {
      final white =
          img.Image(width: image.width, height: image.height, numChannels: 3);
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(white, image);
      image = white;
    }
    if (image.width > 4096 || image.height > 4096) {
      image = img.copyResize(image,
          width: image.width >= image.height ? 4096 : null,
          height: image.height > image.width ? 4096 : null);
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 95));
  }

  static Future<String> transcribeGeminiAudio(
      {required String apiKey,
      required String modelName,
      required Uint8List wavBytes,
      ThinkingEffort thinkingEffort = ThinkingEffort.none}) async {
    await AiAccess.ensure(
        provider: AIProviderType.gemini,
        apiKey: apiKey,
        model: modelName,
        baseUrl: '');
    try {
      return await _callGemini(
          SettingsService.sanitizeKey(apiKey),
          modelName,
          base64Encode(wavBytes),
          'Transcribe the speech exactly in its original language, including Persian and English code-switching. Do not translate, summarize, complete sentences or invent words. Return only the transcript. For silence return [NO_SPEECH].',
          'audio/wav',
          thinkingEffort);
    } catch (error) {
      AiAccess.invalidate(
          provider: AIProviderType.gemini,
          apiKey: apiKey,
          model: modelName,
          baseUrl: '');
      rethrow;
    }
  }

  /// Interactive multi-turn visual Q&A chat about an image for blind and visually impaired users.
  static Future<String> callChatWithImage({
    required AIProviderType providerType,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    required Uint8List imageBytes,
    required String initialDescription,
    required List<Map<String, String>> chatHistory,
    required String userQuestion,
    required bool isPersian,
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
  }) async {
    final historyBuffer = StringBuffer();
    if (initialDescription.trim().isNotEmpty) {
      historyBuffer
          .writeln('Initial Image Description:\n$initialDescription\n');
    }
    if (chatHistory.isNotEmpty) {
      historyBuffer.writeln('Previous Conversation:');
      for (final msg in chatHistory) {
        final role = msg['role'] == 'user' ? 'User' : 'Assistant';
        historyBuffer.writeln('$role: ${msg['text']}');
      }
      historyBuffer.writeln();
    }

    final prompt = isPersian
        ? '''
شما یک دستیار بینایی هوشمند و دقیق برای کاربران نابینا و کم‌بینا هستید.
بر اساس تصویر پیوست‌شده و سابقه گفتگوی زیر، به سوال جدید کاربر با دقت، وضوح و به زبان فارسی پاسخ دهید.

$historyBuffer
سوال جدید کاربر: $userQuestion
'''
        : '''
You are an accurate, helpful visual assistant designed for blind and visually impaired users.
Based on the attached image and the conversation context below, answer the user's new question clearly and concisely in the same language as the question.

$historyBuffer
User's New Question: $userQuestion
''';

    return callVisionModel(
      providerType: providerType,
      apiKey: apiKey,
      modelName: modelName,
      customBaseUrl: customBaseUrl,
      imageBytes: imageBytes,
      prompt: prompt,
      thinkingEffort: thinkingEffort,
      isPersian: isPersian,
    );
  }

  /// Google Gemini REST API implementation with automatic model fallback
  static Future<String> _callGemini(
    String apiKey,
    String model,
    String base64Image,
    String prompt,
    String mimeType, [
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
  ]) async {
    if (apiKey.isEmpty) {
      throw Exception(
          'Gemini API key is missing. Please enter your API key in Settings.');
    }

    final modelsToTry = [model];

    Exception? lastError;

    for (final candidateModel in modelsToTry) {
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$candidateModel:generateContent',
      );

      final effort =
          ThinkingEffort.supportedBy(AIProviderType.gemini, candidateModel)
                  .contains(thinkingEffort)
              ? thinkingEffort
              : ThinkingEffort.none;
      final genConfig = <String, dynamic>{
        if (!candidateModel.startsWith('gemini-3')) 'temperature': 0.1,
        'maxOutputTokens': effort == ThinkingEffort.none ? 4096 : 16384,
        if (effort != ThinkingEffort.none)
          'thinkingConfig': candidateModel.startsWith('gemini-3')
              ? {'thinkingLevel': effort.name.toUpperCase()}
              : {'thinkingBudget': effort.tokenBudget},
      };

      final requestBody = {
        'contents': [
          {
            'parts': [
              {'text': prompt},
              {
                'inline_data': {
                  'mime_type': mimeType,
                  'data': base64Image,
                }
              }
            ]
          }
        ],
        'generationConfig': genConfig,
      };

      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey
            },
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final candidates = data['candidates'] as List?;
        if (candidates != null && candidates.isNotEmpty) {
          final parts = candidates[0]['content']?['parts'] as List?;
          if (parts != null && parts.isNotEmpty) {
            final textParts = parts
                .where((p) => p['text'] != null && !(p['thought'] == true))
                .map((p) => p['text'].toString())
                .toList();
            if (textParts.isNotEmpty) {
              return textParts.join('\n').trim();
            }
          }
        }
        return '';
      }

      final errorBody = utf8.decode(response.bodyBytes);
      lastError =
          AiServiceException.fromResponse(response.statusCode, errorBody);
      throw lastError;
    }

    throw lastError ?? Exception('Gemini API request failed.');
  }

  /// Responses accepts image input without incompatible Chat Completions
  /// sampling parameters. The user's selected model is preserved.
  static Future<String> _callOpenAI(String apiKey, String model,
      String base64Image, String prompt, String mimeType,
      [ThinkingEffort thinkingEffort = ThinkingEffort.none]) async {
    final reasoning = ThinkingEffort.supportedBy(AIProviderType.openai, model)
        .contains(thinkingEffort);
    final response = await http
        .post(Uri.https('api.openai.com', '/v1/responses'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json'
            },
            body: jsonEncode({
              'model': model,
              'store': false,
              'max_output_tokens': 8192,
              if (reasoning && thinkingEffort != ThinkingEffort.none)
                'reasoning': {'effort': thinkingEffort.name},
              'input': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'input_text', 'text': prompt},
                    {
                      'type': 'input_image',
                      'image_url': 'data:$mimeType;base64,$base64Image',
                      'detail': 'high'
                    }
                  ]
                }
              ]
            }))
        .timeout(const Duration(seconds: 90));
    if (response.statusCode != 200) {
      throw AiServiceException.fromResponse(
          response.statusCode, utf8.decode(response.bodyBytes));
    }
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (data['status'] == 'incomplete') {
      throw StateError(
          'The AI response was incomplete. Try a smaller page or a lower thinking effort.');
    }
    final text = <String>[];
    for (final item in data['output'] as List? ?? []) {
      if (item is! Map || item['type'] != 'message') continue;
      for (final part in item['content'] as List? ?? []) {
        if (part is Map &&
            part['type'] == 'output_text' &&
            part['text'] is String) {
          text.add(part['text'] as String);
        }
        if (part is Map && part['type'] == 'refusal') {
          throw StateError('The AI provider declined this request.');
        }
      }
    }
    if (text.isEmpty) {
      throw StateError('The AI provider returned no readable text.');
    }
    return text.join('\n').trim();
  }

  /// Generic OpenAI-compatible Vision Endpoint
  static Future<String> _callOpenAICompatible(
    String baseUrl,
    String apiKey,
    String model,
    String base64Image,
    String prompt,
    String mimeType, {
    Map<String, String>? extraHeaders,
    Map<String, dynamic>? extraBody,
  }) async {
    if (apiKey.isEmpty &&
        !baseUrl.contains('localhost') &&
        !baseUrl.contains('127.0.0.1')) {
      throw Exception('API key is missing. Please add it in Settings.');
    }

    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final url =
        cleanBase.endsWith('/chat/completions') || cleanBase.endsWith('/openai')
            ? Uri.parse(cleanBase.endsWith('/openai')
                ? '$cleanBase/chat/completions'
                : cleanBase)
            : Uri.parse('$cleanBase/chat/completions');

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      ...?extraHeaders,
    };

    final isReasoningModel = model.startsWith('o1') ||
        model.startsWith('o3') ||
        model.startsWith('o4');

    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:$mimeType;base64,$base64Image',
              }
            }
          ]
        }
      ],
      if (!isReasoningModel) 'temperature': 0.1,
      if (isReasoningModel)
        'max_completion_tokens': 4096
      else
        'max_tokens': 4096,
      ...?extraBody,
    };

    final response = await http
        .post(
          url,
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      final errorBody = utf8.decode(response.bodyBytes);
      throw AiServiceException.fromResponse(response.statusCode, errorBody);
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final choices = data['choices'] as List?;
    if (choices != null && choices.isNotEmpty) {
      return choices[0]['message']?['content']?.toString().trim() ?? '';
    }
    return '';
  }

  /// Groq Cloud Llama Vision with automatic model fallback
  static Future<String> _callGroq(
    String apiKey,
    String model,
    String base64Image,
    String prompt,
    String mimeType,
  ) async {
    final modelsToTry = [model];

    Exception? lastError;
    for (final candidate in modelsToTry) {
      try {
        return await _callOpenAICompatible(
          'https://api.groq.com/openai/v1',
          apiKey,
          candidate,
          base64Image,
          prompt,
          mimeType,
        );
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (e.toString().contains('401') || e.toString().contains('403')) {
          rethrow;
        }
      }
    }
    throw lastError ?? Exception('Groq API request failed.');
  }

  /// OpenRouter Gateway
  static Future<String> _callOpenRouter(
    String apiKey,
    String model,
    String base64Image,
    String prompt,
    String mimeType,
  ) async {
    return _callOpenAICompatible(
      'https://openrouter.ai/api/v1',
      apiKey,
      model,
      base64Image,
      prompt,
      mimeType,
      extraHeaders: {
        'X-Title': 'Scanora',
      },
    );
  }

  /// Anthropic Claude REST API with automatic fallback
  static Future<String> _callAnthropic(
    String apiKey,
    String model,
    String base64Image,
    String prompt,
    String mimeType, [
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
  ]) async {
    if (apiKey.isEmpty) {
      throw Exception('Claude API key is missing. Please add it in Settings.');
    }

    final url = Uri.parse('https://api.anthropic.com/v1/messages');

    final headers = {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    };

    final modelsToTry = [model];

    Exception? lastError;

    for (final candidateModel in modelsToTry) {
      final adaptive = thinkingEffort != ThinkingEffort.none &&
          ThinkingEffort.supportedBy(AIProviderType.anthropic, candidateModel)
              .contains(thinkingEffort);
      final body = <String, dynamic>{
        'model': candidateModel,
        'max_tokens': adaptive ? 16384 : 4096,
        if (!adaptive) 'temperature': 0.1,
        if (adaptive) 'thinking': {'type': 'adaptive'},
        if (adaptive) 'output_config': {'effort': thinkingEffort.name},
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': mimeType,
                  'data': base64Image,
                }
              },
              {
                'type': 'text',
                'text': prompt,
              }
            ]
          }
        ]
      };

      final response = await http
          .post(
            url,
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final content = data['content'] as List?;
        if (content != null && content.isNotEmpty) {
          final textBlock = content.firstWhere(
            (c) => c['type'] == 'text',
            orElse: () => content.first,
          );
          return textBlock['text']?.toString().trim() ?? '';
        }
        return '';
      }

      final errorBody = utf8.decode(response.bodyBytes);
      lastError =
          AiServiceException.fromResponse(response.statusCode, errorBody);
      throw lastError;
    }

    throw lastError ?? Exception('Anthropic API request failed.');
  }

  /// Generates a clean 64x64 test PNG image so vision endpoints never reject 1x1 dimensions
  static Uint8List _createTestImage() {
    final image = img.Image(width: 64, height: 64);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    img.drawString(
      image,
      'OK',
      font: img.arial24,
      x: 14,
      y: 20,
      color: img.ColorRgb8(0, 0, 0),
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  /// Tests the API key and model connection, and also discovers available models for this API key!
  static Future<AITestResult> testConnectionDetailed({
    required AIProviderType providerType,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
    ThinkingEffort thinkingEffort = ThinkingEffort.none,
    bool isPersian = false,
  }) async {
    final config = AIProviderConfig.getByType(providerType);
    final cleanKey = SettingsService.sanitizeKey(apiKey);
    var normalizedModel =
        AIProviderConfig.normalizeModel(providerType, modelName);

    if (config.requiresApiKey && cleanKey.isEmpty) {
      return AITestResult(
        success: false,
        message: isPersian
            ? 'کلید API برای ${config.displayName} وارد نشده است. لطفاً ابتدا کلید را وارد کنید.'
            : 'API key for ${config.displayName} is empty. Please enter your API key first.',
      );
    }

    List<String> discovered = const [];
    try {
      discovered = await fetchAvailableModels(
        providerType: providerType,
        apiKey: cleanKey,
        customBaseUrl: customBaseUrl,
      );
      if (!discovered.contains(normalizedModel)) {
        return AITestResult(
            success: false,
            discoveredModels: discovered,
            message: isPersian
                ? 'ابتدا فهرست را به‌روز و مدل را انتخاب کنید.'
                : 'Refresh the list and choose a model first.');
      }
    } catch (error) {
      return AITestResult(
          success: false,
          message: AiServiceException.fromError(error).message(isPersian));
    }

    try {
      final testBytes = _createTestImage();
      final reply = await callVisionModel(
        providerType: providerType,
        apiKey: cleanKey,
        modelName: normalizedModel,
        customBaseUrl: customBaseUrl,
        imageBytes: testBytes,
        prompt: 'Reply with the single word: OK',
        thinkingEffort: thinkingEffort,
        mimeType: 'image/png',
        isPersian: isPersian,
      );

      if (reply.trim().isNotEmpty) {
        final shortReply = reply.trim().replaceAll('\n', ' ');
        final displayReply = shortReply.length > 40
            ? '${shortReply.substring(0, 40)}...'
            : shortReply;
        final countInfo = discovered.isNotEmpty
            ? (isPersian
                ? ' (${discovered.length} مدل فعال برای حساب شما شناسایی شد)'
                : ' (${discovered.length} active models detected for your key)')
            : '';
        return AITestResult(
          success: true,
          modelUsed: normalizedModel,
          discoveredModels: discovered,
          message: isPersian
              ? 'اتصال به ${config.displayName} (مدل $normalizedModel) با موفقیت برقرار شد$countInfo. پاسخ مدل: $displayReply'
              : 'Connected to ${config.displayName} ($normalizedModel) successfully$countInfo! Model reply: $displayReply',
        );
      } else {
        return AITestResult(
          success: false,
          modelUsed: normalizedModel,
          discoveredModels: discovered,
          message: isPersian
              ? 'پاسخی از مدل $normalizedModel دریافت نشد.'
              : 'Empty response received from $normalizedModel.',
        );
      }
    } on TimeoutException {
      return AITestResult(
        success: false,
        modelUsed: normalizedModel,
        discoveredModels: discovered,
        message: isPersian
            ? 'زمان انتظار اتصال به پایان رسید (Timeout). وضعیت اینترنت یا ابزار تغییر آی‌پی خود را بررسی کنید.'
            : 'Connection timed out. Please check your internet connection.',
      );
    } catch (e) {
      final errText = e.toString().replaceFirst('Exception: ', '');
      return AITestResult(
        success: false,
        modelUsed: normalizedModel,
        discoveredModels: discovered,
        message: isPersian
            ? 'خطا در تست اتصال به ${config.displayName}:\n$errText'
            : 'Connection test failed for ${config.displayName}:\n$errText',
      );
    }
  }

  static Future<bool> testConnection({
    required AIProviderType providerType,
    required String apiKey,
    required String modelName,
    required String customBaseUrl,
  }) async {
    final res = await testConnectionDetailed(
      providerType: providerType,
      apiKey: apiKey,
      modelName: modelName,
      customBaseUrl: customBaseUrl,
    );
    return res.success;
  }
}
