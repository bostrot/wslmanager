/// Tests for lib/api/windows_terminal_service.dart — the fragment file that
/// puts this app's instances into the Windows Terminal dropdown
/// (bostrot/ai-tasks#93, bostrot/wsl2-distro-manager#239).
///
/// The GUIDs are the part worth pinning hardest: hiding the entry Windows
/// Terminal generates for a distro only works while the value computed here
/// is bit-for-bit the one it computed itself.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/windows_terminal_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_provisioning_backend.dart';

/// A backend that reports the instances it was given, and can claim to be a
/// remote host — the one case a Windows host still writes nothing for.
class TerminalBackend extends ScriptedBackend {
  TerminalBackend(List<String> instances)
      : remote = false,
        super(instances: instances);

  TerminalBackend.remote()
      : remote = true,
        super(instances: const ['Ubuntu']);

  final bool remote;

  @override
  bool get isRemote => remote;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    dir = Directory.systemTemp.createTempSync('wslm_wt');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A service that believes it is on Windows, so the one thing worth
  /// testing — what lands in the file — runs on the machine the suite runs
  /// on too.
  WindowsTerminalService service({
    List<String> instances = const ['Ubuntu'],
    bool remote = false,
    bool windows = true,
    String? fragmentDirectory,
    String? iconPath,
  }) =>
      WindowsTerminalService(
        backend: remote ? TerminalBackend.remote() : TerminalBackend(instances),
        fragmentDirectory: fragmentDirectory ?? dir.path,
        iconPath: iconPath ?? '',
        hostIsWindows: windows,
      );

  Map<String, Object?> fragmentOf(WindowsTerminalService s) =>
      jsonDecode(File(s.fragmentPath).readAsStringSync())
          as Map<String, Object?>;

  List<Map<String, Object?>> profilesOf(WindowsTerminalService s) => [
        for (final p in fragmentOf(s)['profiles'] as List)
          p as Map<String, Object?>
      ];

  group('profile GUIDs', () {
    test('matches the GUID Windows Terminal generates for the same distro', () {
      // The value Windows Terminal itself computes for a WSL distro named
      // Ubuntu. Hiding its entry is an `updates` on exactly this GUID, so a
      // change here silently leaves two Ubuntus in the menu.
      expect(WindowsTerminalService.generatedProfileGuid('Ubuntu'),
          '{2c4de342-38b7-51cf-b940-2309a097f518}');
      expect(WindowsTerminalService.generatedProfileGuid('Alpine'),
          '{1777cdf0-b2c4-5a63-a204-eb60f349ea7c}');
      // A name with a space and a dot, because distro names carry both.
      expect(WindowsTerminalService.generatedProfileGuid('Ubuntu 22.04'),
          '{32ab11f3-7cb6-5e77-86cb-0d63f42962fe}');
    });

    test('this app\'s own profiles hang off the fragment namespace', () {
      expect(WindowsTerminalService.profileGuid('Ubuntu'),
          '{6bb367d0-deb0-5537-a783-426710ba0700}');
      // The two must never collide: one creates the entry, the other hides
      // the one Windows Terminal made.
      expect(WindowsTerminalService.profileGuid('Ubuntu'),
          isNot(WindowsTerminalService.generatedProfileGuid('Ubuntu')));
    });

    test('is stable and differs per name', () {
      expect(WindowsTerminalService.profileGuid('Ubuntu'),
          WindowsTerminalService.profileGuid('Ubuntu'));
      expect(WindowsTerminalService.profileGuid('Ubuntu'),
          isNot(WindowsTerminalService.profileGuid('ubuntu')));
    });
  });

  group('the command line a profile runs', () {
    test('starts in the home directory, not in /mnt/c', () {
      expect(WindowsTerminalService.commandlineFor('Ubuntu'),
          'wsl.exe -d Ubuntu --cd ~');
    });

    test('quotes a name with a space', () {
      expect(WindowsTerminalService.commandlineFor('My Distro'),
          'wsl.exe -d "My Distro" --cd ~');
    });
  });

  group('the fragment', () {
    test('creates one profile per instance and hides the generated twin', () {
      final s = service();
      final profiles =
          jsonDecode(s.buildFragment(['Ubuntu']))['profiles'] as List<dynamic>;

      expect(profiles, hasLength(2));
      final created = profiles.first as Map<String, Object?>;
      expect(created['name'], 'Ubuntu');
      expect(created['guid'], WindowsTerminalService.profileGuid('Ubuntu'));
      expect(created['commandline'], 'wsl.exe -d Ubuntu --cd ~');
      expect(created.containsKey('startingDirectory'), isTrue);

      final hidden = profiles.last as Map<String, Object?>;
      expect(hidden['updates'],
          WindowsTerminalService.generatedProfileGuid('Ubuntu'));
      expect(hidden['hidden'], isTrue);
    });

    test('leaves the generated entries alone when asked to', () async {
      final s = service();
      await s.setHideGenerated(false);
      final profiles =
          jsonDecode(s.buildFragment(['Ubuntu']))['profiles'] as List<dynamic>;

      expect(profiles, hasLength(1));
      expect((profiles.single as Map<String, Object?>)['updates'], isNull);
    });

    test('writes one entry for a name listed twice', () {
      final profiles =
          jsonDecode(service().buildFragment(['Ubuntu', 'Ubuntu ', ' Ubuntu']))[
              'profiles'] as List<dynamic>;

      expect(profiles, hasLength(2));
      expect((profiles.first as Map<String, Object?>)['name'], 'Ubuntu');
    });

    test('skips a name that is only whitespace', () {
      final profiles =
          jsonDecode(service().buildFragment(['', '   ']))['profiles']
              as List<dynamic>;

      expect(profiles, isEmpty);
    });

    test('names an icon only when the file is really there', () async {
      final icon = File('${dir.path}${Platform.pathSeparator}logo.png')
        ..writeAsBytesSync([0]);
      final withIcon = service(iconPath: icon.path);
      final withoutIcon =
          service(iconPath: '${dir.path}${Platform.pathSeparator}gone.png');

      expect(
          (jsonDecode(withIcon.buildFragment(['Ubuntu']))['profiles'].first
              as Map<String, Object?>)['icon'],
          icon.path);
      expect(
          (jsonDecode(withoutIcon.buildFragment(['Ubuntu']))['profiles'].first
                  as Map<String, Object?>)
              .containsKey('icon'),
          isFalse,
          reason: 'a profile that names a missing icon shows a broken one');
    });
  });

