// Optional public exposure for a local server (the MCP endpoint, the web
// dashboard) via a Cloudflare quick tunnel — outbound only, no account or
// port forwarding needed.
//
// Once on, the token is the ONLY thing gating access, so the Settings UI
// has to spell that out. cloudflared is downloaded on first use and cached
// under the app data dir.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

typedef TunnelProcessSpawner = Future<Process> Function(
    String executable, List<String> args);

typedef BinaryLocator = Future<String?> Function();

Future<Process> _defaultProcessSpawner(String executable, List<String> args) {
  return Process.start(executable, args);
}

class CloudflareTunnelService {
  /// Official release asset for this host. macOS ships as a tgz holding the
  /// binary; Windows and Linux are bare executables.
  static String get _downloadUrl {
    const base =
        'https://github.com/cloudflare/cloudflared/releases/latest/download/';
    if (Platform.isMacOS) return '${base}cloudflared-darwin-arm64.tgz';
    if (Platform.isLinux) return '${base}cloudflared-linux-amd64';
    return '${base}cloudflared-windows-amd64.exe';
  }
  static final RegExp _urlPattern =
      RegExp(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com');
  static const Duration defaultUrlWaitTimeout = Duration(seconds: 25);

  /// The port the MCP server listens on — the tunnel this service pointed
  /// at before the web dashboard needed one of its own.
  static const int defaultLocalPort = 59133;

  // Static for the same reason as WslMcpService._server: one real tunnel
  // per local port, however many wrappers. Keyed by port so the MCP server
  // and the web dashboard can each have their own without either wrapper
  // tearing down the other's.
  static final Map<int, _Tunnel> _tunnels = <int, _Tunnel>{};

  /// The local port this wrapper's tunnel forwards to.
  final int localPort;
  final TunnelProcessSpawner processSpawner;
  final BinaryLocator? binaryLocatorOverride;
  final Dio dio;
  final Duration urlWaitTimeout;

  CloudflareTunnelService({
    this.localPort = defaultLocalPort,
    TunnelProcessSpawner? processSpawner,
    this.binaryLocatorOverride,
    Dio? dio,
    this.urlWaitTimeout = defaultUrlWaitTimeout,
  })  : processSpawner = processSpawner ?? _defaultProcessSpawner,
        dio = dio ?? Dio();

  bool get isRunning => _tunnels.containsKey(localPort);

  String? get publicUrl => _tunnels[localPort]?.publicUrl;

  /// Cached copy, then PATH, then a fresh download.
  Future<String> _locateBinary() async {
    if (binaryLocatorOverride != null) {
      final located = await binaryLocatorOverride!();
      if (located != null) return located;
    }

    final cachedPath = _cachedBinaryPath();
    if (await File(cachedPath).exists() && await _binaryWorks(cachedPath)) {
      return cachedPath;
    }

    if (await _binaryWorks('cloudflared')) {
      return 'cloudflared';
    }

    Notify.message('cloudflare-tunnel-downloading-text'.i18n(),
        loading: true);
    if (_downloadUrl.endsWith('.tgz')) {
      // The macOS asset is an archive; unpack the one binary it contains.
      final archivePath = '$cachedPath.tgz';
      await dio.download(_downloadUrl, archivePath);
      final extract = await Process.run('tar', [
        '-xzf', archivePath,
        '-C', File(cachedPath).parent.path,
        'cloudflared',
      ]);
      try {
        File(archivePath).deleteSync();
      } catch (_) {}
      if (extract.exitCode != 0) {
        throw Exception(
            'Could not unpack cloudflared: ${extract.stderr}');
      }
    } else {
      await dio.download(_downloadUrl, cachedPath);
    }
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', cachedPath]);
    }
    if (!await _binaryWorks(cachedPath)) {
      throw Exception(
          'Downloaded cloudflared but it did not run successfully.');
    }
    return cachedPath;
  }

  String _cachedBinaryPath() {
    final dir = getDataPath()..cd('bin');
    return dir.file(Platform.isWindows ? 'cloudflared.exe' : 'cloudflared');
  }

  Future<bool> _binaryWorks(String executable) async {
    try {
      final result = await Process.run(executable, ['--version'])
          .timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Starts a tunnel to `127.0.0.1:[localPort]` and returns the public URL.
  /// Throws if cloudflared cannot be run or reports no URL in time.
  Future<String> start() async {
    final existing = _tunnels[localPort];
    if (existing != null && existing.publicUrl != null) {
      return existing.publicUrl!;
    }

    final executable = await _locateBinary();
    final process = await processSpawner(
      executable,
      ['tunnel', '--url', 'http://127.0.0.1:$localPort'],
    );
    final tunnel = _Tunnel(process);
    _tunnels[localPort] = tunnel;

    final urlCompleter = Completer<String>();
    void scanForUrl(String line) {
      if (urlCompleter.isCompleted) return;
      final match = _urlPattern.firstMatch(line);
      if (match != null) {
        urlCompleter.complete(match.group(0));
      }
    }

    tunnel.stdoutSub = process.stdout
        .cast<List<int>>()
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(scanForUrl);
    tunnel.stderrSub = process.stderr
        .cast<List<int>>()
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen(scanForUrl);

    try {
      final url = await urlCompleter.future.timeout(urlWaitTimeout);
      tunnel.publicUrl = url;
      return url;
    } on TimeoutException {
      await stop();
      throw Exception(
          'Timed out waiting for cloudflared to report a tunnel URL.');
    }
  }

  /// Tears down this wrapper's tunnel; other ports' tunnels keep running.
  Future<void> stop() async {
    final tunnel = _tunnels.remove(localPort);
    if (tunnel == null) return;
    await tunnel.stdoutSub?.cancel();
    await tunnel.stderrSub?.cancel();
    tunnel.process.kill();
  }
}

/// One running cloudflared process and what it has reported so far.
class _Tunnel {
  final Process process;
  String? publicUrl;
  StreamSubscription<String>? stdoutSub;
  StreamSubscription<String>? stderrSub;

  _Tunnel(this.process);
}
