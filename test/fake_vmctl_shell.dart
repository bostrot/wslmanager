import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/shell.dart';

import 'mocks.dart' show MockProcess;

/// Scripted vmctl: answers by subcommand and records every invocation.
class FakeVmctlShell implements Shell {
  final List<List<String>> calls = [];
  final Map<String, String> responses = {};
  final Map<String, int> exitCodes = {};
  final Map<String, String> errors = {};

  /// The environment handed to each [run] call, parallel to [calls] — so a
  /// test can pin that a secret went through the environment and not argv.
  final List<Map<String, String>?> environments = [];

  /// Sequenced answers, consulted before [responses]: each call for the
  /// subcommand pops the next entry, letting a test model state that
  /// changes between calls (a VM that is stopped, then running).
  final Map<String, List<String>> responseQueue = {};

  /// Sequenced exit codes, consulted before [exitCodes] the same way.
  final Map<String, List<int>> exitCodeQueue = {};

  /// Called with each subcommand, so a test can change what the fake will
  /// answer next — modelling a repair that makes the guest reachable.
  void Function(String command)? onCommand;

  /// Every process [start] handed back, newest last. A streamed command is
  /// only observable through the process itself — what was written to its
  /// stdin is nowhere else.
  final List<MockProcess> processes = [];

  /// When set, a started process stays alive this long instead of exiting at
  /// once — a transfer that hangs rather than one that fails.
  Duration? startDelay;

  String _responseFor(String command) {
    final queue = responseQueue[command];
    if (queue != null && queue.isNotEmpty) return queue.removeAt(0);
    return responses[command] ?? '';
  }

  int _exitCodeFor(String command) {
    final queue = exitCodeQueue[command];
    if (queue != null && queue.isNotEmpty) return queue.removeAt(0);
    return exitCodes[command] ?? 0;
  }

  String _commandOf(List<String> arguments) {
    // Skip the leading `--store <dir>`.
    var index = 0;
    while (index < arguments.length && arguments[index].startsWith('--')) {
      index += 2;
    }
    return index < arguments.length ? arguments[index] : '';
  }

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
  }) async {
    calls.add([executable, ...arguments]);
    environments.add(environment);
    final command = _commandOf(arguments);
    onCommand?.call(command);
    return ProcessResult(
      0,
      _exitCodeFor(command),
      _responseFor(command),
      errors[command] ?? '',
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
    calls.add(['start:$executable', ...arguments]);
    final command = _commandOf(arguments);
    onCommand?.call(command);
    final process = MockProcess(
      exitCode: _exitCodeFor(command),
      stdout: _responseFor(command),
      stderr: errors[command] ?? '',
      delay: startDelay,
    );
    processes.add(process);
    return process;
  }
}
