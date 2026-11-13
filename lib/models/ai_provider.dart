enum AIProviderType {
  gemini,
  openai,
  anthropic,
  groq,
  openrouter,
  custom,
}

enum ThinkingEffort {
  none,
  low,
  medium,
  high;

  static List<ThinkingEffort> supportedBy(
      AIProviderType provider, String model) {
    final id = model.toLowerCase();
    if (provider == AIProviderType.gemini) {
      if (RegExp(r'^gemini-3(?:\.\d+)?-pro(?:-|$)').hasMatch(id) &&
          !id.contains('image')) {
        return [none, low, high];
      }
      if (RegExp(r'^gemini-(?:2\.5-(?:pro|flash)|3(?:\.\d+)?-flash)(?:-|$)')
              .hasMatch(id) &&
          !RegExp(r'live|tts|image|audio').hasMatch(id)) {
        return values;
      }
    }
    if (provider == AIProviderType.openai &&
        RegExp(r'^(?:gpt-5(?:\.\d+)?(?:-|$)|o[134](?:-|$))').hasMatch(id) &&
        !RegExp(r'pro|chat|codex|search').hasMatch(id)) {
      return values;
    }
    if (provider == AIProviderType.anthropic &&
        RegExp(r'^claude-(?:(?:opus|sonnet)-4-[6-9]|(?:opus|sonnet)-5)(?:-|$)')
            .hasMatch(id)) {
      return values;
    }
    return const [none];
  }

  String get displayName {
    switch (this) {
      case ThinkingEffort.none:
        return 'Model default';
      case ThinkingEffort.low:
        return 'Low (Quick Reasoning)';
      case ThinkingEffort.medium:
        return 'Medium (Balanced Reasoning)';
      case ThinkingEffort.high:
        return 'High (Deep Reasoning)';
    }
  }

  String get displayNameFa {
    switch (this) {
      case ThinkingEffort.none:
        return 'پیش‌فرض مدل';
      case ThinkingEffort.low:
        return 'پایین (استدلال سریع - Low)';
      case ThinkingEffort.medium:
        return 'متوسط (استدلال متعادل - Medium)';
      case ThinkingEffort.high:
        return 'بالا (استدلال عمیق - High)';
    }
  }

  String label(bool isPersian) => isPersian ? displayNameFa : displayName;

  int get tokenBudget {
    switch (this) {
      case ThinkingEffort.none:
        return 0;
      case ThinkingEffort.low:
        return 1024;
      case ThinkingEffort.medium:
        return 4096;
      case ThinkingEffort.high:
        return 8192;
    }
  }
}

class AIProviderConfig {
  final AIProviderType type;
  final String displayName;
  final String description;
  final String defaultBaseUrl;
  final bool requiresApiKey;
  final bool isLocal;

  const AIProviderConfig({
    required this.type,
    required this.displayName,
    required this.description,
    required this.defaultBaseUrl,
    this.requiresApiKey = true,
    this.isLocal = false,
  });

  static const List<AIProviderConfig> allProviders = [
    AIProviderConfig(
      type: AIProviderType.gemini,
      displayName: 'Google Gemini',
      description: 'Online image reading and descriptions.',
      defaultBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    ),
    AIProviderConfig(
      type: AIProviderType.openai,
      displayName: 'OpenAI (ChatGPT)',
      description: 'Online image reading and descriptions.',
      defaultBaseUrl: 'https://api.openai.com/v1',
    ),
    AIProviderConfig(
      type: AIProviderType.anthropic,
      displayName: 'Anthropic Claude',
      description:
          'High precision OCR, document layout recognition, and extended thinking.',
      defaultBaseUrl: 'https://api.anthropic.com/v1',
    ),
    AIProviderConfig(
      type: AIProviderType.groq,
      displayName: 'Groq',
      description: 'Online image reading and descriptions.',
      defaultBaseUrl: 'https://api.groq.com/openai/v1',
    ),
    AIProviderConfig(
      type: AIProviderType.openrouter,
      displayName: 'OpenRouter',
      description: 'Online model gateway.',
      defaultBaseUrl: 'https://openrouter.ai/api/v1',
    ),
    AIProviderConfig(
      type: AIProviderType.custom,
      displayName: 'Custom OpenAI-Compatible API',
      description: 'Custom self-hosted proxy or OpenAI-compatible endpoint.',
      defaultBaseUrl: 'https://your-custom-endpoint.com/v1',
    ),
  ];

  static AIProviderConfig getByType(AIProviderType type) {
    return allProviders.firstWhere(
      (p) => p.type == type,
      orElse: () => allProviders.first,
    );
  }

  static String normalizeModel(AIProviderType type, String model) {
    final trimmed = model.trim();
    return trimmed;
  }
}
