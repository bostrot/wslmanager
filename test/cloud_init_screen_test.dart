/// Widget tests for lib/screens/cloud_init_screen.dart and the picker both
/// create pages carry (bostrot/ai-tasks#76).
///
/// No localization delegate is installed, so `.i18n()` returns the key —
/// assertions on `'cloudinit-text'` are the proof the label goes through
/// i18n.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/components/cloud_init_picker.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/cloud_init_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> messages;
  final store = CloudInitStore.instance;

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      messages.add(msg.toString());
    };
  });

  setUp(() async {
    messages = [];
    // The picker follows the cloud-init switch in Settings
    // (bostrot/ai-tasks#87); these tests are about the picker itself.
    SharedPreferences.setMockInitialValues(
        {ExperimentalFeature.cloudInit.prefKey: true});
    prefs = await SharedPreferences.getInstance();
    store.reload();
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(home: page));
    await tester.pumpAndSettle();
  }

  group('CloudInitPage', () {
    testWidgets('shows the empty state and a New button with nothing saved',
        (tester) async {
      await pump(tester, const CloudInitPage());
      expect(find.text('cloudinit-text'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-cloudinit-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-cloudinit-new')), findsOneWidget);
    });

    testWidgets('lists every saved configuration with its description',
        (tester) async {
      await store.save(const CloudInitConfig(
          name: 'dev', description: 'git and curl', content: '#cloud-config\n'));
      await store.save(
          const CloudInitConfig(name: 'db', content: '#!/bin/sh\n'));
      await pump(tester, const CloudInitPage());
      expect(find.byKey(const ValueKey('test-cloudinit-empty')), findsNothing);
      expect(find.byKey(const ValueKey('test-cloudinit-row-dev')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('test-cloudinit-row-db')),
          findsOneWidget);
      expect(find.textContaining('git and curl', findRichText: true),
          findsOneWidget);
    });

    testWidgets('duplicating makes a copy under a free name', (tester) async {
      await store.save(const CloudInitConfig(
          name: 'dev', description: 'd', content: '#cloud-config\nx: 1\n'));
      await pump(tester, const CloudInitPage());
      await tester
          .tap(find.byKey(const ValueKey('test-cloudinit-duplicate-dev')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('test-cloudinit-duplicate-dev')));
      await tester.pumpAndSettle();

      expect(store.items.map((e) => e.name), ['dev', 'dev-copy', 'dev-copy2']);
      expect(store.byName('dev-copy')?.content, '#cloud-config\nx: 1\n');
      expect(store.byName('dev-copy')?.description, 'd');
      expect(find.byKey(const ValueKey('test-cloudinit-row-dev-copy')),
          findsOneWidget);
    });

    testWidgets('deleting asks first and removes on confirmation',
        (tester) async {
      await store.save(
          const CloudInitConfig(name: 'dev', content: '#cloud-config\n'));
      await pump(tester, const CloudInitPage());
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-delete-dev')));
      await tester.pumpAndSettle();
      // The dialog names the configuration and says instances stay as
      // they are.
      expect(find.text('deletecloudinitbody-text'), findsOneWidget);
      expect(store.items, hasLength(1));

      await tester.tap(find.text('delete-text'));
      await tester.pumpAndSettle();
      expect(store.items, isEmpty);
      expect(find.byKey(const ValueKey('test-cloudinit-empty')), findsOneWidget);
    });
  });

  group('CloudInitEditorPage', () {
    CodeLineEditingController editorOf(WidgetTester tester) => tester
        .widget<CodeEditor>(find.byKey(const ValueKey('test-cloudinit-editor')))
        .controller!;

    testWidgets('a new configuration opens on the starter document',
        (tester) async {
      await pump(tester, const CloudInitEditorPage());
      expect(find.text('newcloudinit-text'), findsOneWidget);
      expect(editorOf(tester).text, kCloudInitStarter);
    });

    testWidgets('refuses to save without a name', (tester) async {
      await pump(tester, const CloudInitEditorPage());
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-cloudinit-error')), findsOneWidget);
      expect(find.text('cloudinitnamerequired-text'), findsOneWidget);
      expect(store.items, isEmpty);
    });

    testWidgets('refuses a name that is not a path segment', (tester) async {
      await pump(tester, const CloudInitEditorPage());
      await tester.enterText(
          find.byKey(const ValueKey('test-cloudinit-name')), 'has space');
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-save')));
      await tester.pumpAndSettle();
      expect(find.text('cloudinitnameinvalid-text'), findsOneWidget);
    });

    testWidgets('refuses a name another configuration already has',
        (tester) async {
      await store.save(
          const CloudInitConfig(name: 'dev', content: '#cloud-config\n'));
      await pump(tester, const CloudInitEditorPage());
      await tester.enterText(
          find.byKey(const ValueKey('test-cloudinit-name')), 'dev');
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-save')));
      await tester.pumpAndSettle();
      expect(find.text('cloudinitnametaken-text'), findsOneWidget);
      expect(store.items, hasLength(1));
    });

    testWidgets('refuses a document cloud-init would not run', (tester) async {
      await pump(tester, const CloudInitEditorPage());
      await tester.enterText(
          find.byKey(const ValueKey('test-cloudinit-name')), 'dev');
      editorOf(tester).text = 'packages:\n  - git\n';
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-save')));
      await tester.pumpAndSettle();
      expect(find.text('cloudinitheaderinvalid-text'), findsOneWidget);
      expect(store.items, isEmpty);
    });

    testWidgets('the highlighter follows the first line', (tester) async {
      await pump(tester, const CloudInitEditorPage());
      CodeEditor editor() => tester.widget<CodeEditor>(
          find.byKey(const ValueKey('test-cloudinit-editor')));
      expect(editor().style?.codeTheme?.languages.keys, ['yaml']);
      editorOf(tester).text = '#!/bin/sh\necho hi\n';
      await tester.pump();
      await tester.pump();
      expect(editor().style?.codeTheme?.languages.keys, ['bash']);
      // The editor schedules a short timer on a text change; let it fire
      // before the tree is torn down.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a broken cloud-config is reported with the YAML error',
        (tester) async {
      await pump(tester, const CloudInitEditorPage());
      await tester.enterText(
          find.byKey(const ValueKey('test-cloudinit-name')), 'dev');
      editorOf(tester).text = '#cloud-config\npackages: [git\n';
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('cloudinityamlinvalid-text'), findsOneWidget);
    });

    testWidgets('saves a valid configuration and says so', (tester) async {
      await pump(tester, const CloudInitEditorPage());
      await tester.enterText(
          find.byKey(const ValueKey('test-cloudinit-name')), 'dev');
      await tester.enterText(
          find.byKey(const ValueKey('test-cloudinit-description')), 'tools');
      editorOf(tester).text = '#cloud-config\npackages:\n  - git\n';
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-cloudinit-error')), findsNothing);
      expect(store.byName('dev')?.content, '#cloud-config\npackages:\n  - git\n');
      expect(store.byName('dev')?.description, 'tools');
      expect(messages, contains('cloudinitsaved-text'));
    });

    testWidgets('editing opens on the existing text and may rename it',
        (tester) async {
      await store.save(const CloudInitConfig(
          name: 'dev', description: 'd', content: '#cloud-config\nx: 1\n'));
      await pump(tester, CloudInitEditorPage(existing: store.byName('dev')));
      expect(find.text('editcloudinit-text'), findsOneWidget);
      expect(editorOf(tester).text, '#cloud-config\nx: 1\n');

      await tester.enterText(
          find.byKey(const ValueKey('test-cloudinit-name')), 'dev2');
      await tester.tap(find.byKey(const ValueKey('test-cloudinit-save')));
      await tester.pumpAndSettle();
      expect(store.items.map((e) => e.name), ['dev2']);
    });
  });

  group('CloudInitPicker', () {
    testWidgets('offers None plus every saved configuration', (tester) async {
      await store.save(const CloudInitConfig(
          name: 'dev', description: 'tools', content: '#cloud-config\n'));
      await store.save(const CloudInitConfig(name: 'db', content: '#!/bin/sh'));
      String chosen = '';
      await pump(
          tester,
          ScaffoldPage(
              content: CloudInitPicker(
            value: '',
            hint: 'cloudinitwslhint-text',
            onChanged: (v) => chosen = v,
          )));
      final box = tester.widget<ComboBox<String>>(
          find.byKey(const ValueKey('test-create-cloudinit')));
      expect(box.items!.map((e) => e.value), ['', 'dev', 'db']);
      expect(find.text('cloudinitwslhint-text'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-create-cloudinit-new')),
          findsOneWidget);

      box.onChanged!('dev');
      expect(chosen, 'dev');
    });

    testWidgets('falls back to None when the chosen one was deleted',
        (tester) async {
      await pump(
          tester,
          ScaffoldPage(
              content: CloudInitPicker(
            value: 'gone',
            hint: 'h',
            onChanged: (_) {},
          )));
      final box = tester.widget<ComboBox<String>>(
          find.byKey(const ValueKey('test-create-cloudinit')));
      expect(box.value, '');
    });

    testWidgets('is read-only while a create runs', (tester) async {
      await pump(
          tester,
          ScaffoldPage(
              content: CloudInitPicker(
            value: '',
            hint: 'h',
            enabled: false,
            onChanged: (_) {},
          )));
      final box = tester.widget<ComboBox<String>>(
          find.byKey(const ValueKey('test-create-cloudinit')));
      expect(box.onChanged, isNull);
      expect(
          tester
              .widget<HyperlinkButton>(
                  find.byKey(const ValueKey('test-create-cloudinit-new')))
              .onPressed,
          isNull);
    });
  });
}
