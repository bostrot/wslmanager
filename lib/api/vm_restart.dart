// Restarting a VM as one operation (bostrot/ai-tasks#108).
//
// The Apple backend could start a VM and it could stop one, but nothing put
// the two together, and the gap showed the moment the AI assistant met a VM
// that was up by the hypervisor's reckoning and unreachable by everyone
// else's: it could see the problem, name the remedy, and then had to ask the
// user to carry it out. Two reasons it could not do it itself.
//
// The first is that a stop is not instant. `vmctl stop` asks the guest to
// power down over ACPI and waits; a guest that is wedged — the very state a
// restart is for — never answers, the helper gives up with "retry with
// --force", and the app had no way to say that. So the polite request is
// followed by pulling the plug, but only once the VM is still there to pull
// it on: a stop that failed for any other reason is reported, not escalated.
//
// The second is that "stopped" and "gone" are not the same instant either.
// Starting a VM whose previous run is still releasing its disk is how you
// get two hypervisors on one image, so the restart waits for the VM to
// really leave the running list before it starts it again — and then waits
// for the DHCP lease, because a VM that comes back without one is exactly
// the failure that prompted the restart, and the caller should hear about it
// instead of being told everything is fine.
//
// Written over `AppleVmApi`'s public surface the way [VmResizeService] is:
// the helper path and store it exposes, plus its own start and lease calls.

import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';

/// A restart that could not be carried out; [message] is the helper's own
/// words where it had any.
class VmRestartException implements Exception {
  final String message;
  const VmRestartException(this.message);

  @override
  String toString() => message;
}

/// How a VM was brought down.
class VmStopResult {
  final String name;

  /// False when the VM was already stopped and nothing had to be done.
  final bool wasRunning;

  /// The guest did not answer the shutdown request and was powered off.
  final bool forced;

  const VmStopResult({
    required this.name,
    required this.wasRunning,
    required this.forced,
  });
}

/// What a restart did and what came back up.
class VmRestartResult {
  final String name;

  /// False when the VM was stopped to begin with — then this was a start.
  final bool wasRunning;

  /// The guest ignored the shutdown request and was powered off.
  final bool forced;

  /// It was started with its display window rather than headless.
  final bool gui;

  /// The address it holds now, or null when it has no lease (yet).
  final String? ip;

  /// Whether a lease was waited for at all; tells "no lease" apart from
  /// "nobody looked".
  final bool waitedForIp;

  const VmRestartResult({
    required this.name,
    required this.wasRunning,
    required this.forced,
    required this.gui,
    required this.ip,
    required this.waitedForIp,
  });
}

/// Stops and restarts a VM through `vmctl`.
class VmRestartService {
  final AppleVmApi api;

  /// How long the VM may take to leave the running list after a successful
  /// stop. The helper already waits for its daemon to exit, so this only
  /// covers the tail of that — and turns a helper that lies about it into an
  /// error rather than a second hypervisor on the same disk.
  final Duration stopTimeout;

  /// How long to wait for a DHCP lease after the start before reporting the
  /// VM as up but address-less.
  final Duration leaseTimeout;

  /// Gap between two state probes.
  final Duration pollInterval;

  VmRestartService(
    this.api, {
    Duration? stopTimeout,
    Duration? leaseTimeout,
    Duration? pollInterval,
  })  : stopTimeout = stopTimeout ?? const Duration(seconds: 60),
        leaseTimeout = leaseTimeout ?? const Duration(seconds: 60),
        pollInterval = pollInterval ?? const Duration(seconds: 2);

  /// Whether [api] is a backend this service knows how to drive. A WSL
  /// distro has no lifetime of its own to restart: `wsl --terminate` ends it
  /// and the next command in it starts it again.
  static bool isSupported(VmBackend api) => api is AppleVmApi;

