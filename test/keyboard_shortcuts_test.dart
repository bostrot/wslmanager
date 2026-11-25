import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list.dart';
import 'package:wsl2distromanager/components/list_item.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/nav/keyboard_shortcuts.dart';

import 'vm_backend_test.dart' show FakeBackend;

class _ListBackend extends FakeBackend {
  _ListBackend(this.names, {this.running = const []});
  final List<String> names;
  final List<String> running;
  final started = <String>[];
  final stopped = <String>[];

  @override
  Future<Instances> list(bool showDocker) async {
    lastDistroList = Instances(List.of(names), List.of(running));
    return lastDistroList;
  }

  @override
  Future<void> start(String distribution,
      {String startPath = '',
      String startUser = '',
      String startCmd = ''}) async {
    started.add(distribution);
  }

  @override
  Future<String> stop(String distribution) async {
    stopped.add(distribution);
    return '';
  }
}

final command = Platform.isMacOS
    ? LogicalKeyboardKey.metaLeft
    : LogicalKeyboardKey.controlLeft;

Future<void> chord(WidgetTester tester, LogicalKeyboardKey key,
    {bool shift = false}) async {
  await tester.sendKeyDownEvent(command);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(command);
  await tester.pump();
}

/// A dialog's open or close animation, run to the end.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    GlobalVariable.initialSnapshot = null;
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
    GlobalVariable.initialSnapshot = null;
  });

  group('instance list', () {
    Future<void> drainReloadLoop(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    }

    Future<void> pumpList(WidgetTester tester, VmBackend backend,
        {Widget? above}) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      vmBackendBuilder = () => backend;
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Column(children: [
            if (above != null) above,
            DistroList(api: backend),
          ]),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    String? selected(WidgetTester tester) {
      for (final row in tester.widgetList<ListItem>(find.byType(ListItem))) {
        if (row.selected) return row.item;
      }
      return null;
    }

    final filter = find.byKey(const ValueKey('test-instance-filter'));

    testWidgets('arrows, Home and End move the selection', (tester) async {
      await pumpList(tester, _ListBackend(['alpine', 'debian', 'fedora']));
      expect(selected(tester), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(selected(tester), 'alpine');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(selected(tester), 'debian');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(selected(tester), 'fedora');
      // Stops at the ends instead of wrapping.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(selected(tester), 'fedora');
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(selected(tester), 'alpine');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(selected(tester), 'alpine');

      // Escape lets go of it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(selected(tester), isNull);
      await drainReloadLoop(tester);
    });

    testWidgets('Enter starts the selected instance', (tester) async {
      final backend = _ListBackend(['alpine', 'debian']);
      await pumpList(tester, backend);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(backend.started, ['debian']);
      await drainReloadLoop(tester);
    });

    testWidgets('Ctrl+Shift+T opens a terminal, Ctrl+Shift+S stops',
        (tester) async {
      final backend = _ListBackend(['alpine'], running: ['alpine']);
      await pumpList(tester, backend);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      await chord(tester, LogicalKeyboardKey.keyT, shift: true);
      expect(backend.started, ['alpine']);
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyS, shift: true);
      expect(backend.stopped, ['alpine']);
      await drainReloadLoop(tester);
    });

    testWidgets('a stopped instance is not stopped again', (tester) async {
      final backend = _ListBackend(['alpine']);
      await pumpList(tester, backend);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyS, shift: true);
      expect(backend.stopped, isEmpty);
      await drainReloadLoop(tester);
    });

    Future<void> pressDelete(WidgetTester tester) async {
      if (Platform.isMacOS) {
        await chord(tester, LogicalKeyboardKey.backspace);
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pump();
      }
    }

    testWidgets('F2 renames, Delete asks first, Ctrl+D copies', (tester) async {
      await pumpList(tester, _ListBackend(['alpine', 'debian']));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      await settle(tester);
      expect(find.textContaining("'alpine'"), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(ContentDialog), findsNothing);

      await pressDelete(tester);
      await settle(tester);
      expect(find.textContaining('deleteinstancequestion'), findsOneWidget);
      // The confirmation still starts on Cancel.
      await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
      await settle(tester);
      expect(find.byType(ContentDialog), findsNothing);

      await chord(tester, LogicalKeyboardKey.keyD);
      await tester.pump();
      await settle(tester);
      expect(find.textContaining('copyinstance-text'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await drainReloadLoop(tester);
    });

    testWidgets('nothing acts without a selection', (tester) async {
      final backend = _ListBackend(['alpine']);
      await pumpList(tester, backend);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await pressDelete(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byType(ContentDialog), findsNothing);
      expect(backend.started, isEmpty);
      await drainReloadLoop(tester);
    });

    testWidgets('a click selects, a double-click on the name starts',
        (tester) async {
      final backend = _ListBackend(['alpine', 'debian']);
      await pumpList(tester, backend);
      await tester.tap(find.text('debian'));
      await tester.pump();
      expect(selected(tester), 'debian');
      expect(backend.started, isEmpty);

      await tester.tap(find.text('debian'));
      await tester.pump();
      expect(backend.started, ['debian']);
      await drainReloadLoop(tester);
    });

    testWidgets('keys stay with the filter while typing', (tester) async {
      final names = [for (var i = 0; i < 6; i++) 'distro-$i'];
      await pumpList(tester, _ListBackend(names));
      await tester.enterText(filter, 'distro');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await pressDelete(tester);
      await settle(tester);
      expect(find.byType(ContentDialog), findsNothing);
      expect(selected(tester), isNull);

      // Down leaves the box for the first match.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(selected(tester), 'distro-0');
      await drainReloadLoop(tester);
    });

    testWidgets('another text field keeps every key', (tester) async {
      final backend = _ListBackend(['alpine']);
      await pumpList(tester, backend,
          above: const TextBox(key: ValueKey('other-box')));
      await tester.tap(find.byKey(const ValueKey('other-box')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selected(tester), isNull);
      expect(backend.started, isEmpty);
      await drainReloadLoop(tester);
    });

    testWidgets('Escape clears a filter that does not have focus',
        (tester) async {
      final names = [for (var i = 0; i < 6; i++) 'distro-$i'];
      await pumpList(tester, _ListBackend(names));
      await tester.enterText(filter, 'o-3');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(find.text('distro-0'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('distro-0'), findsOneWidget);
      await drainReloadLoop(tester);
    });

    testWidgets('an open dialog keeps the keys', (tester) async {
      final backend = _ListBackend(['alpine']);
      await pumpList(tester, backend);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final context = tester.element(find.byType(DistroList));
      showDialog<void>(
        context: context,
        builder: (_) => const ContentDialog(
          content: Button(autofocus: true, onPressed: null, child: Text('x')),
        ),
      );
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
      expect(find.byType(ContentDialog), findsOneWidget);
      expect(backend.started, isEmpty);
      Navigator.of(context).pop();
      await settle(tester);
      await drainReloadLoop(tester);
    });
  });

  group('app shortcuts', () {
    late List<String> visited;
    late String path;
    late int helpCalls;

    PaneItem page(String key) => PaneItem(
          key: Key(key),
          icon: const Icon(FluentIcons.home),
          body: const SizedBox.shrink(),
          onTap: () {
            visited.add(key);
            path = key;
          },
        );

    Future<void> pumpShell(WidgetTester tester, {Widget? body}) async {
      visited = [];
      path = '/';
      helpCalls = 0;
      await tester.pumpWidget(FluentApp(
        home: AppShortcuts(
          destinations: () => [
            page('/'),
            page('/templates'),
            page('/addinstance'),
            page('/settings'),
          ],
          currentPath: () => path,
          onHelp: () => helpCalls++,
          child: ScaffoldPage(content: body ?? const SizedBox.shrink()),
        ),
      ));
      await tester.pump();
    }

    testWidgets('Ctrl+N adds an instance, Ctrl+, opens settings',
        (tester) async {
      await pumpShell(tester);
      await chord(tester, LogicalKeyboardKey.keyN);
      await chord(tester, LogicalKeyboardKey.comma);
      expect(visited, ['/addinstance', '/settings']);
    });

    testWidgets('Ctrl+1…9 goes to that pane entry, if there is one',
        (tester) async {
      await pumpShell(tester);
      await chord(tester, LogicalKeyboardKey.digit2);
      await chord(tester, LogicalKeyboardKey.digit1);
      await chord(tester, LogicalKeyboardKey.digit9);
      expect(visited, ['/templates', '/']);
    });

    testWidgets('Ctrl+Tab steps through the pages and wraps', (tester) async {
      await pumpShell(tester);
      Future<void> controlTab({bool shift = false}) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      await controlTab();
      expect(path, '/templates');
      await controlTab(shift: true);
      await controlTab(shift: true);
      expect(path, '/settings');
      await controlTab();
      expect(path, '/');
    });

    testWidgets('F1 opens the help', (tester) async {
      await pumpShell(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      expect(helpCalls, 1);
    });

    testWidgets('Ctrl+/ and ? show the cheat sheet, Escape closes it',
        (tester) async {
      await pumpShell(tester);
      final sheet = find.byKey(const ValueKey('test-shortcuts-dialog'));

      await chord(tester, LogicalKeyboardKey.slash);
      await settle(tester);
      expect(sheet, findsOneWidget);
      expect(find.text('keyboardshortcuts-text'), findsOneWidget);
      expect(find.text(AppKeys.rename.label), findsOneWidget);
      // Nothing behind the sheet reacts to the keys it lists.
      await chord(tester, LogicalKeyboardKey.keyN);
      expect(visited, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(sheet, findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);
      expect(sheet, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('test-shortcuts-close')));
      await settle(tester);
      expect(sheet, findsNothing);
    });

    testWidgets('typing in a text field keeps the keys', (tester) async {
      await pumpShell(tester,
          body: const TextBox(key: ValueKey('box'), autofocus: true));
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyN);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
      await settle(tester);
      expect(visited, isEmpty);
      expect(helpCalls, 0);
      expect(find.byKey(const ValueKey('test-shortcuts-dialog')), findsNothing);
    });

    testWidgets('Alt+F4 and Ctrl+W are left to the window', (tester) async {
      await pumpShell(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.f4), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

      await tester.sendKeyDownEvent(command);
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW), isFalse);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(command);
      expect(visited, isEmpty);
    });
  });

  test('labels follow the platform', () {
    if (Platform.isMacOS) {
      expect(AppKeys.terminal.label, '⌘⇧T');
      expect(AppKeys.delete.label, '⌘⌫');
    } else {
      expect(AppKeys.terminal.label, 'key-ctrl-text+key-shift-text+T');
      expect(AppKeys.delete.label, 'key-delete-text');
    }
    expect(AppKeys.rename.label, 'F2');
    expect(withShortcut('Rename', AppKeys.rename), 'Rename (F2)');
  });
}
