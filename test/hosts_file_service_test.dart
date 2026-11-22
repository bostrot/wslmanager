/// Tests for lib/api/hosts_file_service.dart — the managed block that gives
/// a running instance a name in the host's hosts file
/// (bostrot/ai-tasks#90, bostrot/wsl2-distro-manager#214).
///
/// The file itself is the thing to be careful with: it belongs to the user
/// and to whatever else writes it, so most of what is pinned here is what
/// survives a sync rather than what one adds.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/hosts_file_service.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_provisioning_backend.dart';

/// Stands in for the elevation round trip: records what was launched and
/// reads back the file the service staged for the elevated copy, which only
/// exists while the "elevated" command is running.
class FakeElevationShell implements Shell {
  FakeElevationShell({this.exitCode = 0, this.stderr = '', this.hostsPath});

  final int exitCode;
  final String stderr;

  /// Where a successful "elevated" run copies the staged file, the way the
  /// real batch and `cp` do. Null makes the copy fail silently, which is
  /// what an elevation that never ran looks like from here.
  final String? hostsPath;

  final List<String> executables = [];
  final List<List<String>> arguments = [];
  String? stagedContent;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments_, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async {
    executables.add(executable);
    arguments.add(arguments_);
    final staged = File('${Directory.systemTemp.path}'
        '${Platform.pathSeparator}wslm_hosts.txt');
    if (staged.existsSync()) stagedContent = staged.readAsStringSync();
    final target = hostsPath;
    if (exitCode == 0 && target != null && stagedContent != null) {
      File(target).writeAsStringSync(stagedContent!);
    }
    return ProcessResult(0, exitCode, '', stderr);
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async =>
      throw UnimplementedError();
}

VmCommandOutput probeAnswer(String hostname, String addresses) =>
    VmCommandOutput(0, '$hostname\n__WSLM__\n$addresses\n', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Writing the hosts file is a Windows/macOS affair; a Linux checkout runs
  /// everything except the write itself.
  final elevates = Platform.isWindows || Platform.isMacOS;
  const elevationOnly =
      'the hosts file is only written on Windows and macOS hosts';

  setUp(() async {
    SharedPreferences.setMockInitialValues({'HostsFileSuffix': 'wsl'});
    prefs = await SharedPreferences.getInstance();
  });

  const entry = HostsEntry(
      instance: 'Ubuntu', ip: '172.24.128.2', hostname: 'ubuntu.wsl');

  group('applyBlock', () {
    test('appends the block and keeps every line that was there', () {
      const original = '127.0.0.1\tlocalhost\n::1\tlocalhost\n';
      final result = HostsFileService.applyBlock(original, [entry]);

      expect(result, startsWith('127.0.0.1\tlocalhost\n::1\tlocalhost\n'));
      expect(result, contains(HostsFileService.blockBegin));
      expect(result, contains('172.24.128.2\tubuntu.wsl\t# Ubuntu'));
      expect(result, endsWith('${HostsFileService.blockEnd}\n'));
    });

    test('keeps the file\'s own line endings, and only one CR per line', () {
      const original = '127.0.0.1\tlocalhost\r\n::1\tlocalhost\r\n';
      final result = HostsFileService.applyBlock(original, [entry]);

      expect(result, isNot(contains('\r\r')),
          reason: 'the last preserved line used to keep a CR of its own');
      for (final line in result.split('\r\n')) {
        expect(line, isNot(contains('\r')));
        expect(line, isNot(contains('\n')),
            reason: 'a CRLF hosts file must not come back half LF');
      }
      expect(
          result,
          '127.0.0.1\tlocalhost\r\n::1\tlocalhost\r\n\r\n'
          '${HostsFileService.blockBegin}\r\n'
          '172.24.128.2\tubuntu.wsl\t# Ubuntu\r\n'
          '${HostsFileService.blockEnd}\r\n');
    });

    test('a CRLF file is stable across a second sync too', () {
      const original = '127.0.0.1\tlocalhost\r\n';
      final once = HostsFileService.applyBlock(original, [entry]);
      expect(HostsFileService.applyBlock(once, [entry]), once);
      expect(HostsFileService.applyBlock(once, const []), original);
    });

    test('replaces the previous block instead of stacking a second one', () {
      final once = HostsFileService.applyBlock('127.0.0.1\tlocalhost\n', [
        const HostsEntry(
            instance: 'Ubuntu', ip: '10.0.0.1', hostname: 'ubuntu.wsl'),
      ]);
      final twice = HostsFileService.applyBlock(once, [entry]);

      expect(HostsFileService.blockBegin.allMatches(twice).length, 1);
      expect(twice, contains('172.24.128.2'));
      expect(twice, isNot(contains('10.0.0.1')));
      expect(twice, contains('127.0.0.1\tlocalhost'));
    });

    test('takes the block back out when there is nothing to write', () {
      final once =
          HostsFileService.applyBlock('127.0.0.1\tlocalhost\n', [entry]);
      final cleared = HostsFileService.applyBlock(once, const []);

      expect(cleared, '127.0.0.1\tlocalhost\n');
    });

    test('a marker left without its end takes only its own line', () {
      // A half-written file, or a hand edit that deleted the end marker.
      // Dropping everything after it would delete entries this app never
      // wrote.
      final orphaned = '127.0.0.1\tlocalhost\n'
          '${HostsFileService.blockBegin}\n'
          '10.0.0.9\tsomething.else\n';
      final result = HostsFileService.applyBlock(orphaned, const []);

      expect(result, contains('127.0.0.1\tlocalhost'));
      expect(result, contains('10.0.0.9\tsomething.else'));
      expect(result, isNot(contains(HostsFileService.blockBegin)));
    });

    test('is stable: syncing the same entries twice changes nothing', () {
      final once =
          HostsFileService.applyBlock('127.0.0.1\tlocalhost\n', [entry]);
      expect(HostsFileService.applyBlock(once, [entry]), once);
    });
  });

  group('reading what a guest answered', () {
    test('picks the first address a host can actually reach', () {
      expect(
          HostsFileService.ipv4From('127.0.0.1 172.24.128.2'), '172.24.128.2');
      expect(
          HostsFileService.ipv4From('169.254.10.4 192.168.1.5'), '192.168.1.5');
    });

    test('refuses a group of digits that is not an address', () {
      expect(HostsFileService.ipv4From('999.1.1.1'), isNull);
      expect(HostsFileService.ipv4From('no addresses here'), isNull);
      expect(HostsFileService.ipv4From(''), isNull);
    });

    test('splits the guest hostname from its addresses', () {
      final probe =
          HostsFileService.parseProbe('alpine\n__WSLM__\n 10.1.2.3 \n');
      expect(probe.hostname, 'alpine');
      expect(probe.ip, '10.1.2.3');
    });

    test('the probe carries nothing that quoting could eat', () {
      // It crosses a `bash -c` on WSL and an ssh command line on the Apple
      // backend; a marker with a leading dash would also read as an echo
      // flag on some shells.
      expect(HostsFileService.probeCommand, isNot(contains("'")));
      expect(HostsFileService.probeCommand, isNot(contains('"')));
      expect(HostsFileService.probeMarker, isNot(startsWith('-')));
      expect(HostsFileService.probeCommand,
          contains(HostsFileService.probeMarker));
    });

    test('a guest that printed nothing reports nothing', () {
      final probe = HostsFileService.parseProbe('');
      expect(probe.hostname, isEmpty);
      expect(probe.ip, isNull);
    });
  });

  group('hostnameFor', () {
    test('prefers the name the guest calls itself', () {
      expect(
          HostsFileService.hostnameFor('Ubuntu-22.04', 'devbox', suffix: 'wsl'),
          'devbox.wsl');
    });

    test('falls back to the instance name when the guest has none', () {
      expect(
          HostsFileService.hostnameFor('Ubuntu 22.04', 'localhost',
              suffix: 'wsl'),
          'ubuntu-22.04.wsl');
      expect(HostsFileService.hostnameFor('Ubuntu', '', suffix: 'wsl'),
          'ubuntu.wsl');
    });

    test('does not append a suffix the name already carries', () {
      expect(HostsFileService.hostnameFor('x', 'ubuntu.wsl', suffix: 'wsl'),
          'ubuntu.wsl');
    });

    test('an empty suffix leaves the bare name', () {
      expect(HostsFileService.hostnameFor('Ubuntu', '', suffix: ''), 'ubuntu');
    });

    test('a name with nothing usable in it produces no entry', () {
      expect(HostsFileService.hostnameFor('___', '', suffix: 'wsl'), isEmpty);
    });

    test('sanitizeSuffix takes the dot people type and the case they use', () {
      expect(HostsFileService.sanitizeSuffix('.WSL'), 'wsl');
      expect(HostsFileService.sanitizeSuffix('my lab'), 'mylab');
      expect(HostsFileService.sanitizeSuffix(''), isEmpty);
    });
  });

  group('collect', () {
    test('one entry per instance that answered, sorted by name', () async {
      final backend = ScriptedBackend();
      backend.answers.addAll([
        probeAnswer('ubuntu', '172.24.128.2'),
        probeAnswer('alpine', '172.24.128.3'),
      ]);
      final service =
          HostsFileService(backend: backend, shell: FakeElevationShell());

      final entries = await service.collect(['Ubuntu', 'Alpine']);

      expect(entries.map((e) => e.hostname), ['alpine.wsl', 'ubuntu.wsl']);
      expect(entries.first.ip, '172.24.128.3');
      expect(entries.first.instance, 'Alpine');
      expect(backend.commands.first, HostsFileService.probeCommand);
    });

    test('an instance with no address yet is left out, not written stale',
        () async {
      final backend = ScriptedBackend();
      backend.answers.addAll([
        probeAnswer('booting', ''),
        probeAnswer('ubuntu', '172.24.128.2'),
      ]);
      final service =
          HostsFileService(backend: backend, shell: FakeElevationShell());

      final entries = await service.collect(['Booting', 'Ubuntu']);

      expect(entries.map((e) => e.instance), ['Ubuntu']);
    });

    test('a failed command is skipped rather than guessed at', () async {
      final backend = ScriptedBackend();
      backend.answers.addAll([
        const VmCommandOutput(1, '', 'not running'),
        probeAnswer('ubuntu', '172.24.128.2'),
      ]);
      final service =
          HostsFileService(backend: backend, shell: FakeElevationShell());

      final entries = await service.collect(['Gone', 'Ubuntu']);

      expect(entries.map((e) => e.instance), ['Ubuntu']);
    });

    test('two guests claiming one hostname only get one line', () async {
      final backend = ScriptedBackend();
      backend.answers.addAll([
        probeAnswer('ubuntu', '172.24.128.2'),
        probeAnswer('ubuntu', '172.24.128.9'),
      ]);
      final service =
          HostsFileService(backend: backend, shell: FakeElevationShell());

      final entries = await service.collect(['First', 'Second']);

      expect(entries, hasLength(1));
      expect(entries.single.ip, '172.24.128.2');
    });

    test('a backend that throws costs its instance, not the sync', () async {
      final backend = ScriptedBackend()..failure = StateError('no helper');
      final service =
          HostsFileService(backend: backend, shell: FakeElevationShell());

      expect(await service.collect(['Ubuntu']), isEmpty);
    });
  });

  group('apply', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('wslm_hosts_test');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    String hostsPath() => '${dir.path}${Platform.pathSeparator}hosts';

    test('stages the new file and asks for elevation once', () async {
      final file = File(hostsPath())
        ..writeAsStringSync('127.0.0.1\tlocalhost\n');
      final shell = FakeElevationShell(hostsPath: file.path);
      final service = HostsFileService(
          backend: ScriptedBackend(), shell: shell, hostsPath: file.path);

      final result = await service.apply([entry]);

      expect(result.changed, isTrue);
      expect(shell.executables.single,
          Platform.isWindows ? 'powershell' : 'osascript');
      // Both take the script as an argument of their own; PowerShell only
      // treats it as a command when `-Command` says so.
      expect(
          shell.arguments.single.first, Platform.isWindows ? '-Command' : '-e');
      expect(shell.stagedContent, contains('172.24.128.2\tubuntu.wsl'));
      expect(shell.stagedContent, contains('127.0.0.1\tlocalhost'));
      expect(file.readAsStringSync(), shell.stagedContent);
    }, skip: elevates ? null : elevationOnly);

    test('a file that already says so is not rewritten', () async {
      final wanted =
          HostsFileService.applyBlock('127.0.0.1\tlocalhost\n', [entry]);
      final file = File(hostsPath())..writeAsStringSync(wanted);
      final shell = FakeElevationShell();
      final service = HostsFileService(
          backend: ScriptedBackend(), shell: shell, hostsPath: file.path);

      final result = await service.apply([entry]);

      expect(result.changed, isFalse);
      expect(result.skipped, HostsSkip.unchanged);
      expect(shell.executables, isEmpty,
          reason: 'a no-op must never raise an elevation prompt');
    }, skip: elevates ? null : elevationOnly);

    test('a declined elevation is reported, not swallowed', () async {
      final file = File(hostsPath())
        ..writeAsStringSync('127.0.0.1\tlocalhost\n');
      final shell = FakeElevationShell(exitCode: 1, stderr: 'cancelled');
      final service = HostsFileService(
          backend: ScriptedBackend(), shell: shell, hostsPath: file.path);

      await expectLater(
          service.apply([entry]), throwsA(isA<HostsFileException>()));
    }, skip: elevates ? null : elevationOnly);

    test('an elevation that quietly did nothing is still a failure', () async {
      // The prompt was dismissed, or the copy never ran: the exit code says
      // fine, the file says otherwise, and the file is what counts.
      final file = File(hostsPath())
        ..writeAsStringSync('127.0.0.1\tlocalhost\n');
      final service = HostsFileService(
          backend: ScriptedBackend(),
          shell: FakeElevationShell(),
          hostsPath: file.path);

      await expectLater(
          service.apply([entry]), throwsA(isA<HostsFileException>()));
      expect(file.readAsStringSync(), '127.0.0.1\tlocalhost\n');
    }, skip: elevates ? null : elevationOnly);

    test('a hosts file with a byte that is not UTF-8 still syncs', () async {
      // A comment typed in the machine's old code page. Refusing to decode
      // it would take the whole feature down.
      final file = File(hostsPath())
        ..writeAsBytesSync(
            [...utf8.encode('# f'), 0xFC, ...utf8.encode('r\n')]);
      final shell = FakeElevationShell(hostsPath: file.path);
      final service = HostsFileService(
          backend: ScriptedBackend(), shell: shell, hostsPath: file.path);

      final result = await service.apply([entry]);

      expect(result.changed, isTrue);
      expect(shell.stagedContent, contains('ubuntu.wsl'));
    }, skip: elevates ? null : elevationOnly);

    test('two syncs at once do not race over the staged file', () async {
      final file = File(hostsPath())
        ..writeAsStringSync('127.0.0.1\tlocalhost\n');
      final shell = FakeElevationShell(hostsPath: file.path);
      final service = HostsFileService(
          backend: ScriptedBackend(), shell: shell, hostsPath: file.path);

      final results = await Future.wait([
        service.apply([entry]),
        service.apply([entry]),
      ]);

      // Whichever went second found the file already saying so.
      expect(results.where((r) => r.changed), hasLength(1));
      expect(shell.executables, hasLength(1));
    }, skip: elevates ? null : elevationOnly);

    test('nothing is written for a remote host', () async {
      final shell = FakeElevationShell();
      final service = HostsFileService(
          backend: RemoteScriptedBackend(),
          shell: shell,
          hostsPath: hostsPath());

      final result = await service.sync(instances: ['Ubuntu']);

      expect(result.skipped, HostsSkip.remote);
      expect(shell.executables, isEmpty);
    });
  });

