/// Tests for the WSL-version surface — lib/api/wsl_version.dart and
/// lib/dialogs/wsl_version_dialog.dart (upstream bostrot/wsl2-distro-manager#103).
///
/// The parsing group is the one that matters. `wsl --list --verbose` is the
/// only place the per-distro version is published and its middle column is
/// localised, so counting columns from the left mis-reads the name on exactly
/// the German host the WSL documentation audit was run on.
///
/// There is no localization delegate in the widget group, so `.i18n()` returns
/// the key it was handed — which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_version.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/wsl_version_dialog.dart';

import 'mocks.dart';

/// What an English wsl.exe prints.
const String _verboseEnglish = '  NAME      STATE           VERSION\n'
    '* Ubuntu    Running         2\n'
    '  Debian    Stopped         1\n';

/// The same table from the German host the audit records. `Wird ausgeführt`
/// is two tokens where `Running` is one, and `Ubuntu 22.04 LTS` is three.
const String _verboseGerman = '  NAME              STATUS           VERSION\n'
    '* Ubuntu 22.04 LTS  Wird ausgeführt  2\n'
    '  Debian            Beendet          1\n';

class _MockPlausible implements Plausible {
  @override
  Future<int> event(
          {String? name,
          String? page,
          Map<String, String>? props,
          String? referrer,
          PlausibleRevenue? revenue,
          bool interactive = true}) async =>
      200;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('parsing wsl --list --verbose', () {
    test('reads name, version and the default marker', () {
      final distros = WslDistroVersion.parseVerbose(_verboseEnglish,
          knownNames: const ['Ubuntu', 'Debian']);

      expect(distros.map((d) => d.name), ['Ubuntu', 'Debian']);
      expect(distros.map((d) => d.version), [2, 1]);
      expect(distros.first.isDefault, isTrue);
      expect(distros.last.isDefault, isFalse);
    });

    test('the header row is not a distro', () {
      final distros = WslDistroVersion.parseVerbose(_verboseEnglish);
      expect(distros.map((d) => d.name), isNot(contains('NAME')));
      expect(distros, hasLength(2));
    });

    /// The point of [knownNames]: a localised state and a name with spaces
    /// both break a left-to-right column count, and the audit host prints
    /// both at once.
    test('a localised state and a name with spaces still parse', () {
      final distros = WslDistroVersion.parseVerbose(_verboseGerman,
          knownNames: const ['Ubuntu 22.04 LTS', 'Debian']);

      expect(distros.map((d) => d.name), ['Ubuntu 22.04 LTS', 'Debian']);
      expect(distros.map((d) => d.version), [2, 1]);
    });

    test('the longest matching name wins', () {
      final distros = WslDistroVersion.parseVerbose(
          '  Ubuntu 22.04  Stopped  2\n',
          knownNames: const ['Ubuntu', 'Ubuntu 22.04']);

      expect(distros.single.name, 'Ubuntu 22.04');
    });

    test('without known names the first token is the name', () {
      final distros = WslDistroVersion.parseVerbose(_verboseEnglish);
      expect(distros.map((d) => d.name), ['Ubuntu', 'Debian']);
    });

    test('blank lines, carriage returns and prose are skipped', () {
      final distros = WslDistroVersion.parseVerbose(
          '\r\n\r\nWindows Subsystem for Linux has no installed distributions.\r\n');
      expect(distros, isEmpty);
    });

    /// `WSLApi.list` strips these from the names it returns, and the service
    /// matches parsed rows against that list — so a BOM surviving on one
    /// side only would report a machine with distros as having none.
    test('a BOM and zero-width characters are stripped, as list() strips them',
        () {
      final distros = WslDistroVersion.parseVerbose(
          '﻿  NAME    STATE    VERSION\n'
          '* Ubuntu​  Running  2\n',
          knownNames: const ['Ubuntu']);

      expect(distros.single.name, 'Ubuntu');
    });

    test('a name repeated by a malformed table is only listed once', () {
      final distros = WslDistroVersion.parseVerbose(
          '  Ubuntu  Running  2\n  Ubuntu  Running  2\n');
      expect(distros, hasLength(1));
    });
  });

