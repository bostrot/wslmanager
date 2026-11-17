import 'package:fluent_ui/fluent_ui.dart' show InfoBarSeverity;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/containers/container_service.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'container_service_test.dart' show psLine;
import 'fake_container_shell.dart';
import 'vm_backend_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {};
  });

  late FakeContainerShell shell;
  late Map<String, Future<String> Function(Map<String, dynamic>)> handlers;
  late List<String> names;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The family rides behind the same gate the Containers screen does; these
    // tests are about the tools themselves, so open it.
    ExperimentalFeatures.overrideAll = true;
    shell = FakeContainerShell();
    final backend = FakeBackend();
    final tools = buildWslMcpTools(
      backend,
      WslTerminalManager(wslApi: backend),
      // Off Windows, so the engine list is Docker and Podman whichever
      // host runs the suite; wslc has its own tests.
      containerService: ContainerService(shell: shell, isWindows: false),
    );
    handlers = {for (final t in tools) t.name: t.handler};
    names = tools.map((t) => t.name).toList();
  });

  tearDown(() => ExperimentalFeatures.overrideAll = null);

  test('the family is not registered while Containers is unreleased', () {
    // An MCP client is as much a shipped surface as the nav pane, so a
    // hidden screen must not leave its tools reachable from Claude Desktop.
    ExperimentalFeatures.overrideAll = false;
    final backend = FakeBackend();
    final hidden = buildWslMcpTools(backend, WslTerminalManager(wslApi: backend))
        .map((t) => t.name);
    expect(hidden.where((n) => n.startsWith('container_')), isEmpty);
    // The rest of the surface is untouched.
    expect(hidden, contains('wsl_list_distros'));
  });

  test('the container family is registered on every backend', () {
    expect(
        names,
        containsAll([
          'container_list',
          'container_engines',
          'container_start',
          'container_stop',
          'container_restart',
          'container_remove',
          'container_logs',
          'container_exec',
          'container_inspect',
        ]));
  });

  test('container_list reports every engine and its containers', () async {
    shell.responses['docker ps'] =
        psLine('a1', 'web', 'nginx:latest', 'running', 'Up 2 hours', '80/tcp');
    shell.responses['podman ps'] = psLine('b2', 'db', 'postgres', 'exited');

    final out = await handlers['container_list']!({});
    expect(out, contains('[docker] web (running)'));
    expect(out, contains('[podman] db (exited)'));
  });

  test('container_list says so when the host has no containers', () async {
    final out = await handlers['container_list']!({});
    expect(out, contains('No containers'));
  });

  test('container_list restricted to one engine only asks that one', () async {
    shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
    await handlers['container_list']!({'engine': 'docker'});
    expect(shell.calls.where((c) => c.first == 'podman' && c.contains('ps')),
        isEmpty);
  });

  test('an unknown engine name is refused', () async {
    expect(() => handlers['container_list']!({'engine': 'containerd'}),
        throwsArgumentError);
  });

  test('container_engines lists what is installed and which one is active',
      () async {
    shell.missing.add('podman');
    final out = await handlers['container_engines']!({});
    expect(out, contains('Docker'));
    expect(out, contains('active'));
    expect(out, isNot(contains('Podman')));
  });

  test('every tool explains itself when no engine is installed', () async {
    shell.missing.addAll(['docker', 'podman']);
    for (final tool in ['container_list', 'container_engines']) {
      final out = await handlers[tool]!({});
      expect(out, contains('No container engine found'), reason: tool);
    }
    expect(() => handlers['container_stop']!({'container': 'web'}),
        throwsArgumentError);
  });

  test('container_start and container_stop drive the engine', () async {
    expect(await handlers['container_start']!({'container': 'web'}),
        contains('Started web'));
    expect(shell.calls.last, ['docker', 'start', 'web']);

    expect(await handlers['container_stop']!({'container': 'web'}),
        contains('Stopped web'));
    expect(shell.calls.last, ['docker', 'stop', 'web']);
  });

  test('container_remove refuses without the confirm flag', () async {
    expect(() => handlers['container_remove']!({'container': 'web'}),
        throwsArgumentError);
    expect(shell.calls.where((c) => c.contains('rm')), isEmpty);

    final out = await handlers['container_remove']!(
        {'container': 'web', 'confirm': true, 'force': true});
    expect(out, contains('Removed web'));
    expect(shell.calls.last, ['docker', 'rm', '--force', 'web']);
  });

  test('container_logs defaults to a bounded tail', () async {
    shell.responses['docker logs'] = 'hello';
    final out = await handlers['container_logs']!({'container': 'web'});
    expect(out, 'hello');
    expect(shell.calls.last, ['docker', 'logs', '--tail', '200', 'web']);
  });

  test('container_exec returns the command output', () async {
    shell.responses['docker exec'] = 'root';
    final out = await handlers['container_exec']!(
        {'container': 'web', 'command': 'whoami'});
    expect(out, 'root');
  });

  test('container_exec needs both a container and a command', () async {
    expect(() => handlers['container_exec']!({'container': 'web'}),
        throwsArgumentError);
    expect(() => handlers['container_exec']!({'command': 'whoami'}),
        throwsArgumentError);
  });

  test('the pinned engine is what the tools use by default', () async {
    await prefs.setString(containerEnginePrefKey, 'podman');
    await handlers['container_start']!({'container': 'web'});
    expect(shell.calls.last, ['podman', 'start', 'web']);
  });

  // The read-only half of the family (bostrot/ai-tasks#67): everything a
  // person would type at a terminal to work out why a container is unhappy,
  // and nothing that could change the host.
  group('read-only host inspection', () {
    test('the read-only tools are registered', () {
      expect(
          names,
          containsAll([
            'container_images',
            'container_volumes',
            'container_networks',
            'container_stats',
            'container_processes',
            'container_disk_usage',
          ]));
    });

    test('container_images asks for the four columns worth reading', () async {
      shell.responses['docker images'] = 'nginx:latest\ta1\t142MB\t2 days ago';
      final out = await handlers['container_images']!({});
      expect(out, contains('nginx:latest'));
      expect(shell.calls.last.first, 'docker');
      expect(shell.calls.last, contains('images'));
    });

    test('container_volumes and container_networks read, never prune',
        () async {
      shell.responses['docker volume'] = 'pgdata\tlocal';
      shell.responses['docker network'] = 'bridge\tbridge\tlocal';
      expect(await handlers['container_volumes']!({}), contains('pgdata'));
      expect(await handlers['container_networks']!({}), contains('bridge'));
      expect(shell.calls.map((c) => c.join(' ')),
          everyElement(isNot(contains('prune'))));
    });

    test('container_stats never streams, which would hit the timeout instead '
        'of answering', () async {
      shell.responses['docker stats'] = 'web\t2.5%\t40MiB / 2GiB\t1kB\t0B';
      final out = await handlers['container_stats']!({});
      expect(out, contains('2.5%'));
      expect(shell.calls.last, contains('--no-stream'));
    });

    test('container_stats can sample one container', () async {
      shell.responses['docker stats'] = 'web\t2.5%';
      await handlers['container_stats']!({'container': 'web'});
      expect(shell.calls.last.last, 'web');
    });

    test('container_processes works on an image with no shell', () async {
      // `top` asks the host, so unlike container_exec it does not need a
      // shell inside the image — which is the whole reason it exists.
      shell.responses['docker top'] = 'UID   PID   CMD\nroot  1     nginx';
      final out =
          await handlers['container_processes']!({'container': 'web'});
      expect(out, contains('nginx'));
      expect(shell.calls.last, ['docker', 'top', 'web']);
    });

    test('container_disk_usage reports what a prune would reclaim without '
        'reclaiming it', () async {
      shell.responses['docker system'] = 'TYPE   TOTAL  RECLAIMABLE';
      final out = await handlers['container_disk_usage']!({});
      expect(out, contains('RECLAIMABLE'));
      expect(shell.calls.last, ['docker', 'system', 'df']);
    });

    test('an empty answer is a sentence, not a blank', () async {
      shell.responses['docker images'] = '';
      expect(await handlers['container_images']!({}),
          'No images on this host.');
    });
  });

  group('container_logs filtering', () {
    setUp(() {
      shell.responses['docker logs'] = [
        'listening on :8080',
        'ERROR upstream timeout',
        '  at proxy.go:41',
        'served 200',
      ].join('\n');
    });

    test('since and timestamps are flags on the engine, not filtering here',
        () async {
      await handlers['container_logs']!(
          {'container': 'web', 'since': '15m', 'timestamps': true});
      expect(shell.calls.last, contains('--since=15m'));
      expect(shell.calls.last, contains('--timestamps'));
      // The container ref stays last, after every flag.
      expect(shell.calls.last.last, 'web');
    });

    test('a since that is not a duration never reaches the engine', () async {
      await expectLater(
          handlers['container_logs']!(
              {'container': 'web', 'since': 'last tuesday'}),
          throwsArgumentError);
    });

    test('contains narrows the log and says how much it dropped', () async {
      final out = await handlers['container_logs']!(
          {'container': 'web', 'contains': 'error'});
      expect(out, startsWith('1 of 4 lines matched "error":'));
      expect(out, contains('upstream timeout'));
      expect(out, isNot(contains('served 200')));
    });

    test('context_lines keeps the frame under the match', () async {
      final out = await handlers['container_logs']!(
          {'container': 'web', 'contains': 'ERROR', 'context_lines': 1});
      expect(out, contains('at proxy.go:41'));
      expect(out, contains('listening on :8080'));
    });

    test('an unfiltered log is untouched', () async {
      final out = await handlers['container_logs']!({'container': 'web'});
      expect(out, contains('listening on :8080'));
      expect(out, contains('served 200'));
    });
  });
}
