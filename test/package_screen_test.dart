/// Widget tests for lib/screens/package_screen.dart — the custom-distro
/// distribution surface (doc/audit/wsl-docs/features.md F-8, ordered-list item
/// P05-24).
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// given. That is what makes the label assertions meaningful: a control that
/// renders `oobedefaultname-text` is going through i18n, and one that renders
/// `defaultName` is not.
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/distro_package.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/package_screen.dart';

import 'mocks.dart';

const String _distro = 'Ubuntu';
const String _wsl263 = 'WSL version: 2.6.3.0';
const String _wsl243 = 'WSL version: 2.4.3.0';

void main() {
  late MockShell shell;
  final messages = <String>[];

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
         severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      messages.add(msg.toString());
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    messages.clear();
    shell = MockShell();
    shell.wslVersionOutput = _wsl263;
    shell.distros.add(_distro);
    packagerBuilder = () => DistroPackager(api: WSLApi(shell: shell));
  });

  tearDown(() {
    packagerBuilder = () => DistroPackager();
    packageFilePicker = null;
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const FluentApp(
      home: ScaffoldPage(content: PackagePage()),
    ));
    await tester.pumpAndSettle();
  }

  /// Expander contents are built lazily, so a key inside one is not in the
  /// tree until its header is tapped.
  Future<void> openSection(WidgetTester tester, String headerKey) async {
    await tester.tap(find.text(headerKey));
    await tester.pumpAndSettle();
  }

  group('labels and descriptions', () {
    testWidgets('every documented section has a header', (tester) async {
      await pump(tester);

      for (final label in distributionConfSectionLabels.values) {
        expect(find.text(label), findsOneWidget, reason: '$label is missing');
      }
    });

    testWidgets('each key names its label and its description', (tester) async {
      await pump(tester);
      await openSection(tester, 'oobe-text');

      for (final setting
          in distributionConfSettings.where((s) => s.section == 'oobe')) {
        expect(find.text(setting.labelKey), findsOneWidget);
        expect(find.text(setting.infoKey), findsOneWidget);
      }
      // Never the raw Dart identifier — the mistake wsl.conf CC-4 recorded.
      expect(find.text('defaultName'), findsNothing);
    });
  });

  group('the version gate', () {
    testWidgets('2.4.3 says so and disables the two long-running actions',
        (tester) async {
      shell.wslVersionOutput = _wsl243;
      await pump(tester);

      expect(find.text('requireswsl-text'), findsOneWidget);
      expect(find.text('custompackageunsupported-text'), findsOneWidget);

      final packageButton = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-package-button')));
      expect(packageButton.onPressed, isNull);
    });

    /// 2.4.4 is the documented floor itself (`build-custom-distro.md:16`), so
    /// it is the version the gate has to let through rather than round up.
    testWidgets('2.4.4 exactly is enough', (tester) async {
      shell.wslVersionOutput = 'WSL version: 2.4.4.0';
      await pump(tester);

      expect(find.text('custompackageunsupported-text'), findsNothing);
      final packageButton = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-package-button')));
      expect(packageButton.onPressed, isNotNull);
    });

    /// Disabled is only half of the gate: below the floor `--from-file` is an
    /// invalid option and `--format` is ignored, so nothing may reach wsl.exe
    /// no matter which control is pushed.
    testWidgets('below the floor no packaging command runs', (tester) async {
      shell.wslVersionOutput = _wsl243;
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-package-button')),
          warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(shell.installCalls, isEmpty);
      expect(shell.runCalls.any((call) => call.contains('--export')), false);
    });

    testWidgets('2.6.3 offers them', (tester) async {
      await pump(tester);

      expect(find.text('custompackageunsupported-text'), findsNothing);
      final packageButton = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-package-button')));
      expect(packageButton.onPressed, isNotNull);
    });
  });

  group('the readiness check', () {
    testWidgets('a distro with no distribution config is not ready',
        (tester) async {
      await pump(tester);

      expect(find.text('packagenodefaultname-text'), findsOneWidget);
      expect(find.byKey(const ValueKey('test-package-ready')), findsNothing);
    });

    testWidgets('a complete distro reports ready', (tester) async {
      shell.distributionConfContents = '''[oobe]
command = /etc/oobe.sh
defaultUid = 1000
defaultName = my-distro
''';
      shell.existingDistroFiles.add('/etc/wsl.conf');
      shell.executableDistroFiles.add('/etc/oobe.sh');
      await pump(tester);

      expect(find.byKey(const ValueKey('test-package-ready')), findsOneWidget);
      expect(find.text('packagereadiness-text'), findsOneWidget);
    });
  });

  group('editing the distribution config', () {
    testWidgets('an unset key says so and offers no undo', (tester) async {
      await pump(tester);
      await openSection(tester, 'shortcut-text');

      expect(find.text('settingunset-text'), findsWidgets);
      expect(find.byIcon(FluentIcons.undo), findsNothing);
    });

    /// Both documented booleans default to true, so a switch built from a
    /// missing key must render on — the trap wsl.conf CC-3 recorded.
    testWidgets('an absent boolean renders its documented default',
        (tester) async {
      await pump(tester);
      await openSection(tester, 'shortcut-text');

      final toggle =
          tester.widget<ToggleSwitch>(find.byType(ToggleSwitch).first);
      expect(toggle.checked, true);
    });

    testWidgets('toggling a key writes it and the undo appears',
        (tester) async {
      await pump(tester);
      await openSection(tester, 'shortcut-text');

      await tester.tap(find.byType(ToggleSwitch).first);
      await tester.pumpAndSettle();

      expect(shell.distributionConfContents, contains('[shortcut]'));
      expect(shell.distributionConfContents, contains('enabled = false'));
      expect(find.byIcon(FluentIcons.undo), findsOneWidget);
    });

    testWidgets('the undo removes the line rather than writing the default',
        (tester) async {
      shell.distributionConfContents =
          '[shortcut]\nenabled = false\nicon = /a.ico\n';
      await pump(tester);
      await openSection(tester, 'shortcut-text');

      await tester.tap(find.byIcon(FluentIcons.undo).first);
      await tester.pumpAndSettle();

      expect(shell.distributionConfContents, isNot(contains('enabled')));
      expect(shell.distributionConfContents, contains('icon = /a.ico'));
    });

    testWidgets('a text key commits once, not once per keystroke',
        (tester) async {
      await pump(tester);
      await openSection(tester, 'oobe-text');

      await tester.enterText(find.byType(TextBox).first, 'my-distro');
      await tester.pump(const Duration(milliseconds: 300));
      // Still inside the debounce window: nothing written yet.
      expect(shell.distributionConfContents, isNull);

      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      expect(
          shell.distributionConfContents, contains('defaultName = my-distro'));
      final writes = shell.runCommands
          .where((c) => c.contains('base64 -d > /etc/wsl-distribution.conf'))
          .length;
      expect(writes, 1);
    });

    testWidgets('emptying a text key removes it', (tester) async {
      shell.distributionConfContents =
          '[oobe]\ndefaultName = my-distro\ncommand = /etc/oobe.sh\n';
      await pump(tester);
      await openSection(tester, 'oobe-text');

      await tester.enterText(find.byType(TextBox).first, '');
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();

      expect(shell.distributionConfContents, isNot(contains('defaultName')));
      expect(
          shell.distributionConfContents, contains('command = /etc/oobe.sh'));
    });

    testWidgets('an unreachable distro is reported, not silently empty',
        (tester) async {
      shell.simulateWslConfUnreachable = true;
      await pump(tester);

      expect(find.text('distrounreachable-text'), findsOneWidget);
      expect(find.text('oobedefaultname-text'), findsNothing);
    });

    testWidgets('a failed write says so instead of showing the new value',
        (tester) async {
      shell.simulateWslConfReadOnly = true;
      await pump(tester);
      await openSection(tester, 'shortcut-text');

      await tester.tap(find.byType(ToggleSwitch).first);
      await tester.pumpAndSettle();

      expect(messages.any((m) => m.contains('wslconfwritefailed-text')), true);
    });
  });

  group('the sample OOBE script button', () {
    testWidgets('writes the script and points the config at it',
        (tester) async {
      await pump(tester);
      await openSection(tester, 'oobe-text');

      await tester.tap(find.byKey(const ValueKey('test-package-oobe')));
      await tester.pumpAndSettle();

      expect(shell.writtenDistroFiles[kDefaultOobeScriptPath],
          startsWith('#!/bin/bash'));
      expect(shell.distributionConfContents,
          contains('command = $kDefaultOobeScriptPath'));
      expect(shell.distributionConfContents, contains('defaultUid = 1000'));
      expect(messages.any((m) => m.contains('wroteoobescript-text')), true);
    });
  });

  group('packaging', () {
    testWidgets('stops the distro, then exports as tar.gz', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-package-button')));
      await tester.pumpAndSettle();

      final terminate =
          shell.runCalls.indexWhere((c) => c.contains('--terminate'));
      final export = shell.runCalls.indexWhere((c) => c.contains('--export'));
      expect(terminate, isNonNegative);
      expect(export, greaterThan(terminate));
      expect(shell.runCalls[export].contains('tar.gz'), true);
      // `wsl --export <distro> <file> --format tar.gz` — the file is the third
      // argument, not the last one.
      expect(shell.runCalls[export][2].endsWith('.wsl'), true);
      expect(messages.any((m) => m.contains('packaged-text')), true);
    });

    testWidgets('reports a failed export rather than claiming success',
        (tester) async {
      shell.simulateExportFailure = true;
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-package-button')));
      await tester.pumpAndSettle();

      expect(messages.any((m) => m.contains('packagefailed-text')), true);
      expect(messages.any((m) => m.contains('packaged-text')), false);
    });
  });

  group('installing from a file', () {
    testWidgets('the button stays disabled until a file is picked',
        (tester) async {
      await pump(tester);

      var button = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-install-button')));
      expect(button.onPressed, isNull);

      packageFilePicker = () => 'C:\\p\\my.wsl';
      await tester.tap(find.byKey(const ValueKey('test-package-pick')));
      await tester.pumpAndSettle();

      button = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-install-button')));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('runs --install --from-file with the typed name',
        (tester) async {
      packageFilePicker = () => 'C:\\p\\my.wsl';
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-package-pick')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextBox).last, 'MyDistro');
      await tester.tap(find.byKey(const ValueKey('test-install-button')));
      await tester.pumpAndSettle();

      final call = shell.installCalls.single;
      expect(call.sublist(0, 3), ['--install', '--from-file', 'C:\\p\\my.wsl']);
      expect(call[call.indexOf('--name') + 1], 'MyDistro');
      expect(call.contains('--no-launch'), true);
      expect(messages.any((m) => m.contains('installedpackage-text')), true);
    });

    testWidgets('reports wsl.exe refusing the file', (tester) async {
      shell.installFromFileFailure = 'Invalid distribution file';
      packageFilePicker = () => 'C:\\p\\my.wsl';
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-package-pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-install-button')));
      await tester.pumpAndSettle();

      expect(
          messages.any((m) => m.contains('installpackagefailed-text')), true);
    });
  });
}
