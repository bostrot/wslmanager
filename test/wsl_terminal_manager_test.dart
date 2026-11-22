import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// A controllable fake process: unlike test/mocks.dart's MockProcess (whose
/// exitCode resolves immediately, fine for one-shot commands but wrong for
/// a session meant to stay open), this one only "exits" when the test tells
/// it to — needed to actually exercise sendInput/readNewOutput against a
/// long-lived session instead of just the "unknown session id" error paths.
class _FakeProcess implements Process {
  final StreamController<List<int>> stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> stderrController =
      StreamController<List<int>>();
  final List<String> stdinWrites = [];
  final Completer<int> _exitCompleter = Completer<int>();

  @override
  Stream<List<int>> get stdout => stdoutController.stream;

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  IOSink get stdin => _FakeStdin(stdinWrites);

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  int get pid => 999;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(0);
    return true;
  }

  void emitStdout(String text) => stdoutController.add(utf8.encode(text));

  Future<void> dispose() async {
    await stdoutController.close();
    await stderrController.close();
  }
}

class _FakeStdin implements IOSink {
  final List<String> writes;
  _FakeStdin(this.writes);

  @override
  void writeln([Object? obj = '']) => writes.add(obj.toString());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late _FakeProcess fakeProcess;
  late WslTerminalManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    fakeProcess = _FakeProcess();
    manager = WslTerminalManager(
      wslApi: WSLApi(shell: _ShellReturning(fakeProcess)),
    );
  });

  tearDown(() async {
    await fakeProcess.dispose();
  });

  test('startSession spawns a shell and tracks it', () async {
    final session = await manager.startSession('Ubuntu', user: 'dev');

    expect(session.distribution, 'Ubuntu');
    expect(session.user, 'dev');
    expect(session.isAlive, true);
    expect(manager.sessions, [session]);
  });

  test('sendInput writes a line to the process stdin', () async {
    final session = await manager.startSession('Ubuntu');

    session.sendInput('echo hello');

    expect(fakeProcess.stdinWrites, ['echo hello']);
  });

  test('readNewOutput returns only output produced since the last read',
      () async {
    final session = await manager.startSession('Ubuntu');

    fakeProcess.emitStdout('first chunk\n');
    await Future.delayed(Duration.zero); // let the stream listener fire

    expect(session.readNewOutput(), 'first chunk\n');
    // Nothing new since the last read.
    expect(session.readNewOutput(), '');

    fakeProcess.emitStdout('second chunk\n');
    await Future.delayed(Duration.zero);

    expect(session.readNewOutput(), 'second chunk\n');
  });

  test('close() kills the process and marks the session not alive',
      () async {
    final session = await manager.startSession('Ubuntu');

    await session.close();

    expect(session.isAlive, false);
  });

  test('sendInput after close throws', () async {
    final session = await manager.startSession('Ubuntu');
    await session.close();

    expect(() => session.sendInput('echo hi'), throwsStateError);
  });

  test('closeSession removes it from the manager', () async {
    final session = await manager.startSession('Ubuntu');

    await manager.closeSession(session.id);

    expect(manager.sessions, isEmpty);
    expect(manager.session(session.id), isNull);
  });

  test('closeAll closes every open session', () async {
    await manager.startSession('Ubuntu');

    await manager.closeAll();

    expect(manager.sessions, isEmpty);
  });
}

/// Minimal Shell that always returns [process] from start(), regardless of
/// arguments — enough to test WslTerminalManager's session bookkeeping
/// without a real WSL process.
class _ShellReturning implements Shell {
  final Process process;
  _ShellReturning(this.process);

  @override
  Future<Process> start(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      ProcessStartMode mode = ProcessStartMode.normal,
      bool runInShell = false}) async {
    return process;
  }

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      Encoding? stdoutEncoding,
      Encoding? stderrEncoding}) async {
    return ProcessResult(0, 0, '', '');
  }
}
