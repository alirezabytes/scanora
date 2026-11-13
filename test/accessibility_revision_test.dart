import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'dart:ui' show Tristate;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scanora/l10n/app_localizations.dart';
import 'package:scanora/services/settings_service.dart';
import 'package:scanora/models/captcha_result.dart';
import 'package:scanora/ui/screens/captcha_solver_screen.dart';
import 'package:scanora/ui/settings/help_screen.dart';
import 'package:scanora/ui/settings/privacy_policy_screen.dart';
import 'package:scanora/ui/settings/reading_playback_settings_screen.dart';
import 'package:scanora/ui/widgets/accessible_disclosure.dart';
import 'package:scanora/ui/widgets/accessible_dropdown_field.dart';
import 'package:scanora/ui/widgets/accessible_output_text.dart';
import 'package:scanora/ui/widgets/document_page_range_dialog.dart';
import 'package:scanora/ui/widgets/settings_rows.dart';
import 'package:scanora/services/ocr/captured_page_store.dart';
import 'package:scanora/services/tts/espeak_dictionary_service.dart';

class _ProgressSettings extends SettingsService {
  bool enabled = true;
  @override
  bool get announceProgress => enabled;
  @override
  Future<void> setAnnounceProgress(bool value) async {
    enabled = value;
    notifyListeners();
  }
}

