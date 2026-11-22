/// Tests for lib/dialogs/snippet_env_dialog.dart — the values a snippet is
/// asked for before it runs (bostrot/ai-tasks#99).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/snippet_env.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/snippet_env_dialog.dart';
import 'package:wsl2distromanager/screens/snippet_editor_screen.dart';

QuickActionItem snippet({String content = 'echo hi', String env = ''}) =>
    QuickActionItem.fromYamlString('''
name: github-runner
description: A self-hosted runner
version: 1.0.0
author: bostrot
license: MIT
git: https://github.com/bostrot/wsl-scripts
distro: Ubuntu
$env''', content: content);

void main() {
  setUpAll(() {
    // The editor reports a save through Notify, which has no host widget here.
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {};
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// A page with one button that asks for the snippet's environment and
  /// records the answer — the shape of both "run snippet" call sites.
  Future<void> pump(WidgetTester tester, QuickActionItem action,
      List<Map<String, String>?> answers) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Builder(
          builder: (context) => Button(
            child: const Text('run'),
            onPressed: () async =>
                answers.add(await askSnippetEnv(context, action)),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
  }

  testWidgets('a snippet with nothing to ask for runs straight away',
      (tester) async {
    final answers = <Map<String, String>?>[];
    await pump(tester, snippet(), answers);

    expect(find.byKey(const ValueKey('test-snippet-env-run')), findsNothing);
    expect(answers.single, isEmpty);
  });

  testWidgets('one field per declared variable, with the author\'s words',
      (tester) async {
    await pump(tester, snippet(env: '''
env:
  - name: RUNNER_URL
    description: Where the runner registers
    required: true
  - name: RUNNER_TOKEN
    secret: true
'''), <Map<String, String>?>[]);

    expect(find.text('RUNNER_URL'), findsWidgets);
    expect(find.text('Where the runner registers'), findsOneWidget);
    expect(find.byKey(const ValueKey('test-snippet-env-RUNNER_URL')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-snippet-env-RUNNER_TOKEN')),
        findsOneWidget);
    // A secret is masked and says it is not kept.
    expect(find.text('snippetenvsecret-text'), findsOneWidget);
  });

  testWidgets('what the user types comes back, empty fields dropped',
      (tester) async {
    final answers = <Map<String, String>?>[];
    await pump(tester, snippet(env: '''
env:
  - name: RUNNER_URL
  - name: RUNNER_NAME
'''), answers);

    await tester.enterText(
        find.byKey(const ValueKey('test-snippet-env-RUNNER_URL')),
        'https://github.com/bostrot/wslmanager');
    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();

    expect(answers.single,
        {'RUNNER_URL': 'https://github.com/bostrot/wslmanager'});
  });

  testWidgets('a required variable holds the dialog open', (tester) async {
    final answers = <Map<String, String>?>[];
    await pump(tester, snippet(env: '''
env:
  - name: RUNNER_TOKEN
    required: true
'''), answers);

    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('test-snippet-env-error')), findsOneWidget);
    expect(answers, isEmpty, reason: 'nothing may run yet');

    await tester.enterText(
        find.byKey(const ValueKey('test-snippet-env-RUNNER_TOKEN')), 'abc123');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-snippet-env-error')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();
    expect(answers.single, {'RUNNER_TOKEN': 'abc123'});
  });

  testWidgets('cancelling runs nothing at all', (tester) async {
    final answers = <Map<String, String>?>[];
    await pump(tester, snippet(env: 'env:\n  - name: RUNNER_URL\n'), answers);

    await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(answers.single, isNull);
  });

  testWidgets('a default is prefilled and only has to be confirmed',
      (tester) async {
    final answers = <Map<String, String>?>[];
    await pump(tester, snippet(env: '''
env:
  - name: RUNNER_DIR
    default: /opt/actions-runner
'''), answers);

    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();
    expect(answers.single, {'RUNNER_DIR': '/opt/actions-runner'});
  });

  testWidgets('the last value comes back, but never a secret', (tester) async {
    const env = '''
env:
  - name: RUNNER_URL
  - name: RUNNER_TOKEN
    secret: true
''';
    await pump(tester, snippet(env: env), <Map<String, String>?>[]);
    await tester.enterText(
        find.byKey(const ValueKey('test-snippet-env-RUNNER_URL')),
        'https://example.test/org');
    await tester.enterText(
        find.byKey(const ValueKey('test-snippet-env-RUNNER_TOKEN')), 'secret');
    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();

    expect(prefs.getString('SnippetEnv_github-runner_RUNNER_URL'),
        'https://example.test/org');
    expect(prefs.getString('SnippetEnv_github-runner_RUNNER_TOKEN'), isNull,
        reason: 'a token must not end up in prefs on disk');

    // Re-opening offers the URL again and asks for the token afresh.
    final answers = <Map<String, String>?>[];
    await pump(tester, snippet(env: env), answers);
    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();
    expect(answers.single, {'RUNNER_URL': 'https://example.test/org'});
  });

  testWidgets('an undeclared variable the script reads is asked for too',
      (tester) async {
    final answers = <Map<String, String>?>[];
    await pump(tester,
        snippet(content: 'token="\${GH_TOKEN:-}"\necho "\$token"'), answers);

    expect(find.text('snippetenvdetected-text'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('test-snippet-env-GH_TOKEN')), 'ghp_1');
    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();
    expect(answers.single, {'GH_TOKEN': 'ghp_1'});
  });

  testWidgets('editing a snippet keeps its declared block', (tester) async {
    // The editor has no env field, so a rebuilt item would silently lose the
    // descriptions the run dialog is built from.
    final existing = snippet(env: '''
env:
  - name: RUNNER_TOKEN
    description: Registration token
    secret: true
''');
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester
        .pumpWidget(FluentApp(home: SnippetEditorPage(existing: existing)));
    await tester.pumpAndSettle();
    // Share rather than Save: both write the snippet the same way, and Save
    // then pops its route, which a bare FluentApp has no router for.
    await tester.tap(find.byKey(const ValueKey('test-snippet-share')));
    await tester.pumpAndSettle();

    final saved = QuickAction().byName('github-runner')!;
    expect(saved.env.single.name, 'RUNNER_TOKEN');
    expect(saved.env.single.secret, true);
    expect(saved.env.single.description, 'Registration token');
  });

  testWidgets('the values reach the snippet as exports', (tester) async {
    final answers = <Map<String, String>?>[];
    await pump(tester, snippet(env: 'env:\n  - name: RUNNER_URL\n'), answers);
    await tester.enterText(
        find.byKey(const ValueKey('test-snippet-env-RUNNER_URL')), 'https://x');
    await tester.tap(find.byKey(const ValueKey('test-snippet-env-run')));
    await tester.pumpAndSettle();

    final lines = SnippetEnv.exportLines(answers.single!);
    expect(lines.last, startsWith('export RUNNER_URL='));
  });
}
