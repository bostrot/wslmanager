/// Tests for lib/api/distro_package.dart and the `wsl.exe` verbs P05-24 added
/// to lib/api/wsl.dart — `--install --from-file`, `--export --format`, and the
/// `/etc/wsl-distribution.conf` read/write path.
///
/// Every readiness rule below is a line of `build-custom-distro.md`, so the
/// tests name the rule rather than the widget.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/distro_package.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_distribution_conf.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

const String _distro = 'Ubuntu';

/// `wsl --version` output for a build that has `.wsl` packages.
const String _wsl263 = 'WSL version: 2.6.3.0\nKernel version: 6.6.87.2-1';

/// The last shipping build *without* them — 2.4.4 is the documented floor.
const String _wsl243 = 'WSL version: 2.4.3.0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockShell shell;
  late WSLApi api;
  late DistroPackager packager;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    shell = MockShell();
    shell.wslVersionOutput = _wsl263;
    shell.distros.add(_distro);
    api = WSLApi(shell: shell);
    packager = DistroPackager(api: api);
    tmp = Directory.systemTemp.createTempSync('wsl-package-test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the version gate (build-custom-distro.md:16)', () {
    test('2.6.3 supports .wsl packages', () async {
      expect((await api.capabilities.load()).supportsWslPackages, true);
    });

    test('2.4.3 does not — the floor is 2.4.4', () async {
      shell.wslVersionOutput = _wsl243;
      expect((await api.capabilities.load()).supportsWslPackages, false);
    });

    /// Inbox WSL rejects `--version` outright (`systemd.md:30`), so the
    /// version is unknown and the gate has to close.
    test('the inbox build does not', () async {
      shell.wslVersionOutput = '';
      shell.wslVersionExitCode = 1;
      expect((await api.capabilities.load()).supportsWslPackages, false);
    });
  });

  group('wsl --install --from-file', () {
    test('builds the documented argument order', () async {
      final result = await api.installFromFile('C:\\p\\my.wsl',
          name: 'MyDistro', location: 'C:\\WSL\\MyDistro');

      expect(result.ok, true);
      expect(shell.installCalls.single, [
        '--install',
        '--from-file',
        'C:\\p\\my.wsl',
        '--name',
        'MyDistro',
        '--location',
        'C:\\WSL\\MyDistro',
        '--no-launch',
      ]);
    });

    test('omits --name and --location when there are none', () async {
      await api.installFromFile('C:\\p\\my.wsl', noLaunch: false);

      expect(shell.installCalls.single,
          ['--install', '--from-file', 'C:\\p\\my.wsl']);
    });

    /// An empty name is not a name — appending `--name ''` makes wsl.exe
    /// register the distro under nothing at all.
    test('an empty name is dropped rather than passed through', () async {
      await api.installFromFile('C:\\p\\my.wsl', name: '  ', location: '');

      expect(shell.installCalls.single,
          ['--install', '--from-file', 'C:\\p\\my.wsl', '--no-launch']);
    });

    test('carries wsl.exe stderr back to the caller', () async {
      shell.installFromFileFailure = 'Invalid distribution file';
      final result = await api.installFromFile('C:\\p\\my.wsl');

      expect(result.ok, false);
      expect(result.text, 'Invalid distribution file');
    });

    test('the packager sends the install through the instance path', () async {
      await packager.install('C:\\p\\my.wsl', name: 'MyDistro');

      final call = shell.installCalls.single;
      expect(call.contains('--name'), true);
      expect(call[call.indexOf('--location') + 1],
          getInstancePath('MyDistro').path);
    });
  });

  group('wsl --export --format', () {
    test('appends the format when one is asked for', () async {
      await api.export(_distro, '${tmp.path}\\out.wsl', format: 'tar.gz');

      expect(shell.lastRunArguments, [
        '--export',
        _distro,
        '${tmp.path}\\out.wsl',
        '--format',
        'tar.gz',
      ]);
    });

    /// Every pre-existing caller — Save as template, the move fallback —
    /// still produces a plain tar. P05-24 must not change what they write.
    test('omits it otherwise, so existing callers are unchanged', () async {
      await api.export(_distro, '${tmp.path}\\out.tar');

      expect(shell.lastRunArguments,
          ['--export', _distro, '${tmp.path}\\out.tar']);
    });
  });

  group('packaging', () {
    test('writes a .wsl and reports its size', () async {
      final output = '${tmp.path}\\my-distro.wsl';
      final result = await packager.package(_distro, output);

      expect(result.ok, true);
      expect(result.path, output);
      expect(result.bytes, greaterThan(0));
      expect(File(output).existsSync(), true);
      expect(shell.lastRunArguments.contains('tar.gz'), true);
    });

    test('creates the parent directory', () async {
      final output = '${tmp.path}\\packages\\nested\\my-distro.wsl';
      expect((await packager.package(_distro, output)).ok, true);
      expect(File(output).existsSync(), true);
    });

    test('refuses below the documented WSL floor', () async {
      shell.wslVersionOutput = _wsl243;
      final result = await packager.package(_distro, '${tmp.path}\\a.wsl');

      expect(result.ok, false);
      // Nothing was even attempted, so no export ran.
      expect(shell.runCalls.any((c) => c.contains('--export')), false);
    });

    test('reports wsl.exe failing rather than claiming success', () async {
      shell.simulateExportFailure = true;
      final result = await packager.package(_distro, '${tmp.path}\\a.wsl');

      expect(result.ok, false);
      expect(result.error, contains('Export failed'));
    });

    test('the default file is named after the distro, under packages',
        () async {
      final path = packager.defaultPackageFile('My Distro');
      expect(path.endsWith('.wsl'), true);
      expect(path.contains('packages'), true);
      // The name is sanitised the same way every other path in the app is.
      expect(path.contains('My Distro'), false);
    });
  });

  group('/etc/wsl-distribution.conf through wsl.exe', () {
    test('a distro with no file reads as an empty config', () async {
      final conf = await api.readDistributionConf(_distro);

      expect(conf, isNotNull);
      expect(conf!.toMap(), isEmpty);
    });

    test('an unreachable distro reads as null, not as empty', () async {
      shell.simulateWslConfUnreachable = true;

      expect(await api.readDistributionConf(_distro), isNull);
      // …and the update path must therefore refuse to write, or a distro that
      // would not start gets its config replaced by the one key that was
      // touched.
      expect(
          await api.setDistributionSetting(_distro, 'oobe', 'defaultName', 'x'),
          false);
      expect(shell.distributionConfContents, isNull);
    });

    test('a write round-trips through the file', () async {
      expect(
          await api.setDistributionSetting(
              _distro, 'oobe', 'defaultName', 'my-distro'),
          true);

      final conf = await api.readDistributionConf(_distro);
      expect(conf!.get('oobe', 'defaultName'), 'my-distro');
    });

    /// The payload is base64, so nothing in a value can be interpreted by the
    /// shell it travels through — the fix that made `wsl.conf` CC-2/CC-7 one
    /// change rather than three.
    test('a value with quotes and \$(…) survives the shell', () async {
      const nasty =
          r'''/etc/oobe.sh "a" 'b' `id` $(whoami) /mnt/c/Program Files''';
      await api.setDistributionSetting(_distro, 'oobe', 'command', nasty);

      final conf = await api.readDistributionConf(_distro);
      expect(conf!.get('oobe', 'command'), nasty);
    });

    test('the file is chmodded 0644 as the docs require', () async {
      await api.setDistributionSetting(_distro, 'shortcut', 'enabled', 'false');

      expect(
          shell.chmodCalls.any((c) =>
              c.contains('0644') && c.contains(kWslDistributionConfPath)),
          true);
    });

    test('removing a key deletes its line', () async {
      await api.setDistributionSetting(_distro, 'shortcut', 'enabled', 'false');
      await api.setDistributionSetting(_distro, 'shortcut', 'icon', '/a.ico');

      expect(
          await api.removeDistributionSetting(_distro, 'shortcut', 'enabled'),
          true);
      final conf = await api.readDistributionConf(_distro);
      expect(conf!.get('shortcut', 'enabled'), isNull);
      expect(conf.get('shortcut', 'icon'), '/a.ico');
    });

    test('an untouched section survives a write to another one', () async {
      shell.distributionConfContents = '''# hand written
[oobe]
command = /etc/oobe.sh

[shortcut]
icon = /a.ico
''';
      await api.setDistributionSetting(
          _distro, 'oobe', 'defaultName', 'my-distro');

      expect(shell.distributionConfContents, '''# hand written
[oobe]
command = /etc/oobe.sh
defaultName = my-distro

[shortcut]
icon = /a.ico
''');
    });
  });

  group('the sample OOBE script', () {
    test('lands executable and points the config at it', () async {
      expect(await packager.writeSampleOobe(_distro), true);

      expect(shell.writtenDistroFiles[kDefaultOobeScriptPath],
          startsWith('#!/bin/bash'));
      expect(shell.chmodCalls.any((c) => c.contains('0755')), true);

      final conf = await api.readDistributionConf(_distro);
      expect(conf!.get('oobe', 'command'), kDefaultOobeScriptPath);
      expect(conf.get('oobe', 'defaultUid'), kDefaultOobeUid);
    });

    /// The doc pairs the account-creating script with UID 1000 in both
    /// places; the script and the config key must not be able to disagree.
    test('the UID in the script matches the one written to the config',
        () async {
      await packager.writeSampleOobe(_distro, uid: '1001');

      expect(shell.writtenDistroFiles[kDefaultOobeScriptPath],
          contains("DEFAULT_UID='1001'"));
      final conf = await api.readDistributionConf(_distro);
      expect(conf!.get('oobe', 'defaultUid'), '1001');
    });

    test('the script keeps its shell variables unexpanded by Dart', () {
      final script = sampleOobeScript();
      expect(script, contains(r'"$DEFAULT_UID"'));
      expect(script, contains(r'"$username"'));
      expect(script, isNot(contains(r'${')));
    });

    test('a read-only distro reports failure instead of claiming success',
        () async {
      shell.simulateWslConfReadOnly = true;
      expect(await packager.writeSampleOobe(_distro), false);
    });
  });

  group('readiness checks', () {
    WslDistributionConfFile conf(String text) =>
        WslDistributionConfFile.parse(text);

    const complete = DistroPackageInspection(
        hasWslConf: true, hasResolvConf: false, oobeCommandExecutable: true);

    const ready = '''[oobe]
command = /etc/oobe.sh
defaultUid = 1000
defaultName = my-distro
''';

    test('a complete distro has nothing to report', () {
      expect(packageIssues(conf(ready), complete), isEmpty);
    });

    /// `:191` — the double-click install path needs oobe.defaultName.
    test('a missing defaultName is an error', () {
      final issues = packageIssues(
          conf('[oobe]\ncommand = /etc/oobe.sh\ndefaultUid = 1000\n'),
          complete);

      expect(issues.first.messageKey, 'packagenodefaultname-text');
      expect(issues.first.isError, true);
    });

    test('an empty defaultName counts as missing', () {
      final issues =
          packageIssues(conf('[oobe]\ndefaultName =   \n'), complete);
      expect(
          issues.any((i) => i.messageKey == 'packagenodefaultname-text'), true);
    });

    /// "If that command returns non zero … the user won't be able to open a
    /// shell" — a non-executable command is exactly that, every time.
    test('a non-executable oobe command is an error', () {
      final issues = packageIssues(
          conf(ready),
          const DistroPackageInspection(
              hasWslConf: true, oobeCommandExecutable: false));

      final issue = issues
          .firstWhere((i) => i.messageKey == 'packageoobenotexecutable-text');
      expect(issue.isError, true);
      expect(issue.args, ['/etc/oobe.sh']);
    });

    test('no oobe command at all is a warning, not an error', () {
      final issues =
          packageIssues(conf('[oobe]\ndefaultName = my-distro\n'), complete);

      final issue =
          issues.firstWhere((i) => i.messageKey == 'packagenooobe-text');
      expect(issue.isError, false);
      // …and with no command there is nothing to say about the UID.
      expect(issues.any((i) => i.messageKey == 'packagenouid-text'), false);
    });

    test('a command without a defaultUid is a warning', () {
      final issues = packageIssues(
          conf('[oobe]\ncommand = /etc/oobe.sh\ndefaultName = my-distro\n'),
          complete);

      expect(issues.any((i) => i.messageKey == 'packagenouid-text'), true);
    });

    test('a non-.ico shortcut icon is a warning', () {
      final issues = packageIssues(
          conf('$ready\n[shortcut]\nicon = /usr/lib/wsl/icon.png\n'), complete);

      expect(issues.any((i) => i.messageKey == 'packageiconformat-text'), true);
    });

    test('an .ICO in any case is accepted', () {
      final issues = packageIssues(
          conf('$ready\n[shortcut]\nicon = /usr/lib/wsl/Icon.ICO\n'), complete);

      expect(issues, isEmpty);
    });

    test('a missing /etc/wsl.conf is a warning', () {
      final issues = packageIssues(conf(ready),
          const DistroPackageInspection(oobeCommandExecutable: true));

      expect(issues.any((i) => i.messageKey == 'packagenowslconf-text'), true);
    });

    test('a shipped /etc/resolv.conf is a warning', () {
      final issues = packageIssues(
          conf(ready),
          const DistroPackageInspection(
              hasWslConf: true,
              hasResolvConf: true,
              oobeCommandExecutable: true));

      expect(issues.any((i) => i.messageKey == 'packageresolvconf-text'), true);
    });

    test('errors sort before warnings', () {
      final issues = packageIssues(
          conf('[oobe]\ncommand = /etc/oobe.sh\n'),
          const DistroPackageInspection(
              hasResolvConf: true, oobeCommandExecutable: false));

      expect(issues.first.isError, true);
      expect(issues.last.isError, false);
    });
  });

  group('inspection', () {
    test('reports which documented files the distro has', () async {
      shell.existingDistroFiles.addAll(['/etc/wsl.conf', '/etc/resolv.conf']);
      shell.executableDistroFiles.add('/etc/oobe.sh');

      final result = await packager.inspect(_distro,
          WslDistributionConfFile.parse('[oobe]\ncommand = /etc/oobe.sh\n'));

      expect(result.hasWslConf, true);
      expect(result.hasResolvConf, true);
      expect(result.oobeCommandExecutable, true);
    });

    test('does not probe an oobe command that is not configured', () async {
      final result =
          await packager.inspect(_distro, WslDistributionConfFile.empty());

      expect(result.oobeCommandExecutable, isNull);
      expect(shell.runCalls.any((c) => c.contains('test')), false);
    });

    /// The command comes out of a file the user edits, so it must reach
    /// `test -x` as argv and never as a shell script.
    test('the oobe command is passed as argv, not interpolated', () async {
      await packager.inspect(
          _distro,
          WslDistributionConfFile.parse(
              '[oobe]\ncommand = /etc/oobe.sh; rm -rf /\n'));

      final call = shell.runCalls.firstWhere((c) => c.contains('test'));
      expect(call.last, '/etc/oobe.sh; rm -rf /');
      expect(call.contains('bash'), false);
    });

    /// readDistroFileList is the one probe that builds a script out of its
    /// arguments, so it drops anything that is not a plain absolute path.
    test('the file probe refuses a path with shell metacharacters', () async {
      final found =
          await api.readDistroFileList(_distro, <String>['/etc/x; rm -rf /']);

      expect(found, isEmpty);
      expect(shell.runCommands.any((c) => c.contains('rm -rf')), false);
    });
  });
}
