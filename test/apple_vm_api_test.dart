import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' show InfoBarSeverity, Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:localization/localization.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/apple/guest_greeting.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_vmctl_shell.dart';

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

  late FakeVmctlShell shell;
  late AppleVmApi api;
  late Directory tempStore;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    shell = FakeVmctlShell();
    tempStore = Directory.systemTemp.createTempSync('applevm-test');
    api = AppleVmApi(
      shell: shell,
      helperPathOverride: '/fake/vmctl',
      storeDirOverride: tempStore.path,
      earlyExitProbeDelay: Duration.zero,
      // A test may not sit through a guest boot: one probe, no sleep.
      guestReadyTimeout: Duration.zero,
      guestReadyPollInterval: Duration.zero,
      macosTerminalTimeout: Duration.zero,
    );
  });

  tearDown(() {
    if (tempStore.existsSync()) tempStore.deleteSync(recursive: true);
  });

  List<String> lastCall() => shell.calls.last;

  group('identity', () {
    test('reports backend id, noun and template extension', () {
      expect(api.backendId, 'applevirt');
      expect(api.instanceNoun, 'VM');
      expect(api.templateExtension, 'img');
    });

    test('features exclude every WSL-only surface', () {
      final features = api.features;
      expect(features.wslConfig, isFalse);
      expect(features.packaging, isFalse);
      expect(features.mountDisk, isFalse);
      expect(features.templatesDeprecated, isFalse);
      expect(features.createVm, isTrue);
      // The AI Workspace (a dedicated Linux VM), the serial console and
      // snippets are all supported on this backend, unlike the WSL-only
      // families above.
      expect(features.aiWorkspace, isTrue);
      expect(features.serialConsole, isTrue);
      expect(features.quickActions, isTrue);
      // A VM has a login account of its own; a WSL distro does not.
      expect(features.guestCredentials, isTrue);
    });
  });

  group('list', () {
    test('parses vmctl JSON into Instances', () async {
      shell.responses['list'] = json.encode({
        'vms': [
          {'name': 'ubuntu', 'state': 'running', 'os': 'linux', 'user': 'dev'},
          {'name': 'fedora', 'state': 'stopped', 'os': 'linux', 'user': 'user'},
        ]
      });
      final instances = await api.list(false);
      expect(instances.all, ['ubuntu', 'fedora']);
      expect(instances.running, ['ubuntu']);
      // The helper was invoked with the store and the json flag.
      expect(lastCall(), containsAll(['/fake/vmctl', '--store', 'list']));
    });

    test('empty store lists nothing', () async {
      shell.responses['list'] = '{"vms":[]}';
      final instances = await api.list(false);
      expect(instances.all, isEmpty);
      expect(instances.running, isEmpty);
    });

    test('unreadable output raises AppleVmException', () async {
      shell.responses['list'] = 'not json';
      expect(() => api.list(false), throwsA(isA<AppleVmException>()));
    });

    test('helper failure surfaces its stderr', () async {
      shell.exitCodes['list'] = 1;
      shell.errors['list'] = 'boom from vmctl';
      expect(
        () => api.list(false),
        throwsA(predicate((e) => e.toString().contains('boom from vmctl'))),
      );
    });
  });

  group('lifecycle', () {
    List<String> callWith(String verb) =>
        shell.calls.lastWhere((c) => c.contains(verb));

    test('start opens the VM with its display window', () async {
      shell.responses['start'] = '{"started":"ubuntu"}';
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"running"}]}';
      await api.start('ubuntu');
      expect(
          callWith('start'), containsAll(['start', '--name', 'ubuntu', '--gui']));
    });

    test('startHeadless omits the gui flag', () async {
      shell.responses['start'] = '{"started":"ubuntu"}';
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"running"}]}';
      await api.startHeadless('ubuntu');
      expect(callWith('start'), isNot(contains('--gui')));
    });

    test('a VM that stops right after starting is reported, with the '
        'serial log tail', () async {
      shell.responses['start'] = '{"started":"ubuntu"}';
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"stopped"}]}';
      Directory('${tempStore.path}/ubuntu/run').createSync(recursive: true);
      File('${tempStore.path}/ubuntu/run/serial.log')
          .writeAsStringSync('EFI: no bootable option');
      expect(
        () => api.start('ubuntu'),
        throwsA(predicate((e) =>
            e is AppleVmException &&
            e.message.contains('vmstoppedimmediately-text') &&
            e.message.contains('no bootable option'))),
      );
    });

    test('stop and remove hit the expected verbs', () async {
      shell.responses['stop'] = '{"stopped":"ubuntu"}';
      await api.stop('ubuntu');
      expect(lastCall(), containsAll(['stop', '--name', 'ubuntu']));

      shell.responses['delete'] = '{"deleted":"ubuntu"}';
      await api.remove('ubuntu');
      expect(lastCall(), containsAll(['delete', '--name', 'ubuntu']));
    });

    test('remove clears the per-instance preferences', () async {
      await prefs.setString('Path_gone', 'somewhere');
      await prefs.setString('DistroName_gone', 'Gone');
      shell.responses['delete'] = '{"deleted":"gone"}';
      await api.remove('gone');
      expect(prefs.getString('Path_gone'), isNull);
      expect(prefs.getString('DistroName_gone'), isNull);
    });

    test('shutdown stops every running VM', () async {
      shell.responses['list'] = json.encode({
        'vms': [
          {'name': 'a', 'state': 'running'},
          {'name': 'b', 'state': 'stopped'},
          {'name': 'c', 'state': 'running'},
        ]
      });
      shell.responses['stop'] = '{}';
      await api.shutdown();
      final stops = shell.calls.where((c) => c.contains('stop')).toList();
      expect(stops, hasLength(2));
      expect(stops[0], contains('a'));
      expect(stops[1], contains('c'));
    });
  });

  group('export / import / copy', () {
    test('export and import map to vmctl verbs', () async {
      shell.responses['export'] = '{}';
      await api.export('ubuntu', '/tmp/out.img');
      expect(lastCall(),
          containsAll(['export', '--name', 'ubuntu', '--output', '/tmp/out.img']));

      shell.responses['import'] = '{}';
      await api.import('clone', '', '/tmp/out.img');
      expect(lastCall(),
          containsAll(['import', '--name', 'clone', '--input', '/tmp/out.img']));
    });

    test('copy exports to a staging file, imports it and cleans up', () async {
      shell.responses['export'] = '{}';
      shell.responses['import'] = '{}';
      await api.copy('ubuntu', 'ubuntu2');
      final exportCall = shell.calls.firstWhere((c) => c.contains('export'));
      final importCall = shell.calls.firstWhere((c) => c.contains('import'));
      final staging = exportCall[exportCall.indexOf('--output') + 1];
      expect(staging, importCall[importCall.indexOf('--input') + 1]);
      expect(File(staging).existsSync(), isFalse);
    });
  });

  group('exec', () {
    test('execCommand hands the command over as ONE argument', () async {
      shell.responses['exec'] = 'hello';
      await api.execCommand('ubuntu', 'echo "a b" | wc -l');
      final call = lastCall();
      final separator = call.indexOf('--');
      // Everything after -- must be exactly one element: ssh flattens argv
      // with spaces and the guest shell re-parses it, the same trap wsl.exe
      // has.
      expect(call.sublist(separator + 1), ['echo "a b" | wc -l']);
    });

    test('cwd is prepended as a quoted cd', () async {
      shell.responses['exec'] = '';
      await api.execCommand('ubuntu', 'ls', cwd: "/tmp/it's here");
      final call = lastCall();
      expect(call.last, "cd '/tmp/it'\\''s here' && ls");
    });

    test('execCmdAsRoot runs as root and returns stdout', () async {
      shell.responses['exec'] = 'root-output';
      final out = await api.execCmdAsRoot('ubuntu', 'id');
      expect(out, 'root-output');
      expect(lastCall(), containsAll(['--user', 'root']));
    });
  });

  // The backend-neutral surface the AI sandbox runs on: same contract as the
  // WSL side, over `vmctl exec` instead of wsl.exe (bostrot/ai-tasks#59).
  group('in-instance run and files', () {
    test('runInInstance keeps the guest exit code and both channels',
        () async {
      shell.responses['exec'] = 'out';
      shell.errors['exec'] = 'err';
      shell.exitCodes['exec'] = 2;

      final out = await api.runInInstance('ubuntu', 'false', user: 'dev');

      expect(out.exitCode, 2);
      expect(out.ok, false);
      expect(out.stdout, 'out');
      expect(out.stderr, 'err');
      expect(lastCall(), containsAll(['--user', 'dev']));
    });

    test('a blank user still runs as root', () async {
      shell.responses['exec'] = '';
      await api.runInInstance('ubuntu', 'id', user: '   ');
      expect(lastCall(), containsAll(['--user', 'root']));
    });

    test('writeInstanceFile sends the payload base64-encoded', () async {
      shell.responses['exec'] = '';

      final ok = await api.writeInstanceFile(
          'ubuntu', '/etc/motd', "hi \$USER; rm -rf /");

      expect(ok, true);
      final script = lastCall().last;
      // Nothing the guest's shell can act on survives into the script: the
      // content travels as base64 and is decoded inside the guest.
      expect(script, contains('base64 -d > /etc/motd'));
      expect(script, isNot(contains('rm -rf')));
      expect(script, contains(base64.encode(utf8.encode("hi \$USER; rm -rf /"))));
    });

    test('a path a shell would reinterpret is refused, not quoted', () async {
      final ok = await api.writeInstanceFile(
          'ubuntu', '/etc/motd; rm -rf /', 'x');

      expect(ok, false);
      expect(shell.calls, isEmpty);
      expect(await api.readInstanceFile('ubuntu', '/etc/motd; rm -rf /'),
          isNull);
      expect(shell.calls, isEmpty);
    });

    test('an unreachable guest reads as null, not as an empty file', () async {
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = 'ssh: connect to host port 22: no route';

      expect(await api.readInstanceFile('ubuntu', '/etc/hostname'), isNull);
    });

    test('a readable file comes back verbatim', () async {
      shell.responses['exec'] = 'guest-1\n';
      expect(await api.readInstanceFile('ubuntu', '/etc/hostname'),
          'guest-1\n');
    });

    test('a write the guest rejects reports failure', () async {
      shell.exitCodes['exec'] = 1;
      expect(await api.writeInstanceFile('ubuntu', '/etc/motd', 'x'), false);
    });
  });

  // A VM installed by hand from an ISO never got the store key from
  // cloud-init, so `exec` — and every snippet — failed with ssh's
  // "Permission denied" in a Terminal window (bostrot/ai-tasks#16).
  group('guest access', () {
    test('probe is ok when `true` runs by key', () async {
      final probe = await api.probeGuestAccess('alpine_2');
      expect(probe.ok, isTrue);
      expect(lastCall(), containsAll(['exec', '--user', 'root', 'true']));
    });

    test('probe tells a missing key apart from any other failure', () async {
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] =
          'root@192.168.64.2: Permission denied (publickey,password,keyboard-interactive).';
      final denied = await api.probeGuestAccess('alpine_2', user: 'root');
      expect(denied.state, GuestAccessState.denied);
      expect(denied.message, contains('Permission denied'));

      // ssh's 255 for anything else (no route, no sshd) is not repairable
      // with a password, and must not open the credentials dialog.
      shell.errors['exec'] = 'ssh: connect to host 192.168.64.2 port 22: Connection refused';
      final refused = await api.probeGuestAccess('alpine_2');
      expect(refused.state, GuestAccessState.unreachable);
      expect(refused.message, contains('Connection refused'));

      // A stopped VM: vmctl itself says so with exit 1.
      shell.exitCodes['exec'] = 1;
      shell.errors['exec'] = 'VM alpine_2 is not running.';
      final stopped = await api.probeGuestAccess('alpine_2');
      expect(stopped.state, GuestAccessState.unreachable);
      expect(stopped.message, 'VM alpine_2 is not running.');
    });

    test('authorizeSshKey passes the password by environment, never argv',
        () async {
      shell.responses['authorize'] =
          '{"authorized":"alpine_2","root":true,"user":"eric"}';
      final result = await api.authorizeSshKey('alpine_2',
          user: 'eric', password: 'p4ss w0rd');
      expect(result.user, 'eric');
      expect(result.rootInstalled, isTrue);
      final call = lastCall();
      expect(call, containsAll(['authorize', '--name', 'alpine_2', '--user', 'eric']));
      expect(call.join(' '), isNot(contains('p4ss')));
      expect(shell.environments.last, {AppleVmApi.guestPasswordEnv: 'p4ss w0rd'});
    });

    test('authorizeSshKey reports when only the login user got the key',
        () async {
      shell.responses['authorize'] =
          '{"authorized":"alpine_2","root":false,"user":"eric"}';
      final result = await api.authorizeSshKey('alpine_2',
          user: 'eric', password: 'x');
      expect(result.rootInstalled, isFalse);
    });

    test('authorizeSshKey surfaces ssh\'s reason on a failed sign-in',
        () async {
      shell.exitCodes['authorize'] = 1;
      shell.errors['authorize'] =
          'Could not sign in as eric@192.168.64.2: Permission denied (publickey,password).';
      expect(
          () => api.authorizeSshKey('alpine_2', user: 'eric', password: 'x'),
          throwsA(isA<AppleVmException>().having((e) => e.message, 'message',
              contains('Could not sign in as eric'))));
    });
  });

  group('sizes and metadata', () {
    test('instanceSizeLabel reads the disk image on disk', () {
      final vmDir = Directory('${tempStore.path}/sized')..createSync();
      final disk = File('${vmDir.path}/disk.img');
      disk.writeAsBytesSync(List.filled(3 * 1024 * 1024, 0));
      // Too small for a GB label to show a whole number, but the format
      // stays the WSL one: "<n.nn> GB".
      expect(api.instanceSizeLabel('sized'), '0.00 GB');
      expect(api.instanceSizeLabel('missing'), '');
    });

    test('getDefaultUser comes from the VM config', () async {
      shell.responses['list'] = json.encode({
        'vms': [
          {'name': 'ubuntu', 'state': 'stopped', 'user': 'dev'},
        ]
      });
      expect(await api.getDefaultUser('ubuntu'), 'dev');
      expect(await api.getDefaultUser('missing'), 'root');
    });

    test('guestIp returns null when the helper has no lease', () async {
      shell.responses['ip'] = '{"ip":null}';
      expect(await api.guestIp('ubuntu'), isNull);
      shell.responses['ip'] = '{"ip":"192.168.64.5"}';
      expect(await api.guestIp('ubuntu'), '192.168.64.5');
    });
  });

  group('helper discovery', () {
    // A fully described host: the chain only ever sees these inputs, so
    // the test cannot pass or fail on what this machine has installed.
    const home = '/Users/eric';
    const repo = '/Users/eric/src/wslmanager';
    const bundle = '/Applications/WSL Manager.app/Contents/MacOS/WSL Manager';
    const data = '/Users/eric/Library/Containers/WSLManager/Data';
    final bundled = p.normalize(
      p.join(p.dirname(bundle), '..', 'Resources', 'vmctl'),
    );
    final inData = p.join(data, 'bin', 'vmctl');
    final installed = p.join(
      home,
      'Library',
      'Application Support',
      'WSLManager',
      'bin',
      'vmctl',
    );
    String checkoutBuild(String root, String config) =>
        p.join(root, 'macos', 'vmctl', '.build', config, 'vmctl');
    final release = checkoutBuild(repo, 'release');
    final debug = checkoutBuild(repo, 'debug');

    String resolve(
      Set<String> onDisk, {
      Map<String, String> env = const {'HOME': home, 'PWD': repo},
      String cwd = '/',
    }) => findVmctlHelper(
      environment: env,
      executable: bundle,
      dataDir: data,
      currentDir: cwd,
      exists: onDisk.contains,
    );

    test('VMCTL_PATH wins when it points at a file', () {
      expect(
        resolve(
          {'/opt/vmctl', bundled},
          env: {'HOME': home, 'VMCTL_PATH': '/opt/vmctl'},
        ),
        '/opt/vmctl',
      );
    });

    test('a missing or empty VMCTL_PATH is ignored, not trusted', () {
      expect(
        resolve({bundled}, env: {'HOME': home, 'VMCTL_PATH': '/nowhere'}),
        bundled,
      );
      expect(
        resolve({bundled}, env: {'HOME': home, 'VMCTL_PATH': ''}),
        bundled,
      );
    });

    test('the bundled helper beats every dev location', () {
      expect(resolve({bundled, inData, installed, release, debug}), bundled);
      expect(resolve({inData, installed, release, debug}), inData);
    });

    test('the dev install beats the checkout, release beats debug', () {
      expect(resolve({installed, release, debug}), installed);
      expect(resolve({release, debug}), release);
      expect(resolve({debug}), debug);
    });

    test('the checkout is found through PWD or the working directory', () {
      final elsewhere = checkoutBuild('/elsewhere', 'debug');
      expect(
        resolve({elsewhere}, env: {'HOME': home, 'PWD': '/elsewhere'}),
        elsewhere,
      );
      expect(resolve({debug}, env: {'HOME': home}, cwd: repo), debug);
    });

    test('no HOME skips the install location instead of crashing', () {
      expect(resolve({installed}, env: {}), 'vmctl');
    });

    test('nothing on disk falls back to the bare name for PATH', () {
      expect(resolve({}), 'vmctl');
    });

    test('the test override short-circuits the chain', () {
      expect(api.helperPath(), '/fake/vmctl');
    });
  });

  group('console log', () {
    test('opens this boot and the previous one, newest first', () async {
      final run = Directory('${tempStore.path}/ubuntu/run')
        ..createSync(recursive: true);
      File('${run.path}/serial.log').writeAsStringSync('login: ');
      File('${run.path}/serial.log.1')
          .writeAsStringSync('EXT4-fs error: bad checksum');
      expect(await api.openConsoleLog('ubuntu'), isTrue);
      final open = shell.calls.singleWhere((c) => c.first == 'open');
      expect(open.sublist(1, 2), ['-t']);
      expect(open[2], endsWith('serial.log'));
      expect(open[3], endsWith('serial.log.1'));
    });

    test('a guest that printed nothing has no log to open', () async {
      final run = Directory('${tempStore.path}/quiet/run')
        ..createSync(recursive: true);
      File('${run.path}/serial.log').writeAsStringSync('');
      expect(await api.openConsoleLog('quiet'), isFalse);
      expect(await api.openConsoleLog('missing'), isFalse);
      expect(shell.calls.any((c) => c.first == 'open'), isFalse);
    });
  });

  group('startExplorer / disk mounting', () {
    test('a stopped VM with a mountable partition opens the volume',
        () async {
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"stopped"}]}';
      shell.responses['attach'] = '/dev/disk4              \n'
          '/dev/disk4s1        EFI        /Volumes/EFI BOOT\n';
      api.startExplorer('ubuntu');
      await Future<void>.delayed(Duration.zero);
      final opened =
          shell.calls.where((c) => c.first == 'start:open').toList();
      expect(opened, isNotEmpty);
      expect(opened.first.last, '/Volumes/EFI BOOT');
      // Browsing must never write to the guest's own partitions.
      final attach = shell.calls.firstWhere((c) => c.contains('attach'));
      expect(attach, contains('-readonly'));
    });

    test('an unmountable disk detaches again and opens the VM folder',
        () async {
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"stopped"}]}';
      // Attached, but macOS mounted no volume (ext4-only disk).
      shell.responses['attach'] = '/dev/disk4\n';
      api.startExplorer('ubuntu');
      await Future<void>.delayed(Duration.zero);
      expect(shell.calls.any((c) => c.contains('detach')), isTrue,
          reason: 'a device nothing mounted must not stay attached');
      final opened = shell.calls.lastWhere((c) => c.first == 'start:open');
      expect(opened.last, contains('ubuntu'));
    });

    test('a running VM never attaches its disk', () async {
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"running"}]}';
      api.startExplorer('ubuntu');
      await Future<void>.delayed(Duration.zero);
      expect(shell.calls.any((c) => c.contains('attach')), isFalse);
      expect(shell.calls.any((c) => c.first == 'start:open'), isTrue);
    });

    test('start refuses while the disk is mounted in Finder', () async {
      // Joined the way the API joins it: on a Windows CI runner the store
      // path carries backslashes, and a hand-written '/' never matches.
      final disk = p.join(tempStore.path, 'ubuntu', 'disk.img');
      shell.responses['info'] = 'image-path : $disk\n';
      await expectLater(
          api.start('ubuntu'),
          throwsA(predicate(
              (e) => e.toString().contains('vmejectbeforestart-text'))));
      expect(shell.calls.any((c) => c.contains('start') && c.length > 2),
          isFalse, reason: 'the guard must fire before vmctl start');
    });
  });

  group('row labels', () {
    test('the row shows real usage next to the allocation, and the IP',
        () async {
      final vmDir = Directory('${tempStore.path}/ubuntu')..createSync(recursive: true);
      // 32 MiB logical (sparse allocation stand-in for the test).
      final disk = File('${vmDir.path}/disk.img');
      disk.writeAsBytesSync(List.filled(32 * 1024 * 1024, 0));
      // du says 1.5 GiB of real blocks (value in KiB).
      shell.responses['-k'] = '1572864\t${disk.path}';
      shell.responses['list'] = json.encode({
        'vms': [
          {'name': 'ubuntu', 'state': 'running', 'ip': '192.168.64.7'},
        ]
      });

      await api.list(false); // caches the IP
      // First call kicks the du probe and shows the allocation alone.
      expect(api.instanceMetaLabel('ubuntu'), '192.168.64.7 · 0.03 GB');
      await Future<void>.delayed(Duration.zero);
      expect(api.instanceMetaLabel('ubuntu'), '192.168.64.7 · 1.50 GB / 0.03 GB');
    });

    test('a stopped VM shows no IP', () async {
      final vmDir = Directory('${tempStore.path}/quiet')..createSync(recursive: true);
      File('${vmDir.path}/disk.img')
          .writeAsBytesSync(List.filled(1024 * 1024, 0));
      shell.responses['list'] = json.encode({
        'vms': [
          {'name': 'quiet', 'state': 'stopped', 'ip': '192.168.64.9'},
        ]
      });
      await api.list(false);
      expect(api.instanceMetaLabel('quiet'), isNot(contains('192.168')));
    });
  });

  group('runCommands', () {
    test('opens a Terminal .command that execs the snippet via vmctl',
        () async {
      api.runCommands('ubuntu', ['echo hi', 'ls -la'], user: 'dev');
      await Future<void>.delayed(Duration.zero);
      final openCall = shell.calls.lastWhere((c) => c.first == 'start:open');
      final scriptPath = openCall.last;
      expect(scriptPath, endsWith('snippet.command'));
      final script = File(scriptPath).readAsStringSync();
      expect(script, contains('exec'));
      expect(script, contains('--name "ubuntu"'));
      expect(script, contains('--user "dev"'));
      // The snippet travels base64-encoded, decoded in the guest.
      expect(script, contains('base64 -d | sh'));
    });

    test('the snippet environment rides inside the encoded script', () async {
      api.runCommands('ubuntu', ['echo hi'],
          env: {'RUNNER_TOKEN': 'a b\$c'});
      await Future<void>.delayed(Duration.zero);
      final openCall = shell.calls.lastWhere((c) => c.first == 'start:open');
      final script = File(openCall.last).readAsStringSync();
      final payload =
          RegExp(r'printf %s ([A-Za-z0-9+/=]+) \| base64 -d \| sh')
              .firstMatch(script)!
              .group(1)!;
      final decoded = utf8.decode(base64.decode(payload));
      expect(decoded, startsWith('# Values entered for this run.'));
      expect(decoded, contains('export RUNNER_TOKEN='));
      expect(decoded, endsWith('echo hi'));
      // The value itself is encoded again inside, so the guest shell never
      // sees the `\$`.
      expect(decoded, contains(base64.encode(utf8.encode('a b\$c'))));
    });
  });

  group('showDisplay', () {
    test('asks the daemon to present the screen', () async {
      shell.responses['show'] = '{"shown":"ubuntu"}';
      await api.showDisplay('ubuntu');
      expect(lastCall(), containsAll(['show', '--name', 'ubuntu']));
    });

    test('a stopped VM surfaces the helper error', () async {
      shell.exitCodes['show'] = 1;
      shell.errors['show'] = 'VM ubuntu is not running.';
      expect(
          () => api.showDisplay('ubuntu'),
          throwsA(predicate(
              (e) => e.toString().contains('is not running'))));
    });
  });

  group('openConsole', () {
    test('a stopped VM is started headless first', () async {
      shell.responses['start'] = '{"started":"ubuntu"}';
      // The canned list keeps answering "stopped", so the early-exit probe
      // throws after the start — which is fine here: the claim under test
      // is that console mode starts the VM *without* a display window.
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"stopped"}]}';
      await expectLater(api.openConsole('ubuntu'), throwsA(anything));
      final startCall = shell.calls
          .firstWhere((c) => c.contains('start') && c.first != 'start:open');
      expect(startCall, isNot(contains('--gui')),
          reason: 'console mode must not open a display window');
    });

    test('writes a runnable .command bridge and opens it in Terminal',
        () async {
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"running"}]}';
      await api.openConsole('ubuntu');

      // Running already: no start was issued.
      expect(shell.calls.where((c) => c.contains('start') && c.length > 2),
          isEmpty);
      final openCall =
          shell.calls.lastWhere((c) => c.first == 'start:open');
      final scriptPath = openCall.last;
      expect(scriptPath, endsWith('console.command'));
      final script = File(scriptPath).readAsStringSync();
      expect(script, contains("'/fake/vmctl'"));
      // Single-quoted throughout: the VM name and the guest account are
      // stored strings, and this file is a shell script.
      expect(script, contains("'console' '--name' 'ubuntu'"));
      expect(script, contains(tempStore.path));
    });
  });

  group('openTerminal', () {
    test('a running guest gets an SSH shell as its own account', () async {
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"running","os":"linux","user":"eric",'
          '"ip":"192.168.64.4"}]}';
      await api.openTerminal('ubuntu');

      // The probe ran as the VM's user, not root.
      final probe = shell.calls.firstWhere((c) => c.contains('exec'));
      expect(probe, containsAll(['--user', 'eric', 'true']));

      final openCall = shell.calls.lastWhere((c) => c.first == 'start:open');
      final script = File(openCall.last).readAsStringSync();
      expect(openCall.last, endsWith('shell.command'));
      expect(script,
          contains("'shell' '--name' 'ubuntu' '--user' 'eric'"));
      expect(script, isNot(contains('console')));
    });

    test('a guest that refuses the key falls back to the serial console',
        () async {
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"running","os":"linux","user":"eric",'
          '"ip":"192.168.64.4"}]}';
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = 'eric@192.168.64.2: Permission denied (publickey).';

      await api.openTerminal('ubuntu');

      final openCall = shell.calls.lastWhere((c) => c.first == 'start:open');
      expect(openCall.last, endsWith('console.command'));
      expect(File(openCall.last).readAsStringSync(), contains('console'));
    });

    test('a guest with no lease yet is not probed at all', () async {
      // Without an address the probe can only spend vmctl's 20s lease wait
      // and ssh's connect timeout to learn what the empty `ip` already said.
      shell.responses['list'] =
          '{"vms":[{"name":"ubuntu","state":"running","os":"linux","user":"eric"}]}';
      await api.openTerminal('ubuntu');
      expect(shell.calls.where((c) => c.contains('exec')), isEmpty);
      expect(shell.calls.lastWhere((c) => c.first == 'start:open').last,
          endsWith('console.command'));
    });
  });

  /// A macOS guest has no serial device at all, so the console the Linux
  /// path falls back on does not exist for it — the terminal button used to
  /// hand the user a Terminal window saying "Serial console is only
  /// available for Linux guests." (bostrot/ai-tasks#101).
  group('a macOS guest terminal', () {
    const running = '{"vms":[{"name":"sequoia","state":"running","os":"macos",'
        '"user":"user","ip":"192.168.64.5"}]}';

    // The real English strings, so the assertions below are about what the
    // user is told and not about a key name.
    setUp(() async {
      MapLocalization.delegate.translations = {
        const Locale('en'): (json.decode(
                File(p.join('lib', 'i18n', 'en.json')).readAsStringSync())
            as Map)
            .cast<String, dynamic>(),
      };
      await MapLocalization.delegate.load(const Locale('en'));
    });

    tearDown(() async {
      MapLocalization.delegate.translations = {};
      await MapLocalization.delegate.load(const Locale('en'));
    });

    List<String> openedScript() =>
        shell.calls.lastWhere((c) => c.first == 'start:open');

    test('a running guest gets an SSH shell, never the console', () async {
      shell.responses['list'] = running;
      await api.openTerminal('sequoia');

      final probe = shell.calls.firstWhere((c) => c.contains('exec'));
      expect(probe, containsAll(['--user', 'user', 'true']));
      expect(openedScript().last, endsWith('shell.command'));
      expect(File(openedScript().last).readAsStringSync(),
          contains("'shell' '--name' 'sequoia' '--user' 'user'"));
      expect(shell.calls.where((c) => c.contains('console')), isEmpty);
    });

    test("the instance's own user setting names the Setup Assistant account",
        () async {
      // `vmctl create --os macos` never learns the account typed into Setup
      // Assistant and keeps its placeholder, so the instance's user setting
      // is the only place that name can come from.
      await prefs.setString('StartUser_sequoia', 'eric');
      shell.responses['list'] = running;
      await api.openTerminal('sequoia');

      expect(shell.calls.firstWhere((c) => c.contains('exec')),
          containsAll(['--user', 'eric']));
      expect(File(openedScript().last).readAsStringSync(),
          contains("'--user' 'eric'"));
    });

    test('the console button opens the same SSH shell', () async {
      shell.responses['list'] = running;
      await api.openConsole('sequoia');
      expect(openedScript().last, endsWith('shell.command'));
    });

    test('a refused key is reported in the app, not in a Terminal window',
        () async {
      shell.responses['list'] = running;
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = 'user@192.168.64.5: Permission denied (publickey).';

      await expectLater(
          api.openTerminal('sequoia'),
          throwsA(isA<GuestKeyRefusedException>()
              // The account to offer the repair for travels with it.
              .having((e) => e.user, 'user', 'user')
              .having((e) => e.message, 'message', contains('Remote Login'))));
      // Nothing was opened at all: a console window here would only carry
      // the helper's "Linux guests" refusal.
      expect(shell.calls.where((c) => c.first == 'start:open'), isEmpty);
    });

    test('an unreachable guest reports why instead of opening a console',
        () async {
      shell.responses['list'] = running;
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = 'ssh: connect to host 192.168.64.5 port 22: '
          'Connection refused';

      await expectLater(
          api.openTerminal('sequoia'),
          throwsA(allOf(
            // Not the refusal the key dialog can repair: no sshd answered at
            // all, so the row must not offer to install a key.
            isNot(isA<GuestKeyRefusedException>()),
            predicate((e) =>
                e.toString().contains('Connection refused') &&
                e.toString().contains('Remote Login')),
          )));
      expect(shell.calls.where((c) => c.first == 'start:open'), isEmpty);
    });

    test('a stopped guest is started headless and waited for', () async {
      final waiting = AppleVmApi(
        shell: shell,
        helperPathOverride: '/fake/vmctl',
        storeDirOverride: tempStore.path,
        earlyExitProbeDelay: Duration.zero,
        guestReadyPollInterval: Duration.zero,
        // Long enough to poll, short enough for a test: the deadline is only
        // consulted after a probe has answered.
        macosTerminalTimeout: const Duration(minutes: 1),
      );
      shell.responseQueue['list'] = [
        '{"vms":[{"name":"sequoia","state":"stopped","os":"macos",'
            '"user":"user"}]}',
      ];
      // Once started it stays up, which is what the early-exit probe after
      // a headless start reads.
      shell.responses['list'] = running;
      shell.responses['start'] = '{"started":"sequoia"}';
      // sshd comes up a few seconds after the boot does.
      shell.exitCodeQueue['exec'] = [255, 255, 0];
      shell.errors['exec'] = 'ssh: connect to host: Connection refused';

      await waiting.openMacosTerminal(
          'sequoia', (await waiting.listVms()).single);

      final startCall = shell.calls
          .firstWhere((c) => c.contains('start') && c.first != 'start:open');
      expect(startCall, isNot(contains('--gui')));
      expect(shell.calls.where((c) => c.contains('exec')), hasLength(3));
      expect(openedScript().last, endsWith('shell.command'));
    });

    test('a guest that never answers gives up with words', () async {
      shell.responseQueue['list'] = [
        '{"vms":[{"name":"sequoia","state":"stopped","os":"macos",'
            '"user":"user"}]}',
      ];
      shell.responses['list'] = running;
      shell.responses['start'] = '{"started":"sequoia"}';
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = 'ssh: connect to host: Connection refused';

      // The api under test has a zero-length wait, so the first probe after
      // the start is also the last.
      await expectLater(api.openConsole('sequoia'),
          throwsA(predicate((e) => e.toString().contains('Remote Login'))));
      expect(shell.calls.where((c) => c.first == 'start:open'), isEmpty);
    });

    test('no guest greeting is written into a macOS guest', () async {
      // The greeting is an /etc/profile.d snippet; macOS reads no such
      // directory and would not let the account write it either.
      shell.responses['list'] = running;
      await api.openTerminal('sequoia');
      expect(
          shell.calls.where(
              (c) => c.contains('exec') && c.last.contains(GuestGreeting.path)),
          isEmpty);
      expect(prefs.getInt(GuestGreeting.prefKey('sequoia')), isNull);
    });
  });

  /// Which account a run nobody named an account for signs in as. Root on a
  /// Linux guest, as it has always been; on a macOS guest root cannot sign in
  /// over SSH at all, and every snippet run as root died at the guest's door
  /// (bostrot/ai-tasks#101).
  group('the account an unattended run uses', () {
    const linux = '{"vms":[{"name":"ubuntu","state":"running","os":"linux",'
        '"user":"eric","ip":"192.168.64.4"}]}';
    const macos = '{"vms":[{"name":"sequoia","state":"running","os":"macos",'
        '"user":"user","ip":"192.168.64.5"}]}';

    test('a Linux guest still runs as root', () async {
      shell.responses['list'] = linux;
      expect(await api.execUser('ubuntu'), 'root');
    });

    test("a macOS guest uses vmctl's account rather than root", () async {
      shell.responses['list'] = macos;
      expect(await api.execUser('sequoia'), 'user');
    });

    test('the pinned account wins on either guest', () async {
      await AppleVmApi.setPreferredUser('sequoia', 'erict');
      await AppleVmApi.setPreferredUser('ubuntu', 'dev');
      shell.responses['list'] = macos;
      expect(await api.execUser('sequoia'), 'erict');
      shell.responses['list'] = linux;
      expect(await api.execUser('ubuntu'), 'dev');
      // A pinned account is an answer on its own: the helper is not asked
      // what the guest thinks its account is.
      expect(shell.calls.where((c) => c.contains('list')), isEmpty);
    });

    test('a guest vmctl cannot describe falls back to root', () async {
      shell.exitCodes['list'] = 1;
      shell.errors['list'] = 'No such VM.';
      expect(await api.execUser('ghost'), 'root');
    });

    test('an empty pin is cleared rather than stored', () async {
      await AppleVmApi.setPreferredUser('sequoia', 'erict');
      await AppleVmApi.setPreferredUser('sequoia', '   ');
      expect(prefs.getString('StartUser_sequoia'), isNull);
      expect(AppleVmApi.preferredUser('sequoia'), isEmpty);
    });

    test('a snippet with no start user reaches a macOS guest as its account',
        () async {
      shell.responses['list'] = macos;
      await api.runCommands('sequoia', ['echo hi']);
      final script = File(shell.calls
              .lastWhere((c) => c.first == 'start:open')
              .last)
          .readAsStringSync();
      expect(script, contains('--user "user"'));
      expect(script, isNot(contains('--user "root"')));
    });

    test('the pinned account is what a snippet signs in as', () async {
      await AppleVmApi.setPreferredUser('sequoia', 'erict');
      shell.responses['list'] = macos;
      await api.runCommands('sequoia', ['echo hi']);
      final script = File(shell.calls
              .lastWhere((c) => c.first == 'start:open')
              .last)
          .readAsStringSync();
      expect(script, contains('--user "erict"'));
    });

    test('a snippet in a Linux guest is unchanged', () async {
      shell.responses['list'] = linux;
      await api.runCommands('ubuntu', ['echo hi']);
      final script = File(shell.calls
              .lastWhere((c) => c.first == 'start:open')
              .last)
          .readAsStringSync();
      expect(script, contains('--user "root"'));
    });

    test('an account the caller names is used as given', () async {
      shell.responses['list'] = macos;
      await api.runCommands('sequoia', ['echo hi'], user: ' dev ');
      final script = File(shell.calls
              .lastWhere((c) => c.first == 'start:open')
              .last)
          .readAsStringSync();
      expect(script, contains('--user "dev"'));
    });
  });

  group('guest greeting', () {
    const running =
        '{"vms":[{"name":"ubuntu","state":"running","os":"linux","user":"eric",'
        '"ip":"192.168.64.4"}]}';

    /// The exec that carries the profile snippet, as opposed to the probe.
    List<List<String>> installs() => shell.calls
        .where((c) => c.contains('exec') && c.last.contains(GuestGreeting.path))
        .toList();

    test('the terminal button seeds the snippet before opening the shell',
        () async {
      shell.responses['list'] = running;
      await api.openTerminal('ubuntu');

      expect(installs(), hasLength(1));
      // As the account the session is about to use, not root: that is the
      // one cloud-init gave passwordless sudo.
      expect(installs().single, containsAll(['--user', 'eric']));

      final installIndex = shell.calls.indexOf(installs().single);
      final openIndex =
          shell.calls.indexWhere((c) => c.first == 'start:open');
      expect(installIndex, lessThan(openIndex),
          reason: 'the login shell ssh starts has to find the snippet there');
      expect(prefs.getInt(GuestGreeting.prefKey('ubuntu')),
          GuestGreeting.version);
    });

    test('a VM that already has this version is not touched again', () async {
      shell.responses['list'] = running;
      await prefs.setInt(GuestGreeting.prefKey('ubuntu'), GuestGreeting.version);
      await api.openTerminal('ubuntu');
      expect(installs(), isEmpty);
    });

    test('an older version is replaced', () async {
      shell.responses['list'] = running;
      await prefs.setInt(
          GuestGreeting.prefKey('ubuntu'), GuestGreeting.version - 1);
      expect(await api.ensureGuestGreeting('ubuntu', user: 'eric'), isTrue);
      expect(prefs.getInt(GuestGreeting.prefKey('ubuntu')),
          GuestGreeting.version);
    });

    test('the setting turns it off', () async {
      shell.responses['list'] = running;
      await prefs.setBool(GuestGreeting.enabledPrefKey, false);
      await api.openTerminal('ubuntu');
      expect(installs(), isEmpty);
      // The terminal itself is unaffected.
      expect(shell.calls.lastWhere((c) => c.first == 'start:open').last,
          endsWith('shell.command'));
    });

    test('a guest that refuses the write still gets its terminal', () async {
      shell.responses['list'] = running;
      // The probe and the install share the `exec` subcommand, so the probe
      // answers first and the install after it.
      shell.exitCodeQueue['exec'] = [0, 1];
      shell.errors['exec'] = 'wslmanager: no way to write /etc/profile.d';

      await api.openTerminal('ubuntu');

      expect(installs(), hasLength(1));
      expect(prefs.getInt(GuestGreeting.prefKey('ubuntu')), isNull,
          reason: 'a failed install must be retried, not remembered');
      expect(shell.calls.lastWhere((c) => c.first == 'start:open').last,
          endsWith('shell.command'));
    });

    test('a refused install reports itself instead of throwing', () async {
      shell.exitCodes['exec'] = 1;
      shell.errors['exec'] = 'wslmanager: no way to write /etc/profile.d';
      expect(await api.ensureGuestGreeting('ubuntu', user: 'eric'), isFalse);
      expect(prefs.getInt(GuestGreeting.prefKey('ubuntu')), isNull);
    });

    test('priming after a start waits for the guest, then installs', () async {
      shell.responses['list'] = running;
      await api.primeGuestGreeting('ubuntu');
      expect(installs(), hasLength(1));
      expect(prefs.getInt(GuestGreeting.prefKey('ubuntu')),
          GuestGreeting.version);
    });

    test('priming an unreachable guest gives up quietly', () async {
      shell.responses['list'] = running;
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = 'Connection refused';
      await api.primeGuestGreeting('ubuntu');
      expect(installs(), isEmpty);
      expect(prefs.getInt(GuestGreeting.prefKey('ubuntu')), isNull);
    });

    test('a macOS guest has no profile to seed', () async {
      shell.responses['list'] =
          '{"vms":[{"name":"sequoia","state":"running","os":"macos",'
          '"user":"user","ip":"192.168.64.5"}]}';
      await api.primeGuestGreeting('sequoia');
      expect(shell.calls.where((c) => c.contains('exec')), isEmpty);
    });
  });

  group('guestCredentials', () {
    test('parses the account, password, key and address', () async {
      shell.responses['credentials'] = json.encode({
        'name': 'ubuntu',
        'user': 'eric',
        'password': 'Abc23xyz',
        'sshKey': '/store/id_ed25519',
        'ip': '192.168.64.4',
        'appliedOnNextBoot': false,
      });
      final credentials = await api.guestCredentials('ubuntu');
      expect(lastCall(), containsAll(['credentials', '--name', 'ubuntu']));
      expect(credentials.user, 'eric');
      expect(credentials.password, 'Abc23xyz');
      expect(credentials.sshKeyPath, '/store/id_ed25519');
      expect(credentials.ip, '192.168.64.4');
      expect(credentials.appliedOnNextBoot, isFalse);
    });

    test('a VM given its password just now says so', () async {
      shell.responses['credentials'] = json.encode({
        'user': 'eric',
        'password': 'Abc23xyz',
        'sshKey': '/store/id_ed25519',
        'appliedOnNextBoot': true,
      });
      final credentials = await api.guestCredentials('old');
      expect(credentials.appliedOnNextBoot, isTrue);
      // Stopped guests have no address; the dialog must not invent one.
      expect(credentials.ip, isNull);
    });

    test('a root-only guest reports no password rather than an empty one',
        () async {
      shell.responses['credentials'] =
          '{"user":"root","sshKey":"/store/id_ed25519","appliedOnNextBoot":false}';
      final credentials = await api.guestCredentials('root-vm');
      expect(credentials.user, 'root');
      expect(credentials.password, isNull);
    });

    test('unreadable helper output is an error, not a blank dialog', () async {
      shell.responses['credentials'] = 'not json';
      expect(
          () => api.guestCredentials('ubuntu'),
          throwsA(isA<AppleVmException>().having((e) => e.message, 'message',
              contains('unreadable'))));
    });

    test('a missing VM surfaces the helper error', () async {
      shell.exitCodes['credentials'] = 1;
      shell.errors['credentials'] = 'No VM named "ghost".';
      expect(
          () => api.guestCredentials('ghost'),
          throwsA(isA<AppleVmException>()
              .having((e) => e.message, 'message', contains('No VM named'))));
    });
  });

  group('createLinuxVm / createMacosVm', () {
    test('linux create forwards sizes, user, iso and image', () async {
      shell.responses['create'] = '{"created":"dev"}';
      await api.createLinuxVm('dev',
          isoPath: '/tmp/ubuntu.iso',
          diskSizeGb: 64,
          cpus: 4,
          memoryGb: 8,
          user: 'eric');
      final call = lastCall();
      expect(
          call,
          containsAll([
            'create', '--name', 'dev', '--os', 'linux',
            '--disk-size', '64', '--cpus', '4', '--memory', '8',
            '--user', 'eric', '--iso', '/tmp/ubuntu.iso',
          ]));
      expect(call, isNot(contains('--image')));
    });

    test('a cloud-init document travels as a file that is gone afterwards',
        () async {
      shell.responses['create'] = '{"created":"dev"}';
      String? handedOver;
      String? handoffPath;
      shell.onCommand = (command) {
        if (command != 'create') return;
        final call = shell.calls.last;
        handoffPath = call[call.indexOf('--user-data') + 1];
        handedOver = File(handoffPath!).readAsStringSync();
      };
      await api.createLinuxVm('dev',
          imagePath: '/tmp/debian.qcow2',
          userData: '#cloud-config\npackages:\n  - git\n');
      // The document is on disk, verbatim, while vmctl runs (argv is no
      // place for a multi-line YAML document) …
      expect(handedOver, '#cloud-config\npackages:\n  - git\n');
      // … and cleaned up once vmctl has copied it into the VM's directory.
      expect(File(handoffPath!).existsSync(), isFalse);
      expect(Directory(handoffPath!).parent.existsSync(), isFalse);
    });

    test('the handoff file is removed even when vmctl fails', () async {
      shell.exitCodes['create'] = 1;
      shell.errors['create'] = 'no';
      String? handoffPath;
      shell.onCommand = (command) {
        if (command != 'create') return;
        final call = shell.calls.last;
        handoffPath = call[call.indexOf('--user-data') + 1];
      };
      await expectLater(
          api.createLinuxVm('dev', userData: '#!/bin/sh\necho hi\n'),
          throwsA(isA<AppleVmException>()));
      expect(File(handoffPath!).existsSync(), isFalse);
    });

    test('no document, or a blank one, passes no --user-data', () async {
      shell.responses['create'] = '{"created":"dev"}';
      await api.createLinuxVm('dev');
      expect(lastCall(), isNot(contains('--user-data')));
      await api.createLinuxVm('dev', userData: '  \n');
      expect(lastCall(), isNot(contains('--user-data')));
    });

    test('macos create forwards the restore image', () async {
      shell.responses['create'] = '{"created":"sequoia"}';
      await api.createMacosVm('sequoia', restoreImagePath: '/tmp/r.ipsw');
      expect(
          lastCall(),
          containsAll([
            'create', '--name', 'sequoia', '--os', 'macos',
            '--restore-image', '/tmp/r.ipsw',
          ]));
    });

    test('macos create reports every step the helper announces', () async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] = [
        'progress {"phase":"lookup"}',
        'progress {"fraction":0.5,"phase":"download","received":7,"total":14}',
        'progress {"phase":"prepare"}',
        'progress {"fraction":0.25,"phase":"install"}',
      ].join('\n');

      final seen = <VmCreateProgress>[];
      await api.createMacosVm('sequoia', onProgress: seen.add);

      expect(seen.map((u) => u.phase), [
        VmCreatePhase.lookup,
        VmCreatePhase.download,
        VmCreatePhase.prepare,
        VmCreatePhase.install,
      ]);
      expect(seen[1].fraction, 0.5);
      expect(seen[1].received, 7);
      expect(seen[1].total, 14);
      expect(seen[3].fraction, 0.25);
      // Streamed, not buffered: a create that runs for an hour has to say
      // something before it is over.
      expect(lastCall().first, 'start:/fake/vmctl');
    });

    test('a failed macos create is reported without its progress lines',
        () async {
      shell.exitCodes['create'] = 1;
      shell.errors['create'] = [
        'progress {"fraction":1,"phase":"download"}',
        'macOS installation failed: no space left on device',
      ].join('\n');

      final seen = <VmCreateProgress>[];
      await expectLater(
          api.createMacosVm('sequoia', onProgress: seen.add),
          throwsA(isA<AppleVmException>().having((e) => e.message, 'message',
              'macOS installation failed: no space left on device')));
      expect(seen, hasLength(1));
    });

    test('the helper\'s plain lines reach the caller as status', () async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] = [
        'downloading restore image from https://example.invalid/r.ipsw',
        'progress {"phase":"download","fraction":0.5}',
        '',
      ].join('\n');

      final status = <String>[];
      final seen = <VmCreateProgress>[];
      await api.createMacosVm('sequoia',
          onProgress: seen.add, onStatus: status.add);

      // Only the plain line, and without the blank one after it: this is
      // what a create shows while the helper reports no step at all.
      expect(status,
          ['downloading restore image from https://example.invalid/r.ipsw']);
      expect(seen, hasLength(1));
    });

    /// A dev run resolves `vmctl` from the install path, which rebuilding
    /// the app does not refresh, so the app has to cope with the helper
    /// that shipped before the progress protocol (bostrot/ai-tasks#100).
    test('an older helper\'s install percentage still drives the bar',
        () async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] = [
        'downloading restore image from https://example.invalid/r.ipsw',
        'install 41%',
        'install 42%',
      ].join('\n');

      final status = <String>[];
      final seen = <VmCreateProgress>[];
      await api.createMacosVm('sequoia',
          onProgress: seen.add, onStatus: status.add);

      expect(seen.map((u) => u.phase),
          [VmCreatePhase.install, VmCreatePhase.install]);
      expect(seen.last.fraction, closeTo(0.42, 1e-9));
      expect(status, hasLength(1));
    });
  });

  group('create progress lines', () {
    test('a line without the prefix is not progress', () {
      expect(VmCreateProgress.parse('installing macOS'), isNull);
      expect(VmCreateProgress.parse(''), isNull);
    });

    /// The helper and the app ship together, but a user can end up with an
    /// older app next to a newer helper; an unknown phase has to be
    /// ignorable rather than fatal.
    test('malformed or unknown reports are ignored, never thrown', () {
      expect(VmCreateProgress.parse('progress not json'), isNull);
      expect(VmCreateProgress.parse('progress ["download"]'), isNull);
      expect(VmCreateProgress.parse('progress {"phase":"reticulating"}'),
          isNull);
    });

    test('a fraction outside 0..1 is clamped to the bar', () {
      expect(
          VmCreateProgress.parse('progress {"phase":"install","fraction":1.4}')!
              .fraction,
          1.0);
      expect(
          VmCreateProgress.parse('progress {"phase":"install","fraction":-2}')!
              .fraction,
          0.0);
    });

    test('the pre-protocol install line is read as install progress', () {
      final update = VmCreateProgress.parse('install 7%')!;
      expect(update.phase, VmCreatePhase.install);
      expect(update.fraction, closeTo(0.07, 1e-9));
      expect(VmCreateProgress.parse('install 100%')!.fraction, 1.0);
      // Only that exact shape: the helper's prose is a diagnostic.
      expect(VmCreateProgress.parse('install failed: 7% done'), isNull);
      expect(VmCreateProgress.parse('installing 7%'), isNull);
    });

    test('a download of unknown length carries no total', () {
      final update =
          VmCreateProgress.parse('progress {"phase":"download","total":0}')!;
      expect(update.total, isNull);
      expect(update.fraction, isNull);
    });
  });

  group('root filesystem transfer', () {
    String vmList(List<Map<String, Object?>> vms) => json.encode({'vms': vms});

    Map<String, Object?> vm(String name,
            {bool running = false, String os = 'linux'}) =>
        {
          'name': name,
          'state': running ? 'running' : 'stopped',
          'os': os,
          'user': 'dev',
        };

    /// The single argument `vmctl exec` was handed for the streamed command.
    String remoteCommandOf(List<String> call) => call.last;

    List<String> streamedExecCall() =>
        shell.calls.lastWhere((c) => c.first.startsWith('start:'));

    late File archive;

    setUp(() {
      archive = File(p.join(tempStore.path, 'rootfs.tar'));
    });

    test('the feature flags advertise a rootfs the long way round', () {
      // vmctl's own export is a raw disk; the flag says the *backend* can
      // still produce a root filesystem, which is what the cloud deploy asks
      // for. The second flag is why the pull-back reads differently here.
      expect(api.features.rootfsExport, isTrue);
      expect(api.features.rootfsImportNeedsBase, isTrue);
    });

    test('a running guest is tarred over vmctl exec, straight to the file',
        () async {
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.responses['exec'] = 'TAR-BYTES';

      await api.exportRootfs('ubuntu', archive.path);

      expect(archive.readAsStringSync(), 'TAR-BYTES');
      final call = streamedExecCall();
      expect(call, containsAll(['exec', '--name', 'ubuntu', '--user', 'root']));
      final remote = remoteCommandOf(call);
      // Under the C locale: the export reads tar's warnings by their
      // English wording, and ssh would otherwise forward the Mac's locale.
      expect(remote, startsWith("'env' 'LC_ALL=C' 'tar' '-cf' '-' '-C' '/'"));
      expect(remote, endsWith("'.'"));
      // Nothing was started or stopped: the guest was already up.
      expect(shell.calls.any((c) => c.contains('start')), isFalse);
      expect(shell.calls.any((c) => c.contains('stop')), isFalse);
    });

    test('every exclude is quoted, so the guest shell cannot glob it',
        () async {
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.responses['exec'] = 'TAR';

      await api.exportRootfs('ubuntu', archive.path);

      final remote = remoteCommandOf(streamedExecCall());
      // `./proc/*` reaching an unquoted remote shell is a glob against the
      // guest's home directory, not an argument for tar.
      expect(remote, contains("'--exclude=./proc/*'"));
      // A mount point keeps its directory; the kernel and its modules go
      // whole, because the machine they belong to is not the one this lands
      // on.
      expect(remote, isNot(contains("'--exclude=./proc'")));
      expect(remote, contains("'--exclude=./boot'"));
      expect(remote, contains("'--exclude=./boot/*'"));
      expect(remote, contains("'--exclude=./lib/modules'"));
    });

    test('a stopped guest is started headless and stopped again', () async {
      shell.responseQueue['list'] = [
        vmList([vm('ubuntu')]),
        vmList([vm('ubuntu', running: true)]),
      ];
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.responses['exec'] = 'TAR';

      await api.exportRootfs('ubuntu', archive.path);

      final start = shell.calls.firstWhere((c) => c.contains('start'));
      expect(start, containsAll(['start', '--name', 'ubuntu']));
      // Headless: an export is not a reason to put a window on the screen.
      expect(start, isNot(contains('--gui')));
      expect(shell.calls.any((c) => c.contains('stop')), isTrue);
    });

    test('a macOS guest is refused before anything is started', () async {
      shell.responses['list'] = vmList([vm('sequoia', os: 'macos')]);

      await expectLater(
        api.exportRootfs('sequoia', archive.path),
        // Unit tests run without a loaded locale, so a translated message
        // is its own key — which is exactly the assertion worth making: the
        // refusal names the macOS guest, not some generic failure.
        throwsA(predicate((e) => '$e'.contains('vmrootfsmacosguest-text'))),
      );
      expect(shell.calls.any((c) => c.contains('start')), isFalse);
      expect(archive.existsSync(), isFalse);
    });

    test('a VM that is not there is refused by name', () async {
      shell.responses['list'] = vmList([vm('other', running: true)]);

      await expectLater(
        api.exportRootfs('ubuntu', archive.path),
        throwsA(predicate((e) => '$e'.contains('vmrootfsnotfound-text'))),
      );
    });

    test('a guest that never answers reports ssh\'s own words', () async {
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = 'Connection refused';

      await expectLater(
        api.exportRootfs('ubuntu', archive.path),
        throwsA(predicate((e) => '$e'.contains('Connection refused'))),
      );
    });

    test('a failing tar surfaces the guest stderr and fails the export',
        () async {
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      // The readiness probe passes; the tar itself does not.
      shell.exitCodeQueue['exec'] = [0, 2];
      shell.errors['exec'] = 'tar: /: Cannot open: Permission denied';

      await expectLater(
        api.exportRootfs('ubuntu', archive.path),
        throwsA(predicate((e) => '$e'.contains('Permission denied'))),
      );
      // Whatever tar managed to write before it gave up is a truncated
      // archive, and nothing downstream can tell one of those from a whole
      // one.
      expect(archive.existsSync(), isFalse);
    });

    test('a file that changed under tar is a warning, not a failed export',
        () async {
      // The guest is running while it is read, so this happens whenever a
      // log grows or a directory gains an entry during the walk. GNU tar
      // exits 1 for it; the archive is a snapshot all the same, and a
      // deploy that gave up on it would fail one attempt in a few for no
      // reason anyone could act on.
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.responses['exec'] = 'TAR-BYTES';
      shell.exitCodeQueue['exec'] = [0, 1];
      shell.errors['exec'] =
          'tar: ./var/log/journal/abc/system.journal: file changed as we read it\n'
          'tar: ./var/log: file changed as we read it\n'
          'tar: ./tmp/x: File removed before we read it\n'
          'tar: ./run/docker.sock: socket ignored\n';

      await api.exportRootfs('ubuntu', archive.path);

      expect(archive.readAsStringSync(), 'TAR-BYTES');
    });

    test('exit 1 with anything else on stderr still fails the export',
        () async {
      // busybox tar exits 1 for real errors, and so does GNU tar for a
      // warning it has not been taught here; neither is a snapshot.
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.responses['exec'] = 'TAR';
      shell.exitCodeQueue['exec'] = [0, 1];
      shell.errors['exec'] = "tar: can't open './root/x': Permission denied";

      await expectLater(
        api.exportRootfs('ubuntu', archive.path),
        throwsA(predicate((e) => '$e'.contains('Permission denied'))),
      );
      expect(archive.existsSync(), isFalse);
    });

    test('only GNU tar\'s live-system warnings count as harmless', () {
      expect(
          tarExitedWithWarningsOnly(
              'tar: ./var/log/syslog: file changed as we read it\n'),
          isTrue);
      expect(
          tarExitedWithWarningsOnly('tar: ./a: File removed before we read it\n'
              'tar: ./b: File shrank by 12 bytes; padding with zeros\n'
              'tar: ./c: File shrank by 1 byte; padding with zeros\n'),
          isTrue);
      expect(tarExitedWithWarningsOnly(''), isFalse);
      expect(
          tarExitedWithWarningsOnly('tar: ./a: file changed as we read it\n'
              'tar: ./etc/shadow: Cannot open: Permission denied\n'),
          isFalse);
      expect(
          tarExitedWithWarningsOnly(
              'tar: Exiting with failure status due to previous errors\n'),
          isFalse);
    });

    test('a transfer that hangs is killed and reported', () async {
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.responses['exec'] = 'TAR';
      shell.startDelay = const Duration(seconds: 30);
      final impatient = AppleVmApi(
        shell: shell,
        helperPathOverride: '/fake/vmctl',
        storeDirOverride: tempStore.path,
        earlyExitProbeDelay: Duration.zero,
        guestReadyTimeout: Duration.zero,
        guestReadyPollInterval: Duration.zero,
        rootfsTransferTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        impatient.exportRootfs('ubuntu', archive.path),
        throwsA(predicate((e) => '$e'.contains('Timed out'))),
      );
      expect(shell.processes.last.killCount, greaterThan(0));
      expect(archive.existsSync(), isFalse);
    });

    test('an archive with nothing in it is refused, not deployed', () async {
      shell.responses['list'] = vmList([vm('ubuntu', running: true)]);
      shell.responses['exec'] = '';

      await expectLater(
        api.exportRootfs('ubuntu', archive.path),
        throwsA(isA<AppleVmException>()),
      );
      expect(archive.existsSync(), isFalse);
    });

    group('restore', () {
      setUp(() {
        archive.writeAsStringSync('ARCHIVE');
        shell.responses['export'] = '{}';
        shell.responses['import'] = '{}';
      });

      /// list answers: the source alone, then the fresh clone stopped, then
      /// the clone running — the states a restore actually walks through.
      void listsCloneComingUp() {
        shell.responseQueue['list'] = [
          vmList([vm('ubuntu')]),
          vmList([vm('ubuntu'), vm('ubuntu-cloud')]),
          vmList([vm('ubuntu'), vm('ubuntu-cloud', running: true)]),
        ];
        shell.responses['list'] =
            vmList([vm('ubuntu'), vm('ubuntu-cloud', running: true)]);
      }

      test('clones the source, streams the archive in and leaves it stopped',
          () async {
        listsCloneComingUp();
        shell.responses['exec'] = 'tar (GNU tar) 1.35';

        await api.importRootfs('ubuntu-cloud', archive.path,
            sourceInstance: 'ubuntu');

        // The clone is taken from the source, whose disk carries the kernel a
        // bare root filesystem does not.
        final export = shell.calls.firstWhere((c) => c.contains('export'));
        expect(export, containsAll(['--name', 'ubuntu']));
        final import = shell.calls.firstWhere((c) => c.contains('import'));
        expect(import, containsAll(['--name', 'ubuntu-cloud']));

        final call = streamedExecCall();
        expect(call, containsAll(['--name', 'ubuntu-cloud', '--user', 'root']));
        final remote = remoteCommandOf(call);
        expect(remote, startsWith("'tar' '-xf' '-' '-C' '/'"));
        // The archive travels on stdin; nothing buffers a root filesystem.
        expect(utf8.decode(shell.processes.last.stdinBytes), 'ARCHIVE');
        // Everything under /etc and /usr was replaced beneath a running
        // systemd, so the restored VM is left for the user to boot.
        expect(shell.calls.any((c) => c.contains('stop')), isTrue);
      });

      test('a GNU guest gets --unlink-first so a busy binary can be replaced',
          () async {
        listsCloneComingUp();
        shell.responses['exec'] = 'tar (GNU tar) 1.35';

        await api.importRootfs('ubuntu-cloud', archive.path,
            sourceInstance: 'ubuntu');

        expect(remoteCommandOf(streamedExecCall()),
            contains("'--unlink-first'"));
      });

      test('a busybox guest is not sent an option it would reject', () async {
        listsCloneComingUp();
        shell.responses['exec'] = 'BusyBox v1.36.1 multi-call binary';

        await api.importRootfs('ubuntu-cloud', archive.path,
            sourceInstance: 'ubuntu');

        expect(remoteCommandOf(streamedExecCall()),
            isNot(contains('unlink-first')));
      });

      test('a restore with no source named is refused', () async {
        shell.responses['list'] = vmList([vm('ubuntu')]);

        await expectLater(
          api.importRootfs('ubuntu-cloud', archive.path),
          throwsA(isA<AppleVmException>()),
        );
        expect(shell.calls.any((c) => c.contains('export')), isFalse);
      });

      test('a source that is gone is refused, and nothing is cloned',
          () async {
        shell.responses['list'] = vmList([vm('something-else')]);

        await expectLater(
          api.importRootfs('ubuntu-cloud', archive.path,
              sourceInstance: 'ubuntu'),
          throwsA(predicate((e) => '$e'.contains('vmrootfssourcemissing-text'))),
        );
        expect(shell.calls.any((c) => c.contains('export')), isFalse);
      });

      test('a running source is refused rather than copied torn', () async {
        shell.responses['list'] = vmList([vm('ubuntu', running: true)]);

        await expectLater(
          api.importRootfs('ubuntu-cloud', archive.path,
              sourceInstance: 'ubuntu'),
          throwsA(predicate((e) => '$e'.contains('vmrootfssourcerunning-text'))),
        );
        expect(shell.calls.any((c) => c.contains('export')), isFalse);
      });

      test('an existing name is refused instead of being overwritten',
          () async {
        shell.responses['list'] =
            vmList([vm('ubuntu'), vm('ubuntu-cloud')]);

        await expectLater(
          api.importRootfs('ubuntu-cloud', archive.path,
              sourceInstance: 'ubuntu'),
          throwsA(predicate((e) => '$e'.contains('vmrootfsnametaken-text'))),
        );
        expect(shell.calls.any((c) => c.contains('export')), isFalse);
      });

      test('a clone left half-restored is deleted, not handed over', () async {
        listsCloneComingUp();
        shell.responses['exec'] = 'tar (GNU tar) 1.35';
        // The readiness probe and the tar --version pass; the restore does
        // not.
        shell.exitCodeQueue['exec'] = [0, 0, 3];
        shell.errors['exec'] = 'tar: short read';

        await expectLater(
          api.importRootfs('ubuntu-cloud', archive.path,
              sourceInstance: 'ubuntu'),
          throwsA(predicate((e) => '$e'.contains('short read'))),
        );
        final delete = shell.calls.lastWhere((c) => c.contains('delete'));
        expect(delete, containsAll(['delete', '--name', 'ubuntu-cloud']));
      });
    });
  });
}
