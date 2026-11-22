/// Tests for lib/api/volume_mounts.dart — host folders mounted inside an
/// instance on either backend (bostrot/ai-tasks#79).
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/volume_mounts.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_vmctl_shell.dart';
import 'mocks.dart';

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('guest path rules', () {
    test('accept plain absolute paths', () {
      expect(validateGuestMountPath('/mnt/project'), isNull);
      expect(validateGuestMountPath('/home/dev/src-2.0_x'), isNull);
      expect(validateGuestMountPath('/usr/local/share/project'), isNull);
      expect(validateGuestMountPath('  /work  '), isNull);
    });

    test('refuse relative, dotted, odd and system paths', () {
      expect(validateGuestMountPath(''), 'mountsguestrequired-text');
      expect(validateGuestMountPath('mnt/project'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/mnt/project/'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/mnt//project'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/mnt/../etc'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/mnt/./x'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/mnt/has space'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath("/mnt/it's"), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/etc'), 'mountsguestinvalid-text');
      expect(validateGuestMountPath('/usr'), 'mountsguestinvalid-text');
    });

    test('a macOS guest\'s share is accepted where vmctl reports it', () {
      expect(validateGuestMountPath('/Volumes/My Shared Files/proj'), isNull);
      expect(validateGuestMountPath('/Volumes/My Shared Files/'),
          'mountsguestinvalid-text');
      expect(validateGuestMountPath('/Volumes/My Shared Files/a/b'),
          'mountsguestinvalid-text');
      expect(validateGuestMountPath('/Volumes/My Shared Files/.hidden'),
          'mountsguestinvalid-text');
      expect(validateGuestMountPath('/Volumes/Other Place/x'),
          'mountsguestinvalid-text');
    });
  });

  group('host path rules', () {
    test('windows hosts take drive paths, posix hosts take slashes', () {
      expect(validateHostMountPath(r'C:\Users\eric\proj', windowsStyle: true),
          isNull);
      expect(validateHostMountPath('D:/data', windowsStyle: true), isNull);
      expect(validateHostMountPath('/Users/eric/proj', windowsStyle: false),
          isNull);
      expect(validateHostMountPath('/Users/eric/proj', windowsStyle: true),
          'mountshostinvalid-text');
      expect(validateHostMountPath(r'C:\proj', windowsStyle: false),
          'mountshostinvalid-text');
      expect(validateHostMountPath('proj', windowsStyle: true),
          'mountshostinvalid-text');
      expect(validateHostMountPath('', windowsStyle: true),
          'mountshostrequired-text');
    });

    test('quotes never reach the mount command', () {
      expect(validateHostMountPath("C:\\it's", windowsStyle: true),
          'mountshostinvalid-text');
      expect(validateHostMountPath('/Users/"x"', windowsStyle: false),
          'mountshostinvalid-text');
    });
  });

  test('a guest path is suggested from the folder name', () {
    expect(suggestGuestMountPath(r'C:\Users\eric\My Project'), '/mnt/My-Project');
    expect(suggestGuestMountPath('/Users/eric/proj/'), '/mnt/proj');
    expect(suggestGuestMountPath(r'D:\'), '/mnt/D');
    expect(suggestGuestMountPath('/Users/eric/.hidden'), '/mnt/hidden');
    expect(suggestGuestMountPath(''), '/mnt/share');
    expect(suggestGuestMountPath('/Users/eric/proj', guestRoot: '/Volumes/My Shared Files'),
        '/Volumes/My Shared Files/proj');
  });

  group('fstab block', () {
    const existing = '# /etc/fstab\nLABEL=cloudimg-rootfs / ext4 defaults 0 1\n';

    test('is appended after the rest of the file and read back', () {
      final rendered = FstabMountBlock.render(
          existing, ['C:/proj /mnt/proj drvfs defaults 0 0']);
      expect(
          rendered,
          '# /etc/fstab\nLABEL=cloudimg-rootfs / ext4 defaults 0 1\n'
          '${FstabMountBlock.begin}\n'
          'C:/proj /mnt/proj drvfs defaults 0 0\n'
          '${FstabMountBlock.end}\n');
      expect(FstabMountBlock.lines(rendered),
          ['C:/proj /mnt/proj drvfs defaults 0 0']);
    });

    test('replaces an earlier block and leaves the user lines alone', () {
      final first = FstabMountBlock.render(existing, ['a /mnt/a drvfs defaults 0 0']);
      final withUserLine = '$first//server/share /mnt/nas cifs defaults 0 0\n';
      final second = FstabMountBlock.render(withUserLine, ['b /mnt/b drvfs defaults 0 0']);
      expect(second, contains('LABEL=cloudimg-rootfs / ext4 defaults 0 1\n'));
      expect(second, contains('//server/share /mnt/nas cifs defaults 0 0\n'));
      expect(second, isNot(contains('a /mnt/a')));
      expect(FstabMountBlock.lines(second), ['b /mnt/b drvfs defaults 0 0']);
      // Only one pair of markers, however often it is rewritten.
      expect(FstabMountBlock.begin.allMatches(second).length, 1);
      expect(FstabMountBlock.end.allMatches(second).length, 1);
    });

    test('a block with no end marker takes only its drvfs lines', () {
      const broken = 'LABEL=x / ext4 defaults 0 1\n'
          '${FstabMountBlock.begin}\n'
          'C:/a /mnt/a drvfs defaults 0 0\n'
          '//srv/share /mnt/nas cifs defaults 0 0\n';
      final rendered = FstabMountBlock.render(broken, ['C:/b /mnt/b drvfs defaults 0 0']);
      expect(rendered, contains('LABEL=x / ext4 defaults 0 1\n'));
      expect(rendered, contains('//srv/share /mnt/nas cifs defaults 0 0\n'));
      expect(rendered, isNot(contains('C:/a /mnt/a')));
      expect(FstabMountBlock.lines(rendered), ['C:/b /mnt/b drvfs defaults 0 0']);
    });

    test('an empty list removes the block entirely', () {
      final first = FstabMountBlock.render(existing, ['a /mnt/a drvfs defaults 0 0']);
      expect(FstabMountBlock.render(first, []), existing);
      expect(FstabMountBlock.render('', []), '');
      expect(FstabMountBlock.lines(existing), isEmpty);
    });

    test('whitespace in a field is escaped the way mount reads it', () {
      expect(FstabMountBlock.encodeField('C:/My Project'), r'C:/My\040Project');
      expect(FstabMountBlock.decodeField(r'C:/My\040Project'), 'C:/My Project');
      expect(FstabMountBlock.decodeField(r'a\011b'), 'a\tb');
      // A backslash is an escape character to mount, so it is escaped too.
      expect(FstabMountBlock.encodeField(r'a\b'), r'a\134b');
      expect(FstabMountBlock.decodeField(r'a\134b'), r'a\b');
    });
  });

  group('WSL driver', () {
    late MockShell shell;
    late WSLApi api;
    late VolumeMountService service;

    setUp(() {
      shell = MockShell();
      shell.distros.add('Ubuntu');
      api = WSLApi(shell: shell);
      service = VolumeMountService(api);
    });

    test('applies right away and keeps host paths as windows paths', () {
      expect(service.appliesAtNextStart, isFalse);
      expect(service.windowsHostPaths, isTrue);
      expect(VolumeMountService.isSupported(api), isTrue);
    });

    test('an fstab line is a drvfs entry with forward slashes', () {
      final line = WslVolumeMountDriver.fstabLine(
          const VolumeMount(
              hostPath: r'C:\Users\eric\My Project',
              guestPath: '/mnt/proj',
              readOnly: true),
          owner: ['uid=1000', 'gid=1000']);
      expect(line,
          r'C:/Users/eric/My\040Project /mnt/proj drvfs defaults,metadata,uid=1000,gid=1000,ro 0 0');
      final parsed = WslVolumeMountDriver.parseLine(line);
      expect(parsed?.hostPath, r'C:\Users\eric\My Project');
      expect(parsed?.guestPath, '/mnt/proj');
      expect(parsed?.readOnly, isTrue);
      // Lines that are not ours (or not drvfs) are ignored, not misread.
      expect(WslVolumeMountDriver.parseLine('//srv/x /mnt/x cifs defaults 0 0'),
          isNull);
      expect(WslVolumeMountDriver.parseLine('garbage'), isNull);
    });

    test('lists nothing on a distro without a block', () async {
      shell.writtenDistroFiles['/etc/fstab'] = 'LABEL=x / ext4 defaults 0 1\n';
      expect(await service.list('Ubuntu'), isEmpty);
    });

    test('saving writes the block and mounts the folder now', () async {
      shell.writtenDistroFiles['/etc/fstab'] = 'LABEL=x / ext4 defaults 0 1\n';
      final result = await service.apply('Ubuntu', [
        const VolumeMount(hostPath: r'C:\Users\eric\proj', guestPath: '/mnt/proj'),
      ]);
      expect(result.timing, MountApplyTiming.now);
      expect(result.warnings, isEmpty);

      final fstab = shell.writtenDistroFiles['/etc/fstab']!;
      expect(fstab, startsWith('LABEL=x / ext4 defaults 0 1\n'));
      expect(FstabMountBlock.lines(fstab),
          ['C:/Users/eric/proj /mnt/proj drvfs defaults,metadata 0 0']);
      // The immediate mount, as root, with the same forward-slash source.
      final mountCmd = shell.runCommands.lastWhere((c) => c.contains('mount -t drvfs'));
      expect(mountCmd, contains("mkdir -p '/mnt/proj'"));
      expect(mountCmd,
          contains("mountpoint -q '/mnt/proj' || mount -t drvfs 'C:/Users/eric/proj' '/mnt/proj' -o 'metadata' || fail=1"));
      expect(mountCmd, endsWith(r'exit $fail'));

      // And it reads back.
      expect(await service.list('Ubuntu'), [
        const VolumeMount(hostPath: r'C:\Users\eric\proj', guestPath: '/mnt/proj'),
      ]);
    });

    test('a dropped folder is unmounted and its line removed', () async {
      shell.writtenDistroFiles['/etc/fstab'] = FstabMountBlock.render('', [
        'C:/a /mnt/a drvfs defaults,metadata 0 0',
        'C:/b /mnt/b drvfs defaults,metadata 0 0',
      ]);
      await service.apply('Ubuntu', [
        const VolumeMount(hostPath: r'C:\b', guestPath: '/mnt/b'),
      ]);
      expect(FstabMountBlock.lines(shell.writtenDistroFiles['/etc/fstab']!),
          ['C:/b /mnt/b drvfs defaults,metadata 0 0']);
      final script = shell.runCommands.lastWhere((c) => c.contains('umount'));
      expect(script, contains("umount '/mnt/a' || fail=1"));
      expect(script, isNot(contains("umount '/mnt/b'")));
      expect(script, contains("mountpoint -q '/mnt/b' ||"));
    });

    test('changing a folder to read-only remounts it, and a busy one is reported',
        () {
      final script = WslVolumeMountDriver.applyScript(
        [const VolumeMount(hostPath: r'C:\a', guestPath: '/mnt/a')],
        [const VolumeMount(hostPath: r'C:\a', guestPath: '/mnt/a', readOnly: true)],
      );
      expect(script, contains("if mountpoint -q '/mnt/a'; then umount '/mnt/a' || fail=1; fi"));
      expect(script, contains("-o 'metadata,ro' || fail=1"));
      expect(script, endsWith(r'exit $fail'));
    });

    test('a mount script that fails is a warning, not a silent success',
        () async {
      shell.writtenDistroFiles['/etc/fstab'] = '';
      shell.failingRunCommands.add('exit \$fail');
      final result = await service.apply('Ubuntu', [
        const VolumeMount(hostPath: r'C:\a', guestPath: '/mnt/a'),
      ]);
      expect(result.warnings, ['mountsapplyfailed-text']);
    });

    test('an unreachable distro is an error, not an empty list', () async {
      shell.simulateWslConfUnreachable = true;
      expect(() => service.list('Ubuntu'), throwsA(isA<VolumeMountException>()));
      expect(
          () => service.apply('Ubuntu', [
                const VolumeMount(hostPath: r'C:\a', guestPath: '/mnt/a'),
              ]),
          throwsA(isA<VolumeMountException>()));
    });

    test('a read-only root filesystem fails the save instead of lying',
        () async {
      shell.writtenDistroFiles['/etc/fstab'] = '';
      shell.simulateWslConfReadOnly = true;
      await expectLater(
          service.apply('Ubuntu', [
            const VolumeMount(hostPath: r'C:\a', guestPath: '/mnt/a'),
          ]),
          throwsA(predicate((e) =>
              e is VolumeMountException && e.message == 'mountswritefailed-text')));
    });

    test('a distro with mountFsTab off is warned about', () async {
      shell.writtenDistroFiles['/etc/fstab'] = '';
      shell.wslConfContents = '[automount]\nmountFsTab = false\n';
      final result = await service.apply('Ubuntu', [
        const VolumeMount(hostPath: r'C:\a', guestPath: '/mnt/a'),
      ]);
      expect(result.warnings, ['mountsfstabdisabled-text']);
      // The key only counts in its own section, and the default is on.
      expect(WslVolumeMountDriver.fstabDisabled('[boot]\nmountFsTab=false\n'),
          isFalse);
      expect(WslVolumeMountDriver.fstabDisabled('[automount]\nMOUNTFSTAB = False\n'),
          isTrue);
      expect(WslVolumeMountDriver.fstabDisabled(null), isFalse);
    });

    test('bad input is refused before anything is written', () async {
      shell.writtenDistroFiles['/etc/fstab'] = 'keep\n';
      await expectLater(
          service.apply('Ubuntu', [
            const VolumeMount(hostPath: r'C:\a', guestPath: '/etc'),
          ]),
          throwsA(isA<VolumeMountException>()));
      await expectLater(
          service.apply('Ubuntu', [
            const VolumeMount(hostPath: '/not/windows', guestPath: '/mnt/a'),
          ]),
          throwsA(isA<VolumeMountException>()));
      await expectLater(
          service.apply('Ubuntu', [
            const VolumeMount(hostPath: r'C:\a', guestPath: '/mnt/a'),
            const VolumeMount(hostPath: r'C:\b', guestPath: '/mnt/a'),
          ]),
          throwsA(predicate((e) =>
              e is VolumeMountException &&
              e.message == 'mountsguestduplicate-text')));
      expect(shell.writtenDistroFiles['/etc/fstab'], 'keep\n');
    });
  });

  group('Apple driver', () {
    late FakeVmctlShell shell;
    late AppleVmApi api;
    late VolumeMountService service;

    setUp(() {
      shell = FakeVmctlShell();
      api = AppleVmApi(
        shell: shell,
        helperPathOverride: '/fake/vmctl',
        storeDirOverride: '/tmp/fake-store',
        earlyExitProbeDelay: Duration.zero,
      );
      service = VolumeMountService(api);
    });

    Map<String, dynamic> listing(List<Map<String, dynamic>> mounts,
            {bool running = false}) =>
        {'name': 'dev', 'os': 'linux', 'running': running, 'mounts': mounts};

    test('waits for the next start and takes posix host paths', () {
      expect(service.appliesAtNextStart, isTrue);
      expect(service.windowsHostPaths, isFalse);
      expect(VolumeMountService.isSupported(api), isTrue);
    });

    test('lists what vmctl reports, and what the guest said about it', () async {
      shell.responses['mounts'] = json.encode(listing([
        {
          'hostPath': '/Users/eric/proj',
          'guestPath': '/mnt/proj',
          'readOnly': true,
          'tag': 'wslm0'
        },
      ]));
      expect(await service.list('dev'), [
        const VolumeMount(
            hostPath: '/Users/eric/proj', guestPath: '/mnt/proj', readOnly: true),
      ]);
      expect(shell.calls.last,
          ['/fake/vmctl', '--store', '/tmp/fake-store', 'mounts', '--name', 'dev']);
      expect(service.guestProblem, isNull);
      expect(service.suggestGuestPath('/Users/eric/other'), '/mnt/other');

      shell.responses['mounts'] = json.encode({
        ...listing([], running: true),
        'guest': {'state': 'partial', 'error': 'host directory missing: /gone'},
      });
      await service.list('dev');
      expect(service.guestProblem, 'host directory missing: /gone');

      shell.responses['mounts'] = json.encode({
        ...listing([]),
        'os': 'macos',
      });
      await service.list('dev');
      expect(service.guestProblem, isNull);
      expect(service.suggestGuestPath('/Users/eric/proj'),
          '/Volumes/My Shared Files/proj');
    });

    test('saving unmounts what went away and mounts what changed', () async {
      shell.responses['mounts'] = json.encode(listing([
        {'hostPath': '/a', 'guestPath': '/mnt/a', 'readOnly': false, 'tag': 'wslm0'},
        {'hostPath': '/b', 'guestPath': '/mnt/b', 'readOnly': false, 'tag': 'wslm1'},
        {'hostPath': '/c', 'guestPath': '/mnt/c', 'readOnly': false, 'tag': 'wslm2'},
      ], running: true));
      shell.responses['mount'] = json.encode(listing([], running: true));
      shell.responses['unmount'] = json.encode(listing([], running: true));

      final result = await service.apply('dev', [
        // Unchanged: not touched.
        const VolumeMount(hostPath: '/a', guestPath: '/mnt/a'),
        // Same mount point, now read-only: re-added.
        const VolumeMount(hostPath: '/b', guestPath: '/mnt/b', readOnly: true),
        // New; a trailing slash is normalised away before vmctl sees it.
        const VolumeMount(hostPath: '/d/', guestPath: '/mnt/d'),
      ]);
      expect(result.timing, MountApplyTiming.nextStart);
      expect(result.instanceRunning, isTrue);

      final commands = shell.calls.map((c) => c.sublist(3)).toList();
      expect(commands, [
        ['mounts', '--name', 'dev'],
        ['unmount', '--name', 'dev', '--guest', '/mnt/c'],
        ['mount', '--name', 'dev', '--host', '/b', '--guest', '/mnt/b', '--read-only'],
        ['mount', '--name', 'dev', '--host', '/d', '--guest', '/mnt/d'],
      ]);
    });

    test('an unchanged row given with a trailing slash is not re-added', () async {
      shell.responses['mounts'] = json.encode(listing([
        {'hostPath': '/a', 'guestPath': '/mnt/a', 'readOnly': false, 'tag': 'wslm0'},
      ]));
      await service.apply('dev', [
        const VolumeMount(hostPath: '/a/', guestPath: '/mnt/a'),
      ]);
      expect(shell.calls.map((c) => c[3]), ['mounts']);
    });

    test("a macOS guest's shares round-trip through the dialog's rules", () async {
      shell.responses['mounts'] = json.encode({
        ...listing([
          {
            'hostPath': '/Users/eric/proj',
            'guestPath': '/Volumes/My Shared Files/proj',
            'readOnly': false,
            'tag': 'wslm0'
          },
        ]),
        'os': 'macos',
      });
      shell.responses['unmount'] = json.encode({...listing([]), 'os': 'macos'});
      final current = await service.list('dev');
      // Saving the list as it came back — with one row dropped — passes
      // validation and reaches vmctl.
      await service.apply('dev', current);
      expect(shell.calls.map((c) => c[3]).toList(), ['mounts', 'mounts']);
      await service.apply('dev', []);
      expect(shell.calls.last.sublist(3),
          ['unmount', '--name', 'dev', '--guest', '/Volumes/My Shared Files/proj']);
    });

    test('a stopped VM reports that the change waits for its start', () async {
      shell.responses['mounts'] = json.encode(listing([]));
      shell.responses['mount'] = json.encode(listing([]));
      final result = await service.apply('dev', [
        const VolumeMount(hostPath: '/a', guestPath: '/mnt/a'),
      ]);
      expect(result.instanceRunning, isFalse);
    });

    test("vmctl's refusal is the error the user sees", () async {
      shell.responses['mounts'] = json.encode(listing([]));
      shell.exitCodes['mount'] = 1;
      shell.errors['mount'] = 'Host directory not found: /gone';
      await expectLater(
          service.apply('dev', [
            const VolumeMount(hostPath: '/gone', guestPath: '/mnt/a'),
          ]),
          throwsA(predicate((e) =>
              e is VolumeMountException &&
              e.message == 'Host directory not found: /gone')));
    });

    test('unreadable helper output is reported as such', () async {
      shell.responses['mounts'] = 'not json';
      await expectLater(service.list('dev'),
          throwsA(predicate((e) => '$e'.contains('unreadable output'))));
    });
  });
}
