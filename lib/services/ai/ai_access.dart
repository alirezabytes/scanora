import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../../models/ai_provider.dart';
import '../settings_service.dart';

enum AiFailureKind {
  googleSignIn,
  missingKey,
  invalidKey,
  missingModel,
  invalidEndpoint,
  permission,
  regionUnavailable,
  modelUnavailable,
  quota,
  rateLimit,
  network,
  timeout,
  unavailable,
  unsupported,
  invalidRequest,
  inputTooLarge,
}

class AiServiceException implements Exception {
  final AiFailureKind kind;
  final bool isPersian;
  const AiServiceException(this.kind, {this.isPersian = false});

  String message(bool fa) {
    final messages = <AiFailureKind, (String, String)>{
      AiFailureKind.googleSignIn: (
        'Connect your Google account in Settings before using Google Docs OCR.',
        'ابتدا حساب گوگل را در تنظیمات متصل کنید تا OCR گوگل قابل استفاده باشد.'
      ),
      AiFailureKind.missingKey: (
        'Enter the selected AI service API key in Settings before starting.',
        'ابتدا کلید API سرویس انتخاب‌شده را در تنظیمات وارد کنید.'
      ),
      AiFailureKind.invalidKey: (
        'The AI service did not accept this API key. Check or replace it in Settings.',
        'سرویس هوش مصنوعی این کلید API را نپذیرفت. کلید را در تنظیمات بررسی یا جایگزین کنید.'
      ),
      AiFailureKind.missingModel: (
        'Refresh the model list in Settings and select a model before starting.',
        'ابتدا در تنظیمات فهرست مدل‌ها را به‌روز و یک مدل انتخاب کنید.'
      ),
      AiFailureKind.invalidEndpoint: (
        'Enter a valid HTTP or HTTPS service address in Settings.',
        'نشانی معتبر HTTP یا HTTPS سرویس را در تنظیمات وارد کنید.'
      ),
      AiFailureKind.permission: (
        'This key or account does not have permission to use the service or model. Check access in your provider account.',
        'این کلید یا حساب اجازهٔ استفاده از سرویس یا مدل را ندارد. سطح دسترسی حساب را در سرویس بررسی کنید.'
      ),
      AiFailureKind.regionUnavailable: (
        'This AI service is not available in your region. Choose another service in Settings.',
        'این سرویس هوش مصنوعی در منطقهٔ شما در دسترس نیست. سرویس دیگری را در تنظیمات انتخاب کنید.'
      ),
      AiFailureKind.modelUnavailable: (
        'The selected model is not available to this account. Refresh the model list and choose an available model.',
        'مدل انتخاب‌شده برای این حساب در دسترس نیست. فهرست مدل‌ها را به‌روز و مدل در دسترس را انتخاب کنید.'
      ),
      AiFailureKind.quota: (
        'The service reports exhausted credit or quota. Check billing and usage limits in your provider account.',
        'سرویس پایان اعتبار یا سهمیه را اعلام کرده است. اعتبار و محدودیت مصرف حساب را بررسی کنید.'
      ),
      AiFailureKind.rateLimit: (
        'The service rate limit was reached. Wait a short time before trying again.',
        'محدودیت تعداد درخواست سرویس پر شده است. کمی صبر کنید و دوباره تلاش کنید.'
      ),
      AiFailureKind.network: (
        'Could not connect to the selected AI service. Check your internet connection and service address.',
        'اتصال به سرویس هوش مصنوعی برقرار نشد. اینترنت و نشانی سرویس را بررسی کنید.'
      ),
      AiFailureKind.timeout: (
        'The AI service did not respond in time. Check the connection and try again.',
        'سرویس هوش مصنوعی به‌موقع پاسخ نداد. اتصال را بررسی و دوباره تلاش کنید.'
      ),
      AiFailureKind.unavailable: (
        'The selected AI service is temporarily unavailable. Try again later.',
        'سرویس هوش مصنوعی انتخاب‌شده موقتاً در دسترس نیست. بعداً دوباره تلاش کنید.'
      ),
      AiFailureKind.unsupported: (
        'The selected service or model does not support this task. Choose a compatible model in Settings.',
        'سرویس یا مدل انتخاب‌شده این کار را پشتیبانی نمی‌کند. مدل سازگار را در تنظیمات انتخاب کنید.'
      ),
      AiFailureKind.invalidRequest: (
        'The AI service rejected the request. Check the selected model, service address and input file.',
        'سرویس هوش مصنوعی درخواست را نپذیرفت. مدل، نشانی سرویس و فایل ورودی را بررسی کنید.'
      ),
      AiFailureKind.inputTooLarge: (
        'This file exceeds the service size limit. Choose a smaller file or a shorter recording.',
        'حجم فایل از محدودیت سرویس بیشتر است. فایل کوچک‌تر یا ضبط کوتاه‌تری انتخاب کنید.'
      ),
    };
    final text = messages[kind]!;
    return fa ? text.$2 : text.$1;
  }

