import 'package:localization/localization.dart';

import '../../components/notify.dart';
import '../apple/apple_vm_api.dart';
import '../apple/vm_image_catalog.dart';
import '../execution/broker.dart';
import '../execution/models.dart';
import '../vm/vm_platform.dart';
import '../wsl_args.dart';

/// Where the AI Workspace runs its tools.
///
/// On Windows that is a dedicated WSL distro driven by `wsl.exe`; on macOS a
/// dedicated Linux VM driven over SSH by the `vmctl` helper. The service
/// builds every in-environment command through this, so the tool scripts
/// themselves stay backend-agnostic.
abstract class WorkspaceRuntime {
  /// Human-readable name of the environment, for status messages.
  String get target;

  /// One-shot root command carrying [shellCommand] as a single `sh -c`
  /// argument.
  ExecutionRequest script(String shellCommand, {Duration? timeout});

  /// A session held open so tools survive between one-shot calls. Null when
  /// the environment keeps services alive on its own (a VM does; WSL tears a
  /// distro down once its last session exits).
  ExecutionRequest? keepAlive();

  /// Whether a service bound to the environment's loopback already answers on
  /// this machine's loopback, at the same port.
  ///
  /// Every tool here binds 127.0.0.1 inside the environment. Under WSL the
  /// relay makes that Windows' localhost too. A backend that runs the
  /// workspace in a VM of its own shares no loopback with the host, so each
  /// port needs a [portForward] to be reached at all.
  bool get sharesLoopback;

  /// Long-running command that carries `127.0.0.1:remotePort` inside the
  /// environment to `127.0.0.1:localPort` on this machine. It runs until it
  /// is killed or its stdin closes. Only asked for when [sharesLoopback] is
  /// false.
  ExecutionRequest portForward({
    required int remotePort,
    required int localPort,
  });

  /// The machine running this app, named for error messages — the dashboard
  /// that "is not reachable" is not reachable from here.
  String get hostName;

  /// Whether the environment is already provisioned.
  Future<bool> exists(ExecutionBroker broker);

  /// Whether [provision] really creates the environment, rather than only
  /// explaining why it cannot. Only those runtimes honour
  /// `AiWorkspaceService.autoProvision`.
  bool get provisionCreates => true;

  /// Provision the environment, or throw with guidance when it cannot be
  /// created automatically.
  Future<void> provision(ExecutionBroker broker,
      {required void Function(String key) notify});

  /// The explicit, user-confirmed setup — allowed to do heavy work
  /// (downloads, VM creation) that [provision] must not start unasked.
  /// Backends whose provision is already cheap just reuse it.
  Future<void> setUp(ExecutionBroker broker,
          {required void Function(String key) notify}) =>
      provision(broker, notify: notify);
}

/// Picks the runtime for the active backend. Replaced by tests.
WorkspaceRuntime Function() workspaceRuntimeBuilder =
    defaultWorkspaceRuntime;

WorkspaceRuntime defaultWorkspaceRuntime() {
  final backend = vmBackend();
  if (backend is AppleVmApi) {
    return AppleWorkspaceRuntime(backend);
  }
  return WslWorkspaceRuntime();
}

/// The dedicated WSL distro the workspace has always used.
class WslWorkspaceRuntime extends WorkspaceRuntime {
  static const String distro = 'ai-workspace';

  @override
  String get target => distro;

  @override
  ExecutionRequest script(String shellCommand, {Duration? timeout}) =>
      ExecutionRequest(
        command: 'wsl',
        arguments: wslShellArgs(distro, shellCommand, user: 'root'),
        timeout: timeout ?? const Duration(minutes: 5),
      );

  @override
  ExecutionRequest? keepAlive() => ExecutionRequest(
        command: 'wsl',
        arguments: ['-d', distro, '-u', 'root', 'sleep', 'infinity'],
      );

  // WSL relays Windows' loopback into the distro's, so a service bound to
  // 127.0.0.1 in there answers on Windows' own localhost. Nothing to forward.
  @override
  bool get sharesLoopback => true;

  @override
  ExecutionRequest portForward({
    required int remotePort,
    required int localPort,
  }) =>
      throw UnsupportedError('WSL relays the loopback itself');

  @override
  String get hostName => 'Windows';

  @override
  Future<bool> exists(ExecutionBroker broker) async {
    final result = await broker.run(ExecutionRequest(
      command: 'wsl',
      arguments: ['--list', '--quiet'],
      timeout: const Duration(seconds: 10),
    ));
    if (!result.isSuccess) return false;
    return result.stdout
        .split('\n')
        .map((s) => s.trim())
        .contains(distro);
  }

