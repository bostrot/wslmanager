/// Tests for lib/api/wsl_conf.dart — the `/etc/wsl.conf` model that replaced
/// the `sed`-based writer in assets/scripts/settings.bash.
///
/// Every group below pins one of the defects recorded in
/// doc/audit/wsl-docs/wslconf-keys.md, so a regression names itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/wsl_conf.dart';

void main() {
  group('parsing', () {
    test('reads every section and key', () {
      final conf = WslConfFile.parse('''
[automount]
enabled = true
options = "metadata,uid=1000,gid=1000,umask=022"

[network]
hostname = MyHost
''');

      expect(conf.toMap(), {
        'automount': {
          'enabled': 'true',
          'options': '"metadata,uid=1000,gid=1000,umask=022"',
        },
        'network': {'hostname': 'MyHost'},
      });
    });

    test('a value keeps everything after the first "="', () {
      final conf = WslConfFile.parse('[boot]\ncommand = a=b c=d\n');
      expect(conf.get('boot', 'command'), 'a=b c=d');
    });

    test('an empty file is an empty config, not an error', () {
      expect(WslConfFile.parse('').toMap(), isEmpty);
      expect(WslConfFile.parse('').serialize(), '');
    });

    test('a key outside any section is left alone', () {
      // WSL ignores it, so the dialog must not offer to edit it.
      final conf = WslConfFile.parse('stray = 1\n[boot]\nsystemd = true\n');
      expect(conf.get('boot', 'stray'), isNull);
      expect(conf.toMap().keys, ['boot']);
      expect(conf.serialize(), 'stray = 1\n[boot]\nsystemd = true\n');
    });

    test('a section with no keys is still reported as present', () {
      expect(WslConfFile.parse('[gpu]\n').toMap(), {'gpu': <String, String>{}});
    });

    test('CRLF is read and written back as LF', () {
      final conf = WslConfFile.parse('[boot]\r\nsystemd = true\r\n');
      expect(conf.get('boot', 'systemd'), 'true');
      expect(conf.serialize(), '[boot]\nsystemd = true\n');
    });

    test('a file with no trailing newline keeps not having one', () {
      expect(WslConfFile.parse('[boot]\nsystemd = true').serialize(),
          '[boot]\nsystemd = true');
    });
  });

  /// Audit V-7: `getWSLConf` keyed its map on the file's spelling while the
  /// widgets read the documented one, so `mountfstab = true` populated a
  /// preference nothing rendered and the toggle showed off.
  group('case-insensitive matching (V-7)', () {
    test('a lower-case key is reported under its documented spelling', () {
      final conf = WslConfFile.parse('[automount]\nmountfstab = true\n');
      expect(conf.toMap()['automount'], {'mountFsTab': 'true'});
      expect(conf.get('automount', 'mountFsTab'), 'true');
    });

    test('a lower-case section header matches too', () {
      final conf = WslConfFile.parse('[BOOT]\nSYSTEMD = true\n');
      expect(conf.get('boot', 'systemd'), 'true');
    });

    test('an update edits the line already there, keeping its spelling', () {
      final conf = WslConfFile.parse('[automount]\nmountfstab = true\n');
      conf.set('automount', 'mountFsTab', 'false');
      expect(conf.serialize(), '[automount]\nmountfstab = false\n');
    });

    test('an unknown key keeps the spelling it was written with', () {
      final conf = WslConfFile.parse('[boot]\nSomeFutureKey = 1\n');
      expect(conf.toMap()['boot'], {'SomeFutureKey': '1'});
    });
  });

  /// Audit CC-1: both the existence test and the `s///g` searched the whole
  /// file, so toggling one `enabled` rewrote the other. `[automount]` and
  /// `[interop]` are the two documented sections that share the key name.
  group('section isolation (CC-1)', () {
    const both = '[automount]\nenabled = true\n\n[interop]\nenabled = true\n';

    test('writing [interop] enabled leaves [automount] enabled alone', () {
      final conf = WslConfFile.parse(both);
      conf.set('interop', 'enabled', 'false');
      expect(conf.serialize(),
          '[automount]\nenabled = true\n\n[interop]\nenabled = false\n');
    });

    test('reading them back gives two independent values', () {
      final conf = WslConfFile.parse(both);
      conf.set('automount', 'enabled', 'false');
      expect(conf.get('automount', 'enabled'), 'false');
      expect(conf.get('interop', 'enabled'), 'true');
    });

    test('removing one leaves the other', () {
      final conf = WslConfFile.parse(both);
      expect(conf.remove('interop', 'enabled'), true);
      expect(conf.get('automount', 'enabled'), 'true');
      expect(conf.get('interop', 'enabled'), isNull);
    });
  });

  /// Audit CC-2 and CC-7: the value was interpolated into a `sed` expression
  /// and into an `echo -e "…"` that ran as root, so a `/` broke the write and
  /// a quote or a `$(…)` was a command. Nothing is templated any more, so the
  /// only requirement left is that the value comes back verbatim.
  group('values that used to break the writer (CC-2, CC-7)', () {
    const hostile = <String, String>{
      'slashes': '/mnt/',
      'command': '/usr/sbin/service docker start',
      'quote': 'my"host',
      'single quote': "it's",
      'backtick': r'`id`',
      'substitution': r'$(id)',
      'spaces': '  padded value  ',
      'equals': 'uid=1000,gid=1000',
      'brackets': '[not a section]',
      'hash': 'value # not a comment',
      'backslash': r'C:\Users\me',
    };

    hostile.forEach((name, value) {
      test('$name survives a write/read round trip', () {
        final conf = WslConfFile.parse('[boot]\nsystemd = true\n');
        conf.set('boot', 'command', value);

        final reread = WslConfFile.parse(conf.serialize());
        expect(reread.get('boot', 'command'), value.trim());
        expect(reread.get('boot', 'systemd'), 'true');
      });
    });

    test("automount.root's documented default round-trips", () {
      // The value the old `sed` turned into `sed: unknown option to 's'`.
      final conf = WslConfFile.parse('[automount]\nenabled = true\n');
      conf.set('automount', 'root', '/mnt/');
      expect(conf.serialize(), '[automount]\nenabled = true\nroot = /mnt/\n');
    });
  });

  group('adding keys', () {
    test('a new key goes after the last key of its section', () {
      final conf = WslConfFile.parse(
          '[boot]\nsystemd = true\n\n[network]\nhostname = a\n');
      conf.set('boot', 'command', 'echo hi');
      expect(conf.serialize(),
          '[boot]\nsystemd = true\ncommand = echo hi\n\n[network]\nhostname = a\n');
    });

    test('a new key in an empty section goes after the header', () {
      final conf = WslConfFile.parse('[gpu]\n\n[boot]\nsystemd = true\n');
      conf.set('gpu', 'enabled', 'false');
      expect(conf.serialize(),
          '[gpu]\nenabled = false\n\n[boot]\nsystemd = true\n');
    });

    test('a missing section is appended with a blank line before it', () {
      final conf = WslConfFile.parse('[boot]\nsystemd = true\n');
      conf.set('time', 'useWindowsTimezone', 'false');
      expect(conf.serialize(),
          '[boot]\nsystemd = true\n\n[time]\nuseWindowsTimezone = false\n');
    });

    test('the first key of an empty file creates its section', () {
      final conf = WslConfFile.parse('');
      conf.set('user', 'default', 'tester');
      expect(conf.serialize(), '[user]\ndefault = tester\n');
    });

    test('a new key is written in its documented spelling', () {
      final conf = WslConfFile.parse('[automount]\nenabled = true\n');
      conf.set('automount', 'mountfstab', 'false');
      expect(conf.serialize(),
          '[automount]\nenabled = true\nmountFsTab = false\n');
    });
  });

  /// Audit CC-11 / P05-04: the third state of the tri-state toggles is a key
  /// that is physically gone, so WSL's own default applies again.
  group('removing keys', () {
    test('removing a key deletes its line and nothing else', () {
      final conf = WslConfFile.parse(
          '# keep me\n[boot]\nsystemd = true\ncommand = echo hi\n');
      expect(conf.remove('boot', 'systemd'), true);
      expect(conf.serialize(), '# keep me\n[boot]\ncommand = echo hi\n');
    });

    test('removing a key that is not there reports nothing happened', () {
      final conf = WslConfFile.parse('[boot]\nsystemd = true\n');
      expect(conf.remove('boot', 'command'), false);
      expect(conf.serialize(), '[boot]\nsystemd = true\n');
    });

    test('an absent key reads as null, an empty one as empty', () {
      final conf = WslConfFile.parse('[network]\nhostname =\n');
      expect(conf.get('network', 'hostname'), '');
      expect(conf.contains('network', 'hostname'), true);
      expect(conf.get('network', 'generateHosts'), isNull);
      expect(conf.contains('network', 'generateHosts'), false);
    });
  });

  group('preserving what the user wrote', () {
    test('comments, blank lines and unknown keys survive an edit', () {
      const original = '''
# my notes
; a semicolon line

[boot]
# why systemd is on
systemd = true
futureKey = 42

[automount]
enabled = true
''';
      final conf = WslConfFile.parse(original);
      conf.set('automount', 'enabled', 'false');

      expect(
          conf.serialize(),
          original.replaceFirst('enabled = true\n', 'enabled = false\n',
              original.indexOf('[automount]')));
    });

    test('a commented-out key is not the key', () {
      // The old writer's unanchored regex let a commented line absorb the
      // write (audit S-3); here the comment stays a comment and the real key
      // is appended.
      final conf = WslConfFile.parse('[boot]\n#systemd = false\n');
      expect(conf.get('boot', 'systemd'), isNull);
      conf.set('boot', 'systemd', 'true');
      expect(conf.serialize(), '[boot]\n#systemd = false\nsystemd = true\n');
    });

    test('a file nothing touched comes back byte for byte', () {
      const original =
          '[boot]\n  systemd   =   true  \n\n[interop]\nenabled=false\n';
      expect(WslConfFile.parse(original).serialize(), original);
    });
  });

  group('canonical spellings', () {
    test('every documented section and key resolves to itself', () {
      kWslConfKeys.forEach((section, keys) {
        expect(canonicalWslConfSection(section.toUpperCase()), section);
        for (final key in keys) {
          expect(canonicalWslConfKey(section, key.toLowerCase()), key);
        }
      });
    });

    test('the table holds all fifteen documented keys', () {
      expect(kWslConfKeys.values.expand((keys) => keys).length, 15);
    });

    test('an unknown section or key passes through trimmed', () {
      expect(canonicalWslConfSection(' whatever '), 'whatever');
      expect(canonicalWslConfKey('boot', ' whatever '), 'whatever');
    });
  });
}
