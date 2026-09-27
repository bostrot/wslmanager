/// Tests for lib/dialogs/vm_resources_dialog.dart — the live CPU and memory
/// monitor an instance row opens (bostrot/ai-tasks#109).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm_stats.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/dialogs/vm_resources_dialog.dart';

import 'fake_provisioning_backend.dart';

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

/// A service that answers from a script instead of a guest.
///
/// Each entry is either a [VmResourceUsage] to return or anything else to
/// throw. The last entry repeats, so a poll that outlives the script keeps
/// getting the same answer rather than running dry.
class _ScriptedStats extends VmStatsService {
  _ScriptedStats(List<Object> answers) : super(ScriptedBackend()) {
    _answers.addAll(answers);
  }

  final List<Object> _answers = [];
  int calls = 0;
  final List<String> forgotten = [];

  @override
  Future<VmResourceUsage> sample(String instance) async {
    calls++;
    final answer = _answers.length > 1 ? _answers.removeAt(0) : _answers.first;
    if (answer is VmResourceUsage) return answer;
    throw answer;
  }

  @override
  void forget(String instance) => forgotten.add(instance);
}

VmResourceUsage usage({
  double? instanceCpuPercent,
  double? guestCpuPercent,
  int instanceMemoryBytes = 512 * 1024 * 1024,
  int memoryUsedBytes = 2 * 1024 * 1024 * 1024,
  int memoryTotalBytes = 8 * 1024 * 1024 * 1024,
  int swapUsedBytes = 0,
  int swapTotalBytes = 0,
  int processCount = 42,
  int cpuCount = 4,
}) =>
    VmResourceUsage(
      instanceCpuPercent: instanceCpuPercent,
      guestCpuPercent: guestCpuPercent,
      instanceMemoryBytes: instanceMemoryBytes,
      memoryUsedBytes: memoryUsedBytes,
      memoryTotalBytes: memoryTotalBytes,
      swapUsedBytes: swapUsedBytes,
      swapTotalBytes: swapTotalBytes,
      processCount: processCount,
      cpuCount: cpuCount,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Long enough that the dialog's own open and close animations never reach
  /// it; a test that wants a second reading advances the clock by hand.
  const Duration interval = Duration(seconds: 10);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    plausible = _MockPlausible();
  });

  Future<void> pumpAndOpen(
    WidgetTester tester,
    _ScriptedStats service, {
    bool running = true,
    String backendId = 'wsl',
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Builder(
          builder: (context) => Button(
            child: const Text('open'),
            onPressed: () => showVmResourcesDialog(
              'ubuntu',
              running: running,
              service: service,
              backendId: backendId,
              pollInterval: interval,
              context: context,
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Let the next poll fire and its reading arrive.
  Future<void> nextPoll(WidgetTester tester) async {
    await tester.pump(interval);
    await tester.pump(Duration.zero);
  }

  /// Closes the dialog, which is also what cancels the poll.
  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
    await tester.pumpAndSettle();
  }

  String valueOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('a stopped instance is told so and is never asked',
      (tester) async {
    final service = _ScriptedStats([usage()]);
    await pumpAndOpen(tester, service, running: false);
    expect(find.byKey(const ValueKey('test-vmresources-stopped')),
        findsOneWidget);
    expect(find.text('vmresourcesnotrunning-text'), findsOneWidget);
    // Reading /proc means running a command inside the instance, and on WSL
    // that would boot the very instance the user only wanted to look at.
    expect(service.calls, 0);
    await close(tester);
  });

  testWidgets('the first reading shows the totals and waits for a rate',
      (tester) async {
    final service = _ScriptedStats([usage()]);
    await pumpAndOpen(tester, service);
    expect(service.calls, 1);
    // A percentage needs two readings; the memory figure does not.
    expect(valueOf(tester, 'test-vmresources-cpu'),
        'vmresourcesmeasuring-text');
    expect(valueOf(tester, 'test-vmresources-memory'), '512 MB');
    expect(find.byKey(const ValueKey('test-vmresources-loading')),
        findsNothing);
    // Both figures carry a graph from the first reading on.
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is UsageGraphPainter),
        findsNWidgets(2));
    await close(tester);
  });

  testWidgets('the second reading fills in the percentages', (tester) async {
    final service = _ScriptedStats([
      usage(),
      usage(instanceCpuPercent: 24.6, guestCpuPercent: 71.2),
    ]);
    await pumpAndOpen(tester, service);
    await nextPoll(tester);
    expect(service.calls, 2);
    expect(valueOf(tester, 'test-vmresources-cpu'), '25%');
    expect(find.text('vmresourcescpudetail-text'), findsOneWidget);
    expect(find.text('vmresourcesprocesses-text'), findsOneWidget);
    await close(tester);
  });

  testWidgets('both graphs are drawn against the same time axis',
      (tester) async {
    final service = _ScriptedStats([
      usage(),
      usage(instanceCpuPercent: 24.6, guestCpuPercent: 71.2),
      usage(instanceCpuPercent: 30.0, guestCpuPercent: 80.0),
    ]);
    await pumpAndOpen(tester, service);
    await nextPoll(tester);
    await nextPoll(tester);

    final painters = tester
        .widgetList<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is UsageGraphPainter))
        .map((paint) => paint.painter as UsageGraphPainter)
        .toList();
    expect(painters, hasLength(2));
    final cpu = painters.first;
    final memory = painters.last;
    // Three readings, but the first had no rate: the CPU line is one point
    // shorter and has to start one step in, or the charts would disagree
    // about when anything happened.
    expect(memory.values, hasLength(3));
    expect(memory.offset, 0);
    expect(cpu.values, [24.6, 30.0]);
    expect(cpu.offset, 1);
    expect(cpu.capacity, memory.capacity);
    await close(tester);
  });

  testWidgets('swap is reported only by a guest that has any', (tester) async {
    final service = _ScriptedStats([usage()]);
    await pumpAndOpen(tester, service);
    expect(valueOf(tester, 'test-vmresources-footer'),
        'vmresourcesprocesses-text');
    await close(tester);

    final swapping = _ScriptedStats([
      usage(swapTotalBytes: 2 * 1024 * 1024 * 1024, swapUsedBytes: 1024 * 1024)
    ]);
    await pumpAndOpen(tester, swapping);
    expect(valueOf(tester, 'test-vmresources-footer'),
        'vmresourcesprocesses-text · vmresourcesswap-text');
    await close(tester);
  });

  testWidgets('a guest that cannot be read says so instead of showing zeros',
      (tester) async {
    final service =
        _ScriptedStats([const VmStatsException('vmresourcesnoproc-text')]);
    await pumpAndOpen(tester, service);
    expect(find.byKey(const ValueKey('test-vmresources-error')),
        findsOneWidget);
    // The service's own failures carry a key the dialog translates.
    expect(find.text('vmresourcesnoproc-text'), findsOneWidget);
    expect(find.byKey(const ValueKey('test-vmresources-cpu')), findsNothing);
    await close(tester);
  });

  testWidgets('a later failure keeps the last figures and marks them stale',
      (tester) async {
    final service = _ScriptedStats([
      usage(instanceCpuPercent: 12.0, guestCpuPercent: 30.0),
      const VmStatsException('vmresourcesnoproc-text'),
    ]);
    await pumpAndOpen(tester, service);
    expect(valueOf(tester, 'test-vmresources-cpu'), '12%');
    await nextPoll(tester);
    // A busy guest that missed one poll must not blank the graph it filled.
    expect(valueOf(tester, 'test-vmresources-cpu'), '12%');
    expect(find.byKey(const ValueKey('test-vmresources-stale')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-vmresources-error')), findsNothing);
    await close(tester);
  });

  testWidgets('an instance that goes down mid-watch ends the poll',
      (tester) async {
    final service = _ScriptedStats([
      usage(instanceCpuPercent: 12.0, guestCpuPercent: 30.0),
      const VmStatsNotRunningException(),
    ]);
    await pumpAndOpen(tester, service);
    expect(valueOf(tester, 'test-vmresources-cpu'), '12%');
    await nextPoll(tester);
    // Being stopped is not a failure, and nothing may keep probing: on WSL
    // the next probe would boot the instance again.
    expect(find.byKey(const ValueKey('test-vmresources-stopped')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-vmresources-error')), findsNothing);
    expect(find.byKey(const ValueKey('test-vmresources-stale')), findsNothing);
    final after = service.calls;
    await tester.pump(interval * 3);
    expect(service.calls, after);
    await close(tester);
  });

  testWidgets('only WSL explains that the totals are shared', (tester) async {
    final shared = _ScriptedStats([usage()]);
    await pumpAndOpen(tester, shared, backendId: 'wsl');
    expect(find.byKey(const ValueKey('test-vmresources-shared-note')),
        findsOneWidget);
    await close(tester);

    // An Apple VM is a machine of its own: there is nothing to explain.
    final own = _ScriptedStats([usage()]);
    await pumpAndOpen(tester, own, backendId: 'applevirt');
    expect(find.byKey(const ValueKey('test-vmresources-shared-note')),
        findsNothing);
    await close(tester);
  });

  testWidgets('closing stops the poll and drops the baseline', (tester) async {
    final service = _ScriptedStats([usage()]);
    await pumpAndOpen(tester, service);
    await close(tester);
    expect(service.forgotten, ['ubuntu']);
    final before = service.calls;
    await tester.pump(interval * 3);
    expect(service.calls, before);
  });
}
