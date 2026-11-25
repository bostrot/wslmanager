import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'vm_backend_test.dart' show FakeBackend;

class _ListBackend extends FakeBackend {
  _ListBackend(this.names);
  List<String> names;
  int listCalls = 0;

  @override
  Future<Instances> list(bool showDocker) async {
    listCalls++;
    lastDistroList = Instances(List.of(names), []);
    return lastDistroList;
  }
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

  group('filterInstances', () {
    const names = ['Ubuntu-24.04', 'ubuntu-dev', 'Debian', 'docker-desktop'];

    test('an empty or blank query keeps every instance', () {
      expect(filterInstances(names, ''), names);
      expect(filterInstances(names, '   '), names);
    });

    test('matches a substring regardless of case and padding', () {
      expect(
          filterInstances(names, ' UBUNTU '), ['Ubuntu-24.04', 'ubuntu-dev']);
      expect(filterInstances(names, 'de'),
          ['ubuntu-dev', 'Debian', 'docker-desktop']);
    });

    test('nothing matches', () {
      expect(filterInstances(names, 'arch'), isEmpty);
    });
  });

  Future<void> drainReloadLoop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> pumpList(WidgetTester tester, VmBackend backend) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    vmBackendBuilder = () => backend;
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(content: Column(children: [DistroList(api: backend)])),
    ));
    await tester.pump();
    await tester.pump();
  }

  final filter = find.byKey(const ValueKey('test-instance-filter'));

  testWidgets('a short list shows no filter box', (tester) async {
    await pumpList(tester, _ListBackend(['alpine', 'debian']));
    expect(find.text('alpine'), findsOneWidget);
    expect(filter, findsNothing);
    await drainReloadLoop(tester);
  });

  testWidgets('typing narrows the rows and survives the 5s poll',
      (tester) async {
    final names = [for (var i = 0; i < 5; i++) 'distro-$i', 'Ubuntu-work'];
    await pumpList(tester, _ListBackend(names));
    expect(filter, findsOneWidget);

    await tester.enterText(filter, 'ubuntu');
    await tester.pump();
    expect(find.text('Ubuntu-work'), findsOneWidget);
    expect(find.text('distro-0'), findsNothing);

    // The poll rebuilds the rows; the query must still apply.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.text('Ubuntu-work'), findsOneWidget);
    expect(find.text('distro-0'), findsNothing);
    await drainReloadLoop(tester);
  });

  testWidgets('no match says so and offers to clear', (tester) async {
    final names = [for (var i = 0; i < 6; i++) 'distro-$i'];
    await pumpList(tester, _ListBackend(names));

    await tester.enterText(filter, 'zzz');
    await tester.pump();
    expect(find.byKey(const ValueKey('test-instance-filter-empty')),
        findsOneWidget);

    await tester.tap(find.text('clearfilter-text'));
    await tester.pump();
    expect(find.text('distro-0'), findsOneWidget);
    expect(find.text('distro-5'), findsOneWidget);
    await drainReloadLoop(tester);
  });

  testWidgets('escape clears the query', (tester) async {
    final names = [for (var i = 0; i < 6; i++) 'distro-$i'];
    await pumpList(tester, _ListBackend(names));

    await tester.enterText(filter, 'o-3');
    await tester.pump();
    expect(find.text('distro-0'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('distro-0'), findsOneWidget);
    await drainReloadLoop(tester);
  });

  testWidgets('the clear button empties the box', (tester) async {
    final names = [for (var i = 0; i < 6; i++) 'distro-$i'];
    await pumpList(tester, _ListBackend(names));
    final clear = find.byKey(const ValueKey('test-instance-filter-clear'));
    expect(clear, findsNothing);

    await tester.enterText(filter, 'o-3');
    await tester.pump();
    await tester.tap(clear);
    await tester.pump();
    expect(find.text('distro-0'), findsOneWidget);
    expect(clear, findsNothing);
    await drainReloadLoop(tester);
  });

  testWidgets('a row keeps its own state when filtering moves it',
      (tester) async {
    final names = [for (var i = 0; i < 6; i++) 'distro-$i'];
    await pumpList(tester, _ListBackend(names));
    final before =
        tester.state(find.byKey(const ValueKey('instance-row-distro-3')));

    await tester.enterText(filter, 'o-3');
    await tester.pump();
    // distro-3 is now the first row; it must be the same State, not the one
    // that used to belong to distro-0.
    expect(tester.state(find.byKey(const ValueKey('instance-row-distro-3'))),
        same(before));
    await drainReloadLoop(tester);
  });

  testWidgets('the box stays while a query is typed below the threshold',
      (tester) async {
    final backend = _ListBackend([for (var i = 0; i < 6; i++) 'distro-$i']);
    await pumpList(tester, backend);
    await tester.enterText(filter, 'o-1');
    await tester.pump();

    // An instance is deleted elsewhere; the list drops below six.
    backend.names = backend.names.sublist(1);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(filter, findsOneWidget);
    expect(find.text('distro-1'), findsOneWidget);
    await drainReloadLoop(tester);
  });

  group('keyboard', () {
    final command = Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;

    Future<void> pressFind(WidgetTester tester) async {
      await tester.sendKeyDownEvent(command);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(command);
      await tester.pump();
    }

    bool filterFocused(WidgetTester tester) {
      final focused = FocusManager.instance.primaryFocus?.context;
      return focused != null &&
          find
              .descendant(
                  of: filter, matching: find.byWidget(focused.widget))
              .evaluate()
              .isNotEmpty;
    }

    testWidgets('Ctrl+F opens and focuses the filter on a short list',
        (tester) async {
      await pumpList(tester, _ListBackend(['alpine', 'debian']));
      expect(filter, findsNothing);

      await pressFind(tester);
      expect(filter, findsOneWidget);
      expect(filterFocused(tester), isTrue);

      await tester.enterText(filter, 'deb');
      await tester.pump();
      expect(find.text('alpine'), findsNothing);
      expect(find.text('debian'), findsOneWidget);

      // Escape clears the query, and a box nobody asked to keep goes away.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(filter, findsNothing);
      expect(find.text('alpine'), findsOneWidget);
      await drainReloadLoop(tester);
    });

    testWidgets('Ctrl+F selects the query already typed', (tester) async {
      await pumpList(
          tester, _ListBackend([for (var i = 0; i < 6; i++) 'distro-$i']));
      await tester.enterText(filter, 'o-3');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await pressFind(tester);
      expect(filterFocused(tester), isTrue);
      final box = tester.widget<EditableText>(
          find.descendant(of: filter, matching: find.byType(EditableText)));
      expect(box.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: 3));
      await drainReloadLoop(tester);
    });

    testWidgets('F5 reloads the list without waiting for the poll',
        (tester) async {
      final backend = _ListBackend(['alpine']);
      await pumpList(tester, backend);
      final before = backend.listCalls;
      backend.names = ['alpine', 'fresh'];

      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();
      await tester.pump();
      expect(backend.listCalls, greaterThan(before));
      expect(find.text('fresh'), findsOneWidget);
      await drainReloadLoop(tester);
    });

    testWidgets('the keys leave an open dialog alone', (tester) async {
      final backend = _ListBackend(['alpine', 'debian']);
      await pumpList(tester, backend);
      final context = tester.element(find.byType(DistroList));
      showDialog<void>(
        context: context,
        builder: (_) => const ContentDialog(
          content: TextBox(key: ValueKey('dialog-box'), autofocus: true),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final before = backend.listCalls;

      await pressFind(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();
      expect(filter, findsNothing);
      expect(backend.listCalls, before);

      Navigator.of(context).pop();
      await tester.pump(const Duration(milliseconds: 300));
      await drainReloadLoop(tester);
    });

    testWidgets('another text field keeps its own Ctrl+F', (tester) async {
      final backend = _ListBackend(['alpine', 'debian']);
      vmBackendBuilder = () => backend;
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Column(children: [
            const TextBox(key: ValueKey('other-box')),
            DistroList(api: backend),
          ]),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('other-box')));
      await tester.pump();

      await pressFind(tester);
      expect(filter, findsNothing);
      await drainReloadLoop(tester);
    });
  });
}
