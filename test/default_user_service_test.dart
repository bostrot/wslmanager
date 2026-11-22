/// Tests for lib/api/default_user_service.dart.
///
/// Upstream bostrot/wsl2-distro-manager#268: a distro created here opened as
/// root when the user typed `wsl` in a Windows terminal. Every group below
/// pins one half of the reason — the `/etc/wsl.conf` key not being read until
/// the distro restarts, and `--manage --set-default-user` not being used at
/// all — so a regression names itself.
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/default_user_service.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

/// A `/etc/passwd` with root and one ordinary account.
const String _passwd = 'root:x:0:0:root:/root:/bin/bash\n'
    'tester:x:1000:1000::/home/tester:/bin/bash\n';

/// `wsl --version` of a build that has `--manage` (WSL 2.5+).
const String _wsl25 = 'WSL version: 2.5.0.0\nKernel version: 6.6.87.2-1\n';

void main() {
  late MockShell mockShell;
  late WSLApi api;
  late DefaultUserService service;

  setUpAll(() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await initPrefs();
  });

  setUp(() {
    mockShell = MockShell();
    mockShell.wslConfContents = '';
    mockShell.writtenDistroFiles['/etc/passwd'] = _passwd;
    api = WSLApi(shell: mockShell);
    service = DefaultUserService(api);
  });

  /// Every `wsl --terminate` the distro was handed.
  int terminates() =>
      mockShell.runCalls.where((args) => args.contains('--terminate')).length;

  group('parsePasswd', () {
    test('reads the home directory of each account', () {
      final entries = parsePasswd(_passwd);

      expect(entries.map((e) => e.name), ['root', 'tester']);
      expect(entries.last.uid, 1000);
      expect(entries.last.home, '/home/tester');
      expect(entries.last.shell, '/bin/bash');
    });

    test('skips comments, blank lines and truncated records', () {
      final entries = parsePasswd('# added by the image build\n'
          '\n'
          'broken:x:1000\n'
          'nouid:x:abc:1000::/home/nouid:/bin/sh\n'
          'ok:x:1001:1001::/var/lib/ok:/bin/sh\n');

      expect(entries.map((e) => e.name), ['ok']);
      expect(entries.single.home, '/var/lib/ok');
    });
  });

  group('refusing a name that would break the distro', () {
    test('a name that is not a POSIX user name is never written', () async {
      final result = await service.setDefaultUser('Test', 'root; rm -rf /');

      expect(result.status, DefaultUserStatus.invalidName);
      expect(result.ok, false);
      expect(mockShell.wslConfContents, '');
      expect(mockShell.manageCalls, isEmpty);
    });

    test('an account /etc/passwd does not have is refused', () async {
      // `[user] default` naming a missing account stops the distro from
      // starting at all — strictly worse than the root shell it replaces.
      final result = await service.setDefaultUser('Test', 'ghost');

      expect(result.status, DefaultUserStatus.noSuchUser);
      expect(mockShell.wslConfContents, '');
      expect(mockShell.manageCalls, isEmpty);
    });

    test('an unreadable /etc/passwd is a failure, not an empty one', () async {
      mockShell.simulateWslConfUnreachable = true;

      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.status, DefaultUserStatus.failed);
      expect(mockShell.manageCalls, isEmpty);
    });

    test('a distro with no readable /etc/passwd is still settable', () async {
      // Empty is "cannot verify", which must not take the setting away from a
      // distro that is merely unusual.
      mockShell.writtenDistroFiles['/etc/passwd'] = '';

      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.ok, true);
      expect(result.home, isNull);
      expect(mockShell.wslConfContents, '[user]\ndefault = tester\n');
    });
  });

  group('WSL without --manage', () {
    test('writes the key and terminates so it is read', () async {
      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.status, DefaultUserStatus.applied);
      expect(result.viaManage, false);
      expect(result.restarted, true);
      expect(result.home, '/home/tester');
      expect(mockShell.wslConfContents, '[user]\ndefault = tester\n');
      expect(terminates(), 1);
      expect(mockShell.manageCalls, isEmpty);
    });

    test('other wsl.conf sections survive the write', () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';

      await service.setDefaultUser('Test', 'tester');

      expect(mockShell.wslConfContents,
          '[boot]\nsystemd = true\n\n[user]\ndefault = tester\n');
    });

    test('a terminate that never runs still reports the write', () async {
      mockShell.throwOnTerminate = true;

      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.status, DefaultUserStatus.needsRestart);
      expect(result.ok, true);
      expect(mockShell.wslConfContents, '[user]\ndefault = tester\n');
    });

    test('a read-only /etc reports failure rather than success', () async {
      mockShell.simulateWslConfReadOnly = true;

      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.status, DefaultUserStatus.failed);
      expect(terminates(), 0);
    });
  });

  group('WSL 2.5+', () {
    setUp(() => mockShell.wslVersionOutput = _wsl25);

    test('sets the default user through --manage and leaves the distro up',
        () async {
      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.status, DefaultUserStatus.applied);
      expect(result.viaManage, true);
      expect(result.restarted, false);
      expect(result.home, '/home/tester');
      expect(mockShell.manageCalls.single,
          ['--manage', 'Test', '--set-default-user', 'tester']);
      // The registry is authoritative for the next session, so nothing is
      // waiting on the config file being re-read.
      expect(terminates(), 0);
      // Written anyway: a distro exported from here carries its default user
      // with it, and the registry entry does not travel.
      expect(mockShell.wslConfContents, '[user]\ndefault = tester\n');
    });

    test('a read-only /etc is not a failed change here', () async {
      // The registry entry is enough on its own; only the copy that travels
      // with an `--export` is missing.
      mockShell.simulateWslConfReadOnly = true;

      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.status, DefaultUserStatus.applied);
      expect(result.viaManage, true);
      expect(terminates(), 0);
    });

    test('falls back to the config route when --manage fails', () async {
      mockShell.manageFailure = 'Invalid command line option: --manage';

      final result = await service.setDefaultUser('Test', 'tester');

      expect(result.status, DefaultUserStatus.applied);
      expect(result.viaManage, false);
      expect(result.restarted, true);
      expect(terminates(), 1);
    });
  });

  group('clearDefaultUser', () {
    test('drops the key and terminates without --manage', () async {
      mockShell.wslConfContents = '[user]\ndefault = tester\n';

      final result = await service.clearDefaultUser('Test');

      expect(result.ok, true);
      expect(mockShell.wslConfContents, '[user]\n');
      expect(terminates(), 1);
    });

    test('puts the registry back to root on WSL 2.5+', () async {
      // Dropping the line alone would leave the distro opening as a user no
      // file mentions any more: `DefaultUid` outlives `/etc/wsl.conf`.
      mockShell.wslVersionOutput = _wsl25;
      mockShell.wslConfContents = '[user]\ndefault = tester\n';

      await service.clearDefaultUser('Test');

      expect(mockShell.manageCalls.single,
          ['--manage', 'Test', '--set-default-user', 'root']);
    });
  });

  group('readDefaultUser', () {
    test('reports the configured account', () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n\n'
          '[user]\ndefault = tester\n';

      expect(await service.readDefaultUser('Test'), 'tester');
    });

    test('is null when the distro has no [user] default — the root shell',
        () async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';

      expect(await service.readDefaultUser('Test'), isNull);
    });

    test('is null when the distro cannot be reached', () async {
      mockShell.simulateWslConfUnreachable = true;

      expect(await service.readDefaultUser('Test'), isNull);
    });
  });

  group('homeDirectory', () {
    test('answers from /etc/passwd, not from /home/<user>', () async {
      mockShell.writtenDistroFiles['/etc/passwd'] =
          'alpineuser:x:1000:1000::/var/home/alpineuser:/bin/sh\n';

      expect(await service.homeDirectory('Test', 'alpineuser'),
          '/var/home/alpineuser');
    });

    test('is null for an account the distro does not have', () async {
      expect(await service.homeDirectory('Test', 'ghost'), isNull);
    });
  });
}