  AiServiceException localized(bool fa) =>
      AiServiceException(kind, isPersian: fa);
  @override
  String toString() => message(isPersian);

  static AiServiceException fromResponse(int status, String body) {
    // Inspect service error codes, but never echo a response that may contain
    // credentials, request content, HTML, or other sensitive values.
    final lower = body.toLowerCase();
    if (status == 401 ||
        lower.contains('api_key_invalid') ||
        lower.contains('api key not valid') ||
        lower.contains('invalid_api_key') ||
        lower.contains('authentication_error')) {
      return const AiServiceException(AiFailureKind.invalidKey);
    }
    if (status == 402 ||
        [
          'insufficient_quota',
          'credit_balance_exhausted',
          'spend_limit',
          'usage_limit',
          'billing_error',
          'quota_exceeded',
          'quota exceeded'
        ].any(lower.contains)) {
      return const AiServiceException(AiFailureKind.quota);
    }
    if (status == 429) return const AiServiceException(AiFailureKind.rateLimit);
    if (lower.contains('unsupported_country') ||
        lower.contains('country, region, or territory') ||
        lower.contains('location is not supported')) {
      return const AiServiceException(AiFailureKind.regionUnavailable);
    }
    if (status == 413) {
      return const AiServiceException(AiFailureKind.inputTooLarge);
    }
    if (status == 403) {
      return const AiServiceException(AiFailureKind.permission);
    }
    if (status == 404 || lower.contains('model_not_found')) {
      return const AiServiceException(AiFailureKind.modelUnavailable);
    }
    if (status >= 500 || status == 498) {
      return const AiServiceException(AiFailureKind.unavailable);
    }
    if (['does not support', 'not supported', 'unsupported']
        .any(lower.contains)) {
      return const AiServiceException(AiFailureKind.unsupported);
    }
    return const AiServiceException(AiFailureKind.invalidRequest);
  }

  static AiServiceException fromError(Object error) {
    if (error is AiServiceException) return error;
    if (error is TimeoutException) {
      return const AiServiceException(AiFailureKind.timeout);
    }
    if (error is http.ClientException ||
        error is SocketException ||
        error is HandshakeException) {
      return const AiServiceException(AiFailureKind.network);
    }
    return const AiServiceException(AiFailureKind.invalidRequest);
  }
}

/// Small authenticated metadata checks run before decoding/uploading user data.
/// They cannot predict a later generation quota change; runtime errors still
/// invalidate this cache and are reported without an offline fallback.
class AiAccess {
  static final _verified = <String, DateTime>{};
  static final _pending = <String, Future<void>>{};

  static void validateConfiguration(
      {required AIProviderType provider,
      required String apiKey,
      required String model,
      required String baseUrl}) {
    validateCredentials(provider: provider, apiKey: apiKey, baseUrl: baseUrl);
    if (model.trim().isEmpty) {
      throw const AiServiceException(AiFailureKind.missingModel);
    }
  }

  static void validateCredentials(
      {required AIProviderType provider,
      required String apiKey,
      required String baseUrl}) {
    if (SettingsService.sanitizeKey(apiKey).isEmpty) {
      throw const AiServiceException(AiFailureKind.missingKey);
    }
    final uri = Uri.tryParse(baseUrl.trim());
    if (provider == AIProviderType.custom &&
        (uri == null ||
            uri.host.isEmpty ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.userInfo.isNotEmpty ||
            uri.hasQuery ||
            uri.hasFragment)) {
      throw const AiServiceException(AiFailureKind.invalidEndpoint);
    }
  }

  static String _id(
          AIProviderType provider, String apiKey, String model, String url) =>
      sha256
          .convert(utf8.encode(jsonEncode([
            provider.name,
            SettingsService.sanitizeKey(apiKey),
            AIProviderConfig.normalizeModel(provider, model),
            if (provider == AIProviderType.custom) url.trim(),
          ])))
          .toString();

