import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// The pipeline that produces the Windows Arm64 build is only ever exercised
/// by a real release, on a runner nobody has locally, and most of the ways it
/// can go wrong are silent: an SDK that builds x64 under emulation, an
/// installer that says Arm64 in its name and `x64compatible` in its header, a
/// re-upload that changes the bytes under a published checksum. These are the
/// invariants that keep those failures loud.

/// The first Flutter stable whose engine publishes `windows-arm64` artifacts.
/// Anything older cannot produce this build at all, whatever runner it is
/// given.
const List<int> minimumArm64Flutter = <int>[3, 44, 0];

const String arm64Runner = 'windows-11-arm';

YamlMap workflow(String name) =>
    loadYaml(File('.github/workflows/$name').readAsStringSync()) as YamlMap;

/// Every `run:` and `uses:` line of [job], flattened, so a step can be looked
/// for without caring which step it ended up in.
String stepsText(YamlMap job) {
  final StringBuffer buffer = StringBuffer();
  for (final Object? step in job['steps'] as YamlList) {
    final YamlMap map = step as YamlMap;
    for (final String key in <String>['uses', 'run', 'name']) {
      if (map[key] != null) {
        buffer.writeln(map[key].toString());
      }
    }
    if (map['with'] != null) {
      buffer.writeln((map['with'] as YamlMap).values.join('\n'));
    }
  }
  return buffer.toString();
}

List<int> parseVersion(String version) =>
    version.split('.').map(int.parse).toList();

bool isAtLeast(List<int> version, List<int> minimum) {
  for (int index = 0; index < minimum.length; index++) {
    if (version[index] != minimum[index]) {
      return version[index] > minimum[index];
    }
  }
  return true;
}

/// The one job in [name] that runs on the Arm64 runner.
YamlMap arm64Job(String name) {
  final YamlMap jobs = workflow(name)['jobs'] as YamlMap;
  final List<YamlMap> matches = <YamlMap>[
    for (final Object? key in jobs.keys)
      if ((jobs[key] as YamlMap)['runs-on'] == arm64Runner)
        jobs[key] as YamlMap,
  ];
  expect(
    matches,
    hasLength(1),
    reason: '$name should have exactly one $arm64Runner job',
  );
  return matches.single;
}

