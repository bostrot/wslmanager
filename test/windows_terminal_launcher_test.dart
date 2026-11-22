/// Tests for lib/api/windows_terminal_launcher.dart — starting an instance
/// through its own Windows Terminal profile
/// (bostrot/ai-tasks#95, bostrot/wsl2-distro-manager#279).
///
/// The argument list is the whole feature: `-p <profile>` is what makes the
/// tab carry the distro's colours instead of the default profile's, and the
/// escaping is what keeps a start command from being read as a second
/// Windows Terminal command.
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/windows_terminal_launcher.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// A Windows host with Windows Terminal installed.
  const installed = WindowsTerminalLauncher(
    hostIsWindows: true,
    executablePath: r'C:\Users\me\AppData\Local\Microsoft\WindowsApps\wt.exe',
  );

  /// A Windows host without it.
  const missing =
      WindowsTerminalLauncher(hostIsWindows: true, executablePath: '');

  const wslArgs = ['wsl', '-d', 'Ubuntu'];

  group('profile launch', () {
    test('the default start goes through wt with the instance profile', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: wslArgs,
      );

      expect(launch.executable, 'start');
      expect(launch.arguments,
          ['wt', '-w', '0', 'nt', '-p', 'Ubuntu', 'wsl', '-d', 'Ubuntu']);
    });

    test('the bare wt token is used, never the located path', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: wslArgs,
      );

      // `start "C:\...\wt.exe"` would read the quoted path as the window
      // title and open a stray cmd window instead of a terminal.
      expect(launch.arguments.first, 'wt');
      expect(launch.arguments.any((a) => a.contains('\\')), isFalse);
    });

    test('the start path and user survive the rewrite', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: const [
          'wsl',
          '-d',
          'Ubuntu',
          '--cd',
          '/home/me',
          '--user',
          'me'
        ],
      );

      expect(launch.arguments, [
        'wt',
        '-w',
        '0',
        'nt',
        '-p',
        'Ubuntu',
        'wsl',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/me',
        '--user',
        'me',
      ]);
    });

    test('an instance name with spaces stays one argument', () {
      final launch = installed.resolve(
        instance: 'My Distro',
        executable: 'start',
        arguments: const ['wsl', '-d', 'My Distro'],
      );

      expect(launch.arguments[5], 'My Distro');
    });

    test('a name that is only whitespace names no profile', () {
      final launch = installed.resolve(
        instance: '   ',
        executable: 'start',
        arguments: wslArgs,
      );

      expect(launch.arguments, wslArgs);
      expect(launch.executable, 'start');
    });
  });

  group('when the rewrite is left alone', () {
    test('Windows Terminal is not installed', () {
      final launch = missing.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: wslArgs,
      );

      expect(launch.executable, 'start');
      expect(launch.arguments, wslArgs);
    });

    test('the host is not Windows', () {
      const launcher = WindowsTerminalLauncher(
          hostIsWindows: false, executablePath: r'C:\wt.exe');

      final launch = launcher.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: wslArgs,
      );

      expect(launch.arguments, wslArgs);
    });

    test('the instance lives on a remote host', () {
      // The profile for it is on that machine, not on this one, and `-p
      // Ubuntu` here would name a profile that does not exist.
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: const ['ssh', '--', 'user@host', 'wsl', '-d', 'Ubuntu'],
        remote: true,
      );

      expect(launch.arguments.first, 'ssh');
      expect(launch.arguments, isNot(contains('-p')));
    });

    test('the preference is turned off', () async {
      await prefs.setBool(WindowsTerminalLauncher.prefEnabled, false);

      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: wslArgs,
      );

      expect(launch.arguments, wslArgs);
    });

    test('a terminal of the user own choosing is left as it is', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'custom_terminal.exe',
        arguments: wslArgs,
      );

      expect(launch.executable, 'custom_terminal.exe');
      expect(launch.arguments, wslArgs);
    });
  });

  group('a terminal setting that already points at Windows Terminal', () {
    test('keeps the executable and gains the profile', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: r'C:\Program Files\WindowsApps\wt.exe',
        arguments: wslArgs,
      );

      expect(launch.executable, r'C:\Program Files\WindowsApps\wt.exe');
      expect(launch.arguments,
          ['-w', '0', 'nt', '-p', 'Ubuntu', 'wsl', '-d', 'Ubuntu']);
    });

    test('is matched whatever the case', () {
      expect(WindowsTerminalLauncher.isWindowsTerminal('WT.EXE'), isTrue);
      expect(WindowsTerminalLauncher.isWindowsTerminal(' wt '), isTrue);
      expect(WindowsTerminalLauncher.isWindowsTerminal('wt.exe'), isTrue);
      expect(
          WindowsTerminalLauncher.isWindowsTerminal('powershell.exe'), isFalse);
      expect(WindowsTerminalLauncher.isWindowsTerminal('alacritty'), isFalse);
    });

    test('still opens in a new tab of the window that is there', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'wt',
        arguments: wslArgs,
      );

      expect(launch.arguments.take(3), ['-w', '0', 'nt']);
    });

    test('a remote instance keeps the tab but loses the profile', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'wt',
        arguments: const ['ssh', '--', 'user@host', 'wsl', '-d', 'Ubuntu'],
        remote: true,
      );

      expect(launch.arguments.take(3), ['-w', '0', 'nt']);
      expect(launch.arguments, isNot(contains('-p')));
    });
  });

  group('semicolons', () {
    test('the keep-open shell is escaped for the wt parser', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: const ['wsl', '-d', 'Ubuntu', 'htop', ';/bin/sh'],
      );

      // Unescaped, wt reads `;` as "and now a second command" and the shell
      // that keeps the window open never runs.
      expect(launch.arguments.last, r'\;/bin/sh');
    });

    test('a start command brings its own semicolons along', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'start',
        arguments: const ['wsl', '-d', 'Ubuntu', 'a;b;c', ';/bin/sh'],
      );

      expect(launch.arguments, contains(r'a\;b\;c'));
    });

    test('nothing else in the command line is touched', () {
      expect(
        WindowsTerminalLauncher.escapeArguments(
            const ['wsl', '-d', 'Ubuntu', '--cd', r'C:\Users\me']),
        const ['wsl', '-d', 'Ubuntu', '--cd', r'C:\Users\me'],
      );
    });

    test('a terminal of the user own choosing is escaped too', () {
      final launch = installed.resolve(
        instance: 'Ubuntu',
        executable: 'wt.exe',
        arguments: const ['wsl', '-d', 'Ubuntu', ';/bin/sh'],
      );

      expect(launch.arguments.last, r'\;/bin/sh');
    });
  });

  group('finding wt.exe', () {
    test('there is nothing to find off Windows', () {
      expect(WindowsTerminalLauncher.locateExecutable(),
          Platform.isWindows ? anything : isNull);
    });

    test('an injected path is reported as installed', () {
      expect(installed.isInstalled, isTrue);
      expect(missing.isInstalled, isFalse);
    });

    test('the profile name is the trimmed instance name', () {
      expect(WindowsTerminalLauncher.profileNameFor('  Ubuntu  '), 'Ubuntu');
    });
  });
}