  group('the elevated command', () {
    test('copies rather than moves, so the file keeps its permissions', () {
      final batch = HostsFileService.windowsBatch(
          r'C:\Temp\wslm_hosts.txt', r'C:\Windows\System32\drivers\etc\hosts');

      expect(batch, contains('copy /y'));
      expect(batch, isNot(contains('move')));
      expect(batch, contains('ipconfig /flushdns'));
    });

    test('a dismissed Windows prompt cannot report success', () {
      final script =
          HostsFileService.windowsElevationScript(r'C:\Temp\wslm_hosts.bat');

      // Without this, Start-Process only writes an error, $p stays null and
      // `exit $p.ExitCode` exits zero.
      expect(script, contains(r"$ErrorActionPreference = 'Stop'"));
      expect(script, contains('-Verb RunAs'));
      expect(script, contains(r'exit $p.ExitCode'));
    });

    test('drops the resolver cache on macOS too', () {
      final command =
          HostsFileService.macosCommand('/tmp/wslm_hosts.txt', '/etc/hosts');

      expect(command, startsWith('/bin/cp '));
      expect(command, contains('dscacheutil -flushcache'));
    });

    test('the AppleScript keeps the command quoted as one string', () {
      final script =
          HostsFileService.osascriptScript('/tmp/wslm_hosts.txt', '/etc/hosts');

      expect(script, startsWith('do shell script "'));
      expect(script, endsWith('" with administrator privileges'));
      expect(script, isNot(contains('\n')));
    });
  });
}

/// A backend driving another machine: its instances' addresses mean nothing
/// in this machine's hosts file.
class RemoteScriptedBackend extends ScriptedBackend {
  @override
  bool get isRemote => true;

  @override
  String get remoteLabel => 'windows-box';
}
