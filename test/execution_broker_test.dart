import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        Process,
        ProcessResult,
        ProcessSignal,
        ProcessStartMode,
        systemEncoding;

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/execution/models.dart';
import 'package:wsl2distromanager/api/shell.dart';

import 'mocks.dart';

/// A minimal mock shell that returns configurable results.
class TestShell implements Shell {
  String stdoutData = 'ok';
  String stderrData = '';
  int exitCode = 0;
  Duration? artificialDelay;

  /// Raw bytes to emit instead of [stdoutData]/[stderrData], one stream event
  /// per entry. Lets a test hand the broker output that is not valid UTF-8, or
  /// split a multi-byte sequence across two chunks.
  List<List<int>>? stdoutChunks;
  List<List<int>>? stderrChunks;

  List<String> lastCommand = [];
  List<List<String>> allCommands = [];

  /// The last process handed out by [start], so tests can inspect kill counts.
  MockProcess? lastProcess;

  bool throwOnRun = false;

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      Encoding? stdoutEncoding,
      Encoding? stderrEncoding}) async {
    if (throwOnRun) throw Exception('shell error');
    lastCommand = [executable, ...arguments];
    allCommands.add([executable, ...arguments]);
    if (artificialDelay != null) await Future.delayed(artificialDelay!);
    // When an encoding is provided, the real shell returns a decoded String.
    // Return raw bytes only when encoding is null (WSL path).
    return ProcessResult(
      -1, // pid placeholder
      exitCode,
      stdoutEncoding != null ? stdoutData : utf8.encode(stdoutData),
      stderrEncoding != null ? stderrData : utf8.encode(stderrData),
    );
  }

  @override
  Future<Process> start(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      ProcessStartMode mode = ProcessStartMode.inheritStdio,
      bool runInShell = false}) async {
    if (throwOnRun) throw Exception('shell error');
    lastCommand = [executable, ...arguments];
    allCommands.add([executable, ...arguments]);
    // `artificialDelay` becomes the child's lifetime rather than a delay before
    // the result arrives — that is what a hung command actually looks like now
    // that run() owns a killable handle.
    lastProcess = MockProcess(
      exitCode: exitCode,
      stdout: stdoutData,
      stderr: stderrData,
      stdoutChunks: stdoutChunks,
      stderrChunks: stderrChunks,
      delay: artificialDelay,
    );
    return lastProcess!;
  }

  void reset() {
    lastCommand.clear();
    allCommands.clear();
    lastProcess = null;
    stdoutChunks = null;
    stderrChunks = null;
  }
}

