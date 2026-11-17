import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localization/localization.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/runtime.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/ai_workspace_screen.dart';

import 'mocks.dart';

/// The real window is 1280 wide. At the 800x600 test default the card's action
/// row overflows — and without a localization delegate the labels render as
/// raw i18n keys, which are longer still — so every card throws a layout error
/// before a single assertion runs.
const Size _kSurface = Size(1400, 1000);

/// Mounts the page with [service] behind the Providers it reads in initState.
///
/// The config service is built on the same workspace, and its schema pull is
/// never started here: the page only asks for one when the user opens the
/// configuration dialog.
Widget _page(AiWorkspaceService service) {
  return MultiProvider(
    providers: [
      Provider<AiWorkspaceService>.value(value: service),
      Provider<AiWorkspaceConfigService>.value(
        value: AiWorkspaceConfigService(workspace: service),
      ),
    ],
    child: const FluentApp(home: ScaffoldPage(content: AiWorkspacePage())),
  );
}

/// Missing until [setUp] runs — the shape of a Mac with no workspace VM.
/// [errorKey] picks which of the three provisioning states it reports.
class _GuidedFakeRuntime extends WslWorkspaceRuntime {
  _GuidedFakeRuntime({this.errorKey = 'ai-workspace-vm-missing-text'});
  final String errorKey;
  bool present = false;
  int setUpCalls = 0;

  @override
  Future<bool> exists(ExecutionBroker broker) async => present;

  @override
  Future<void> provision(ExecutionBroker broker,
      {required void Function(String key) notify}) async {
    throw Exception(errorKey);
  }

  @override
  Future<void> setUp(ExecutionBroker broker,
      {required void Function(String key) notify}) async {
    setUpCalls++;
    present = true;
  }
}