  @override
  Future<void> provision(ExecutionBroker broker,
      {required void Function(String key) notify}) async {
    notify('ai-workspace-preparing-text');
    final install = await broker.run(ExecutionRequest(
      command: 'wsl',
      arguments: ['--install', 'Ubuntu', '--name', distro],
      timeout: const Duration(minutes: 10),
    ));
    // `wsl --install` exits non-zero even when it registered the distro (it
    // also tries an interactive first-boot with no console here), so trust
    // the registry, not the exit code.
    if (install.isSuccess || await exists(broker)) return;
    final detail = [install.stderr, install.stdout]
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => 'no output from wsl');
    throw Exception('Failed to create the AI workspace distro: $detail');
  }
}

/// A dedicated Linux VM on the Apple backend, reached over SSH via `vmctl
/// exec`.
///
/// Unlike WSL, a bootable guest cannot be conjured from nothing — it needs an
/// installed, running Linux VM — so [provision] requires one named
/// [vmName] to exist and be running, and explains how to make it when it is
/// not. Once it is up, the tool scripts run in it exactly as they do in the
/// WSL distro (they assume a Debian/Ubuntu userland with apt).
class AppleWorkspaceRuntime extends WorkspaceRuntime {
  AppleWorkspaceRuntime(this._api);

  static const String vmName = 'ai-workspace';
  final AppleVmApi _api;

  @override
  String get target => vmName;

  List<String> _execArgs(String shellCommand) => [
        '--store',
        _api.storeDir,
        'exec',
        '--name',
        vmName,
        '--user',
        'root',
        '--',
        shellCommand,
      ];

  @override
  ExecutionRequest script(String shellCommand, {Duration? timeout}) =>
      ExecutionRequest(
        command: _api.helperPath(),
        arguments: _execArgs(shellCommand),
        timeout: timeout ?? const Duration(minutes: 5),
      );

  // A running VM keeps its services alive on its own — no held session
  // needed.
  @override
  ExecutionRequest? keepAlive() => null;

  /// The guest is a VM on macOS' own vmnet NAT with no loopback relay of any
  /// kind: the Mac's `localhost` is the Mac. That is what made "Dashboard URL
  /// not reachable from Windows: http://localhost:4096" the standing answer
  /// for a perfectly healthy OpenCode on macOS (bostrot/ai-tasks#70).
  ///
  /// Dialling the guest's own address instead was tried and is not enough.
  /// It needs every tool to bind all interfaces, which puts OpenCode's
  /// unauthenticated server on vmnet. It also misses any server started
  /// before the bind changed. And OpenClaw's Control UI refuses to pair over
  /// plain HTTP from a non-loopback origin whatever the token. So ports are
  /// forwarded over the SSH connection the runtime already uses, loopback
  /// to loopback.
  @override
  bool get sharesLoopback => false;

  /// `vmctl forward`, as root like every other call into the guest: that is
  /// the account the store key is known to reach.
  @override
  ExecutionRequest portForward({
    required int remotePort,
    required int localPort,
  }) =>
      ExecutionRequest(
        command: _api.helperPath(),
        arguments: [
          '--store',
          _api.storeDir,
          'forward',
          '--name',
          vmName,
          '--user',
          'root',
          '--port',
          '$remotePort',
          '--local-port',
          '$localPort',
        ],
      );

  @override
  String get hostName => 'macOS';

  /// Remembers the last reachability answer. [exists] is consulted on every
  /// visit to the page, and an unreachable guest costs the probe's full
  /// timeout each time, so the answer is reused briefly rather than paid for
  /// again on the next rebuild.
  static DateTime? _probedAt;
  static bool _probeResult = false;
  static const Duration _probeTtl = Duration(seconds: 30);

  static void resetProbeCache() {
    _probedAt = null;
    _probeResult = false;
  }

  /// How long one SSH probe may take before the guest counts as silent.
  ///
  /// `vmctl exec` itself waits up to 20s for a DHCP lease and ssh another
  /// 10s to connect, so the old 3s budget killed the helper before it could
  /// even fail properly: a guest that was merely slow to answer, and one
  /// whose lease had lapsed, both surfaced as "set the workspace up" while
  /// the Home screen showed the VM running. Fifteen seconds is what the
  /// guided setup already waits per probe.
  static const Duration probeTimeout = Duration(seconds: 15);

