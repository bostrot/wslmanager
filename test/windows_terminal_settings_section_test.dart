/// Tests for lib/components/windows_terminal_settings_section.dart — the
/// Settings section behind the Windows Terminal profiles
/// (bostrot/ai-tasks#93, bostrot/wsl2-distro-manager#239).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/windows_terminal_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/windows_terminal_settings_section.dart';

import 'fake_provisioning_backend.dart';

/// The instances the section is shown, and whether they live on this
/// machine at all.
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

  final List<String> notices = [];
  late Directory dir;

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      notices.add(msg);
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    notices.clear();
    dir = Directory.systemTemp.createTempSync('wslm_wt_widget');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  WindowsTerminalService service({
    List<String> instances = const ['Ubuntu'],
    bool remote = false,
  }) =>
      WindowsTerminalService(
        backend: remote ? TerminalBackend.remote() : TerminalBackend(instances),
        fragmentDirectory: dir.path,
        iconPath: '',
        hostIsWindows: true,
      );

  Future<void> pump(WidgetTester tester, WindowsTerminalService s) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: SingleChildScrollView(
          child: WindowsTerminalSettingsSection(service: s),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Taps [key] and lets the service's file work actually run — it touches
  /// dart:io, which the fake clock in a widget test would otherwise hold.
  Future<void> tapAndSettle(WidgetTester tester, Key key) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(key));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  List<Map<String, Object?>> profilesOf(WindowsTerminalService s) => [
        for (final p in (jsonDecode(File(s.fragmentPath).readAsStringSync())
            as Map<String, Object?>)['profiles'] as List)
          p as Map<String, Object?>
      ];

  testWidgets('writing now lists the profiles it wrote', (tester) async {
    final s = service(instances: ['Ubuntu', 'Alpine']);

    await pump(tester, s);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.syncKey);

    expect(File(s.fragmentPath).existsSync(), isTrue);
    expect(notices, contains('windowsterminalwritten-text'));
    expect(find.text('Ubuntu'), findsOneWidget);
    expect(find.text('Alpine'), findsOneWidget);
    expect(find.text('windowsterminalrestart-text'), findsOneWidget,
        reason: 'a profile nobody sees until a restart needs saying so');
  });

  testWidgets('says so instead of writing when nothing changed',
      (tester) async {
    final s = service();

    await pump(tester, s);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.syncKey);
    final stamp = File(s.fragmentPath).lastModifiedSync();
    notices.clear();
    await tapAndSettle(tester, WindowsTerminalSettingsSection.syncKey);

    expect(notices, contains('windowsterminalunchanged-text'));
    expect(File(s.fragmentPath).lastModifiedSync(), stamp);
  });

  testWidgets('removing takes the profiles back out', (tester) async {
    final s = service();

    await pump(tester, s);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.syncKey);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.clearKey);

    expect(File(s.fragmentPath).existsSync(), isFalse);
    expect(notices, contains('windowsterminalcleared-text'));
    expect(find.text('Ubuntu'), findsNothing);
  });

  testWidgets('the switch remembers the choice and writes straight away',
      (tester) async {
    final s = service();

    await pump(tester, s);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.toggleKey);
    addTearDown(s.stopAutoSync);

    expect(prefs.getBool(WindowsTerminalService.prefEnabled), isTrue);
    expect(File(s.fragmentPath).existsSync(), isTrue);
  });

  testWidgets('turning the feature off removes what it wrote', (tester) async {
    final s = service();

    await pump(tester, s);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.toggleKey);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.toggleKey);

    expect(prefs.getBool(WindowsTerminalService.prefEnabled), isFalse);
    expect(File(s.fragmentPath).existsSync(), isFalse);
  });

  testWidgets('unhiding the generated entries rewrites the file',
      (tester) async {
    final s = service();

    await pump(tester, s);
    await tapAndSettle(tester, WindowsTerminalSettingsSection.toggleKey);
    addTearDown(s.stopAutoSync);
    expect(profilesOf(s), hasLength(2));

    await tapAndSettle(tester, WindowsTerminalSettingsSection.hideGeneratedKey);

    expect(prefs.getBool(WindowsTerminalService.prefHideGenerated), isFalse);
    expect(profilesOf(s), hasLength(1),
        reason: 'the entry that hid Windows Terminal\'s own profile is gone');
  });

  testWidgets('a remote host gets the explanation, not the controls',
      (tester) async {
    await pump(tester, service(remote: true));

    expect(find.text('windowsterminalunsupported-text'), findsOneWidget);
    expect(find.byKey(WindowsTerminalSettingsSection.syncKey), findsNothing);
  });
}