void main() {
  late TestShell testShell;
  late AiWorkspaceService service;

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
    // The first-start AI question is answered with a yes here: these tests
    // are about what happens once the features are on (bostrot/ai-tasks#98).
    AiService.setFeaturesEnabled(true);
    // Pin the WSL runtime so the service drives the injected test shell; on
    // a macOS dev host the default is the Apple runtime, which would poll a
    // real vmctl and hang.
    workspaceRuntimeBuilder = WslWorkspaceRuntime.new;
    // The page skips every WSL call for non-Pro users, so nothing would poll.
    GlobalVariable.testProEnabled = true;
    testShell = TestShell();
    service = AiWorkspaceService(
      broker: ExecutionBroker(shell: testShell),
      reachabilityChecker: (_) async => true,
    );
  });

  tearDown(() {
    workspaceRuntimeBuilder = defaultWorkspaceRuntime;
    GlobalVariable.testProEnabled = false;
    GlobalVariable.sandboxChat.value = null;
    GlobalVariable.aiPanel.value = false;
    testShell.reset();
  });

  // A container that is still migrating answers `starting`, and nothing else
  // on this page re-probes a tool once it has been checked — `_initService`
  // skips anything already `checked`, and the only other timer watches
  // installs. Without a poll the card sits on "Starting up..." with Start,
  // Stop and the dashboard all disabled forever. Measured against a real
  // Open WebUI container: `docker inspect` said `healthy` while the card
  // still read "Startet...".
  testWidgets('a tool left in `starting` is re-probed until it settles',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    testShell.stdoutData = 'ai-workspace';
    await service.ensureDistro();
    service.seedToolStates();
    for (final tool in AiWorkspaceTool.values) {
      final state = service.getState(tool)!;
      state.status = ToolStatus.stopped;
      // What a completed probe leaves behind: without both flags the page
      // either re-probes over the seeded state or spins on "checking" forever.
      state.checked = true;
      state.hasKnownStatus = true;
    }
    service.getState(AiWorkspaceTool.openWebUi)!.status = ToolStatus.starting;

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    // The migration window: the gate keeps answering `starting`.
    expect(service.getState(AiWorkspaceTool.openWebUi)?.status,
        ToolStatus.starting);

    // Migrations finish; the very next poll has to pick that up on its own,
    // with no user interaction in between.
    testShell.stdoutData = 'running';
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    expect(service.getState(AiWorkspaceTool.openWebUi)?.status,
        ToolStatus.running);
  });

  // The poll must not outlive what it is waiting for, or the page keeps
  // shelling out to WSL every ten seconds for the rest of the session.
  testWidgets('the poll stops once no tool is starting', (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    testShell.stdoutData = 'ai-workspace';
    await service.ensureDistro();
    service.seedToolStates();
    for (final tool in AiWorkspaceTool.values) {
      final state = service.getState(tool)!;
      state.status = ToolStatus.stopped;
      // What a completed probe leaves behind: without both flags the page
      // either re-probes over the seeded state or spins on "checking" forever.
      state.checked = true;
      state.hasKnownStatus = true;
    }
    service.getState(AiWorkspaceTool.openWebUi)!.status = ToolStatus.starting;

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    testShell.stdoutData = 'running';
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    final settled = testShell.allCommands.length;
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(testShell.allCommands.length, settled);
  });

  // A tool that is simply stopped must not start a timer at all.
  testWidgets('no poll runs when nothing is starting', (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    testShell.stdoutData = 'ai-workspace';
    await service.ensureDistro();
    service.seedToolStates();
    for (final tool in AiWorkspaceTool.values) {
      final state = service.getState(tool)!;
      state.status = ToolStatus.stopped;
      state.checked = true;
      state.hasKnownStatus = true;
    }

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    final settled = testShell.allCommands.length;
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();

    expect(testShell.allCommands.length, settled);
  });

  /// Puts every tool in a settled, known state so the page renders cards
  /// straight away instead of spinning on "checking".
  Future<void> seedSettled(ToolStatus status) async {
    testShell.stdoutData = 'ai-workspace';
    await service.ensureDistro();
    service.seedToolStates();
    for (final tool in AiWorkspaceTool.values) {
      final state = service.getState(tool)!;
      state.status = status;
      state.checked = true;
      state.hasKnownStatus = true;
    }
  }

  /// Runs the install of [tool] to completion, then gives the progress ticker a
  /// frame to land its own setState on.
  ///
  /// `pumpAndSettle` is unusable on this page: a status probe can land a tool
  /// back on `starting`, and that poll schedules a frame every ten seconds
  /// for as long as it runs, so nothing ever settles.
  ///
  /// The wait runs under [WidgetTester.runAsync] because cancelling a
  /// subscription of a closed StreamController never completes on the fake
  /// clock, and the streamed install cancels both of the child's pipes before
  /// it returns — on the fake clock the install simply never ends.
  Future<void> pumpInstallToEnd(
      WidgetTester tester, AiWorkspaceTool tool) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (service.isInstalling(tool) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(service.isInstalling(tool), false,
        reason: 'the install never finished');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  // A Hermes install runs for minutes (measured: 482s cold). Without the
  // streamed line under the card the user watches a bare spinner, and a
  // wedged installer looks exactly like a working one.
  testWidgets('the card shows installer output while the install runs',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.notInstalled);

    final child = ControlledProcess();
    testShell.processFactory = () => child;

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byKey(const ValueKey('test-ai-install-hermesAgent')));
    await tester.pump();
    // Two frames: one for the button press, one for the child to be spawned
    // and its pipes listened to before anything is written to them.
    await tester.pump(const Duration(milliseconds: 100));

    // Nothing printed yet: the placeholder holds the region open so it does
    // not pop into existence on the first line.
    expect(find.byKey(const ValueKey('test-ai-install-progress-hermesAgent')),
        findsOneWidget);

    child.emit('Cloning hermes-agent...\n');
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Cloning hermes-agent'), findsOneWidget);

    // The line has to keep moving with no user interaction in between — the
    // page repaints on its own tick, not on a button press.
    child.emit('Installing node dependencies...\n');
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Cloning hermes-agent'), findsNothing);
    expect(find.textContaining('Installing node dependencies'), findsOneWidget);

    child.exit(0);
    await pumpInstallToEnd(tester, AiWorkspaceTool.hermesAgent);

    // Finished: the progress region is gone and the card carries the status.
    expect(find.byKey(const ValueKey('test-ai-install-progress-hermesAgent')),
        findsNothing);
  });

  // Navigating away disposes this page; the install keeps running in the
  // service. A fresh page has to re-attach to it, progress line and all.
  testWidgets('a fresh page re-attaches to an install already in flight',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.notInstalled);

    final child = ControlledProcess();
    testShell.processFactory = () => child;

    // Started with no page mounted at all — the service owns it.
    final install = service.install(AiWorkspaceTool.hermesAgent);
    // Let the child be spawned and its pipes listened to before anything is
    // written to them.
    await tester.pump(const Duration(milliseconds: 100));
    child.emit('Downloading Chromium 184.3 MiB\n');
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('Downloading Chromium'), findsOneWidget);
    // A probe mid-install would report the tool missing and cache that over a
    // download that is still running.
    expect(service.getState(AiWorkspaceTool.hermesAgent)?.status,
        ToolStatus.notInstalled);

    child.exit(0);
    await pumpInstallToEnd(tester, AiWorkspaceTool.hermesAgent);
    expect(await tester.runAsync(() => install), true);
    expect(find.byKey(const ValueKey('test-ai-install-progress-hermesAgent')),
        findsNothing);
  });

  // A killed shell writes nothing of its own to stderr, so the last line the
  // installer managed to print is the only clue the user has about where it
  // got to. The service keeps it; the card has to keep showing it.
  testWidgets('a failed install keeps its last output on the card',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.notInstalled);

    final child = ControlledProcess();
    testShell.processFactory = () => child;

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byKey(const ValueKey('test-ai-install-hermesAgent')));
    await tester.pump();
    // Two frames: one for the button press, one for the child to be spawned
    // and its pipes listened to before anything is written to them.
    await tester.pump(const Duration(milliseconds: 100));

    child.emit('npm install --silent\n');
    await tester.pump(const Duration(seconds: 1));
    child.exit(1);
    await pumpInstallToEnd(tester, AiWorkspaceTool.hermesAgent);

    expect(service.getState(AiWorkspaceTool.hermesAgent)?.status,
        ToolStatus.error);
    expect(service.installProgress(AiWorkspaceTool.hermesAgent),
        'npm install --silent');
    expect(
        find.byKey(const ValueKey('test-ai-install-last-output-hermesAgent')),
        findsOneWidget);
  });

  // For the whole of a six-minute install the pill above the live spinner read
  // "Not Installed" — the one element on the card whose job is to say what
  // state the tool is in said the wrong thing for the entire operation
  // (audit PS-19).
  testWidgets('the badge says Installing for the length of the install',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.notInstalled);

    final child = ControlledProcess();
    testShell.processFactory = () => child;

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    // Every card starts out saying the same thing.
    expect(find.text('notinstalled-text'),
        findsNWidgets(AiWorkspaceTool.values.length));

    await tester.tap(find.byKey(const ValueKey('test-ai-install-hermesAgent')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('test-ai-installing-badge-hermesAgent')),
        findsOneWidget);
    expect(find.text('installing-text'), findsOneWidget);
    // The card being installed no longer claims to be uninstalled; the
    // others still do, correctly.
    expect(find.text('notinstalled-text'),
        findsNWidgets(AiWorkspaceTool.values.length - 1));

    child.emit('Cloning hermes-agent...\n');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('test-ai-installing-badge-hermesAgent')),
        findsOneWidget);

    child.exit(0);
    await pumpInstallToEnd(tester, AiWorkspaceTool.hermesAgent);

    expect(find.byKey(const ValueKey('test-ai-installing-badge-hermesAgent')),
        findsNothing);
  });

  // Every other destructive confirmation in the app submits in red; this one
  // used the accent-blue primary, so the dialog that removes a tool looked
  // less dangerous than the one that saves a template (audit PS-27). The name
  // also floated on a bare line above a sentence calling it "this tool"
  // (PS-28).
  testWidgets('the uninstall confirmation is red and names the tool',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.stopped);

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    await tester
        .tap(find.byKey(const ValueKey('test-ai-uninstall-hermesAgent')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('test-ai-uninstall-confirm')));
    expect(confirm.style?.backgroundColor?.resolve({}), Colors.red);

    // One sentence, with the tool in it: the dialog no longer carries a
    // stray caption line of its own.
    expect(find.text('ai-workspace-uninstall-confirm'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(ContentDialog), matching: find.text('Hermes Agent')),
        findsNothing);

    await tester.tap(find.byKey(const ValueKey('test-ai-uninstall-cancel')));
    await tester.pump(const Duration(milliseconds: 100));
  });

  // One primary action per state (FIX-14). The old row kept every button
  // visible with the wrong ones disabled: an installed tool wore a dead
  // "Installed" button (PS-22), a running tool's only filled button was Stop
  // (PS-23), and a tool stuck in `starting` could only be uninstalled
  // (PS-16).
  testWidgets('a stopped tool offers Start, not a dead Installed button',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.stopped);

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('test-ai-start-hermesAgent')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-install-hermesAgent')),
        findsNothing,
        reason: 'an installed tool must not carry an Install/Installed button');
    expect(find.text('installed-text'), findsNothing);
  });

  // The settings live in the tool's own config file, which only exists once
  // the tool does — an uninstalled card has nothing to read and no schema to
  // read it with (bostrot/ai-tasks#72).
  testWidgets('Configure appears once a tool is installed', (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.stopped);
    service.getState(AiWorkspaceTool.openCode)!.status =
        ToolStatus.notInstalled;

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('test-ai-configure-hermesAgent')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-configure-openCode')),
        findsNothing);
  });

  testWidgets('on a running tool the dashboard is primary and Stop is not',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.running);

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    // Open Dashboard renders filled (the accent primary); Stop plain.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('test-ai-open-dashboard-hermesAgent')),
            matching: find.byType(FilledButton)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('test-ai-stop-hermesAgent')),
            matching: find.byType(FilledButton)),
        findsNothing);
  });

  testWidgets('Stop stays live on a tool stuck in Starting up', (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.starting);

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    final stop = tester.widget<BusyButton>(
        find.byKey(const ValueKey('test-ai-stop-hermesAgent')));
    expect(stop.onPressed, isNotNull,
        reason: 'Uninstall must not be the only way out of a stuck start');
  });

  // With the assistant panel open the OpenCode card is about 440 px wide,
  // and a running, configurable tool carries four buttons. As one plain row
  // they ran 68 px past the card edge (issue #82); the state actions now
  // wrap while Uninstall keeps the right edge.
  //
  // Real labels for this one: raw i18n keys are so much longer that the page
  // title alone overflows any width narrow enough to make the row wrap.
  testWidgets('a running card wraps its actions instead of overflowing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(610, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    MapLocalization.delegate.translations = {
      const Locale('en'): {
        'ai-workspace-title': 'AI Workspace',
        'ai-workspace-installed-at-text': 'Installed: %s',
        'running-text': 'Running',
        'ai-workspace-open-dashboard-text': 'Open dashboard',
        'stop-text': 'Stop',
        'ai-workspace-configure-text': 'Configure',
        'uninstall-text': 'Uninstall',
      },
    };
    addTearDown(() async {
      // Loading an empty map clears the sentences the delegate installed,
      // so the other tests keep rendering raw keys as they always have.
      MapLocalization.delegate.translations = {};
      await MapLocalization.delegate.load(const Locale('en'));
    });
    await seedSettled(ToolStatus.running);

    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<AiWorkspaceService>.value(value: service),
        Provider<AiWorkspaceConfigService>.value(
          value: AiWorkspaceConfigService(workspace: service),
        ),
      ],
      child: FluentApp(
        locale: const Locale('en'),
        localizationsDelegates: [MapLocalization.delegate],
        home: const ScaffoldPage(content: AiWorkspacePage()),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull,
        reason: 'the action row must not overflow at a narrow width');

    final dashboard =
        find.byKey(const ValueKey('test-ai-open-dashboard-openCode'));
    final configure = find.byKey(const ValueKey('test-ai-configure-openCode'));
    final uninstall = find.byKey(const ValueKey('test-ai-uninstall-openCode'));
    expect(dashboard, findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-stop-openCode')), findsOneWidget);
    expect(configure, findsOneWidget);
    expect(uninstall, findsOneWidget);

    // Something moved to a second line rather than being squeezed...
    expect(tester.getTopLeft(configure).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(dashboard).dy));
    // ...and every button, Uninstall included, ends inside the card.
    final card = find.ancestor(of: uninstall, matching: find.byType(Card));
    final cardRight = tester.getBottomRight(card.first).dx;
    for (final button in [dashboard, configure, uninstall]) {
      expect(tester.getBottomRight(button).dx, lessThanOrEqualTo(cardRight));
    }
  });

  testWidgets('a missing workspace VM offers guided setup, not an error',
      (tester) async {
    tester.view.physicalSize = _kSurface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final runtime = _GuidedFakeRuntime();
    final guided = AiWorkspaceService(
      broker: ExecutionBroker(shell: testShell),
      reachabilityChecker: (_) async => true,
      runtime: runtime,
    );

    await tester.pumpWidget(_page(guided));
    await tester.pumpAndSettle();

    // The provisioning case renders the setup card, not the error view.
    final setup = find.byKey(const ValueKey('test-workspace-setup'));
    expect(setup, findsOneWidget);
    expect(find.text('retry-text'.i18n()), findsNothing);

    await tester.tap(setup);
    await tester.pumpAndSettle();

    expect(runtime.setUpCalls, 1);
    // Setup succeeded, so the page moved on to the normal tool grid.
    expect(find.byKey(const ValueKey('test-workspace-setup')), findsNothing);
  });

  // Automatic setup off in Settings: a deleted 'ai-workspace' distro stays
  // deleted, and the page asks before creating it (bostrot/wsl2-distro-manager#321).
  testWidgets('a deleted distro with automatic setup off offers to set it up',
      (tester) async {
    tester.view.physicalSize = _kSurface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await AiWorkspaceService.setAutoProvision(false);
    final runtime = _GuidedFakeRuntime(errorKey: 'must not be provisioned');
    final guided = AiWorkspaceService(
      broker: ExecutionBroker(shell: testShell),
      reachabilityChecker: (_) async => true,
      runtime: runtime,
    );

    await tester.pumpWidget(_page(guided));
    await tester.pumpAndSettle();

    expect(find.text(AiWorkspaceService.notProvisionedKey.i18n()),
        findsOneWidget);
    expect(find.text('ai-workspace-setup-now-btn'.i18n()), findsOneWidget);
    expect(find.text('retry-text'.i18n()), findsNothing);
    expect(runtime.setUpCalls, 0);

    await tester.tap(find.byKey(const ValueKey('test-workspace-setup')));
    await tester.pumpAndSettle();

    expect(runtime.setUpCalls, 1);
    expect(find.byKey(const ValueKey('test-workspace-setup')), findsNothing);
  });

  testWidgets('a running VM that does not answer offers repair, not install',
      (tester) async {
    // The Home screen listed 'ai-workspace' as running with an address while
    // this page said it had to be set up: the card told the user Debian
    // would be downloaded and a VM created. It must say what is wrong.
    tester.view.physicalSize = _kSurface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final runtime =
        _GuidedFakeRuntime(errorKey: 'ai-workspace-vm-unreachable-text');
    final guided = AiWorkspaceService(
      broker: ExecutionBroker(shell: testShell),
      reachabilityChecker: (_) async => true,
      runtime: runtime,
    );

    await tester.pumpWidget(_page(guided));
    await tester.pumpAndSettle();

    expect(find.text('ai-workspace-repair-text'.i18n()), findsOneWidget);
    expect(find.text('ai-workspace-repair-btn'.i18n()), findsOneWidget);
    expect(find.text('ai-workspace-setup-text'.i18n()), findsNothing);
    expect(find.text('ai-workspace-setup-btn'.i18n()), findsNothing);
    expect(find.text('retry-text'.i18n()), findsNothing);

    // The button still runs the guided setup, which is what repairs it.
    await tester.tap(find.byKey(const ValueKey('test-workspace-setup')));
    await tester.pumpAndSettle();
    expect(runtime.setUpCalls, 1);
    expect(find.byKey(const ValueKey('test-workspace-setup')), findsNothing);
  });

  testWidgets('a stopped VM offers to start it, not to create it',
      (tester) async {
    tester.view.physicalSize = _kSurface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final runtime =
        _GuidedFakeRuntime(errorKey: 'ai-workspace-vm-stopped-text');
    final guided = AiWorkspaceService(
      broker: ExecutionBroker(shell: testShell),
      reachabilityChecker: (_) async => true,
      runtime: runtime,
    );

    await tester.pumpWidget(_page(guided));
    await tester.pumpAndSettle();

    expect(find.text('ai-workspace-start-vm-text'.i18n()), findsOneWidget);
    expect(find.text('ai-workspace-start-vm-btn'.i18n()), findsOneWidget);
    expect(find.text('ai-workspace-setup-text'.i18n()), findsNothing);
    expect(find.text('ai-workspace-repair-btn'.i18n()), findsNothing);
  });

  // A sandbox is its own distro; the workspace VM (or the 'ai-workspace'
  // distro on Windows) is only where the tool cards run. The page used to
  // swap itself for a full-screen setup view whenever that environment was
  // missing, so the sandboxes disappeared with it (bostrot/ai-tasks#30).
  testWidgets('sandboxes stay usable while the workspace VM is missing',
      (tester) async {
    tester.view.physicalSize = _kSurface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await prefs.setStringList('SandboxDistros', ['wslm-sandbox-play']);
    final guided = AiWorkspaceService(
      broker: ExecutionBroker(shell: testShell),
      reachabilityChecker: (_) async => true,
      runtime: _GuidedFakeRuntime(),
    );

    await tester.pumpWidget(_page(guided));
    await tester.pumpAndSettle();

    // The setup offer is still there — as a card, not the whole page.
    expect(find.byKey(const ValueKey('test-workspace-setup')), findsOneWidget);
    expect(find.text('sandbox-title-text'.i18n()), findsOneWidget);
    expect(find.byKey(const ValueKey('test-sandbox-add')), findsOneWidget);
    final openChat =
        find.byKey(const ValueKey('test-sandbox-chat-wslm-sandbox-play'));
    expect(openChat, findsOneWidget);

    // Opening the sandbox chat docks it without touching the environment.
    await tester.ensureVisible(openChat);
    await tester.tap(openChat);
    // Past the HoverButton's 100 ms tap timer, or it is still pending when
    // the tree is torn down.
    await tester.pump(const Duration(milliseconds: 200));
    expect(GlobalVariable.sandboxChat.value, 'wslm-sandbox-play');
    expect(GlobalVariable.aiPanel.value, isTrue);
  });

  // The Windows shape of the same problem: the 'ai-workspace' distro could
  // not be created, which is a plain error rather than a guided-setup case.
  testWidgets('sandboxes stay usable when the environment check fails',
      (tester) async {
    tester.view.physicalSize = _kSurface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final broken = AiWorkspaceService(
      broker: ExecutionBroker(shell: testShell),
      reachabilityChecker: (_) async => true,
      runtime: _GuidedFakeRuntime(
          errorKey: 'Failed to create the AI workspace distro: no space'),
    );

    await tester.pumpWidget(_page(broken));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-workspace-error-card')),
        findsOneWidget);
    expect(find.text('retry-text'.i18n()), findsOneWidget);
    expect(find.byKey(const ValueKey('test-workspace-setup')), findsNothing);
    // No tool card renders without an environment to run it in...
    expect(find.byKey(const ValueKey('test-ai-install-hermesAgent')),
        findsNothing);
    // ...but the sandbox section does.
    expect(find.byKey(const ValueKey('test-sandbox-add')), findsOneWidget);
    expect(find.text('sandbox-none-text'.i18n()), findsOneWidget);
  });

  // The Pro gate is the one that still covers sandboxes: SandboxChat refuses
  // to send without a licence, so the page must not offer to create one.
  testWidgets('the paywall still hides the sandbox section', (tester) async {
    tester.view.physicalSize = _kSurface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    GlobalVariable.testProEnabled = false;
    await prefs.setStringList('SandboxDistros', ['wslm-sandbox-play']);

    await tester.pumpWidget(_page(service));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-ai-workspace-upgrade')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-sandbox-add')), findsNothing);
    expect(find.byKey(const ValueKey('test-sandbox-chat-wslm-sandbox-play')),
        findsNothing);
  });
  // The assistant's endpoint and model (bostrot/ai-tasks#81) live in a row
  // of their own under the tool cards, and the row says what is set so the
  // question "which model are these on?" needs no dialog.
  testWidgets(
      "the shared settings card names the assistant's model and opens the dialog",
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await seedSettled(ToolStatus.stopped);
    AiService()
      ..setByokBaseUrl('https://llm.example.com/v1')
      ..setByokModel('gpt-4.1')
      ..setByokApiKey('sk-byok');

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('test-workspace-shared-card')),
        findsOneWidget);
    expect(
        find.text('ai-workspace-shared-current-text'
            .i18n(['gpt-4.1', 'https://llm.example.com/v1'])),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('test-workspace-shared')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final endpoint = tester
        .widget<Text>(find.byKey(const ValueKey('test-ai-shared-endpoint')));
    expect(endpoint.data, 'https://llm.example.com/v1');
    expect(find.text('sk-byok'), findsNothing,
        reason: 'the key is shown nowhere but the field that edits it');
  });

  // The page is the other place (besides startup) that provisions the
  // workspace distro. With AI switched off in Settings it must say where the
  // switch is and never run a single command (bostrot/ai-tasks#85).
  testWidgets('AI switched off shows the notice and never touches WSL',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AiService.setFeaturesEnabled(false);
    addTearDown(() => AiService.setFeaturesEnabled(true));

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('ai-disabled-text'), findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-workspace-open-settings')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-workspace-upgrade')),
        findsNothing, reason: 'off is not the same as unpaid');
    expect(find.byKey(const ValueKey('test-ai-workspace-beta-badge')),
        findsNothing);
    expect(testShell.allCommands, isEmpty,
        reason: 'no probe, no provisioning while AI is off');
  });

  testWidgets('a lapsed licence with AI off sees the paywall, not the switch',
      (tester) async {
    // The switch is only offered to Pro, so the notice pointing at it must
    // never win over the upgrade prompt.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    GlobalVariable.testProEnabled = false;
    AiService.setFeaturesEnabled(false);
    addTearDown(() => AiService.setFeaturesEnabled(true));

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('test-ai-workspace-upgrade')),
        findsOneWidget);
    expect(find.text('ai-disabled-text'), findsNothing);
    expect(testShell.allCommands, isEmpty);
  });

  testWidgets('switched back on while mounted, the page starts probing',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AiService.setFeaturesEnabled(false);
    addTearDown(() => AiService.setFeaturesEnabled(true));
    testShell.stdoutData = 'ai-workspace';

    await tester.pumpWidget(_page(service));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('ai-disabled-text'), findsOneWidget);
    expect(testShell.allCommands, isEmpty);

    AiService.setFeaturesEnabled(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('ai-disabled-text'), findsNothing);
    expect(testShell.allCommands, isNotEmpty,
        reason: 'the probe that initState skipped runs now');
  });
}
