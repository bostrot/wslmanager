/// Tests for the wsl.dart file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/app.dart';
import 'package:wsl2distromanager/api/remote_command.dart';
import 'package:wsl2distromanager/api/windows_terminal_launcher.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_conf.dart';
import 'package:wsl2distromanager/api/wslconfig.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/create_dialog.dart';

import 'mocks.dart';

void main() {
  late MockShell mockShell;
  late WSLApi wslApi;
  late Dio mockDio;
  late List<String> statusMessages;

  void statusMsg(
    String msg, {
    Duration? duration,
    dynamic severity = "",
    bool loading = false,
    bool useWidget = false,
    bool leadingIcon = true,
    dynamic widget,
  }) {
    statusMessages.add(msg);
  }

  // Stuff before tests
  setUpAll(() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    // Pin the distro root: these tests stage fixtures under C:\WSL2-Distros,
    // so they must not depend on the per-user default storage root
    // (%APPDATA%) that getDistroPath() otherwise falls back to.
    SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
    await initPrefs();

    Notify();
    Notify.message = statusMsg;
  });

  setUp(() {
    mockShell = MockShell();
    wslApi = WSLApi(shell: mockShell);
    mockDio = Dio();
    mockDio.httpClientAdapter = MockHttpClientAdapter();
    statusMessages = [];
  });

  test('Check update', () async {
    App app = App(dio: mockDio);
    var updateUrl = await app.checkUpdate('1.0.0');
    // Check if updateUrl contains https:// and .msix
    expect(updateUrl.contains('https://'), true);
    expect(updateUrl.contains('.msix'), true);
  });

  test('Version to double', () {
    App app = App();
    var version = app.versionToDouble('1.0.0');
    expect(version, 100.0);
  });

  test('Check motd', () async {
    App app = App(dio: mockDio);
    var motd = await app.checkMotd();
    expect(motd, isNotEmpty);
  });

  test('Get distro links', () async {
    App app = App(dio: mockDio);
    var links = await app.getDistroLinks();
    expect(links, isNotEmpty);
  });

  test('UTF16 to UTF8', () {
    var utf16 = 'Hello World';
    var bytes = utf16.codeUnits;
    var bytes2 = bytes.expand((e) => [e, 0]).toList();

    var utf8 = wslApi.utf8Convert(bytes2);
    expect(utf8, utf16);
  });

  test('utf8Convert preserves unicode characters', () {
    final text = '错误: 路径无效';
    final converted = wslApi.utf8Convert(utf8.encode(text));
    expect(converted, text);
  });

  Future<bool> isInstance(String name) async {
    bool found;
    // Get list
    var list = await wslApi.list(false);
    found = false;

    for (var item in list.all) {
      if (item == name) {
        found = true;
      }
    }
    return found;
  }

  createDistro(name, loc, image, user) async {
    await createInstance(
      TextEditingController(text: name),
      TextEditingController(text: loc),
      wslApi,
      TextEditingController(text: image),
      TextEditingController(text: user),
    );
  }

  test('Create instance test', skip: !Platform.isWindows, () async {
    // Save original state of distroRootfsLinks and restore after test to prevent test pollution
    final originalDistroRootfsLinks =
        Map<String, String>.from(distroRootfsLinks);
    addTearDown(() {
      distroRootfsLinks
        ..clear()
        ..addAll(originalDistroRootfsLinks);
    });
    // Test with download
    distroRootfsLinks['Debian'] = 'http://example.com/debian.tar.gz';

    final file = File('C:/WSL2-Distros/distros/Debian.tar.gz');
    if (!await file.exists()) {
      file.createSync(recursive: true);
    }

    // Delete the instance
    await wslApi.remove('test');
    expect(await isInstance('test'), false);

    // Test creating it
    await createDistro(
      'test',
      '',
      'Debian',
      '',
    );

    // Verify that the file exists
    expect(await file.exists(), true);
    expect(await isInstance('test'), true);

    // Delete the instance
    await wslApi.remove('test');
    expect(await isInstance('test'), false);

    // Test without download
    // Test creating it
    await createDistro(
      'test',
      '',
      'Debian',
      '',
    );

    expect(await isInstance('test'), true);
  });

  test('Create instance shows stderr on import failure', () async {
    mockShell.simulateInvalidPath = true;
    mockShell.importFailureStdout = 'cOv...NO';

    await createDistro(
      'test',
      '',
      '/tmp/non-existent-template.tar.gz',
      '',
    );

    expect(
      statusMessages.any((m) => m.contains('Invalid installation path')),
      true,
    );
    expect(statusMessages.any((m) => m.contains('cOv...NO')), false);
  });

  test('Copy instance test', skip: !Platform.isWindows, () async {
    // Setup: create 'test'
    mockShell.distros.add('test');
    File('C:/WSL2-Distros/test/ext4.vhdx').createSync(recursive: true);

    // Old copy
    await wslApi.copy('test', 'testcopy');
    expect(await isInstance('testcopy'), true);

    // New copy with vhd
    await wslApi.stop('test');
    await wslApi.copyVhd('test', 'testcopy2');

    expect(await isInstance('testcopy2'), true);

    // Delete the instance
    await wslApi.remove('test');
    await wslApi.remove('testcopy');
    await wslApi.remove('testcopy2');

    expect(await isInstance('test'), false);
    expect(await isInstance('testcopy'), false);
    expect(await isInstance('testcopy2'), false);
  });

  test('Cleanup test', skip: !Platform.isWindows, () async {
    // Create a new instance
    mockShell.distros.add('test');
    File('C:/WSL2-Distros/test/ext4.vhdx').createSync(recursive: true);

    // Cleanup
    String result = await wslApi.cleanup('test');

    // Should return success message
    expect(result, contains('Cleanup completed successfully'));

    // Still exists (cleanup re-imports it)
    expect(await isInstance('test'), true);

    // Check that export file is cleaned up (should not exist after successful cleanup)
    var exportFile = File('C:/WSL2-Distros/test/export.tar.gz');
    expect(await exportFile.exists(), false);
  });

  test('Cleanup test with nonexistent instance', () async {
    const name = 'nonexistent-instance';

    try {
      var result = await wslApi.cleanup(name);

      final lower = result.toLowerCase();
      final handled = lower.contains('not found') ||
          lower.contains('does not exist') ||
          lower.contains('no such') ||
          lower.contains('error') ||
          lower.contains('not exist');

      expect(handled, true,
          reason:
              'cleanup returned a message but it did not indicate a missing instance or an error: "$result"');
    } catch (e) {
      expect(e, isA<Exception>());
    }
  });

  test('Move distro', () async {
    mockShell.distros.add('test');
    File('C:/WSL2-Distros/test/ext4.vhdx').createSync(recursive: true);

    await wslApi.move('test', 'C:/WSL2-Distros/test-moved');

    var file = File('C:/WSL2-Distros/test-moved/ext4.vhdx');
    expect(await file.exists(), true);

    expect(await isInstance('test'), true);

    await wslApi.remove('test');
    expect(await isInstance('test'), false);

    if (await Directory('C:/WSL2-Distros/test-moved').exists()) {
      await Directory('C:/WSL2-Distros/test-moved').delete(recursive: true);
    }
  });

  test('Check if instance exists', () async {
    expect(await isInstance('test'), false);
  });

  group('Editor Settings', () {
    test('Default editor is notepad.exe', () async {
      prefs.remove('Editor');
      wslApi.editConfig();
      // Wait for async execution
      await Future.delayed(Duration.zero);

      expect(mockShell.lastStartArguments, contains('notepad.exe'));
    });

    test('Custom editor is used', () async {
      prefs.setString('Editor', 'code.exe');
      wslApi.editConfig();
      // Wait for async execution
      await Future.delayed(Duration.zero);

      expect(mockShell.lastStartArguments, contains('code.exe'));
    });

    test('Open bashrc uses custom editor', () async {
      prefs.setString('Editor', 'vim.exe');
      await wslApi.openBashrc('Ubuntu');

      expect(mockShell.lastStartArguments, contains('vim.exe'));
    });
  });

  group('Terminal Tests', () {
    test('WSL start with custom terminal', () async {
      prefs.setString('Terminal', 'custom_terminal.exe');
      wslApi.start('Ubuntu');
      // Wait for async
      await Future.delayed(const Duration(milliseconds: 100));
      expect(mockShell.lastStartExecutable, 'custom_terminal.exe');
      expect(mockShell.lastStartArguments, contains('wsl'));
      expect(mockShell.lastStartArguments, contains('-d'));
      expect(mockShell.lastStartArguments, contains('Ubuntu'));
      prefs.remove('Terminal');
    });

    test('WSL start with default terminal', () async {
      prefs.remove('Terminal');
      wslApi.start('Ubuntu');
      // Wait for async
      await Future.delayed(const Duration(milliseconds: 100));
      expect(mockShell.lastStartExecutable, 'start');
      expect(mockShell.lastStartArguments, contains('wsl'));
      expect(mockShell.lastStartArguments, contains('-d'));
      expect(mockShell.lastStartArguments, contains('Ubuntu'));
    });

    // bostrot/wsl2-distro-manager#279: a start used to open whatever the
    // default profile looks like, because `wsl -d <name>` says nothing about
    // which distro's Windows Terminal profile the tab belongs to.
    group('Windows Terminal profile', () {
      /// A Windows host with Windows Terminal installed — the suite runs on
      /// neither, so both are injected.
      WSLApi onWindows() => WSLApi(
            shell: mockShell,
            terminalLauncher: const WindowsTerminalLauncher(
              hostIsWindows: true,
              executablePath: r'C:\wt.exe',
            ),
          );

      setUp(() => prefs.remove('Terminal'));

      // Also on the way out, so a failed expectation cannot leave a terminal
      // or an off switch behind for the groups that follow.
      tearDown(() async {
        await prefs.remove('Terminal');
        await prefs.remove(WindowsTerminalLauncher.prefEnabled);
      });

      test('start names the instance profile', () async {
        await onWindows().start('Ubuntu');

        expect(mockShell.lastStartExecutable, 'start');
        expect(mockShell.lastStartArguments,
            ['wt', '-w', '0', 'nt', '-p', 'Ubuntu', 'wsl', '-d', 'Ubuntu']);
      });

      test('start keeps the path, the user and the start command', () async {
        await onWindows().start('Ubuntu',
            startPath: '/home/me', startUser: 'me', startCmd: 'htop');

        final args = mockShell.lastStartArguments;
        expect(args.take(6), ['wt', '-w', '0', 'nt', '-p', 'Ubuntu']);
        expect(args, containsAllInOrder(['--cd', '/home/me']));
        expect(args, containsAllInOrder(['--user', 'me']));
        // The shell that keeps the window open has to reach wsl.exe, so its
        // semicolon must not read as a second Windows Terminal command.
        expect(args.last, r'\;/bin/sh');
      });

      test('a host without Windows Terminal starts as before', () async {
        final api = WSLApi(
          shell: mockShell,
          terminalLauncher: const WindowsTerminalLauncher(
              hostIsWindows: true, executablePath: ''),
        );
        await api.start('Ubuntu');

        expect(mockShell.lastStartExecutable, 'start');
        expect(mockShell.lastStartArguments, ['wsl', '-d', 'Ubuntu']);
      });

      test('the preference turns the rewrite off', () async {
        await prefs.setBool(WindowsTerminalLauncher.prefEnabled, false);
        await onWindows().start('Ubuntu');

        expect(mockShell.lastStartArguments, ['wsl', '-d', 'Ubuntu']);
      });

      test('a Windows Terminal set by hand gains the profile', () async {
        prefs.setString('Terminal', 'wt.exe');
        await onWindows().start('Ubuntu');

        expect(mockShell.lastStartExecutable, 'wt.exe');
        expect(mockShell.lastStartArguments,
            ['-w', '0', 'nt', '-p', 'Ubuntu', 'wsl', '-d', 'Ubuntu']);
      });
    });
  });

  group('Remote WSL Tests', () {
    setUp(() {
      prefs.setBool('UseRemoteWSL', true);
      prefs.setString('RemoteWSLTarget', 'user@192.168.1.20');
    });

    tearDown(() {
      prefs.remove('UseRemoteWSL');
      prefs.remove('RemoteWSLTarget');
    });

    test('useRemoteWsl is false with a malformed target', () async {
      prefs.setString('RemoteWSLTarget', '-not-a-valid-target');
      expect(wslApi.useRemoteWsl, false);
    });

    test('useRemoteWsl is false when the toggle is off', () async {
      prefs.setBool('UseRemoteWSL', false);
      expect(wslApi.useRemoteWsl, false);
    });

    test('useRemoteWsl is true with a valid target and toggle on', () async {
      expect(wslApi.useRemoteWsl, true);
    });

    // Regression coverage for a real bug: start()/openBashrc()/startVSCode()/
    // exec()'s passwd branch launch via Windows `start`/a terminal exe with
    // 'ssh' as part of the *argument list*, not as the process executable
    // (unlike _runWsl/_startWsl, which pass 'ssh' as the executable
    // directly). They previously built their args via _buildRemoteArgs alone
    // — which only returns ssh's own options, never the literal 'ssh' token —
    // so remote terminal/editor/VS Code launches silently passed SSH's
    // options (`-o`, `BatchMode=yes`, ...) as the program to run instead of
    // running ssh at all.
    test('start() prefixes remote args with the literal ssh token', skip: Platform.isMacOS, () async {
      prefs.remove('Terminal');
      wslApi.start('Ubuntu');
      await Future.delayed(const Duration(milliseconds: 100));

      expect(mockShell.lastStartExecutable, 'start');
      expect(mockShell.lastStartArguments.first, 'ssh');
      expect(mockShell.lastStartArguments, contains('user@192.168.1.20'));
      expect(mockShell.lastStartArguments, contains('wsl'));
      expect(mockShell.lastStartArguments, contains('-d'));
      expect(mockShell.lastStartArguments, contains('Ubuntu'));
    });

    test('openBashrc() prefixes remote args with the literal ssh token', skip: Platform.isMacOS,
        () async {
      await wslApi.openBashrc('Ubuntu');

      expect(mockShell.lastStartExecutable, 'start');
      expect(mockShell.lastStartArguments.first, 'ssh');
      expect(mockShell.lastStartArguments, contains('user@192.168.1.20'));
      expect(mockShell.lastStartArguments, contains('wsl'));
    });

    test('startVSCode() prefixes remote args with the literal ssh token', skip: Platform.isMacOS,
        () async {
      wslApi.startVSCode('Ubuntu');
      await Future.delayed(const Duration(milliseconds: 100));

      expect(mockShell.lastStartExecutable, 'start');
      expect(mockShell.lastStartArguments, containsAllInOrder(['/b', 'ssh']));
      expect(mockShell.lastStartArguments, contains('user@192.168.1.20'));
      expect(mockShell.lastStartArguments, contains('code'));
    });

    test('exec() passwd branch prefixes remote args with the literal ssh token', skip: Platform.isMacOS,
        () async {
      await wslApi.exec('Ubuntu', ['passwd']);

      expect(mockShell.lastStartExecutable, 'start');
      // `start`'s own switches come first — an empty console title and
      // `/wait`, which is what makes the password prompt awaited at all
      // (audit CI-13) — and the literal `ssh` token still leads the command.
      expect(mockShell.lastStartArguments,
          containsAllInOrder(['', '/wait', 'ssh']));
      expect(mockShell.lastStartArguments, contains('user@192.168.1.20'));
    });

    test('stop() routes through ssh as the process executable, not the arg list',
        () async {
      await wslApi.stop('Ubuntu');

      // _runWsl passes 'ssh' as the executable itself (correct pattern —
      // contrast with the start()/openBashrc()/etc. cases above, which
      // launch through a different executable and need 'ssh' inlined into
      // the argument list instead).
      expect(mockShell.lastRunExecutable, 'ssh');
      expect(mockShell.lastRunArguments, contains('user@192.168.1.20'));
      // Plain tokens cross the wire bare. The POSIX-quoted `'--terminate'`
      // they used to be is a parse error on a host whose OpenSSH login shell
      // is PowerShell — the default on most configured Windows machines —
      // which is why no remote command worked from the Mac
      // (bostrot/ai-tasks#21).
      expect(mockShell.lastRunArguments, contains('--terminate'));
      expect(mockShell.lastRunArguments, contains('Ubuntu'));
      expect(mockShell.lastRunArguments, isNot(contains("'--terminate'")));
    });

    test(
        'a remote command with spaces and metacharacters crosses the wire whole',
        () async {
      // ssh joins the remote argv with spaces and the host's login shell
      // re-splits it by its own rules — cmd.exe, PowerShell and bash all
      // differently. So a command like this travels as an encoded PowerShell
      // wrapper: only shell-neutral tokens leave this machine, and the host
      // runs exactly the argv it was given.
      await wslApi.runVerb(
          ['-d', 'Ubuntu', '--exec', 'bash', '-c', 'echo hi | tee /tmp/x']);
      final args = mockShell.runCalls.last;
      final target = args.indexOf('user@192.168.1.20');
      expect(target, greaterThan(0));
      final remote = args.sublist(target + 1);
      expect(remote.every(isShellNeutralToken), isTrue,
          reason: remote.join(' '));
      expect(remote, contains('-EncodedCommand'));
      expect(decodeRemoteCommand(remote), [
        'wsl',
        '-d',
        'Ubuntu',
        '--exec',
        'bash',
        '-c',
        'echo hi | tee /tmp/x',
      ]);
    });

    test('a remote in-distro script still reaches the mock shell', () async {
      // The test shell unwraps the encoded command, so the existing
      // `bash -c` simulations keep answering for remote targets too.
      mockShell.defaultUserHome = '/home/remote';
      expect(await wslApi.getDefaultUserHome('Ubuntu'), '/home/remote');
    });

    test('remoteInstallPath builds a path under the shared remote root',
        () async {
      expect(wslApi.remoteInstallPath('Ubuntu'),
          r'C:\wsl2dm\instances\Ubuntu');
    });

    // Regression coverage for a real gap: the remote move() branch used to
    // skip every safety net the local branch has (same-path check,
    // minimum-export-size check, recovery markers) — a bad/truncated
    // remote export could get the source distro deleted before anyone
    // noticed. Both checks below must reject *before* remove() runs.
    test('move() remote rejects a no-op move to the same path', () async {
      mockShell.distros.add('Ubuntu');
      prefs.setString('Path_Ubuntu', r'C:\wsl2dm\instances\Ubuntu');

      await expectLater(
        () => wslApi.move('Ubuntu', r'C:\wsl2dm\instances\Ubuntu'),
        throwsA(predicate((e) =>
            e.toString().contains('must be different from current path'))),
      );
      // The distro must still be registered — remove() was never reached.
      expect(mockShell.distros, contains('Ubuntu'));
      prefs.remove('Path_Ubuntu');
    });

    test('move() remote rejects a too-small export and never removes the distro',
        () async {
      mockShell.distros.add('Ubuntu');
      mockShell.remoteFileSizeBytes = 512; // well under the 1MB safety floor

      await expectLater(
        () => wslApi.move('Ubuntu', r'C:\wsl2dm\instances\UbuntuMoved'),
        throwsA(predicate(
            (e) => e.toString().contains('Export failed or file too small'))),
      );
      expect(mockShell.distros, contains('Ubuntu'));
      expect(prefs.getString('MoveOp_Distro'), isNull);
    });
  });

  test('WSL getWSLConf parses correctly', () async {
    // Mock execCmdAsRoot to return sample config
    mockShell.execCmdAsRootResponse = '''
[automount]
enabled = true
options = "metadata,uid=1000,gid=1000,umask=022,fmask=11,case=off"
mountFsTab = true

[network]
generateHosts = true
hostname = MyHost

[boot]
systemd = true
''';

    var config = await wslApi.getWSLConf('Ubuntu');

    expect(config['automount']!['enabled'], 'true');
    expect(config['automount']!['mountFsTab'], 'true');
    expect(config['automount']!['options'],
        '"metadata,uid=1000,gid=1000,umask=022,fmask=11,case=off"');
    expect(config['network']!['generateHosts'], 'true');
    expect(config['network']!['hostname'], 'MyHost');
    expect(config['boot']!['systemd'], 'true');
  });

  /// The `/etc/wsl.conf` writer, end to end through the shell layer. The
  /// per-key behaviour lives in test/wsl_conf_test.dart; what is pinned here
  /// is the command WSLApi builds and the failure it reports.
  group('wsl.conf read/write', () {
    test('setSetting writes only the key it was given', () async {
      mockShell.wslConfContents =
          '# hand written\n[automount]\nenabled = true\n\n[interop]\nenabled = true\n';

      expect(await wslApi.setSetting('Ubuntu', 'interop', 'enabled', 'false'),
          true);

      // Audit CC-1: the old `sed` rewrote both `enabled` lines at once.
      expect(mockShell.wslConfContents,
          '# hand written\n[automount]\nenabled = true\n\n[interop]\nenabled = false\n');
    });

    test('a value full of shell metacharacters round-trips verbatim', () async {
      // Audit CC-2 / CC-7: `/` broke the sed delimiter and `"`, backticks and
      // `$(…)` ran as root inside the distro.
      const value = r'/usr/sbin/service docker start && echo "$(id)" `x`';
      mockShell.wslConfContents = '';

      expect(await wslApi.setSetting('Ubuntu', 'boot', 'command', value), true);
      expect((await wslApi.getWSLConf('Ubuntu'))['boot']!['command'], value);
    });

    test('a value with spaces and "=" survives', () async {
      mockShell.wslConfContents = '';
      await wslApi.setSetting(
          'Ubuntu', 'automount', 'options', 'metadata,uid=1000,gid=1000');
      await wslApi.setSetting('Ubuntu', 'boot', 'command', 'echo a = b');

      final config = await wslApi.getWSLConf('Ubuntu');
      expect(config['automount']!['options'], 'metadata,uid=1000,gid=1000');
      expect(config['boot']!['command'], 'echo a = b');
    });

    /// The four keys P05-03 added, with the values they will actually be
    /// given rather than a placeholder — `[user] default` is the one CC-6 is
    /// about, and the other three are booleans whose section is their only
    /// distinguishing feature (`enabled` belongs to two of them).
    test('the keys this phase added take their real values', () async {
      mockShell.wslConfContents = '';

      expect(await wslApi.setSetting('Ubuntu', 'user', 'default', 'ada.love'),
          true);
      await wslApi.setSetting('Ubuntu', 'boot', 'protectBinfmt', 'false');
      await wslApi.setSetting('Ubuntu', 'gpu', 'enabled', 'true');
      await wslApi.setSetting('Ubuntu', 'time', 'useWindowsTimezone', 'false');
      await wslApi.setSetting('Ubuntu', 'interop', 'enabled', 'false');

      final config = await wslApi.getWSLConf('Ubuntu');
      expect(config['user']!['default'], 'ada.love');
      expect(config['boot']!['protectBinfmt'], 'false');
      expect(config['gpu']!['enabled'], 'true');
      expect(config['time']!['useWindowsTimezone'], 'false');
      // Two sections, two keys spelled `enabled`, and neither may answer for
      // the other.
      expect(config['interop']!['enabled'], 'false');
    });

    test('a non-ASCII value survives the base64 payload', () async {
      // The content goes in base64-encoded UTF-8 and comes back out through
      // utf8Convert; a byte-oriented step anywhere in that chain shows up
      // here before it shows up in a bug report.
      mockShell.wslConfContents = '';
      const value = "echo 'Grüße, 世界'";

      await wslApi.setSetting('Ubuntu', 'boot', 'command', value);
      expect((await wslApi.getWSLConf('Ubuntu'))['boot']!['command'], value);
    });

    test('a # inside a value is a value, not a comment', () async {
      mockShell.wslConfContents = '';
      const value = 'echo "#1 distro" > /tmp/motd';

      await wslApi.setSetting('Ubuntu', 'boot', 'command', value);
      expect((await wslApi.getWSLConf('Ubuntu'))['boot']!['command'], value);
    });

    test('a backslash in a wsl.conf value is not escaped', () async {
      // The two files share one model but not one dialect: `.wslconfig`
      // doubles backslashes because WSL's parser reads them as escapes (R-6),
      // and `/etc/wsl.conf` takes the rest of the line verbatim. A value that
      // came back doubled here would be a real path with a wrong name in it.
      mockShell.wslConfContents = '';
      const value = r'/mnt/c/Program\ Files/tool/run.sh';

      await wslApi.setSetting('Ubuntu', 'boot', 'command', value);
      expect(mockShell.wslConfContents, contains('command = $value'));
      expect((await wslApi.getWSLConf('Ubuntu'))['boot']!['command'], value);
    });

    test('every documented key round-trips through the writer', () async {
      mockShell.wslConfContents = '';

      for (final section in kWslConfKeys.entries) {
        for (final key in section.value) {
          expect(await wslApi.setSetting('Ubuntu', section.key, key, 'v-$key'),
              true);
        }
      }

      final config = await wslApi.getWSLConf('Ubuntu');
      for (final section in kWslConfKeys.entries) {
        for (final key in section.value) {
          expect(config[section.key]?[key], 'v-$key',
              reason: '[${section.key}] $key did not survive');
        }
      }
    });

    test('the writer never puts a double quote in the command', () async {
      // runInShell is false, so a `"` reaches bash literally — see
      // lib/api/wsl_args.dart.
      mockShell.wslConfContents = '';
      await wslApi.setSetting('Ubuntu', 'network', 'hostname', 'my"host');

      // runCalls, not lastRunArguments: the write goes through
      // ExecutionBroker, which spawns via Shell.start so it can reap the
      // child. The assertion is about the argv, not about the channel.
      final write = mockShell.runCalls.last;
      expect(write.last, isNot(contains('"')));
      expect(write, containsAllInOrder(['-d', 'Ubuntu']));
      expect(write, containsAllInOrder(['-u', 'root']));
      expect(mockShell.lastRunInShell, false);
      expect((await wslApi.getWSLConf('Ubuntu'))['network']!['hostname'],
          'my"host');
    });

    test('removeSetting deletes the line, leaving the rest', () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\ncommand = echo hi\n';

      expect(await wslApi.removeSetting('Ubuntu', 'boot', 'systemd'), true);
      expect(mockShell.wslConfContents, '[boot]\ncommand = echo hi\n');
    });

    test('removing a key that is not there does not rewrite the file',
        () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';
      mockShell.simulateWslConfReadOnly = true;

      // No write is attempted, so the read-only filesystem never comes up.
      expect(await wslApi.removeSetting('Ubuntu', 'boot', 'command'), true);
      expect(mockShell.wslConfContents, '[boot]\nsystemd = true\n');
    });

    test('a read-only /etc/wsl.conf reports failure', () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';
      mockShell.simulateWslConfReadOnly = true;

      // The old writer returned true unconditionally with showOutput: false,
      // so a failed write still showed as applied (audit CC-2).
      expect(
          await wslApi.setSetting('Ubuntu', 'boot', 'systemd', 'false'), false);
      expect(mockShell.wslConfContents, '[boot]\nsystemd = true\n');
    });

    test('an unreachable distro is never overwritten', () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';
      mockShell.simulateWslConfUnreachable = true;

      expect(
          await wslApi.setSetting('Ubuntu', 'network', 'hostname', 'x'), false);
      expect(await wslApi.getWSLConf('Ubuntu'), isEmpty);
      expect(mockShell.wslConfContents, '[boot]\nsystemd = true\n');
    });

    test('a distro with no wsl.conf gets one created', () async {
      mockShell.wslConfContents = null;

      expect(
          await wslApi.setSetting('Ubuntu', 'user', 'default', 'tester'), true);
      expect(mockShell.wslConfContents, '[user]\ndefault = tester\n');
    });

    /// The dialog writes per key, not on a Save button, so two edits made a
    /// second apart overlap. Each one is a whole-file read, mutate and write
    /// back; without serialisation the second read predates the first write
    /// and the second write puts back a file the first key was never in.
    ///
    /// Found by running it: a `[network] hostname` typed 1.2s before a
    /// `generateHosts` toggle never reached the real distro's `/etc/wsl.conf`,
    /// and nor did `[boot] protectBinfmt` set next to `[boot] command`. Both
    /// calls returned true — neither of them failed.
    test('concurrent key writes do not overwrite each other', () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';

      final results = await Future.wait(<Future<bool>>[
        wslApi.setSetting('Ubuntu', 'network', 'hostname', 'wdm-test-host'),
        wslApi.setSetting('Ubuntu', 'network', 'generateHosts', 'false'),
        wslApi.setSetting('Ubuntu', 'boot', 'protectBinfmt', 'false'),
      ]);

      expect(results, everyElement(true));
      final config = await wslApi.getWSLConf('Ubuntu');
      expect(config['network']!['hostname'], 'wdm-test-host');
      expect(config['network']!['generateHosts'], 'false');
      expect(config['boot']!['protectBinfmt'], 'false');
      expect(config['boot']!['systemd'], 'true');
    });

    test('a removal racing a write keeps both outcomes', () async {
      mockShell.wslConfContents =
          '[boot]\nsystemd = true\nprotectBinfmt = false\n';

      final results = await Future.wait(<Future<bool>>[
        wslApi.removeSetting('Ubuntu', 'boot', 'protectBinfmt'),
        wslApi.setSetting('Ubuntu', 'user', 'default', 'tester'),
      ]);

      expect(results, everyElement(true));
      final config = await wslApi.getWSLConf('Ubuntu');
      expect(config['boot']!.containsKey('protectBinfmt'), false);
      expect(config['user']!['default'], 'tester');
      expect(config['boot']!['systemd'], 'true');
    });

    /// One distro refusing its write must not wedge the queue for the next
    /// one: the serialiser's tail swallows the error rather than chaining it.
    test('a failed write does not poison later writes to the same distro',
        () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';
      mockShell.simulateWslConfReadOnly = true;

      expect(await wslApi.setSetting('Ubuntu', 'user', 'default', 'tester'),
          false);

      mockShell.simulateWslConfReadOnly = false;
      expect(await wslApi.setSetting('Ubuntu', 'user', 'default', 'tester'),
          true);
      expect((await wslApi.getWSLConf('Ubuntu'))['user']!['default'], 'tester');
    });

    test('wsl-distribution.conf writes are serialised too', () async {
      mockShell.distributionConfContents = '[oobe]\ndefaultName = Demo\n';

      final results = await Future.wait(<Future<bool>>[
        wslApi.setDistributionSetting('Ubuntu', 'oobe', 'defaultUid', '1000'),
        wslApi.setDistributionSetting(
            'Ubuntu', 'shortcut', 'icon', r'C:\icons\demo.ico'),
      ]);

      expect(results, everyElement(true));
      final conf = await wslApi.readDistributionConf('Ubuntu');
      expect(conf!.get('oobe', 'defaultName'), 'Demo');
      expect(conf.get('oobe', 'defaultUid'), '1000');
      expect(conf.get('shortcut', 'icon'), r'C:\icons\demo.ico');
    });
  });

  test('Move distro fails if export is too small', () async {
    mockShell.distros.add('test-small');
    mockShell.simulateSmallExport = true;
    File('C:/WSL2-Distros/test/ext4.vhdx').createSync(recursive: true);

    // Keep DistroPath pinned across this reset — the fixtures live under
    // C:\WSL2-Distros, not the per-user default storage root.
    SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
    prefs = await SharedPreferences.getInstance();

    try {
      await wslApi.move('test-small', 'C:/WSL2-Distros/test-moved-small');
      fail('Should have thrown exception');
    } catch (e) {
      expect(e.toString(), contains('Export failed or file too small'));
    }

    // Verify markers are NOT set (failed before setting them)
    expect(prefs.getString('MoveOp_Distro'), null);
    expect(prefs.getString('MoveOp_BackupPath'), null);
  });

  test('Move distro sets recovery markers on failure during remove', () async {
    mockShell.distros.add('test-fail-remove');
    mockShell.simulateRemoveFailure = true;
    File('C:/WSL2-Distros/test/ext4.vhdx').createSync(recursive: true);

    // Keep DistroPath pinned across this reset — the fixtures live under
    // C:\WSL2-Distros, not the per-user default storage root.
    SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
    prefs = await SharedPreferences.getInstance();

    try {
      await wslApi.move('test-fail-remove', 'C:/WSL2-Distros/test-moved-fail');
      fail('Should have thrown exception');
    } catch (e) {
      // Expected failure from remove
    }

    // Verify markers ARE set (failed after setting them but before clearing)
    expect(prefs.getString('MoveOp_Distro'), 'test-fail-remove');
    expect(prefs.getString('MoveOp_BackupPath'), contains('export.ext4'));
  });

  test('Move distro clears recovery markers on success', () async {
    mockShell.distros.add('test-success');
    File('C:/WSL2-Distros/test/ext4.vhdx').createSync(recursive: true);

    // Keep DistroPath pinned across this reset — the fixtures live under
    // C:\WSL2-Distros, not the per-user default storage root.
    SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
    prefs = await SharedPreferences.getInstance();

    // Manually set markers to ensure they get cleared
    await prefs.setString('MoveOp_Distro', 'test-success');
    await prefs.setString('MoveOp_BackupPath', 'dummy/path');

    await wslApi.move('test-success', 'C:/WSL2-Distros/test-moved-success');

    // Verify markers are CLEARED
    expect(prefs.getString('MoveOp_Distro'), null);
    expect(prefs.getString('MoveOp_BackupPath'), null);
  });

  test('startVSCode uses preference if set', () async {
    SharedPreferences.setMockInitialValues({'VSCodeCmd': 'custom-code'});
    prefs = await SharedPreferences.getInstance();

    wslApi.startVSCode('Ubuntu');

    // Wait for async execution (startVSCode is async void)
    await Future.delayed(const Duration(milliseconds: 10));

    expect(mockShell.lastStartArguments, contains('custom-code'));
  });

  test('startVSCode defaults to code if not set', () async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();

    wslApi.startVSCode('Ubuntu');
    await Future.delayed(const Duration(milliseconds: 10));

    expect(mockShell.lastStartArguments, contains('code'));
  });

  group('Issue regressions', () {
    setUp(() async {
      // Earlier tests in this file reset the mock prefs, which drops the
      // pinned distro root that these fixtures live under.
      SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
      prefs = await SharedPreferences.getInstance();
    });

    test('remove() drops every preference keyed by the distro name', () async {
      mockShell.distros.add('stale');
      for (final prefix in distroPrefKeyPrefixes) {
        await prefs.setString('$prefix' 'stale', 'x');
      }

      await wslApi.remove('stale');

      for (final prefix in distroPrefKeyPrefixes) {
        expect(prefs.get('$prefix' 'stale'), isNull,
            reason: '$prefix should have been cleared');
      }
    });

    test('cleanup() finds the disk when the stored path is stale', skip: !Platform.isWindows, () async {
      mockShell.distros.add('moved');
      File('C:/WSL2-Distros/moved/ext4.vhdx').createSync(recursive: true);
      await prefs.setString('Path_moved', r'C:\gone\moved');

      final result = await wslApi.cleanup('moved');

      expect(result, contains('Cleanup completed successfully'));
      // The stale entry is corrected to where the disk actually is.
      expect(prefs.getString('Path_moved'), contains('moved'));
      expect(prefs.getString('Path_moved'), isNot(contains('gone')));
    });

    test('cleanup() lists the paths it tried when nothing is found', () async {
      mockShell.distros.add('missing-disk');
      await prefs.setString('Path_missing-disk', r'C:\nowhere');

      await expectLater(
        wslApi.cleanup('missing-disk'),
        throwsA(predicate((e) => e.toString().contains('nowhere'))),
      );
    });

    test('startVSCode() opens the default user home when no path is stored',
        () async {
      await wslApi.startVSCode('Ubuntu');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(mockShell.lastStartArguments, contains('/home/tester'));
    });

    test('startVSCode() still honours an explicit path', () async {
      await wslApi.startVSCode('Ubuntu', path: '/srv/project');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(mockShell.lastStartArguments, contains('/srv/project'));
      expect(mockShell.lastStartArguments, isNot(contains('/home/tester')));
    });
  });

  // Regression guard for the `bash: -c: line 2: syntax error near unexpected
  // token` class of failure: wsl.exe re-joins its argv and re-parses it
  // through the distro's default shell unless `--exec` is present, so a
  // pre-split command loses its quoting on the way in.
  // See lib/api/wsl_args.dart.
  group('in-distro invocations go through wsl_args', () {
    test('execCmdAsRoot hands the whole command to bash -c behind --exec',
        () async {
      await wslApi.execCmdAsRoot('Ubuntu', "echo 'hello world' > /tmp/out");

      expect(mockShell.lastRunExecutable, 'wsl');
      expect(mockShell.lastRunArguments, [
        '-d',
        'Ubuntu',
        '-u',
        'root',
        '--exec',
        'bash',
        '-c',
        "echo 'hello world' > /tmp/out",
      ]);
    });

    test('execCmdAsRoot does not pre-split the command into argv', () async {
      await wslApi.execCmdAsRoot('Ubuntu', 'ls -la /etc');

      // The old form appended splitShellArgs() to the argument list, which
      // stripped quotes and left the re-parse to do the rest.
      expect(mockShell.lastRunArguments, isNot(contains('-la')));
      expect(mockShell.lastRunArguments.last, 'ls -la /etc');
    });

    test('execCmdAsRoot does not run through cmd.exe', () async {
      // runInShell: true would let cmd.exe eat &, |, <, > and ^ before
      // wsl.exe ever saw them.
      await wslApi.execCmdAsRoot('Ubuntu', 'cat /proc/net/tcp');
      expect(mockShell.lastRunInShell, isFalse);
    });

    test('exec() keeps a quoted redirection intact', () async {
      const cmd =
          "echo 'tester ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/wslsudo";
      await wslApi.exec('Ubuntu', [cmd]);

      expect(mockShell.lastRunArguments,
          ['-d', 'Ubuntu', '--exec', 'bash', '-c', cmd]);
      // The bare `(` that the old split left behind is what the distro's
      // shell choked on.
      expect(mockShell.lastRunArguments, isNot(contains('ALL=(ALL)')));
    });

    test('getDefaultUser execs whoami rather than letting a shell see it',
        () async {
      await wslApi.getDefaultUser('Ubuntu');
      expect(mockShell.lastRunArguments, ['-d', 'Ubuntu', '--exec', 'whoami']);
    });

    test('getDefaultUserHome passes the HOME echo through sh -c', () async {
      await wslApi.getDefaultUserHome('Ubuntu');
      expect(mockShell.lastRunArguments,
          ['-d', 'Ubuntu', '--exec', 'sh', '-c', r'echo $HOME']);
    });

    test('start() keeps the default-shell re-parse it depends on', () async {
      // The trailing `;/bin/sh` only becomes a second command because the
      // distro's shell re-parses the flattened argv — this one call site must
      // NOT gain --exec.
      wslApi.start('Ubuntu', startCmd: 'htop');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(mockShell.lastStartArguments, contains(';/bin/sh'));
      expect(mockShell.lastStartArguments, isNot(contains('--exec')));
    });
  });

  /// P05-08, P05-16, P05-23 — wsl.exe verbs the audit found missing entirely
  /// (doc/audit/wsl-docs/cli-flags.md CC-1, CC-2).
  ///
  /// Every assertion here is about the **argument list**, because that is what
  /// those findings are about: `--manage` takes the distro before the option,
  /// and nothing may be assembled as a pre-quoted string — `runInShell: false`
  /// passes a `"` straight through to bash (AGENTS.md).
  group('wsl.exe verbs', () {
    test('--version and --status are asked, and answered', () async {
      mockShell.wslVersionOutput =
          'WSL version: 2.6.3.0\nKernel version: 6.6.87.2-1\n';
      mockShell.wslStatusOutput =
          'Default Distribution: Ubuntu\nDefault Version: 2\n';

      final capabilities = await wslApi.capabilities.load();
      expect(capabilities.version, '2.6.3.0');
      expect(capabilities.supportsManage, true);
      expect(capabilities.defaultDistro, 'Ubuntu');
      expect(mockShell.runCalls, contains(equals(['--version'])));
      expect(mockShell.runCalls, contains(equals(['--status'])));
    });

    test('--manage puts the distro before the option', () async {
      await wslApi.manageResize('Ubuntu', '256GB');
      expect(mockShell.manageCalls.single,
          ['--manage', 'Ubuntu', '--resize', '256GB']);
    });

    test('--set-sparse writes a bare true/false, never a quoted one', () async {
      await wslApi.manageSetSparse('Ubuntu', true);
      expect(mockShell.manageCalls.single,
          ['--manage', 'Ubuntu', '--set-sparse', 'true']);

      await wslApi.manageSetSparse('Ubuntu', false);
      expect(mockShell.manageCalls.last,
          ['--manage', 'Ubuntu', '--set-sparse', 'false']);

      for (final call in mockShell.manageCalls) {
        expect(call.any((arg) => arg.contains('"')), false);
      }
    });

    test('--set-default-user passes the name as one argument', () async {
      await wslApi.manageSetDefaultUser('Ubuntu', 'ada lovelace');
      expect(mockShell.manageCalls.single,
          ['--manage', 'Ubuntu', '--set-default-user', 'ada lovelace']);
    });

    test('--update takes --web-download only when asked', () async {
      await wslApi.updateWsl();
      expect(mockShell.updateCalls.single, ['--update']);

      await wslApi.updateWsl(webDownload: true);
      expect(mockShell.updateCalls.last, ['--update', '--web-download']);
    });

    test('--update hands back what wsl.exe said', () async {
      final result = await wslApi.updateWsl();
      expect(result.ok, true);
      expect(result.text, contains('already installed'));
    });

    test('diskUsage asks the system distro the documented question', () async {
      mockShell.dfOutput =
          'Filesystem     1K-blocks     Used Available Use% Mounted on\n'
          '/dev/sdd        104857600  1048576 103809024   1% /mnt/wslg/distro\n';

      final usage = await wslApi.diskUsage('Ubuntu');
      expect(mockShell.runCalls.last,
          ['--system', '-d', 'Ubuntu', 'df', '-k', '/mnt/wslg/distro']);
      expect(usage!.usedBytes, 1048576 * 1024);
      expect(usage.totalBytes, 104857600 * 1024);
    });

    test('a distro that cannot answer df yields null, not zeroes', () async {
      mockShell.dfOutput = '';
      expect(await wslApi.diskUsage('Ubuntu'), isNull);
    });
  });

  /// P05-15. #280 is the one finding in this audit with a report of real data
  /// loss behind it: the old move exports to a tar, **unregisters** the distro
  /// and imports it back, and the reporter's distro vanished inside that
  /// window. `--manage --move` has no such window.
  group('move prefers the native verb (P05-15)', () {
    setUp(() {
      mockShell.wslVersionOutput = 'WSL version: 2.6.3.0\n';
    });

    test('on WSL 2.5+ it issues one --manage --move and never unregisters',
        () async {
      mockShell.distros.add('nativemove');
      File('C:/WSL2-Distros/nativemove/ext4.vhdx').createSync(recursive: true);

      await wslApi.move('nativemove', 'C:/WSL2-Distros/nativemove-target');

      expect(mockShell.manageCalls.single, [
        '--manage',
        'nativemove',
        '--move',
        'C:/WSL2-Distros/nativemove-target',
      ]);
      // The destructive path's three steps, none of which ran.
      expect(
          mockShell.runCalls.any((call) => call.contains('--export')), false);
      expect(mockShell.runCalls.any((call) => call.contains('--unregister')),
          false);
      expect(
          mockShell.runCalls.any((call) => call.contains('--import')), false);
      expect(mockShell.distros, contains('nativemove'));
      expect(prefs.getString('Path_nativemove'),
          'C:/WSL2-Distros/nativemove-target');

      await Directory('C:/WSL2-Distros/nativemove-target')
          .delete(recursive: true);
    });

    test('the distro is terminated first, because a running one holds the VHD',
        () async {
      mockShell.distros.add('nativemove2');
      await wslApi.move('nativemove2', 'C:/WSL2-Distros/nativemove2-target');

      final terminate =
          mockShell.runCalls.indexWhere((c) => c.contains('--terminate'));
      final move = mockShell.runCalls.indexWhere((c) => c.contains('--move'));
      expect(terminate, greaterThanOrEqualTo(0));
      expect(move, greaterThan(terminate));

      await Directory('C:/WSL2-Distros/nativemove2-target')
          .delete(recursive: true);
    });

    test('supportsNativeMove reflects the installed build', () async {
      expect(await wslApi.supportsNativeMove(), true);

      final inbox = WSLApi(shell: MockShell()..wslVersionExitCode = 1);
      expect(await inbox.supportsNativeMove(), false);
    });

    test('a failed native move never falls back to the destructive path',
        () async {
      // Retrying a recoverable failure with export → unregister → import is
      // how a recoverable error becomes an unrecoverable one.
      mockShell.distros.add('failmove');
      mockShell.manageFailure = 'The system cannot find the path specified.';

      await expectLater(
          () => wslApi.move('failmove', 'C:/WSL2-Distros/failmove-target'),
          throwsA(
              predicate((e) => e.toString().contains('cannot find the path'))));

      expect(mockShell.distros, contains('failmove'));
      expect(mockShell.runCalls.any((call) => call.contains('--unregister')),
          false);
      expect(prefs.getString('MoveOp_Distro'), isNull);
    });

    test('a no-op move is refused before anything runs', () async {
      mockShell.distros.add('samepath');
      await expectLater(
          () => wslApi.move('samepath', getInstancePath('samepath').path),
          throwsA(
              predicate((e) => e.toString().contains('must be different'))));
      expect(mockShell.manageCalls, isEmpty);
    });

    test('an empty target is refused rather than resolved to the cwd',
        () async {
      // p.canonicalize('') is the process's working directory, which is not
      // where anyone means to put a distro.
      mockShell.distros.add('notarget');
      await expectLater(() => wslApi.move('notarget', '   '),
          throwsA(predicate((e) => e.toString().contains('no target path'))));
      expect(mockShell.manageCalls, isEmpty);
    });
  });

  /// P05-02 at the API boundary. The model is covered end to end in
  /// test/wslconfig_test.dart; these two pin the routing decisions `saveSettings`
  /// depends on. Nothing here touches the real `%UserProfile%\.wslconfig`.
  group('.wslconfig section routing (P05-02)', () {
    test('an experimental key is written to [experimental], never [wsl2]',
        () async {
      // Runtime R-4: all seven are *rejected* under [wsl2] and the setting is
      // silently off, with only a stderr line to say so.
      final config = WslConfigFile.parse('[wsl2]\nmemory = 8GB\n');
      config.set(config.sectionFor('sparseVhd'), 'sparseVhd', 'true');

      expect(config.get('experimental', 'sparseVhd'), 'true');
      expect(config.get('wsl2', 'sparseVhd'), isNull);
      expect(config.serialize(), startsWith('[wsl2]\nmemory = 8GB\n'));
    });

    test('an unreachable remote host reads as null, never as an empty file',
        () async {
      // The difference readWSLConf already draws for wsl.conf: an *unreadable*
      // config must not come back as an *empty* one, or the next Save replaces
      // the remote host's whole configuration with the one key the user
      // touched.
      SharedPreferences.setMockInitialValues({
        'DistroPath': defaultPath,
        'UseRemoteWSL': true,
        'RemoteWSLTarget': 'user@host',
      });
      prefs = await SharedPreferences.getInstance();
      addTearDown(() async {
        SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
        prefs = await SharedPreferences.getInstance();
      });

      final unreachable = WSLApi(shell: MockShell()..sshFails = true);
      expect(await unreachable.readWslConfig(), isNull);
      expect(await unreachable.readConfig(), isEmpty);
      expect(
          await unreachable
              .updateWslConfig((c) => c.set('wsl2', 'memory', '1GB')),
          false);
    });

    test('readConfig flattens only the sections the app knows', () async {
      final config = WslConfigFile.parse(
          '[wsl2]\nmemory = 8GB\n\n[experimental]\nsparseVhd = true\n'
          '\n[future]\nsomething = 1\n');
      expect(config.flatten(), {'memory': '8GB', 'sparseVhd': 'true'});
    });
  });

  /// The same read → mutate → write → read round trip test/wslconfig_test.dart
  /// makes against the model, but through [WSLApi] — so the transport is in
  /// the loop as well as the parser.
  ///
  /// The remote target is the only `.wslconfig` transport a test can own: the
  /// local one resolves through `%USERPROFILE%`, which a test process cannot
  /// move, and a suite that writes the developer's own `.wslconfig` is not a
  /// suite anyone can run twice. It is also the transport with quoting in it —
  /// the whole file crosses the wire inside a PowerShell single-quoted string
  /// literal — which is the half [WslConfigFile] cannot be asked about.
  group('.wslconfig round trips through the API (P05-02)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'DistroPath': defaultPath,
        'UseRemoteWSL': true,
        'RemoteWSLTarget': 'user@host',
      });
      prefs = await SharedPreferences.getInstance();
      mockShell.remoteWslConfigContents = '';
    });

    tearDown(() async {
      SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
      prefs = await SharedPreferences.getInstance();
    });

    test('every documented key round-trips, in the section WSL reads it from',
        () async {
      for (final section in kWslConfigKeys.entries) {
        for (final key in section.value) {
          expect(await wslApi.setConfig(key, 'v-$key'), true,
              reason: '$key could not be written');
        }
      }

      final config = await wslApi.readWslConfig();
      for (final section in kWslConfigKeys.entries) {
        for (final key in section.value) {
          expect(config!.get(section.key, key), 'v-$key',
              reason: '[${section.key}] $key did not survive');
          // R-4: an `[experimental]` key filed under `[wsl2]` is rejected and
          // the setting stays off, with only a stderr line to say so.
          final wrong = section.key == 'wsl2' ? 'experimental' : 'wsl2';
          expect(config.get(wrong, key), isNull,
              reason: '$key was also written to [$wrong]');
        }
      }
      expect((await wslApi.readConfig()).length,
          kWslConfigWsl2Keys.length + kWslConfigExperimentalKeys.length);
    });

    test('the unusual values the widgets can produce are written as typed',
        () async {
      // Every one of these is a value P05-01/P05-09/P05-11 made reachable and
      // the old writer mangled or refused: a byte count too large for the
      // slider, an explicit `0`, and the two enumerations.
      const values = <String, String>{
        'memory': '8589934592',
        'swap': '0',
        'processors': '64',
        'defaultVhdSize': '1099511627776',
        'vmIdleTimeout': '60000',
        'networkingMode': 'mirrored',
        'autoMemoryReclaim': 'dropCache',
        'kernelCommandLine':
            'cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1',
      };

      for (final entry in values.entries) {
        await wslApi.setConfig(entry.key, entry.value);
      }

      final config = await wslApi.readConfig();
      for (final entry in values.entries) {
        expect(config[entry.key], entry.value,
            reason: '${entry.key} was not written as typed');
      }
      // `0` is a value, not an absence: it is how the docs say to turn swap
      // off, and an empty string would remove the key instead.
      expect(mockShell.remoteWslConfigContents, contains('swap = 0'));
    });

    test('a picked Windows path crosses the wire escaped exactly once',
        () async {
      // R-6: a single backslash is `wsl: Ungültiges Escapezeichen` and the
      // line is discarded, so every path the file picker produced used to be
      // a dead line.
      const picked = r'C:\Program Files\WSL\my kernel';
      expect(await wslApi.setConfig('kernel', picked), true);

      expect(mockShell.remoteWslConfigContents,
          contains(r'kernel = C:\\Program Files\\WSL\\my kernel'));
      expect((await wslApi.readConfig())['kernel'], picked,
          reason: 'the user must see the path they picked, not the escaping');

      // Saving again must not escape what is already escaped.
      await wslApi.setConfig('kernel', picked);
      expect(mockShell.remoteWslConfigContents,
          contains(r'kernel = C:\\Program Files\\WSL\\my kernel'));
    });

    test('a single quote is escaped for PowerShell, not passed through',
        () async {
      const value = "init='/bin/sh -c id'";
      expect(await wslApi.setConfig('kernelCommandLine', value), true);

      // Unescaped, the quote closes the string literal the file is being
      // carried in and the remainder is parsed as PowerShell code. The script
      // crosses the wire base64-encoded (remote_command.dart), so look inside.
      expect(decodePowerShellScript(mockShell.runCalls.last.last),
          contains("init=''/bin/sh -c id''"));
      expect((await wslApi.readConfig())['kernelCommandLine'], value);
    });

    test('a hand-edited file keeps its comments, spelling and line endings',
        () async {
      const original = '# tuned by hand\r\n'
          '[wsl2]\r\n'
          'memory = 4GB\r\n'
          'swapfile = C:\\\\Temp\\\\wsl.vhdx\r\n'
          '\r\n'
          '[experimental]\r\n'
          'sparseVhd = true\r\n';
      mockShell.remoteWslConfigContents = original;

      expect(await wslApi.setConfig('memory', '8GB'), true);

      // Only the edited line moves: the comment stays, the lower-case
      // `swapfile` keeps its spelling rather than being appended a second
      // time under the documented one (R-8), `[experimental]` stays where it
      // is (R-4), and a Windows file stays CRLF.
      expect(mockShell.remoteWslConfigContents,
          original.replaceFirst('memory = 4GB', 'memory = 8GB'));

      final config = await wslApi.readConfig();
      expect(config['swapFile'], r'C:\Temp\wsl.vhdx');
      expect(config['sparseVhd'], 'true');
    });

    test('a commented-out key does not absorb the write', () async {
      // CC-5: the old writer's regex was unanchored, so `#memory=8GB` took
      // the write and stayed commented out — the setting silently did
      // nothing, on that boot and every later one.
      mockShell.remoteWslConfigContents = '[wsl2]\n#memory = 4GB\n';

      expect(await wslApi.setConfig('memory', '8GB'), true);

      expect(mockShell.remoteWslConfigContents, contains('#memory = 4GB'));
      expect(mockShell.remoteWslConfigContents, contains('memory = 8GB'));
      expect((await wslApi.readConfig())['memory'], '8GB');
    });

    test('removeConfig deletes the line so the documented default applies',
        () async {
      mockShell.remoteWslConfigContents =
          '[wsl2]\nmemory = 4GB\nguiApplications = false\n';

      expect(await wslApi.removeConfig('guiApplications'), true);

      expect(mockShell.remoteWslConfigContents, '[wsl2]\nmemory = 4GB\n');
      expect((await wslApi.readConfig()).containsKey('guiApplications'), false,
          reason: 'absent and false are different answers to the toggle');
    });

    test('a failed write is reported, not assumed', () async {
      mockShell.remoteWslConfigContents = '[wsl2]\nmemory = 4GB\n';
      mockShell.remoteWslConfigWriteFails = true;

      expect(await wslApi.setConfig('memory', '8GB'), false);
      expect(mockShell.remoteWslConfigContents, '[wsl2]\nmemory = 4GB\n');
    });
  });

  /// The in-distro file plumbing P05-24 generalised out of `readWSLConf` /
  /// `writeWSLConf`, plus the `/etc/wsl-distribution.conf` round trip built on
  /// top of it (doc/audit/wsl-docs/features.md F-8).
  group('in-distro file read/write (P05-24)', () {
    test('every documented wsl-distribution.conf key round-trips', () async {
      mockShell.distributionConfContents = '';

      const values = <String, Map<String, String>>{
        'oobe': {
          'command': '/etc/oobe.sh',
          'defaultUid': '1000',
          'defaultName': 'my-distro',
        },
        'shortcut': {'enabled': 'true', 'icon': '/usr/lib/wsl/my-icon.ico'},
        'windowsterminal': {
          'enabled': 'false',
          'profileTemplate': '/usr/lib/wsl/terminal-profile.json',
        },
      };

      for (final section in values.entries) {
        for (final pair in section.value.entries) {
          expect(
              await wslApi.setDistributionSetting(
                  'Ubuntu', section.key, pair.key, pair.value),
              true,
              reason: '[${section.key}] ${pair.key} failed to write');
        }
      }

      final conf = await wslApi.readDistributionConf('Ubuntu');
      for (final section in values.entries) {
        for (final pair in section.value.entries) {
          expect(conf!.get(section.key, pair.key), pair.value,
              reason: '[${section.key}] ${pair.key} did not survive');
        }
      }
    });

    test('a value with spaces and "=" survives', () async {
      mockShell.distributionConfContents = '';
      await wslApi.setDistributionSetting(
          'Ubuntu', 'oobe', 'command', '/etc/oobe.sh --uid=1000 --name=a b');

      final conf = await wslApi.readDistributionConf('Ubuntu');
      expect(
          conf!.get('oobe', 'command'), '/etc/oobe.sh --uid=1000 --name=a b');
    });

    test('writeDistroFile carries an arbitrary path and chmods it', () async {
      expect(
          await wslApi.writeDistroFile(
              'Ubuntu', '/usr/lib/wsl/profile.json', '{"profiles": []}',
              mode: '0644'),
          true);

      expect(mockShell.writtenDistroFiles['/usr/lib/wsl/profile.json'],
          '{"profiles": []}');
      expect(mockShell.chmodCalls.single,
          containsAllInOrder(['chmod', '0644', '/usr/lib/wsl/profile.json']));
    });

    test('a failed chmod is a failed write, not a silent one', () async {
      mockShell.simulateWslConfReadOnly = true;
      expect(
          await wslApi.writeDistroFile('Ubuntu', '/etc/oobe.sh', '#!/bin/sh\n',
              mode: '0755'),
          false);
    });

    test('readDistroFile reports an unreachable distro as null', () async {
      mockShell.simulateWslConfUnreachable = true;
      expect(await wslApi.readDistroFile('Ubuntu', '/etc/os-release'), isNull);
    });

    /// `wsl.conf` and `wsl-distribution.conf` are separate files and a write
    /// to one must not touch the other — they share a writer now.
    test('the two config files stay separate', () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';
      mockShell.distributionConfContents = '[oobe]\ndefaultName = a\n';

      await wslApi.setDistributionSetting('Ubuntu', 'oobe', 'defaultName', 'b');

      expect(mockShell.wslConfContents, '[boot]\nsystemd = true\n');
      expect(mockShell.distributionConfContents, '[oobe]\ndefaultName = b\n');
    });
  });

  /// Phase 05, "wire the new settings into the API layer": every command the
  /// phase added must go through [ExecutionBroker] with a timeout, must not
  /// put a `"` anywhere in its argv, and must resolve a disk through
  /// [findVhdxPath] rather than the stale `Path_` preference.
  group('the new API surface is brokered, quoted and path-resolved', () {
    test('a verb spawns through Shell.start, never Process.run', () async {
      // Not a style preference. `Process.run` hands back no handle, so the
      // only thing a timeout around it can do is stop waiting — the child
      // goes on holding whatever it holds. The broker spawns through
      // `Shell.start` precisely so it can reap.
      await wslApi.versionInfo();

      expect(mockShell.lastStartExecutable, 'wsl');
      expect(mockShell.lastStartArguments, ['--version']);
      expect(mockShell.lastRunExecutable, '',
          reason: 'the run channel must not have been used at all');
    });

    test('in-distro reads and writes are brokered too', () async {
      mockShell.wslConfContents = '';
      await wslApi.setSetting('Ubuntu', 'boot', 'systemd', 'true');

      expect(mockShell.lastStartExecutable, 'wsl');
      expect(mockShell.lastRunExecutable, '');
    });

    test('every verb carries a timeout sized to its work', () async {
      // Read off the broker's own audit log, so this pins what was actually
      // requested rather than what the call site looks like.
      Future<Duration> lastTimeout(Future<void> Function() call) async {
        final before = wslApi.executionBroker.auditLog.length;
        await call();
        // Otherwise a call that never reached the broker reads the *previous*
        // entry's timeout, and two verbs that happen to share a number make
        // an unbrokered one look bounded.
        expect(wslApi.executionBroker.auditLog.length, before + 1,
            reason: 'the call did not go through the broker at all');
        return wslApi.executionBroker.auditLog.last.request.timeout;
      }

      const target = 'C:/WSL2-Distros/timeoutprobe';
      addTearDown(() async {
        final dir = Directory(target);
        if (dir.existsSync()) await dir.delete(recursive: true);
      });

      expect(await lastTimeout(() => wslApi.versionInfo()),
          const Duration(seconds: 20));
      expect(await lastTimeout(() => wslApi.statusInfo()),
          const Duration(seconds: 20));
      expect(await lastTimeout(() => wslApi.manageMove('Ubuntu', target)),
          const Duration(minutes: 30));
      expect(await lastTimeout(() => wslApi.updateWsl()),
          const Duration(minutes: 20));
      expect(await lastTimeout(() => wslApi.installFromFile('C:/a.wsl')),
          const Duration(minutes: 60));
      expect(await lastTimeout(() => wslApi.diskUsage('Ubuntu')),
          const Duration(seconds: 30));
      expect(
          await lastTimeout(
              () => wslApi.readDistroFile('Ubuntu', '/etc/os-release')),
          const Duration(seconds: 60));

      // The other three `--manage` options are the same half-hour of work as
      // the move: each of them copies or rewrites the whole VHD.
      expect(await lastTimeout(() => wslApi.manageResize('Ubuntu', '256GB')),
          const Duration(minutes: 30));
      expect(await lastTimeout(() => wslApi.manageSetSparse('Ubuntu', true)),
          const Duration(minutes: 30));
      expect(
          await lastTimeout(
              () => wslApi.manageSetDefaultUser('Ubuntu', 'ada')),
          const Duration(minutes: 30));

      // The in-distro primitives are all sized for a distro that has to cold
      // start to answer, not for the few hundred bytes they move.
      mockShell.wslConfContents = '';
      expect(
          await lastTimeout(() =>
              wslApi.writeDistroFile('Ubuntu', '/etc/wsl.conf', '[boot]\n')),
          const Duration(seconds: 60));
      expect(
          await lastTimeout(
              () => wslApi.isExecutableInDistro('Ubuntu', '/etc/oobe.sh')),
          const Duration(seconds: 60));
      expect(
          await lastTimeout(() =>
              wslApi.readDistroFileList('Ubuntu', const ['/etc/wsl.conf'])),
          const Duration(seconds: 60));

      // A verb that names no timeout still carries one: the point of routing
      // everything through the broker is that nothing can wait forever.
      expect(await lastTimeout(() => wslApi.runVerb(['--list', '--quiet'])),
          const Duration(minutes: 5));
    });

    test('a wedged verb is killed, not abandoned', () async {
      final hung = ControlledProcess();
      final testShell = TestShell()..processFactory = () => hung;
      final api = WSLApi(shell: testShell);

      final result =
          await api.runVerb(['--manage', 'Ubuntu', '--move', 'C:/target'],
              timeout: const Duration(milliseconds: 50));

      expect(result.ok, false);
      expect(result.stderr, contains('timed out'));
      expect(hung.killCount, greaterThanOrEqualTo(1),
          reason: 'the child must be reaped, not left running');
    });

    test('no new command puts a double quote in its argv', () async {
      // runInShell is false, so a `"` is not a quote to anything downstream —
      // it reaches bash literally (lib/api/wsl_args.dart).
      mockShell.distributionConfContents = '';

      await wslApi.setDistributionSetting(
          'Ubuntu', 'windowsterminal', 'profileTemplate', '/usr/lib/a"b.json');
      await wslApi.writeDistroFile('Ubuntu', '/etc/oobe.sh', 'echo "hi"\n',
          mode: '0755');
      await wslApi.installFromFile('C:/My Distros/a.wsl', name: 'my distro');
      await wslApi.manageResize('Ubuntu', '2TB');
      await wslApi.readDistroFileList(
          'Ubuntu', const ['/etc/wsl.conf', '/etc/resolv.conf']);

      for (final call in mockShell.runCalls) {
        for (final argument in call) {
          expect(argument, isNot(contains('"')),
              reason: 'a double quote reached bash in: ${call.join(' ')}');
        }
      }
    });

    test('a name with a double quote is refused, not registered', () async {
      // The name is argv to wsl.exe, but start() launches a terminal through
      // cmd.exe on purpose, and a quote in the name makes that command line
      // unparseable — the distro would install and then never open.
      final result =
          await wslApi.installFromFile('C:/a.wsl', name: 'my"distro');

      expect(result.ok, false);
      expect(result.text, contains('double quote'));
      expect(mockShell.installCalls, isEmpty);
    });

    test('a path that is not a plain path is refused, not interpolated',
        () async {
      // `> $path` has to be shell syntax for the redirection to happen at
      // all, which is the one half the base64 payload cannot cover.
      mockShell.wslConfContents = '';
      final before = mockShell.runCalls.length;

      expect(
          await wslApi.writeDistroFile(
              'Ubuntu', '/etc/wsl.conf; rm -rf /', 'x'),
          false);
      expect(await wslApi.readDistroFile('Ubuntu', '/etc/\$(id).conf'), isNull);
      expect(await wslApi.readDistroFile('Ubuntu', 'etc/wsl.conf'), isNull,
          reason: 'a relative path is not an absolute one');

      expect(mockShell.runCalls.length, before,
          reason: 'nothing may run for a refused path');
    });

    test('a plain path is still accepted', () async {
      mockShell.wslConfContents = '';
      expect(
          await wslApi.writeDistroFile(
              'Ubuntu', '/usr/lib/wsl/my-icon.ico', 'x'),
          true);
    });

    /// Stage [name]'s disk where the app's own default puts it, while the
    /// stored `Path_` preference points somewhere it is not — a distro moved
    /// by anything other than this app, or a config restored onto a machine
    /// with a different layout.
    void stageStaleDistro(String name, {int? bytes}) {
      final vhdx = File('C:/WSL2-Distros/$name/ext4.vhdx')
        ..createSync(recursive: true);
      if (bytes != null) {
        final handle = vhdx.openSync(mode: FileMode.write);
        handle.truncateSync(bytes);
        handle.closeSync();
      }
      prefs.setString('Path_$name', 'C:/WSL2-Distros/$name-gone');
      addTearDown(() async {
        await prefs.remove('Path_$name');
        for (final path in ['C:/WSL2-Distros/$name', 'C:/WSL2-Distros/$name-gone']) {
          final dir = Directory(path);
          if (dir.existsSync()) await dir.delete(recursive: true);
        }
      });
    }

    test('currentDistroPath resolves the disk, not the stale preference', skip: !Platform.isWindows,
        () async {
      stageStaleDistro('stalepref');

      final resolved = wslApi.currentDistroPath('stalepref');
      expect(File('$resolved/ext4.vhdx').existsSync(), true,
          reason: 'the answer must be where the disk actually is');
      expect(resolved.toLowerCase(), isNot(contains('-gone')));
    });

    test('vhdxSizeBytes measures the resolved disk', skip: !Platform.isWindows, () async {
      // 3 MB clears move()'s 1 MB floor without asking the build machine for
      // real disk; the assertion is on the exact length either way.
      const size = 3 * 1024 * 1024;
      stageStaleDistro('sizedpref', bytes: size);

      expect(wslApi.vhdxSizeBytes('sizedpref'), size);
      expect(wslApi.vhdxSizeBytes('no-such-distro-anywhere'), 0);
    });
  });
}