  /// A running VM whose guest never answers is not a usable workspace, so
  /// reachability is part of existing here. Without that the page sailed
  /// past provisioning and failed several steps later inside a tool install,
  /// reporting "no DHCP lease" from the bottom of a Docker script.
  @override
  Future<bool> exists(ExecutionBroker broker) async {
    final AppleVmInfo? vm;
    try {
      vm = await _api.vmInfo(vmName);
    } catch (_) {
      return false;
    }
    if (vm == null || !vm.running) return false;

    final probedAt = _probedAt;
    if (probedAt != null && DateTime.now().difference(probedAt) < _probeTtl) {
      return _probeResult;
    }
    // A probe the broker had to kill comes back as a failed result like any
    // other, and is cached the same way; otherwise a silent guest is
    // re-dialled on every rebuild for the full timeout each time.
    final probe = await broker.run(script('true', timeout: probeTimeout));
    _probedAt = DateTime.now();
    _probeResult = probe.isSuccess;
    return _probeResult;
  }

  @override
  bool get provisionCreates => false;

  @override
  Future<void> provision(ExecutionBroker broker,
      {required void Function(String key) notify}) async {
    final vm = await _api.vmInfo(vmName);
    if (vm == null) {
      throw Exception('ai-workspace-vm-missing-text');
    }
    if (!vm.running) {
      throw Exception('ai-workspace-vm-stopped-text');
    }
    // Running but unreachable: the guided setup can repair it.
    throw Exception('ai-workspace-vm-unreachable-text');
  }

  /// Delay between SSH reachability probes after starting the VM.
  /// Injectable so tests do not sit through a boot's worth of sleeps.
  Duration setUpRetryDelay = const Duration(seconds: 3);

  /// Probes a guest gets after this code booted it: a first boot runs
  /// cloud-init end to end before sshd is up, so this is generous.
  static const int bootProbeAttempts = 40;

  /// Probes a guest gets when it was already running before setup began.
  /// Such a guest has had its boot; if it still does not answer after a few
  /// tries it is not going to (a lapsed lease, a frozen guest, a seed with
  /// no network config), and the user who pressed the button is better
  /// served by the repair than by ten minutes of silence first.
  static const int runningProbeAttempts = 4;

  /// The one-click path the AI Workspace page offers when the VM is absent:
  /// download the Debian cloud image (reused from the ISO cache when
  /// present), create the VM seeded from it, start it headless, and wait
  /// until the guest answers over SSH — cloud-init needs a first boot to
  /// create the user and install the store key.
  @override
  Future<void> setUp(ExecutionBroker broker,
      {required void Function(String key) notify}) async {
    var vm = await _api.vmInfo(vmName);
    // Whether this call is the one bringing the guest up, which decides how
    // long to wait for it before treating silence as a fault.
    var booted = false;
    if (vm == null) {
      final entry = VmImageCatalog.entryById('debian-13-cloud');
      if (entry == null) {
        throw Exception('ai-workspace-vm-missing-text');
      }
      Notify.message('ai-workspace-downloading-text'.i18n(), loading: true);
      final image = await vmImageCatalogBuilder().download(entry,
          onProgress: (received, total) {
        if (total > 0) {
          Notify.message(
              '${'ai-workspace-downloading-text'.i18n()} '
              '${(received / total * 100).toStringAsFixed(0)}%',
              loading: true);
        }
      });
      notify('ai-workspace-preparing-text');
      await _api.createLinuxVm(vmName,
          imagePath: image, diskSizeGb: 32, cpus: 2, memoryGb: 4);
      vm = await _api.vmInfo(vmName);
    }
    if (vm != null && !vm.running) {
      notify('ai-workspace-starting-vm-text');
      await _api.startHeadless(vmName);
      booted = true;
    }
    if (await _waitForGuest(broker,
        attempts: booted ? bootProbeAttempts : runningProbeAttempts)) {
      resetProbeCache();
      return;
    }

    // Still nothing. VMs created by older builds carry a seed with no
    // network config, so their DHCP client asks in a way macOS never
    // answers and they can never be reached; a guest that has since lost
    // its address or frozen looks the same from here. Rewrite the seed and
    // reboot — repairing in place rather than throwing the disk away.
    notify('ai-workspace-repairing-text');
    resetProbeCache();
    await _api.reseed(vmName);
    await _api.stop(vmName);
    await Future<void>.delayed(setUpRetryDelay);
    await _api.startHeadless(vmName);
    if (await _waitForGuest(broker, attempts: bootProbeAttempts)) return;

    throw Exception('ai-workspace-vm-unreachable-text');
  }

  Future<bool> _waitForGuest(ExecutionBroker broker,
      {required int attempts}) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      final probe = await broker.run(script('true', timeout: probeTimeout));
      if (probe.isSuccess) return true;
      await Future<void>.delayed(setUpRetryDelay);
    }
    return false;
  }
}
