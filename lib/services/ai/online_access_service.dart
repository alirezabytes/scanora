import '../../models/ai_provider.dart';
import '../settings_service.dart';
import '../cloud/scanora_cloud_ocr_service.dart';
import 'ai_access.dart';

enum OnlineTask { vision, ocr, speech }

class OnlineAccessService {
  static void validate(SettingsService settings,
      {OnlineTask task = OnlineTask.vision}) {
    if (settings.isOfflineMode ||
        task == OnlineTask.ocr && settings.useScanoraCloudOcr) {
      return;
    }
    final provider = settings.activeProvider;
    AiAccess.validateConfiguration(
        provider: provider,
        apiKey: settings.getApiKey(provider),
        model: modelFor(settings, task),
        baseUrl: settings.customBaseUrl);
    if (task == OnlineTask.speech &&
        ![AIProviderType.gemini, AIProviderType.openai].contains(provider)) {
      throw const AiServiceException(AiFailureKind.unsupported);
    }
  }

  static String modelFor(SettingsService settings, OnlineTask task) =>
      task == OnlineTask.speech &&
              settings.activeProvider == AIProviderType.openai
          ? 'gpt-transcribe'
          : settings.getSelectedModel(settings.activeProvider);

  static Future<void> ensure(SettingsService settings,
      {OnlineTask task = OnlineTask.vision, bool force = false}) async {
    validate(settings, task: task);
    if (settings.isOfflineMode) return;
    if (task == OnlineTask.ocr && settings.useScanoraCloudOcr) {
      await ScanoraCloudOcrService.checkAccess(force: force);
      return;
    }
    await AiAccess.ensure(
        provider: settings.activeProvider,
        apiKey: settings.getApiKey(settings.activeProvider),
        model: modelFor(settings, task),
        baseUrl: settings.customBaseUrl,
        force: force);
  }
}
