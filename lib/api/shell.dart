import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:wsl2distromanager/api/process_reaper.dart';
import 'package:wsl2distromanager/api/remote_command.dart';

/// Shared SSH client options for remote WSL connections.
List<String> getSshClientOptions() {
  final tmpDir = Directory.systemTemp.path;
  final controlPath = p.join(tmpDir, 'wsl2dm_ssh_mux.sock');
  return <String>[
    '-o',
    'BatchMode=yes',
    '-o',
    'PasswordAuthentication=no',
    '-o',
    'KbdInteractiveAuthentication=no',
    '-o',
    'ControlMaster=auto',
    '-o',
    'ControlPersist=10m',
    '-o',
    'ControlPath=$controlPath',
    '-o',
    'ServerAliveInterval=30',
    '-o',
    'ServerAliveCountMax=3',
  ];
}

/// The full `ssh` argument list that runs [executable] with [args] on the
/// remote Windows host [target] — `ssh <options> [-tt] -- <target> <command>`.
///
/// ssh's own options and the target stay raw (the local ssh consumes them);
/// the command goes through [remoteHostCommand], which is what keeps it whole
/// across the host's login shell. `WSLApi` and `MountService` both build
/// their remote calls here so an ssh-level change lands in one place.
List<String> sshRemoteCommand(
  String target,
  String executable,
  List<String> args, {
  bool allocateTty = false,
}) {
  return <String>[
    ...getSshClientOptions(),
    if (allocateTty) '-tt',
    '--',
    target,
    ...remoteHostCommand(executable, args),
  ];
}

/// The full `ssh` argument list that runs the PowerShell [script] itself on
/// [target]; see [remotePowerShellScript] for the failure contract.
List<String> sshRemotePowerShell(String target, String script) {
  return <String>[
    ...getSshClientOptions(),
    '--',
    target,
    ...remotePowerShellScript(script),
  ];
}

/// Interface for shell operations to allow mocking
abstract class Shell {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  });

  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  });
}

/// Default implementation using dart:io Process
class ProcessShell implements Shell {
  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

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
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
    // Tie the child to the app job so a force-kill of the app takes it down
    // too — best-effort, never throws, no-op off Windows.
    ProcessReaper.instance.adopt(process.pid);
    return process;
  }
}
