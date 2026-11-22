/// Destructive actions have to look and behave destructive (FIX-08).
///
/// The three shapes this covers are the three the audit found missing: an
/// irreversible action that asks nothing before it runs (ST-04, ST-19, PS-35),
/// one that asks with copy written for a different object (ST-38, ST-54), and
/// one that is styled exactly like the harmless control next to it (LN-04,
/// ST-29, PS-27).
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// handed — which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/mount_service.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list_item.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/mount_dialog.dart';
import 'package:wsl2distromanager/dialogs/settings_dialog.dart';
import 'package:wsl2distromanager/screens/settings_screen.dart';

import 'mocks.dart';

/// The real client posts to analytics.bostrot.com; every dialog here opens
/// through `dialog()`, which reports a page view.
class _MockPlausible implements Plausible {
  @override
  Future<int> event(
          {String? name,
          String? page,
          Map<String, String>? props,
          String? referrer,
          PlausibleRevenue? revenue,
          bool interactive = true}) async =>
      200;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _read(String path) => File(path).readAsStringSync();

void main() {
  setUpAll(() {
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
    plausible = _MockPlausible();
    // The row under test is the WSL one; on a macOS dev host the default
    // backend would otherwise be Apple virtualization and hide half the
    // strip.
    vmBackendBuilder = () => WSLApi(shell: MockShell());
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
  });

  group('the distro row (LN-04)', () {
    Future<void> pumpBar(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Bar(
            widget: const ListItem(
                item: 'Ubuntu', running: [], trailing: '2.1 GB'),
            isCleaning: false,
            onCleaningChanged: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    /// The action icons, in the order they are laid out.
    List<Icon> icons(WidgetTester tester) => tester
        .widgetList<Icon>(
            find.descendant(of: find.byType(Bar), matching: find.byType(Icon)))
        .toList();

    testWidgets('delete is last, not between cleanup and settings',
        (tester) async {
      await pumpBar(tester);

      final glyphs = icons(tester).map((i) => i.icon).toList();
      expect(glyphs.last, FluentIcons.delete);
      // What made it a finding: the two controls it used to sit between are
      // both routine, and both are 32px away.
      expect(glyphs.indexOf(FluentIcons.broom),
          lessThan(glyphs.indexOf(FluentIcons.settings)));
      expect(glyphs.indexOf(FluentIcons.settings), glyphs.length - 2);
    });

    testWidgets('delete carries the destructive colour behind a separator',
        (tester) async {
      await pumpBar(tester);

      final deleteIcon = icons(tester).last;
      expect(deleteIcon.icon, FluentIcons.delete);
      expect(deleteIcon.color,
          destructiveColor(tester.element(find.byType(Bar))));
      // Every other icon in the strip keeps the ambient foreground.
      expect(icons(tester).where((i) => i.color != null).length, 1);
      expect(
          find.descendant(
              of: find.byType(Bar), matching: find.byType(Divider)),
          findsOneWidget);
    });
  });

  group('Stop WSL (ST-04)', () {
    testWidgets('asks before it shuts every instance down', (tester) async {
      var stopped = 0;
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              child: const Text('press'),
              onPressed: () => confirmStopWsl(context, () => stopped++),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('press'));
      await tester.pumpAndSettle();

      // The consequence is in the dialog, not only in a tooltip nobody hovers.
      expect(find.text('stopwslquestion-text'), findsOneWidget);
      expect(find.text('stopwslbody-text'), findsOneWidget);
      expect(stopped, 0);

      await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(stopped, 0, reason: 'Cancel may not shut WSL down');

      await tester.tap(find.text('press'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('stopwsl-text'));
      await tester.pumpAndSettle();
      expect(stopped, 1);
    });
  });

  group('clear chat history (PS-35)', () {
    Future<void> pumpChat(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
          const FluentApp(home: ScaffoldPage(content: AiChatPanel())));
      await tester.pumpAndSettle();
    }

    Finder clearButton() => find.byKey(const ValueKey('test-chat-clear'));

    testWidgets('is disabled while there is nothing to clear', (tester) async {
      AiService().clearHistory();
      await pumpChat(tester);

      final button = tester.widget<IconButton>(
          find.descendant(of: clearButton(), matching: find.byType(IconButton)));
      expect(button.onPressed, isNull);
    });

    testWidgets('asks before erasing a conversation', (tester) async {
      SharedPreferences.setMockInitialValues({
        'AiConversation': json.encode([
          {
            'role': 'user',
            'content': 'why is my distro stopped',
            'timestamp': '2026-08-30T10:00:00.000',
          }
        ])
      });
      prefs = await SharedPreferences.getInstance();
      await AiService().init();
      addTearDown(AiService().clearHistory);

      await pumpChat(tester);

      await tester.tap(clearButton());
      await tester.pumpAndSettle();

      expect(find.text('clearchatquestion-text'), findsOneWidget);
      expect(AiService().conversationHistory, hasLength(1),
          reason: 'the question is asked before anything is deleted');

      await tester.tap(find.text('clear-text'));
      await tester.pumpAndSettle();
      expect(AiService().conversationHistory, isEmpty);
    });
  });

  group('mount a physical disk (ST-46)', () {
    testWidgets('says it needs elevation and detaches the disk, up front',
        (tester) async {
      final shell = MockShell();
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: MountDialog(service: MountService(shell: shell)),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-mount-physical-warning')),
          findsOneWidget);
      expect(find.text('physicalmountwarning-text'), findsOneWidget);
      // "Up front" is the whole finding: the old copy was appended to the
      // error, after `wsl --mount` had already failed.
      expect(shell.runCalls.any((args) => args.contains('--mount')), false);
    });
  });

  group('the per-distro actions (ST-29)', () {
    Future<void> pumpColumn(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final draft = WslConfDraft();
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: SingleChildScrollView(
            child: StatefulBuilder(
              builder: (context, setState) => settingsColumn(
                TextEditingController(),
                TextEditingController(),
                TextEditingController(),
                context,
                'Ubuntu',
                false,
                setState,
                draft,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('sit under their own heading, not among the expanders',
        (tester) async {
      await pumpColumn(tester);

      expect(find.text('distroactions-text'), findsOneWidget);
      // Terminate used to be the fourth row of the `wsl.conf` stack, in the
      // shape of the three Expander headers above it.
      final heading = tester.getTopLeft(find.text('distroactions-text')).dy;
      expect(tester.getTopLeft(find.text('terminatedistro-text')).dy,
          greaterThan(heading));
      expect(tester.getTopLeft(find.text('interop-text')).dy,
          lessThan(heading));
    });

    testWidgets('the irreversible ones are coloured as such', (tester) async {
      await pumpColumn(tester);

      for (final label in ['terminatedistro-text', 'move-text']) {
        final icon = tester.widget<Icon>(find.descendant(
            of: find.ancestor(
                of: find.text(label), matching: find.byType(Button)),
            matching: find.byType(Icon)));
        expect(icon.color, destructiveColor(tester.element(find.text(label))),
            reason: '$label is not reversible');
      }
    });

    testWidgets('an action is sized to its label, not to the dialog',
        (tester) async {
      await pumpColumn(tester);

      final width = tester
          .getSize(find.ancestor(
              of: find.text('move-text'), matching: find.byType(Button)))
          .width;
      expect(width, lessThan(400),
          reason: 'a full-width row is the Expander shape ST-29 is about');
    });
  });

  group('the MCP token (ST-19)', () {
    // The settings screen reads `.wslconfig` off a real `WSLApi` in
    // `initState`, so it cannot be pumped here. What the finding is about is
    // reachable from the source: one click rotated the token, four pixels
    // from a copy button, with nothing between the press and the rotation.
    test('rotating it is behind a confirmation that says clients break', () {
      final src = _read('lib/screens/settings_screen.dart');
      final button = src.substring(src.indexOf('test-mcp-regenerate-token'));
      final press = button.substring(
          button.indexOf('onPressed:'), button.indexOf('regenerateToken()'));

      expect(press, contains('dialog('));
      expect(press, contains('regeneratetokenquestion-text'));
      expect(press, contains('regeneratetokenbody-text'));
      // And the rotation is reported: it used to leave no trace at all.
      expect(button, contains('tokenregenerated-text'));

      final en = json.decode(_read('lib/i18n/en.json')) as Map<String, dynamic>;
      expect((en['regeneratetokenbody-text'] as String).toLowerCase(),
          contains('mcp client'));
    });
  });

  group('delete copy is written for the object being deleted', () {
    test('templates and snippets no longer borrow the distro strings', () {
      expect(_read('lib/screens/template_screen.dart'),
          isNot(contains('deleteinstancequestion-text')));
      expect(_read('lib/screens/actions_screen.dart'),
          isNot(contains('deleteinstancebody-text')));
      expect(_read('lib/screens/template_screen.dart'),
          contains('deletetemplatequestion-text'));
      expect(_read('lib/screens/actions_screen.dart'),
          contains('deletesnippetquestion-text'));
    });

    test('the distro strings are used by the distro row alone (ST-38, ST-54)',
        () {
      final users = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => f.readAsStringSync().contains('deleteinstancequestion'))
          .map((f) => f.uri.pathSegments.last)
          .toList();
      expect(users, ['list_item.dart']);
    });

    test('neither new string calls a template or a snippet a distro', () {
      final en = json.decode(_read('lib/i18n/en.json')) as Map<String, dynamic>;
      String value(String key) {
        expect(en, contains(key));
        return (en[key] as String).toLowerCase();
      }

      expect(value('deletetemplatequestion-text'), contains('template'));
      expect(value('deletesnippetquestion-text'), contains('snippet'));
      // The bodies may mention instances — the template one says the ones
      // already stamped from it survive — but neither may still be the
      // distro's "you won't be able to recover it".
      for (final key in [
        'deletetemplatequestion-text',
        'deletetemplatebody-text',
        'deletesnippetquestion-text',
        'deletesnippetbody-text',
      ]) {
        expect(value(key), isNot(contains('distro')));
        expect(en[key], isNot(en['deleteinstancebody-text']));
        expect(en[key], isNot(en['deleteinstancequestion-text']));
      }
    });
  });

  group('every locale carries the new copy', () {
    test('the uninstall dialog names the tool in all nine (PS-28)', () {
      for (final file in Directory('lib/i18n')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))) {
        final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
        // One `%s` exactly: the localization package throws a RangeError on a
        // second placeholder it has no argument for.
        for (final key in [
          'ai-workspace-uninstall-title',
          'ai-workspace-uninstall-confirm',
          'deletetemplatequestion-text',
          'deletesnippetquestion-text',
        ]) {
          expect('%s'.allMatches(map[key] as String), hasLength(1),
              reason: '$key in ${file.uri.pathSegments.last}');
        }
      }
    });
  });
}