  group('writing it', () {
    test('writes the file and says what went in', () async {
      final s = service(instances: ['Ubuntu', 'Alpine']);
      final result = await s.sync();

      expect(result.changed, isTrue);
      expect(result.names, ['Ubuntu', 'Alpine']);
      expect(File(s.fragmentPath).existsSync(), isTrue);
      expect(profilesOf(s), hasLength(4));
    });

    test('a second sync with the same instances writes nothing', () async {
      final s = service();
      await s.sync();
      final stamp = File(s.fragmentPath).lastModifiedSync();

      final again = await s.sync();

      expect(again.changed, isFalse);
      expect(again.names, ['Ubuntu']);
      expect(File(s.fragmentPath).lastModifiedSync(), stamp);
    });

    test('an instance that is gone leaves the file with it', () async {
      final before = service(instances: ['Ubuntu', 'Alpine']);
      await before.sync();

      final after = service(instances: ['Ubuntu']);
      await after.sync();

      final names = [
        for (final p in profilesOf(after))
          if (p['name'] != null) p['name']
      ];
      expect(names, ['Ubuntu'], reason: 'the file is rewritten, not appended');
    });

    test('clearing takes the file and its folder back out', () async {
      final nested = Directory('${dir.path}${Platform.pathSeparator}WSL').path;
      final s = service(fragmentDirectory: nested);
      await s.sync();
      expect(File(s.fragmentPath).existsSync(), isTrue);

      final cleared = await s.clear();

      expect(cleared.changed, isTrue);
      expect(cleared.names, isEmpty);
      expect(File(s.fragmentPath).existsSync(), isFalse);
      expect(Directory(nested).existsSync(), isFalse,
          reason: 'an empty folder this app made is not left behind');
    });

    test('clearing twice is not a second write', () async {
      final s = service();
      await s.sync();
      await s.clear();

      expect((await s.clear()).changed, isFalse);
    });

    test('keeps a folder that holds somebody else\'s fragment', () async {
      final s = service();
      await s.sync();
      final other = File('${dir.path}${Platform.pathSeparator}other.json')
        ..writeAsStringSync('{}');

      await s.clear();

      expect(other.existsSync(), isTrue);
      expect(dir.existsSync(), isTrue);
    });
  });

  group('when it must not write', () {
    test('a remote host gets no profiles for distros it cannot open', () async {
      final s = service(remote: true);
      final result = await s.sync();

      expect(result.skipped, WindowsTerminalSkip.remote);
      expect(File(s.fragmentPath).existsSync(), isFalse);
    });

    test('WSL missing altogether is not a distro called wslNotInstalled',
        () async {
      // `wsl --list` answers with that placeholder instead of an empty
      // list; a profile for it would open a distro that does not exist.
      final s = service(instances: ['wslNotInstalled']);
      final result = await s.sync();

      expect(result.names, isEmpty);
      expect(File(s.fragmentPath).existsSync(), isFalse);
    });

    test('a host without a Windows Terminal writes nothing', () async {
      final s = service(windows: false);
      final result = await s.sync();

      expect(result.skipped, WindowsTerminalSkip.unsupported);
      expect(File(s.fragmentPath).existsSync(), isFalse);
    });

    test('the feature is off until it is turned on', () async {
      final s = service();

      expect(s.enabled, isFalse);
      await s.setEnabled(true);
      expect(s.enabled, isTrue);
      expect(prefs.getBool(WindowsTerminalService.prefEnabled), isTrue);
    });

    test('a remote host reports the feature as off even when enabled',
        () async {
      final s = service(remote: true);
      await s.setEnabled(true);

      expect(s.enabled, isFalse);
    });
  });

  group('following the instance list', () {
    test('does not start a timer while the feature is off', () {
      final s = service();
      s.startAutoSync();
      addTearDown(s.stopAutoSync);

      expect(File(s.fragmentPath).existsSync(), isFalse);
    });

    test('writes the current list as soon as it is started', () async {
      final s = service();
      await s.setEnabled(true);
      s.startAutoSync();
      addTearDown(s.stopAutoSync);

      // The first tick is not awaited by startAutoSync; it is one microtask
      // plus the backend's answer away.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(File(s.fragmentPath).existsSync(), isTrue);
      expect(profilesOf(s).first['name'], 'Ubuntu');
    });
  });
}
