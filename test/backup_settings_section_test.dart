/// Tests for lib/components/backup_settings_section.dart — the two buttons
/// in Settings that open the backup dialog (bostrot/ai-tasks#89).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/components/backup_settings_section.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  /// What the buttons asked for: one entry per press, true for the restore
  /// side. The dialog itself has its own tests; what matters here is which
  /// side each button opens and whether it opens at all.
  late List<bool> opened;

  setUp(() => opened = <bool>[]);

  /// Pumps the section without the flag the Settings screen passes, so the
  /// preference fallback is the thing under test.
  Future<void> pumpFromPrefs(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: SingleChildScrollView(
          child: BackupSettingsSection(
            onOpen: (context, {required restore}) => opened.add(restore),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, {bool remote = false}) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: SingleChildScrollView(
          child: BackupSettingsSection(
            isRemote: remote,
            onOpen: (context, {required restore}) => opened.add(restore),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('says what the section is for before either button is pressed',
      (tester) async {
    await pump(tester);

    expect(find.text('backupsettingsinfo-text'), findsOneWidget);
    expect(find.byKey(BackupSettingsSection.backupKey), findsOneWidget);
    expect(find.byKey(BackupSettingsSection.restoreKey), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('the backup button opens the backup side', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(BackupSettingsSection.backupKey));
    await tester.pumpAndSettle();

    expect(opened, [false]);
  });

  testWidgets('the restore button opens the restore side — the new-PC case',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(BackupSettingsSection.restoreKey));
    await tester.pumpAndSettle();

    expect(opened, [true]);
  });

  testWidgets('a remote host gets the explanation and two dead buttons',
      (tester) async {
    await pump(tester, remote: true);

    expect(find.byKey(BackupSettingsSection.remoteKey), findsOneWidget);
    expect(find.text('backupremote-text'), findsOneWidget);

    // Still there, so the reason is next to the thing it is about — but
    // pressing either must do nothing, not open a dialog that would write
    // the archives onto the other machine's disk.
    await tester.tap(find.byKey(BackupSettingsSection.backupKey));
    await tester.tap(find.byKey(BackupSettingsSection.restoreKey));
    await tester.pumpAndSettle();

    expect(opened, isEmpty);
    final backup = tester
        .widget<FilledButton>(find.byKey(BackupSettingsSection.backupKey));
    expect(backup.onPressed, isNull);
    final restore =
        tester.widget<Button>(find.byKey(BackupSettingsSection.restoreKey));
    expect(restore.onPressed, isNull);
  });

  testWidgets('a local host is not told about remote hosts', (tester) async {
    await pump(tester);

    expect(find.byKey(BackupSettingsSection.remoteKey), findsNothing);
  });

  testWidgets('without the flag, a configured remote target still disables it',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'UseRemoteWSL': true, 'RemoteWSLTarget': 'user@host'});
    prefs = await SharedPreferences.getInstance();

    await pumpFromPrefs(tester);

    expect(find.byKey(BackupSettingsSection.remoteKey), findsOneWidget);
  });

  testWidgets('without the flag, the switch being off leaves it usable',
      (tester) async {
    // Off, but with a target still saved: the pair is what decides, not the
    // target on its own.
    SharedPreferences.setMockInitialValues(
        {'UseRemoteWSL': false, 'RemoteWSLTarget': 'user@host'});
    prefs = await SharedPreferences.getInstance();

    await pumpFromPrefs(tester);

    expect(find.byKey(BackupSettingsSection.remoteKey), findsNothing);
    await tester.tap(find.byKey(BackupSettingsSection.restoreKey));
    await tester.pumpAndSettle();
    expect(opened, [true]);
  });
}
