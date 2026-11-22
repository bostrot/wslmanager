import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' hide Response;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/mcp/cloudflare_tunnel_service.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/web/web_dashboard_page.dart';
import 'package:wsl2distromanager/api/web/web_dashboard_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

/// Stands in for the AI provider at the dio layer, as ai_service_test does:
/// the dashboard's chat must never reach a real endpoint. [responder] may
/// hold its answer back, so a test can look at the dashboard mid-run; like
/// the real adapter, a held answer is dropped once the request is cancelled.
class _ProviderAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final Future<ResponseBody> Function(RequestOptions options) responder;

  _ProviderAdapter(this.responder);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    final answer = responder(options);
    if (cancelFuture == null) return answer;
    return Future.any([
      answer,
      cancelFuture.then((_) => throw DioException.requestCancelled(
          requestOptions: options, reason: 'cancelled')),
    ]);
  }

  @override
  void close({bool force = false}) {}
}

/// A complete (non-streamed) chat completion carrying [message].
ResponseBody _completion(Map<String, dynamic> message) =>
    ResponseBody.fromString(
      json.encode({
        'choices': [
          {'message': message}
        ]
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody _textReply(String text) => _completion({'content': text});

/// A backend that records what the dashboard asked of it, without any
/// wsl.exe or vmctl behind it.
class _FakeBackend extends VmBackend {
  List<String> all = ['Ubuntu', 'Debian'];
  List<String> running = ['Ubuntu'];
  final List<String> calls = [];
  bool failList = false;

  @override
  String get backendId => 'fake';

  @override
  String get instanceNoun => 'distro';

  @override
  VmFeatures get features => const VmFeatures(quickActions: true);

  @override
  Future<Instances> list(bool showDocker) async {
    calls.add('list');
    if (failList) throw Exception('backend down');
    lastDistroList = Instances(List.of(all), List.of(running));
    return lastDistroList;
  }

  @override
  Future<List<String>> listRunning() async => List.of(running);

  @override
  Future<void> start(String distribution,
      {String startPath = '', String startUser = '', String startCmd = ''}) async {
    calls.add('start $distribution');
  }

  @override
  Future<String> stop(String distribution) async {
    calls.add('stop $distribution');
    running.remove(distribution);
    return '';
  }

  @override
  Future<String> shutdown() async {
    calls.add('shutdown');
    running.clear();
    return '';
  }

  @override
  Future<String> remove(String distribution) async {
    calls.add('remove $distribution');
    all.remove(distribution);
    return '';
  }

  @override
  Future<String> export(String distribution, String location,
          {String? format}) async =>
      '';

  @override
  Future<String> import(
          String distribution, String installLocation, String filename,
          {bool isVhd = false}) async =>
      '';

  @override
  Future<String> execCmdAsRoot(String distribution, String cmd) async {
    calls.add('exec $distribution $cmd');
    if (!running.contains(distribution)) running.add(distribution);
    return 'ran: $cmd';
  }

  @override
  Future<VmCommandOutput> runInInstance(
    String instance,
    String command, {
    String user = 'root',
    String cwd = '',
    Duration timeout = const Duration(minutes: 5),
  }) async =>
      const VmCommandOutput(0, '', '');

  @override
  Future<String?> readInstanceFile(String instance, String path) async => null;

  @override
  Future<bool> writeInstanceFile(
          String instance, String path, String content) async =>
      false;

  @override
  Future<Process> startShell(String distribution, {String? user}) =>
      throw UnimplementedError();

  @override
  Future<String?> getSize(String distribution) async => '1 GB';

  @override
  String currentDistroPath(String distribution) => '/vms/$distribution';

  @override
  Future<String> getDefaultUser(String distribution) async => 'root';

  @override
  Future<void> runCommands(String instance, List<String> commands,
      {String? user, Map<String, String> env = const {}}) async {}

  @override
  Future<String> copy(String distribution, String newName) async {
    calls.add('copy $distribution $newName');
    all.add(newName);
    return '';
  }

  @override
  void startExplorer(String distribution) {}

  @override
  String instanceSizeLabel(String distribution) => '1 GB';
}

/// A fixed interface for the lister seam. A record, not a NetworkInterface:
/// see HostInterface in the service for why the real type cannot be faked
/// portably across the Flutter pin.
HostInterface _fakeInterface(String name, List<String> ips) =>
    HostInterface(name, [for (final ip in ips) InternetAddress(ip)]);

void main() {
  late _FakeBackend backend;
  late MockHttpServer mockServer;
  Handler? capturedHandler;
  Object? boundAddress;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The first-start AI question is answered with a yes here: these tests
    // are about what happens once the features are on (bostrot/ai-tasks#98).
    AiService.setFeaturesEnabled(true);
    backend = _FakeBackend();
    mockServer = MockHttpServer();
    capturedHandler = null;
    boundAddress = null;
  });

  tearDown(() async {
    // The server handle is static (see web_dashboard_service.dart), so a
    // server left "running" by one test would make the next test's start()
    // skip its own factory and leave capturedHandler null.
    await WebDashboardService().stop();
  });

  WebDashboardService service({
    NetworkInterfaceLister? interfaces,
    CloudflareTunnelService? tunnel,
  }) =>
      WebDashboardService(
        backend: backend,
        serverFactory: (handler, address, port) async {
          capturedHandler = handler;
          boundAddress = address;
          return mockServer;
        },
        interfaceLister: interfaces ?? () async => [],
        tunnel: tunnel,
      );

  Future<Response> call(
    String path, {
    String method = 'GET',
    String? token,
    Map<String, String>? headers,
    Object? body,
    Map<String, String> query = const {},
  }) async {
    final uri = Uri.parse('http://192.168.1.2:${WebDashboardService.port}$path')
        .replace(queryParameters: {
      ...query,
      if (token != null) 'token': token,
    });
    return await capturedHandler!(Request(
      method,
      uri,
      headers: headers,
      body: body == null ? null : json.encode(body),
    ));
  }

  Future<Map<String, dynamic>> decode(Response response) async =>
      json.decode(await response.readAsString()) as Map<String, dynamic>;

  test('start() binds every interface — being reachable is the point',
      () async {
    final svc = service();
    await svc.start();

    expect(boundAddress, '0.0.0.0');
    expect(svc.isRunning, true);
  });

  test('stop() closes the server, clears isRunning and tears the tunnel down',
      () async {
    final tunnel = CloudflareTunnelService(
      localPort: WebDashboardService.port,
      processSpawner: (_, __) async => throw StateError('never spawned'),
      binaryLocatorOverride: () async => 'cloudflared',
    );
    final svc = service(tunnel: tunnel);
    await svc.start();

    await svc.stop();

    expect(mockServer.closed, true);
    expect(svc.isRunning, false);
    expect(tunnel.isRunning, false);
  });

  test('a failed bind rethrows and leaves the preference off', () async {
    final svc = WebDashboardService(
      backend: backend,
      serverFactory: (_, __, ___) async => throw const SocketException('busy'),
      interfaceLister: () async => [],
    );

    await expectLater(svc.setEnabled(true), throwsA(isA<SocketException>()));

    expect(svc.isRunning, false);
    expect(prefs.getBool('WebDashboardEnabled'), false);
  });

  group('token', () {
    test('is generated once and stays stable', () {
      final svc = service();
      expect(svc.token, isNotEmpty);
      expect(svc.token, svc.token);
    });

    test('regenerateToken() rotates it and every link with it', () {
      final svc = service();
      final before = svc.localUrl;
      final rotated = svc.regenerateToken();

      expect(svc.token, rotated);
      expect(svc.localUrl, isNot(before));
      expect(svc.localUrl, contains('token=$rotated'));
    });

    test('links carry the token as a query parameter', () {
      final svc = service();
      final uri = Uri.parse(svc.urlFor('10.0.0.5'));
      expect(uri.host, '10.0.0.5');
      expect(uri.port, WebDashboardService.port);
      expect(uri.queryParameters['token'], svc.token);
    });
  });

  group('auth', () {
    test('rejects the page without a token, revealing nothing', () async {
      final svc = service();
      await svc.start();

      final response = await call('/');

      expect(response.statusCode, 403);
      final html = await response.readAsString();
      expect(html, isNot(contains('api/state')));
      expect(html, isNot(contains(svc.token)));
    });

    test('rejects an API call with the wrong token as JSON', () async {
      final svc = service();
      await svc.start();

      final response = await call('/api/state', token: 'nope');

      expect(response.statusCode, 403);
      expect((await decode(response))['ok'], false);
    });

    test('accepts the token as a query parameter', () async {
      final svc = service();
      await svc.start();

      final response = await call('/', token: svc.token);

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('text/html'));
      expect(await response.readAsString(), contains('/api/state'));
    });

    test('accepts the token in the dashboard header and as a bearer',
        () async {
      final svc = service();
      await svc.start();

      final viaHeader = await call('/api/state',
          headers: {WebDashboardService.tokenHeader: svc.token});
      final viaBearer = await call('/api/state',
          headers: {'authorization': 'Bearer ${svc.token}'});

      expect(viaHeader.statusCode, 200);
      expect(viaBearer.statusCode, 200);
    });
  });

  group('/api/state', () {
    test('lists instances with their state and the backend facts', () async {
      final svc = service();
      await svc.start();

      final body = await decode(await call('/api/state', token: svc.token));

      expect(body['host']['backend'], 'fake');
      expect(body['host']['instanceNoun'], 'distro');
      expect(body['host']['features']['quickActions'], true);
      final instances = (body['instances'] as List).cast<Map>();
      expect(instances.map((i) => i['name']), ['Ubuntu', 'Debian']);
      expect(instances.first['running'], true);
      expect(instances.last['running'], false);
      expect(instances.first['path'], '/vms/Ubuntu');
      expect(body['sessions'], isEmpty);
    });

    test('falls back to the last known list and reports the failure',
        () async {
      final svc = service();
      await svc.start();
      await call('/api/state', token: svc.token);
      backend.failList = true;

      final body = await decode(await call('/api/state', token: svc.token));

      expect(body['error'], contains('backend down'));
      expect((body['instances'] as List).length, 2);
    });
  });

  group('instance actions', () {
    test('start runs a no-op command so no window opens on the host',
        () async {
      final svc = service();
      await svc.start();

      final body = await decode(await call('/api/instances/Debian/start',
          method: 'POST', token: svc.token));

      expect(body['ok'], true);
      expect(backend.calls, contains('exec Debian true'));
      expect(backend.calls, isNot(contains('start Debian')));
    });

    test('stop, copy and shutdown reach the backend', () async {
      final svc = service();
      await svc.start();

      await call('/api/instances/Ubuntu/stop', method: 'POST', token: svc.token);
      final copy = await decode(await call('/api/instances/Ubuntu/copy',
          method: 'POST', token: svc.token, body: {'new_name': 'Ubuntu-2'}));
      await call('/api/shutdown', method: 'POST', token: svc.token);

      expect(copy['ok'], true);
      expect(backend.calls,
          containsAll(['stop Ubuntu', 'copy Ubuntu Ubuntu-2', 'shutdown']));
    });

    test('copy without a new name is a 400, not a backend call', () async {
      final svc = service();
      await svc.start();

      final response = await call('/api/instances/Ubuntu/copy',
          method: 'POST', token: svc.token, body: {'new_name': ' '});

      expect(response.statusCode, 400);
      expect(backend.calls.where((c) => c.startsWith('copy')), isEmpty);
    });

    test('actions are POST only', () async {
      final svc = service();
      await svc.start();

      final response =
          await call('/api/instances/Ubuntu/stop', token: svc.token);

      expect(response.statusCode, 405);
      expect(backend.calls, isNot(contains('stop Ubuntu')));
    });
  });

  group('/api/tools', () {
    test('lists the MCP tool set with schemas', () async {
      final svc = service();
      await svc.start();

      final body = await decode(await call('/api/tools', token: svc.token));

      final tools = (body['tools'] as List).cast<Map>();
      final names = tools.map((t) => t['name']).toSet();
      expect(names, containsAll({'wsl_list_distros', 'wsl_run_command',
          'wsl_unregister_distro', 'wsl_terminal_start'}));
      expect(tools.first['inputSchema'], isA<Map>());
    });

    test('a family switched on in Settings is listed on the next request',
        () async {
      // The container_*, kube_* and cloud_* families follow the experimental
      // switches (bostrot/ai-tasks#87); a dashboard left open should see a
      // flip without being turned off and on.
      final svc = service();
      await svc.start();

      Future<Set<dynamic>> names() async {
        final body = await decode(await call('/api/tools', token: svc.token));
        return (body['tools'] as List).cast<Map>().map((t) => t['name']).toSet();
      }

      expect(await names(), isNot(contains('kube_contexts')));
      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, true);
      expect(await names(), contains('kube_contexts'));
      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, false);
      expect(await names(), isNot(contains('kube_contexts')));
      expect(await names(), contains('wsl_list_distros'));
    });

    test('calling a tool round-trips through the backend', () async {
      final svc = service();
      await svc.start();

      final body = await decode(await call('/api/tools/wsl_run_command',
          method: 'POST',
          token: svc.token,
          body: {
            'arguments': {'distro': 'Ubuntu', 'command': 'uname -a'}
          }));

      expect(body['ok'], true);
      expect(body['text'], 'ran: uname -a');
      expect(backend.calls, contains('exec Ubuntu uname -a'));
    });

    test('a tool error comes back as ok:false, never as a 500', () async {
      final svc = service();
      await svc.start();

      final body = await decode(await call('/api/tools/wsl_unregister_distro',
          method: 'POST',
          token: svc.token,
          body: {
            'arguments': {'distro': 'Ubuntu'}
          }));

      expect(body['ok'], false);
      expect(body['error'], contains('confirm'));
      expect(backend.all, contains('Ubuntu'));
    });

    test('an unknown tool is a 404 and malformed JSON a 400', () async {
      final svc = service();
      await svc.start();

      final unknown =
          await call('/api/tools/nope', method: 'POST', token: svc.token);
      final malformed = await capturedHandler!(Request(
        'POST',
        Uri.parse('http://h:1/api/tools/wsl_list_distros?token=${svc.token}'),
        body: '{not json',
      ));

      expect(unknown.statusCode, 404);
      expect(malformed.statusCode, 400);
    });
  });

  group('/api/chat', () {
    late AiService ai;

    setUp(() async {
      // Pro, as the dashboard itself requires — the same overrides
      // ai_service_test uses. A key is what makes the assistant configured.
      LicenseManager.storeInstallCheckOverride = () => true;
      LicenseManager.storeFreeFromOverride =
          DateTime.now().toUtc().add(const Duration(days: 1));
      await LicenseManager().init();
      ai = AiService();
      await ai.init();
      ai.clearHistory();
      // No real tool registry; the test that needs tools hands over the
      // dashboard's own set.
      ai.toolsForTesting = const [];
    });

    tearDown(() async {
      ai.cancelRun();
      await WebDashboardService.chatRunForTesting;
      ai.clearHistory();
      LicenseManager.storeInstallCheckOverride = null;
      LicenseManager.storeFreeFromOverride = null;
    });

    Future<Map<String, dynamic>> chatState(WebDashboardService svc,
            {String? rev}) async =>
        decode(await call('/api/chat',
            token: svc.token, query: {if (rev != null) 'rev': rev}));

    Future<Map<String, dynamic>> send(
            WebDashboardService svc, String message) async =>
        decode(await call('/api/chat',
            method: 'POST', token: svc.token, body: {'message': message}));

    List<String> roles(Map<String, dynamic> state) => [
          for (final m in (state['messages'] as List).cast<Map>())
            m['role'] as String
        ];

    test('reports "no key" and an empty transcript before anything is set up',
        () async {
      final svc = service();
      await svc.start();

      final state = await chatState(svc);

      expect(state['configured'], false);
      expect(state['enabled'], true);
      expect(state['pro'], true);
      expect(state['busy'], false);
      expect(state['messages'], isEmpty);
      expect(state['count'], 0);
    });

    test('a send with AI switched off is refused up front and the page is told',
        () async {
      ai.setByokApiKey('sk-test');
      AiService.setFeaturesEnabled(false);
      addTearDown(() => AiService.setFeaturesEnabled(true));
      final svc = service();
      await svc.start();

      final state = await chatState(svc);
      expect(state['enabled'], false);
      expect(state['configured'], true);

      final response = await call('/api/chat',
          method: 'POST', token: svc.token, body: {'message': 'hi'});

      expect(response.statusCode, 400);
      expect((await decode(response))['error'], 'ai-disabled');
      expect(ai.conversationHistory, isEmpty);
    });

    test('a send without a key is refused up front and adds nothing',
        () async {
      final svc = service();
      await svc.start();

      final response = await call('/api/chat',
          method: 'POST', token: svc.token, body: {'message': 'hi'});

      expect(response.statusCode, 400);
      expect((await decode(response))['error'], 'byok-required');
      expect(ai.conversationHistory, isEmpty);
    });

    test('a send answers at once and the reply arrives on a later poll',
        () async {
      ai.setByokApiKey('sk-test');
      final gate = Completer<ResponseBody>();
      final provider = _ProviderAdapter((_) => gate.future);
      ai.dioForTesting.httpClientAdapter = provider;
      final svc = service();
      await svc.start();

      final started = await send(svc, 'which instances are running?');
      final midRun = await chatState(svc);

      expect(started['ok'], true);
      expect(midRun['busy'], true);
      // The question is already there while the provider thinks.
      expect(roles(midRun), ['user']);

      gate.complete(_textReply('Ubuntu is running.'));
      await WebDashboardService.chatRunForTesting;
      final done = await chatState(svc);

      expect(done['busy'], false);
      expect(done['error'], isNull);
      expect(roles(done), ['user', 'assistant']);
      expect((done['messages'] as List).last['content'], 'Ubuntu is running.');
      // Sent to the provider on the key from the app; the key itself is
      // not part of anything the page receives.
      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.headers['Authorization'],
          'Bearer sk-test');
      final body = json.decode(provider.requests.single.data as String)
          as Map<String, dynamic>;
      expect((body['messages'] as List).last['content'],
          'which instances are running?');
      expect(json.encode(done), isNot(contains('sk-test')));
    });

    test("the assistant drives the dashboard's tools against the backend",
        () async {
      ai.setByokApiKey('sk-test');
      ai.toolsForTesting =
          buildWslMcpTools(backend, WslTerminalManager(wslApi: backend));
      var round = 0;
      ai.dioForTesting.httpClientAdapter = _ProviderAdapter((_) async {
        round++;
        if (round == 1) {
          return _completion({
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'wsl_run_command',
                  'arguments':
                      json.encode({'distro': 'Ubuntu', 'command': 'uptime'}),
                },
              }
            ],
          });
        }
        return _textReply('Up for 3 days.');
      });
      final svc = service();
      await svc.start();

      await send(svc, 'how long has Ubuntu been up?');
      await WebDashboardService.chatRunForTesting;
      final state = await chatState(svc);

      expect(backend.calls, contains('exec Ubuntu uptime'));
      final messages = (state['messages'] as List).cast<Map>();
      expect(roles(state), contains('tool'));
      expect(messages.firstWhere((m) => m['role'] == 'tool')['content'],
          'wsl_run_command');
      expect(messages.last['role'], 'assistant');
      expect(messages.last['content'], 'Up for 3 days.');
      expect(state['busy'], false);
    });

    test('one run at a time: send, retry and clear are 409 until it is stopped',
        () async {
      ai.setByokApiKey('sk-test');
      // Never answers — the run only ends when it is cancelled.
      ai.dioForTesting.httpClientAdapter =
          _ProviderAdapter((_) => Completer<ResponseBody>().future);
      final svc = service();
      await svc.start();
      await send(svc, 'first');

      final second = await call('/api/chat',
          method: 'POST', token: svc.token, body: {'message': 'second'});
      final retry =
          await call('/api/chat/retry', method: 'POST', token: svc.token);
      final clear =
          await call('/api/chat/clear', method: 'POST', token: svc.token);

      expect(second.statusCode, 409);
      expect(retry.statusCode, 409);
      expect(clear.statusCode, 409);
      expect(ai.conversationHistory.map((m) => m.content), ['first']);

      final cancel = await decode(
          await call('/api/chat/cancel', method: 'POST', token: svc.token));
      await WebDashboardService.chatRunForTesting;
      final state = await chatState(svc);

      expect(cancel['ok'], true);
      expect(state['busy'], false);
      expect(state['error'], 'cancelled');
      // The question stays, as after any interrupted run, so retry works.
      expect(roles(state), ['user']);
    });

    test('a failed provider request is reported as a code and retry re-runs',
        () async {
      ai.setByokApiKey('sk-test');
      var fail = true;
      ai.dioForTesting.httpClientAdapter = _ProviderAdapter((_) async => fail
          ? ResponseBody.fromString('server error', 500)
          : _textReply('ok now'));
      final svc = service();
      await svc.start();

      await send(svc, 'hello');
      await WebDashboardService.chatRunForTesting;
      final failed = await chatState(svc);

      expect(failed['busy'], false);
      expect(failed['error'], 'byok-request-failed');
      expect(roles(failed), ['user']);

      fail = false;
      final retried = await decode(
          await call('/api/chat/retry', method: 'POST', token: svc.token));
      await WebDashboardService.chatRunForTesting;
      final state = await chatState(svc);

      expect(retried['ok'], true);
      expect(state['error'], isNull);
      expect(roles(state), ['user', 'assistant']);
      expect((state['messages'] as List).last['content'], 'ok now');
    });

    test('a poll with the revision it already holds gets no messages',
        () async {
      ai.setByokApiKey('sk-test');
      ai.dioForTesting.httpClientAdapter =
          _ProviderAdapter((_) async => _textReply('hi'));
      final svc = service();
      await svc.start();
      await send(svc, 'hello');
      await WebDashboardService.chatRunForTesting;

      final full = await chatState(svc);
      final unchanged = await chatState(svc, rev: '${full['revision']}');
      await call('/api/chat/clear', method: 'POST', token: svc.token);
      final afterClear = await chatState(svc, rev: '${full['revision']}');

      expect(full['messages'], hasLength(2));
      expect(unchanged.containsKey('messages'), false);
      expect(unchanged['count'], 2);
      // Clearing on the phone clears the shared transcript.
      expect(afterClear['messages'], isEmpty);
      expect(afterClear['revision'], isNot(full['revision']));
      expect(ai.conversationHistory, isEmpty);
    });

    test('a malformed body, an empty message or a GET action is no run',
        () async {
      ai.setByokApiKey('sk-test');
      final provider = _ProviderAdapter((_) async => _textReply('never'));
      ai.dioForTesting.httpClientAdapter = provider;
      final svc = service();
      await svc.start();

      final malformed = await capturedHandler!(Request(
        'POST',
        Uri.parse('http://h:1/api/chat?token=${svc.token}'),
        body: '{not json',
      ));
      final empty = await call('/api/chat',
          method: 'POST', token: svc.token, body: {'message': '  '});
      final wrongMethod = await call('/api/chat/cancel', token: svc.token);

      expect(malformed.statusCode, 400);
      expect(empty.statusCode, 400);
      expect(wrongMethod.statusCode, 405);
      expect(provider.requests, isEmpty);
      expect(ai.conversationHistory, isEmpty);
    });

    test('needs the token like every other endpoint', () async {
      final svc = service();
      await svc.start();

      final response = await call('/api/chat', token: 'nope');

      expect(response.statusCode, 403);
    });
  });

  group('page', () {
    test('carries the Assistant tab and talks to /api/chat', () {
      expect(webDashboardHtml, contains('data-tab="chat"'));
      expect(webDashboardHtml, contains("'/api/chat'"));
      expect(webDashboardHtml, contains("'/api/chat/'"));
    });

    test('reads the AI switch out of every poll, not just the initial state',
        () {
      // The notice and the disabled Send both key off `chat.enabled`; a poll
      // that does not copy the flag leaves them at their initial `true`.
      expect(webDashboardHtml, contains('enabled: data.enabled !== false'));
      expect(webDashboardHtml, contains("CHAT_ERRORS['ai-disabled']"));
    });

    test('keeps a gap between the sticky header and the content', () {
      // The body is `<main class="wrap">`; a bare `main{padding-top}` rule
      // loses to the `.wrap` padding shorthand, so the gap must live there.
      final wrap = RegExp(r'\.wrap\{([^}]*)\}').firstMatch(webDashboardHtml);
      expect(wrap, isNotNull);
      expect(wrap!.group(1), matches(RegExp(r'padding:(?!0[ ;])\d+px')));
      expect(webDashboardHtml, isNot(matches(RegExp(r'\bmain\{[^}]*padding'))));
    });
  });

  group('share links', () {
    test('lanAddresses() drops loopback and link-local and prefers private',
        () async {
      final svc = service(
        interfaces: () async => [
          _fakeInterface('en0', ['203.0.113.7', '10.1.2.3']),
          _fakeInterface('lo0', ['127.0.0.1']),
          _fakeInterface('awdl0', ['169.254.10.10']),
          _fakeInterface('en1', ['192.168.1.20']),
        ],
      );

      expect(await svc.lanAddresses(),
          ['192.168.1.20', '10.1.2.3', '203.0.113.7']);
      final urls = await svc.shareUrls();
      expect(urls.first, svc.urlFor('192.168.1.20'));
      expect(urls, everyElement(contains('token=${svc.token}')));
    });

    test('a failing interface probe yields no LAN links, not an exception',
        () async {
      final svc = service(interfaces: () async => throw Exception('no net'));

      expect(await svc.lanAddresses(), isEmpty);
    });

    test('tunnelUrl is null until the tunnel is up and carries the token',
        () async {
      final svc = service(
        tunnel: CloudflareTunnelService(
          localPort: WebDashboardService.port,
          processSpawner: (_, __) async => throw StateError('never spawned'),
          binaryLocatorOverride: () async => 'cloudflared',
        ),
      );

      expect(svc.tunnelUrl, isNull);
    });
  });

  test('setEnabled persists the preference and starts/stops the server',
      () async {
    final svc = service();

    await svc.setEnabled(true);
    expect(prefs.getBool('WebDashboardEnabled'), true);
    expect(svc.isRunning, true);

    await svc.setEnabled(false);
    expect(prefs.getBool('WebDashboardEnabled'), false);
    expect(svc.isRunning, false);
  });
}
