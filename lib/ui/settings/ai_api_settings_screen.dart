import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../models/ai_provider.dart';
import '../../services/ai/ai_service.dart';
import '../../services/ai/ai_access.dart';
import '../../services/a11y/accessibility_service.dart';
import '../../services/diagnostics_service.dart';
import '../../services/settings_service.dart';
import '../widgets/accessible_dropdown_field.dart';

class AiApiSettingsScreen extends StatefulWidget {
  const AiApiSettingsScreen({super.key});
  @override
  State<AiApiSettingsScreen> createState() => _AiApiSettingsScreenState();
}

class _AiApiSettingsScreenState extends State<AiApiSettingsScreen> {
  final _key = TextEditingController();
  final _url = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  bool _busy = false, _hidden = true;
  String _status = '';
  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    _load(settings);
    if (_key.text.isNotEmpty && !settings.isOfflineMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  void _load(SettingsService settings) {
    _key.text = settings.getApiKey(settings.activeProvider);
    _url.text = settings.customBaseUrl;
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _edited(String _) {
    _generation++;
    _debounce?.cancel();
    setState(() {
      _busy = false;
      _status = '';
    });
    if (SettingsService.sanitizeKey(_key.text).length >= 10) {
      _debounce = Timer(const Duration(milliseconds: 1000), _refresh);
    }
  }

  Future<void> _refresh() async {
    _debounce?.cancel();
    final settings = context.read<SettingsService>();
    final l = AppLocalizations.of(context);
    final provider = settings.activeProvider;
    final key = SettingsService.sanitizeKey(_key.text);
    final endpoint = _url.text.trim();
    final generation = ++_generation;
    try {
      AiAccess.validateCredentials(
          provider: provider, apiKey: key, baseUrl: endpoint);
    } on AiServiceException catch (error) {
      if (key.isEmpty) await settings.setApiKey(provider, '');
      if (!mounted || generation != _generation) return;
      setState(() {
        _busy = false;
        _status = error.message(l.isPersian);
      });
      AccessibilityService.announce(context, _status);
      return;
    }
    setState(() {
      _busy = true;
      _status = l.tx('Getting the model list…', 'در حال دریافت فهرست مدل‌ها…');
    });
    try {
      await settings.setApiKey(provider, key);
      if (provider == AIProviderType.custom) {
        await settings.setCustomBaseUrl(endpoint);
      }
      if (!mounted || generation != _generation) return;
      final fingerprint = settings.modelAccessFingerprint(provider);
      final models = await AIService.fetchAvailableModels(
          providerType: provider, apiKey: key, customBaseUrl: endpoint);
      if (!mounted || generation != _generation) return;
      await settings.setDiscoveredModels(provider, models,
          expectedFingerprint: fingerprint);
      if (!mounted || generation != _generation) return;
      setState(() => _status = models.isEmpty
          ? l.tx('The service returned no models for this key.',
              'سرویس برای این کلید مدلی برنگرداند.')
          : l.tx('List updated: ${models.length} models. Choose a model below.',
              'فهرست به‌روز شد: ${models.length} مدل. مدل را از فهرست زیر انتخاب کنید.'));
      AccessibilityService.announce(context, _status);
    } catch (error, stack) {
      DiagnosticsService.record('models.refresh', error, stack);
      if (!mounted || generation != _generation) return;
      setState(() =>
          _status = AiServiceException.fromError(error).message(l.isPersian));
      AccessibilityService.announce(context, _status);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    _debounce?.cancel();
    final settings = context.read<SettingsService>();
    final l = AppLocalizations.of(context);
    final provider = settings.activeProvider;
    final model = settings.getSelectedModel(provider);
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _status =
          l.tx('Checking the selected model…', 'در حال بررسی مدل انتخابی…');
    });
    try {
      final result = await AIService.testConnectionDetailed(
          providerType: provider,
          apiKey: settings.getApiKey(provider),
          modelName: model,
          customBaseUrl: settings.customBaseUrl,
          thinkingEffort: settings.thinkingEffort,
          isPersian: l.isPersian);
      if (!mounted || generation != _generation) return;
      setState(() => _status = result.success
          ? l.tx('The selected model accepted the test image.',
              'مدل انتخابی تصویر آزمایشی را پذیرفت.')
          : result.message);
      AccessibilityService.announce(context, _status);
    } catch (error, stack) {
      DiagnosticsService.record('models.test', error, stack);
      if (!mounted || generation != _generation) return;
      setState(() =>
          _status = AiServiceException.fromError(error).message(l.isPersian));
      AccessibilityService.announce(context, _status);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _clearKey() async {
    final settings = context.read<SettingsService>();
    final l = AppLocalizations.of(context);
    final provider = settings.activeProvider;
    final generation = ++_generation;
    _debounce?.cancel();
    _key.clear();
    setState(() {
      _busy = false;
      _hidden = true;
      _status = l.tx('Connection key cleared.', 'کلید ارتباطی پاک شد.');
    });
    await settings.setApiKey(provider, '');
    if (mounted && generation == _generation) {
      AccessibilityService.announce(context, _status);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService>();
    final l = AppLocalizations.of(context);
    final provider = s.activeProvider;
    final matches =
        SettingsService.sanitizeKey(_key.text) == s.getApiKey(provider) &&
            (provider != AIProviderType.custom ||
                _url.text.trim() == s.customBaseUrl);
    final models = matches ? s.getEffectiveModels(provider) : <String>[];
    final selected = matches ? s.getSelectedModel(provider) : '';
    final levels = ThinkingEffort.supportedBy(provider, selected);
    return Scaffold(
        appBar: AppBar(title: Text(l.tx('Connection keys', 'کلیدهای ارتباطی'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(l.tx(
              'Add your key to get the model list from your service. Refresh it after changing your account.',
              'کلید خود را وارد کنید تا فهرست مدل‌ها از سرویس دریافت شود. پس از تغییر حساب، فهرست را به‌روز کنید.')),
          const SizedBox(height: 20),
          AccessibleDropdownField<AIProviderType>(
              initialValue: provider,
              decoration: InputDecoration(labelText: l.tx('Service', 'سرویس')),
              items: [
                for (final config in AIProviderConfig.allProviders)
                  DropdownMenuItem(
                      value: config.type, child: Text(config.displayName))
              ],
              onChanged: _busy
                  ? null
                  : (value) async {
                      if (value == null) return;
                      _generation++;
                      _debounce?.cancel();
                      await s.setActiveProvider(value);
                      if (!mounted) return;
                      setState(() {
                        _load(s);
                        _status = '';
                      });
                      if (_key.text.isNotEmpty && !s.isOfflineMode) _refresh();
                    }),
          const SizedBox(height: 16),
          TextField(
              controller: _key,
              obscureText: _hidden,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: _edited,
              onSubmitted: (_) => _refresh(),
              decoration: InputDecoration(
                  labelText: l.tx('Connection key', 'کلید ارتباطی'),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                      tooltip: _hidden
                          ? l.tx('Show key', 'نمایش کلید')
                          : l.tx('Hide key', 'پنهان‌کردن کلید'),
                      icon: Icon(
                          _hidden ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _hidden = !_hidden)))),
          TextButton.icon(
              icon: const Icon(Icons.content_paste),
              label: Text(l.tx('Paste key', 'جای‌گذاری کلید')),
              onPressed: () async {
                final value = await Clipboard.getData(Clipboard.kTextPlain);
                if (!mounted) return;
                _key.text = SettingsService.sanitizeKey(value?.text ?? '');
                _edited(_key.text);
              }),
          TextButton.icon(
            icon: const Icon(Icons.clear_rounded),
            label: Text(l.tx('Clear key', 'پاک کردن کلید')),
            onPressed: _key.text.isEmpty && s.getApiKey(provider).isEmpty
                ? null
                : _clearKey,
          ),
          if (provider == AIProviderType.custom) ...[
            const SizedBox(height: 12),
            TextField(
                controller: _url,
                onChanged: _edited,
                decoration: InputDecoration(
                    labelText: l.tx('Service address', 'نشانی سرویس'),
                    border: const OutlineInputBorder()))
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: Text(l.tx('Update key & model list',
                  'به‌روزرسانی کلید و فهرست مدل‌ها')),
              onPressed: _busy ? null : _refresh),
          if (_busy) const LinearProgressIndicator(),
          if (_status.isNotEmpty)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(_status)),
          const SizedBox(height: 12),
          if (models.isNotEmpty)
            AccessibleDropdownField<String>(
                key: ValueKey('${provider.name}:$selected:${models.join('|')}'),
                initialValue: selected.isEmpty ? null : selected,
                isExpanded: true,
                hint: Text(l.tx('Choose a model', 'انتخاب مدل')),
                decoration: InputDecoration(labelText: l.tx('Model', 'مدل')),
                items: [
                  for (final id in models)
                    DropdownMenuItem(value: id, child: Text(id))
                ],
                onChanged: _busy
                    ? null
                    : (value) async {
                        if (value != null) {
                          await s.setSelectedModel(provider, value);
                        }
                      }),
          if (levels.length > 1)
            AccessibleDropdownField<ThinkingEffort>(
              key: ValueKey('effort:$provider:$selected'),
              initialValue: s.thinkingEffort,
              decoration: InputDecoration(
                labelText: l.tx('Reasoning effort', 'میزان استدلال'),
                helperText: l.tx('Used for each request with this model.',
                    'برای هر درخواست با این مدل استفاده می‌شود.'),
              ),
              items: [
                for (final level in levels)
                  DropdownMenuItem(
                      value: level, child: Text(level.label(l.isPersian))),
              ],
              onChanged: _busy
                  ? null
                  : (level) {
                      if (level != null) s.setThinkingEffort(level);
                    },
            ),
          if (models.isEmpty && !_busy)
            Text(l.tx(
                'No model list is saved for this key. Update the list first.',
                'برای این کلید فهرستی ذخیره نشده است. ابتدا فهرست را به‌روز کنید.')),
          const SizedBox(height: 16),
          Text(l.tx(
              'The list comes from the service. Use also depends on your account limits and credit.',
              'فهرست از سرویس دریافت می‌شود. امکان استفاده به محدودیت‌ها و اعتبار حساب هم بستگی دارد.')),
          OutlinedButton.icon(
              icon: const Icon(Icons.check_circle_outline),
              label: Text(l.tx('Check selected model', 'بررسی مدل انتخابی')),
              onPressed: _busy || selected.isEmpty ? null : _test),
        ]));
  }
}