  group('the verbs', () {
    late MockShell mockShell;
    late WSLApi api;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mockShell = MockShell();
      api = WSLApi(shell: mockShell);
    });

    test('setDefaultVersion runs wsl --set-default-version', () async {
      final result = await api.setDefaultVersion(2);

      expect(result.ok, isTrue);
      expect(mockShell.versionCalls, [
        ['--set-default-version', '2']
      ]);
    });

    /// Refused here rather than handed to wsl.exe: the answer is a localised
    /// "Invalid command line option", which says nothing about 1 and 2.
    test('setDefaultVersion refuses anything but 1 or 2 without running',
        () async {
      final result = await api.setDefaultVersion(3);

      expect(result.ok, isFalse);
      expect(result.text, contains('1 or 2'));
      expect(mockShell.versionCalls, isEmpty);
    });

    test('a failing wsl.exe comes back as the message it printed', () async {
      mockShell.versionFailure = 'Access is denied.';

      final result = await api.setDefaultVersion(1);

      expect(result.ok, isFalse);
      expect(result.text, 'Access is denied.');
    });
  });

  group('the service', () {
    late MockShell mockShell;
    late WslVersionService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mockShell = MockShell();
      mockShell.distros.addAll(['Ubuntu', 'Debian']);
      mockShell.wslListVerboseOutput = _verboseEnglish;
      mockShell.wslStatusOutput = 'Default Distribution: Ubuntu\n'
          'Default Version: 2\n';
      service = WslVersionService(apiBuilder: () => WSLApi(shell: mockShell));
    });

    test('reports every distro and the default version', () async {
      final snapshot = await service.load();

      expect(snapshot.ok, isTrue);
      expect(snapshot.defaultVersion, 2);
      expect(snapshot.distros.map((d) => d.name), ['Ubuntu', 'Debian']);
    });

    /// Docker Desktop's helper distros are hidden wherever the app hides
    /// them: they are WSL 2 and converting one breaks Docker.
    test('a distro the name list filters out is not offered', () async {
      mockShell.distros.clear();
      mockShell.distros.add('Ubuntu');
      mockShell.wslListVerboseOutput =
          '  NAME                STATE     VERSION\n'
          '* Ubuntu              Running   2\n'
          '  docker-desktop      Running   2\n';

      final snapshot = await service.load();

      expect(snapshot.distros.map((d) => d.name), ['Ubuntu']);
    });

    /// An empty list and a failed probe look identical to a user unless the
    /// difference is carried: "you have no distros" is a very different
    /// sentence from "wsl.exe did not answer".
    test('wsl.exe answering nothing is an error, not an empty machine',
        () async {
      mockShell.wslListVerboseFailure = 'Windows Subsystem for Linux is not '
          'installed.';

      final snapshot = await service.load();

      expect(snapshot.ok, isFalse);
      expect(snapshot.error, contains('not installed'));
      expect(snapshot.distros, isEmpty);
    });

    test('no distros installed is not an error', () async {
      mockShell.distros.clear();
      mockShell.wslListVerboseOutput = '';

      final snapshot = await service.load();

      expect(snapshot.ok, isTrue);
      expect(snapshot.distros, isEmpty);
    });

    test('convert refuses a version WSL does not have', () async {
      final result = await service.convert('Ubuntu', 3);

      expect(result.ok, isFalse);
      expect(mockShell.versionCalls, isEmpty);
    });

    /// `stop` spawns wsl.exe directly and throws when it is missing, unlike
    /// everything else here. A convert that rethrew would leave the dialog's
    /// busy flag set for good, with no message saying why.
    test('a terminate that throws does not sink the conversion', () async {
      mockShell.throwOnTerminate = true;

      final result = await service.convert('Ubuntu', 2);

      expect(result.ok, isTrue);
      expect(mockShell.versionCalls, [
        ['--set-version', 'Ubuntu', '2']
      ]);
    });

    /// The confirmation says the distro is shut down first, so it is —
    /// rather than wsl.exe pulling it down partway through the conversion,
    /// under a user who is still typing in it.
    test('convert terminates the distro, then runs wsl --set-version',
        () async {
      final result = await service.convert('Ubuntu', 1);

      expect(result.ok, isTrue);
      expect(mockShell.versionCalls, [
        ['--set-version', 'Ubuntu', '1']
      ]);
      final terminate = mockShell.runCalls
          .indexWhere((args) => args.join(' ') == '--terminate Ubuntu');
      final convert = mockShell.runCalls
          .indexWhere((args) => args.join(' ') == '--set-version Ubuntu 1');
      expect(terminate, isNonNegative);
      expect(terminate, lessThan(convert));
    });
  });

  group('the dialog', () {
    late MockShell mockShell;

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
      plausible = _MockPlausible();
      mockShell = MockShell();
      mockShell.distros.addAll(['Ubuntu', 'Debian']);
      mockShell.wslListVerboseOutput = _verboseEnglish;
      mockShell.wslStatusOutput = 'Default Version: 2\n';
      wslVersionServiceBuilder =
          () => WslVersionService(apiBuilder: () => WSLApi(shell: mockShell));
    });

    tearDown(() {
      wslVersionServiceBuilder = () => WslVersionService();
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const FluentApp(
        home: ScaffoldPage(content: WslVersionDialogContent()),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('each distro names its version and the one it can move to',
        (tester) async {
      await pump(tester);

      expect(find.text('Ubuntu'), findsOneWidget);
      expect(find.text('Debian'), findsOneWidget);
      // Ubuntu is WSL 2 and the default distro; Debian is WSL 1.
      expect(find.byKey(const ValueKey('test-wsl-convert-Ubuntu')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('test-wsl-convert-Debian')),
          findsOneWidget);
    });

    /// A disk rewrite that starts on one click is the shape audit ST-29 is
    /// about: Move asks first, and this costs the same.
    testWidgets('converting asks before it runs', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-wsl-convert-Debian')));
      await tester.pumpAndSettle();

      expect(find.text('convertwslversionbody-text'), findsOneWidget);
      expect(mockShell.versionCalls, isEmpty);
    });

    testWidgets('confirming converts to the other version', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-wsl-convert-Debian')));
      await tester.pumpAndSettle();
      // The confirmation's submit button, whose label names the target.
      await tester.tap(find.text('converttowsl-text').last);
      await tester.pumpAndSettle();

      expect(mockShell.versionCalls, [
        ['--set-version', 'Debian', '2']
      ]);
    });

    testWidgets('cancelling the confirmation changes nothing', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-wsl-convert-Ubuntu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cancel-text'));
      await tester.pumpAndSettle();

      expect(mockShell.versionCalls, isEmpty);
    });

    /// Driven through `onChanged` rather than the popup: both items render
    /// the same raw i18n key without a delegate, so tapping one of them
    /// cannot say which was tapped.
    testWidgets('the combo shows the default version wsl --status reported',
        (tester) async {
      await pump(tester);

      final combo = tester.widget<ComboBox<int>>(
          find.byKey(const ValueKey('test-wsl-default-version-combo')));
      expect(combo.value, 2);
      expect(combo.items!.map((item) => item.value), [1, 2]);
    });

    testWidgets('the default-version combo writes the chosen version',
        (tester) async {
      await pump(tester);

      tester
          .widget<ComboBox<int>>(
              find.byKey(const ValueKey('test-wsl-default-version-combo')))
          .onChanged!(1);
      await tester.pumpAndSettle();

      expect(mockShell.versionCalls, [
        ['--set-default-version', '1']
      ]);
    });

    /// `wsl --status` not naming a default version is a real state on the
    /// inbox build, and a combo that guesses 2 there is claiming something
    /// wsl.exe never said.
    testWidgets('an unreported default version selects nothing',
        (tester) async {
      mockShell.wslStatusOutput = '';
      await pump(tester);

      final combo = tester.widget<ComboBox<int>>(
          find.byKey(const ValueKey('test-wsl-default-version-combo')));
      expect(combo.value, isNull);
      expect(find.text('wslversionunknown-text'), findsOneWidget);
    });
  });
}