  /// Stops [name], powering the guest off when it ignores the shutdown
  /// request and [force] allows it.
  ///
  /// Throws [VmRestartException] when there is no such VM, when the stop
  /// failed for a reason forcing cannot fix, or when the guest is still
  /// running after a forced stop.
  Future<VmStopResult> stop(String name, {bool force = true}) async {
    final vm = await _require(name);
    if (!vm.running) {
      return VmStopResult(name: name, wasRunning: false, forced: false);
    }
    final forced = await _stop(name, allowForce: force);
    await _awaitStopped(name);
    return VmStopResult(name: name, wasRunning: true, forced: forced);
  }

  /// Stops [name] if it is running, waits until it really is, then starts it
  /// again — headless unless [gui] asks for the display window.
  ///
  /// With [waitForIp] the result carries the address the guest picked up, or
  /// null when it had none by [leaseTimeout]; a guest that comes back without
  /// a lease is unreachable, which is worth saying.
  Future<VmRestartResult> restart(
    String name, {
    bool gui = false,
    bool waitForIp = true,
  }) async {
    final stopped = await stop(name);
    try {
      if (gui) {
        await api.start(name);
      } else {
        await api.startHeadless(name);
      }
    } on AppleVmException catch (error) {
      throw VmRestartException(error.toString());
    }
    final ip = waitForIp ? await _awaitLease(name) : null;
    return VmRestartResult(
      name: name,
      wasRunning: stopped.wasRunning,
      forced: stopped.forced,
      gui: gui,
      ip: ip,
      waitedForIp: waitForIp,
    );
  }

  Future<AppleVmInfo> _require(String name) async {
    final AppleVmInfo? vm;
    try {
      vm = await api.vmInfo(name);
    } on AppleVmException catch (error) {
      throw VmRestartException(error.toString());
    }
    if (vm == null) throw VmRestartException('No VM named "$name".');
    return vm;
  }

  /// Returns true when the guest had to be powered off.
  Future<bool> _stop(String name, {required bool allowForce}) async {
    try {
      await _runHelper(['stop', '--name', name]);
      return false;
    } on VmRestartException catch (error) {
      // Whether forcing is the answer is a question about the VM, not about
      // the wording of the complaint: a stop that failed and left nothing
      // running did its job, and one that failed with the guest still up is
      // the wedged guest --force exists for.
      if (!await _isRunning(name)) return false;
      if (!allowForce) rethrow;
      try {
        await _runHelper(['stop', '--name', name, '--force']);
      } on VmRestartException catch (forceError) {
        throw VmRestartException('$name would not stop: ${error.message} '
            'Powering it off failed too: ${forceError.message}');
      }
      return true;
    }
  }

  Future<void> _awaitStopped(String name) async {
    final deadline = DateTime.now().add(stopTimeout);
    while (true) {
      if (!await _isRunning(name)) return;
      if (!DateTime.now().isBefore(deadline)) {
        throw VmRestartException(
            '$name is still running ${stopTimeout.inSeconds}s after it was '
            'stopped; starting it again now would run two hypervisors on one '
            'disk.');
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// The lease the guest holds, or null when it has none by [leaseTimeout].
  Future<String?> _awaitLease(String name) async {
    final deadline = DateTime.now().add(leaseTimeout);
    while (true) {
      final ip = await api.guestIp(name);
      if (ip != null && ip.isNotEmpty) return ip;
      if (!DateTime.now().isBefore(deadline)) return null;
      await Future<void>.delayed(pollInterval);
    }
  }

  /// State probe that never decides the question by failing: a helper call
  /// that did not answer is not evidence the VM went away.
  Future<bool> _isRunning(String name) async {
    try {
      final vm = await api.vmInfo(name);
      return vm?.running ?? false;
    } on AppleVmException {
      return true;
    }
  }

  Future<void> _runHelper(List<String> args) async {
    final ProcessResult result;
    try {
      result = await api.shell.run(
        api.helperPath(),
        ['--store', api.storeDir, ...args],
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (e) {
      throw VmRestartException(
          'Could not run the vmctl helper (${api.helperPath()}): ${e.message}');
    }
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw VmRestartException(stderr.isNotEmpty
          ? stderr
          : 'vmctl ${args.join(' ')} failed with exit code ${result.exitCode}');
    }
  }
}
