import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_service.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

void main() {
  late MockShell mockShell;
  late WSLApi wslApi;
  late MockHttpServer mockServer;
  Handler? capturedHandler;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mockShell = MockShell();
    wslApi = WSLApi(shell: mockShell);
    mockServer = MockHttpServer();
    capturedHandler = null;
  });

  tearDown(() async {
    // _server is static (mirrors Sync's `static late HttpServer server` —
    // see wsl_mcp_service.dart), shared across every WslMcpService()
    // instance. Without resetting it, a "running" server from an earlier
    // test makes start()'s idempotency guard skip the next test's factory
    // entirely, silently leaving capturedHandler null.
    await WslMcpService().stop();
  });

  WslMcpService service() => WslMcpService(
        wslApi: wslApi,
        serverFactory: (handler, address, port) async {
          capturedHandler = handler;
          return mockServer;
        },
      );

  Future<Response> post(Map<String, dynamic> body, {String? token}) async {
    final request = Request(
      'POST',
      Uri.parse('http://127.0.0.1:${WslMcpService.port}${WslMcpService.path}'),
      body: json.encode(body),
      headers: token != null ? {'authorization': 'Bearer $token'} : null,
    );
    return await capturedHandler!(request);
  }

  test('start() binds to 127.0.0.1, never 0.0.0.0', () async {
    Object? boundAddress;
    final svc = WslMcpService(
      wslApi: wslApi,
      serverFactory: (handler, address, port) async {
        boundAddress = address;
        return mockServer;
      },
    );

    await svc.start();

    // This endpoint can run arbitrary commands in the user's WSL distros —
    // binding it to anything but loopback would expose it to the LAN.
    expect(boundAddress, '127.0.0.1');
    expect(svc.isRunning, true);
  });

  test('stop() closes the server and clears isRunning', () async {
    final svc = service();
    await svc.start();
    expect(svc.isRunning, true);

    await svc.stop();

    expect(mockServer.closed, true);
    expect(svc.isRunning, false);
  });

  test('token is generated on first access and stays stable afterward', () {
    final svc = service();
    final first = svc.token;
    final second = svc.token;

    expect(first, isNotEmpty);
    expect(second, first);
  });

  test('regenerateToken() rotates the token', () {
    final svc = service();
    final before = svc.token;
    final after = svc.regenerateToken();

    expect(after, isNot(before));
    expect(svc.token, after);
  });

  test('a request without the correct bearer token is rejected', () async {
    final svc = service();
    await svc.start();

    final response = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});

    expect(response.statusCode, 403);
  });

  test('a request with the correct bearer token is processed', () async {
    final svc = service();
    await svc.start();

    final response = await post(
      {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
      token: svc.token,
    );

    expect(response.statusCode, 200);
    final body = json.decode(await response.readAsString());
    final toolNames =
        (body['result']['tools'] as List).map((t) => t['name']).toSet();
    expect(
        toolNames,
        containsAll({
          'wsl_list_distros',
          'wsl_run_command',
          'wsl_stop_distro',
          'wsl_import_distro',
          'wsl_unregister_distro',
          'wsl_set_wsl_conf',
          'wsl_set_wslconfig',
          'wsl_terminal_start',
          'wsl_terminal_send',
          'wsl_terminal_signal',
          'wsl_terminal_close',
        }));
  });

  test('a family switched on in Settings is listed on the next request',
      () async {
    // The container_*, kube_* and cloud_* families follow the experimental
    // switches (bostrot/ai-tasks#87), and a client connected to a running
    // server should see a flip without the server being turned off and on.
    final svc = service();
    await svc.start();

    Future<Set<dynamic>> names() async {
      final response = await post(
        {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
        token: svc.token,
      );
      final body = json.decode(await response.readAsString());
      return (body['result']['tools'] as List).map((t) => t['name']).toSet();
    }

    expect(await names(), isNot(contains('kube_contexts')));
    ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, true);
    expect(await names(), contains('kube_contexts'));
    ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, false);
    expect(await names(), isNot(contains('kube_contexts')));
    // The rest of the surface is there throughout.
    expect(await names(), contains('wsl_list_distros'));
  });

  test('an actual tool call round-trips through the real WSLApi', () async {
    final svc = service();
    await svc.start();

    final response = await post(
      {
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'wsl_stop_distro',
          'arguments': {'distro': 'Ubuntu'},
        },
      },
      token: svc.token,
    );

    final body = json.decode(await response.readAsString());
    expect(body['result']['isError'], false);
    expect(mockShell.lastRunArguments, contains('--terminate'));
    expect(mockShell.lastRunArguments, contains('Ubuntu'));
  });

  test('setEnabled(true) persists the preference and starts the server',
      () async {
    final svc = service();
    await svc.setEnabled(true);

    expect(prefs.getBool('McpServerEnabled'), true);
    expect(svc.isRunning, true);
  });

  test('setEnabled(false) persists the preference and stops the server',
      () async {
    final svc = service();
    await svc.setEnabled(true);
    await svc.setEnabled(false);

    expect(prefs.getBool('McpServerEnabled'), false);
    expect(svc.isRunning, false);
  });

  group('connectClaudeDesktop', () {
    test('writes the bridge entry and preserves the rest of the config',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('claude_desktop');
      addTearDown(() => tempDir.delete(recursive: true));
      WslMcpService.claudeDesktopConfigDirOverride = tempDir.path;
      addTearDown(
          () => WslMcpService.claudeDesktopConfigDirOverride = null);
      File('${tempDir.path}${Platform.pathSeparator}claude_desktop_config.json')
          .writeAsStringSync(json.encode({
        'mcpServers': {
          'other': {'command': 'foo'}
        },
        'theme': 'dark',
      }));

      final svc = service();
      final path = await svc.connectClaudeDesktop();

      final config =
          json.decode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final servers = config['mcpServers'] as Map<String, dynamic>;
      // The other server and the unrelated setting both survive.
      expect(servers.keys, containsAll(['other', 'wsl-manager']));
      expect(config['theme'], 'dark');

      final entry = servers['wsl-manager'] as Map<String, dynamic>;
      expect(entry['command'], 'npx');
      final args = (entry['args'] as List).cast<String>();
      expect(args, contains(svc.endpointUrl));
      // The token travels via env, not argv — Claude Desktop splits argv
      // on spaces.
      expect(args, contains(r'Authorization:${AUTH_HEADER}'));
      expect((entry['env'] as Map)['AUTH_HEADER'], 'Bearer ${svc.token}');
    });

    test('reports when Claude Desktop is not installed', () async {
      WslMcpService.claudeDesktopConfigDirOverride =
          '${Directory.systemTemp.path}${Platform.pathSeparator}no-claude-desktop-here';
      addTearDown(
          () => WslMcpService.claudeDesktopConfigDirOverride = null);

      await expectLater(
        service().connectClaudeDesktop(),
        throwsA(predicate(
            (e) => e.toString().contains('claude-desktop-not-found'))),
      );
    });
  });
}
