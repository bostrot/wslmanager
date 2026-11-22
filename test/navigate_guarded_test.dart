/// Tests for `navigateGuardedOn` (lib/nav/router.dart): a nav pane
/// destination replaces the shell page rather than stacking it. Pushing left
/// every page the user had switched away from mounted underneath the current
/// one, so each visit to Home added another eternal 5 s instance poll and the
/// app crawled after an hour of use (ai-tasks#26).
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';
import 'package:wsl2distromanager/nav/router.dart';

import 'vm_backend_test.dart' show FakeBackend;

/// Counts how often the instance list is polled — one call per live poll
/// loop per tick, so the count says how many pages are still alive.
class _CountingBackend extends FakeBackend {
  int listCalls = 0;

  @override
  Future<Instances> list(bool showDocker) async {
    listCalls++;
    final result = Instances(['alpine'], []);
    lastDistroList = result;
    return result;
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
    UnsavedChangesGuard.reset();
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
    GlobalVariable.initialSnapshot = null;
    UnsavedChangesGuard.reset();
  });

  /// The app's shape in miniature: a shell route with Home (the real
  /// DistroList and its poll), a second pane destination, and a sub-page
  /// that is pushed rather than switched to.
  GoRouter buildRouter(VmBackend backend) => GoRouter(
        routes: [
          ShellRoute(
            builder: (context, state, child) => child,
            routes: [
              GoRoute(
                path: '/',
                name: 'home',
                builder: (context, state) => ScaffoldPage(
                  content: Column(children: [DistroList(api: backend)]),
                ),
              ),
              GoRoute(
                path: '/settings',
                name: 'settings',
                builder: (context, state) =>
                    const ScaffoldPage(content: Text('settings page')),
              ),
              GoRoute(
                path: '/detail',
                name: 'detail',
                builder: (context, state) =>
                    const ScaffoldPage(content: Text('detail page')),
              ),
            ],
          ),
        ],
      );

  Future<GoRouter> pumpApp(WidgetTester tester, VmBackend backend) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    vmBackendBuilder = () => backend;
    final router = buildRouter(backend);
    addTearDown(router.dispose);
    await tester.pumpWidget(FluentApp.router(routerConfig: router));
    await tester.pump();
    await tester.pump();
    return router;
  }

  /// Dispose the tree, then let any poll loop's pending tick fire and see
  /// its dead state, ending itself — the test binding rejects a timer that
  /// is still pending when the test ends.
  Future<void> drainReloadLoop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> pollTick(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
  }

  testWidgets('switching pane destinations replaces the page, never stacks',
      (tester) async {
    final backend = _CountingBackend();
    final router = await pumpApp(tester, backend);
    expect(find.text('alpine'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await navigateGuardedOn(router, 'settings', path: '/settings');
      await tester.pumpAndSettle();
      await navigateGuardedOn(router, 'home', path: '/');
      await tester.pumpAndSettle();
    }

    expect(find.byType(DistroList, skipOffstage: false), findsOneWidget,
        reason: 'the three earlier Home pages must be gone, not covered');
    expect(router.canPop(), isFalse);

    // Only the visible page polls: one list() per tick, not one per visit.
    final before = backend.listCalls;
    await pollTick(tester);
    expect(backend.listCalls - before, 1);
    await drainReloadLoop(tester);
  });

  testWidgets('a page the user switched away from stops polling',
      (tester) async {
    final backend = _CountingBackend();
    final router = await pumpApp(tester, backend);

    await navigateGuardedOn(router, 'settings', path: '/settings');
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
    expect(find.byType(DistroList, skipOffstage: false), findsNothing);

    final before = backend.listCalls;
    await pollTick(tester);
    await pollTick(tester);
    expect(backend.listCalls, before,
        reason: 'no Home page is alive, so nothing may poll the backend');
    await drainReloadLoop(tester);
  });

  testWidgets('a pane destination also clears a pushed sub-page',
      (tester) async {
    final backend = _CountingBackend();
    final router = await pumpApp(tester, backend);

    // "Add instance" from the list, the snippet editor: real steps into
    // something, pushed so Back returns to where they came from.
    router.pushNamed('detail');
    await tester.pumpAndSettle();
    expect(find.text('detail page'), findsOneWidget);
    expect(router.canPop(), isTrue);

    await navigateGuardedOn(router, 'settings', path: '/settings');
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
    expect(find.text('detail page', skipOffstage: false), findsNothing);
    expect(find.byType(DistroList, skipOffstage: false), findsNothing);
    expect(router.canPop(), isFalse);
    await drainReloadLoop(tester);
  });

  testWidgets('a refused unsaved-changes guard keeps the current page',
      (tester) async {
    final backend = _CountingBackend();
    final router = await pumpApp(tester, backend);
    UnsavedChangesGuard.register(() async => false);

    await navigateGuardedOn(router, 'settings', path: '/settings');
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/');
    expect(find.byType(DistroList), findsOneWidget);
    await drainReloadLoop(tester);
  });

  testWidgets('the destination already on screen is a no-op and asks nothing',
      (tester) async {
    final backend = _CountingBackend();
    final router = await pumpApp(tester, backend);
    var asked = 0;
    UnsavedChangesGuard.register(() async {
      asked++;
      return true;
    });

    await navigateGuardedOn(router, 'home', path: '/');
    await tester.pumpAndSettle();

    expect(asked, 0);
    expect(find.byType(DistroList, skipOffstage: false), findsOneWidget);
    await drainReloadLoop(tester);
  });
}
