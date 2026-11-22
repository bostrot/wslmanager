/// Tests for the keyboard-operability slice of the UI/UX audit (FIX-06):
/// the shell tab order, the focus adoption that unsticks a dead Tab, the
/// distro row's single focus ring and the safe default in a confirmation.
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list_item.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:wsl2distromanager/nav/shell_focus.dart';
import 'package:wsl2distromanager/theme.dart';

import 'mocks.dart';

/// Labels every tab stop reachable from the pumped widget, in order, by
/// walking the cycle until it wraps.
Future<List<String>> tabCycle(WidgetTester tester, {int limit = 30}) async {
  final seen = <String>[];
  for (var i = 0; i < limit; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final label = primaryFocus?.debugLabel ?? '<none>';
    if (seen.contains(label)) break;
    seen.add(label);
  }
  return seen;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // ListItem asks for the host backend when it mounts. On a Windows
    // runner that is a real WSLApi, and the first WSLApi ever built kicks
    // off the distro-catalogue fetch — inside a widget test that is a Dio
    // timer left pending in the fake zone, which fails the test. Building
    // it here, outside the pump, keeps that one-off out of the test body.
    final backend = WSLApi(shell: MockShell());
    vmBackendBuilder = () => backend;
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
  });

  group('shouldAdoptKeyboardFocus', () {
    testWidgets('true when focus is parked on the root scope', (tester) async {
      await tester.pumpWidget(const FluentApp(home: SizedBox()));
      // The measured dead state: focus on the root scope with the whole tree
      // below it unreachable.
      final root = FocusManager.instance.rootScope;
      addTearDown(() => root.descendantsAreFocusable = true);
      root.descendantsAreFocusable = false;
      root.requestFocus();
      await tester.pump();

      expect(primaryFocus, root);
      expect(shouldAdoptKeyboardFocus(), true);
    });

    test('true when nothing has been focused yet', () {
      expect(shouldAdoptKeyboardFocus(), true);
    });

    testWidgets('false while a real control holds focus', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
          FluentApp(home: Focus(focusNode: node, child: const SizedBox())));
      node.requestFocus();
      await tester.pump();

      // A text box the user is typing in, or an open dialog, must not have
      // focus yanked back to the shell.
      expect(shouldAdoptKeyboardFocus(), false);
    });
  });

  group('ShellTraversalPolicy', () {
    /// The shell's shape: the page is built before the chrome, which is what
    /// put the navigation pane last in the measured cycle (IA-05).
    Widget shell() => FluentApp(
          home: FocusTraversalGroup(
            policy: ShellTraversalPolicy(),
            child: Column(
              children: [
                ShellBodyScope(
                  child: FocusTraversalGroup(
                    child: Row(children: [
                      Button(
                          focusNode: FocusNode(debugLabel: 'page-one'),
                          onPressed: () {},
                          child: const Text('page one')),
                      Button(
                          focusNode: FocusNode(debugLabel: 'page-two'),
                          onPressed: () {},
                          child: const Text('page two')),
                    ]),
                  ),
                ),
                Row(children: [
                  Button(
                      focusNode: FocusNode(debugLabel: 'chrome-one'),
                      onPressed: () {},
                      child: const Text('chrome one')),
                  Button(
                      focusNode: FocusNode(debugLabel: 'chrome-two'),
                      onPressed: () {},
                      child: const Text('chrome two')),
                ]),
              ],
            ),
          ),
        );

    testWidgets('reaches the chrome before the page content', (tester) async {
      await tester.pumpWidget(shell());

      expect(await tabCycle(tester),
          ['chrome-one', 'chrome-two', 'page-one', 'page-two']);
    });

    testWidgets('falls back to reading order when there is no body',
        (tester) async {
      await tester.pumpWidget(FluentApp(
        home: FocusTraversalGroup(
          policy: ShellTraversalPolicy(),
          child: Row(children: [
            Button(
                focusNode: FocusNode(debugLabel: 'first'),
                onPressed: () {},
                child: const Text('first')),
            Button(
                focusNode: FocusNode(debugLabel: 'second'),
                onPressed: () {},
                child: const Text('second')),
          ]),
        ),
      ));

      expect(await tabCycle(tester), ['first', 'second']);
    });
  });

  group('ListItem focus', () {
    Widget row() => const FluentApp(
          home: ScaffoldPage(
            content: ListItem(
                item: 'Ubuntu', running: ['Ubuntu'], trailing: '2.1 GB'),
          ),
        );

    /// The width the ring at [finder] would actually paint. fluent_ui resolves
    /// it from the nearest [FocusTheme], so a suppressed ring reports 0 while
    /// still reporting `focused: true`.
    double ringWidth(WidgetTester tester, Finder finder) =>
        FocusTheme.of(tester.element(finder)).primaryBorder?.width ?? 0;

    testWidgets('the header draws no second ring around its chevron',
        (tester) async {
      await tester.pumpWidget(row());

      // Start and Stop live inside the Expander header's own HoverButton, so
      // focusing one lit the button's ring *and* the chevron's, 1,100px apart
      // (IA-05, IA-06). The chevron's ring is switched off at the theme.
      final chevron = find.ancestor(
        of: find.byWidgetPredicate((widget) =>
            widget is Icon &&
            (widget.icon == FluentIcons.chevron_down ||
                widget.icon == FluentIcons.chevron_up)),
        matching: find.byType(FocusBorder),
      ).first;
      final startButton = find.descendant(
        of: find.byKey(const ValueKey('test-listitem-start')),
        matching: find.byType(FocusBorder),
      ).first;

      expect(ringWidth(tester, chevron), 0);
      expect(ringWidth(tester, startButton), greaterThan(0));
    });

    testWidgets('the row stop lights the row, not a control inside it',
        (tester) async {
      await tester.pumpWidget(row());
      final rowRing = find.ancestor(
        of: find.byType(Expander),
        matching: find.byType(FocusBorder),
      );
      expect(tester.widget<FocusBorder>(rowRing).focused, false);

      // First stop is the header itself.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(tester.widget<FocusBorder>(rowRing).focused, true);

      // Second stop is the Start button, which owns its own ring.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(tester.widget<FocusBorder>(rowRing).focused, false);
    });
  });

  group('confirmation dialogs', () {
    testWidgets('focus the safe action, not the destructive one',
        (tester) async {
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(key: (GlobalVariable.infobox = GlobalKey())),
      ));

      dialog(
        item: 'Ubuntu',
        title: 'Delete Ubuntu?',
        body: 'This cannot be undone.',
        submitText: 'Delete',
        submitInput: false,
        onSubmit: (_) {},
      );
      await tester.pumpAndSettle();

      // Tab, Enter on a modal is a reflex; it used to delete the distro.
      final cancel = find.byKey(const ValueKey('test-dialog-cancel'));
      expect(tester.widget<Button>(cancel).autofocus, true);
      expect(primaryFocus?.context?.findAncestorWidgetOfExactType<Button>(),
          tester.widget<Button>(cancel));
    });

    testWidgets('a dialog that asks for text focuses the box', (tester) async {
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(key: (GlobalVariable.infobox = GlobalKey())),
      ));

      dialog(item: 'Name', title: 'Copy Ubuntu', submitText: 'Copy');
      await tester.pumpAndSettle();

      expect(tester.widget<Button>(
              find.byKey(const ValueKey('test-dialog-cancel')))
          .autofocus, false);
      expect(tester.widget<TextBox>(find.byType(TextBox)).autofocus, true);
    });
  });

  group('buildAppTheme', () {
    test('draws a focus ring thick enough to see', () {
      // WCAG 2.2 Focus Appearance asks for the area of a 2px perimeter; the
      // shipped ring measured as a hairline (IA-07). Both strokes carry the
      // width — the inner one is what separates the ring from its background.
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(
          brightness: brightness,
          accentColor: Colors.blue,
          tenFootScreen: false,
        );
        final focus = FocusThemeData.fromTheme(theme).merge(theme.focusTheme);

        expect(focus.primaryBorder?.width, greaterThanOrEqualTo(2.0));
        expect(focus.secondaryBorder?.width, greaterThanOrEqualTo(2.0));
        expect(focus.primaryBorder?.color, isNot(focus.secondaryBorder?.color));
      }
    });

    test('keeps the ten-foot glow behind a flag', () {
      expect(
          buildAppTheme(
                  brightness: Brightness.light,
                  accentColor: Colors.blue,
                  tenFootScreen: true)
              .focusTheme
              .glowFactor,
          2.0);
    });
  });

  group('keyboard reachability', () {
    test('no interactive GestureDetector is left in lib/', () {
      // A GestureDetector has no focus node and no semantics action, so a
      // control built out of one cannot be reached or activated by keyboard
      // at all (IA-04). Three of them were the AI panel's only entry point,
      // the Pro upsell's only call to action and a recommendation's action.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('GestureDetector(')) {
            offenders.add('${entity.path}:${i + 1}');
          }
        }
      }

      expect(offenders, isEmpty);
    });
  });
}
