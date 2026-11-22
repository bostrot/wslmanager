/// Widget tests for lib/screens/provisioning_screen.dart
/// (bostrot/ai-tasks#78): the list, the editor and the apply page against
/// a scripted backend.
///
/// No localization delegate is installed, so `.i18n()` returns the key —
/// assertions on `'playbooks-text'` are the proof the label goes through
/// i18n.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/provisioning.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';
import 'package:wsl2distromanager/screens/provisioning_screen.dart';

import 'fake_provisioning_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> messages;
  final store = PlaybookStore.instance;
  final runs = PlaybookRunStore.instance;

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
    UnsavedChangesGuard.reset();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store.reload();
    runs.reload();
    runs.now = () => DateTime(2026, 9, 14, 11, 5);
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(home: page));
    await tester.pumpAndSettle();
  }

  group('PlaybooksPage', () {
    testWidgets('shows the empty state and a New button with nothing saved',
        (tester) async {
      await pump(tester, const PlaybooksPage());
      expect(find.text('playbooks-text'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-playbook-empty')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-playbook-new')), findsOneWidget);
    });

    testWidgets('lists every playbook with its description and run history',
        (tester) async {
      await store.save(const Playbook(
          name: 'dev',
          description: 'git and curl',
          content: 'packages: [git]'));
      await store.save(const Playbook(name: 'db', content: 'packages: [pg]'));
      await ProvisioningRunner(ScriptedBackend())
          .apply('ubuntu', store.byName('dev')!);
      await pump(tester, const PlaybooksPage());
      expect(find.byKey(const ValueKey('test-playbook-empty')), findsNothing);
      expect(
          find.byKey(const ValueKey('test-playbook-row-dev')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('test-playbook-row-db')), findsOneWidget);
      expect(find.textContaining('git and curl', findRichText: true),
          findsOneWidget);
      expect(find.byKey(const ValueKey('test-playbook-run-dev-ubuntu')),
          findsOneWidget);
      expect(find.textContaining('2026-09-14 11:05'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('test-playbook-norun-db')), findsOneWidget);
    });

    testWidgets('duplicating makes a copy under a free name', (tester) async {
      await store.save(const Playbook(
          name: 'dev', description: 'd', content: 'packages: [git]\n'));
      await pump(tester, const PlaybooksPage());
      await tester
          .tap(find.byKey(const ValueKey('test-playbook-duplicate-dev')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('test-playbook-duplicate-dev')));
      await tester.pumpAndSettle();
      expect(store.items.map((e) => e.name), ['dev', 'dev-copy', 'dev-copy2']);
      expect(store.byName('dev-copy')?.content, 'packages: [git]\n');
      expect(find.byKey(const ValueKey('test-playbook-row-dev-copy')),
          findsOneWidget);
    });

    testWidgets('deleting asks first and removes on confirmation',
        (tester) async {
      await store.save(const Playbook(name: 'dev', content: 'packages: [x]'));
      await pump(tester, const PlaybooksPage());
      await tester.tap(find.byKey(const ValueKey('test-playbook-delete-dev')));
      await tester.pumpAndSettle();
      expect(find.text('deleteplaybookbody-text'), findsOneWidget);
      expect(store.items, hasLength(1));

      await tester.tap(find.text('delete-text'));
      await tester.pumpAndSettle();
      expect(store.items, isEmpty);
      expect(find.byKey(const ValueKey('test-playbook-empty')), findsOneWidget);
    });
  });

  group('PlaybookEditorPage', () {
    CodeLineEditingController editorOf(WidgetTester tester) => tester
        .widget<CodeEditor>(find.byKey(const ValueKey('test-playbook-editor')))
        .controller!;

    testWidgets('a new playbook opens on the starter document', (tester) async {
      await pump(tester, const PlaybookEditorPage());
      expect(find.text('newplaybook-text'), findsOneWidget);
      expect(editorOf(tester).text, kPlaybookStarter);
      // The starter is itself a valid playbook.
      expect(validatePlaybook(kPlaybookStarter), isNull);
    });

    testWidgets('an existing playbook fills the form', (tester) async {
      await pump(
          tester,
          const PlaybookEditorPage(
              existing: Playbook(
                  name: 'dev',
                  description: 'tools',
                  content: 'packages: [git]\n')));
      expect(find.text('editplaybook-text'), findsOneWidget);
      expect(
          tester
              .widget<TextBox>(find.byKey(const ValueKey('test-playbook-name')))
              .controller
              ?.text,
          'dev');
      expect(editorOf(tester).text, 'packages: [git]\n');
    });

    testWidgets('refuses a missing name, a bad name and a taken name',
        (tester) async {
      await store.save(const Playbook(name: 'taken', content: 'packages: [x]'));
      await pump(tester, const PlaybookEditorPage());
      final save = find.byKey(const ValueKey('test-playbook-save'));
      final error = find.byKey(const ValueKey('test-playbook-error'));

      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(error).data, 'playbooknamerequired-text');

      await tester.enterText(
          find.byKey(const ValueKey('test-playbook-name')), 'bad name');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(error).data, 'playbooknameinvalid-text');

      await tester.enterText(
          find.byKey(const ValueKey('test-playbook-name')), 'taken');
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(error).data, 'playbooknametaken-text');
      expect(store.items, hasLength(1));
      expect(messages, isEmpty);
    });

    testWidgets('refuses a document the engine cannot apply', (tester) async {
      await pump(tester, const PlaybookEditorPage());
      await tester.enterText(
          find.byKey(const ValueKey('test-playbook-name')), 'dev');
      editorOf(tester).text = 'hostname: box\n';
      await tester.tap(find.byKey(const ValueKey('test-playbook-save')));
      await tester.pumpAndSettle();
      final error = find.byKey(const ValueKey('test-playbook-error'));
      expect(
          tester.widget<Text>(error).data, startsWith('playbooknothing-text'));
      expect(store.items, isEmpty);

      editorOf(tester).text = 'packages: [\n';
      await tester.tap(find.byKey(const ValueKey('test-playbook-save')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(error).data,
          startsWith('playbookyamlinvalid-text'));
    });

    testWidgets('saves a valid playbook and says so', (tester) async {
      await pump(tester, const PlaybookEditorPage());
      await tester.enterText(
          find.byKey(const ValueKey('test-playbook-name')), 'dev');
      await tester.enterText(
          find.byKey(const ValueKey('test-playbook-description')), 'tools');
      editorOf(tester).text = 'packages: [git]';
      await tester.tap(find.byKey(const ValueKey('test-playbook-save')));
      await tester.pumpAndSettle();
      expect(store.byName('dev')?.description, 'tools');
      expect(store.byName('dev')?.content, 'packages: [git]\n');
      expect(messages, ['playbooksaved-text']);
    });

    testWidgets('leaving with edits asks first; Close honours the answer',
        (tester) async {
      await pump(tester, const PlaybookEditorPage());
      expect(UnsavedChangesGuard.isDirty, isTrue,
          reason: 'the editor registers a guard while it is on screen');
      // Nothing typed yet: leaving is free.
      expect(await UnsavedChangesGuard.confirmLeave(), isTrue);

      editorOf(tester).text = 'packages: [git]\n';
      final leave = UnsavedChangesGuard.confirmLeave();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-unsaved-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('test-unsaved-cancel')));
      await tester.pumpAndSettle();
      expect(await leave, isFalse);

      // Close asks too, and Save from the prompt saves.
      await tester.enterText(
          find.byKey(const ValueKey('test-playbook-name')), 'dev');
      await tester.tap(find.byKey(const ValueKey('test-playbook-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-unsaved-save')));
      await tester.pumpAndSettle();
      expect(store.byName('dev')?.content, 'packages: [git]\n');
      expect(messages, ['playbooksaved-text']);
    });

    testWidgets('a rename carries the run history along', (tester) async {
      await store.save(const Playbook(name: 'dev', content: 'packages: [x]'));
      await ProvisioningRunner(ScriptedBackend())
          .apply('ubuntu', store.byName('dev')!);
      await pump(tester, PlaybookEditorPage(existing: store.byName('dev')));
      await tester.enterText(
          find.byKey(const ValueKey('test-playbook-name')), 'prod');
      await tester.tap(find.byKey(const ValueKey('test-playbook-save')));
      await tester.pumpAndSettle();
      expect(store.items.map((e) => e.name), ['prod']);
      expect(runs.forPlaybook('prod').single.instance, 'ubuntu');
      expect(runs.forPlaybook('dev'), isEmpty);
    });
  });

  group('PlaybookApplyPage', () {
    const playbook = Playbook(
      name: 'dev',
      description: 'tools',
      content: 'packages: [git]\nhostname: box\nruncmd:\n  - echo hi\n',
    );

    testWidgets('lists the instances, the steps, and applies to the chosen one',
        (tester) async {
      final backend = ScriptedBackend();
      backend.answers.addAll([
        answer('changed', stdout: 'git: missing'),
        answer('changed', stdout: 'hi'),
      ]);
      await pump(tester, PlaybookApplyPage(playbook: playbook, api: backend));
      expect(find.text('applyplaybooktitle-text'), findsOneWidget);
      expect(find.text('tools'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('test-playbook-instance')), findsOneWidget);
      // The plan is shown before anything runs.
      expect(
          find.byKey(const ValueKey('test-playbook-step-0')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('test-playbook-step-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-playbook-summary')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('test-playbook-run')));
      await tester.pumpAndSettle();

      expect(backend.targets, ['ubuntu', 'ubuntu']);
      expect(backend.commands.first, contains('WSLM_CHECK=0'));
      expect(find.text('playbookstatuschanged-text'), findsNWidgets(2));
      expect(find.text('playbookstatusskipped-text'), findsOneWidget);
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('test-playbook-summary')))
              .data,
          'playbooksummary-text');
      expect(messages, ['playbookdone-text']);
      expect(runs.forPlaybook('dev').single.changed, 2);
    });

    testWidgets('check mode runs with WSLM_CHECK=1 and a Check button',
        (tester) async {
      final backend = ScriptedBackend();
      await pump(tester, PlaybookApplyPage(playbook: playbook, api: backend));
      await tester.tap(find.byKey(const ValueKey('test-playbook-check')));
      await tester.pumpAndSettle();
      expect(find.text('applyplaybookcheckrun-text'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('test-playbook-run')));
      await tester.pumpAndSettle();
      expect(backend.commands.first, contains('WSLM_CHECK=1'));
      expect(runs.forPlaybook('dev').single.check, isTrue);
    });

    testWidgets('a failed step stops the run, opens its output and says so',
        (tester) async {
      final backend = ScriptedBackend();
      backend.answers.add(answer('failed', stderr: 'no apt here'));
      await pump(tester, PlaybookApplyPage(playbook: playbook, api: backend));
      await tester.tap(find.byKey(const ValueKey('test-playbook-run')));
      await tester.pumpAndSettle();

      expect(backend.commands, hasLength(1));
      expect(find.text('playbookstatusfailed-text'), findsOneWidget);
      expect(find.text('no apt here'), findsOneWidget);
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('test-playbook-summary')))
              .data,
          startsWith('playbookfailedat-text'));
      expect(messages, ['playbookfailed-text']);
    });

    testWidgets('says so when the playbook compiles to no steps',
        (tester) async {
      const empty = Playbook(
          name: 'nothing', content: 'package_update: false\npackages: []\n');
      await pump(
          tester, PlaybookApplyPage(playbook: empty, api: ScriptedBackend()));
      expect(
          find.byKey(const ValueKey('test-playbook-nosteps')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('test-playbook-run')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(runs.forPlaybook('nothing'), isEmpty);
    });

    testWidgets('says so when there is no instance', (tester) async {
      final backend = ScriptedBackend(instances: const []);
      await pump(tester, PlaybookApplyPage(playbook: playbook, api: backend));
      expect(find.byKey(const ValueKey('test-playbook-noinstances')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('test-playbook-instance')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('test-playbook-run')),
          warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(backend.commands, isEmpty);
    });
  });
}