void main() {
  group('the Arm64 SDK pin', () {
    for (final String name in <String>['releaser.yml', 'test.yml']) {
      test('$name pins a Flutter that can target Windows Arm64', () {
        final Object? pin = (workflow(name)['env'] as YamlMap?)?['FLUTTER_ARM64_VERSION'];
        expect(pin, isNotNull, reason: '$name should pin the Arm64 SDK');
        expect(
          isAtLeast(parseVersion(pin.toString()), minimumArm64Flutter),
          isTrue,
          reason:
              'Flutter $pin publishes no windows-arm64 engine artifacts; '
              '${minimumArm64Flutter.join('.')} is the oldest that does',
        );
      });

      test('$name installs that SDK by cloning, not from the x64 zip', () {
        final YamlMap job = arm64Job(name);
        final String steps = stepsText(job);
        expect(
          steps,
          isNot(contains('subosito/flutter-action')),
          reason:
              'the published Windows SDK is x64 only, so the action would '
              'build an x64 app under emulation',
        );
        expect(steps, contains('git clone'));
        expect(steps, contains(r'$env:FLUTTER_ARM64_VERSION'));
      });

      test('$name refuses to ship a build that turned out to be x64', () {
        expect(
          stepsText(arm64Job(name)),
          contains('check_pe_architecture.dart'),
        );
        expect(stepsText(arm64Job(name)), contains('arm64'));
      });
    }

    test('the x64 jobs keep their own, older pin', () {
      final String releaser =
          File('.github/workflows/releaser.yml').readAsStringSync();
      expect(releaser, contains("flutter-version: '3.41.6'"));
    });
  });

  group('releaser.yml', () {
    test('builds the Arm64 app only after the x64 job made the release', () {
      final YamlMap job = arm64Job('releaser.yml');
      expect(job['needs'].toString(), contains('build'));
    });

    test('packages the Arm64 MSIX and installer from the Arm64 build', () {
      final String steps = stepsText(arm64Job('releaser.yml'));
      expect(steps, contains('msix:create --architecture arm64'));
      expect(steps, contains('stage-payload.ps1 -Architecture arm64'));
      expect(steps, contains('/DTargetArch=arm64'));
      expect(steps, contains(r'build\windows\arm64\runner\Release'));
    });

    test('attaches assets only to the release this run created, and never '
        'over bytes that are already published', () {
      final YamlList steps = arm64Job('releaser.yml')['steps'] as YamlList;
      final YamlMap upload = steps.firstWhere(
        (Object? step) =>
            (step as YamlMap)['run']?.toString().contains('gh release upload') ??
            false,
      ) as YamlMap;

      expect(upload['run'].toString(), isNot(contains('--clobber')));
      final String condition = upload['if'].toString();
      expect(condition, contains("exists == 'false'"));
      expect(condition, contains("refs/heads/main"));
    });

    test('names the Arm64 assets so WinGet can tell them apart', () {
      final String steps = stepsText(arm64Job('releaser.yml'));
      expect(steps, contains('-arm64-setup.exe'));
      expect(steps, contains('-arm64-unsigned.msix'));
      expect(steps, contains('-arm64.zip'));
    });

    test('dispatches the publish workflows once both builds are done, and '
        'still does so when the Arm64 one failed', () {
      final YamlMap jobs = workflow('releaser.yml')['jobs'] as YamlMap;
      final YamlMap publish = jobs['publish'] as YamlMap;
      expect(publish['needs'].toString(), contains('build-arm64'));
      expect(publish['if'].toString(), contains('always()'));
      expect(publish['if'].toString(), contains("needs.build.result == 'success'"));
      expect(stepsText(publish), contains('publish-winget.yml'));
      expect(stepsText(publish), contains('publish-store.yml'));

      // The dispatch used to sit at the end of the x64 job; leaving a copy
      // there would publish a WinGet manifest before the Arm64 installer is
      // on the release.
      expect(stepsText(jobs['build'] as YamlMap),
          isNot(contains('publish-winget.yml')));
    });
  });

  group('the WinGet manifest', () {
    test('collects both installers off the release', () {
      final YamlMap jobs = workflow('publish-winget.yml')['jobs'] as YamlMap;
      final YamlList steps = (jobs['publish'] as YamlMap)['steps'] as YamlList;
      final YamlMap publish = steps.firstWhere(
        (Object? step) =>
            (step as YamlMap)['uses']?.toString().contains('winget-releaser') ??
            false,
      ) as YamlMap;

      final RegExp installers =
          RegExp(((publish['with'] as YamlMap)['installers-regex'] as String));
      expect(installers.hasMatch('wsl2-distro-manager-v2.3.0-setup.exe'), isTrue);
      expect(
        installers.hasMatch('wsl2-distro-manager-v2.3.0-arm64-setup.exe'),
        isTrue,
        reason: 'the Arm64 installer has to reach the manifest too',
      );
      // The MSIX and the archive are not installers.
      expect(
        installers.hasMatch('wsl2-distro-manager-v2.3.0-arm64-unsigned.msix'),
        isFalse,
      );
      expect(installers.hasMatch('wsl2-distro-manager-v2.3.0-arm64.zip'), isFalse);
    });
  });

  group('the Inno Setup script', () {
    late String setup;

    setUp(() {
      setup = File('installer/setup.iss').readAsStringSync();
    });

    test('still builds the x64 installer exactly as before when nothing is '
        'passed', () {
      expect(setup, contains('#ifndef TargetArch'));
      expect(setup, contains('#define TargetArch "x64"'));
      expect(setup, contains('#define ArchitectureIdentifiers "x64compatible"'));
      expect(setup, contains('#define OutputName "wsl2-distro-manager-setup"'));
    });

    test('marks the Arm64 installer as Arm64 rather than x64compatible', () {
      expect(setup, contains('#define ArchitectureIdentifiers "arm64"'));
      expect(
        setup,
        contains('#define OutputName "wsl2-distro-manager-setup-arm64"'),
      );
      expect(setup, contains('ArchitecturesAllowed={#ArchitectureIdentifiers}'));
      expect(
        setup,
        contains('ArchitecturesInstallIn64BitMode={#ArchitectureIdentifiers}'),
      );
      expect(setup, contains('OutputBaseFilename={#OutputName}'));
    });

    test('rejects any other architecture instead of defaulting to one', () {
      expect(setup, contains('#error'));
    });

    test('keeps one AppId, so either installer upgrades the other in place',
        () {
      expect(
        RegExp(r'^AppId=', multiLine: true).allMatches(setup),
        hasLength(1),
      );
    });
  });

  group('stage-payload.ps1', () {
    late String stage;

    setUp(() {
      stage = File('installer/stage-payload.ps1').readAsStringSync();
    });

    test('takes an architecture and defaults to the old behaviour', () {
      expect(stage, contains("[ValidateSet('auto', 'x64', 'arm64')]"));
      expect(stage, contains(r"$Architecture = 'auto'"));
    });

    test('never falls back to the other architecture once told which one', () {
      // The top-level else, not one of the inline PowerShell ternaries.
      final RegExpMatch? branch =
          RegExp(r'^\} else \{$', multiLine: true).firstMatch(stage);
      expect(branch, isNotNull);
      final String explicit = stage.substring(branch!.start);
      expect(explicit, contains('throw'));
      expect(
        explicit,
        isNot(contains('Select-Object -First 1')),
        reason: 'an explicit architecture must not search a candidate list',
      );
    });

    test('reads the emulation-proof environment variable when guessing', () {
      expect(stage, contains(r'$env:PROCESSOR_ARCHITEW6432'));
    });
  });
}
