import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' show InfoBarSeverity;
import 'package:wsl2distromanager/api/ai_workspace/runtime.dart';
import 'package:wsl2distromanager/api/apple/vm_image_catalog.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_vmctl_shell.dart';
import 'mocks.dart';

/// The AI Workspace runs its tools in a WSL distro on Windows and a Linux VM
/// on macOS; the runtime is what keeps the tool scripts backend-agnostic.
/// A catalog whose download is a fixed local file — no network.
class _FixedDownloadCatalog implements VmImageCatalog {
  _FixedDownloadCatalog(this.path);
  final String path;
  int downloads = 0;

  @override
  Future<String> download(VmIsoCatalogEntry entry,
      {void Function(int, int)? onProgress,
      CancelSignal? cancelSignal}) async {
    downloads++;
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Every `exec` fails with the timeout the broker reports for a helper it
/// had to kill — the shape of a probe stuck behind a dead address.
/// Everything else answers like [FakeVmctlShell].
class _HangingExecShell extends FakeVmctlShell {
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    if (arguments.contains('exec')) {
      calls.add(['start:$executable', ...arguments]);
      throw TimeoutException('probe killed', const Duration(seconds: 15));
    }
    return super.start(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
        mode: mode);
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
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
    workspaceRuntimeBuilder = defaultWorkspaceRuntime;
    AppleWorkspaceRuntime.resetProbeCache();
  });

  group('runtime selection', () {
    test('the WSL backend gets the WSL runtime', () {
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      expect(defaultWorkspaceRuntime(), isA<WslWorkspaceRuntime>());
    });

    test('the Apple backend gets the VM runtime', () {
      vmBackendBuilder = () => AppleVmApi(
          shell: FakeVmctlShell(),
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/rt-test');
      expect(defaultWorkspaceRuntime(), isA<AppleWorkspaceRuntime>());
    });
  });

  group('WSL runtime', () {
    final runtime = WslWorkspaceRuntime();

    test('scripts run as root in the dedicated distro via wsl.exe', () {
      final req = runtime.script('echo hi');
      expect(req.command, 'wsl');
      expect(req.arguments, containsAll([WslWorkspaceRuntime.distro, 'root']));
      // The single-argument shell payload survives (--exec, no re-parse).
      expect(req.arguments.join(' '), contains('echo hi'));
    });

    test('a distro keeps no services alive on its own, so it holds a session',
        () {
      expect(runtime.keepAlive(), isNotNull);
    });

    // WSL relays Windows' loopback into the distro's, so a service bound to
    // 127.0.0.1 in there is already on Windows' localhost.
    test('the distro shares the host\'s loopback, so nothing is forwarded',
        () {
      expect(runtime.sharesLoopback, isTrue);
      expect(runtime.hostName, 'Windows');
      expect(() => runtime.portForward(remotePort: 4096, localPort: 4096),
          throwsUnsupportedError);
    });
  });

  group('Apple runtime', () {
    AppleWorkspaceRuntime buildRuntime(FakeVmctlShell shell) =>
        AppleWorkspaceRuntime(AppleVmApi(
            shell: shell,
            helperPathOverride: '/fake/vmctl',
            storeDirOverride: '/tmp/rt-test'));

    test('scripts run through vmctl exec against the workspace VM', () {
      final runtime = buildRuntime(FakeVmctlShell());
      final req = runtime.script('echo hi');
      expect(req.command, '/fake/vmctl');
      expect(
          req.arguments,
          containsAllInOrder(
              ['exec', '--name', AppleWorkspaceRuntime.vmName]));
      // The command is one argument past `--`, never re-split.
      final sep = req.arguments.indexOf('--');
      expect(req.arguments.sublist(sep + 1), ['echo hi']);
    });

    test('a running VM keeps its own services, so no held session', () {
      expect(buildRuntime(FakeVmctlShell()).keepAlive(), isNull);
    });

    // A VM on macOS' vmnet NAT shares no loopback with the Mac, which is what
    // put "not reachable from Windows: http://localhost:4096" on a healthy
    // OpenCode card (bostrot/ai-tasks#70). The port is carried out over the
    // SSH the runtime already uses, so the tool keeps its loopback bind.
    test('ports are forwarded over vmctl, loopback to loopback', () {
      final runtime = buildRuntime(FakeVmctlShell());
      expect(runtime.sharesLoopback, isFalse);
      expect(runtime.hostName, 'macOS');

      final req = runtime.portForward(remotePort: 4096, localPort: 50123);

      expect(req.command, '/fake/vmctl');
      expect(
          req.arguments,
          containsAllInOrder([
            '--store',
            '/tmp/rt-test',
            'forward',
            '--name',
            AppleWorkspaceRuntime.vmName,
          ]));
      // The workspace port and the local one are separate: only the local
      // one moves when the Mac already has something on it.
      expect(req.arguments.sublist(req.arguments.indexOf('--port')),
          ['--port', '4096', '--local-port', '50123']);
    });

    test('a running VM that never answers is repaired, not abandoned',
        () async {
      final shell = FakeVmctlShell();
      final broker = ExecutionBroker(shell: shell);
      final runtime = buildRuntime(shell)..setUpRetryDelay = Duration.zero;
      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"running"}]}';
      // Unreachable until the seed is rewritten, then fine.
      shell.exitCodes['exec'] = 255;
      var reseeded = false;
      shell.onCommand = (command) {
        if (command == 'reseed') {
          reseeded = true;
          shell.exitCodes['exec'] = 0;
        }
      };

      await runtime.setUp(broker, notify: (_) {});

      expect(reseeded, isTrue, reason: 'the stale seed must be rewritten');
      expect(shell.calls.any((c) => c.contains('reseed')), isTrue);
      expect(shell.calls.any((c) => c.contains('start')), isTrue,
          reason: 'the guest has to reboot to pick the new seed up');
      // The VM had been running before setup began, so the user who pressed
      // the button is not kept waiting through a first boot's worth of
      // probes before the repair starts.
      final reseedAt = shell.calls.indexWhere((c) => c.contains('reseed'));
      final probesBefore = shell.calls
          .sublist(0, reseedAt)
          .where((c) => c.contains('exec'))
          .length;
      expect(probesBefore, AppleWorkspaceRuntime.runningProbeAttempts);
      expect(probesBefore,
          lessThan(AppleWorkspaceRuntime.bootProbeAttempts));
    });

