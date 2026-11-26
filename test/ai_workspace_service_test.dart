import 'dart:async' show Timer;
import 'dart:io' show Process, ProcessException, ProcessStartMode, Socket;

import 'package:flutter_test/flutter_test.dart';
import 'package:localization/localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_workspace/runtime.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/execution/models.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

/// A real bash for the probe-script tests below, or null when none is
/// installed on this machine.
///
/// The status probes are bash *programs* assembled from string fragments, and
/// every status bug this file guards against was a defect in that program
/// rather than in the Dart around it: `[ -d "~/.hermes" ]` never matched
/// because `~` does not expand inside double quotes, and `grep -q 18789` also
/// matched `:187890`. A mock shell handing back a canned `running` cannot see
/// either. Prefers Git Bash, but WSL's `bash.exe` works too — the scripts are
/// POSIX-only and reference no host paths.
String? _locateBash() {
  const candidates = [
    r'C:\Program Files\Git\bin\bash.exe',
    r'C:\Program Files (x86)\Git\bin\bash.exe',
    'bash',
  ];
  for (final candidate in candidates) {
    try {
      if (Process.runSync(candidate, ['-c', 'echo ok']).exitCode == 0) {
        return candidate;
      }
    } catch (_) {
      // Not on this machine — try the next candidate.
    }
  }
  return null;
}

final String? _bash = _locateBash();

/// Runs [script] — the exact string the service sends into the distro — under
/// a real bash, with [prelude]'s shell functions standing in for the distro's
/// commands. Functions take precedence over `PATH` lookups, so no temporary
/// directory or `PATH` juggling is needed.
Future<String> _runProbeScript(String prelude, String script) async {
  final result = await Process.run(_bash!, ['-c', '$prelude$script']);
  return (result.stdout as String).trim();
}

/// True when something on this machine really is listening on [port].
///
/// The gateway probe's `/dev/tcp` fallback makes a genuine connection attempt,
/// so a "nothing is listening" case cannot be asserted while a real service
/// holds the port.
Future<bool> _hostPortIsOpen(int port) async {
  try {
    final socket = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(milliseconds: 200));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// A runtime shaped like the macOS backend: the workspace lives in its own VM
/// and shares no loopback with the machine running the app, so every port is
/// reached through a forward. Built on the WSL plumbing so [TestShell] still
/// sees the commands it understands — what is under test here is the
/// forwarding, not how the script gets in.
class _RemoteGuestRuntime extends WslWorkspaceRuntime {
  @override
  bool get sharesLoopback => false;

  @override
  String get hostName => 'macOS';

  @override
  ExecutionRequest portForward({
    required int remotePort,
    required int localPort,
  }) =>
      ExecutionRequest(command: 'vmctl', arguments: [
        'forward',
        '--port',
        '$remotePort',
        '--local-port',
        '$localPort',
      ]);
}

/// [TestShell], except that a `forward` gets a child that stays up until the
/// test ends it, the way `vmctl forward` does. Everything else answers as
/// usual.
class _ForwardingShell extends TestShell {
  final List<ControlledProcess> forwards = [];
  final List<List<String>> forwardCommands = [];

  /// Makes starting a forward throw, as a missing helper binary would.
  bool refuseForward = false;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    ProcessStartMode mode = ProcessStartMode.inheritStdio,
    bool runInShell = false,
  }) async {
    if (!arguments.contains('forward')) {
      return super.start(executable, arguments,
          workingDirectory: workingDirectory,
          environment: environment,
          includeParentEnvironment: includeParentEnvironment,
          mode: mode,
          runInShell: runInShell);
    }
    if (refuseForward) {
      throw ProcessException(executable, arguments, 'No such file');
    }
    forwardCommands.add([executable, ...arguments]);
    final process = ControlledProcess();
    forwards.add(process);
    return process;
  }
}