  static void invalidate(
      {required AIProviderType provider,
      required String apiKey,
      required String model,
      required String baseUrl}) {
    _verified.remove(_id(provider, apiKey, model, baseUrl));
  }

  static void clearCache() {
    _verified.clear();
  }

  static Future<void> ensure(
      {required AIProviderType provider,
      required String apiKey,
      required String model,
      required String baseUrl,
      bool force = false}) async {
    validateConfiguration(
        provider: provider, apiKey: apiKey, model: model, baseUrl: baseUrl);
    final id = _id(provider, apiKey, model, baseUrl);
    final validUntil = _verified[id];
    if (!force && validUntil != null && DateTime.now().isBefore(validUntil)) {
      return;
    }
    final existing = _pending[id];
    if (existing != null) return existing;
    final check = _check(provider, SettingsService.sanitizeKey(apiKey),
        AIProviderConfig.normalizeModel(provider, model), baseUrl);
    _pending[id] = check;
    try {
      await check;
      if (_verified.length >= 32) _verified.remove(_verified.keys.first);
      _verified[id] = DateTime.now().add(const Duration(seconds: 30));
    } catch (error) {
      _verified.remove(id);
      throw AiServiceException.fromError(error);
    } finally {
      _pending.remove(id);
    }
  }

  static Future<void> _check(
      AIProviderType provider, String key, String model, String base) async {
    final headers = <String, String>{};
    late Uri endpoint;
    Uri modelEndpoint(String host, List<String> prefix) =>
        Uri(scheme: 'https', host: host, pathSegments: [...prefix, model]);
    switch (provider) {
      case AIProviderType.gemini:
        endpoint = modelEndpoint(
            'generativelanguage.googleapis.com', ['v1beta', 'models']);
        headers['x-goog-api-key'] = key;
      case AIProviderType.openai:
        endpoint = modelEndpoint('api.openai.com', ['v1', 'models']);
        headers['Authorization'] = 'Bearer $key';
      case AIProviderType.anthropic:
        endpoint = modelEndpoint('api.anthropic.com', ['v1', 'models']);
        headers.addAll({'x-api-key': key, 'anthropic-version': '2023-06-01'});
      case AIProviderType.groq:
        endpoint = modelEndpoint('api.groq.com', ['openai', 'v1', 'models']);
        headers['Authorization'] = 'Bearer $key';
      case AIProviderType.openrouter:
        endpoint = Uri.https('openrouter.ai', '/api/v1/key');
        headers['Authorization'] = 'Bearer $key';
      case AIProviderType.custom:
        final clean = base
            .trim()
            .replaceFirst(RegExp(r'/chat/completions/?$'), '')
            .replaceFirst(RegExp(r'/$'), '');
        endpoint = Uri.parse('$clean/models');
        if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
    }
    final client = http.Client();
    late final http.Response response;
    try {
      final request = http.Request('GET', endpoint)
        ..followRedirects = false
        ..headers.addAll(headers);
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 8));
    } finally {
      client.close();
    }
    if (response.statusCode != 200) {
      throw AiServiceException.fromResponse(response.statusCode,
          utf8.decode(response.bodyBytes, allowMalformed: true));
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map) {
      throw const AiServiceException(AiFailureKind.invalidRequest);
    }
    if (data['error'] != null) {
      throw AiServiceException.fromResponse(400, jsonEncode(data));
    }
    if (provider == AIProviderType.gemini && data['name'] is! String ||
        [AIProviderType.openai, AIProviderType.anthropic, AIProviderType.groq]
                .contains(provider) &&
            data['id'] is! String ||
        provider == AIProviderType.openrouter && data['data'] is! Map) {
      throw const AiServiceException(AiFailureKind.invalidRequest);
    }
    if (provider == AIProviderType.custom) {
      final models = data['data'];
      if (models is! List ||
          !models.any((item) => item is Map && item['id'] == model)) {
        throw const AiServiceException(AiFailureKind.modelUnavailable);
      }
    }
    final methods = data['supportedGenerationMethods'];
    if (provider == AIProviderType.gemini &&
        methods is List &&
        !methods.contains('generateContent')) {
      throw const AiServiceException(AiFailureKind.unsupported);
    }
    if (provider == AIProviderType.openrouter) {
      final keyInfo = data['data'] as Map;
      final remaining = keyInfo['limit_remaining'];
      if (keyInfo['limit'] is num && remaining is num && remaining <= 0) {
        throw const AiServiceException(AiFailureKind.quota);
      }
    }
  }
}
