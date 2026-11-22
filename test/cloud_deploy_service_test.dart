import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/cloud/cloud_deploy_service.dart';
import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_cloud.dart';

/// What `ssh-keygen -l` prints for the key the fake ~/.ssh holds.
const String _md5Line = '256 MD5:aa:bb:cc wslmanager (ED25519)';
const String _sha256Line = '256 SHA256:zzzz wslmanager (ED25519)';

/// A shell on which a deploy goes all the way through: the local key is
/// recognised and the container is found running when it is checked on.
FakeCloudShell _deployShell() => FakeCloudShell()
  ..responses['-E md5'] = _md5Line
  ..responses['-E sha256'] = _sha256Line
  ..responses['docker inspect'] = 'running 0\n'
  ..responses['is-system-running'] = 'running\n';

CloudServer _running({String ip = '203.0.113.10', String name = 'deploy-1'}) =>
    CloudServer(
      id: '1',
      name: name,
      state: CloudServerState.running,
      provider: CloudProviderId.hetzner,
      ipv4: ip,
      labels: const {CloudServer.deployedInstanceLabel: 'Ubuntu'},
    );

void main() {
  late Directory tempDir;
  late Directory sshDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud-deploy-test');
    sshDir = Directory('${tempDir.path}/ssh')..createSync(recursive: true);
    File('${sshDir.path}/id_ed25519.pub')
        .writeAsStringSync('ssh-ed25519 AAAAC3Nz key@host\n');
    SharedPreferences.setMockInitialValues({'DataPath': tempDir.path});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  CloudDeployService service(
    FakeCloudShell shell,
    FakeCloudProvider provider, {
    FakeDeployBackend? backend,
    // Pinned rather than read off the machine running the tests, which is
    // arm64 on one developer's Mac and x86-64 in CI.
    String localArchitecture = 'x86',
    Duration readyTimeout = const Duration(seconds: 5),
  }) =>
      CloudDeployService(
        provider: provider,
        shell: shell,
        backend: backend ?? FakeDeployBackend(),
        sshDirectoryOverride: sshDir.path,
        localArchitecture: localArchitecture,
        pollInterval: Duration.zero,
        readyTimeout: readyTimeout,
      );

  group('posix quoting', () {
    test('leaves shell-neutral tokens alone', () {
      expect(posixQuote('docker'), 'docker');
      expect(posixQuote('/root/Ubuntu-cloud.tar'), '/root/Ubuntu-cloud.tar');
      expect(posixQuote('root@203.0.113.10'), 'root@203.0.113.10');
    });

    test('quotes anything the remote shell would re-parse', () {
      // ssh joins its argv and the remote shell parses the result, so a space
      // or a metacharacter that arrives bare becomes a second argument — or a
      // second command.
      expect(posixQuote('two words'), "'two words'");
      expect(posixQuote(r'a;rm -rf /'), r"'a;rm -rf /'");
      expect(posixQuote(r'$(whoami)'), r"'$(whoami)'");
      expect(posixQuote("it's"), r"'it'\''s'");
    });

    test('builds a command line out of a whole argv', () {
      expect(posixCommandLine(['docker', 'run', '--name', 'a b']),
          "docker run --name 'a b'");
    });
  });

  test('cloud ssh accepts a new host key but not a changed one', () {
    final options = cloudSshOptions();
    // Without this the very first command against a server created seconds
    // ago fails: BatchMode turns the host-key prompt into a refusal.
    expect(options, contains('StrictHostKeyChecking=accept-new'));
    expect(options, contains('BatchMode=yes'));
    // And never the app's shared multiplexing socket: it has no %h in it, so
    // a master already open to the remote Windows host would swallow these
    // commands and run them on the wrong machine.
    expect(options.join(' '), isNot(contains('ControlPath')));
    expect(options.join(' '), isNot(contains('ControlMaster')));
  });

  test('deploys an instance end to end', () async {
    final shell = _deployShell();
    final provider = FakeCloudProvider()
      ..getServerAnswers.addAll([
        const CloudServer(
            id: '1',
            name: 'deploy-1',
            state: CloudServerState.initializing,
            provider: CloudProviderId.hetzner),
        _running(),
      ]);
    final backend = FakeDeployBackend();
    final stages = <DeployStage>[];

    final server = await service(shell, provider, backend: backend).deploy(
      instance: 'Ubuntu',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
      onProgress: (progress) => stages.add(progress.stage),
    );

    expect(server.address, '203.0.113.10');

    // Exported as a tarball, which is the only format `docker import` reads.
    expect(backend.exports.single[0], 'Ubuntu');
    expect(backend.exports.single[2], 'tar');

    // The create carries cloud-init and the label that makes the pull back
    // possible later.
    expect(provider.lastCreate['serverType'], 'cx22');
    expect(provider.lastCreate['userData'], contains('docker.io'));
    expect((provider.lastCreate['labels']! as Map)[
        CloudServer.deployedInstanceLabel], 'Ubuntu');

    expect(shell.sawCommand('test -f $cloudReadyMarker'), isTrue);
    final upload = shell.commandContaining('scp');
    expect(upload, contains('root@203.0.113.10:/root/Ubuntu-cloud.tar'));
    // The local side is a bare file name, never a full path: scp splits an
    // operand on its first colon, so `C:\\…\\Ubuntu-cloud.tar` reads as a
    // file on a host called `C` under any scp that does not special-case
    // Windows drive letters.
    expect(upload, contains(' Ubuntu-cloud.tar '));
    expect(upload, isNot(contains(tempDir.path)));
    expect(
        shell.sawCommand('docker import /root/Ubuntu-cloud.tar '
            'wslmanager/ubuntu'),
        isTrue);
    // The fake image carries no systemd, so the container is kept alive
    // with `sleep` — on the server's own network, so anything the user
    // starts inside is reachable on the server's address.
    final run = shell.commandContaining('docker run --detach');
    expect(run, contains('--name Ubuntu'));
    expect(run, contains('--network host'));
    expect(run, contains('--init'));
    expect(run, endsWith('wslmanager/ubuntu sleep infinity'));
    expect(run, isNot(contains('--privileged')));
    // And it is checked on afterwards rather than assumed to be up.
    expect(shell.commandLines.indexWhere((l) => l.contains('docker inspect')),
        greaterThan(shell.commandLines.indexOf(run)));
    // The staged archive is removed on both ends.
    expect(shell.sawCommand('rm -f /root/Ubuntu-cloud.tar'), isTrue);
    expect(File('${tempDir.path}/tmp/Ubuntu-cloud.tar').existsSync(), isFalse);

    expect(stages.first, DeployStage.exporting);
    expect(stages.last, DeployStage.done);
    expect(stages, contains(DeployStage.waitingForDocker));
  });

  test('boots a root filesystem that carries systemd with systemd as PID 1',
      () async {
    // What the probe of the imported image prints on an Ubuntu rootfs, and
    // what systemd answers once the boot is over: the guest's resolver
    // failed on a port the server owns, which is a booted system all the
    // same.
    final shell = _deployShell()
      ..responses['docker run --rm'] = '/usr/lib/systemd/systemd\n'
      ..responses['is-system-running'] = 'degraded\n';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await service(shell, provider).deploy(
      instance: 'web-2',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
    );

    // The probe asks the image itself, after the import and before the run,
    // for each place systemd may live.
    final probe = shell.commandContaining('docker run --rm');
    expect(probe, contains('wslmanager/web-2 sh -c'));
    expect(probe, contains('-x /usr/lib/systemd/systemd '));
    expect(probe, contains('-x /lib/systemd/systemd '));

    final run = shell.commandContaining('docker run --detach');
    expect(run, contains('--name web-2'));
    expect(run, contains('--network host'));
    // What a booting systemd needs, and not the whole machine.
    expect(run, contains('--cap-add SYS_ADMIN'));
    expect(run, contains('--cgroupns host'));
    expect(run, contains('--volume /sys/fs/cgroup:/sys/fs/cgroup:rw'));
    expect(run, contains('--security-opt apparmor=unconfined'));
    expect(run, contains('--tmpfs /run '));
    expect(run, contains('--stop-signal SIGRTMIN+3'));
    expect(run, contains('--stop-timeout 90'));
    expect(run, contains('--env container=docker'));
    expect(run, isNot(contains('--privileged')));
    // systemd itself is the command, with the units that would provision or
    // hijack the server masked on its "kernel command line".
    expect(run, contains('wslmanager/web-2 /usr/lib/systemd/systemd '));
    for (final unit in cloudMaskedUnits) {
      expect(run, contains(' systemd.mask=$unit'));
    }
    expect(cloudMaskedUnits, containsAll(['cloud-init.service', 'ssh.socket']));
    // Nothing keeps systemd from being PID 1.
    expect(run, isNot(contains('--init')));
    expect(run, isNot(contains('sleep infinity')));

    // The boot itself is what is waited for, not the process.
    final wait = shell.commandContaining('is-system-running');
    expect(
        wait, contains('docker exec web-2 systemctl is-system-running --wait'));
    expect(shell.sawCommand('docker inspect'), isFalse);

    final order = shell.commandLines;
    expect(order.indexOf(probe),
        greaterThan(order.indexWhere((l) => l.contains('docker import'))));
    expect(order.indexOf(run), greaterThan(order.indexOf(probe)));
    expect(order.indexOf(wait), greaterThan(order.indexOf(run)));
  });

  test('asks systemd again while its control socket is not up yet', () async {
    final shell = _deployShell()
      ..responses['docker run --rm'] = '/usr/lib/systemd/systemd\n'
      // The first `docker exec` lands before PID 1 listens; ssh relays the
      // failure and prints nothing.
      ..failFirst['is-system-running'] = 1;
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await service(shell, provider).deploy(
      instance: 'web-2',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
    );

    final asks =
        shell.commandLines.where((l) => l.contains('is-system-running')).length;
    expect(asks, 2);
    // Between the two, the container is confirmed to still be there.
    expect(shell.sawCommand('docker inspect --format'), isTrue);
    expect(shell.sawCommand('docker rm'), isFalse);
  });

  test(
      'a boot that ends in emergency mode fails the deploy, names the '
      'failed units and keeps the container stopped', () async {
    final shell = _deployShell()
      ..responses['docker run --rm'] = '/usr/lib/systemd/systemd\n'
      ..responses['is-system-running'] = 'maintenance\n'
      ..responses['systemctl --failed'] =
          'boot-efi.mount loaded failed failed /boot/efi\n'
      ..responses['journalctl'] =
          'systemd[1]: boot-efi.mount: Mount process exited, code=exited'
      ..responses['docker logs'] = 'Welcome to Ubuntu 24.04 LTS!';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await expectLater(
      service(shell, provider).deploy(
        instance: 'web-2',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having(
          (e) => e.message,
          'message',
          allOf(
              contains('web-2 did not come up'),
              contains('"maintenance"'),
              contains('boot-efi.mount'),
              contains('Welcome to Ubuntu'),
              contains('Mount process exited'),
              contains('docker start web-2')))),
    );
    expect(shell.sawCommand('docker logs --tail 20 web-2'), isTrue);
    // The journal is read while the container is still up — it is gone
    // from `docker exec` once the container is stopped.
    final lines = shell.commandLines;
    expect(lines.indexWhere((l) => l.contains('journalctl')),
        lessThan(lines.indexWhere((l) => l.contains('docker stop --time'))));
    // Kept for a look, but not left restarting in a loop on a billed
    // server: `unless-stopped` honours a stop. And the stop is not given
    // the container's own ninety seconds — the error is already known.
    expect(shell.sawCommand('docker rm'), isFalse);
    expect(shell.sawCommand('docker update'), isFalse);
    expect(shell.sawCommand('docker stop --time 15 web-2'), isTrue);
  });

  test('an empty journal is left out of the error rather than quoted',
      () async {
    final shell = _deployShell()
      ..responses['docker run --rm'] = '/usr/lib/systemd/systemd\n'
      ..responses['is-system-running'] = 'maintenance\n'
      ..responses['journalctl'] = '-- No entries --\n';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await expectLater(
      service(shell, provider).deploy(
        instance: 'web-2',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having((e) => e.message, 'message',
          allOf(contains('"maintenance"'), isNot(contains('Journal'))))),
    );
  });

  test('a boot that never finishes names the jobs still pending', () async {
    final shell = _deployShell()
      ..responses['docker run --rm'] = '/usr/lib/systemd/systemd\n'
      ..responses['is-system-running'] = 'starting\n'
      ..responses['list-jobs'] = '12 snapd.seeded.service start running\n';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await expectLater(
      // Short enough not to wait, long enough for the address poll before
      // it, which shares the timeout.
      service(shell, provider, readyTimeout: const Duration(milliseconds: 300))
          .deploy(
        instance: 'web-2',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having(
          (e) => e.message,
          'message',
          allOf(contains('did not finish booting'), contains('starting'),
              contains('snapd.seeded.service')))),
    );
    expect(shell.sawCommand('docker stop --time 15 web-2'), isTrue);
  });

  test('a server of the other architecture is refused before the export',
      () async {
    final shell = _deployShell();
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());
    final backend = FakeDeployBackend();

    await expectLater(
      service(shell, provider, backend: backend, localArchitecture: 'arm')
          .deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        serverArchitecture: 'x86',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having((e) => e.message, 'message',
          allOf(contains('cx22 is an x86 server type'), contains('arm')))),
    );
    // Nothing was exported, created or billed for.
    expect(backend.exports, isEmpty);
    expect(provider.lastCreate, isEmpty);
    expect(shell.calls, isEmpty);
  });

  test('a matching or unknown server architecture deploys as before', () async {
    for (final architecture in ['arm', 'arm64', '']) {
      final shell = _deployShell();
      final provider = FakeCloudProvider()..getServerAnswers.add(_running());
      await service(shell, provider, localArchitecture: 'arm').deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cax11',
        serverArchitecture: architecture,
        image: 'ubuntu-24.04',
        location: 'nbg1',
      );
      expect(provider.lastCreate['serverType'], 'cax11');
    }
  });

  test('an image the server cannot execute is explained, not shrugged off',
      () async {
    // What Docker prints when the kernel refuses the image's own `sh`: the
    // rootfs was built for the other architecture. Exit 125 is the same
    // code as "no daemon", so the words are what tell it apart.
    final shell = _deployShell()
      ..exitCodes['docker run --rm'] = 125
      ..errors['docker run --rm'] = 'docker: Error response from daemon: '
          'failed to create task for container: exec: "sh": exec format error';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await expectLater(
      service(shell, provider, localArchitecture: 'arm').deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having(
          (e) => e.message,
          'message',
          allOf(
              contains('probing'),
              contains('exec format error'),
              contains('CPU architecture'),
              contains('(arm)'),
              contains('same architecture')))),
    );
    expect(shell.sawCommand('docker run --detach'), isFalse);

    // The same words from the start itself — an image with no `sh` for the
    // probe but a systemd of the wrong architecture — get the same hint.
    final late = _deployShell()
      ..exitCodes['docker run --rm'] = 127
      ..exitCodes['docker run --detach'] = 125
      ..errors['docker run --detach'] = 'exec: "sleep": exec format error';
    await expectLater(
      service(late, FakeCloudProvider()..getServerAnswers.add(_running()))
          .deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having(
          (e) => e.message,
          'message',
          allOf(contains('starting the container'),
              contains('CPU architecture')))),
    );
  });

  test('architecture families are read from either side\'s wording', () {
    expect(cloudArchitectureFamily('x86'), 'x86');
    expect(cloudArchitectureFamily('x86_64'), 'x86');
    expect(cloudArchitectureFamily('amd64'), 'x86');
    expect(cloudArchitectureFamily('arm'), 'arm');
    expect(cloudArchitectureFamily('arm64'), 'arm');
    expect(cloudArchitectureFamily('aarch64'), 'arm');
    expect(cloudArchitectureFamily(''), '');
    expect(cloudArchitectureFamily('riscv64'), '');
    // Whole words: a description is not a family just for containing one.
    expect(cloudArchitectureFamily('x86_64 (AMD, warm pool)'), 'x86');
    expect(cloudArchitectureFamily('charm'), '');

    const none = <String, String>{};
    expect(
        cloudLocalArchitecture(abi: Abi.macosArm64, environment: none), 'arm');
    expect(cloudLocalArchitecture(abi: Abi.windowsArm64, environment: none),
        'arm');
    expect(
        cloudLocalArchitecture(abi: Abi.windowsX64, environment: none), 'x86');
    expect(cloudLocalArchitecture(abi: Abi.linuxX64, environment: none), 'x86');
    expect(
        cloudLocalArchitecture(abi: Abi.linuxRiscv64, environment: none), '');
    // The x64 build on an ARM64 Windows PC runs under emulation: its ABI
    // says x64, but the machine — and every WSL distribution on it — is
    // arm64, which Windows tells the emulated process about.
    expect(
        cloudLocalArchitecture(abi: Abi.windowsX64, environment: const {
          'PROCESSOR_ARCHITECTURE': 'AMD64',
          'PROCESSOR_ARCHITEW6432': 'ARM64',
        }),
        'arm');
    // Whatever runs the tests is one of the two a provider sells.
    expect(cloudLocalArchitecture(), anyOf('arm', 'x86'));
  });

  test('a server that cannot even run the probe fails the deploy', () async {
    // Exit 1 is the probe saying "no"; 125 is Docker itself failing.
    final shell = _deployShell()
      ..exitCodes['docker run --rm'] = 125
      ..errors['docker run --rm'] = 'Cannot connect to the Docker daemon';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await expectLater(
      service(shell, provider).deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having((e) => e.message, 'message',
          allOf(contains('probing'), contains('Docker daemon')))),
    );
    expect(shell.sawCommand('docker run --detach'), isFalse);
  });

  test('a probe that fails or answers nonsense means no systemd', () async {
    for (final shell in [
      // No `sh` in the image, say.
      _deployShell()..exitCodes['docker run --rm'] = 127,
      // A path that is not one of the ones asked for.
      _deployShell()..responses['docker run --rm'] = '/sbin/init\n',
    ]) {
      final provider = FakeCloudProvider()..getServerAnswers.add(_running());
      await service(shell, provider).deploy(
        instance: 'Alpine',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      );
      final run = shell.commandContaining('docker run --detach');
      expect(run, endsWith('wslmanager/alpine sleep infinity'));
      expect(run, isNot(contains('systemd.mask')));
    }
  });

  test(
      'a sleep container that does not stay up fails the deploy with its '
      'log and is kept stopped', () async {
    final shell = _deployShell()
      ..responses['docker inspect'] = 'restarting 3\n'
      // A container's stdout and stderr are replayed by `docker logs` on
      // its own, and an init that refuses to start says why on stderr.
      ..responses['docker logs'] = 'starting'
      ..errors['docker logs'] = 'exec: "sleep": executable file not found';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await expectLater(
      service(shell, provider).deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Ubuntu did not come up'), contains('restarting 3'),
              contains('starting'), contains('executable file not found')))),
    );
    expect(shell.sawCommand('docker logs --tail 20 Ubuntu'), isTrue);
    expect(shell.sawCommand('docker stop --time 15 Ubuntu'), isTrue);
    expect(shell.sawCommand('docker rm'), isFalse);
    // No systemd, so no journal to ask for.
    expect(shell.sawCommand('journalctl'), isFalse);
    // The staged archive does not outlive a failed deploy.
    expect(File('${tempDir.path}/tmp/Ubuntu-cloud.tar').existsSync(), isFalse);
  });

  test('reuses an SSH key the provider already holds', () async {
    final shell = _deployShell();
    final provider = FakeCloudProvider(sshKeys: const [
      CloudSshKey(id: '42', name: 'other-machine', fingerprint: 'aa:bb:cc'),
    ])
      ..getServerAnswers.add(_running());

    await service(shell, provider).deploy(
      instance: 'Ubuntu',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
    );

    expect(provider.lastCreate['sshKeyIds'], ['42']);
    expect(provider.createdKeys, isEmpty);
  });

  test('uploads the key when the provider does not have it yet', () async {
    final shell = _deployShell();
    final provider = FakeCloudProvider(sshKeys: const [
      CloudSshKey(id: '42', name: 'someone-else', fingerprint: 'ff:ee:dd'),
    ])
      ..getServerAnswers.add(_running());

    await service(shell, provider).deploy(
      instance: 'Ubuntu',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
    );

    expect(provider.createdKeys, hasLength(1));
    expect(provider.lastCreate['sshKeyIds'], [provider.createdKeys.single.id]);
  });

  test('refuses to deploy without an SSH key, rather than creating a server '
      'nobody can reach', () async {
    // A provider that mails a root password instead is useless here: every
    // step after the create is an SSH command and password auth is off.
    final emptySsh = Directory('${tempDir.path}/no-keys')
      ..createSync(recursive: true);
    final shell = FakeCloudShell()..exitCodes['ssh-keygen'] = 1;
    final provider = FakeCloudProvider();

    await expectLater(
      CloudDeployService(
        provider: provider,
        shell: shell,
        backend: FakeDeployBackend(),
        sshDirectoryOverride: emptySsh.path,
        pollInterval: Duration.zero,
      ).deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>()
          .having((e) => e.message, 'message', contains('SSH public key'))),
    );
    expect(provider.lastCreate, isEmpty);
  });

  test('keeps polling while the server is still initializing', () async {
    final shell = _deployShell();
    final provider = FakeCloudProvider()
      ..getServerAnswers.addAll([
        const CloudServer(
            id: '1',
            name: 'deploy-1',
            state: CloudServerState.initializing,
            provider: CloudProviderId.hetzner),
        const CloudServer(
            id: '1',
            name: 'deploy-1',
            state: CloudServerState.starting,
            provider: CloudProviderId.hetzner,
            ipv4: '203.0.113.10'),
        _running(),
      ]);

    await service(shell, provider).deploy(
      instance: 'Ubuntu',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
    );

    // An address alone is not enough — `starting` still has no sshd.
    expect(provider.getServerCalls, 3);
  });

  test('waits for cloud-init rather than racing the docker install', () async {
    final shell = _deployShell()
      // The first two `test -f` calls fail, as they do while the server is
      // still installing Docker.
      ..failFirst['test -f $cloudReadyMarker'] = 2;
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await service(shell, provider).deploy(
      instance: 'Ubuntu',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
    );

    final probes = shell.commandLines
        .where((line) => line.contains('test -f $cloudReadyMarker'))
        .length;
    expect(probes, 3);
    // The import only runs after the marker appears.
    expect(shell.sawCommand('docker import'), isTrue);
  });

  test('a failing remote command surfaces the server\'s own stderr', () async {
    final shell = _deployShell()
      ..exitCodes['docker import'] = 1
      ..errors['docker import'] = 'no space left on device';
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());

    await expectLater(
      service(shell, provider).deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>().having((e) => e.message, 'message',
          contains('no space left on device'))),
    );
    // The half-finished deploy still cleans up after itself locally.
    expect(File('${tempDir.path}/tmp/Ubuntu-cloud.tar').existsSync(), isFalse);
  });

  test('a backend that cannot export a rootfs never creates a server',
      () async {
    final shell = FakeCloudShell();
    final provider = FakeCloudProvider();
    final backend = FakeDeployBackend(rootfsExport: false);
    final deploy = service(shell, provider, backend: backend);

    expect(deploy.canDeploy, isFalse);
    await expectLater(
      deploy.deploy(
        instance: 'Ubuntu',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<CloudException>()),
    );
    expect(provider.lastCreate, isEmpty);
    expect(backend.exports, isEmpty);
  });

  test('rejects a name that could arrive as another flag', () async {
    final deploy = service(FakeCloudShell(), FakeCloudProvider());

    await expectLater(
      deploy.deploy(
        instance: '--rm',
        serverName: 'deploy-1',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      deploy.deploy(
        instance: 'Ubuntu',
        serverName: 'a name with spaces',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'nbg1',
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('pulls a deployed instance back under a new local name', () async {
    final shell = FakeCloudShell();
    final provider = FakeCloudProvider();
    final backend = FakeDeployBackend();
    final stages = <DeployStage>[];

    await service(shell, provider, backend: backend).pullBack(
      server: _running(),
      instance: 'Ubuntu',
      localName: 'Ubuntu-cloud',
      onProgress: (progress) => stages.add(progress.stage),
    );

    expect(
        shell.sawCommand(
            'docker export --output /root/Ubuntu-cloud-pull.tar Ubuntu'),
        isTrue);
    final download = shell.commandContaining('scp');
    expect(download, contains('root@203.0.113.10:/root/Ubuntu-cloud-pull.tar'));
    expect(download, isNot(contains(tempDir.path)));
    // Imported under the new name, never over the instance it came from.
    expect(backend.imports.single[0], 'Ubuntu-cloud');
    // The instance it came from still travels with it: a backend that cannot
    // boot a bare root filesystem restores onto a copy of that instance, and
    // dropping it here would break only the Apple backend.
    expect(backend.rootfsImports.single[0], 'Ubuntu-cloud');
    expect(backend.rootfsImports.single[2], 'Ubuntu');
    expect(stages, contains(DeployStage.downloading));
    expect(stages.last, DeployStage.done);
    // The server is left alone: pulling back is a copy, not a move.
    expect(provider.deleted, isEmpty);
    expect(provider.poweredOff, isEmpty);
  });

  test('a backend that reports its own sub-steps has them shown', () async {
    // Reading a root filesystem out of a stopped VM means booting it first —
    // minutes in which the deploy has nothing else to say. The backend's own
    // wording is what reaches the progress line.
    final backend = FakeDeployBackend()..exportStatus = ['Starting Ubuntu'];
    final provider = FakeCloudProvider()..getServerAnswers.add(_running());
    final details = <String>[];

    await service(_deployShell(), provider, backend: backend).deploy(
      instance: 'Ubuntu',
      serverName: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
      onProgress: (progress) => details.add(progress.detail),
    );

    expect(details, contains('Starting Ubuntu'));
  });

  test('a backend that cannot export a rootfs never pulls one back', () async {
    final backend = FakeDeployBackend(rootfsExport: false);

    await expectLater(
      service(FakeCloudShell(), FakeCloudProvider(), backend: backend)
          .pullBack(
        server: _running(),
        instance: 'Ubuntu',
        localName: 'Ubuntu-cloud',
      ),
      throwsA(isA<CloudException>()),
    );
    expect(backend.imports, isEmpty);
  });

  test('refuses to pull from a server with no address', () async {
    await expectLater(
      service(FakeCloudShell(), FakeCloudProvider()).pullBack(
        server: const CloudServer(
            id: '1',
            name: 'deploy-1',
            state: CloudServerState.off,
            provider: CloudProviderId.hetzner),
        instance: 'Ubuntu',
        localName: 'Ubuntu-cloud',
      ),
      throwsA(isA<CloudException>()
          .having((e) => e.message, 'message', contains('no address'))),
    );
  });
}
