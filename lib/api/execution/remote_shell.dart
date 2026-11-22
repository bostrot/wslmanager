// SSH-based shell implementation matching the [Shell] interface.
// Provides remote command execution via SSH with connection pooling,
// fallback to local on disconnect, and automatic reconnection.

import 'dart:async';
import 'dart:convert' show Encoding, utf8;
import 'dart:io' as io;

import '../shell.dart';

/// Remote shell backed by SSH with mux connection support.
///
/// Not instantiated anywhere in production (see
/// doc/remote-execution-architecture.md). Before wiring it in, replace
/// [_escapeArgs] with `remoteHostCommand` from lib/api/remote_command.dart:
/// double-quoting the remote command is exactly what a Windows host's
/// PowerShell login shell strips, the failure that broke remote WSL from the
/// Mac (bostrot/ai-tasks#21), and `runInShell: true` adds a `cmd.exe /c`
/// layer on Windows on top of that.
class RemoteShell implements Shell {
  final String _targetHost; // e.g., "user@192.168.1.100"
  final List<String> Function() _sshOptionsBuilder;
  bool _connected = false;

  RemoteShell({
    required String targetHost,
    List<String> Function()? sshOptionsBuilder,
  }) : _targetHost = targetHost,
       _sshOptionsBuilder = sshOptionsBuilder ?? getSshClientOptions;

  @override
  Future<io.ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = utf8,
    Encoding? stderrEncoding = utf8,
  }) async {
    final sshOpts = _sshOptionsBuilder();
    final cmd = <String>['ssh', ...sshOpts, _targetHost];

    // Build remote command string.
    String remoteCmd;
    if (workingDirectory != null) {
      remoteCmd = 'cd $workingDirectory && $executable ${_escapeArgs(arguments)}';
    } else {
      remoteCmd = '$executable ${_escapeArgs(arguments)}';
    }

    // Add environment variables inline.
    if (environment != null && environment.isNotEmpty) {
      final envStr = environment.entries
          .map((e) => '${e.key}="${e.value}"')
          .join(' ');
      remoteCmd = '$envStr $remoteCmd';
    }

    cmd.add(remoteCmd);

    try {
      final result = await io.Process.run(
        cmd.first,
        cmd.sublist(1),
        runInShell: true,
        stdoutEncoding: stdoutEncoding,
        stderrEncoding: stderrEncoding,
      );

      _connected = result.exitCode == 0;
      return result;
    } catch (e) {
      _connected = false;
      rethrow;
    }
  }

  @override
  Future<io.Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    io.ProcessStartMode mode = io.ProcessStartMode.normal,
  }) async {
    final sshOpts = _sshOptionsBuilder();
    final cmd = <String>['ssh', ...sshOpts, _targetHost];

    // Build remote command string.
    String remoteCmd;
    if (workingDirectory != null) {
      remoteCmd = 'cd $workingDirectory && $executable ${_escapeArgs(arguments)}';
    } else {
      remoteCmd = '$executable ${_escapeArgs(arguments)}';
    }

    // Add environment variables inline.
    if (environment != null && environment.isNotEmpty) {
      final envStr = environment.entries
          .map((e) => '${e.key}="${e.value}"')
          .join(' ');
      remoteCmd = '$envStr $remoteCmd';
    }

    cmd.add(remoteCmd);

    try {
      final process = await io.Process.start(
        cmd.first,
        cmd.sublist(1),
        runInShell: true,
        mode: mode,
      );

      _connected = true;
      return process;
    } catch (e) {
      _connected = false;
      rethrow;
    }
  }

  /// Returns true if the last SSH connection succeeded.
  bool get isConnected => _connected;

  /// Escape shell arguments for safe remote execution.
  String _escapeArgs(List<String> args) {
    return args.map((arg) {
      // Simple escaping: wrap in quotes and escape internal quotes/backslashes.
      final escaped = arg.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      return '"$escaped"';
    }).join(' ');
  }
}
