import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/app.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/apple/vm_image_catalog.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/sandbox_service.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_vmctl_shell.dart';
import 'mocks.dart';

class _FakeApp extends App {
  _FakeApp(this.links);
  final Map<String, String> links;
  @override
  Future<Map<String, String>> getDistroLinks({String? architecture}) async =>
      links;
}

/// A catalog that hands back a local path without touching the network, and
/// remembers which entry it was asked for.
class _FakeCatalog extends VmImageCatalog {
  _FakeCatalog(this.path);
  final String path;
  VmIsoCatalogEntry? requested;

  @override
  Future<String> download(
    VmIsoCatalogEntry entry, {
    void Function(int received, int total)? onProgress,
    CancelSignal? cancelSignal,
  }) async {
    requested = entry;
    onProgress?.call(1, 2);
    return path;
  }
}

class _StringAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) responder;
  final List<RequestOptions> requests = [];
  _StringAdapter(this.responder);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The first-start AI question is answered with a yes here: these tests
    // are about what happens once the features are on (bostrot/ai-tasks#98).
    AiService.setFeaturesEnabled(true);
    LicenseManager.storeInstallCheckOverride = () => false;
    // A Store copy here is a paid-era one: hold the flip in the future so
    // package identity alone is Pro.
    LicenseManager.storeFreeFromOverride =
        DateTime.now().toUtc().add(const Duration(days: 1));
    await LicenseManager().init();
  });

  tearDown(() {
    LicenseManager.storeInstallCheckOverride = null;
    LicenseManager.storeFreeFromOverride = null;
  });

  group('SandboxService', () {
    test('tracks sandbox names in prefs', () {
      final svc = SandboxService();
      expect(svc.list(), isEmpty);
      expect(svc.isSandbox('wslm-sandbox-x'), false);
      expect(svc.distroNameFor('My Box!'), 'wslm-sandbox-My_Box_');
    });

    test('createUbuntuSandbox picks Ubuntu, downloads, imports, records',
        () async {
      final shell = MockShell();
      final api = WSLApi(shell: shell);
      final dio = Dio()
        ..httpClientAdapter = _StringAdapter(
            (_) => ResponseBody.fromString('rootfs-bytes', 200));
      final svc = SandboxService(
        backend: api,
        app: _FakeApp({
          'Alpine': 'https://example.com/alpine.tar.gz',
          'Ubuntu-24.04': 'https://example.com/ubuntu-2404.tar.gz',
          'Ubuntu-22.04': 'https://example.com/ubuntu-2204.tar.gz',
        }),
        dio: dio,
      );

      final distro = await svc.createUbuntuSandbox('play');

      expect(distro, 'wslm-sandbox-play');
      expect(svc.list(), contains('wslm-sandbox-play'));
      expect(svc.isSandbox('wslm-sandbox-play'), true);
      // Imported via wsl --import, not some other distro's rootfs.
      expect(shell.runCalls.any((c) => c.contains('--import')), true);
    });

    test('refuses a blank name', () async {
      await expectLater(
          SandboxService(backend: WSLApi(shell: MockShell()))
              .createUbuntuSandbox('   '),
          throwsArgumentError);
    });

    test('a named catalog image overrides the Ubuntu default', () async {
      final adapter = _StringAdapter(
          (_) => ResponseBody.fromString('rootfs-bytes', 200));
      final svc = SandboxService(
        backend: WSLApi(shell: MockShell()),
        app: _FakeApp({
          'Alpine': 'https://example.com/alpine.tar.gz',
          'Ubuntu-24.04': 'https://example.com/ubuntu-2404.tar.gz',
        }),
        dio: Dio()..httpClientAdapter = adapter,
      );

      await svc.createUbuntuSandbox('alp', image: 'Alpine');

      expect(adapter.requests.single.path,
          'https://example.com/alpine.tar.gz');
    });

    test('creation publishes stage and clears it when done', () async {
      final svc = SandboxService(
        backend: WSLApi(shell: MockShell()),
        app: _FakeApp({'Ubuntu-24.04': 'https://example.com/u.tar.gz'}),
        dio: Dio()
          ..httpClientAdapter = _StringAdapter(
              (_) => ResponseBody.fromString('rootfs-bytes', 200)),
      );
      final stages = <String?>[];
      void listener() => stages.add(SandboxService.creationStage.value);
      SandboxService.creationStage.addListener(listener);
      addTearDown(
          () => SandboxService.creationStage.removeListener(listener));

      await svc.createUbuntuSandbox('stagey');

      expect(stages, containsAllInOrder(['resolving', 'downloading', 'importing', null]));
      expect(SandboxService.isCreating, false);
    });
  });

  group('SandboxService on the Apple backend', () {
    late FakeVmctlShell shell;
    late AppleVmApi api;
    late Directory store;

    /// A store with no VMs first (the name-collision check), then one running
    /// VM (the post-start liveness check).
    void scriptAHealthyCreate(String distro) {
      shell.responseQueue['list'] = [
        '{"vms":[]}',
        '{"vms":[{"name":"$distro","state":"running","os":"linux"}]}',
      ];
      shell.responses['list'] =
          '{"vms":[{"name":"$distro","state":"running","os":"linux"}]}';
      shell.responses['create'] = '{"created":"$distro"}';
      shell.responses['start'] = '{"started":"$distro"}';
    }

    SandboxService service(_FakeCatalog catalog) =>
        SandboxService(backend: api, catalog: catalog);

    setUp(() {
      shell = FakeVmctlShell();
      store = Directory.systemTemp.createTempSync('sandbox-apple-test');
      api = AppleVmApi(
        shell: shell,
        helperPathOverride: '/fake/vmctl',
        storeDirOverride: store.path,
        earlyExitProbeDelay: Duration.zero,
      );
      SandboxService.bootProbeDelay = Duration.zero;
      SandboxService.bootProbeAttempts = 3;
    });

    tearDown(() {
      if (store.existsSync()) store.deleteSync(recursive: true);
      SandboxService.bootProbeDelay = const Duration(seconds: 3);
      SandboxService.bootProbeAttempts = 40;
    });

    List<String> callWith(String verb) =>
        shell.calls.lastWhere((c) => c.contains(verb));

    test('creates a VM from the newest Ubuntu cloud image and boots it',
        () async {
      scriptAHealthyCreate('wslm-sandbox-play');
      final catalog = _FakeCatalog('/tmp/ubuntu-cloud.img');

      final name = await service(catalog).createUbuntuSandbox('play');

      expect(name, 'wslm-sandbox-play');
      // The default is a cloud image — an installer ISO would sit at its own
      // console waiting for a human, which no sandbox can use.
      expect(catalog.requested!.isCloudImage, true);
      expect(catalog.requested!.id, 'ubuntu-26-04-cloud');
      // Seeded from that image, under the sandbox name…
      final create = callWith('create');
      expect(create, containsAllInOrder(['--name', 'wslm-sandbox-play']));
      expect(create, containsAllInOrder(['--image', '/tmp/ubuntu-cloud.img']));
      // …and started, so the chat has something to talk to.
      expect(callWith('start'), contains('wslm-sandbox-play'));
      expect(SandboxService(backend: api).list(),
          contains('wslm-sandbox-play'));
    });

    test('a named cloud image overrides the Ubuntu default', () async {
      scriptAHealthyCreate('wslm-sandbox-deb');
      final catalog = _FakeCatalog('/tmp/debian.raw');

      await service(catalog)
          .createUbuntuSandbox('deb', image: 'Debian 13 (cloud image)');

      expect(catalog.requested!.id, 'debian-13-cloud');
    });

    test('an installer ISO is refused, and nothing is created', () async {
      scriptAHealthyCreate('wslm-sandbox-iso');
      final catalog = _FakeCatalog('/tmp/never.iso');

      await expectLater(
          service(catalog)
              .createUbuntuSandbox('iso', image: 'Debian (netinst)'),
          throwsStateError);

      expect(catalog.requested, isNull);
      expect(shell.calls.any((c) => c.contains('create')), false);
      expect(SandboxService(backend: api).list(), isEmpty);
      expect(SandboxService.isCreating, false);
    });

    test('an existing VM of the same name is a collision, not an overwrite',
        () async {
      shell.responses['list'] =
          '{"vms":[{"name":"wslm-sandbox-taken","state":"stopped"}]}';
      final catalog = _FakeCatalog('/tmp/img');

      await expectLater(
          service(catalog).createUbuntuSandbox('taken'), throwsStateError);

      expect(shell.calls.any((c) => c.contains('create')), false);
    });

    test('a guest that never answers still leaves a created sandbox',
        () async {
      scriptAHealthyCreate('wslm-sandbox-slow');
      // Every SSH probe fails: the VM exists and is booting, it is simply not
      // reachable yet. Throwing here would discard a multi-GB download.
      shell.exitCodes['exec'] = 255;

      final name =
          await service(_FakeCatalog('/tmp/img')).createUbuntuSandbox('slow');

      expect(name, 'wslm-sandbox-slow');
      expect(SandboxService(backend: api).list(), contains(name));
      expect(
          shell.calls.where((c) => c.contains('exec')).length,
          SandboxService.bootProbeAttempts);
    });

    test('a VM that fails to start is still listed, so it can be deleted',
        () async {
      shell.responseQueue['list'] = ['{"vms":[]}'];
      shell.responses['list'] =
          '{"vms":[{"name":"wslm-sandbox-dud","state":"stopped"}]}';
      shell.responses['create'] = '{"created":"wslm-sandbox-dud"}';
      shell.exitCodes['start'] = 1;
      shell.errors['start'] = 'no bootable device';

      await expectLater(
          service(_FakeCatalog('/tmp/img')).createUbuntuSandbox('dud'),
          throwsA(isA<AppleVmException>()));

      // The VM exists on disk; a name the list never learned about would be
      // taken with no delete button anywhere to release it.
      expect(SandboxService(backend: api).list(),
          contains('wslm-sandbox-dud'));
    });

    test('deleting stops the VM first — vmctl refuses to delete a running one',
        () async {
      scriptAHealthyCreate('wslm-sandbox-gone');
      final svc = service(_FakeCatalog('/tmp/img'));
      await svc.createUbuntuSandbox('gone');
      shell.calls.clear();

      await svc.deleteSandbox('wslm-sandbox-gone');

      final verbs = shell.calls
          .map((c) => c.firstWhere((a) => a == 'stop' || a == 'delete',
              orElse: () => ''))
          .where((v) => v.isNotEmpty)
          .toList();
      expect(verbs, ['stop', 'delete']);
      expect(svc.list(), isEmpty);
    });

    test('publishes every stage and clears it when done', () async {
      scriptAHealthyCreate('wslm-sandbox-stagey');
      final stages = <String?>[];
      void listener() => stages.add(SandboxService.creationStage.value);
      SandboxService.creationStage.addListener(listener);
      addTearDown(
          () => SandboxService.creationStage.removeListener(listener));

      await service(_FakeCatalog('/tmp/img')).createUbuntuSandbox('stagey');

      expect(
          stages,
          containsAllInOrder(
              ['resolving', 'downloading', 'creating', 'starting', null]));
      expect(SandboxService.isCreating, false);
    });

    test('offers only cloud images as sandbox images', () async {
      final choices = await SandboxService(backend: api).imageChoices();

      expect(choices, isNotEmpty);
      expect(choices, contains('Ubuntu 26.04 LTS (cloud image)'));
      expect(choices.any((name) => name.contains('netinst')), false);
      for (final name in choices) {
        expect(VmImageCatalog.entryFor(name)!.isCloudImage, true);
      }
    });

    test('sandbox tools reach the VM through vmctl, never wsl.exe', () async {
      shell.responses['exec'] = 'root';
      final tools = buildSandboxTools(
          api, WslTerminalManager(wslApi: api), 'wslm-sandbox-box');

      final out = await tools
          .firstWhere((t) => t.name == 'sandbox_run_command')
          .handler({'command': 'whoami'});

      expect(out, 'root');
      final call = callWith('exec');
      expect(call.first, '/fake/vmctl');
      final nameIndex = call.indexOf('--name');
      expect(nameIndex, isNonNegative);
      expect(call[nameIndex + 1], 'wslm-sandbox-box');
      expect(call.last, 'whoami');
    });

    test('a failing command reports its exit code instead of "(no output)"',
        () async {
      shell.exitCodes['exec'] = 3;
      shell.errors['exec'] = 'no such file';
      final tools = buildSandboxTools(
          api, WslTerminalManager(wslApi: api), 'wslm-sandbox-box');

      final out = await tools
          .firstWhere((t) => t.name == 'sandbox_run_command')
          .handler({'command': 'cat /nope'});

      expect(out, contains('Exit code 3'));
      expect(out, contains('no such file'));
    });
  });

  group('buildSandboxTools scoping', () {
    late MockShell shell;
    late WSLApi api;
    late WslTerminalManager tm;

    setUp(() {
      shell = MockShell();
      api = WSLApi(shell: shell);
      tm = WslTerminalManager(wslApi: api);
    });

    McpTool tool(String name) =>
        buildSandboxTools(api, tm, 'wslm-sandbox-box')
            .firstWhere((t) => t.name == name);

    test('only sandbox_* tools, no lifecycle or other-distro access', () {
      final names = buildSandboxTools(api, tm, 'wslm-sandbox-box')
          .map((t) => t.name)
          .toSet();
      expect(names, {
        'sandbox_run_command',
        'sandbox_write_file',
        'sandbox_read_file',
        'sandbox_terminal_start',
        'sandbox_terminal_send',
        'sandbox_terminal_read',
        'sandbox_terminal_close',
      });
      // No way to name another distro, unregister, or reach the host.
      expect(names.any((n) => n.contains('unregister')), false);
      expect(names.any((n) => n.contains('list_distros')), false);
    });

    test('run_command is hardcoded to the sandbox distro', () async {
      await tool('sandbox_run_command').handler({'command': 'whoami'});
      // The -d flag names the sandbox, and only the sandbox — the command has
      // no distro argument to override it.
      final call = shell.runCalls.last;
      final dIndex = call.indexOf('-d');
      expect(dIndex, isNonNegative);
      expect(call[dIndex + 1], 'wslm-sandbox-box');
    });
  });

  group('SandboxChat', () {
    test('runs the agent with the sandbox tools and returns the answer',
        () async {
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      final ai = AiService();
      ai.setByokApiKey('sk-test');

      final chat = SandboxChat.forTesting('wslm-sandbox-box', service: ai);
      // A trivial tool so the loop has something scoped to offer, though the
      // model answers directly here.
      chat.toolsForTesting = [
        McpTool(
          name: 'sandbox_noop',
          description: 'noop',
          inputSchema: const {'type': 'object', 'properties': {}},
          handler: (_) async => 'ok',
        )
      ];

      ai.dioForTesting.httpClientAdapter = _StringAdapter((_) =>
          ResponseBody.fromString(
            json.encode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'inside sandbox'}
                }
              ]
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType]
            },
          ));

      final reply = await chat.send('hi');
      expect(reply, 'inside sandbox');
      expect(chat.history.where((m) => m.role == 'user'), hasLength(1));
      expect(chat.history.where((m) => m.role == 'assistant'), hasLength(1));
    });

    test('throws pro-required when not Pro', () async {
      final chat = SandboxChat.forTesting('wslm-sandbox-box');
      await expectLater(chat.send('hi'),
          throwsA(predicate((e) => e.toString().contains('pro-required'))));
    });

    test('history persists across close and reopen', () {
      // The user-visible guarantee: closing the panel and reopening the chat
      // comes back to the same conversation, not an empty one.
      prefs.setStringList('SandboxDistros', ['wslm-sandbox-persist']);
      prefs.setString(
          'SandboxChat_wslm-sandbox-persist',
          json.encode([
            AiMessage(
                    role: 'user',
                    content: 'remember me',
                    timestamp: DateTime.now())
                .toJson()
          ]));

      final chat = SandboxChat.of('wslm-sandbox-persist');
      expect(chat.history.single.content, 'remember me');
      // It shows up in the "last sessions" list…
      expect(SandboxChat.sessions(), contains('wslm-sandbox-persist'));
      // …and the same instance comes back on reopen.
      expect(identical(chat, SandboxChat.of('wslm-sandbox-persist')), true);

      SandboxChat.dropTranscript('wslm-sandbox-persist');
      expect(prefs.getString('SandboxChat_wslm-sandbox-persist'), isNull);
    });
  });
}
