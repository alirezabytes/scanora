import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:scanora/l10n/app_localizations.dart';
import 'package:scanora/models/ai_provider.dart';
import 'package:scanora/models/app_language.dart';
import 'package:scanora/services/ai/ai_access.dart';
import 'package:scanora/services/ai/ai_service.dart';
import 'package:scanora/services/ocr/page_turn_tracker.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/services/native_bridge_service.dart';
import 'package:scanora/services/tts/espeak_tts_service.dart';
import 'package:scanora/services/tts/tts_models.dart';
import 'package:scanora/ui/hub/adaptive_hub_screen.dart';
import 'package:scanora/ui/settings/ai_api_settings_screen.dart';
import 'package:scanora/ui/settings/espeak/espeak_voice_characteristics_screen.dart';
import 'package:scanora/ui/settings/espeak/espeak_settings_screen.dart';
import 'package:scanora/ui/settings/about_settings_screen.dart';
import 'package:scanora/ui/widgets/accessible_dropdown_field.dart';
import 'package:scanora/ui/widgets/accessible_output_text.dart';
import 'package:scanora/ui/widgets/document_page_range_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'Reasoning level is saved per model and sent with a Gemini image request',
      () async {
    final settings = SettingsService.memory();
    const provider = AIProviderType.gemini;
    await settings.setActiveProvider(provider);
    await settings.setDiscoveredModels(
        provider, ['gemini-2.5-flash', 'gemini-3-pro-preview']);
    await settings.setSelectedModel(provider, 'gemini-2.5-flash');
    await settings.setThinkingEffort(ThinkingEffort.medium);
    await settings.setSelectedModel(provider, 'gemini-3-pro-preview');
    expect(settings.thinkingEffort, ThinkingEffort.none);
    await settings.setThinkingEffort(ThinkingEffort.high);
    await settings.setSelectedModel(provider, 'gemini-2.5-flash');
    expect(settings.thinkingEffort, ThinkingEffort.medium);
    final image =
        await File('test/fixtures/english_document.png').readAsBytes();
    final response = await http.runWithClient(
      () => AIService.callVisionModel(
        providerType: provider,
        apiKey: 'fixture-key',
        modelName: settings.getSelectedModel(provider),
        customBaseUrl: '',
        imageBytes: image,
        prompt: 'Read',
        thinkingEffort: settings.thinkingEffort,
      ),
      () => MockClient((request) async {
        if (request.method == 'GET') {
          expect(request.url.path, '/v1beta/models/gemini-2.5-flash');
          return http.Response('{"name":"models/gemini-2.5-flash"}', 200);
        }
        final body = jsonDecode(request.body);
        expect(
            body['generationConfig']['thinkingConfig']['thinkingBudget'], 4096);
        return http.Response(
            '{"candidates":[{"content":{"parts":[{"text":"Read successfully"}]}}]}',
            200);
      }),
    );
    expect(response, 'Read successfully');
  });

  test('A different page number is not ignored in otherwise similar text', () {
    final body =
        List.filled(20, 'Some repeated book text with several different words.')
            .join(' ');
    expect(PageTurnTracker.sameText('$body ۱۲', '$body ۱۳'), isFalse);
  });

  test('Speech sample follows the interface language even with a fixed voice',
      () async {
    final settings = SettingsService.memory();
    await settings.setTtsVoice('fa');
    await settings.setLanguage('en');
    expect(EspeakTtsService.sampleText(settings), contains('Your text'));
    expect(
        RegExp(r'[\u0600-\u06ff]').hasMatch(EspeakTtsService.sampleText(
            settings,
            includePronunciationDemo: true)),
        isFalse);
    await settings.setTtsVoice('en');
    await settings.setLanguage('fa');
    expect(EspeakTtsService.sampleText(settings), contains('اسکنورا'));
    expect(AppLanguage.all.map((l) => l.displayName), ['English', 'Persian']);
    expect(AppLocalizations(const Locale('en')).translate('version'),
        'Scanora 2.4.15');
    expect(AppLocalizations(const Locale('fa')).translate('version'),
        'اسکنورا نسخه ۲.۴.۱۵');
  });

  test(
      'Rate boost reaches the native engine range and resets with voice settings',
      () async {
    final settings = SettingsService.memory();
    await settings.setTtsRate(450);
    await settings.setTtsRateBoost(true);
    expect(settings.effectiveTtsRate, 1350);
    await settings.resetTtsVoiceCharacteristics();
    expect(settings.effectiveTtsRate, 175);
    expect(settings.ttsRateBoost, isFalse);
  });

  test(
      'Models belong to a verified key and endpoint; stale responses cannot replace them',
      () async {
    final s = SettingsService.memory();
    const p = AIProviderType.custom;
    expect(s.getEffectiveModels(AIProviderType.gemini), isEmpty);
    await s.setApiKey(p, 'first-fixture-key');
    await s.setCustomBaseUrl('https://first.invalid/v1');
    final first = s.modelAccessFingerprint(p);
    await s.setDiscoveredModels(p, ['available-v1'],
        expectedFingerprint: first);
    await s.setSelectedModel(p, 'invented');
    expect(s.getSelectedModel(p), isEmpty);
    await s.setSelectedModel(p, 'available-v1');
    expect(s.getSelectedModel(p), 'available-v1');
    await s.setDiscoveredModels(p, ['available-v1', 'available-v2']);
    expect(s.getEffectiveModels(p), ['available-v1', 'available-v2']);
    expect(s.getSelectedModel(p), 'available-v1');
    await s.setCustomBaseUrl('https://second.invalid/v1');
    expect(s.getEffectiveModels(p), isEmpty);
    await s.setDiscoveredModels(p, ['stale'], expectedFingerprint: first);
    expect(s.getEffectiveModels(p), isEmpty);
    await s.setDiscoveredModels(p, ['second-model']);
    await s.setSelectedModel(p, 'second-model');
    await s.setApiKey(p, 'second-fixture-key');
    expect(s.getEffectiveModels(p), isEmpty);
    expect(s.getSelectedModel(p), isEmpty);
  });

  test(
      'Gemini discovery uses the key, follows pagination and filters audio-only models',
      () async {
    final pages = <String?>[];
    final models = await http.runWithClient(
        () => AIService.fetchAvailableModels(
            providerType: AIProviderType.gemini,
            apiKey: 'fixture-key',
            customBaseUrl: ''),
        () => MockClient((request) async {
              expect(request.headers['x-goog-api-key'], 'fixture-key');
              final token = request.url.queryParameters['pageToken'];
              pages.add(token);
              return http.Response(
                  jsonEncode({
                    'models': [
                      {
                        'name': token == null
                            ? 'models/vision-new'
                            : 'models/vision-upgraded',
                        'supportedGenerationMethods': ['generateContent']
                      },
                      {
                        'name': 'models/voice-tts',
                        'supportedGenerationMethods': ['generateContent']
                      },
                      {
                        'name': 'models/embedding-only',
                        'supportedGenerationMethods': ['embedContent']
                      },
                    ],
                    if (token == null) 'nextPageToken': 'second'
                  }),
                  200);
            }));
    expect(pages, [null, 'second']);
    expect(models, ['vision-new', 'vision-upgraded']);
  });

  test('Invalid OpenRouter keys cannot populate a public model catalog',
      () async {
    final paths = <String>[];
    await http.runWithClient(
        () => expectLater(
            AIService.fetchAvailableModels(
                providerType: AIProviderType.openrouter,
                apiKey: 'invalid-fixture-key',
                customBaseUrl: ''),
            throwsA(isA<AiServiceException>().having(
                (error) => error.kind, 'kind', AiFailureKind.invalidKey))),
        () => MockClient((r) async {
              paths.add(r.url.path);
              return http.Response('{}', 401);
            }));
    expect(paths, ['/api/v1/key']);
    paths.clear();
    await http.runWithClient(
        () => expectLater(
            AIService.fetchAvailableModels(
                providerType: AIProviderType.custom,
                apiKey: 'custom-fixture-key',
                customBaseUrl: ''),
            throwsA(isA<AiServiceException>().having(
                (error) => error.kind, 'kind', AiFailureKind.invalidEndpoint))),
        () => MockClient((r) async {
              paths.add(r.url.host);
              return http.Response('{}', 200);
            }));
    expect(paths, isEmpty,
        reason: 'A custom key must not go to a default third-party endpoint.');
  });

  test(
      'Display brightness flicker is ignored while changed letters remain detectable',
      () {
    final original =
        Uint8List.fromList(List.generate(200, (i) => i.isEven ? 30 : 180));
    final brighter = Uint8List.fromList(original.map((v) => v + 20).toList());
    expect(
        PageTurnTracker.imageDifference(original, brighter), closeTo(0, .0001));
    final changed = Uint8List.fromList(brighter.reversed.toList());
    expect(PageTurnTracker.imageDifference(original, changed), greaterThan(.1));
  });

  testWidgets(
      'The same read-only output and reading units are available on Android and Windows',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AccessibleOutputText(
                text: 'First paragraph.\n\nمتن فارسی.\n\nLast paragraph.',
                label: 'Recognized text'))));
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text,
        'First paragraph.\n\nمتن فارسی.\n\nLast paragraph.');
    expect(field.readOnly, isTrue);
    expect(find.bySemanticsLabel('Paragraph 1'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Read by')), findsWidgets);
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(field.focusNode.hasFocus, isTrue);
    }
    semantics.dispose();
  },
      variant: TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.windows}));

  testWidgets('A shared photo opens a named dialog with a real cancel action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(ChangeNotifierProvider.value(
        value: SettingsService.memory(),
        child: const MaterialApp(home: AdaptiveHubScreen())));
    await tester.pumpAndSettle();
    NativeBridgeService.onSharedImageReceived?.call(Uint8List.fromList([1]));
    await tester.pumpAndSettle();
    expect(
        find.text('What do you want to do with this image?'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('scrim', caseSensitive: false)),
        findsNothing);
    expect(find.text('Image to Text'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets(
      'Android announces the page name on every swipe, including quick revisits',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final messages = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (m) async {
      messages.add(m.toString());
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility, null));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: DocumentPageRangeDialog(totalPages: 25))));
    for (final (label, value) in [
      ('Start Page', '1'),
      ('End Page', '25'),
      ('Start Page', '1'),
    ]) {
      messages.clear();
      final node = tester.getSemantics(find.bySemanticsLabel(label));
      node.owner!
          .performAction(node.id, SemanticsAction.didGainAccessibilityFocus);
      await tester.pump();
      expect(messages.where((m) => m.contains('$label, $value')), hasLength(1));
    }
    semantics.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
      'Opening the main menu does not announce the entire menu as an alert',
      (tester) async {
    final messages = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (m) async {
      messages.add(m.toString());
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility, null));
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
        value: SettingsService.memory(),
        child: const MaterialApp(home: AdaptiveHubScreen())));
    await tester.pump();
    expect(
        messages.where((m) =>
            m.contains('Scanora.') && m.contains('Reading and Documents')),
        isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Voice dialog only applies changes on Save', (tester) async {
    final settings = SettingsService.memory();
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
      value: settings,
      child: MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () => editEspeakVoice(context),
          child: const Text('Open voice settings'),
        ),
      ))),
    ));

    for (final button in ['Cancel', 'Save']) {
      await tester.tap(find.text('Open voice settings'));
      await tester.pumpAndSettle();
      tester.widget<Slider>(find.byType(Slider).first).onChanged!(250);
      await tester.tap(find.text('Rate boost'));
      await tester.pump();
      expect(settings.ttsRate, 175);
      expect(settings.ttsRateBoost, isFalse);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(settings.ttsRate, button == 'Save' ? 250 : 175);
      expect(settings.ttsRateBoost, button == 'Save');
    }
    await tester.tap(find.text('Open voice settings'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue);
    expect(settings.effectiveTtsRate, 750);
    expect(find.text('750 words per minute, 429 percent'), findsOneWidget);
  });

  testWidgets('Punctuation defaults to Some and offers four ordered levels',
      (tester) async {
    final settings = SettingsService.memory();
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
      value: settings,
      child: const MaterialApp(home: EspeakSettingsScreen()),
    ));
    expect(settings.ttsPunctuation, TtsPunctuation.some);
    await tester.tap(find.text('Speak punctuation'));
    await tester.pumpAndSettle();
    final options = tester.widgetList<RadioListTile<TtsPunctuation>>(
        find.byType(RadioListTile<TtsPunctuation>));
    expect(options.map((option) => (option.title as Text).data),
        ['None', 'Some', 'Most', 'All']);
    await tester.tap(find.text('Most'));
    await tester.pumpAndSettle();
    expect(settings.ttsPunctuation, TtsPunctuation.most);
    expect(TtsPunctuation.fromPreference(0), TtsPunctuation.none);
    expect(TtsPunctuation.fromPreference(1), TtsPunctuation.all);
    expect(TtsPunctuation.fromPreference(2), TtsPunctuation.most);
    expect(TtsPunctuation.fromPreference(3), TtsPunctuation.some);
  });

  testWidgets('About lists English first and opens the offline privacy policy',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutSettingsScreen()));
    expect(find.text('Help & FAQ'), findsOneWidget);
    expect(find.text('Read English, Persian and mixed text'), findsOneWidget);
    expect(find.text('Open-source licenses'), findsNothing);
    expect(find.text('View full notices'), findsNothing);
    final policyButton = find.text('Privacy Policy');
    await tester.ensureVisible(policyButton);
    await tester.tap(policyButton);
    await tester.pumpAndSettle();
    expect(find.text('Your privacy at a glance'), findsOneWidget);
    await tester.tap(find.text('Your privacy at a glance'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('have no access through the app'), findsOneWidget);
    expect(find.text('Scanora Cloud and Google Drive'), findsOneWidget);
  });

  testWidgets(
      'Refreshing the same key replaces the model list after account changes',
      (tester) async {
    final s = SettingsService.memory();
    await s.toggleOfflineMode(false);
    await s.setActiveProvider(AIProviderType.gemini);
    await s.setApiKey(AIProviderType.gemini, 'fixture-service-key');
    var requestCount = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
          value: s, child: const MaterialApp(home: AiApiSettingsScreen())));
      await tester.pumpAndSettle();
      expect(s.getEffectiveModels(AIProviderType.gemini), ['model-one']);
      expect(s.getSelectedModel(AIProviderType.gemini), isEmpty);
      await s.setSelectedModel(AIProviderType.gemini, 'model-one');
      await tester.ensureVisible(find.text('Update key & model list'));
      await tester.tap(find.text('Update key & model list'));
      await tester.pumpAndSettle();
      expect(s.getEffectiveModels(AIProviderType.gemini),
          ['model-one', 'model-two']);
      expect(s.getSelectedModel(AIProviderType.gemini), 'model-one');
      final dropdown = tester.widget<AccessibleDropdownField<String>>(
          find.byType(AccessibleDropdownField<String>));
      expect(dropdown.items!.map((i) => i.value), ['model-one', 'model-two']);
      await tester.ensureVisible(find.text('Clear key'));
      await tester.tap(find.text('Clear key'));
      await tester.pumpAndSettle();
      expect(s.getApiKey(AIProviderType.gemini), isEmpty);
      expect(s.getSelectedModel(AIProviderType.gemini), isEmpty);
      expect(s.getEffectiveModels(AIProviderType.gemini), isEmpty);
      expect(find.text('Connection key cleared.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((r) async {
              requestCount++;
              return http.Response(
                  jsonEncode({
                    'models': [
                      {
                        'name': 'models/model-one',
                        'supportedGenerationMethods': ['generateContent']
                      },
                      if (requestCount > 1)
                        {
                          'name': 'models/model-two',
                          'supportedGenerationMethods': ['generateContent']
                        }
                    ]
                  }),
                  200);
            }));
    expect(requestCount, 2);
  });
}
