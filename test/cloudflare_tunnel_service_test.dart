import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/mcp/cloudflare_tunnel_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// A controllable fake tunnel process — lets tests feed cloudflared-style
/// log lines to stdout/stderr and control when it "exits", without
/// spawning anything real.
class _FakeProcess implements Process {
  final StreamController<List<int>> stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> stderrController =
      StreamController<List<int>>();
  bool killed = false;

  @override
  Stream<List<int>> get stdout => stdoutController.stream;

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  void emitStdoutLine(String line) =>
      stdoutController.add(utf8.encode('$line\n'));
  void emitStderrLine(String line) =>
      stderrController.add(utf8.encode('$line\n'));

  Future<void> dispose() async {
    await stdoutController.close();
    await stderrController.close();
  }
}

void main() {
  late _FakeProcess fakeProcess;
  late CloudflareTunnelService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    fakeProcess = _FakeProcess();
    service = CloudflareTunnelService(
      processSpawner: (executable, args) async => fakeProcess,
      binaryLocatorOverride: () async => 'cloudflared',
      urlWaitTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    await service.stop();
    await fakeProcess.dispose();
  });

  test('start() resolves with the tunnel URL parsed from stdout', () async {
    final startFuture = service.start();

    // cloudflared logs its banner across several lines before the URL.
    fakeProcess.emitStdoutLine('2026-01-01T00:00:00Z INF Starting tunnel');
    fakeProcess.emitStdoutLine(
        '2026-01-01T00:00:00Z INF |  https://random-words-1234.trycloudflare.com  |');

    final url = await startFuture;

    expect(url, 'https://random-words-1234.trycloudflare.com');
    expect(service.publicUrl, url);
    expect(service.isRunning, true);
  });

  test('start() also detects the URL when cloudflared logs it to stderr',
      () async {
    final startFuture = service.start();

    fakeProcess
        .emitStderrLine('INF |  https://another-one.trycloudflare.com  |');

    final url = await startFuture;

    expect(url, 'https://another-one.trycloudflare.com');
  });

  test('start() passes the local port through to the tunnel command',
      () async {
    String? capturedExecutable;
    List<String>? capturedArgs;
    service = CloudflareTunnelService(
      processSpawner: (executable, args) async {
        capturedExecutable = executable;
        capturedArgs = args;
        return fakeProcess;
      },
      binaryLocatorOverride: () async => 'cloudflared',
      urlWaitTimeout: const Duration(seconds: 2),
    );

    final startFuture = service.start();
    fakeProcess.emitStdoutLine('https://x.trycloudflare.com');
    await startFuture;

    expect(capturedExecutable, 'cloudflared');
    expect(capturedArgs, ['tunnel', '--url', 'http://127.0.0.1:59133']);
  });

  test('start() times out and stops the process if no URL ever appears',
      () async {
    await expectLater(service.start(), throwsException);

    expect(fakeProcess.killed, true);
    expect(service.isRunning, false);
    expect(service.publicUrl, isNull);
  });

  test('stop() kills the process and clears the public URL', () async {
    final startFuture = service.start();
    fakeProcess.emitStdoutLine('https://x.trycloudflare.com');
    await startFuture;

    await service.stop();

    expect(fakeProcess.killed, true);
    expect(service.isRunning, false);
    expect(service.publicUrl, isNull);
  });

  test('tunnels for different local ports are independent', () async {
    // The MCP server and the web dashboard each publish their own port;
    // stopping one must not kill the other's cloudflared.
    final otherProcess = _FakeProcess();
    addTearDown(otherProcess.dispose);
    final other = CloudflareTunnelService(
      localPort: 59134,
      processSpawner: (executable, args) async {
        expect(args, ['tunnel', '--url', 'http://127.0.0.1:59134']);
        return otherProcess;
      },
      binaryLocatorOverride: () async => 'cloudflared',
      urlWaitTimeout: const Duration(seconds: 2),
    );
    addTearDown(other.stop);

    final mcpStart = service.start();
    fakeProcess.emitStdoutLine('https://mcp.trycloudflare.com');
    await mcpStart;
    final webStart = other.start();
    otherProcess.emitStdoutLine('https://web.trycloudflare.com');
    await webStart;

    expect(service.publicUrl, 'https://mcp.trycloudflare.com');
    expect(other.publicUrl, 'https://web.trycloudflare.com');
    // A fresh wrapper for the same port sees the same tunnel.
    expect(CloudflareTunnelService(localPort: 59134).publicUrl,
        'https://web.trycloudflare.com');

    await service.stop();

    expect(fakeProcess.killed, true);
    expect(otherProcess.killed, false);
    expect(other.isRunning, true);
    expect(other.publicUrl, 'https://web.trycloudflare.com');
  });

  test('a second start() while already running returns the existing URL '
      'without spawning a new process', () async {
    var spawnCount = 0;
    service = CloudflareTunnelService(
      processSpawner: (executable, args) async {
        spawnCount++;
        return fakeProcess;
      },
      binaryLocatorOverride: () async => 'cloudflared',
      urlWaitTimeout: const Duration(seconds: 2),
    );

    final startFuture = service.start();
    fakeProcess.emitStdoutLine('https://x.trycloudflare.com');
    final firstUrl = await startFuture;

    final secondUrl = await service.start();

    expect(secondUrl, firstUrl);
    expect(spawnCount, 1);
  });
}
