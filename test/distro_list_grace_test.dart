import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'vm_backend_test.dart' show FakeBackend;

/// A backend whose list() follows a script of results and failures.
class _FlakyBackend extends FakeBackend {
  _FlakyBackend(this.script);
  final List<Object> script;
  int calls = 0;

  @override
  Future<Instances> list(bool showDocker) async {
    final step = script[calls >= script.length ? script.length - 1 : calls];
    calls++;
    if (step is Instances) {
      lastDistroList = step;
      return step;
    }
    throw step as Exception;
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

  Future<void> drainReloadLoop(WidgetTester tester) async {
    // Dispose the tree, then let the poll loop's pending tick fire and
    // observe the dead state, ending itself.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> pumpList(WidgetTester tester, VmBackend backend) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    vmBackendBuilder = () => backend;
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(content: Column(children: [DistroList(api: backend)])),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('one failed poll keeps showing the last known rows',
      (tester) async {
    final backend = _FlakyBackend([
      Instances(['alpine'], []),
      Exception('helper briefly unavailable'),
      Instances(['alpine'], []),
    ]);
    await pumpList(tester, backend);
    expect(find.text('alpine'), findsOneWidget);

    // Next poll fails once — the rows must survive, no error page.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.text('alpine'), findsOneWidget);
    expect(find.textContaining('listfailed'), findsNothing);
    await drainReloadLoop(tester);
  });

  testWidgets('a persistent failure still surfaces the error view',
      (tester) async {
    final backend = _FlakyBackend([
      Instances(['alpine'], []),
      Exception('down'),
      Exception('down'),
      Exception('down'),
      Exception('down'),
    ]);
    await pumpList(tester, backend);
    expect(find.text('alpine'), findsOneWidget);

    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
    }
    expect(find.textContaining('listfailed'), findsWidgets,
        reason: 'three consecutive failures are no longer a blip');
    await drainReloadLoop(tester);
  });

  testWidgets('with no known-good list, a failure shows the error at once',
      (tester) async {
    final backend = _FlakyBackend([Exception('never worked')]);
    await pumpList(tester, backend);
    await tester.pump();
    expect(find.textContaining('listfailed'), findsWidgets);
    await drainReloadLoop(tester);
  });
}