void main() {
  testWidgets('Captcha answer hides model metadata and remains accessible',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final bytes = await tester.runAsync(
        () => File('test/fixtures/captchas/digits.png').readAsBytes());
    for (final language in ['en', 'fa']) {
      final settings = SettingsService.memory();
      final screenKey = GlobalKey<CaptchaSolverScreenState>();
      await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          key: ValueKey(language),
          locale: Locale(language),
          supportedLocales: const [Locale('en'), Locale('fa')],
          localizationsDelegates: const [
            AppLocalizationsDelegate(),
            ...GlobalMaterialLocalizations.delegates,
          ],
          home: CaptchaSolverScreen(key: screenKey),
        ),
      ));
      await tester.pumpAndSettle();
      await screenKey.currentState!.loadExternalImage(bytes!,
          solved: CaptchaResult(
            text: '72380',
            confidence: 1,
            elapsedMilliseconds: 1215,
            isOffline: true,
            providerName: 'ddddocr',
            modelName: 'ddddocr.onnx (Raw)',
          ));
      await tester.pumpAndSettle();
      expect(find.textContaining('ddddocr'), findsNothing);
      expect(find.textContaining('Model score'), findsNothing);
      expect(find.textContaining('1215'), findsNothing);
      expect(find.text('Solved Result'), findsNothing);
      expect(find.text('Output text'), findsNothing);
      expect(find.text('متن خروجی'), findsNothing);
      final label = language == 'fa' ? 'پاسخ کپچا' : 'Captcha answer';
      expect(find.text(label), findsNothing);
      final answer =
          tester.getSemantics(find.bySemanticsLabel(label)).getSemanticsData();
      expect(answer.value, '72380');
      expect(answer.flagsCollection.isTextField, isTrue);
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.readOnly, isTrue);
      expect(field.controller.text, '72380');
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    }
    semantics.dispose();
  },
      variant: TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.windows}));

  testWidgets('Long Windows output remains keyboard readable in one field',
      (tester) async {
    final content =
        List.generate(80, (i) => 'Paragraph content ${i + 1}').join('\n\n');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: AccessibleOutputText(text: content),
    )));
    final input = find.byType(EditableText);
    expect(input, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final field = tester.widget<EditableText>(input);
    expect(field.focusNode.hasFocus, isTrue);
    expect(field.readOnly, isTrue);
    expect(field.controller.text, content);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('TalkBack can expand and read an Android privacy topic',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: PrivacyPolicyScreen()));
    final title = find.bySemanticsLabel('Your privacy at a glance');
    final description =
        find.bySemanticsLabel(RegExp('Your data is never sent'));
    final before = tester.getSemantics(title);
    expect(
        before.getSemanticsData().flagsCollection.isExpanded, Tristate.isFalse);
    expect(description, findsNothing);
    before.owner!.performAction(before.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    final after = tester.getSemantics(title);
    expect(after.id, before.id);
    expect(
        after.getSemanticsData().flagsCollection.isExpanded, Tristate.isTrue);
    expect(description, findsOneWidget);
    after.owner!.performAction(after.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(description, findsNothing);
    semantics.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
      'Tab puts keyboard focus on the named switch and disclosure nodes',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SettingsSwitchRow(
            icon: Icons.percent,
            title: 'Announce progress',
            value: false,
            onChanged: (_) {},
          ),
          const AccessibleDisclosure(
            title: 'Camera reading',
            child: Text('Hold the camera steady.'),
          ),
        ]),
      ),
    ));
    for (final label in ['Announce progress', 'Camera reading']) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final data =
          tester.getSemantics(find.bySemanticsLabel(label)).getSemanticsData();
      expect(data.flagsCollection.isFocused, Tristate.isTrue, reason: label);
    }
    semantics.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
      'Page fields expose their names together with editable numeric values',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body:
                DocumentPageRangeDialog(totalPages: 20, allowForceOcr: true))));
    await tester.pump();
    final fields = tester.widgetList<EditableText>(find.byType(EditableText));
    expect(fields.length, 2);
    final start =
        tester.getSemantics(find.byType(EditableText).first).getSemanticsData();
    final end =
        tester.getSemantics(find.byType(EditableText).last).getSemanticsData();
    expect(start.label, contains('Start Page'));
    expect(start.value, '1');
    expect(end.label, contains('End Page'));
    expect(end.value, '20');
    expect(start.flagsCollection.isTextField, isTrue);

    for (final (label, value) in [('Start Page', '1'), ('End Page', '20')]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final data =
          tester.getSemantics(find.bySemanticsLabel(label)).getSemanticsData();
      expect(data.flagsCollection.isFocused, Tristate.isTrue, reason: label);
      expect(data.value, value);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    final returned = tester
        .getSemantics(find.bySemanticsLabel('Start Page'))
        .getSemanticsData();
    expect(returned.flagsCollection.isFocused, Tristate.isTrue);
    expect(returned.value, '1');
    semantics.dispose();
  },
      variant: TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.windows}));

  testWidgets('Tab reaches every privacy paragraph in a short Windows window',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(home: PrivacyPolicyScreen()));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // Back button.
    await tester.pumpAndSettle();
    for (final (heading, text) in [
      (
        'Your privacy at a glance',
        'never sent to or stored on a Scanora server'
      ),
      ('When you work without internet', 'With Work offline on'),
      ('When you use an online service', 'directly to the service you chose'),
      ('Scanora Cloud and Google Drive', 'Google receives the image'),
      ('Connection keys and web links', 'Scanora saves it in the app settings'),
      ('Your choices', 'turn on Work offline'),
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final data = tester
          .getSemantics(find.bySemanticsLabel(RegExp('^$heading\n')))
          .getSemanticsData();
      expect(data.label, contains(text));
      expect(data.flagsCollection.isFocused, Tristate.isTrue, reason: heading);
    }
    semantics.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
      'Switch has a name, current state and announces the changed state',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final messages = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (m) async {
      messages.add(m.toString());
      return null;
    });
    var enabled = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StatefulBuilder(
                builder: (context, setState) => SettingsSwitchRow(
                    icon: Icons.percent,
                    title: 'Announce progress',
                    value: enabled,
                    onChanged: (v) => setState(() => enabled = v))))));
    var data =
        tester.getSemantics(find.byType(SettingsSwitchRow)).getSemanticsData();
    expect(data.label, 'Announce progress');
    expect(data.flagsCollection.isToggled != Tristate.none, isTrue);
    expect(data.value, 'Off');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    data =
        tester.getSemantics(find.byType(SettingsSwitchRow)).getSemanticsData();
    expect(data.flagsCollection.isToggled == Tristate.isTrue, isTrue);
    expect(data.value, 'On');
    expect(messages.any((m) => m.contains('Announce progress: On')), isTrue);
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, null);
    semantics.dispose();
  });

  testWidgets('Disclosure expanded and collapsed states keep the topic name',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AccessibleDisclosure(
                title: 'Camera reading',
                child: Text('Keep the page steady.')))));
    final header = find.bySemanticsLabel('Camera reading');
    expect(header, findsOneWidget);
    expect(find.text('Keep the page steady.'), findsNothing);
    expect(
        tester
                .getSemantics(header)
                .getSemanticsData()
                .flagsCollection
                .isExpanded !=
            Tristate.none,
        isTrue);
    await tester.tap(find.text('Camera reading'));
    await tester.pump();
    expect(
        tester
                .getSemantics(header)
                .getSemanticsData()
                .flagsCollection
                .isExpanded ==
            Tristate.isTrue,
        isTrue);
    expect(find.text('Keep the page steady.'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
      'Android Help keeps each answer after its question in swipe order',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final announcements = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, (message) async {
      announcements.add(message.toString());
      return null;
    });
    addTearDown(() => messenger.setMockDecodedMessageHandler<Object?>(
        SystemChannels.accessibility, null));

    Iterable<String> labelsInOrder(SemanticsNode node) sync* {
      if (node.label.isNotEmpty) yield node.label;
      for (final child in node
          .debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder)) {
        yield* labelsInOrder(child);
      }
    }

    for (final language in ['en', 'fa']) {
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(language),
        locale: Locale(language),
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          ...GlobalMaterialLocalizations.delegates,
        ],
        home: const HelpScreen(),
      ));
      await tester.pumpAndSettle();
      final topics = tester
          .widgetList<AccessibleDisclosure>(find.byType(AccessibleDisclosure))
          .take(2)
          .toList();
      final question = topics.first.title;
      final answer = (topics.first.child as Text).data!;
      final nextQuestion = topics.last.title;
      final heading = find.bySemanticsLabel(question);
      final before = tester.getSemantics(heading);
      final owner = before.owner!;

      owner.performAction(before.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      final expanded = tester.getSemantics(heading);
      expect(expanded.id, before.id);
      expect(expanded.getSemanticsData().flagsCollection.isExpanded,
          Tristate.isTrue);
      final labels = labelsInOrder(owner.rootSemanticsNode!).toList();
      expect(labels.skip(labels.indexOf(question)).take(3),
          [question, answer, nextQuestion]);

      owner.performAction(expanded.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(answer), findsNothing);
    }
    expect(announcements.where((message) => message.contains('announce')),
        isEmpty);
    semantics.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('Dropdown exposes its field name with its selected option',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AccessibleDropdownField<String>(
                initialValue: 'online',
                decoration: const InputDecoration(labelText: 'Reading service'),
                items: const [
                  DropdownMenuItem(value: 'online', child: Text('Online'))
                ],
                onChanged: (_) {}))));
    final data = tester
        .getSemantics(find.byType(AccessibleDropdownField<String>))
        .getSemanticsData();
    expect(data.label, contains('Reading service'));
    expect(data.label, contains('Online'));
    semantics.dispose();
  });

  test(
      'Captured book photos are stored on disk and preserve their recognized text',
      () async {
    final pages = CapturedPageStore(offline: true);
    await pages.append(Uint8List.fromList([1, 2, 3]), text: 'Page one');
    await pages.append(Uint8List.fromList([4, 5, 6]), text: 'صفحه دو');
    expect(pages.length, 2);
    expect(pages[0], [1, 2, 3]);
    expect(pages.textAt(1), 'صفحه دو');
    await pages.close();
    expect(() => pages[0], throwsA(isA<FileSystemException>()));
  });

  test(
      'Dictionary import accepts the bundled format and rejects broken offsets',
      () async {
    final bytes =
        await File('windows/espeak-ng/espeak-ng-data/en_dict').readAsBytes();
    expect(EspeakDictionaryService.isValid('en_dict', bytes), isTrue);
    final broken = Uint8List.fromList(bytes);
    ByteData.sublistView(broken).setUint32(4, 0xffffffff, Endian.little);
    expect(EspeakDictionaryService.isValid('en_dict', broken), isFalse);
    expect(EspeakDictionaryService.isValid('../en_dict', bytes), isFalse);
    expect(EspeakDictionaryService.isValid('document.txt', Uint8List(2000)),
        isFalse);
  });
  testWidgets('Reading settings let the user turn off spoken progress',
      (tester) async {
    final settings = _ProgressSettings();
    await tester.pumpWidget(ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: const MaterialApp(home: ReadingPlaybackSettingsScreen())));
    final row = find.widgetWithText(SettingsSwitchRow, 'Announce progress');
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pump();
    expect(settings.announceProgress, isFalse);
    expect(tester.widget<SettingsSwitchRow>(row).value, isFalse);
  });
}
