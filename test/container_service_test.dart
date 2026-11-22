import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/containers/container_models.dart';
import 'package:wsl2distromanager/api/containers/container_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_container_shell.dart';

/// `ps --format` output: the tab-separated template the service asks for.
String psLine(String id, String name, String image, String state,
        [String status = '', String ports = '']) =>
    [id, name, image, state, status, ports].join('\t');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeContainerShell shell;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    shell = FakeContainerShell();
  });

  /// Off Windows by default, which is where the pre-`wslc` expectations
  /// below were written: the Windows-only engine is probed only when a test
  /// asks for a Windows host, so the same assertions hold on the Windows CI
  /// job as on a Mac.
  ContainerService service({Duration? timeout, bool isWindows = false}) =>
      ContainerService(
          shell: shell,
          isWindows: isWindows,
          timeout: timeout ?? const Duration(seconds: 30));

  group('parsePsOutput', () {
    test('reads every field of a row', () {
      final containers = ContainerService.parsePsOutput(
        psLine('abc123', 'web', 'nginx:latest', 'running', 'Up 2 hours',
            '0.0.0.0:8080->80/tcp'),
        ContainerEngine.docker,
      );

      expect(containers, hasLength(1));
      final container = containers.single;
      expect(container.id, 'abc123');
      expect(container.name, 'web');
      expect(container.image, 'nginx:latest');
      expect(container.state, ContainerState.running);
      expect(container.status, 'Up 2 hours');
      expect(container.ports, '0.0.0.0:8080->80/tcp');
      expect(container.engine, ContainerEngine.docker);
      expect(container.ref, 'web');
    });

    test('falls back to the status word when .State comes back empty', () {
      // Engines older than the `.State` field leave that column blank; the
      // first word of `.Status` is the same information.
      final containers = ContainerService.parsePsOutput(
        psLine('abc123', 'web', 'nginx', '', 'Exited (0) 3 minutes ago'),
        ContainerEngine.podman,
      );
      expect(containers.single.state, ContainerState.exited);
    });

    test('keeps an unknown state instead of dropping the row', () {
      final containers = ContainerService.parsePsOutput(
        psLine('abc123', 'web', 'nginx', 'wedged'),
        ContainerEngine.docker,
      );
      expect(containers.single.state, ContainerState.unknown);
      expect(containers.single.name, 'web');
    });

    test('skips banner lines that are not containers', () {
      // podman-docker prints this on stdout before the table.
      final output = [
        'Emulate Docker CLI using podman. Create /etc/containers/nodocker',
        '',
        psLine('abc123', 'web', 'nginx', 'running'),
      ].join('\n');

      final containers =
          ContainerService.parsePsOutput(output, ContainerEngine.podman);
      expect(containers, hasLength(1));
      expect(containers.single.name, 'web');
    });

    test('falls back to the id when a container has no name', () {
      final containers = ContainerService.parsePsOutput(
        psLine('abc123', '', 'nginx', 'running'),
        ContainerEngine.docker,
      );
      expect(containers.single.ref, 'abc123');
    });
  });

  group('engine detection', () {
    test('finds only the engines that answer --version', () async {
      shell.missing.add('podman');
      final engines = await service().availableEngines();
      expect(engines, [ContainerEngine.docker]);
    });

    test('reports none when neither engine is installed', () async {
      shell.missing.addAll(['docker', 'podman']);
      expect(await service().availableEngines(), isEmpty);
      expect(await service().activeEngine(), isNull);
    });

    test('the pinned engine wins over probe order', () async {
      final api = service();
      await api.setPreferredEngine(ContainerEngine.podman);
      expect(await api.activeEngine(), ContainerEngine.podman);
    });

    test('a pinned engine that is not installed falls back', () async {
      shell.missing.add('podman');
      final api = service();
      await api.setPreferredEngine(ContainerEngine.podman);
      expect(await api.activeEngine(), ContainerEngine.docker);
    });

    test('the probe is cached until it is invalidated', () async {
      final api = service();
      await api.availableEngines();
      final probes = shell.calls.length;
      await api.availableEngines();
      expect(shell.calls.length, probes);

      api.invalidateEngineCache();
      await api.availableEngines();
      expect(shell.calls.length, greaterThan(probes));
    });
  });

  group('list', () {
    test('asks the engine for stopped containers too', () async {
      shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
      await service().list(engine: ContainerEngine.docker);

      final call = shell.calls.last;
      expect(call.first, 'docker');
      expect(call, contains('--all'));
      expect(call, contains('--format'));
    });

    test('running-only drops the --all flag', () async {
      shell.responses['docker ps'] = '';
      await service()
          .list(engine: ContainerEngine.docker, runningOnly: true);
      expect(shell.calls.last, isNot(contains('--all')));
    });

    test("surfaces the engine's own error when the daemon is down", () async {
      shell.exitCodes['docker ps'] = 1;
      shell.errors['docker ps'] =
          'Cannot connect to the Docker daemon at unix:///var/run/docker.sock';

      expect(
        () => service().list(engine: ContainerEngine.docker),
        throwsA(isA<ContainerException>().having((e) => e.message, 'message',
            contains('Cannot connect to the Docker daemon'))),
      );
    });

    test('without any engine it says so instead of failing obscurely',
        () async {
      shell.missing.addAll(['docker', 'podman']);
      expect(
        () => service().list(),
        throwsA(isA<ContainerException>().having((e) => e.message, 'message',
            contains('No container engine found'))),
      );
    });
  });

  group('listAll', () {
    test('merges both engines and tags each row with its origin', () async {
      shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
      shell.responses['podman ps'] = psLine('b2', 'db', 'postgres', 'exited');

      final containers = await service().listAll();
      expect(containers.map((c) => c.name), ['web', 'db']);
      expect(containers.map((c) => c.engine),
          [ContainerEngine.docker, ContainerEngine.podman]);
    });

    test('one broken engine does not hide the other', () async {
      shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
      shell.exitCodes['podman ps'] = 125;
      shell.errors['podman ps'] = 'podman machine is not running';

      final containers = await service().listAll();
      expect(containers.map((c) => c.name), ['web']);
    });

    test('when every engine fails both messages are reported', () async {
      shell.exitCodes['docker ps'] = 1;
      shell.errors['docker ps'] = 'Cannot connect to the Docker daemon';
      shell.exitCodes['podman ps'] = 125;
      shell.errors['podman ps'] = 'podman machine is not running';

      expect(
        service().listAll(),
        throwsA(isA<ContainerException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Cannot connect to the Docker daemon'),
                contains('podman machine is not running')))),
      );
    });
  });

  group('lifecycle', () {
    test('start, stop and restart pass the container through', () async {
      final api = service();
      await api.start(ContainerEngine.docker, 'web');
      expect(shell.calls.last, ['docker', 'start', 'web']);

      await api.stop(ContainerEngine.docker, 'web');
      expect(shell.calls.last, ['docker', 'stop', 'web']);

      await api.restart(ContainerEngine.podman, 'web');
      expect(shell.calls.last, ['podman', 'restart', 'web']);
    });

    test('remove only forces when asked', () async {
      final api = service();
      await api.remove(ContainerEngine.docker, 'web');
      expect(shell.calls.last, ['docker', 'rm', 'web']);

      await api.remove(ContainerEngine.docker, 'web', force: true);
      expect(shell.calls.last, ['docker', 'rm', '--force', 'web']);
    });

    test('a failing verb reports the exit code and the engine text', () async {
      shell.exitCodes['docker stop'] = 1;
      shell.errors['docker stop'] = 'No such container: web';

      expect(
        () => service().stop(ContainerEngine.docker, 'web'),
        throwsA(isA<ContainerException>().having((e) => e.message, 'message',
            allOf(contains('exit 1'), contains('No such container')))),
      );
    });

    test('a name that could pass for a flag is refused', () async {
      final api = service();
      for (final bad in ['--rm', '-f', 'web;rm -rf /', '', 'a b']) {
        expect(() => api.stop(ContainerEngine.docker, bad),
            throwsA(isA<ArgumentError>()),
            reason: '"$bad" must not reach the command line');
      }
      expect(shell.calls, isEmpty);
    });
  });

  group('logs and exec', () {
    test('logs bound the output and merge both streams', () async {
      shell.responses['docker logs'] = 'listening on :80';
      shell.errors['docker logs'] = 'warning: no config file';

      final output =
          await service().logs(ContainerEngine.docker, 'web', lines: 50);
      expect(shell.calls.last, ['docker', 'logs', '--tail', '50', 'web']);
      expect(output, contains('listening on :80'));
      expect(output, contains('warning: no config file'));
    });

    test('a non-positive line count is refused', () async {
      expect(() => service().logs(ContainerEngine.docker, 'web', lines: 0),
          throwsA(isA<ArgumentError>()));
    });

    test('exec runs the command through the container shell', () async {
      shell.responses['docker exec'] = 'root';
      final output =
          await service().exec(ContainerEngine.docker, 'web', 'whoami');
      expect(shell.calls.last, ['docker', 'exec', 'web', 'sh', '-c', 'whoami']);
      expect(output, 'root');
    });

    test('a failing exec carries the command output, not just a code',
        () async {
      shell.exitCodes['docker exec'] = 127;
      shell.errors['docker exec'] = 'sh: nope: not found';

      expect(
        () => service().exec(ContainerEngine.docker, 'web', 'nope'),
        throwsA(isA<ContainerException>().having((e) => e.message, 'message',
            allOf(contains('127'), contains('not found')))),
      );
    });

    test('an empty command never reaches the engine', () async {
      expect(() => service().exec(ContainerEngine.docker, 'web', '   '),
          throwsA(isA<ArgumentError>()));
      expect(shell.calls, isEmpty);
    });
  });

  test('a hung engine is killed, not just stopped being awaited', () async {
    shell.hangs.add('docker ps');
    final api = service(timeout: const Duration(milliseconds: 50));

    await expectLater(
      api.list(engine: ContainerEngine.docker),
      throwsA(isA<ContainerException>()
          .having((e) => e.message, 'message', contains('did not answer'))),
    );
    // Abandoning the future would leave the child running; the point of
    // going through ExecutionBroker is that it reaps it.
    expect(shell.started.single.killCount, greaterThan(0));
  });

  test('with a remote WSL target the command runs over ssh', () async {
    SharedPreferences.setMockInitialValues({
      'UseRemoteWSL': true,
      'RemoteWSLTarget': 'user@host',
    });
    prefs = await SharedPreferences.getInstance();

    await service().start(ContainerEngine.docker, 'web');

    final call = shell.calls.last;
    expect(call.first, 'ssh');
    expect(call, contains('user@host'));
    expect(call.join(' '), contains('docker'));
    expect(call.join(' '), contains('start'));
  });

  // Read-only host inspection (bostrot/ai-tasks#67).
  group('read-only inspection', () {
    test('stats never streams', () async {
      // Without --no-stream `docker stats` never exits, so this would hit the
      // broker's timeout on every call instead of answering.
      shell.responses['docker stats'] = 'web\t2.5%';
      await service().stats(ContainerEngine.docker);
      expect(shell.calls.single, contains('--no-stream'));
    });

    test('stats for one container puts the ref after the flags', () async {
      shell.responses['docker stats'] = 'web\t2.5%';
      await service().stats(ContainerEngine.docker, ref: 'web');
      expect(shell.calls.single.last, 'web');
    });

    test('a ref that could pass for a flag is refused', () async {
      await expectLater(
          service().stats(ContainerEngine.docker, ref: '--format={{.X}}'),
          throwsArgumentError);
      await expectLater(
          service().processes(ContainerEngine.docker, '-a'),
          throwsArgumentError);
      expect(shell.calls, isEmpty);
    });

    test('images, volumes, networks and disk usage each run their own read',
        () async {
      final api = service();
      shell.responses['docker images'] = 'nginx:latest\ta1';
      shell.responses['docker volume'] = 'pgdata\tlocal';
      shell.responses['docker network'] = 'bridge\tbridge\tlocal';
      shell.responses['docker system'] = 'TYPE';
      expect(await api.images(ContainerEngine.docker), contains('nginx'));
      expect(await api.volumes(ContainerEngine.docker), contains('pgdata'));
      expect(await api.networks(ContainerEngine.docker), contains('bridge'));
      expect(await api.diskUsage(ContainerEngine.docker), contains('TYPE'));
      // Nothing in the family can prune, remove or build.
      expect(
          shell.calls.map((c) => c.join(' ')),
          everyElement(allOf(isNot(contains('prune')), isNot(contains(' rm ')),
              isNot(contains('build')))));
    });

    test("a refusing daemon surfaces the engine's own words", () async {
      shell.exitCodes['docker images'] = 1;
      shell.errors['docker images'] = 'Cannot connect to the Docker daemon';
      await expectLater(
          service().images(ContainerEngine.docker),
          throwsA(isA<ContainerException>().having((e) => e.message, 'message',
              contains('Cannot connect to the Docker daemon'))));
    });
  });

  group('logs options', () {
    test('since and timestamps are engine flags, and the ref stays last',
        () async {
      shell.responses['docker logs'] = 'line';
      await service().logs(ContainerEngine.docker, 'web',
          since: '15m', timestamps: true);
      final call = shell.calls.single;
      expect(call, contains('--since=15m'));
      expect(call, contains('--timestamps'));
      expect(call.last, 'web');
    });

    test('a since that is not a duration never reaches the engine', () async {
      await expectLater(
          service().logs(ContainerEngine.docker, 'web', since: '2026-09-01'),
          throwsArgumentError);
      expect(shell.calls, isEmpty);
    });
  });

  // WSL's own container CLI (bostrot/ai-tasks#111).
  //
  // Every expectation here was taken from `wslc 3.0.1.0` on a Windows host:
  // its own `--help`, and the output of a container run through it.
  group('wslc', () {
    /// A container as `wslc list --format json` really prints it: one object
    /// per line, English keys, `State` separate from the human `Status`.
    String wslcJson({
      String id = '3a8ffd6b4238e460ea095a16d96c472d7df973d40fad5f1ea3ef8cc2926f3bf5',
      String name = 'web',
      String image = 'alpine',
      String state = 'running',
      String status = 'Up 16 seconds',
      String ports = '',
    }) =>
        '{"Command":"\\"sleep 900\\"","CreatedAt":"2026-10-01 21:10:05 '
        '+0200 '
        'MESZ","HealthStatus":"","ID":"$id","Image":"$image","Labels":'
        '"com.microsoft.wsl.container.metadata={}","LocalVolumes":"0",'
        '"Mounts":"","Names":"$name","Networks":"bridge","Ports":"$ports",'
        '"RunningFor":"19 seconds ago","Size":"0B","State":"$state",'
        '"Status":"$status"}';

    test('is not probed off Windows', () async {
      expect(await service().availableEngines(),
          [ContainerEngine.docker, ContainerEngine.podman]);
      expect(shell.calls.map((call) => call.first), isNot(contains('wslc')));
    });

    test('is probed on Windows, with the flag it shares with Docker',
        () async {
      // `wslc` answers both `wslc version` and `wslc --version`; the shared
      // spelling keeps the probe one line for every engine.
      final engines = await service(isWindows: true).availableEngines();
      expect(engines, contains(ContainerEngine.wslc));
      expect(shell.calls, contains(equals(['wslc', '--version'])));
    });

    test('counts as an engine when Docker and Podman are both missing',
        () async {
      shell.missing.addAll(['docker', 'podman']);
      final api = service(isWindows: true);
      expect(await api.availableEngines(), [ContainerEngine.wslc]);
      expect(await api.activeEngine(), ContainerEngine.wslc);
    });

    test('Docker still wins the automatic pick when both are installed',
        () async {
      expect(await service(isWindows: true).activeEngine(),
          ContainerEngine.docker);
    });

    test('is listed with json, not a template it has no language for',
        () async {
      shell.responses['wslc ps'] = wslcJson(name: 'web');
      final containers =
          await service(isWindows: true).list(engine: ContainerEngine.wslc);

      expect(shell.calls.last,
          ['wslc', 'ps', '--all', '--no-trunc', '--format', 'json']);
      expect(containers.single.name, 'web');
      expect(containers.single.image, 'alpine');
      expect(containers.single.state, ContainerState.running);
      expect(containers.single.engine, ContainerEngine.wslc);
    });

    test("Docker's own verbs reach it unchanged", () async {
      // Verified aliases: `ps`, `rm --force`, `logs`, `inspect`, `stop`.
      final api = service(isWindows: true);
      await api.stop(ContainerEngine.wslc, 'web');
      expect(shell.calls.last, ['wslc', 'stop', 'web']);

      await api.remove(ContainerEngine.wslc, 'web', force: true);
      expect(shell.calls.last, ['wslc', 'rm', '--force', 'web']);

      await api.inspect(ContainerEngine.wslc, 'web');
      expect(shell.calls.last, ['wslc', 'inspect', 'web']);

      shell.responses['wslc exec'] = 'root';
      await api.exec(ContainerEngine.wslc, 'web', 'whoami');
      expect(shell.calls.last, ['wslc', 'exec', 'web', 'sh', '-c', 'whoami']);
    });

    test('a text-only read is left in the engine\'s own table', () async {
      // There is no template to ask for, and `--format json` would turn a
      // readable table into one object per line for no gain.
      final api = service(isWindows: true);
      shell.responses['wslc images'] = 'REPOSITORY   TAG';
      shell.responses['wslc volume'] = 'DRIVER   VOLUME NAME';
      shell.responses['wslc network'] = 'NETWORK ID   NAME';
      await api.images(ContainerEngine.wslc);
      expect(shell.calls.last, ['wslc', 'images']);
      await api.volumes(ContainerEngine.wslc);
      expect(shell.calls.last, ['wslc', 'volume', 'ls']);
      // `network ls` exists on wslc 3.0.1, unlike `top` and `system df`.
      await api.networks(ContainerEngine.wslc);
      expect(shell.calls.last, ['wslc', 'network', 'ls']);
    });

    test('stats is one sample already, so --no-stream is never sent',
        () async {
      // Sending it fails the call outright: "Der Optionsname wurde für den
      // aktuellen Befehl --no-stream nicht erkannt".
      shell.responses['wslc stats'] = '{"Name":"web","CPUPerc":"0.00%"}';
      await service(isWindows: true).stats(ContainerEngine.wslc, ref: 'web');
      expect(shell.calls.last, ['wslc', 'stats', 'web']);
      expect(shell.calls.last, isNot(contains('--no-stream')));
    });

    test('a log window is sent as an instant, not a duration', () async {
      // `--since 15m` is read as epoch 15 — "since 1970" — with no error,
      // so the duration is resolved against the clock before it is sent.
      shell.responses['wslc logs'] = 'listening on :80';
      final before = DateTime.now().toUtc();
      await service(isWindows: true)
          .logs(ContainerEngine.wslc, 'web', lines: 50, since: '15m');

      final call = shell.calls.last;
      expect(call.take(4), ['wslc', 'logs', '--tail', '50']);
      expect(call.last, 'web');
      final sent = call.firstWhere((arg) => arg.startsWith('--since='));
      final epoch = int.parse(sent.split('=').last);
      final asked = before.subtract(const Duration(minutes: 15));
      expect(epoch * 1000,
          closeTo(asked.millisecondsSinceEpoch, const Duration(minutes: 1).inMilliseconds));
    });

    test('Docker keeps the duration it understands', () async {
      shell.responses['docker logs'] = 'line';
      await service().logs(ContainerEngine.docker, 'web', since: '15m');
      expect(shell.calls.last, contains('--since=15m'));
    });

    test('a read it has no command for is refused without a process',
        () async {
      // `wslc system df` and `wslc top` answer "Nicht erkannter Befehl" —
      // and would do so in whatever language Windows is set to.
      final api = service(isWindows: true);
      for (final read in [
        () => api.diskUsage(ContainerEngine.wslc),
        () => api.processes(ContainerEngine.wslc, 'web'),
      ]) {
        await expectLater(
            read(),
            throwsA(isA<ContainerException>().having((e) => e.message,
                'message', contains('WSL container has no'))));
      }
      expect(shell.calls, isEmpty);
    });

    test('a refusing engine is reported in its own words', () async {
      shell.exitCodes['wslc ps'] = 1;
      shell.errors['wslc ps'] = 'Der WSL-Containerdienst wird nicht ausgeführt';

      await expectLater(
          service(isWindows: true).list(engine: ContainerEngine.wslc),
          // Matched on an ASCII part: the broker decodes a non-WSL command
          // with the system code page, which turns the test's UTF-8 "ü"
          // into "Ã¼" on a Windows runner.
          throwsA(isA<ContainerException>().having((e) => e.message, 'message',
              contains('Der WSL-Containerdienst'))));
      expect(shell.calls, hasLength(1));
    });

    test('the engine is offered in settings as an engine like any other', () {
      // The Settings dropdown and the MCP engine argument both enumerate the
      // engines, so the executable is the contract.
      expect(ContainerEngine.byExecutable('wslc'), ContainerEngine.wslc);
      expect(ContainerEngine.wslc.cli, ContainerCli.wslc);
    });
  });

  group('parseJsonOutput', () {
    test('reads one object per line, as the engine prints them', () {
      final containers = ContainerService.parseJsonOutput(
        '{"ID":"a1","Names":"web","Image":"nginx","State":"running",'
        '"Status":"Up 2 hours","Ports":"0.0.0.0:8080->80/tcp"}\n'
        '{"ID":"b2","Names":"db","Image":"postgres:16","State":"exited",'
        '"Status":"Exited (0) 3 minutes ago","Ports":""}',
        ContainerEngine.wslc,
      );

      expect(containers.map((c) => c.name), ['web', 'db']);
      expect(containers.first.ports, '0.0.0.0:8080->80/tcp');
      expect(containers.first.state, ContainerState.running);
      expect(containers.last.state, ContainerState.exited);
      expect(containers.last.status, 'Exited (0) 3 minutes ago');
      expect(containers.last.ports, isEmpty);
    });

    test('a line that is not JSON does not take the listing with it', () {
      final containers = ContainerService.parseJsonOutput(
        'WSL container is in preview.\n'
        '{"ID":"a1","Names":"web","Image":"nginx","State":"running"}\n'
        '{ truncated',
        ContainerEngine.wslc,
      );
      expect(containers.single.ref, 'web');
    });

    test('falls back to the status word when State is absent', () {
      final containers = ContainerService.parseJsonOutput(
        '{"ID":"a1","Names":"web","Status":"Exited (0) 3 minutes ago"}',
        ContainerEngine.wslc,
      );
      expect(containers.single.state, ContainerState.exited);
    });

    test('an object with neither id nor name is not a row', () {
      expect(
          ContainerService.parseJsonOutput(
              '{"Image":"nginx","State":"running"}', ContainerEngine.wslc),
          isEmpty);
    });

    test('an array is decoded whole, in case an engine answers with one', () {
      final containers = ContainerService.parseJsonOutput(
        '[\n  {"ID":"a1","Names":"web","State":"running"},\n'
        '  {"ID":"b2","Names":"db","State":"exited"}\n]',
        ContainerEngine.wslc,
      );
      expect(containers.map((c) => c.ref), ['web', 'db']);
    });

    test('several names collapse to the one the engine shows first', () {
      final containers = ContainerService.parseJsonOutput(
          '{"ID":"a1","Names":"web,web-alias","State":"running"}',
          ContainerEngine.docker);
      expect(containers.single.name, 'web');
    });

    test('no containers is an empty list, not an error', () {
      expect(
          ContainerService.parseJsonOutput('', ContainerEngine.wslc), isEmpty);
    });
  });
}