void main() {
  group('ExecutionBroker policy enforcement', () {
    late TestShell testShell;
    late ExecutionBroker broker;

    setUp(() {
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
    });

    test('allowedCommands whitelist blocks disallowed command', () async {
      final request = ExecutionRequest(
        command: 'rm',
        arguments: ['-rf', '/tmp/test'],
        allowedCommands: ['ls', 'cat', 'pwd'],
      );
      expect(() => broker.run(request), throwsA(isA<Exception>()));
    });

    test('allowedCommands whitelist allows permitted command', () async {
      final request = ExecutionRequest(
        command: 'ls',
        arguments: ['-la'],
        allowedCommands: ['ls', 'cat', 'pwd'],
      );
      final result = await broker.run(request);
      expect(result.exitCode, 0);
      expect(testShell.lastCommand[0], 'ls');
    });

    test('allowedCommands null means no restriction', () async {
      final request = ExecutionRequest(
        command: 'rm',
        arguments: ['-rf', '/tmp/test'],
      );
      final result = await broker.run(request);
      expect(result.exitCode, 0);
    });

    test('readOnly mode blocks apt-get install', () async {
      final request = ExecutionRequest(
        command: 'apt-get',
        arguments: ['install', 'curl'],
        readOnly: true,
      );
      expect(() => broker.run(request), throwsA(isA<Exception>()));
    });

    test('readOnly mode blocks pip install', () async {
      final request = ExecutionRequest(
        command: 'pip',
        arguments: ['install', 'requests'],
        readOnly: true,
      );
      expect(() => broker.run(request), throwsA(isA<Exception>()));
    });

    test('readOnly mode blocks npm install', () async {
      final request = ExecutionRequest(
        command: 'npm',
        arguments: ['install', 'express'],
        readOnly: true,
      );
      expect(() => broker.run(request), throwsA(isA<Exception>()));
    });

    test('readOnly mode allows read-only commands from allowlist', () async {
      final request = ExecutionRequest(
        command: 'ls',
        arguments: ['-la'],
        readOnly: true,
      );
      expect(() => broker.run(request), returnsNormally);
    });

    test('readOnly mode allows cat', () async {
      final request = ExecutionRequest(
        command: 'cat',
        arguments: ['/etc/os-release'],
        readOnly: true,
      );
      expect(() => broker.run(request), returnsNormally);
    });
  });

  group('ExecutionBroker audit trail', () {
    late TestShell testShell;
    late ExecutionBroker broker;

    setUp(() {
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
    });

    test('audit log records successful execution', () async {
      await broker.run(const ExecutionRequest(
        command: 'echo',
        arguments: ['hello'],
      ));
      expect(broker.auditLog.length, 1);
      final entry = broker.auditLog.first;
      expect(entry.request.command, 'echo');
      expect(entry.exitCode, 0);
      expect(entry.severity, AuditSeverity.info);
    });

    test('audit log records failed execution', () async {
      testShell.exitCode = 1;
      await broker.run(const ExecutionRequest(
        command: 'false',
        arguments: [],
      ));
      expect(broker.auditLog.length, 1);
      final entry = broker.auditLog.first;
      expect(entry.exitCode, 1);
      expect(entry.severity, AuditSeverity.error);
    });

    test('audit log accumulates entries', () async {
      await broker
          .run(const ExecutionRequest(command: 'echo', arguments: ['a']));
      await broker
          .run(const ExecutionRequest(command: 'ls', arguments: ['-la']));
      await broker.run(
          const ExecutionRequest(command: 'cat', arguments: ['/etc/hostname']));
      expect(broker.auditLog.length, 3);
    });

    test('clearAuditLog empties history', () async {
      await broker
          .run(const ExecutionRequest(command: 'echo', arguments: ['test']));
      expect(broker.auditLog.length, 1);
      broker.clearAuditLog();
      expect(broker.auditLog.isEmpty, true);
    });
  });

  group('ExecutionBroker run result', () {
    late TestShell testShell;
    late ExecutionBroker broker;

    setUp(() {
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
    });

    test('returns stdout from shell', () async {
      testShell.stdoutData = 'hello world';
      final result = await broker.run(const ExecutionRequest(
        command: 'echo',
        arguments: ['hello world'],
      ));
      expect(result.stdout, contains('hello world'));
    });

    test('returns stderr from shell', () async {
      testShell.stderrData = 'error message';
      final result = await broker.run(const ExecutionRequest(
        command: 'bad-cmd',
        arguments: [],
      ));
      expect(result.stderr, contains('error message'));
    });

    test('returns exit code from shell', () async {
      testShell.exitCode = 42;
      final result = await broker.run(const ExecutionRequest(
        command: 'custom',
        arguments: [],
      ));
      expect(result.exitCode, 42);
    });

    test('measures execution duration', () async {
      testShell.artificialDelay = const Duration(milliseconds: 50);
      final result = await broker.run(const ExecutionRequest(
        command: 'slow-cmd',
        arguments: [],
      ));
      expect(result.duration.inMilliseconds, greaterThanOrEqualTo(40));
    });

    test('a hung command times out instead of hanging forever', () async {
      testShell.artificialDelay = const Duration(seconds: 5);
      final result = await broker.run(const ExecutionRequest(
        command: 'hung-cmd',
        arguments: [],
        timeout: Duration(milliseconds: 50),
      ));
      expect(result.exitCode, -1);
      expect(result.stderr, contains('timed out'));
      expect(result.auditSeverity, AuditSeverity.error);
    });

    test('captures the command and arguments in audit entry', () async {
      await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['--list', '--quiet'],
      ));
      final entry = broker.auditLog.first;
      expect(entry.request.command, 'wsl');
      expect(entry.request.arguments, ['--list', '--quiet']);
    });

    test('forwards runInShell to the shell', () async {
      final result = await broker.run(const ExecutionRequest(
        command: 'cmd',
        arguments: ['/c', 'echo hello'],
        runInShell: true,
      ));
      expect(result.exitCode, 0);
    });
  });

  group('ExecutionBroker timeout reaping', () {
    late TestShell testShell;
    late ExecutionBroker broker;

    setUp(() {
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
    });

    // Regression: `Process.run` handed back no handle, so a timeout could only
    // abandon the child. With list.dart re-polling every 5s that leaked 842
    // orphaned wsl.exe processes on 2026-08-27.
    test('a timed-out command is killed exactly once', () async {
      testShell.artificialDelay = const Duration(seconds: 30);

      final result = await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['--list', '--verbose'],
        timeout: Duration(milliseconds: 50),
      ));

      final process = testShell.lastProcess;
      expect(process, isNotNull, reason: 'run() must go through Shell.start');
      expect(process!.killCount, 1);
      // SIGKILL escalation only happens when the child ignores the first
      // signal; this one exits, so the polite signal is the only one sent.
      expect(process.lastKillSignal, ProcessSignal.sigterm);
      expect(result.exitCode, -1);
    });

    test('the TimeoutException reaches the caller', () async {
      testShell.artificialDelay = const Duration(seconds: 30);

      final result = await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['--list', '--verbose'],
        timeout: Duration(milliseconds: 50),
      ));

      // run() reports failures on the result rather than throwing, so the
      // exception travels in `error` — callers need no try/catch.
      expect(result.error, isA<TimeoutException>());
      expect(
        (result.error as TimeoutException).message,
        contains('Command timed out after 0s: wsl --list --verbose'),
      );
      expect(result.stderr, contains('timed out'));
      expect(result.auditSeverity, AuditSeverity.error);
      expect(broker.auditLog.last.errorMessage, contains('timed out'));
    });

    test('a command inside its timeout is never killed', () async {
      testShell.artificialDelay = const Duration(milliseconds: 20);

      final result = await broker.run(const ExecutionRequest(
        command: 'echo',
        arguments: ['quick'],
        timeout: Duration(seconds: 5),
      ));

      expect(result.exitCode, 0);
      expect(testShell.lastProcess!.killCount, 0);
    });
  });

  group('ExecutionBroker output decoding', () {
    late TestShell testShell;
    late ExecutionBroker broker;

    // 'hello' the way wsl.exe writes it: UTF-16LE, so every ASCII byte is
    // followed by a null. utf8.encode maps '\u0000' to a single 0x00 byte, so
    // this string is exactly that byte sequence.
    const utf16leHello = 'h\u0000e\u0000l\u0000l\u0000o\u0000';

    setUp(() {
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
    });

    test('WSL stdout and stderr take the raw-bytes branch', () async {
      testShell.stdoutData = utf16leHello;
      testShell.stderrData = 'w\u0000a\u0000r\u0000n\u0000';

      final result = await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['--list', '--quiet'],
      ));

      expect(result.stdout, 'hello');
      expect(result.stderr, 'warn');
    });

    test('a wsl.exe path is treated as WSL too', () async {
      testShell.stdoutData = utf16leHello;

      final result = await broker.run(const ExecutionRequest(
        command: r'C:\Windows\System32\wsl.exe',
        arguments: ['--list'],
      ));

      expect(result.stdout, 'hello');
    });

    test('WSL bytes are assembled before decoding, not per chunk', () async {
      // 'é' is C3 A9 in UTF-8; the split puts one byte in each stream event.
      // Decoding chunk-by-chunk would yield two replacement characters.
      testShell.stdoutChunks = [
        [0xC3],
        [0xA9, 0x21],
      ];

      final result = await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['-d', 'Ubuntu', 'echo'],
      ));

      expect(result.stdout, 'é!');
    });

    test('non-WSL output decodes with systemEncoding', () async {
      // The old code expressed this split as
      // `stdoutEncoding: isWsl ? null : systemEncoding`. Asserting against
      // systemEncoding rather than a literal keeps the test honest on a host
      // whose ANSI codepage is UTF-8, where both branches happen to agree.
      final bytes = utf8.encode('café');
      testShell.stdoutChunks = [bytes];

      final result = await broker.run(const ExecutionRequest(
        command: 'echo',
        arguments: ['café'],
      ));

      expect(result.stdout, systemEncoding.decode(bytes));
    });

    test('non-WSL ASCII passes through unchanged', () async {
      testShell.stdoutData = 'line one\nline two\n';
      testShell.stderrData = 'a warning\n';

      final result = await broker.run(const ExecutionRequest(
        command: 'echo',
        arguments: ['hi'],
      ));

      expect(result.stdout, 'line one\nline two\n');
      expect(result.stderr, 'a warning\n');
    });

    // Stripping the lone ESC byte left its parameters behind as ordinary
    // text, so the AI Workspace card rendered a streamed installer line as
    // `[0;36m— Trying SSH clone...` (measured 2026-08-28). The sequence has
    // to be removed whole.
    test('ANSI colour sequences are removed with their parameters', () async {
      testShell.stdoutData = '\x1B[0;36m- Trying SSH clone...\x1B[0m\n';

      final result = await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['-d', 'ai-workspace', 'bash'],
      ));

      expect(result.stdout, '- Trying SSH clone...\n');
    });

    test('cursor moves, line erases and window titles are removed too',
        () async {
      testShell.stdoutData =
          '\x1B]0;installing\x07\x1B[2K\x1B[1Aprogress 40%\x1B[?25l\n';

      final result = await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['-d', 'ai-workspace', 'bash'],
      ));

      expect(result.stdout, 'progress 40%\n');
    });

    test('a bracket that is not an escape sequence survives', () async {
      testShell.stdoutData = 'pgrep -f [h]ermes matched [0] processes\n';

      final result = await broker.run(const ExecutionRequest(
        command: 'wsl',
        arguments: ['-d', 'ai-workspace', 'bash'],
      ));

      expect(result.stdout, 'pgrep -f [h]ermes matched [0] processes\n');
    });

    test('empty output yields empty strings, not nulls', () async {
      testShell.stdoutData = '';
      testShell.stderrData = '';

      final result = await broker.run(const ExecutionRequest(
        command: 'true',
        arguments: [],
      ));

      expect(result.stdout, '');
      expect(result.stderr, '');
    });
  });

  group('ExecutionBroker runStream events', () {
    late TestShell testShell;
    late ExecutionBroker broker;

    setUp(() {
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
    });

    // Note: these cover the failure path only — full stream event ordering
    // against a live process is verified by integration/e2e tests.

    test('runStream emits ExecutionStarted before error', () async {
      testShell.throwOnRun = true;
      final events = <ExecutionEvent>[];
      await broker
          .runStream(const ExecutionRequest(
            command: 'echo',
            arguments: ['streaming'],
          ))
          .forEach(events.add);

      expect(events.first, isA<ExecutionStarted>());
    });

    test('StdOutChunk events not emitted when start fails', () async {
      testShell.throwOnRun = true;
      final events = <ExecutionEvent>[];
      await broker
          .runStream(const ExecutionRequest(
            command: 'echo',
            arguments: ['data'],
          ))
          .forEach(events.add);

      final stdoutEvents = events.whereType<StdOutChunk>().toList();
      expect(stdoutEvents.isEmpty, true);
    });

    test('ExecutionStarted event has correct metadata', () async {
      final events = <ExecutionEvent>[];
      await broker
          .runStream(const ExecutionRequest(
            command: 'test-cmd',
            arguments: ['arg1', 'arg2'],
          ))
          .forEach(events.add);

      final started = events.first as ExecutionStarted;
      expect(started.command, 'test-cmd');
      expect(started.arguments, ['arg1', 'arg2']);
    });

    test('ExecutionExited not emitted when start fails (gets Error instead)',
        () async {
      testShell.throwOnRun = true;
      final events = <ExecutionEvent>[];
      await broker
          .runStream(const ExecutionRequest(
            command: 'echo',
            arguments: ['done'],
          ))
          .forEach(events.add);

      expect(events.last, isA<ExecutionError>());
      expect(events.whereType<ExecutionExited>().isEmpty, true);
    });
  });

  group('ExecutionBroker error handling', () {
    late TestShell testShell;
    late ExecutionBroker broker;

    setUp(() {
      testShell = TestShell();
      broker = ExecutionBroker(shell: testShell);
    });

    test('run() catches shell exception and returns error result', () async {
      testShell.throwOnRun = true;
      final result = await broker.run(const ExecutionRequest(
        command: 'bad',
        arguments: [],
      ));
      expect(result.exitCode, -1);
      expect(result.auditSeverity, AuditSeverity.error);
    });

    test('runStream() emits ExecutionError on shell exception', () async {
      testShell.throwOnRun = true;
      final events = <ExecutionEvent>[];
      await broker
          .runStream(const ExecutionRequest(
            command: 'bad',
            arguments: [],
          ))
          .forEach(events.add);

      expect(events.first, isA<ExecutionStarted>());
      expect(events.any((e) => e is ExecutionError), true);
    });

    test('policy violation does not add audit entry', () async {
      broker.clearAuditLog();
      try {
        await broker.run(const ExecutionRequest(
          command: 'rm',
          arguments: ['-rf', '/'],
          allowedCommands: ['ls'],
        ));
        fail('Expected exception');
      } catch (e) {
        // Expected
      }
      expect(broker.auditLog.isEmpty, true);
    });
  });

  group('ExecutionRequest defaults', () {
    test('default timeout is 5 minutes', () {
      final request = const ExecutionRequest(command: 'test');
      expect(request.timeout, const Duration(minutes: 5));
    });

    test('default captureOutput is true', () {
      final request = const ExecutionRequest(command: 'test');
      expect(request.captureOutput, true);
    });

    test('default readOnly is false', () {
      final request = const ExecutionRequest(command: 'test');
      expect(request.readOnly, false);
    });

    test('custom timeout is preserved', () {
      final request = const ExecutionRequest(
        command: 'test',
        timeout: Duration(minutes: 15),
      );
      expect(request.timeout, const Duration(minutes: 15));
    });
  });
}
