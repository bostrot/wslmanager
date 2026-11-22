/// Tests for lib/api/wslconfig.dart and the shared model beneath it — the
/// `%UserProfile%\.wslconfig` engine that replaced `WSLApi.readConfig` /
/// `setConfig` / `writeConfig`.
///
/// Every group below pins one of the defects recorded in
/// doc/audit/wsl-docs/wslconfig-keys.md, so a regression names itself. Two of
/// them — CC-11 and CC-5's write half — were the ones the audit explicitly
/// recorded as *"read from the source, never reproduced"*, and they are
/// reproduced here first.
// ignore_for_file: dangling_library_doc_comments

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/wslconfig.dart';

void main() {
  group('the reference tables are complete', () {
    test('27 documented keys, 20 + 7', () {
      expect(kWslConfigWsl2Keys.length, 20);
      expect(kWslConfigExperimentalKeys.length, 7);
    });

    test('no key name is shared between the two sections', () {
      final wsl2 = kWslConfigWsl2Keys.map((k) => k.toLowerCase()).toSet();
      final experimental =
          kWslConfigExperimentalKeys.map((k) => k.toLowerCase()).toSet();
      expect(wsl2.intersection(experimental), isEmpty);
    });

    test('every experimental key resolves to [experimental]', () {
      final config = WslConfigFile.empty();
      for (final key in kWslConfigExperimentalKeys) {
        expect(config.sectionFor(key), 'experimental', reason: key);
      }
      for (final key in kWslConfigWsl2Keys) {
        expect(config.sectionFor(key), 'wsl2', reason: key);
      }
    });

    test('the seven documented-true booleans are recorded as such', () {
      // Audit CC-1: every one of these rendered off when the key was absent.
      const documentedTrue = <String>[
        'localhostForwarding',
        'guiApplications',
        'nestedVirtualization',
        'dnsProxy',
        'firewall',
        'dnsTunneling',
        'autoProxy',
      ];
      for (final key in documentedTrue) {
        expect(kWslConfigBoolDefaults[key], true, reason: key);
      }
      expect(kWslConfigBoolDefaults.values.where((v) => v).length,
          documentedTrue.length);
    });
  });

  /// Audit CC-3 / runtime R-4. `readConfig` flattened the whole file into one
  /// map and `setConfig` rewrote a key wherever it appeared. Relocating an
  /// `[experimental]` key into `[wsl2]` is not untidy — WSL rejects it there
  /// and boots with the setting off, saying so only on stderr.
  group('sections (CC-3, R-4)', () {
    const both = '[wsl2]\nmemory = 8GB\n\n[experimental]\nsparseVhd = true\n';

    test('a key is read from the section it is in', () {
      final config = WslConfigFile.parse(both);
      expect(config.get('wsl2', 'memory'), '8GB');
      expect(config.get('experimental', 'sparseVhd'), 'true');
      expect(config.get('wsl2', 'sparseVhd'), isNull);
    });

    test('an experimental key is written back to [experimental]', () {
      final config = WslConfigFile.parse('[wsl2]\nmemory = 8GB\n');
      config.set(config.sectionFor('autoMemoryReclaim'), 'autoMemoryReclaim',
          'gradual');
      expect(config.serialize(),
          '[wsl2]\nmemory = 8GB\n\n[experimental]\nautoMemoryReclaim = gradual\n');
    });

    test('a key filed by hand in an unusual section is edited where it is', () {
      // sectionOf beats the documented table, so a hand-placed key is not
      // duplicated into a second section.
      final config =
          WslConfigFile.parse('[experimental]\nlocalhostForwarding = false\n');
      expect(config.sectionFor('localhostForwarding'), 'experimental');
      config.set(config.sectionFor('localhostForwarding'),
          'localhostForwarding', 'true');
      expect(
          config.serialize(), '[experimental]\nlocalhostForwarding = true\n');
    });

    test('writing one section leaves the other untouched', () {
      final config = WslConfigFile.parse(both);
      config.set('experimental', 'sparseVhd', 'false');
      expect(config.serialize(),
          '[wsl2]\nmemory = 8GB\n\n[experimental]\nsparseVhd = false\n');
    });

    test('a key in an unknown section is left out of flatten()', () {
      // …and therefore never gets a controller that would write it somewhere
      // else on the next Save.
      final config =
          WslConfigFile.parse('[wsl2]\nmemory = 8GB\n\n[future]\nthing = 1\n');
      expect(config.flatten(), {'memory': '8GB'});
      expect(
          config.serialize(), '[wsl2]\nmemory = 8GB\n\n[future]\nthing = 1\n');
    });
  });

  /// Audit CC-4 / runtime R-8. The old regex was built from the camelCase
  /// spelling with no `caseSensitive: false`, so a lower-case line was never
  /// matched and Save appended a duplicate — which WSL resolves to the *first*
  /// occurrence, making the user's edit a silent no-op forever.
  group('case-insensitive matching (CC-4, R-8)', () {
    test("the docs' own lower-case example file is read correctly", () {
      final config =
          WslConfigFile.parse('[wsl2]\nswapfile = C:\\\\Temp\\\\swap.vhdx\n'
              'localhostforwarding = false\n');
      expect(config.get('wsl2', 'swapFile'), 'C:\\Temp\\swap.vhdx');
      expect(config.get('wsl2', 'localhostForwarding'), 'false');
      expect(config.flatten()['swapFile'], 'C:\\Temp\\swap.vhdx');
    });

    test('an update edits the lower-case line rather than appending', () {
      final config = WslConfigFile.parse('[wsl2]\nswapfile = a.vhdx\n');
      config.set('wsl2', 'swapFile', 'b.vhdx');
      expect(config.serialize(), '[wsl2]\nswapfile = b.vhdx\n');
      // The duplicate that used to be appended, and used to lose.
      expect('swapFile ='.allMatches(config.serialize()).length, 0);
    });

    test('a lower-case section header matches too', () {
      final config = WslConfigFile.parse('[WSL2]\nMEMORY = 4GB\n');
      expect(config.get('wsl2', 'memory'), '4GB');
    });
  });

  /// Audit CC-2. `value.replaceAll(' ', '')` mangled every value with an
  /// internal space, and the mangled form was written back on the next Save.
  group('values keep their spaces (CC-2)', () {
    test('kernelCommandLine survives a round trip', () {
      const line = 'console=ttyS0 nokaslr systemd.unified_cgroup_hierarchy=1';
      final config = WslConfigFile.parse('[wsl2]\nkernelCommandLine = $line\n');
      expect(config.get('wsl2', 'kernelCommandLine'), line);

      config.set('wsl2', 'kernelCommandLine', line);
      expect(
          WslConfigFile.parse(config.serialize())
              .get('wsl2', 'kernelCommandLine'),
          line);
    });

    test('a path under C:\\Program Files keeps its space', () {
      final config = WslConfigFile.empty();
      config.set('wsl2', 'kernel', r'C:\Program Files\WSL\kernel');
      expect(WslConfigFile.parse(config.serialize()).get('wsl2', 'kernel'),
          r'C:\Program Files\WSL\kernel');
    });
  });

  /// Audit CC-10 / runtime R-6. `swapFile=C:\Temp\x.vhdx` is
  /// `wsl: Ungültiges Escapezeichen` and the whole line is discarded, so every
  /// value `kernelModules`' file picker could produce was a dead line.
  group('path escaping (CC-10, R-6)', () {
    test('a picked Windows path is written with doubled backslashes', () {
      final config = WslConfigFile.empty();
      config.set('wsl2', 'kernelModules', r'C:\Temp\modules.vhdx');
      expect(config.serialize(),
          '[wsl2]\r\nkernelModules = C:\\\\Temp\\\\modules.vhdx\r\n');
    });

    test('and read back as the path the user picked', () {
      final config =
          WslConfigFile.parse('[wsl2]\nswapFile = C:\\\\Temp\\\\swap.vhdx\n');
      expect(config.get('wsl2', 'swapFile'), r'C:\Temp\swap.vhdx');
    });

    test('the escaping is idempotent across a round trip', () {
      final config = WslConfigFile.empty();
      config.set('wsl2', 'kernel', r'C:\a\b');
      final reread = WslConfigFile.parse(config.serialize());
      reread.set('wsl2', 'kernel', reread.get('wsl2', 'kernel')!);
      expect(reread.serialize(), config.serialize());
    });

    test('a broken single-backslash line is repaired by rewriting it', () {
      // The form the old writer produced. Reading it leniently gives the value
      // the user meant; writing it back escapes it, so the next Save fixes the
      // line WSL was throwing away.
      final config =
          WslConfigFile.parse('[wsl2]\nswapFile = C:\\Temp\\swap.vhdx\n');
      expect(config.get('wsl2', 'swapFile'), r'C:\Temp\swap.vhdx');
      config.set('wsl2', 'swapFile', config.get('wsl2', 'swapFile')!);
      expect(
          config.serialize(), '[wsl2]\nswapFile = C:\\\\Temp\\\\swap.vhdx\n');
    });

    test('only the three documented path keys are escaped', () {
      final config = WslConfigFile.empty();
      config.set('wsl2', 'kernelCommandLine', r'a\b');
      expect(config.serialize(), '[wsl2]\r\nkernelCommandLine = a\\b\r\n');
      expect(kWslConfigPathKeys, ['kernel', 'kernelModules', 'swapFile']);
    });
  });

  /// Audit CC-5 / coverage-sweep S-3 / runtime R-7. The read side turned
  /// `# memory = 8GB` into a key named `#memory`; the write side's unanchored
  /// regex let that same comment absorb the write, so the line stayed commented
  /// out and the app reported the save as done.
  group('comments (CC-5, S-3, R-7)', () {
    test('a commented-out key is not a key', () {
      final config = WslConfigFile.parse('[wsl2]\n# memory = 8GB\n');
      expect(config.get('wsl2', 'memory'), isNull);
      expect(config.flatten(), isEmpty);
    });

    test('writing the key adds a real line and leaves the comment alone', () {
      final config = WslConfigFile.parse('[wsl2]\n#memory=8GB\n');
      config.set('wsl2', 'memory', '4GB');
      expect(config.serialize(), '[wsl2]\n#memory=8GB\nmemory = 4GB\n');
    });

    test('a `;` line is preserved but never treated as a comment key', () {
      // R-7: WSL rejects `;` with "Ungültiger Schlüsselname", so the app must
      // not quietly support it — but it must not eat the line either.
      const original = '[wsl2]\n;memory=8GB\nmemory = 4GB\n';
      final config = WslConfigFile.parse(original);
      expect(config.get('wsl2', 'memory'), '4GB');
      expect(config.serialize(), original);
    });
  });

  /// Audit CC-11 / coverage-sweep S-2. `setConfig` had three branches and no
  /// fourth: a key could be added and changed but never removed, so "unset —
  /// use the documented default" had nowhere to be written. This is the finding
  /// that blocked the tri-state toggles.
  group('removing a key (CC-11)', () {
    test('removing deletes the line and nothing else', () {
      final config =
          WslConfigFile.parse('# mine\n[wsl2]\nmemory = 8GB\nprocessors = 4\n');
      expect(config.remove('wsl2', 'memory'), true);
      expect(config.serialize(), '# mine\n[wsl2]\nprocessors = 4\n');
    });

    test('removing a key that is not there reports nothing happened', () {
      final config = WslConfigFile.parse('[wsl2]\nmemory = 8GB\n');
      expect(config.remove('wsl2', 'swap'), false);
      expect(config.serialize(), '[wsl2]\nmemory = 8GB\n');
    });

    test('removal is case-insensitive like everything else', () {
      final config = WslConfigFile.parse('[wsl2]\nSWAPFILE = a.vhdx\n');
      expect(config.remove('wsl2', 'swapFile'), true);
      expect(config.serialize(), '[wsl2]\n');
    });

    test('absent and empty are different answers', () {
      final config = WslConfigFile.parse('[wsl2]\nswap =\n');
      expect(config.get('wsl2', 'swap'), '');
      expect(config.contains('wsl2', 'swap'), true);
      expect(config.get('wsl2', 'memory'), isNull);
      expect(config.contains('wsl2', 'memory'), false);
    });
  });

  /// P05-02's own "done when": a hand-edited file survives load → Save
  /// byte-identical apart from the one key the user changed.
  group('preserving what the user wrote', () {
    const original = '# my machine\r\n'
        '\r\n'
        '[wsl2]\r\n'
        'memory=8GB\r\n'
        'kernelCommandLine = console=ttyS0 nokaslr\r\n'
        'someFutureKey = 42\r\n'
        '\r\n'
        '# turned this off in 2024\r\n'
        '#guiApplications=false\r\n'
        '\r\n'
        '[experimental]\r\n'
        'autoMemoryReclaim = gradual\r\n';

    test('a file nothing touched comes back byte for byte', () {
      expect(WslConfigFile.parse(original).serialize(), original);
    });

    test('only the edited line changes', () {
      final config = WslConfigFile.parse(original);
      config.set('wsl2', 'memory', '4GB');
      expect(config.serialize(),
          original.replaceFirst('memory=8GB', 'memory = 4GB'));
    });

    test('CRLF is preserved, and an LF file stays LF', () {
      expect(WslConfigFile.parse(original).serialize(), contains('\r\n'));
      const lf = '[wsl2]\nmemory = 8GB\n';
      final config = WslConfigFile.parse(lf);
      config.set('wsl2', 'processors', '4');
      expect(config.serialize(), '[wsl2]\nmemory = 8GB\nprocessors = 4\n');
      expect(config.serialize(), isNot(contains('\r')));
    });

    test('a brand new file is written with Windows line endings', () {
      final config = WslConfigFile.empty();
      config.set('wsl2', 'memory', '8GB');
      expect(config.serialize(), '[wsl2]\r\nmemory = 8GB\r\n');
    });

    test('an empty file is an empty config, not an error', () {
      expect(WslConfigFile.parse('').flatten(), isEmpty);
      expect(WslConfigFile.parse('').serialize(), '');
    });

    test('a key outside any section is left alone', () {
      // WSL ignores it, so the screen must not offer to edit it.
      const stray = 'memory = 8GB\n[wsl2]\nprocessors = 4\n';
      final config = WslConfigFile.parse(stray);
      expect(config.flatten(), {'processors': '4'});
      expect(config.serialize(), stray);
    });
  });

  /// What Save does. The old loop re-emitted every non-empty key into `[wsl2]`
  /// on every press, which is how a hand-added `[experimental]` key was
  /// silently relocated into a section WSL ignores it in (CC-3, R-4), and it
  /// had no branch at all for a key the user cleared (CC-11).
  group('applying the settings screen edits', () {
    const original = '# mine\r\n'
        '[wsl2]\r\n'
        'memory=8GB\r\n'
        'someFutureKey = 42\r\n'
        '\r\n'
        '[experimental]\r\n'
        'autoMemoryReclaim = gradual\r\n';

    test('a Save that changed nothing writes nothing', () {
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      expect(applyWslConfigEdits(config, loaded, Map.of(loaded)), 0);
      expect(config.serialize(), original);
    });

    test('only the edited key moves; the rest of the file is untouched', () {
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      final edits = Map.of(loaded)..['memory'] = '4GB';

      expect(applyWslConfigEdits(config, loaded, edits), 1);
      expect(config.serialize(),
          original.replaceFirst('memory=8GB', 'memory = 4GB'));
      expect(loaded['memory'], '4GB');
    });

    test('an experimental key stays in [experimental] across a Save', () {
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      final edits = Map.of(loaded)..['autoMemoryReclaim'] = 'disabled';

      applyWslConfigEdits(config, loaded, edits);
      expect(config.get('experimental', 'autoMemoryReclaim'), 'disabled');
      expect(config.get('wsl2', 'autoMemoryReclaim'), isNull);
    });

    test('an emptied value removes the key — the tri-state third state', () {
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      final edits = Map.of(loaded)..['memory'] = '';

      expect(applyWslConfigEdits(config, loaded, edits), 1);
      expect(config.contains('wsl2', 'memory'), false);
      expect(loaded.containsKey('memory'), false);
      expect(config.serialize(), original.replaceFirst('memory=8GB\r\n', ''));
    });

    test('a new key is added in its documented section', () {
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      final edits = Map.of(loaded)..['sparseVhd'] = 'true';

      expect(applyWslConfigEdits(config, loaded, edits), 1);
      expect(config.get('experimental', 'sparseVhd'), 'true');
    });

    test('a picked path is escaped exactly once', () {
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      final edits = Map.of(loaded)..['kernelModules'] = r'C:\Temp\mods.vhdx';

      applyWslConfigEdits(config, loaded, edits);
      expect(config.serialize(),
          contains('kernelModules = C:\\\\Temp\\\\mods.vhdx'));

      // A second Save with the same value is a no-op, not a second escape.
      expect(applyWslConfigEdits(config, loaded, edits), 0);
      expect(config.serialize(),
          contains('kernelModules = C:\\\\Temp\\\\mods.vhdx'));
      expect(config.serialize(), isNot(contains(r'C:\\\\Temp')));
    });

    test('whitespace around a value is not a change', () {
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      expect(applyWslConfigEdits(config, loaded, {'memory': '  8GB  '}), 0);
    });

    test('a key with no widget is left where the user filed it', () {
      // `someFutureKey` gets a controller because it is in [wsl2], but no
      // widget writes to it, so its value never differs from the loaded one.
      final config = WslConfigFile.parse(original);
      final loaded = config.flatten();
      applyWslConfigEdits(config, loaded, Map.of(loaded));
      expect(config.serialize(), contains('someFutureKey = 42'));
    });
  });

  group('escape helpers', () {
    test('escape doubles every backslash', () {
      expect(escapeWslConfigPath(r'C:\a\b'), r'C:\\a\\b');
      expect(escapeWslConfigPath('no slashes'), 'no slashes');
    });

    test('unescape halves doubled ones and keeps lone ones', () {
      expect(unescapeWslConfigPath(r'C:\\a\\b'), r'C:\a\b');
      expect(unescapeWslConfigPath(r'C:\a\b'), r'C:\a\b');
      expect(unescapeWslConfigPath(r'trailing\\'), 'trailing\\');
    });
  });
}
