/// Widget tests for the `wsl.conf` editor in lib/dialogs/settings_dialog.dart.
///
/// Each group pins one of the findings in doc/audit/wsl-docs/wslconf-keys.md.
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// given — which is exactly what makes CC-4 testable: a control that renders
/// `automountmountfstab-text` is going through i18n, and one that renders
/// `MountFsTab` is not.
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/settings_dialog.dart';

import 'mocks.dart';

const String _distro = 'Ubuntu';

WslConfSetting _setting(String prefKey) =>
    wslConfSettings.firstWhere((s) => s.prefKey == prefKey);

void main() {
  late MockShell mockShell;

  /// The buffer the editor writes into. Since ST-28 nothing reaches the distro
  /// until it is flushed, which is what the dialog's Save button does.
  late WslConfDraft draft;

  Future<void> pump(WidgetTester tester, WslConfSetting setting) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: StatefulBuilder(
          builder: (context, setState) =>
              wslConfField(_distro, setState, setting, draft),
        ),
      ),
    ));
  }

  /// What the dialog's Save button does. Settles afterwards: a fresh
  /// [WSLApi] kicks off the distro-links fetch, whose timer would otherwise
  /// still be pending when the test ends.
  Future<void> save(WidgetTester tester) async {
    await draft.flush(_distro);
    await tester.pumpAndSettle();
  }

  /// How many `printf … | base64 -d > /etc/wsl.conf` the mock has seen.
  int writes() => mockShell.runCommands
      .where((cmd) => cmd.contains('base64 -d > /etc/wsl.conf'))
      .length;

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
    mockShell = MockShell();
    mockShell.wslConfContents = '';
    draft = WslConfDraft();
    wslApiBuilder = () => WSLApi(shell: mockShell);
  });

  tearDown(() => wslApiBuilder = () => WSLApi());

  /// CC-4: `setting.uppercaseFirst()` as the label, no description, no
  /// `.i18n()` call anywhere in either helper.
  group('labels and descriptions (CC-4)', () {
    testWidgets('a toggle names its label and its description', (tester) async {
      await pump(tester, _setting('automount-mountFsTab'));

      expect(find.text('automountmountfstab-text'), findsOneWidget);
      expect(find.text('automountmountfstabinfo-text'), findsOneWidget);
      expect(find.text('MountFsTab'), findsNothing);
    });

    testWidgets('a text box does too, plus a placeholder', (tester) async {
      await pump(tester, _setting('automount-root'));

      expect(find.text('automountroot-text'), findsOneWidget);
      expect(find.text('automountrootinfo-text'), findsOneWidget);
      expect(find.text('Root'), findsNothing);
      expect(tester.widget<TextBox>(find.byType(TextBox)).placeholder, '/mnt/');
    });

    testWidgets('every rendered key builds without a missing string',
        (tester) async {
      for (final setting in wslConfSettings) {
        await pump(tester, setting);
        expect(find.text(setting.labelKey), findsOneWidget,
            reason: '[${setting.section}] ${setting.key}');
        expect(find.text(setting.infoKey), findsOneWidget,
            reason: '[${setting.section}] ${setting.key}');
      }
    });
  });

  /// CC-3: six keys documented `true` rendered off on a distro whose
  /// `wsl.conf` is absent or near-empty, which is most of them.
  group('tri-state booleans (CC-3)', () {
    testWidgets('an unset documented-true key renders on and says it is unset',
        (tester) async {
      await pump(tester, _setting('automount-enabled'));

      expect(
          tester.widget<ToggleSwitch>(find.byType(ToggleSwitch)).checked, true);
      expect(find.text('settingunset-text'), findsOneWidget);
      // Nothing to reset while the key is not in the file.
      expect(find.byIcon(FluentIcons.undo), findsNothing);
    });

    testWidgets('a key set to false renders off, with no unset hint',
        (tester) async {
      await prefs.setBool('$_distro-automount-enabled', false);
      await pump(tester, _setting('automount-enabled'));

      expect(tester.widget<ToggleSwitch>(find.byType(ToggleSwitch)).checked,
          false);
      expect(find.text('settingunset-text'), findsNothing);
      expect(find.byIcon(FluentIcons.undo), findsOneWidget);
    });

    testWidgets('a key with no documented default renders off', (tester) async {
      // [boot] systemd ships on in some images and off in others, so the
      // dialog must not invent a default for it.
      await pump(tester, _setting('boot-systemd'));

      expect(tester.widget<ToggleSwitch>(find.byType(ToggleSwitch)).checked,
          false);
      expect(find.text('settingunset-text'), findsOneWidget);
    });

    testWidgets('toggling writes the key on Save', (tester) async {
      await pump(tester, _setting('gpu-enabled'));
      await tester.tap(find.byType(ToggleSwitch));
      await tester.pumpAndSettle();

      expect(writes(), 0, reason: 'nothing reaches the distro before Save');
      await save(tester);

      expect(mockShell.wslConfContents, '[gpu]\nenabled = false\n');
      expect(prefs.getBool('$_distro-gpu-enabled'), false);
    });

    testWidgets('resetting removes the line so the default applies again',
        (tester) async {
      mockShell.wslConfContents =
          '[automount]\nenabled = false\nroot = /mnt/\n';
      await prefs.setBool('$_distro-automount-enabled', false);
      await pump(tester, _setting('automount-enabled'));

      await tester.tap(find.byIcon(FluentIcons.undo));
      await tester.pumpAndSettle();

      // The switch already reads as the documented default, but the file is
      // untouched until Save.
      expect(
          tester.widget<ToggleSwitch>(find.byType(ToggleSwitch)).checked, true);
      expect(mockShell.wslConfContents,
          '[automount]\nenabled = false\nroot = /mnt/\n');

      await save(tester);

      expect(mockShell.wslConfContents, '[automount]\nroot = /mnt/\n');
      expect(prefs.containsKey('$_distro-automount-enabled'), false);
    });
  });

  /// ST-28: every control used to write to the distro the moment it changed,
  /// so the dialog's Cancel button undid nothing.
  group('Cancel actually cancels (ST-28)', () {
    testWidgets('a toggle flipped and then abandoned never reaches the distro',
        (tester) async {
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';
      await prefs.setBool('$_distro-boot-systemd', true);
      await pump(tester, _setting('boot-systemd'));

      await tester.tap(find.byType(ToggleSwitch));
      await tester.pumpAndSettle();
      expect(draft.isDirty, true);

      // What Cancel does.
      draft.clear();

      expect(writes(), 0);
      expect(mockShell.wslConfContents, '[boot]\nsystemd = true\n');
      expect(prefs.getBool('$_distro-boot-systemd'), true);
    });

    testWidgets('a typed value abandoned never reaches the distro',
        (tester) async {
      await pump(tester, _setting('network-hostname'));

      await tester.enterText(find.byType(TextBox), 'abandoned');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      draft.clear();
      await save(tester);

      expect(writes(), 0);
      expect(prefs.containsKey('$_distro-network-hostname'), false);
    });

    testWidgets('two edits to different keys both survive one Save',
        (tester) async {
      await pump(tester, _setting('network-hostname'));
      await tester.enterText(find.byType(TextBox), 'box');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      await pump(tester, _setting('boot-systemd'));
      await tester.tap(find.byType(ToggleSwitch));
      await tester.pumpAndSettle();

      await save(tester);

      expect(mockShell.wslConfContents,
          '[network]\nhostname = box\n\n[boot]\nsystemd = true\n');
    });
  });

  /// CC-5: `onChanged` ran a full in-distro script execution per character
  /// typed. The debounce still holds; since ST-28 the settled value goes into
  /// the draft and Save is what writes it.
  group('one write per value, not per keystroke (CC-5)', () {
    testWidgets('a twelve-character hostname is written once', (tester) async {
      await pump(tester, _setting('network-hostname'));

      await tester.enterText(find.byType(TextBox), 'my-host-nam');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextBox), 'my-host-name');
      expect(writes(), 0, reason: 'nothing written while still typing');

      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      await save(tester);

      expect(writes(), 1);
      expect(mockShell.wslConfContents, '[network]\nhostname = my-host-name\n');
    });

    testWidgets('leaving the box commits the value to the draft',
        (tester) async {
      await pump(tester, _setting('network-hostname'));

      await tester.enterText(find.byType(TextBox), 'committed');
      // Focus moves away before the debounce would have fired.
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(draft.isDirty, true);
      await save(tester);

      expect(writes(), 1);
      expect(mockShell.wslConfContents, '[network]\nhostname = committed\n');
    });

    testWidgets('emptying the box removes the key rather than blanking it',
        (tester) async {
      mockShell.wslConfContents = '[network]\nhostname = old\n';
      await prefs.setString('$_distro-network-hostname', 'old');
      await pump(tester, _setting('network-hostname'));

      await tester.enterText(find.byType(TextBox), '');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      await save(tester);

      expect(mockShell.wslConfContents, '[network]\n');
      expect(prefs.containsKey('$_distro-network-hostname'), false);
    });

    testWidgets('a value that did not change is not written at all',
        (tester) async {
      await prefs.setString('$_distro-network-hostname', 'same');
      await pump(tester, _setting('network-hostname'));

      await tester.enterText(find.byType(TextBox), 'same');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      await save(tester);

      expect(writes(), 0);
    });
  });

  /// CC-6: `[user] default` was written once at creation and never shown
  /// again, while a lookalike "Start user" box sat above it.
  group('[user] default (CC-6)', () {
    testWidgets('it is editable and writes the wsl.conf key', (tester) async {
      await pump(tester, userDefaultSetting);

      expect(find.text('wsldefaultuser-text'), findsOneWidget);
      expect(find.text('defaultuserinfo-text'), findsOneWidget);

      await tester.enterText(find.byType(TextBox), 'tester');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      await save(tester);

      expect(mockShell.wslConfContents, '[user]\ndefault = tester\n');
    });
  });

  /// The preference clear list: switching distros must not leak a value from
  /// the one opened before.
  group('loadDistroSettings', () {
    testWidgets('clears every rendered key before reading the file',
        (tester) async {
      for (final setting in wslConfSettings) {
        await prefs.setString('$_distro-${setting.prefKey}', 'stale');
      }
      mockShell.wslConfContents = '[boot]\nsystemd = true\n';

      await loadDistroSettings(_distro);

      for (final setting in wslConfSettings) {
        if (setting.prefKey == 'boot-systemd') continue;
        expect(prefs.containsKey('$_distro-${setting.prefKey}'), false,
            reason: '${setting.prefKey} leaked from the previous distro');
      }
      expect(prefs.getBool('$_distro-boot-systemd'), true);
    });

    testWidgets('normalises the file spelling to the widget spelling',
        (tester) async {
      // Audit V-7: `mountfstab = true` used to populate a preference that no
      // widget read, so the toggle rendered off.
      mockShell.wslConfContents = '[automount]\nmountfstab = true\n';

      await loadDistroSettings(_distro);

      expect(prefs.getBool('$_distro-automount-mountFsTab'), true);
    });
  });
}
