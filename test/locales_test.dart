import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/wsl_conf.dart';
import 'package:wsl2distromanager/api/wsl_distribution_conf.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/dialogs/settings_dialog.dart';
import 'package:wsl2distromanager/screens/package_screen.dart';

/// A locale without a matching lib/i18n file makes LocalJsonLocalization throw
/// during load, and the failed delegate leaves the app rendering an empty
/// window — so the two lists have to stay in step.
void main() {
  test('every supported locale has a translation file named after it', () {
    for (final locale in supportedLocalesList) {
      final file = File('lib/i18n/${locale.toString()}.json');
      expect(file.existsSync(), true,
          reason: 'missing ${file.path} for locale $locale');
    }
  });

  test('every language option resolves to a shipped translation', () {
    for (final code in languageOptions.keys) {
      expect(File('lib/i18n/$code.json').existsSync(), true,
          reason: 'language option "$code" has no lib/i18n/$code.json');
    }
  });

  test('every translation file is reachable from the supported locales', () {
    final shipped = Directory('lib/i18n')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .map((name) => name.substring(0, name.length - '.json'.length))
        .toSet();
    final supported =
        supportedLocalesList.map((locale) => locale.toString()).toSet();

    expect(shipped.difference(supported), isEmpty,
        reason: 'translation files nothing can select');
  });

  test('all translation files parse and share the English key set', () {
    final english =
        (json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map)
            .keys
            .toSet();

    for (final locale in supportedLocalesList) {
      final file = File('lib/i18n/${locale.toString()}.json');
      final keys = (json.decode(file.readAsStringSync()) as Map).keys.toSet();
      expect(english.difference(keys), isEmpty,
          reason: '${file.path} is missing keys');
    }
  });

  /// `%s` / `%sN` are filled positionally by the localization package, so a
  /// translation that drops or invents one either loses the value it was meant
  /// to show or reads back a raw `%s` in the UI. `%s` and `%s0` are
  /// interchangeable for a single argument, so only the count has to match.
  test('every locale uses as many placeholders as English', () {
    final placeholder = RegExp(r'%s\d?');
    final english =
        json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map;

    for (final locale in supportedLocalesList) {
      final file = File('lib/i18n/${locale.toString()}.json');
      final translated = json.decode(file.readAsStringSync()) as Map;

      for (final key in english.keys) {
        expect(placeholder.allMatches(translated[key] as String).length,
            placeholder.allMatches(english[key] as String).length,
            reason: '${file.path}: "$key" has the wrong placeholder count');
      }
    }
  });

  /// The keys the WSL documentation audit added for the `.wslconfig` and
  /// `wsl.conf` editors (see doc/audit/wsl-docs/). They were written with a
  /// real translation per locale rather than an English fallback, and the
  /// fallback is easy to reintroduce — scripts/add_translation_key.dart copies
  /// English into any locale that is missing a key — so it is worth pinning.
  group('WSL documentation audit i18n keys', () {
    const auditKeys = [
      'settingdefault-text',
      'settingunset-text',
      'settingoutofrange-text',
      'settinginvalidsize-text',
      'settinginvalidnumber-text',
      'defaultuserinfo-text',
      'wslconfrestart-text',
      'terminatedistro-text',
      'deprecatedvalue-text',
      'onlyapplieswhen-text',
      'ignoredinmirrored-text',
      'milliseconds-text',
      'unitexample-text',
      'bootsystemd-text',
      'bootsystemdinfo-text',
      'bootcommand-text',
      'bootcommandinfo-text',
      'automountenabled-text',
      'automountenabledinfo-text',
      'automountmountfstab-text',
      'automountmountfstabinfo-text',
      'automountroot-text',
      'automountrootinfo-text',
      'automountoptions-text',
      'automountoptionsinfo-text',
      'networkgeneratehosts-text',
      'networkgeneratehostsinfo-text',
      'networkgenerateresolvconf-text',
      'networkgenerateresolvconfinfo-text',
      'networkhostname-text',
      'networkhostnameinfo-text',
      'interopenabled-text',
      'interopenabledinfo-text',
      'interopappendwindowspath-text',
      'interopappendwindowspathinfo-text',
      'gpu-text',
      'time-text',
      'user-text',
      'gpuenabled-text',
      'gpuenabledinfo-text',
      'usewindowstimezone-text',
      'usewindowstimezoneinfo-text',
      'protectbinfmt-text',
      'protectbinfmtinfo-text',
      'startuserinfo-text',
      'wslconfwritefailed-text',
      // P05-02, P05-08, P05-15, P05-16, P05-23 — the M-sized surfaces.
      'wslversion-text',
      'wslnotfound-text',
      'wslinbox-text',
      'wslreported-text',
      'updatewsl-text',
      'updatewslwebdownload-text',
      'updatewslwebdownloadinfo-text',
      'updatingwsl-text',
      'wslupdated-text',
      'wslupdatefailed-text',
      'wslconfigwritefailed-text',
      'requireswsl-text',
      'diskusage-text',
      'diskallocated-text',
      'diskallocatedinfo-text',
      'diskused-text',
      'diskusedinfo-text',
      'diskfree-text',
      'diskusageunavailable-text',
      'resizedisk-text',
      'resizediskinfo-text',
      'resizediskinvalid-text',
      'resizingdisk-text',
      'resizeddisk-text',
      'resizediskfailed-text',
      'setsparse-text',
      'setsparseinfo-text',
      'setsparseon-text',
      'setsparseoff-text',
      'settingsparse-text',
      'sparseset-text',
      'sparsefailed-text',
      'movenative-text',
      'movelegacy-text',
      // P05-24 — custom-distro distribution (the audit's one L, features F-8).
      'custompackage-text',
      'custompackageinfo-text',
      'custompackageunsupported-text',
      'distributionconf-text',
      'distributionconfinfo-text',
      'distrounreachable-text',
      'selectdistro-text',
      'oobe-text',
      'oobedefaultname-text',
      'oobedefaultnameinfo-text',
      'oobecommand-text',
      'oobecommandinfo-text',
      'oobedefaultuid-text',
      'oobedefaultuidinfo-text',
      'writeoobescript-text',
      'writeoobescriptinfo-text',
      'writingoobescript-text',
      'wroteoobescript-text',
      'shortcut-text',
      'shortcutenabled-text',
      'shortcutenabledinfo-text',
      'shortcuticon-text',
      'shortcuticoninfo-text',
      'windowsterminal-text',
      'terminalprofileenabled-text',
      'terminalprofileenabledinfo-text',
      'terminalprofiletemplate-text',
      'terminalprofiletemplateinfo-text',
      'packagereadiness-text',
      'packagereadinessinfo-text',
      'packageready-text',
      'packagenodefaultname-text',
      'packageoobenotexecutable-text',
      'packagenooobe-text',
      'packagenouid-text',
      'packageiconformat-text',
      'packagenowslconf-text',
      'packageresolvconf-text',
      'packagedistro-text',
      'packagedistroinfo-text',
      'packageoutput-text',
      'packageformatinfo-text',
      'packagenopath-text',
      'createpackage-text',
      'packaging-text',
      'packaged-text',
      'packagefailed-text',
      'installfromfile-text',
      'installfromfileinfo-text',
      'packagenofile-text',
      'installpackage-text',
      'installingpackage-text',
      'installedpackage-text',
      'installpackagefailed-text',
    ];

    test('are present and non-empty in every locale', () {
      for (final locale in supportedLocalesList) {
        final file = File('lib/i18n/${locale.toString()}.json');
        final translated = json.decode(file.readAsStringSync()) as Map;

        for (final key in auditKeys) {
          expect(translated[key], isA<String>(),
              reason: '${file.path} is missing "$key"');
          expect((translated[key] as String).trim(), isNotEmpty,
              reason: '${file.path}: "$key" is blank');
        }
      }
    });

    test('are translated, not copied from English', () {
      final english =
          json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map;

      for (final locale in supportedLocalesList) {
        if (locale.toString() == 'en') continue;
        final file = File('lib/i18n/${locale.toString()}.json');
        final translated = json.decode(file.readAsStringSync()) as Map;

        for (final key in auditKeys) {
          // Short labels can legitimately be identical — "GPU" is "GPU"
          // everywhere. A sentence that matches English is a fallback.
          if ((english[key] as String).length <= 20) continue;
          expect(translated[key], isNot(english[key]),
              reason: '${file.path}: "$key" is still the English string');
        }
      }
    });
  });

  /// The distro settings dialog used to label its controls with the Dart
  /// identifier — `"MountFsTab"` — and carried no `.i18n()` call at all
  /// (doc/audit/wsl-docs/wslconf-keys.md CC-4). Every key it renders now names
  /// two strings, and a key added without them would silently render its i18n
  /// key as the label.
  group('wsl.conf dialog strings', () {
    test('every rendered key has a label and a description in English', () {
      final english =
          json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map;

      for (final setting in wslConfSettings) {
        for (final key in [setting.labelKey, setting.infoKey]) {
          expect(english[key], isA<String>(),
              reason:
                  '[${setting.section}] ${setting.key} → "$key" is missing');
          expect((english[key] as String).trim(), isNotEmpty,
              reason: '[${setting.section}] ${setting.key} → "$key" is empty');
        }
      }
    });

    test('every section header has one too', () {
      final english =
          json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map;

      for (final label in wslConfSectionLabels.values) {
        expect(english[label], isA<String>(), reason: '"$label" is missing');
      }
    });

    test('the dialog renders all fifteen documented keys', () {
      // Fourteen in the Expanders plus [user] default, which sits next to the
      // "Start user" box instead.
      expect(wslConfSettings.length, 15);

      for (final section in kWslConfKeys.entries) {
        for (final key in section.value) {
          expect(
              wslConfSettings
                  .any((s) => s.section == section.key && s.key == key),
              true,
              reason: '[${section.key}] $key has no widget');
        }
      }
    });

    test('every section except [user] has an Expander', () {
      expect(wslConfSectionLabels.keys.toSet()..add('user'),
          kWslConfKeys.keys.toSet());
    });

    test('the six documented-true toggles carry their default', () {
      // Audit CC-3: these all rendered off on a distro whose wsl.conf is
      // absent, which is most of them.
      const documentedTrue = [
        'automount-enabled',
        'automount-mountFsTab',
        'network-generateHosts',
        'network-generateResolvConf',
        'interop-enabled',
        'interop-appendWindowsPath',
      ];
      for (final prefKey in documentedTrue) {
        final setting = wslConfSettings.firstWhere((s) => s.prefKey == prefKey);
        expect(setting.defaultOn, true, reason: '$prefKey defaults to on');
      }

      // [boot] systemd is the exception: its default is whatever the distro
      // image ships, so it must not claim one.
      expect(
          wslConfSettings
              .firstWhere((s) => s.prefKey == 'boot-systemd')
              .defaultOn,
          isNull);
    });
  });

  /// The same guarantee for the `wsl-distribution.conf` editor added by
  /// P05-24: a key rendered without a label and a description shows its own
  /// i18n key in the UI.
  group('wsl-distribution.conf editor strings', () {
    test('every rendered key has a label and a description in English', () {
      final english =
          json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map;

      for (final setting in distributionConfSettings) {
        for (final key in [setting.labelKey, setting.infoKey]) {
          expect(english[key], isA<String>(),
              reason:
                  '[${setting.section}] ${setting.key} → "$key" is missing');
          expect((english[key] as String).trim(), isNotEmpty,
              reason: '[${setting.section}] ${setting.key} → "$key" is empty');
        }
      }
    });

    test('every section header has one too', () {
      final english =
          json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map;

      for (final label in distributionConfSectionLabels.values) {
        expect(english[label], isA<String>(), reason: '"$label" is missing');
      }
    });

    test('the editor renders all seven documented keys', () {
      expect(distributionConfSettings.length, 7);

      for (final section in kWslDistributionConfKeys.entries) {
        for (final key in section.value) {
          expect(
              distributionConfSettings
                  .any((s) => s.section == section.key && s.key == key),
              true,
              reason: '[${section.key}] $key has no widget');
        }
      }
    });

    test('every documented section has a header', () {
      expect(distributionConfSectionLabels.keys.toSet(),
          kWslDistributionConfKeys.keys.toSet());
    });

    test('both documented booleans default to on', () {
      for (final setting in distributionConfSettings.where((s) => s.isToggle)) {
        expect(setting.defaultOn, true,
            reason: '[${setting.section}] ${setting.key} defaults to on');
      }
    });
  });

  /// The rule above was scoped to the WSL-docs audit keys, which is how a
  /// whole dialog shipped in English in six locales without any gate firing
  /// (audit TL-09, TL-10). This is the same rule over *every* key.
  group('no locale ships English sentences', () {
    /// Values that are legitimately byte-identical to English everywhere:
    /// product names, literal examples and technical placeholders.
    const identicalByDesign = [
      // Paths and address examples are examples, not prose.
      'examplepath-text',
      'exampleunmountpath-text',
      'remote-ssh-target-placeholder-text',
      // Product and feature names (TL-13: "AI Workspace" is a product name —
      // decided, not overlooked).
      'ai-workspace-title',
      'plan-store',
      'turnkeylinux-text',
      'windowsterminal-text',
      'windowsstore-text',
      'githubissue-text',
    ];

    test('every value over 20 characters is translated', () {
      final english =
          json.decode(File('lib/i18n/en.json').readAsStringSync()) as Map;

      for (final locale in supportedLocalesList) {
        if (locale.toString() == 'en') continue;
        final file = File('lib/i18n/${locale.toString()}.json');
        final translated = json.decode(file.readAsStringSync()) as Map;

        for (final key in english.keys) {
          if (identicalByDesign.contains(key)) continue;
          // Short labels can legitimately be identical — "GPU" is "GPU"
          // everywhere. A sentence that matches English is a fallback.
          if ((english[key] as String).length <= 20) continue;
          expect(translated[key], isNot(english[key]),
              reason: '${file.path}: "$key" is still the English string');
        }
      }
    });
  });
}