    test('a VM setUp booted itself gets a full boot before any repair',
        () async {
      final shell = FakeVmctlShell();
      final broker = ExecutionBroker(shell: shell);
      final runtime = buildRuntime(shell)..setUpRetryDelay = Duration.zero;
      shell.responseQueue['list'] = [
        '{"vms":[{"name":"ai-workspace","state":"stopped"}]}',
      ];
      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"running"}]}';
      // cloud-init takes its time on a first boot: silent for a while,
      // then fine — well past the patience a long-running guest gets.
      final silent = AppleWorkspaceRuntime.runningProbeAttempts * 3;
      shell.exitCodeQueue['exec'] = List<int>.filled(silent, 255, growable: true);
      shell.exitCodes['exec'] = 0;

      await runtime.setUp(broker, notify: (_) {});

      expect(shell.calls.any((c) => c.contains('reseed')), isFalse,
          reason: 'a guest still booting is not broken');
      expect(shell.calls.where((c) => c.contains('exec')).length, silent + 1);
    });

    test('a probe the broker had to kill counts as silent, and is cached',
        () async {
      final shell = _HangingExecShell();
      final broker = ExecutionBroker(shell: shell);
      final runtime = buildRuntime(shell);
      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"running"}]}';

      expect(await runtime.exists(broker), isFalse);
      expect(await runtime.exists(broker), isFalse);
      // One dial, not one per rebuild: the second answer came from the cache.
      expect(shell.calls.where((c) => c.contains('exec')).length, 1);
    });

    test('the probe outlives the helper\'s own lease and connect waits', () {
      // vmctl exec blocks up to 20s on the lease table and ssh up to 10s
      // on connect; a budget below that killed the helper before it could
      // even report why the guest was silent.
      expect(AppleWorkspaceRuntime.probeTimeout,
          greaterThanOrEqualTo(const Duration(seconds: 15)));
    });

    test('exists is true only for a running workspace VM', () async {
      final shell = FakeVmctlShell();
      // The same fake the runtime drives: exists() probes through the broker.
      final broker = ExecutionBroker(shell: shell);
      shell.responses['list'] = '{"vms":[]}';
      expect(await buildRuntime(shell).exists(broker), isFalse);

      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"stopped"}]}';
      expect(await buildRuntime(shell).exists(broker), isFalse);

      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"running"}]}';
      shell.responses['exec'] = 'ok';
      expect(await buildRuntime(shell).exists(broker), isTrue);

      // Running but unreachable is not "exists": the page must not sail on
      // and fail inside a tool install.
      AppleWorkspaceRuntime.resetProbeCache();
      shell.exitCodes['exec'] = 255;
      expect(await buildRuntime(shell).exists(broker), isFalse);
    });

    test('guided setUp on a missing VM downloads, creates, boots and waits',
        () async {
      final shell = FakeVmctlShell();
      final broker = ExecutionBroker(shell: shell);
      final runtime = buildRuntime(shell)..setUpRetryDelay = Duration.zero;
      final dir = Directory.systemTemp.createTempSync('ws-setup-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final image = File('${dir.path}/debian.raw')..writeAsBytesSync([1]);
      final catalog = _FixedDownloadCatalog(image.path);
      vmImageCatalogBuilder = () => catalog;
      addTearDown(() => vmImageCatalogBuilder = () => VmImageCatalog());

      shell.responseQueue['list'] = [
        '{"vms":[]}',
        '{"vms":[{"name":"ai-workspace","state":"stopped"}]}',
      ];
      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"running"}]}';
      shell.responses['exec'] = 'ok';

      await runtime.setUp(broker, notify: (_) {});

      expect(catalog.downloads, 1);
      final create = shell.calls.firstWhere((c) => c.contains('create'));
      expect(create, contains('--image'));
      expect(create[create.indexOf('--image') + 1], image.path);
      expect(shell.calls.any((c) => c.contains('start')), isTrue);
      expect(shell.calls.any((c) => c.contains('exec')), isTrue,
          reason: 'setup must verify the guest answers over SSH');
    });

    test('guided setUp on a stopped VM only boots it', () async {
      final shell = FakeVmctlShell();
      final broker = ExecutionBroker(shell: shell);
      final runtime = buildRuntime(shell)..setUpRetryDelay = Duration.zero;
      shell.responseQueue['list'] = [
        '{"vms":[{"name":"ai-workspace","state":"stopped"}]}',
      ];
      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"running"}]}';
      shell.responses['exec'] = 'ok';

      await runtime.setUp(broker, notify: (_) {});

      expect(shell.calls.any((c) => c.contains('create')), isFalse);
      expect(shell.calls.any((c) => c.contains('start')), isTrue);
    });

    test('a guest that never answers is a clear error, not a hang', () async {
      final shell = FakeVmctlShell();
      final broker = ExecutionBroker(shell: shell);
      final runtime = buildRuntime(shell)..setUpRetryDelay = Duration.zero;
      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"running"}]}';
      shell.exitCodes['exec'] = 255;

      await expectLater(
          runtime.setUp(broker, notify: (_) {}),
          throwsA(predicate((e) =>
              e.toString().contains('ai-workspace-vm-unreachable-text'))));
    });

    test('provision explains a missing or stopped VM instead of conjuring one',
        () async {
      final shell = FakeVmctlShell();
      final broker = ExecutionBroker(shell: MockShell());
      void noop(String key) {}

      shell.responses['list'] = '{"vms":[]}';
      await expectLater(
          buildRuntime(shell).provision(broker, notify: noop),
          throwsA(predicate(
              (e) => e.toString().contains('ai-workspace-vm-missing-text'))));

      shell.responses['list'] =
          '{"vms":[{"name":"ai-workspace","state":"stopped"}]}';
      await expectLater(
          buildRuntime(shell).provision(broker, notify: noop),
          throwsA(predicate(
              (e) => e.toString().contains('ai-workspace-vm-stopped-text'))));
    });
  });
}
