import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/shell.dart';

import 'mocks.dart' show MockProcess;

/// A scripted `docker`/`podman`: answers per (executable, subcommand) and
/// records every invocation so a test can assert on the exact argv.
class FakeContainerShell implements Shell {
  /// Every `[executable, ...arguments]` this shell has been handed.
  final List<List<String>> calls = [];

  /// stdout keyed by `<executable> <subcommand>`, e.g. `docker ps`.
  final Map<String, String> responses = {};

  /// stderr, same keys.
  final Map<String, String> errors = {};

  /// Exit codes, same keys. Absent means 0.
  final Map<String, int> exitCodes = {};

  /// Executables that are not installed: running one throws the
  /// ProcessException dart:io raises for a missing binary.
  final Set<String> missing = {};

  /// Commands that never answer, so the service's timeout can be exercised.
  final Set<String> hangs = {};

  /// Every child handed back by [start], so a test can assert a timed-out
  /// command was actually reaped rather than merely stopped being awaited.
  final List<MockProcess> started = [];

  String _key(String executable, List<String> arguments) {
    final subcommand = arguments.isEmpty ? '' : arguments.first;
    return '$executable $subcommand'.trim();
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
    if (missing.contains(executable)) {
      throw ProcessException(
          executable, arguments, 'No such file or directory', 2);
    }
    final key = _key(executable, arguments);
    if (hangs.contains(key)) {
      return Completer<ProcessResult>().future;
    }
    return ProcessResult(
      0,
      exitCodes[key] ?? 0,
      responses[key] ?? '',
      errors[key] ?? '',
    );
  }

  /// [ContainerService] runs everything through `ExecutionBroker`, which
  /// spawns rather than runs — so this is the channel the container tests
  /// actually exercise. A hung command stays alive until the broker kills it,
  /// which is what makes the timeout assertable.
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
    calls.add([executable, ...arguments]);
    if (missing.contains(executable)) {
      throw ProcessException(
          executable, arguments, 'No such file or directory', 2);
    }
    final key = _key(executable, arguments);
    final process = MockProcess(
      exitCode: exitCodes[key] ?? 0,
      stdout: responses[key] ?? '',
      stderr: errors[key] ?? '',
      delay: hangs.contains(key) ? const Duration(minutes: 5) : null,
    );
    started.add(process);
    return process;
  }
}
