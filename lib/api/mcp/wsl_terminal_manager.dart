// Session-based terminal control: a shell process stays alive across MCP
// calls, so a client can drive a REPL or a long-running program that needs
// stdin after starting. Contrast wsl_run_command, which is one-shot.
//
// Built on VmBackend.startShell() — the WSL default-shell spawn on
// Windows, an SSH session into the VM on macOS.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';

class WslTerminalSession {
  final String id;
  final String distribution;
  final String user;
  final Process process;
  final DateTime startedAt;

  final StringBuffer _output = StringBuffer();
  int _readOffset = 0;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  bool _closed = false;

  WslTerminalSession({
    required this.id,
    required this.distribution,
    required this.user,
    required this.process,
  }) : startedAt = DateTime.now() {
    _stdoutSub = process.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.write);
    _stderrSub = process.stderr
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_output.write);
    process.exitCode.then((_) => _closed = true);
  }

  bool get isAlive => !_closed;

  /// Sends a line of input, as if typed and followed by Enter.
  void sendInput(String text) {
    if (_closed) {
      throw StateError('Terminal session $id has already closed.');
    }
    process.stdin.writeln(text);
  }

  /// Sends a raw control byte (0x03 Ctrl-C, 0x04 Ctrl-D).
  ///
  /// The session is a pipe, not a TTY, so a program that only honours these
  /// from a terminal may ignore them — killing the session is the reliable
  /// fallback, which is why the MCP signal tool offers both.
  void sendControl(int byte) {
    if (_closed) {
      throw StateError('Terminal session $id has already closed.');
    }
    process.stdin.add([byte]);
  }

  /// Closes stdin — a true end-of-file, which ends `cat`, a heredoc, or the
  /// shell itself regardless of TTY semantics.
  Future<void> sendEof() {
    if (_closed) {
      throw StateError('Terminal session $id has already closed.');
    }
    return process.stdin.close();
  }

  /// Output since the last call. Consuming — a second call with nothing new
  /// in between returns empty, not a repeat.
  String readNewOutput() {
    final all = _output.toString();
    final fresh = all.substring(_readOffset);
    _readOffset = all.length;
    return fresh;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    process.kill();
  }
}

class WslTerminalManager {
  final VmBackend wslApi;
  final Map<String, WslTerminalSession> _sessions = {};
  int _nextId = 1;

  WslTerminalManager({VmBackend? wslApi}) : wslApi = wslApi ?? vmBackend();

  List<WslTerminalSession> get sessions => _sessions.values.toList();

  WslTerminalSession? session(String id) => _sessions[id];

  Future<WslTerminalSession> startSession(String distribution,
      {String? user}) async {
    final process = await wslApi.startShell(distribution, user: user);
    final id = 'term-${_nextId++}';
    final session = WslTerminalSession(
      id: id,
      distribution: distribution,
      user: user ?? 'root',
      process: process,
    );
    _sessions[id] = session;
    return session;
  }

  Future<void> closeSession(String id) async {
    final session = _sessions.remove(id);
    await session?.close();
  }

  /// Closes every session — call when the server stops, so no orphaned WSL
  /// shells are left behind.
  Future<void> closeAll() async {
    final all = _sessions.values.toList();
    _sessions.clear();
    for (final session in all) {
      await session.close();
    }
  }
}
