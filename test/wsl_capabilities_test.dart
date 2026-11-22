// Tests for lib/api/wsl_capabilities.dart — the service that finally asks
// `wsl.exe` which WSL this is (audit cli-flags CC-1 / P05-08).
//
// Two things are pinned here that a version string alone cannot express:
//
// * `wsl --version` is **localised**. The machine the audit's runtime pass ran
//   on answers in German, so the parser matches by shape, not by the English
//   label, and the German output is a fixture below.
// * `atLeast` returns **false** when the version is unknown. Every gate built
//   on it chooses between a native verb and a safe fallback, and the fallback
//   is the one that must win a tie — an inbox build that cannot answer
//   `--version` must not be handed `--manage`.
// ignore_for_file: dangling_library_doc_comments

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_capabilities.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

/// Real `wsl --version` output, English.
const String _englishVersion = '''
WSL version: 2.6.3.0
Kernel version: 6.6.87.2-1
WSLg version: 1.0.66
MSRDC version: 1.2.6353
Direct3D version: 1.611.1-81528511
DXCore version: 10.0.26100.1-240331-1435.ge-release
Windows version: 10.0.26200.1234
''';

/// The same, as the machine in doc/audit/wsl-docs/runtime.md prints it.
const String _germanVersion = '''
WSL-Version: 2.6.3.0
Kernelversion: 6.6.87.2-1
WSLg-Version: 1.0.66
Windows-Version: 10.0.26200.1234
''';

const String _status = '''
Default Distribution: Ubuntu
Default Version: 2
''';