void main() {
  group('AiWorkspaceService', () {
    late TestShell testShell;
    late ExecutionBroker broker;
    late AiWorkspaceService service;
    // These tests exercise the WSL runtime specifically; pin it so they
    // don't take the Apple path on a macOS dev host.
    setUp(() => workspaceRuntimeBuilder = WslWorkspaceRuntime.new);
    tearDown(() => workspaceRuntimeBuilder = defaultWorkspaceRuntime);
    // Recorded rather than swallowed: the toast is the loudest thing on the
    // screen, so which one a lifecycle call raises is behaviour worth testing.
    final notifications = <String>[];

    setUpAll(() {
      Notify();
      Notify.message = (msg,
          {duration,
           severity = InfoBarSeverity.info,
          loading = false,
          useWidget = false,
          leadingIcon = true,
          dynamic widget}) {
        notifications.add(msg);
      };
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
      // Default to "always reachable" so getDashboardUrl tests don't hit a
      // real HTTP stack — individual tests override this where they
      // specifically want to exercise unreachable/timeout behavior.
      service = AiWorkspaceService(
        broker: broker,
        reachabilityChecker: (_) async => true,
      );
    });

    tearDown(() {
      testShell.reset();
      notifications.clear();
    });

    group('ensureDistro', () {
      test('marks distro ready when it already exists', () async {
        // wsl --list --quiet returns the ai-workspace distro name
        testShell.stdoutData = 'Alpine\nai-workspace\nUbuntu';
        await service.ensureDistro();

        expect(testShell.lastCommand, ['wsl', '--list', '--quiet']);
      });

      test('attempts to install Ubuntu when distro missing', () async {
        // wsl --list --quiet returns no ai-workspace
        testShell.stdoutData = 'Alpine\nUbuntu';
        await service.ensureDistro();

        // Should have tried to install on the second wsl --install call
        expect(
          testShell.allCommands.any((cmd) => cmd.contains('--install')),
          true,
          reason: 'Should attempt to install Ubuntu',
        );
      });

      // Deleting the distro used to be undone on the next start
      // (bostrot/wsl2-distro-manager#321).
      test('with automatic setup off, a missing distro is not recreated',
          () async {
        await AiWorkspaceService.setAutoProvision(false);
        testShell.stdoutData = 'Alpine\nUbuntu';

        await expectLater(
          service.ensureDistro(),
          throwsA(predicate((e) =>
              e.toString().contains(AiWorkspaceService.notProvisionedKey))),
        );
        expect(
          testShell.allCommands.any((cmd) => cmd.contains('--install')),
          false,
        );
      });

      test('with automatic setup off, an existing distro is still used',
          () async {
        await AiWorkspaceService.setAutoProvision(false);
        testShell.stdoutData = 'ai-workspace';

        await service.ensureDistro();
        expect(testShell.lastCommand, ['wsl', '--list', '--quiet']);
      });

      test('with automatic setup off, the explicit setup still creates it',
          () async {
        await AiWorkspaceService.setAutoProvision(false);
        testShell.stdoutData = 'Alpine\nUbuntu';

        await service.setUpEnvironment();
        expect(
          testShell.allCommands.any((cmd) => cmd.contains('--install')),
          true,
        );
        // Ready now, so the next call neither probes nor throws.
        testShell.allCommands.clear();
        await service.ensureDistro();
        expect(testShell.allCommands, isEmpty);
      });

      test('the startup probe stops quietly when setup is off and missing',
          () async {
        await AiWorkspaceService.setAutoProvision(false);
        testShell.stdoutData = 'Alpine\nUbuntu';

        await service.ensureInitialized();
        // Only the distro list ran: no install, no per-tool probe.
        expect(testShell.allCommands, [
          ['wsl', '--list', '--quiet']
        ]);
        expect(service.toolStates.length, AiWorkspaceTool.values.length);
      });

      test('automatic setup defaults to on', () {
        expect(AiWorkspaceService.autoProvision, isTrue);
      });

      test('a runtime that cannot provision keeps its own guidance', () async {
        await AiWorkspaceService.setAutoProvision(false);
        final vmLike = AiWorkspaceService(
          broker: broker,
          reachabilityChecker: (_) async => true,
          runtime: _GuidanceOnlyRuntime(),
        );

        await expectLater(
          vmLike.ensureDistro(),
          throwsA(predicate((e) =>
              e.toString().contains('ai-workspace-vm-missing-text'))),
        );
      });
    });

    group('init', () {
      test('initializes all tool states and probes status', () async {
        // Distro check succeeds immediately (first call)
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        expect(service.toolStates.length, AiWorkspaceTool.values.length);
        for (final tool in AiWorkspaceTool.values) {
          expect(service.getState(tool), isNotNull);
        }
      });

      test('probes every tool with one wsl call each, not two', () async {
        // 1 distro list check + 1 status call per tool, down from up to
        // 1 + 2 per tool before the status+existence checks were combined
        // into a single shell invocation. Counted off the enum so adding a
        // tool does not silently relax the assertion.
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        expect(testShell.allCommands.length,
            1 + AiWorkspaceTool.values.length);
      });
    });

    group('ensureInitialized', () {
      // Regression: the AI Workspace screen used to construct its own
      // AiWorkspaceService and do these checks only once the user navigated
      // there. Now app startup kicks this off in the background via a
      // shared instance, so the screen can skip straight to already-known
      // state — that only works if repeated calls don't redo the work.
      test('seeds state, ensures the distro, and checks every tool',
          () async {
        testShell.stdoutData = 'ai-workspace';

        await service.ensureInitialized();

        expect(service.toolStates.length, AiWorkspaceTool.values.length);
        for (final tool in AiWorkspaceTool.values) {
          expect(service.getState(tool)?.checked, true);
        }
      });

      test('is memoized — a second call does not repeat the WSL round trips',
          () async {
        testShell.stdoutData = 'ai-workspace';

        await service.ensureInitialized();
        final commandCountAfterFirstCall = testShell.allCommands.length;
        await service.ensureInitialized();

        expect(testShell.allCommands.length, commandCountAfterFirstCall);
      });

      test('a caller that awaits it while already in flight joins the same '
          'work instead of starting a duplicate', () async {
        testShell.stdoutData = 'ai-workspace';
        testShell.artificialDelay = const Duration(milliseconds: 50);

        final first = service.ensureInitialized();
        final second = service.ensureInitialized();
        await Future.wait([first, second]);

        // 1 distro list check + 1 status call per tool, exactly as a single
        // caller would produce — not doubled.
        expect(testShell.allCommands.length,
            1 + AiWorkspaceTool.values.length);
      });
    });

    group('persisted status cache', () {
      test('seedToolStates() has nothing to show before any check has ever '
          'run', () {
        service.seedToolStates();

        for (final tool in AiWorkspaceTool.values) {
          expect(service.getState(tool)?.status, ToolStatus.notInstalled);
          expect(service.getState(tool)?.hasKnownStatus, false);
        }
      });

      test('a confirmed refreshStatus() result is cached for the next '
          'AiWorkspaceService instance (simulating an app restart)',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        // A brand new instance — same prefs, no shared in-memory state —
        // stands in for the app being relaunched.
        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();

        final state = restarted.getState(AiWorkspaceTool.openWebUi)!;
        expect(state.status, ToolStatus.running);
        expect(state.hasKnownStatus, true);
        // Not checked yet *this session* — a live refresh is still owed,
        // even though there's already something real to show.
        expect(state.checked, false);
      });

      test('a cached tool still gets a real background refresh, it just '
          "doesn't need to block the UI on it first", () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();
        expect(restarted.getState(AiWorkspaceTool.hermesAgent)?.checked, false);

        await restarted.ensureInitialized();

        expect(restarted.getState(AiWorkspaceTool.hermesAgent)?.checked, true);
      });

      test('a shell-level failure does not overwrite good cached data',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        // Simulate a transient WSL hiccup on the next check. (ExecutionBroker
        // itself never lets this propagate as a raw exception — it always
        // converts a shell-level failure into a failed ExecutionResult — so
        // this exercises the same "not a confirmed signal" branch as a
        // plain non-zero exit code, just via a different trigger.)
        testShell.throwOnRun = true;
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        // In-memory state for *this* session reflects the failed attempt...
        expect(
          service.getState(AiWorkspaceTool.openWebUi)?.status,
          ToolStatus.error,
        );
        // ...but the cache a future launch would read from still has the
        // last genuinely confirmed answer, not the transient failure.
        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();
        expect(
          restarted.getState(AiWorkspaceTool.openWebUi)?.status,
          ToolStatus.running,
        );
      });

      test('a generic (non-distro-missing) command failure does not '
          'overwrite good cached data', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        testShell.exitCode = 1;
        testShell.stderrData = 'some transient docker error';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();
        expect(
          restarted.getState(AiWorkspaceTool.openWebUi)?.status,
          ToolStatus.running,
        );
      });

      test('install() success is cached immediately, without waiting for a '
          'follow-up refreshStatus()', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.hermesAgent);

        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();
        expect(
          restarted.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.stopped,
        );
      });

      test('start() success is cached', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        service.getState(AiWorkspaceTool.hermesAgent)!.status =
            ToolStatus.stopped;

        testShell.exitCode = 0;
        await service.start(AiWorkspaceTool.hermesAgent);

        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();
        expect(
          restarted.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.running,
        );
      });

      test('stop() success is cached', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        service.getState(AiWorkspaceTool.hermesAgent)!.status =
            ToolStatus.running;

        testShell.exitCode = 0;
        await service.stop(AiWorkspaceTool.hermesAgent);

        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();
        expect(
          restarted.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.stopped,
        );
      });
    });

    group('install', () {
      test('installs hermes agent successfully', () async {
        // First call: ensureDistro list check. Tool states init via init().
        testShell.stdoutData = 'ai-workspace';
        await service.init(); // initializes tool states + consumes distro check

        // Now install should work — the wsl command for install goes through broker
        testShell.exitCode = 0;
        final result = await service.install(AiWorkspaceTool.hermesAgent);

        expect(result, true);
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.stopped,
        );
      });

      test('returns false and sets error on install failure', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stderrData = 'curl failed';

        final result = await service.install(AiWorkspaceTool.openClaw);

        expect(result, false);
        expect(
          service.getState(AiWorkspaceTool.openClaw)?.status,
          ToolStatus.error,
        );
        expect(
          service.getState(AiWorkspaceTool.openClaw)?.errorMessage,
          contains('curl failed'),
        );
      });

      test(
          'a failed install keeps its error and message across a background '
          'refresh', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stderrData = 'curl failed';
        await service.install(AiWorkspaceTool.openClaw);

        // The probe that follows an install would otherwise report a bare
        // "missing" and wipe the only explanation the user ever gets.
        testShell.exitCode = 0;
        testShell.stderrData = '';
        testShell.stdoutData = 'missing';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        final state = service.getState(AiWorkspaceTool.openClaw);
        expect(state?.status, ToolStatus.error);
        expect(state?.errorMessage, contains('curl failed'));
        // The card still has to stop showing a spinner.
        expect(state?.checked, true);
        expect(state?.hasKnownStatus, true);
      });

      test(
          'a sticky failure still leaves the tool installable, so Retry '
          'works', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stderrData = 'curl failed';
        await service.install(AiWorkspaceTool.openClaw);
        testShell.stdoutData = 'missing';
        await service.refreshStatus(AiWorkspaceTool.openClaw);
        expect(service.getState(AiWorkspaceTool.openClaw)?.status,
            ToolStatus.error);

        // Retry is the same install() call the UI's "Retry" button makes.
        testShell.exitCode = 0;
        testShell.stderrData = '';
        testShell.stdoutData = '';
        final retried = await service.install(AiWorkspaceTool.openClaw);

        expect(retried, true);
        final state = service.getState(AiWorkspaceTool.openClaw);
        expect(state?.status, ToolStatus.stopped);
        expect(state?.errorMessage, isNull);
        expect(state?.errorSticky, false);
      });

      test('clearError() releases the tool back to the status probe', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stderrData = 'curl failed';
        await service.install(AiWorkspaceTool.openClaw);

        service.clearError(AiWorkspaceTool.openClaw);
        expect(
            service.getState(AiWorkspaceTool.openClaw)?.errorMessage, isNull);

        testShell.exitCode = 0;
        testShell.stderrData = '';
        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        expect(service.getState(AiWorkspaceTool.openClaw)?.status,
            ToolStatus.stopped);
      });

      test('a failed start is sticky too', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        service.getState(AiWorkspaceTool.hermesAgent)?.status =
            ToolStatus.stopped;

        testShell.exitCode = 1;
        testShell.stderrData = 'gateway never bound';
        await service.start(AiWorkspaceTool.hermesAgent);

        testShell.exitCode = 0;
        testShell.stderrData = '';
        testShell.stdoutData = 'missing';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        final state = service.getState(AiWorkspaceTool.hermesAgent);
        expect(state?.status, ToolStatus.error);
        expect(state?.errorMessage, contains('gateway never bound'));
      });

      test(
          'a transient probe failure is not sticky — the next probe still '
          'corrects it', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stderrData = 'some transient docker error';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);
        expect(service.getState(AiWorkspaceTool.openWebUi)?.status,
            ToolStatus.error);

        testShell.exitCode = 0;
        testShell.stderrData = '';
        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(service.getState(AiWorkspaceTool.openWebUi)?.status,
            ToolStatus.running);
      });

      test('installing Open WebUI prepares docker before pulling the image',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        final result = await service.install(AiWorkspaceTool.openWebUi);

        expect(result, true);
        // Docker setup command must run before the docker pull/run command.
        final dockerSetupIndex = testShell.allCommands
            .indexWhere((cmd) => cmd.any((a) => a.contains('docker.io')));
        final dockerPullIndex = testShell.allCommands
            .indexWhere((cmd) => cmd.any((a) => a.contains('docker pull')));
        expect(dockerSetupIndex, isNot(-1));
        expect(dockerPullIndex, isNot(-1));
        expect(dockerSetupIndex, lessThan(dockerPullIndex));
      });

      test('does not attempt docker setup for non-docker tools', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.hermesAgent);

        expect(
          testShell.allCommands.any((cmd) => cmd.any((a) => a.contains('docker.io'))),
          false,
        );
      });

      test('all commands run as root in the dedicated distro', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.hermesAgent);

        expect(
          testShell.allCommands.where((cmd) => cmd.contains('-d')).every(
                (cmd) => cmd.contains('-u') && cmd.contains('root'),
              ),
          true,
        );
      });

      // Regression: get.hermes-agent.dev and install.openclaw.ai never
      // resolved to anything — they were placeholder URLs. Guard the real,
      // verified install endpoints so a future edit can't silently
      // reintroduce a dead domain.
      test('hermes agent installs from the real nousresearch endpoint',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.hermesAgent);

        expect(
          testShell.lastCommand
              .any((a) => a.contains('hermes-agent.nousresearch.com')),
          true,
        );
        expect(
          testShell.lastCommand.any((a) => a.contains('get.hermes-agent.dev')),
          false,
        );
      });

      // `--non-interactive` only gates `prompt_yes_no`; `main()` runs the
      // setup wizard unconditionally, and the wizard reads from `/dev/tty`
      // directly. Its own skip is a failed `(: </dev/tty)` probe, which under
      // wsl.exe succeeds — so the wizard opened a terminal nobody was typing
      // into and `hermes_cli.main setup` sat there with no I/O for 20 min
      // until the silence budget reaped the install (measured 2026-08-28).
      // `--skip-setup` is the installer's documented way out.
      test('hermes install skips the setup wizard that waits on a tty',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.hermesAgent);

        final command = testShell.lastCommand.last;
        expect(command.contains('--skip-setup'), true);
        expect(command.contains('--non-interactive'), true);
      });

      test('openclaw installs from the real openclaw.ai endpoint', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.openClaw);

        expect(
          testShell.lastCommand.any((a) => a.contains('openclaw.ai/install.sh')),
          true,
        );
        expect(
          testShell.lastCommand.any((a) => a.contains('install.openclaw.ai')),
          false,
        );
      });

      // Regression: `curl ... | sh` exits 0 even when curl can't resolve the
      // host (an empty stdin still makes the piped shell "succeed"), which
      // previously made every install of a dead URL report success while
      // installing nothing. `set -o pipefail` makes the pipeline surface
      // curl's own failure instead.
      test('install commands are prefixed with pipefail so a dead curl '
          'target cannot masquerade as success', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        for (final tool in [AiWorkspaceTool.hermesAgent, AiWorkspaceTool.openClaw]) {
          await service.install(tool);
          expect(
            testShell.lastCommand.any((a) => a.contains('set -o pipefail')),
            true,
            reason: '${tool.name} install should be pipefail-guarded',
          );
        }
      });

      // Every in-distro command reaches bash through `Process.run(...,
      // runInShell: false)`, so a double quote arrives literally and `~` does
      // not expand inside one — `[ -d "~/.hermes" ]` never matched anything.
      test('no built command uses a double quote or a tilde', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        for (final tool in AiWorkspaceTool.values) {
          service.getState(tool)?.status = ToolStatus.stopped;
          await service.install(tool);
          await service.start(tool);
          await service.stop(tool);
          await service.uninstall(tool);
        }

        for (final command in testShell.allCommands) {
          for (final argument in command) {
            expect(
              argument.contains('"'),
              false,
              reason: 'double quote in: $argument',
            );
            expect(
              argument.contains('~'),
              false,
              reason: 'tilde in: $argument',
            );
          }
        }
      });
    });

    // The install path streams instead of capturing a single result, and its
    // budget is silence rather than wall clock. Measured 2026-08-28: a cold
    // Hermes install runs 482s and goes quiet for 306s inside one
    // `npm install --silent`, so the old 5-minute total cap killed a healthy
    // install every time, always mid-npm.
    group('streamed install', () {
      /// A service whose install budgets are small enough to observe.
      AiWorkspaceService shortBudgetService({
        Duration silence = const Duration(milliseconds: 300),
        Duration ceiling = const Duration(seconds: 30),
      }) => AiWorkspaceService(
        broker: broker,
        reachabilityChecker: (_) async => true,
        installSilenceTimeout: silence,
        installMaxDuration: ceiling,
      );

      test('reports the installer output while it is still running', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService(silence: const Duration(seconds: 5));
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);

        await Future.delayed(const Duration(milliseconds: 50));
        child.emit('Cloning hermes-agent...\n');
        await Future.delayed(const Duration(milliseconds: 50));

        // The point of streaming: this is readable before the child exits.
        expect(service.isInstalling(AiWorkspaceTool.hermesAgent), true);
        expect(
          service.installProgress(AiWorkspaceTool.hermesAgent),
          'Cloning hermes-agent...',
        );

        // Carriage returns are line ends too — progress bars redraw with them.
        child.emit('Downloading Chromium 184.3 MiB [====      ] 40%\r');
        await Future.delayed(const Duration(milliseconds: 50));
        expect(
          service.installProgress(AiWorkspaceTool.hermesAgent),
          contains('40%'),
        );

        child.exit(0);
        expect(await install, true);
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.stopped,
        );
      });

      test('gives up when the installer goes silent', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService();
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);

        await Future.delayed(const Duration(milliseconds: 50));
        child.emit('Installing node dependencies...\n');
        // ...and then nothing, for longer than the silence budget.

        expect(await install, false);
        // Abandoned means reaped: a timeout that only stops waiting leaves an
        // orphaned wsl.exe behind.
        expect(child.killCount, greaterThan(0));

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        expect(state.status, ToolStatus.error);
        expect(state.errorMessage, contains('Nothing was printed for'));
        // Where it got to is the only clue the user has.
        expect(state.errorMessage, contains('Installing node dependencies'));
        expect(state.errorSticky, true);
      });

      test('keeps waiting while output is still arriving', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService();
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);

        // Six ticks at 100ms each: three times the 300ms silence budget in
        // total, and never 300ms without something to show for it.
        for (var tick = 0; tick < 6; tick++) {
          await Future.delayed(const Duration(milliseconds: 100));
          child.emit('step $tick\n');
        }
        child.exit(0);

        expect(await install, true);
        expect(child.killCount, 0);
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.stopped,
        );
        expect(service.installProgress(AiWorkspaceTool.hermesAgent), 'step 5');
      });

      test(
        'stops an installer that never finishes but keeps talking',
        () async {
          testShell.stdoutData = 'ai-workspace';
          final service = shortBudgetService(
            silence: const Duration(seconds: 5),
            ceiling: const Duration(milliseconds: 400),
          );
          await service.init();

          final child = ControlledProcess();
          testShell.processFactory = () => child;
          final install = service.install(AiWorkspaceTool.hermesAgent);

          final chatter = Timer.periodic(
            const Duration(milliseconds: 50),
            (_) => child.emit('still working\n'),
          );
          final installed = await install;
          chatter.cancel();

          expect(installed, false);
          expect(child.killCount, greaterThan(0));
          expect(
            service.getState(AiWorkspaceTool.hermesAgent)?.errorMessage,
            contains('Still running after'),
          );
        },
      );

      test(
        'a failed install keeps its message through the next probe',
        () async {
          testShell.stdoutData = 'ai-workspace';
          final service = shortBudgetService();
          await service.init();

          final child = ControlledProcess();
          testShell.processFactory = () => child;
          final install = service.install(AiWorkspaceTool.hermesAgent);
          await Future.delayed(const Duration(milliseconds: 50));
          child.emit('fetching sources\n');
          expect(await install, false);

          final message = service
              .getState(AiWorkspaceTool.hermesAgent)
              ?.errorMessage;
          testShell.processFactory = null;
          testShell.stdoutData = 'missing';
          await service.refreshStatus(AiWorkspaceTool.hermesAgent);

          // The probe that runs straight after a failure used to overwrite it
          // with a bare "not installed" and no reason at all.
          expect(
            service.getState(AiWorkspaceTool.hermesAgent)?.status,
            ToolStatus.error,
          );
          expect(
            service.getState(AiWorkspaceTool.hermesAgent)?.errorMessage,
            message,
          );
        },
      );

      // A `\r` frame is the freshest thing there is while the bar is redrawing
      // and meaningless once it stops: the Playwright download left the
      // fragment `(O) 2. No` frozen on the card as both the progress line and
      // the retained "Last output" of the failure that followed 12 minutes
      // later (measured 2026-08-28).
      test('a progress-bar frame is shown live but never kept', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService(silence: const Duration(seconds: 5));
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);

        await Future.delayed(const Duration(milliseconds: 50));
        child.emit('Installing browser tools\n');
        child.emit('Downloading Chromium 184.3 MiB [==   ] 40%\r');
        await Future.delayed(const Duration(milliseconds: 50));

        // Live: the redraw is what the user wants to see.
        expect(service.installProgress(AiWorkspaceTool.hermesAgent),
            contains('40%'));

        child.exit(1);
        expect(await install, false);

        // Over: the last thing the installer actually committed to a line.
        expect(service.installProgress(AiWorkspaceTool.hermesAgent),
            'Installing browser tools');
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.errorMessage,
          isNot(contains('40%')),
        );
      });

      // `_installProgress` used to be cleared only when a new install began,
      // so a *start* that failed rendered the card with the *installer's*
      // final line quoted underneath it.
      test('the next action drops the previous install output', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService();
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);
        await Future.delayed(const Duration(milliseconds: 50));
        child.emit('fetching sources\n');
        expect(await install, false);
        expect(service.installProgress(AiWorkspaceTool.hermesAgent),
            'fetching sources');

        testShell.processFactory = null;
        testShell.exitCode = 1;
        service.getState(AiWorkspaceTool.hermesAgent)!.status =
            ToolStatus.stopped;
        await service.start(AiWorkspaceTool.hermesAgent);

        expect(service.installProgress(AiWorkspaceTool.hermesAgent), isNull);
      });

      // The silence budget has to fire on an installer that never prints
      // anything at all, not only on one that prints and then stops: the
      // measured failure was `hermes_cli.main setup` sitting on `/dev/tty`,
      // and a wedge that early leaves no line to quote back.
      test('gives up on an installer that never prints anything', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService();
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;

        expect(await service.install(AiWorkspaceTool.hermesAgent), false);
        expect(child.killCount, greaterThan(0));

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        expect(state.status, ToolStatus.error);
        expect(state.errorMessage, contains('Nothing was printed for'));
        // No line arrived, so there is nothing to attribute — an empty
        // `Last output:` reads as though the installer said something.
        expect(state.errorMessage, isNot(contains('Last output')));
        expect(service.installProgress(AiWorkspaceTool.hermesAgent), isNull);
      });

      // Progress is progress whichever pipe it arrives on. The Hermes
      // installer's own steps report on stderr — npm and Playwright both do —
      // so a budget that only watches stdout kills a healthy install just as
      // the old wall-clock cap did.
      test('output on stderr alone counts as progress', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService();
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);

        // Three times the silence budget, with nothing at all on stdout.
        for (var tick = 0; tick < 6; tick++) {
          await Future.delayed(const Duration(milliseconds: 100));
          child.emitError('npm warn deprecated package $tick\n');
        }
        child.exit(0);

        expect(await install, true);
        expect(child.killCount, 0);
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.stopped,
        );
        expect(
          service.installProgress(AiWorkspaceTool.hermesAgent),
          'npm warn deprecated package 5',
        );
      });

      // `wsl.exe` is a Windows launcher around a Linux process, and a
      // terminated one can report a clean 0. Trusting that would turn every
      // abandoned install into a *success*: the card would go green over a
      // half-built tree with no `hermes` binary in it — the exact debris the
      // old wall-clock cap left behind. Two things stop it, and this pins the
      // pair rather than either one: the abandon path rewrites a 0 exit to
      // -1, and `isSuccess` additionally requires no `error`. Removing both
      // (verified) turns this install green.
      test('a killed installer that reports success is still a failure',
          () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService();
        await service.init();

        final child = ControlledProcess()..exitCodeOnKill = 0;
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);
        await Future.delayed(const Duration(milliseconds: 50));
        child.emit('Installing node dependencies...\n');

        expect(await install, false);
        expect(child.killCount, greaterThan(0));

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        expect(state.status, ToolStatus.error);
        expect(state.errorMessage, contains('Nothing was printed for'));
        // Nothing was installed, so nothing may claim to have been.
        expect(state.installPath, isNull);
        expect(
          notifications,
          isNot(contains(
              'ai-workspace-install-success-text'.i18n(['Hermes Agent']))),
        );
      });

      // The page polls `isInstalling` to decide whether to keep repainting and
      // whether a status probe may run; an abandoned install that never left
      // the set would spin forever and lock the tool out of every probe.
      test('a killed install releases the tool and stays in error', () async {
        testShell.stdoutData = 'ai-workspace';
        final service = shortBudgetService();
        await service.init();

        final child = ControlledProcess();
        testShell.processFactory = () => child;
        final install = service.install(AiWorkspaceTool.hermesAgent);
        await Future.delayed(const Duration(milliseconds: 50));
        child.emit('Installing node dependencies...\n');
        expect(await install, false);

        expect(service.isInstalling(AiWorkspaceTool.hermesAgent), false);
        final message =
            service.getState(AiWorkspaceTool.hermesAgent)!.errorMessage;

        // Only an explicit user action clears it — two probes in a row do not.
        testShell.processFactory = null;
        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.error,
        );
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.errorMessage,
          message,
        );

        service.clearError(AiWorkspaceTool.hermesAgent);
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.running,
        );
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.errorMessage,
          isNull,
        );
      });
    });

    group('start/stop', () {
      test('starts a stopped tool', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        // Pre-set tool as installed/stopped
        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.stopped;

        testShell.exitCode = 0;
        final result = await service.start(AiWorkspaceTool.hermesAgent);

        expect(result, true);
        expect(state.status, ToolStatus.running);
        expect(state.lastStarted, isNotNull);
      });

      test('stops a running tool', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.running;

        testShell.exitCode = 0;
        final result = await service.stop(AiWorkspaceTool.hermesAgent);

        expect(result, true);
        expect(state.status, ToolStatus.stopped);
        expect(state.lastStopped, isNotNull);
      });

      test('cannot start uninstalled tool', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        // Force tool to notInstalled since init() probes status (mock returns "running")
        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.notInstalled;

        final result = await service.start(AiWorkspaceTool.hermesAgent);

        expect(result, false);
      });

      // `docker start` returning is not the container serving. Without the
      // post-start health probe the card claims "running" for the whole
      // migration window and Open Dashboard walks into a dead port.
      test('a started Open WebUI stays "starting" until it is healthy',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openWebUi)!;
        state.status = ToolStatus.stopped;

        testShell.exitCode = 0;
        testShell.stdoutData = 'starting';
        final result = await service.start(AiWorkspaceTool.openWebUi);

        expect(result, true);
        expect(state.status, ToolStatus.starting);
        expect(service.getUrl(AiWorkspaceTool.openWebUi), isNull);
        // Observed on the real app: the card read "Starting up..." while the
        // toast underneath it announced "Open WebUI is running", because the
        // notification was raised before the health re-probe.
        expect(notifications.last,
            'ai-workspace-starting-text'.i18n(['Open WebUI']));
        expect(
          notifications,
          isNot(contains('ai-workspace-started-text'.i18n(['Open WebUI']))),
        );
      });

      // The complement: once the gate says healthy the toast has to go back to
      // announcing the tool as running, or a successful start reads as though
      // it never finished.
      test('a healthy Open WebUI is announced as running', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        service.getState(AiWorkspaceTool.openWebUi)!.status =
            ToolStatus.stopped;

        testShell.exitCode = 0;
        testShell.stdoutData = 'running';
        await service.start(AiWorkspaceTool.openWebUi);

        expect(notifications.last,
            'ai-workspace-started-text'.i18n(['Open WebUI']));
      });

      // The launcher exits 0 even when the gateway dies immediately, so the
      // start command's own success gate has to be the port. Without it
      // start() flips the card to "running" against a dead port.
      test('starting hermes waits for its port instead of trusting pgrep',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        service.getState(AiWorkspaceTool.hermesAgent)!.status =
            ToolStatus.stopped;
        testShell.stdoutData = '';
        await service.start(AiWorkspaceTool.hermesAgent);

        final command = testShell.lastCommand.last;
        // `serve`, not `gateway`: `hermes gateway` is the messaging gateway
        // and binds no TCP port at all, so the card could never go green off
        // it. `hermes serve` is what listens on 9119 (measured 2026-08-28:
        // started by hand, the card went green on its own).
        expect(command.contains('setsid hermes serve --skip-build'), true);
        expect(command.contains('gateway'), false);
        expect(command.contains('for _i in'), true);
        expect(command.contains('/dev/tcp/127.0.0.1/9119'), true);
        // The gate is the port, never a live process. `pgrep` is allowed
        // exactly once — in the kill that clears the old server first — so
        // this pins it there rather than banning the word outright.
        expect('pgrep'.allMatches(command).length, 1);
        expect(command.contains('pgrep -f \'[h]ermes.*serve\''), true);
        expect(command.trimRight().endsWith('2>/dev/null; }'), true,
            reason: 'the listening test has to be the last thing that runs');
      });

      // `--no-onboard` never creates the systemd unit `gateway restart`
      // restarts, so on a fresh macOS guest Start failed every time
      // (bostrot/ai-tasks#70). The gateway is run directly instead, after
      // the one setting it refuses to start without.
      test('starting openclaw runs the gateway itself and waits for its port',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        service.getState(AiWorkspaceTool.openClaw)!.status = ToolStatus.stopped;
        testShell.stdoutData = '';
        await service.start(AiWorkspaceTool.openClaw);

        final command = testShell.lastCommand.last;
        expect(command.contains('gateway restart'), false);
        expect(
            command.contains('setsid openclaw gateway run --port 18789'), true);
        expect(command.indexOf('openclaw config set gateway.mode local'),
            lessThan(command.indexOf('gateway run')));
        // Bind and auth stay the config's call: an onboarded distro may have
        // chosen its own, and loopback is the default either way.
        expect(command.contains('--bind'), false);
        expect(command.contains('--auth'), false);
        expect(command.contains('for _i in'), true);
        expect(command.contains(r':18789([^0-9]|$)'), true);
        expect(command.contains('"'), false);
      });

      // OpenCode's flag default for `--port` is 0, i.e. "pick any free
      // port". Omitting it would leave the server on an address the card
      // could never find, so the card's own port has to be on the command
      // line — and, like the other two servers, the gate is the port rather
      // than the launcher's exit code.
      test('starting opencode pins its port and waits for it', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        service.getState(AiWorkspaceTool.openCode)!.status =
            ToolStatus.stopped;
        testShell.stdoutData = '';
        await service.start(AiWorkspaceTool.openCode);

        final command = testShell.lastCommand.last;
        // `web`, not `serve`: both start the same HTTP server but only `web`
        // serves the browser UI "Open Dashboard" opens.
        expect(command.contains('setsid opencode web --port 4096'), true);
        expect(command.contains('--hostname 127.0.0.1'), true);
        expect(command.contains('for _i in'), true);
        expect(command.contains('/dev/tcp/127.0.0.1/4096'), true);
        // The gate is the port, never a live process — `pgrep` is allowed
        // only in the kill that clears the old server first.
        expect('pgrep'.allMatches(command).length, 1);
        expect(command.contains('pgrep -f \'[o]pencode\''), true);
        expect(command.trimRight().endsWith('2>/dev/null; }'), true,
            reason: 'the listening test has to be the last thing that runs');
        // `runInShell: false` means a `"` reaches bash literally.
        expect(command.contains('"'), false);
      });

      // The installer hardcodes `\$HOME/.opencode/bin` and offers no prefix
      // flag, and every command here runs through a non-interactive
      // `bash -c` that sources no rc file — so without the symlink the
      // `cmd://opencode` existence check would answer "missing" over a
      // perfectly good install, exactly the way the tilde-based checks used
      // to for hermes and openclaw.
      test('installing opencode puts the binary somewhere PATH can find it',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        await service.install(AiWorkspaceTool.openCode);

        final command = testShell.lastCommand.last;
        expect(command.startsWith('set -o pipefail; '), true,
            reason: 'a dead curl target must not masquerade as success');
        expect(command.contains('https://opencode.ai/install'), true);
        // No rc-file surgery: the symlink is what puts it on PATH, and an
        // `export PATH` line appended to `.bashrc` is never read here.
        expect(command.contains('--no-modify-path'), true);
        // The installer still reads `basename \$SHELL` under `set -u`, above
        // the block that flag turns off, so an environment that reaches the
        // distro without SHELL would abort it before the first download.
        expect(command.contains('SHELL=\${SHELL:-/bin/bash}'), true);
        expect(
            command.contains(
                'ln -sf \$HOME/.opencode/bin/opencode /usr/local/bin/opencode'),
            true);
      });

      // `pkill -f` matches the *command line* of the `bash -c` running it, and
      // the `[h]ermes` bracket only shields the pattern itself. Every command
      // here that mentions its tool a second time, unbracketed, therefore
      // signalled its own shell: Hermes never reached `setsid hermes gateway`,
      // OpenClaw's Stop always returned non-zero, and both uninstalls died
      // before removing anything. Measured against the real distro 2026-08-28.
      test('no lifecycle command reaches for pkill', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        for (final tool in AiWorkspaceTool.values) {
          service.getState(tool)!.status = ToolStatus.stopped;
          await service.start(tool);
          await service.stop(tool);
          await service.uninstall(tool);
        }

        final args = testShell.allCommands.expand((cmd) => cmd);
        expect(
          args.where((arg) => arg.contains('pkill')),
          isEmpty,
          reason: 'pkill -f cannot tell the tool from the shell killing it',
        );

        final killLoops =
            args.where((arg) => arg.contains('pgrep -f')).toList();
        expect(killLoops, isNotEmpty,
            reason: 'the gateways still have to be killable');
        for (final loop in killLoops) {
          expect(loop.contains(r'[ $_p = $$ ]'), true,
              reason: 'the kill loop must skip the shell running it');
          expect(loop.contains(r'[ $_p = $PPID ]'), true,
              reason: 'and its parent, which carries the same command line');
        }
      });

      // Stop is the only lifecycle call with no toast of its own, so the
      // card's `Error:` line is the entire feedback — and a shell taken down
      // by a signal writes nothing to stderr, which put a literal `Error:`
      // with nothing after it on the OpenClaw card.
      test('a failed stop with no stderr still says something readable',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openClaw)!;
        state.status = ToolStatus.running;

        testShell.exitCode = 143; // SIGTERM, the shape of the self-kill
        testShell.stderrData = '   ';
        final result = await service.stop(AiWorkspaceTool.openClaw);

        expect(result, false);
        expect(state.errorMessage,
            'ai-workspace-stop-failed-text'.i18n(['OpenClaw']));
      });

      // A kill that matched nothing exits 0 exactly like one that worked, and
      // `docker stop` is followed by `|| true`. Measured 2026-08-28: the
      // Hermes card flipped to "stopped" while the process was still running
      // and still listening on 9119. Every stop now ends on the same port test
      // the status probe uses.
      test('every stop command verifies the port is actually released',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        for (final tool in AiWorkspaceTool.values) {
          service.getState(tool)!.status = ToolStatus.running;
          await service.stop(tool);

          final command = testShell.lastCommand.last;
          final port = service.getState(tool)!.port;
          expect(command.contains('/dev/tcp/127.0.0.1/$port'), true,
              reason: '${tool.name} stop should end on its own port');
          expect(command.trimRight().endsWith('2>/dev/null; }'), true,
              reason: '${tool.name}: the port test has to be the last thing '
                  'that runs, or the exit code is somebody else\'s');
          expect(command.contains('! {'), true,
              reason: '${tool.name}: stopped means the port is *not* serving');
        }
      });

      // `hermes gateway` is the messaging gateway and never binds a port, so
      // a kill aimed at it matched nothing the card cares about while
      // `hermes serve` kept serving.
      test('stopping hermes targets the process that holds the port', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        service.getState(AiWorkspaceTool.hermesAgent)!.status =
            ToolStatus.running;
        await service.stop(AiWorkspaceTool.hermesAgent);

        final command = testShell.lastCommand.last;
        expect(command.contains('pgrep -f \'[h]ermes.*serve\''), true);
        expect(command.contains('gateway'), false);
      });

      // Same bug class as the failed stop below: a start whose gate is a bare
      // shell test writes nothing to stderr, and the card has no toast to fall
      // back on once it is dismissed — it rendered a red `Error:` followed by
      // nothing at all.
      test('a failed start with no stderr still says something readable',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.stopped;

        testShell.exitCode = 1;
        testShell.stderrData = '   ';
        final result = await service.start(AiWorkspaceTool.hermesAgent);

        expect(result, false);
        expect(state.errorMessage,
            'ai-workspace-start-failed-text'.i18n(['Hermes Agent']));
      });

      test('a failed stop keeps real stderr when there is any', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openClaw)!;
        state.status = ToolStatus.running;

        testShell.exitCode = 1;
        testShell.stderrData = 'openclaw: permission denied\n';
        final result = await service.stop(AiWorkspaceTool.openClaw);

        expect(result, false);
        expect(state.errorMessage, 'openclaw: permission denied');
      });

      // The failure used to be assigned straight onto `errorMessage`, which
      // left `status` on `running` — a red error line under a green "running"
      // pill — and left it non-sticky, so the next background probe wiped the
      // only feedback the stop path has (audit PS-32).
      test('a failed stop moves the card off "running" and sticks', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openClaw)!;
        state.status = ToolStatus.running;

        testShell.exitCode = 1;
        testShell.stderrData = 'openclaw: permission denied\n';
        expect(await service.stop(AiWorkspaceTool.openClaw), false);

        expect(state.status, ToolStatus.error,
            reason: 'a stop that failed may not leave the badge on running');
        expect(state.errorSticky, true);

        // The probe that follows must leave both alone until the user acts.
        testShell.exitCode = 0;
        await service.refreshStatus(AiWorkspaceTool.openClaw);
        expect(state.errorMessage, 'openclaw: permission denied');
        expect(state.status, ToolStatus.error);
      });
    });

    group('uninstall', () {
      test('uninstalls a filesystem-based tool', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.stopped;

        testShell.exitCode = 0;
        final result = await service.uninstall(AiWorkspaceTool.hermesAgent);

        expect(result, true);
        expect(state.status, ToolStatus.notInstalled);
        expect(state.installPath, isNull);
      });

      // The installer writes `<bindir>/hermes` as a wrapper *script*, not a
      // symlink into the install root, so removing only the roots left it on
      // PATH: `command -v hermes` kept answering "exists" and the card read
      // "Installed" over a launcher whose first line was
      // `venv/bin/python: No such file or directory`, with Install disabled.
      // Measured 2026-08-28 — the app could not return itself to a clean
      // state at all.
      test('uninstalling hermes removes the launcher, not just the roots',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        service.getState(AiWorkspaceTool.hermesAgent)!.status =
            ToolStatus.stopped;
        testShell.allCommands.clear();
        await service.uninstall(AiWorkspaceTool.hermesAgent);

        final removal = testShell.allCommands
            .expand((cmd) => cmd)
            .firstWhere((arg) => arg.contains('hermes-agent'));
        expect(removal.contains('/usr/local/bin/hermes'), true);
        expect(removal.contains('\$HOME/.local/bin/hermes'), true);
      });

      // Same failure mode the hermes launcher had: the install command adds
      // `/usr/local/bin/opencode` itself, and leaving it behind means
      // `command -v opencode` keeps answering "exists" over a dangling
      // symlink, so the card reads "Installed" with Install disabled and the
      // app cannot get itself back to a clean state.
      test('uninstalling opencode removes the PATH symlink it created',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        service.getState(AiWorkspaceTool.openCode)!.status =
            ToolStatus.stopped;
        testShell.allCommands.clear();
        await service.uninstall(AiWorkspaceTool.openCode);

        final removal = testShell.allCommands
            .expand((cmd) => cmd)
            .firstWhere((arg) => arg.contains('rm -f /usr/local/bin/opencode'));
        expect(removal.contains('rm -rf \$HOME/.opencode'), true);
        // Nothing interactive: an unattended uninstall has nobody to answer a
        // confirmation prompt, which is how a third-party installer already
        // burned a whole timeout budget in this file's history.
        expect(removal.contains('opencode uninstall'), false);
      });

      test('stops running tool before uninstalling', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.running;

        testShell.exitCode = 0; // stop succeeds, then uninstall succeeds
        final result = await service.uninstall(AiWorkspaceTool.hermesAgent);

        expect(result, true);
        expect(state.status, ToolStatus.notInstalled);
      });
    });

    group('refreshStatus', () {
      test('detects running status', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        // Status check returns "running"
        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.running,
        );
      });

      test('detects stopped status', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        // The combined status+existence check's single shell invocation
        // resolves to 'exists' when the process isn't running but the
        // install is still present.
        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        expect(
          service.getState(AiWorkspaceTool.openClaw)?.status,
          ToolStatus.stopped,
        );
      });

      // Regression: the card read "Not installed" while still printing
      // "Installed: cmd://openclaw" underneath, because only uninstall()
      // ever reset the path.
      test('a notInstalled result clears a stale installPath', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.openClaw);
        expect(service.getState(AiWorkspaceTool.openClaw)?.installPath,
            'cmd://openclaw');

        // The binary is gone (uninstalled outside the app, distro reset, ...).
        testShell.stdoutData = 'missing';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        final state = service.getState(AiWorkspaceTool.openClaw);
        expect(state?.status, ToolStatus.notInstalled);
        expect(state?.installPath, isNull);
      });

      test('a confirmed install is re-asserted after a notInstalled probe',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'missing';
        await service.refreshStatus(AiWorkspaceTool.openClaw);
        expect(service.getState(AiWorkspaceTool.openClaw)?.installPath, isNull);

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        final state = service.getState(AiWorkspaceTool.openClaw);
        expect(state?.status, ToolStatus.stopped);
        expect(state?.installPath, 'cmd://openclaw');
      });

      test('a cached notInstalled does not resurrect a persisted install path',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 0;
        await service.install(AiWorkspaceTool.openClaw);
        testShell.stdoutData = 'missing';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        // Whatever a stale pref still holds, a notInstalled seed must not
        // show a path before the first live probe answers.
        await prefs.setString(
            'AiWorkspaceInstallPath_openClaw', 'cmd://openclaw');
        final restarted = AiWorkspaceService(broker: broker);
        restarted.seedToolStates();

        final state = restarted.getState(AiWorkspaceTool.openClaw);
        expect(state?.status, ToolStatus.notInstalled);
        expect(state?.installPath, isNull);
      });

      test('issues a single wsl call, not two', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        testShell.reset();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        expect(testShell.allCommands.length, 1);
      });

      test('detects a stopped Docker-backed tool via docker inspect',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(
          service.getState(AiWorkspaceTool.openWebUi)?.status,
          ToolStatus.stopped,
        );
        expect(
          testShell.lastCommand.any((a) => a.contains('docker inspect')),
          true,
        );
      });

      // Regression: dockerd does not auto-start on distro boot, so right
      // after a cold WSL start the daemon is down and `docker inspect`/
      // `docker ps` fail — which used to get misread as "not installed"
      // even for a genuinely-installed tool, and then made the next
      // install attempt fail with "name already in use".
      test('starts the docker daemon before checking a docker-backed tool',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(
          testShell.lastCommand.any((a) => a.contains('service docker start')),
          true,
        );
      });

      test('does not try to start docker for non-docker tools', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        expect(
          testShell.lastCommand.any((a) => a.contains('service docker start')),
          false,
        );
      });

      // Open WebUI's container reports `Up` for the ~2 minutes its alembic
      // migrations take, during which nothing answers on the port and a
      // restart kills it. Docker's healthcheck is the only source that knows
      // the difference, so the probe has to consult it.
      test('reports Open WebUI as starting while its container is migrating',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'starting';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        final state = service.getState(AiWorkspaceTool.openWebUi);
        expect(state?.status, ToolStatus.starting);
        expect(state?.installPath, 'docker://open-webui');
      });

      test('reports Open WebUI as running once its container is healthy',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(
          service.getState(AiWorkspaceTool.openWebUi)?.status,
          ToolStatus.running,
        );
      });

      test('gates the Open WebUI probe on docker inspect health', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        final command = testShell.lastCommand.last;
        expect(command.contains('{{.State.Health.Status}}'), true);
        // `runInShell: false` means a `"` reaches bash literally and breaks
        // the --format filter; the Go template has to be single-quoted.
        expect(command.contains('"'), false);
      });

      test('does not health-gate tools without a healthcheck', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        expect(
          testShell.lastCommand.last.contains('{{.State.Health.Status}}'),
          false,
        );
        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.running,
        );
      });

      // An unhealthy container is still an installed one: the health gate
      // answers `stopped`, which must not fall through to notInstalled and
      // wipe the install path with it.
      test('an unhealthy container reads as stopped, not notInstalled',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'stopped';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        final state = service.getState(AiWorkspaceTool.openWebUi);
        expect(state?.status, ToolStatus.stopped);
        expect(state?.installPath, 'docker://open-webui');
      });

      // Regression: the exists-check used to be `[ -d "~/.hermes-agent" ]`,
      // which never matches — `~` doesn't expand inside double quotes in
      // bash, so a genuinely-installed tool with no process currently
      // running was always misreported as not installed. `command -v`
      // checks PATH instead and has no such quoting pitfall.
      test('checks hermes agent installation via command -v, not a path',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        expect(
          testShell.lastCommand.any((a) => a.contains('command -v hermes')),
          true,
        );
        expect(
          testShell.lastCommand.any((a) => a.contains('~/.hermes')),
          false,
        );
      });

      test('checks openclaw installation via command -v, not a path',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        expect(
          testShell.lastCommand.any((a) => a.contains('command -v openclaw')),
          true,
        );
      });

      // Both gateways used to be probed with `pgrep`, which proves only that
      // a process exists: OpenClaw's gateway stays alive after a failed bind
      // and Hermes' launcher exits 0 while its gateway is already dead, so a
      // card read "running" against a port that refused every connection.
      test('hermes agent status is decided by its port, not by pgrep',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        final command = testShell.lastCommand.last;
        expect(command.contains('9119'), true);
        expect(command.contains('/dev/tcp/127.0.0.1/9119'), true);
        expect(command.contains('pgrep'), false);
      });

      test('openclaw status is decided by its port, not by pgrep', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        final command = testShell.lastCommand.last;
        expect(command.contains('18789'), true);
        expect(command.contains('/dev/tcp/127.0.0.1/18789'), true);
        expect(command.contains('pgrep'), false);
      });

      // A bare `grep -q 18789` also matches `:187890` and any other column
      // carrying those digits, so the port has to be anchored.
      test('the port probe anchors the port number', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openClaw);

        expect(
          testShell.lastCommand.last.contains(r':18789([^0-9]|$)'),
          true,
        );
        // `runInShell: false` means a `"` reaches bash literally.
        expect(testShell.lastCommand.last.contains('"'), false);
      });

      // The port probe answering "not listening" must not be read as "not
      // installed": the probe falls through to the exists check, and an
      // installed-but-dead gateway keeps its card and its install path.
      test(
          'a gateway that is not listening reads as stopped, keeping its '
          'install path', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        final state = service.getState(AiWorkspaceTool.hermesAgent);
        expect(state?.status, ToolStatus.stopped);
        expect(state?.installPath, 'cmd://hermes');
        // The else-branch of the port probe is what produced that answer.
        expect(
          testShell.lastCommand.last.contains('command -v hermes'),
          true,
        );
      });

      test('handles error gracefully', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        // What wsl.exe answers for a distro that is not registered.
        testShell.exitCode = 1;
        testShell.stderrData = 'There is no distribution with the supplied '
            'name.\r\nError code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(
          service.getState(AiWorkspaceTool.openWebUi)?.status,
          ToolStatus.notInstalled,
        );
      });

      // wsl.exe localizes the sentence but never the code.
      test('reads a localized missing-distro error by its code', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        testShell.stdoutData = 'running';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        testShell.exitCode = 1;
        testShell.stderrData = 'Es ist keine Verteilung mit dem angegebenen '
            'Namen vorhanden.\r\nFehlercode: '
            'Wsl/Service/WSL_E_DISTRO_NOT_FOUND';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(
          service.getState(AiWorkspaceTool.openWebUi)?.status,
          ToolStatus.notInstalled,
        );
        final restarted = AiWorkspaceService(broker: broker)..seedToolStates();
        expect(restarted.getState(AiWorkspaceTool.openWebUi)?.status,
            ToolStatus.notInstalled);
      });

      // wsl.exe sometimes reports on stdout and leaves stderr empty.
      test('finds the missing-distro code on stdout too', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stdoutData =
            'Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND';
        await service.refreshStatus(AiWorkspaceTool.hermesAgent);

        expect(
          service.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.notInstalled,
        );
      });

      // vmctl's answer when the macOS workspace VM is not in the store.
      test("reads vmctl's missing-VM message as not installed", () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stdoutData = '';
        testShell.stderrData = 'vmctl: No VM named "ai-workspace".';
        await service.refreshStatus(AiWorkspaceTool.openCode);

        expect(
          service.getState(AiWorkspaceTool.openCode)?.status,
          ToolStatus.notInstalled,
        );
      });

      // A failure inside the distro, or one that only mentions the distro by
      // name, says nothing about whether the tool is installed. Reading it as
      // "not installed" used to drop the install path and persist that guess
      // over the last confirmed answer.
      for (final stderr in const [
        'bash: line 1: docker: command not found',
        'curl: (6) Could not resolve host: localhost: Name or service not '
            'found',
        'Failed to start ai-workspace.\r\nError code: '
            'Wsl/Service/CreateInstance/E_FAIL',
        'The operation timed out because a response was not received from '
            'the virtual machine or container.\r\nError code: '
            'Wsl/Service/CreateInstance/HCS_E_CONNECTION_TIMEOUT',
      ]) {
        test('keeps the last confirmed status on: $stderr', () async {
          testShell.stdoutData = 'ai-workspace';
          await service.init();
          testShell.stdoutData = 'exists';
          await service.refreshStatus(AiWorkspaceTool.hermesAgent);

          testShell.exitCode = 1;
          testShell.stdoutData = '';
          testShell.stderrData = stderr;
          await service.refreshStatus(AiWorkspaceTool.hermesAgent);

          final state = service.getState(AiWorkspaceTool.hermesAgent)!;
          expect(state.status, ToolStatus.error);
          expect(state.errorMessage, stderr);

          final restarted = AiWorkspaceService(broker: broker)
            ..seedToolStates();
          final cached = restarted.getState(AiWorkspaceTool.hermesAgent)!;
          expect(cached.status, ToolStatus.stopped);
          expect(cached.installPath, 'cmd://hermes');
        });
      }

      // Regression coverage for `checked`: a UI decides whether to show a
      // checking spinner based on whether a tool was *attempted*, not
      // whether that attempt succeeded — so `checked` must end up true on
      // every path through refreshStatus, including the error ones.
      test('marks the tool as checked even when the distro is missing',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.exitCode = 1;
        testShell.stderrData =
            'Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(service.getState(AiWorkspaceTool.openWebUi)?.checked, true);
      });

      test('marks the tool as checked even when the broker throws',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.throwOnRun = true;
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        expect(service.getState(AiWorkspaceTool.openWebUi)?.checked, true);
      });

      test('a freshly-seeded tool is not checked yet', () {
        service.seedToolStates();

        for (final tool in AiWorkspaceTool.values) {
          expect(service.getState(tool)?.checked, false);
        }
      });
    });

    group('getUrl', () {
      test('returns URL for running tool', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.running;

        expect(
          service.getUrl(AiWorkspaceTool.hermesAgent),
          'http://localhost:9119',
        );
      });

      test('returns null for non-running tool', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openClaw)!;
        state.status = ToolStatus.stopped;

        expect(service.getUrl(AiWorkspaceTool.openClaw), isNull);
      });
    });

    group('getDashboardUrl', () {
      // The whole point of the starting state: the dashboard must stay shut
      // until the container is actually serving.
      test('returns null while the tool is still starting up', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openWebUi)!;
        state.status = ToolStatus.starting;

        expect(
            await service.getDashboardUrl(AiWorkspaceTool.openWebUi), isNull);
      });

      test('returns null for a tool that is not running', () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openWebUi)!;
        state.status = ToolStatus.stopped;

        expect(await service.getDashboardUrl(AiWorkspaceTool.openWebUi), isNull);
      });

      test('Open WebUI uses the static port without any extra WSL call',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openWebUi)!;
        state.status = ToolStatus.running;
        testShell.allCommands.clear();

        final url = await service.getDashboardUrl(AiWorkspaceTool.openWebUi);

        expect(url, 'http://localhost:8083');
        expect(testShell.allCommands, isEmpty);
      });

      // `hermes dashboard` *starts* a server on the same fixed port and then
      // blocks — it never prints a URL, so running it burned 40s and then put
      // `No dashboard URL from: hermes dashboard` on the card while nothing
      // opened (measured 2026-08-28). The port is fixed and reachable, so the
      // static URL is the whole answer and no command runs at all.
      test('hermes agent opens its fixed port without running any command',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.hermesAgent)!;
        state.status = ToolStatus.running;
        testShell.allCommands.clear();

        final url = await service.getDashboardUrl(AiWorkspaceTool.hermesAgent);

        expect(url, 'http://localhost:9119');
        expect(testShell.allCommands, isEmpty);
        expect(state.errorMessage, isNull);
      });

      test('openclaw runs "openclaw dashboard" and returns the printed URL',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openClaw)!;
        state.status = ToolStatus.running;
        testShell.stdoutData = 'http://127.0.0.1:18789/pair/xyz';

        final url = await service.getDashboardUrl(AiWorkspaceTool.openClaw);

        expect(url, 'http://127.0.0.1:18789/pair/xyz');
        expect(
          testShell.lastCommand.any((a) => a.contains('openclaw dashboard')),
          true,
        );
      });

      test('returns null when no URL is found in the command output',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        final state = service.getState(AiWorkspaceTool.openClaw)!;
        state.status = ToolStatus.running;
        testShell.stdoutData = '';
        testShell.exitCode = 1;

        expect(await service.getDashboardUrl(AiWorkspaceTool.openClaw), isNull);
        expect(state.errorMessage, contains('openclaw dashboard'));
      });

      // Regression: docker reporting a container "Up" (or a gateway CLI
      // printing a link) doesn't guarantee the web server inside has
      // actually finished starting — clicking "Open Dashboard" used to
      // open a browser tab to a URL nothing was listening on yet, which
      // showed as an empty response. getDashboardUrl now waits for
      // something to actually answer before returning a URL at all.
      test('does not return a URL that never becomes reachable', () async {
        final unreachable = AiWorkspaceService(
          broker: broker,
          reachabilityChecker: (_) async => false,
        );
        testShell.stdoutData = 'ai-workspace';
        await unreachable.init();

        final state = unreachable.getState(AiWorkspaceTool.openWebUi)!;
        state.status = ToolStatus.running;

        expect(
          await unreachable.getDashboardUrl(AiWorkspaceTool.openWebUi),
          isNull,
        );
      });

      test('returns the URL once the reachability check reports it is live',
          () async {
        var callCount = 0;
        final flakyThenUp = AiWorkspaceService(
          broker: broker,
          // Simulates the container being "Up" per docker but not actually
          // serving yet for the first couple of polls.
          reachabilityChecker: (_) async => (++callCount) >= 3,
        );
        testShell.stdoutData = 'ai-workspace';
        await flakyThenUp.init();

        final state = flakyThenUp.getState(AiWorkspaceTool.openWebUi)!;
        state.status = ToolStatus.running;

        final url = await flakyThenUp.getDashboardUrl(AiWorkspaceTool.openWebUi);

        expect(url, 'http://localhost:8083');
        expect(callCount, greaterThanOrEqualTo(3));
      });

      // The dashboard is dialled from the machine running the app, and only
      // WSL relays this machine's loopback into the workspace. On the macOS
      // backend the workspace is a VM on its own network, so `localhost` is
      // the Mac and nothing is serving there — which is how a healthy,
      // listening OpenCode card came to read "Dashboard URL not reachable
      // from Windows: http://localhost:4096" (bostrot/ai-tasks#70). The port
      // is forwarded out instead, and the URL re-pointed at the local end.
      group('on a backend that shares no loopback with this machine', () {
        late _ForwardingShell shell;
        late ExecutionBroker remoteBroker;

        setUp(() {
          shell = _ForwardingShell();
          remoteBroker = ExecutionBroker(shell: shell);
        });

        /// A service on the remote runtime with [tool] already running.
        Future<AiWorkspaceService> runningRemote(
          AiWorkspaceTool tool, {
          DashboardReachabilityChecker? reachable,
          LocalPortPicker? pick,
        }) async {
          final remote = AiWorkspaceService(
            broker: remoteBroker,
            runtime: _RemoteGuestRuntime(),
            reachabilityChecker: reachable ?? (_) async => true,
            localPortPicker: pick ?? (preferred) async => preferred,
          );
          addTearDown(remote.dispose);
          shell.stdoutData = 'ai-workspace';
          await remote.init();
          remote.getState(tool)!.status = ToolStatus.running;
          shell.stdoutData = '';
          return remote;
        }

        test('the dashboard port is forwarded and dialled on this machine',
            () async {
          final dialled = <String>[];
          final remote = await runningRemote(AiWorkspaceTool.openWebUi,
              reachable: (url) async {
            dialled.add(url);
            return true;
          });

          final url = await remote.getDashboardUrl(AiWorkspaceTool.openWebUi);

          // `127.0.0.1`, not `localhost`: the forward listens on IPv4 only.
          expect(url, 'http://127.0.0.1:8083');
          // The probe has to dial what the browser will open, or it proves
          // nothing about the URL that is handed back.
          expect(dialled, ['http://127.0.0.1:8083']);
          expect(shell.forwardCommands.single,
              containsAllInOrder(['--port', '8083', '--local-port', '8083']));
        });

        // Someone else on the Mac may already hold the dashboard's port —
        // an OpenCode of their own on 4096, say. Only the local end moves.
        test('a taken local port moves the forward, not the workspace port',
            () async {
          final remote = await runningRemote(AiWorkspaceTool.openCode,
              pick: (_) async => 50123);

          final url = await remote.getDashboardUrl(AiWorkspaceTool.openCode);

          expect(url, 'http://127.0.0.1:50123');
          expect(shell.forwardCommands.single,
              containsAllInOrder(['--port', '4096', '--local-port', '50123']));
        });

        // OpenClaw's URL carries the gateway token as a fragment, and a
        // dashboard opened without it shows "unauthorized: gateway token
        // missing" — so moving the port must not touch anything else.
        test('a printed URL keeps its path and token fragment', () async {
          final remote = await runningRemote(AiWorkspaceTool.openClaw,
              pick: (_) async => 51000);
          shell.stdoutData =
              'http://127.0.0.1:18789/pair/xyz\nGATEWAY_TOKEN:sekrit';

          final url = await remote.getDashboardUrl(AiWorkspaceTool.openClaw);

          expect(url, 'http://127.0.0.1:51000/pair/xyz#token=sekrit');
          expect(shell.forwardCommands.single,
              containsAllInOrder(['--port', '18789']));
        });

        // The browser tab keeps using the forward after the call returns, so
        // a second open must not start a second ssh for the same port.
        test('one forward serves every open of the same dashboard', () async {
          final remote = await runningRemote(AiWorkspaceTool.openCode);

          await remote.getDashboardUrl(AiWorkspaceTool.openCode);
          await remote.getDashboardUrl(AiWorkspaceTool.openCode);

          expect(shell.forwardCommands, hasLength(1));
        });

        // A double-click opens twice before the first forward exists. Two
        // forwards would orphan one: untracked, holding a port, never killed.
        test('overlapping opens share the forward still being opened',
            () async {
          final remote = await runningRemote(AiWorkspaceTool.openCode);

          final urls = await Future.wait([
            remote.getDashboardUrl(AiWorkspaceTool.openCode),
            remote.getDashboardUrl(AiWorkspaceTool.openCode),
          ]);

          expect(urls, ['http://127.0.0.1:4096', 'http://127.0.0.1:4096']);
          expect(shell.forwardCommands, hasLength(1));
        });

        // A guest that rebooted takes the old session with it; the next open
        // has to notice and dial again rather than hand out a dead port.
        test('a forward that ended is replaced on the next open', () async {
          final remote = await runningRemote(AiWorkspaceTool.openCode);
          await remote.getDashboardUrl(AiWorkspaceTool.openCode);

          shell.forwards.single.exit(255);
          await pumpEventQueue();
          final url = await remote.getDashboardUrl(AiWorkspaceTool.openCode);

          expect(url, 'http://127.0.0.1:4096');
          expect(shell.forwardCommands, hasLength(2));
        });

        // ssh is the only one who knows why a forward failed — a taken port,
        // no lease, a refused key — so its words go on the card, and a dead
        // forward is not polled for the full reachability budget.
        test('a forward that dies says why, and is not waited out', () async {
          final remote = await runningRemote(AiWorkspaceTool.openWebUi,
              reachable: (_) async {
            shell.forwards.last
              ..emitError('bind [127.0.0.1]:8083: Address already in use\n')
              ..exit(255);
            return false;
          });
          final state = remote.getState(AiWorkspaceTool.openWebUi)!;

          final clock = Stopwatch()..start();
          final url = await remote.getDashboardUrl(AiWorkspaceTool.openWebUi);

          expect(url, isNull);
          expect(state.errorMessage, contains('macOS'));
          expect(state.errorMessage, contains('http://127.0.0.1:8083'));
          expect(state.errorMessage, contains('Address already in use'));
          expect(state.errorMessage, isNot(contains('Windows')));
          expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
        });

        test('a forward that cannot even start is reported, not dialled',
            () async {
          var dials = 0;
          final remote = await runningRemote(AiWorkspaceTool.openWebUi,
              reachable: (_) async {
            dials++;
            return true;
          });
          shell.refuseForward = true;
          final state = remote.getState(AiWorkspaceTool.openWebUi)!;

          expect(
              await remote.getDashboardUrl(AiWorkspaceTool.openWebUi), isNull);
          expect(state.errorMessage, contains('Could not forward Open WebUI'));
          expect(dials, 0);
        });

        test('dispose closes every forward', () async {
          final remote = await runningRemote(AiWorkspaceTool.openWebUi);
          await remote.getDashboardUrl(AiWorkspaceTool.openWebUi);

          remote.dispose();

          expect(shell.forwards.single.killCount, 1);
        });

        // Binding every interface was the first fix for #70. It exposed
        // OpenCode's unauthenticated server on vmnet and still missed a
        // server started before the change. The forward reaches the
        // loopback, so the loopback bind stays.
        test('opencode keeps its loopback bind on this backend too', () async {
          final remote = await runningRemote(AiWorkspaceTool.openCode);
          remote.getState(AiWorkspaceTool.openCode)!.status =
              ToolStatus.stopped;

          await remote.start(AiWorkspaceTool.openCode);

          final command = shell.lastCommand.last;
          expect(command.contains('--hostname 127.0.0.1'), true);
          expect(command.contains('0.0.0.0'), false);
        });
      });
    });

    group('wsl command routing', () {
      // Without --exec, wsl.exe re-joins argv and runs it through the
      // distro's default shell, which eats a level of quoting: the script
      // handed to `bash -c` is split, only its first word reaches the child
      // bash, and the remainder executes in the outer shell. That is why the
      // probe's `_s=$(...)` was always empty and the health gate could never
      // be reached. Measured live 2026-08-28.
      test('shell commands are passed through --exec so argv survives',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        testShell.stdoutData = 'exists';
        await service.refreshStatus(AiWorkspaceTool.openWebUi);

        final command = testShell.lastCommand;
        expect(command.contains('--exec'), true);
        expect(
          command.indexOf('--exec'),
          lessThan(command.indexOf('bash')),
          reason: '--exec must precede the command it protects',
        );
      });

      test('all commands use wsl with -d ai-workspace flag', () async {
        // Distro check + init
        testShell.stdoutData = 'ai-workspace';
        await service.init();

        // Install command should route through WSL
        await service.install(AiWorkspaceTool.hermesAgent);

        expect(testShell.lastCommand[0], 'wsl');
        expect(
          testShell.allCommands.any(
            (cmd) => cmd.contains('-d') && cmd.contains(kAiWorkspaceDistro),
          ),
          true,
        );
      });
    });

    // Every test above stubs the probe's *answer* and asserts how the service
    // reads it. These run the exact bash program the service sends into the
    // distro and assert the program itself produces the right answer, with
    // shell functions standing in for `ss`, `docker` and the tool binaries.
    group('probe script semantics', () {
      /// The bash program `refreshStatus` sends for [tool].
      Future<String> probeScriptFor(AiWorkspaceTool tool) async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        testShell.stdoutData = 'exists';
        await service.refreshStatus(tool);
        return testShell.lastCommand.last;
      }

      /// The bash program `start` (or `stop`, when [start] is false) sends for
      /// [tool].
      Future<String> lifecycleScriptFor(AiWorkspaceTool tool,
          {required bool start}) async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        service.getState(tool)!.status = ToolStatus.stopped;
        testShell.stdoutData = '';
        if (start) {
          await service.start(tool);
        } else {
          await service.stop(tool);
        }
        return testShell.lastCommand.last;
      }

      /// Stubs for the kill loop, with `pgrep` handing back the *running*
      /// shell's own pid and its parent's alongside a decoy. Nothing else can
      /// prove the filter looks at real pids rather than an invented number.
      /// `kill` reports instead of signalling, so a script that would have
      /// killed itself still runs to the end and can be inspected.
      const killStubs = 'pgrep() { echo \$\$; echo \$PPID; echo 4242; }; '
          'kill() { echo "killed:\$1"; }; ';

      /// The pids the script asked to kill, in order.
      List<String> killedBy(String answer) => answer
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.startsWith('killed:'))
          .toList();

      /// Fast-forwards the daemon wait loop; nothing here needs real seconds.
      const noSleep = 'sleep() { :; }; ';

      /// A `docker` stub. [health] is the body of the `inspect` branch, [ps]
      /// what `docker ps` prints.
      String dockerStub({
        required String health,
        String ps = 'abcd open-webui Up 2 minutes',
      }) =>
          '$noSleep'
          'docker() { case \$1 in '
          'info) return 0;; '
          "ps) echo '$ps';; "
          'inspect) $health;; '
          'esac; }; ';

      test('a gateway whose port is listening reads as running', () async {
        final script = await probeScriptFor(AiWorkspaceTool.openClaw);

        final answer = await _runProbeScript(
          "ss() { echo 'LISTEN 0 4096 127.0.0.1:18789 0.0.0.0:*'; }; ",
          script,
        );

        expect(answer, 'running');
      });

      test('the hermes probe answers on its own port', () async {
        final script = await probeScriptFor(AiWorkspaceTool.hermesAgent);

        final answer = await _runProbeScript(
          "ss() { echo 'LISTEN 0 4096 127.0.0.1:9119 0.0.0.0:*'; }; ",
          script,
        );

        expect(answer, 'running');
      });

      // The bullet this phase set out to prove: `pgrep` finds the gateway and
      // would have reported it running, while nothing answers on the port.
      // The probe has to say "installed, not serving" instead — which
      // refreshStatus maps to stopped, keeping the card and its install path.
      test(
          'a gateway process that exists while nothing listens reads as '
          'installed, not running', () async {
        if (await _hostPortIsOpen(18789)) {
          markTestSkipped('a real service holds 18789 on this machine, so the '
              '/dev/tcp fallback cannot be exercised');
          return;
        }
        final script = await probeScriptFor(AiWorkspaceTool.openClaw);

        final answer = await _runProbeScript(
          "ss() { echo 'LISTEN 0 4096 127.0.0.1:22 0.0.0.0:*'; }; "
          'pgrep() { echo 4242; }; openclaw() { :; }; ',
          script,
        );

        expect(answer, 'exists');
      });

      test('the opencode probe answers on its own port', () async {
        final script = await probeScriptFor(AiWorkspaceTool.openCode);

        final answer = await _runProbeScript(
          "ss() { echo 'LISTEN 0 4096 127.0.0.1:4096 0.0.0.0:*'; }; ",
          script,
        );

        expect(answer, 'running');
      });

      // The `cmd://opencode` half of the same probe: nothing on the port,
      // but the binary is on PATH, so the card must keep its install rather
      // than fall back to "Not installed".
      test('an installed opencode with nothing listening reads as installed',
          () async {
        if (await _hostPortIsOpen(4096)) {
          markTestSkipped('a real service holds 4096 on this machine, so the '
              '/dev/tcp fallback cannot be exercised');
          return;
        }
        final script = await probeScriptFor(AiWorkspaceTool.openCode);

        final answer = await _runProbeScript(
          "ss() { echo 'LISTEN 0 4096 127.0.0.1:22 0.0.0.0:*'; }; "
          'opencode() { :; }; ',
          script,
        );

        expect(answer, 'exists');
      });

      // `4096` is a prefix of `40960`, and a bare `grep -q 4096` also matches
      // the `4096` that `ss -ltn` prints in its Send-Q column on every single
      // row — so an unanchored probe would have reported this tool running
      // against any listening socket at all.
      test('opencode is not reported running off an unrelated socket',
          () async {
        if (await _hostPortIsOpen(4096)) {
          markTestSkipped('a real service holds 4096 on this machine');
          return;
        }
        final script = await probeScriptFor(AiWorkspaceTool.openCode);

        final answer = await _runProbeScript(
          "ss() { echo 'LISTEN 0 4096 127.0.0.1:40960 0.0.0.0:*'; }; "
          'opencode() { :; }; ',
          script,
        );

        expect(answer, 'exists');
      });

      test(
          'a gateway that is neither listening nor installed reads as '
          'missing', () async {
        if (await _hostPortIsOpen(18789)) {
          markTestSkipped('a real service holds 18789 on this machine');
          return;
        }
        final script = await probeScriptFor(AiWorkspaceTool.openClaw);

        final answer = await _runProbeScript('ss() { :; }; ', script);

        expect(answer, 'missing');
      });

      // Regression: a bare `grep -q 18789` matches `:187890` and any other
      // column carrying those digits, so an unrelated socket reported the
      // gateway as running.
      test('a neighbouring port is not mistaken for the gateway port',
          () async {
        if (await _hostPortIsOpen(18789)) {
          markTestSkipped('a real service holds 18789 on this machine');
          return;
        }
        final script = await probeScriptFor(AiWorkspaceTool.openClaw);

        final answer = await _runProbeScript(
          "ss() { echo 'LISTEN 0 4096 127.0.0.1:187890 0.0.0.0:*'; }; "
          'openclaw() { :; }; ',
          script,
        );

        expect(answer, 'exists');
      });

      // Open WebUI runs ~2 minutes of alembic migrations while its container
      // already reports `Up`, and probing or restarting it inside that window
      // kills it. `docker ps` alone cannot tell the difference.
      test('a migrating Open WebUI container reads as starting, not running',
          () async {
        final script = await probeScriptFor(AiWorkspaceTool.openWebUi);

        final answer = await _runProbeScript(
          dockerStub(health: 'echo starting'),
          script,
        );

        expect(answer, 'starting');
      });

      test('a healthy Open WebUI container reads as running', () async {
        final script = await probeScriptFor(AiWorkspaceTool.openWebUi);

        final answer = await _runProbeScript(
          dockerStub(health: 'echo healthy'),
          script,
        );

        expect(answer, 'running');
      });

      test('an unhealthy Open WebUI container reads as stopped', () async {
        final script = await probeScriptFor(AiWorkspaceTool.openWebUi);

        final answer = await _runProbeScript(
          dockerStub(health: 'echo unhealthy'),
          script,
        );

        expect(answer, 'stopped');
      });

      // An image with no HEALTHCHECK makes `docker inspect` fail and leaves
      // the variable empty. An empty answer is no evidence of a problem, so
      // the gate must fall through to running rather than strand the card.
      test('an Open WebUI image with no healthcheck still reads as running',
          () async {
        final script = await probeScriptFor(AiWorkspaceTool.openWebUi);

        final answer = await _runProbeScript(
          dockerStub(health: 'return 1'),
          script,
        );

        expect(answer, 'running');
      });

      test('a container that is not up falls through to the existence check',
          () async {
        final script = await probeScriptFor(AiWorkspaceTool.openWebUi);

        final answer = await _runProbeScript(
          dockerStub(health: 'echo healthy', ps: ''),
          script,
        );

        expect(answer, 'exists');
      });

      // A daemon that never answers says nothing about whether the tool is
      // installed, so the probe reports that instead of guessing.
      test('a docker daemon that never comes up prints the dockerdown marker',
          () async {
        final script = await probeScriptFor(AiWorkspaceTool.openWebUi);

        final answer = await _runProbeScript(
          '${noSleep}docker() { return 1; }; ',
          script,
        );

        expect(answer, 'dockerdown');
      });

      // Found by clicking through the app, not by a test: a canned stdout
      // cannot show a shell that killed itself. `pkill -f '[h]ermes.*gateway'`
      // matched the very `bash -c` carrying it, because the same string goes
      // on to say `setsid hermes gateway` — so the script died on its first
      // statement and the launcher never ran at all. The sentinel at the end
      // is the whole point of the test.
      test('the hermes start command survives its own kill pattern', () async {
        final script =
            await lifecycleScriptFor(AiWorkspaceTool.hermesAgent, start: true);

        final answer = await _runProbeScript(
          // A throwaway HOME: the command creates `$HOME/.hermes` and appends
          // to a log there, and a test has no business writing to the real one.
          // `ss` answers so the port wait breaks on its first iteration —
          // twenty real `/dev/tcp` connect attempts take longer than the test
          // timeout on Windows, and the wait is not what this test is about.
          'HOME=\$(mktemp -d); $killStubs$noSleep'
              'setsid() { :; }; '
              "ss() { echo 'LISTEN 0 4096 127.0.0.1:9119 0.0.0.0:*'; }; ",
          '$script; echo SURVIVED',
        );

        expect(answer.contains('SURVIVED'), true,
            reason: 'the kill must not signal the shell running it');
        expect(killedBy(answer), ['killed:4242'],
            reason: 'only the gateway, never this shell or its parent');
      });

      // The mirror image on the other tool: here the unbracketed second
      // mention comes *before* the kill (`openclaw gateway stop`), so the
      // gateway really did stop — and then the shell died, so Stop reported
      // failure with an empty message over a tool that was genuinely down.
      test('the openclaw stop command survives its own kill pattern', () async {
        final script =
            await lifecycleScriptFor(AiWorkspaceTool.openClaw, start: false);

        final answer = await _runProbeScript(
          '${killStubs}openclaw() { :; }; ',
          '$script; echo SURVIVED',
        );

        expect(answer.contains('SURVIVED'), true);
        expect(killedBy(answer), ['killed:4242']);
      });

      /// Runs the openclaw start command under real bash. [authConfigured]
      /// is what `openclaw config get gateway.auth` answers. Returns the
      /// script's output with the `openclaw`/`setsid` calls it made at the
      /// end, in order.
      Future<String> runOpenClawStart({required bool authConfigured}) async {
        final script =
            await lifecycleScriptFor(AiWorkspaceTool.openClaw, start: true);
        return _runProbeScript(
          // A throwaway HOME for the log and the call record. The port only
          // "listens" once setsid has launched something, so both the
          // wait-for-closed before the launch and the wait-for-open after it
          // are exercised for real. setsid runs in the background (`&`), so
          // the waits need real, if short, sleeps to see it land.
          'HOME=\$(mktemp -d); $killStubs'
              'sleep() { command sleep 0.05; }; '
              'openclaw() { echo "openclaw \$*" >> \$HOME/calls; '
              '[ "\$1 \$2 \$3" != "config get gateway.auth" ] '
              '|| ${authConfigured ? 'true' : 'false'}; }; '
              'setsid() { echo "setsid \$*" >> \$HOME/calls; }; '
              'ss() { grep -q setsid \$HOME/calls 2>/dev/null && '
              "echo 'LISTEN 0 4096 127.0.0.1:18789 0.0.0.0:*'; }; ",
          '$script && echo STARTED; echo SURVIVED; cat \$HOME/calls',
        );
      }

      List<String> callsIn(String answer) => answer
          .split('\n')
          .where((line) =>
              line.startsWith('openclaw ') || line.startsWith('setsid '))
          .toList();

      // The start names `openclaw` unbracketed several times around its
      // kill, so it needs the same guard as the others. It also has an
      // order: an onboarded unit has to let go of the port before this
      // gateway binds it, and the config has to be written before the
      // gateway reads it.
      test(
          'the openclaw start command survives its own kill, configures the '
          'gateway with a persisted token, then runs it', () async {
        if (await _hostPortIsOpen(18789)) {
          markTestSkipped('a real service holds 18789 on this machine, so the '
              'port waits cannot be exercised');
          return;
        }

        final answer = await runOpenClawStart(authConfigured: false);

        expect(answer.contains('SURVIVED'), true,
            reason: 'the kill must not signal the shell running it');
        expect(answer.contains('STARTED'), true,
            reason: 'the port came up, so the start has to report success');
        expect(killedBy(answer), ['killed:4242']);
        final calls = callsIn(answer);
        expect(calls, hasLength(6));
        expect(calls.sublist(0, 4), [
          'openclaw gateway stop',
          'openclaw config set gateway.mode local',
          'openclaw config get gateway.auth',
          'openclaw config set gateway.auth.mode token',
        ]);
        // Persisted, so dashboardCommand can read it back and it survives a
        // restart; random, so no two workspaces share one. 48 hex digits
        // behind a letter, which JSON5 cannot read as a number.
        expect(
            calls[4],
            matches(RegExp(
                r'^openclaw config set gateway\.auth\.token t[0-9a-f]{48}$')));
        expect(calls[5], 'setsid openclaw gateway run --port 18789');
      });

      // Onboarding, or the user, may have chosen password auth or a token of
      // their own; a Start button must not overwrite either.
      test('the openclaw start command leaves configured auth alone', () async {
        if (await _hostPortIsOpen(18789)) {
          markTestSkipped('a real service holds 18789 on this machine');
          return;
        }

        final answer = await runOpenClawStart(authConfigured: true);

        expect(answer.contains('STARTED'), true);
        expect(callsIn(answer), [
          'openclaw gateway stop',
          'openclaw config set gateway.mode local',
          'openclaw config get gateway.auth',
          'setsid openclaw gateway run --port 18789',
        ]);
      });

      test('the hermes stop command survives its own kill pattern', () async {
        final script =
            await lifecycleScriptFor(AiWorkspaceTool.hermesAgent, start: false);

        final answer = await _runProbeScript(
          killStubs,
          '$script; echo SURVIVED',
        );

        expect(answer.contains('SURVIVED'), true);
        expect(killedBy(answer), ['killed:4242']);
      });

      // Third tool, same trap: the start command names `opencode`
      // unbracketed three more times after the kill (`setsid opencode web`
      // and the log path), so a `pkill -f` here would take the shell down
      // before the server was ever launched.
      test('the opencode start command survives its own kill pattern',
          () async {
        final script =
            await lifecycleScriptFor(AiWorkspaceTool.openCode, start: true);

        final answer = await _runProbeScript(
          // A throwaway HOME: the command creates `\$HOME/.opencode` and
          // appends to a log there, and a test has no business writing to the
          // real one. `ss` answers so the port wait breaks on its first
          // iteration rather than making twenty real connect attempts.
          'HOME=\$(mktemp -d); $killStubs$noSleep'
              'setsid() { :; }; '
              "ss() { echo 'LISTEN 0 4096 127.0.0.1:4096 0.0.0.0:*'; }; ",
          '$script; echo SURVIVED',
        );

        expect(answer.contains('SURVIVED'), true,
            reason: 'the kill must not signal the shell running it');
        expect(killedBy(answer), ['killed:4242'],
            reason: 'only the server, never this shell or its parent');
      });

      // And the uninstall, where the unbracketed mentions are the `rm` paths
      // — the case that left OpenClaw's uninstall removing nothing at all.
      test('the opencode uninstall command survives its own kill pattern',
          () async {
        testShell.stdoutData = 'ai-workspace';
        await service.init();
        service.getState(AiWorkspaceTool.openCode)!.status =
            ToolStatus.stopped;
        testShell.stdoutData = '';
        await service.uninstall(AiWorkspaceTool.openCode);
        final script = testShell.allCommands
            .expand((cmd) => cmd)
            .lastWhere((arg) => arg.contains('rm -f /usr/local/bin/opencode'));

        final answer = await _runProbeScript(
          // Neither the real `rm` nor the real removal may run: this asserts
          // the script survives, not that it can delete the host's files.
          'HOME=\$(mktemp -d); ${killStubs}rm() { :; }; '
              'opencode() { :; }; ',
          '$script; echo SURVIVED',
        );

        expect(answer.contains('SURVIVED'), true);
        expect(killedBy(answer), ['killed:4242']);
      });

      // The same property without the safety net: `kill` is the real one here,
      // and `pgrep` hands the loop nothing but this shell's own pid and its
      // parent's. A filter that misses either really does take the script
      // down, which is precisely what the distro showed.
      test('the kill loop survives being handed its own pid', () async {
        final script =
            await lifecycleScriptFor(AiWorkspaceTool.hermesAgent, start: false);

        final answer = await _runProbeScript(
          'pgrep() { echo \$\$; echo \$PPID; }; ',
          '$script; echo SURVIVED',
        );

        expect(answer, 'SURVIVED');
      });
    },
        skip: _bash == null
            ? 'no bash available to run the probe scripts'
            : null);
  });
}

/// The macOS shape: [provision] only explains, so the automatic-setup switch
/// must not hide that explanation.
class _GuidanceOnlyRuntime extends WslWorkspaceRuntime {
  @override
  bool get provisionCreates => false;

  @override
  Future<bool> exists(ExecutionBroker broker) async => false;

  @override
  Future<void> provision(ExecutionBroker broker,
      {required void Function(String key) notify}) async {
    throw Exception('ai-workspace-vm-missing-text');
  }
}
