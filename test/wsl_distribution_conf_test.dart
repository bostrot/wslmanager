/// Tests for lib/api/wsl_distribution_conf.dart — the `.wsl` packaging half of
/// doc/audit/wsl-docs/features.md F-8 (ordered-list item P05-24).
///
/// The model itself is `ini_config.dart`, already exercised by
/// wsl_conf_test.dart and wslconfig_test.dart. What these tests pin is the
/// *dialect*: the documented key table, the case-insensitive canonicalisation
/// on top of it, and the round trip of values a distribution maintainer
/// actually writes — paths, JSON template locations, and values containing
/// spaces and `=`.
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/wsl_distribution_conf.dart';

void main() {
  group('the documented key table', () {
    test('has exactly the three documented sections', () {
      expect(kWslDistributionConfKeys.keys.toSet(),
          {'oobe', 'shortcut', 'windowsterminal'});
    });

    test('has the seven documented keys', () {
      expect(kWslDistributionConfKeys['oobe'],
          ['command', 'defaultUid', 'defaultName']);
      expect(kWslDistributionConfKeys['shortcut'], ['enabled', 'icon']);
      expect(kWslDistributionConfKeys['windowsterminal'],
          ['enabled', 'profileTemplate']);
    });

    test('both documented booleans default to on', () {
      expect(kWslDistributionConfBoolDefaults['shortcut-enabled'], true);
      expect(kWslDistributionConfBoolDefaults['windowsterminal-enabled'], true);
    });

    test('reads /etc/wsl-distribution.conf', () {
      expect(kWslDistributionConfPath, '/etc/wsl-distribution.conf');
    });
  });

  group('parsing', () {
    test('reads the sample file from build-custom-distro.md', () {
      final conf = WslDistributionConfFile.parse('''# /etc/wsl-distribution.conf

[oobe]
command = /etc/oobe.sh
defaultUid = 1000
defaultName = my-distro

[shortcut]
enabled = true
icon = /usr/lib/wsl/my-icon.ico

[windowsterminal]
enabled = true
ProfileTemplate = /usr/lib/wsl/terminal-profile.json
''');

      expect(conf.get('oobe', 'command'), '/etc/oobe.sh');
      expect(conf.get('oobe', 'defaultUid'), '1000');
      expect(conf.get('oobe', 'defaultName'), 'my-distro');
      expect(conf.get('shortcut', 'enabled'), 'true');
      expect(conf.get('shortcut', 'icon'), '/usr/lib/wsl/my-icon.ico');
      expect(conf.get('windowsterminal', 'enabled'), 'true');
    });

    /// The doc's own sample writes `ProfileTemplate` while its reference table
    /// writes `profileTemplate`. Both have to reach the widget, or a file
    /// copied out of the documentation populates a key nothing renders.
    test('ProfileTemplate and profileTemplate are the same key', () {
      final conf = WslDistributionConfFile.parse(
          '[windowsterminal]\nProfileTemplate = /a.json\n');

      expect(conf.get('windowsterminal', 'profileTemplate'), '/a.json');
      expect(conf.get('WINDOWSTERMINAL', 'PROFILETEMPLATE'), '/a.json');
    });

    test('absent is not the same as empty', () {
      final conf = WslDistributionConfFile.parse('[oobe]\ndefaultName =\n');

      expect(conf.get('oobe', 'defaultName'), '');
      expect(conf.contains('oobe', 'defaultName'), true);
      expect(conf.get('oobe', 'command'), isNull);
      expect(conf.contains('oobe', 'command'), false);
    });

    test('an empty file is an empty config, not an error', () {
      expect(WslDistributionConfFile.empty().toMap(), isEmpty);
      expect(WslDistributionConfFile.parse('').toMap(), isEmpty);
    });

    test('shortcut.enabled and windowsterminal.enabled stay distinct', () {
      final conf = WslDistributionConfFile.parse(
          '[shortcut]\nenabled = false\n\n[windowsterminal]\nenabled = true\n');

      expect(conf.get('shortcut', 'enabled'), 'false');
      expect(conf.get('windowsterminal', 'enabled'), 'true');
    });
  });

  group('writing', () {
    test('a new key lands in its own section, not at the end of the file', () {
      final conf = WslDistributionConfFile.parse(
          '[oobe]\ncommand = /etc/oobe.sh\n\n[shortcut]\nenabled = true\n');
      conf.set('oobe', 'defaultUid', '1000');

      expect(conf.serialize(), '''[oobe]
command = /etc/oobe.sh
defaultUid = 1000

[shortcut]
enabled = true
''');
    });

    test('a missing section is created', () {
      final conf = WslDistributionConfFile.empty();
      conf.set('oobe', 'defaultName', 'my-distro');

      expect(conf.serialize(), '[oobe]\ndefaultName = my-distro\n');
    });

    test('comments and unknown keys survive a write', () {
      const source = '''# maintained by hand
[oobe]
; a semicolon comment
command = /etc/oobe.sh
somethingElse = keep me
''';
      final conf = WslDistributionConfFile.parse(source);
      conf.set('oobe', 'defaultUid', '1000');

      expect(conf.serialize(), '''# maintained by hand
[oobe]
; a semicolon comment
command = /etc/oobe.sh
somethingElse = keep me
defaultUid = 1000
''');
    });

    test('an untouched file round-trips byte for byte', () {
      const source = '''#  oddly    spaced
[oobe]
   command    =    /etc/oobe.sh

[shortcut]
enabled=true
''';
      expect(WslDistributionConfFile.parse(source).serialize(), source);
    });

    test('removing a key deletes its line so WSL\'s default applies', () {
      final conf = WslDistributionConfFile.parse(
          '[shortcut]\nenabled = false\nicon = /a.ico\n');

      expect(conf.remove('shortcut', 'enabled'), true);
      expect(conf.serialize(), '[shortcut]\nicon = /a.ico\n');
      expect(conf.get('shortcut', 'enabled'), isNull);
      // Removing a key that is not there is a no-op, not a failure.
      expect(conf.remove('shortcut', 'enabled'), false);
    });

    test('an existing key keeps the spelling the file gave it', () {
      final conf = WslDistributionConfFile.parse(
          '[windowsterminal]\nProfileTemplate = /a.json\n');
      conf.set('windowsterminal', 'profileTemplate', '/b.json');

      // WSL resolves a duplicate key to its first occurrence, so appending a
      // differently-spelled second line would be a line that never wins.
      expect(
          conf.serialize(), '[windowsterminal]\nProfileTemplate = /b.json\n');
    });
  });

  /// Values a maintainer really writes. `wsl-distribution.conf` has no
  /// escaping — WSL takes the rest of the line as written — and the writer
  /// never puts a value through a shell, so all of these must survive intact.
  group('awkward values round-trip', () {
    const values = <String>[
      '/usr/lib/wsl/my icon.ico',
      '/etc/oobe.sh --flag=value',
      'bash -c "echo hi"',
      "sh -c 'echo hi'",
      r'/etc/oobe.sh $HOME `id` $(whoami)',
      '/mnt/c/Program Files/wsl/profile.json',
      'a = b = c',
      '100%',
    ];

    for (final value in values) {
      test('"$value"', () {
        final conf = WslDistributionConfFile.empty();
        conf.set('oobe', 'command', value);

        final reparsed = WslDistributionConfFile.parse(conf.serialize());
        expect(reparsed.get('oobe', 'command'), value);
      });
    }
  });

  group('canonicalisation helpers', () {
    test('normalise a known section and key', () {
      expect(canonicalDistributionConfSection('OOBE'), 'oobe');
      expect(canonicalDistributionConfKey('oobe', 'DEFAULTUID'), 'defaultUid');
      expect(canonicalDistributionConfKey('windowsterminal', 'profiletemplate'),
          'profileTemplate');
    });

    test('leave an unknown section and key as written', () {
      expect(canonicalDistributionConfSection('Nonsense'), 'Nonsense');
      expect(canonicalDistributionConfKey('oobe', 'Nonsense'), 'Nonsense');
    });
  });
}