void main() {
  group('version parsing', () {
    test('reads the WSL version, not WSLg and not the kernel', () {
      final capabilities = WslCapabilities.parse(
          const WslOutput(0, _englishVersion, ''), const WslOutput(0, '', ''));
      expect(capabilities.version, '2.6.3.0');
      expect(capabilities.kernelVersion, '6.6.87.2-1');
      expect(capabilities.isStoreWsl, true);
      expect(capabilities.wslMissing, false);
    });

    test('a localised answer parses the same way', () {
      final capabilities = WslCapabilities.parse(
          const WslOutput(0, _germanVersion, ''), const WslOutput(0, '', ''));
      expect(capabilities.version, '2.6.3.0');
      expect(capabilities.kernelVersion, '6.6.87.2-1');
    });

    test('the inbox build rejects the flag and reports no version', () {
      // systemd.md:30's documented probe: this is what tells the two builds
      // apart, and it is why `isStoreWsl` is not a guess.
      final capabilities = WslCapabilities.parse(
          const WslOutput(1, '', 'Invalid command line option: --version'),
          const WslOutput(0, _status, ''));
      expect(capabilities.version, isNull);
      expect(capabilities.isStoreWsl, false);
      expect(capabilities.supportsManage, false);
      expect(capabilities.wslMissing, false);
      expect(capabilities.defaultDistro, 'Ubuntu');
    });

    test('a wsl.exe that will not run at all is reported as missing', () {
      final capabilities = WslCapabilities.parse(
          const WslOutput(-1, '', 'ProcessException'),
          const WslOutput(-1, '', 'ProcessException'));
      expect(capabilities.wslMissing, true);
      expect(capabilities.supportsManage, false);
    });
  });

  group('status parsing', () {
    test('reads the default distro and version', () {
      final capabilities = WslCapabilities.parse(
          const WslOutput(0, _englishVersion, ''),
          const WslOutput(0, _status, ''));
      expect(capabilities.defaultDistro, 'Ubuntu');
      expect(capabilities.defaultVersion, 2);
    });
  });

  /// Runtime R-1 and R-4: wsl.exe reports a refused config key and an
  /// unsupported host CPU on stderr **with exit code 0**. A service that reads
  /// only the exit code cannot tell a working command from an ignored one.
  group('warnings (R-1, R-4)', () {
    test("WSL's own stderr is carried through, not discarded", () {
      final capabilities = WslCapabilities.parse(
        const WslOutput(0, _englishVersion,
            'wsl: Geschachtelte Virtualisierung wird auf diesem Computer nicht unterstützt.'),
        const WslOutput(0, _status, "wsl: Unbekannter Schlüssel „wsl2.foo“"),
      );
      expect(capabilities.warnings, hasLength(2));
      expect(capabilities.warnings.first, contains('Virtualisierung'));
      expect(capabilities.warnings.last, contains('Unbekannter'));
    });

    test('blank stderr lines are not warnings', () {
      final capabilities = WslCapabilities.parse(
          const WslOutput(0, _englishVersion, '\n  \n'),
          const WslOutput(0, '', ''));
      expect(capabilities.warnings, isEmpty);
    });

    /// Audit ST-07: the Settings panel headed every one of these lines with
    /// "WSL reported:" inside the `.wslconfig` section, so a virtualisation
    /// warning read as a complaint about the config file. Only the lines that
    /// name the file belong there — and the file name is not localized.
    test('config warnings are separated from everything else', () {
      final capabilities = WslCapabilities.parse(
        const WslOutput(0, _englishVersion,
            'wsl: Geschachtelte Virtualisierung wird auf diesem Computer nicht unterstützt.'),
        const WslOutput(0, _status,
            'wsl: Unbekannter Schlüssel „wsl2.foo“ in .wslconfig wird ignoriert'),
      );
      expect(capabilities.configWarnings, hasLength(1));
      expect(capabilities.configWarnings.single, contains('.wslconfig'));
      expect(capabilities.otherWarnings, hasLength(1));
      expect(capabilities.otherWarnings.single, contains('Virtualisierung'));
      // Nothing is dropped on the way — both lists together are the whole set.
      expect(capabilities.configWarnings.length + capabilities.otherWarnings.length,
          capabilities.warnings.length);
    });
  });

  group('atLeast', () {
    WslCapabilities at(String version) => WslCapabilities(version: version);

    test('compares component by component, not lexically', () {
      expect(at('2.10.0').atLeast(2, 5), true);
      expect(at('2.4.13').atLeast(2, 5), false);
      expect(at('10.0.0').atLeast(2, 5), true);
    });

    test('an exact match counts as at least', () {
      expect(at('2.5.0').atLeast(2, 5), true);
      expect(at('2.5').atLeast(2, 5), true);
      expect(at('2.5.7.0').atLeast(2, 5, 7), true);
    });

    test('an unknown version is never enough', () {
      // The gate has to fall back rather than guess: the fallback path always
      // works, the native one does not always exist.
      expect(const WslCapabilities().atLeast(2, 5), false);
      expect(const WslCapabilities().supportsManage, false);
      expect(WslCapabilities.unknown.supportsManage, false);
    });

    test('--manage is gated on 2.5', () {
      expect(at('2.4.13').supportsManage, false);
      expect(at('2.5.0').supportsManage, true);
      expect(at('2.6.3.0').supportsManage, true);
    });

    /// `build-custom-distro.md:16` states the floor in so many words — "This
    /// guide only applies to WSL release 2.4.4 and higher" — and it is the
    /// one floor in this app with a *patch* component, which is where a
    /// two-component version and a lexical compare both go wrong.
    test('.wsl packages are gated on 2.4.4', () {
      expect(at('2.4.3.0').supportsWslPackages, false);
      expect(at('2.4').supportsWslPackages, false,
          reason: 'a missing patch component is patch 0, not "close enough"');
      expect(at('2.4.4').supportsWslPackages, true);
      expect(at('2.4.4.0').supportsWslPackages, true);
      expect(at('2.4.10').supportsWslPackages, true,
          reason: '10 > 4 component-wise, even though "10" < "4" as text');
      expect(at('2.5.0').supportsWslPackages, true);
      expect(const WslCapabilities().supportsWslPackages, false);
    });
  });

  /// `disk-space.md:30`'s documented usage check. `-k` is used rather than `-h`
  /// so there is one unit to parse and the formatting stays in the UI.
  group('df parsing', () {
    test('reads the data row past the header', () {
      const output =
          'Filesystem     1K-blocks     Used Available Use% Mounted on\n'
          '/dev/sdd      1055762868  3540192 998529532   1% /mnt/wslg/distro\n';
      final usage = WslDiskUsage.parseDf(output)!;
      expect(usage.totalBytes, 1055762868 * 1024);
      expect(usage.usedBytes, 3540192 * 1024);
      expect(usage.availableBytes, 998529532 * 1024);
      expect(usage.usedFraction, closeTo(0.00335, 0.0001));
    });

    test('a distro that would not start yields nothing rather than zeroes', () {
      expect(WslDiskUsage.parseDf(''), isNull);
      expect(
          WslDiskUsage.parseDf('df: /mnt/wslg/distro: No such file'), isNull);
    });
  });

  group('the service caches', () {
    late MockShell mockShell;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mockShell = MockShell();
      mockShell.wslVersionOutput = _englishVersion;
      mockShell.wslStatusOutput = _status;
    });

    test('runs the probes once and reuses the answer', () async {
      final service =
          WslCapabilityService(apiBuilder: () => WSLApi(shell: mockShell));

      final first = await service.load();
      expect(first.version, '2.6.3.0');
      final probeCalls = mockShell.runCommands.length;

      final second = await service.load();
      expect(identical(first, second), true);
      expect(service.cached, same(first));
      // Nothing new was executed for the second call.
      expect(mockShell.runCommands.length, probeCalls);
    });

    test('concurrent callers share one probe', () async {
      final service =
          WslCapabilityService(apiBuilder: () => WSLApi(shell: mockShell));
      final results = await Future.wait(
          <Future<WslCapabilities>>[service.load(), service.load()]);
      expect(identical(results[0], results[1]), true);
    });

    test('reset makes the next call ask again', () async {
      final service =
          WslCapabilityService(apiBuilder: () => WSLApi(shell: mockShell));
      final first = await service.load();
      service.reset();
      expect(service.cached, isNull);

      mockShell.wslVersionOutput = 'WSL version: 2.7.0.0';
      final second = await service.load();
      expect(identical(first, second), false);
      expect(second.version, '2.7.0.0');
    });

    test(
        'a WSLApi built around an injected shell does not read the app-wide '
        'cache', () async {
      // Otherwise the real wsl.exe on the developer's machine decides which
      // branch every move/disk test takes.
      final api = WSLApi(shell: mockShell);
      expect(identical(api.capabilities, WslCapabilityService.instance), false);

      final production = WSLApi();
      expect(identical(production.capabilities, WslCapabilityService.instance),
          true);
    });
  });
}
