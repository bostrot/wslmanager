import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/shell.dart';

import 'mocks.dart' show MockProcess;

/// A scripted `kubectl`: answers per command fragment and records every
/// invocation so a test can assert on the exact argv.
///
/// Keyed on a *fragment* rather than the subcommand, because every kubectl
/// call this app makes carries `--context=` and `--namespace=` flags before
/// and after the verb — `arguments.first` says nothing about which command it
/// is. The first key contained in the joined argv wins, so `get pods` and
/// `get namespaces` can be scripted separately.
class FakeKubectlShell implements Shell {
  /// Every `[executable, ...arguments]` this shell has been handed.
  final List<List<String>> calls = [];

  /// stdout, keyed by a fragment of the command line, e.g. `get pods`.
  final Map<String, String> responses = {};

  /// stderr, same keys.
  final Map<String, String> errors = {};

  /// Exit codes, same keys. Absent means 0.
  final Map<String, int> exitCodes = {};

  /// Executables that are not installed: running one throws the
  /// ProcessException dart:io raises for a missing binary.
  final Set<String> missing = {};

  /// Command fragments that never answer, so the timeout can be exercised.
  final Set<String> hangs = {};

  /// Every child handed back by [start], so a test can assert a timed-out
  /// command was actually reaped rather than merely stopped being awaited.
  final List<MockProcess> started = [];

  /// The scripted value for [argv], or [orElse] when no key matches it.
  T _lookup<T>(Map<String, T> table, List<String> argv, T orElse) {
    final line = argv.join(' ');
    for (final entry in table.entries) {
      if (line.contains(entry.key)) return entry.value;
    }
    return orElse;
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
    if (hangs.any(arguments.join(' ').contains)) {
      return Completer<ProcessResult>().future;
    }
    return ProcessResult(
      0,
      _lookup(exitCodes, arguments, 0),
      _lookup(responses, arguments, ''),
      _lookup(errors, arguments, ''),
    );
  }

  /// [KubeService] runs everything through `ExecutionBroker`, which spawns
  /// rather than runs — so this is the channel the tests actually exercise.
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
    final process = MockProcess(
      exitCode: _lookup(exitCodes, arguments, 0),
      stdout: _lookup(responses, arguments, ''),
      stderr: _lookup(errors, arguments, ''),
      delay: hangs.any(arguments.join(' ').contains)
          ? const Duration(minutes: 5)
          : null,
    );
    started.add(process);
    return process;
  }
}
