/// Tests for lib/dialogs/volume_mounts_dialog.dart — the shared-folder editor
/// every instance row and the AI Workspace open (bostrot/ai-tasks#79).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/volume_mounts.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/volume_mounts_dialog.dart';

/// A driver that answers from memory and records what was saved.
class _FakeDriver implements VolumeMountDriver {
  List<VolumeMount> stored = [];
  List<VolumeMount>? saved;
  Object? listError;
  Object? applyError;
  MountApplyResult result = const MountApplyResult(
      timing: MountApplyTiming.now, instanceRunning: true);

  @override
  bool appliesAtNextStart = false;

  @override
  bool windowsHostPaths = false;

  @override
  String? guestRoot;

  @override
  String? guestProblem;

  @override
  Future<List<VolumeMount>> list(String instance) async {
    if (listError != null) throw listError!;
    return List.of(stored);
  }

  @override
  Future<MountApplyResult> apply(
      String instance, List<VolumeMount> mounts) async {
    if (applyError != null) throw applyError!;
    saved = mounts;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> notices = [];
  final List<InfoBarSeverity> severities = [];
  late _FakeDriver driver;

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
      severities.add(severity);
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    notices.clear();
    severities.clear();
    driver = _FakeDriver();
  });

  /// Opens the dialog over a page, the way the app does, so closing it can
  /// be observed.
  Future<void> pumpAndOpen(WidgetTester tester, {bool remote = true}) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = VolumeMountService.withDriver(driver, isRemote: remote);
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Builder(
          builder: (context) => Button(
            child: const Text('open'),
            onPressed: () => showVolumeMountsDialog('ubuntu',
                service: service, context: context),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the instance\'s folders and says when there are none',
      (tester) async {
    await pumpAndOpen(tester);
    expect(find.byKey(const ValueKey('test-mounts-none')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
    await tester.pumpAndSettle();

    driver.stored = [
      const VolumeMount(
          hostPath: '/Users/eric/proj', guestPath: '/mnt/proj', readOnly: true),
    ];
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-mounts-none')), findsNothing);
    expect(find.text('/mnt/proj'), findsOneWidget);
    expect(find.text('/Users/eric/proj'), findsOneWidget);
    expect(find.text('mountsreadonly-text'), findsWidgets);
  });

  testWidgets('the save button is filled and first, Cancel last',
      (tester) async {
    await pumpAndOpen(tester);
    final dialog = find.byType(ContentDialog);
    final actions = tester.widget<ContentDialog>(dialog).actions!;
    expect(actions.first, isA<FilledButton>());
    expect(actions.last, isA<Button>());
    expect(find.text('save-text'), findsOneWidget);
    expect(find.text('cancel-text'), findsOneWidget);
  });

  testWidgets('an invalid entry is refused under the form, not added',
      (tester) async {
    await pumpAndOpen(tester);
    await tester.tap(find.byKey(const ValueKey('test-mounts-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-mounts-field-error')), findsOneWidget);
    expect(find.text('mountshostrequired-text'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('test-mounts-host')), '/Users/eric/proj');
    await tester.enterText(
        find.byKey(const ValueKey('test-mounts-guest')), '/etc');
    await tester.tap(find.byKey(const ValueKey('test-mounts-add')));
    await tester.pumpAndSettle();
    expect(find.text('mountsguestinvalid-text'), findsOneWidget);
    expect(find.byKey(const ValueKey('test-mounts-none')), findsOneWidget);

    // Typing again clears the message.
    await tester.enterText(
        find.byKey(const ValueKey('test-mounts-guest')), '/mnt/proj');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-mounts-field-error')), findsNothing);
  });

  testWidgets('adding, removing and saving hands the whole list to the backend',
      (tester) async {
    driver.stored = [
      const VolumeMount(hostPath: '/Users/eric/old', guestPath: '/mnt/old'),
    ];
    await pumpAndOpen(tester);

    await tester.enterText(
        find.byKey(const ValueKey('test-mounts-host')), '/Users/eric/proj');
    await tester.enterText(
        find.byKey(const ValueKey('test-mounts-guest')), '/mnt/proj');
    await tester.tap(find.byKey(const ValueKey('test-mounts-readonly')));
    await tester.tap(find.byKey(const ValueKey('test-mounts-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-mounts-guest-/mnt/proj')),
        findsOneWidget);
    // The form is empty again for the next one.
    expect(
        tester
            .widget<TextBox>(find.byKey(const ValueKey('test-mounts-host')))
            .controller!
            .text,
        isEmpty);

    // The same mount point twice is refused.
    await tester.enterText(
        find.byKey(const ValueKey('test-mounts-host')), '/Users/eric/other');
    await tester.enterText(
        find.byKey(const ValueKey('test-mounts-guest')), '/mnt/proj');
    await tester.tap(find.byKey(const ValueKey('test-mounts-add')));
    await tester.pumpAndSettle();
    expect(find.text('mountsguestduplicate-text'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('test-mounts-remove-/mnt/old')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-mounts-guest-/mnt/old')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('test-mounts-save')));
    await tester.pumpAndSettle();
    expect(driver.saved, [
      const VolumeMount(
          hostPath: '/Users/eric/proj', guestPath: '/mnt/proj', readOnly: true),
    ]);
    expect(notices, ['mountsapplied-text']);
    expect(severities, [InfoBarSeverity.success]);
    // Saved and closed.
    expect(find.byType(ContentDialog), findsNothing);
  });

  testWidgets('a change that waits for the next start says so',
      (tester) async {
    driver.appliesAtNextStart = true;
    driver.result = const MountApplyResult(
        timing: MountApplyTiming.nextStart, instanceRunning: true);
    await pumpAndOpen(tester);
    expect(find.byKey(const ValueKey('test-mounts-next-start')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('test-mounts-save')));
    await tester.pumpAndSettle();
    expect(notices, ['mountsrestart-text']);

    driver.result = const MountApplyResult(
        timing: MountApplyTiming.nextStart, instanceRunning: false);
    notices.clear();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-mounts-save')));
    await tester.pumpAndSettle();
    expect(notices, ['mountsonstart-text']);
  });

  testWidgets('warnings from the backend reach the user after a save',
      (tester) async {
    driver.result = const MountApplyResult(
        timing: MountApplyTiming.now,
        instanceRunning: true,
        warnings: ['mountsfstabdisabled-text', 'mount: /mnt/x: busy']);
    await pumpAndOpen(tester);
    await tester.tap(find.byKey(const ValueKey('test-mounts-save')));
    await tester.pumpAndSettle();
    expect(notices, [
      'mountsapplied-text',
      'mountsfstabdisabled-text',
      'mountsapplywarning-text',
    ]);
    expect(severities.sublist(1), everyElement(InfoBarSeverity.warning));
  });

  testWidgets('a failed save keeps the dialog open with the reason',
      (tester) async {
    driver.applyError = const VolumeMountException('mountswritefailed-text');
    await pumpAndOpen(tester);
    await tester.tap(find.byKey(const ValueKey('test-mounts-save')));
    await tester.pumpAndSettle();
    expect(find.byType(ContentDialog), findsOneWidget);
    // The service's key is translated, not shown raw (here `.i18n()` is the
    // identity, so the check is that the key survived the error mapping at
    // all — a WslFailure would have kept it, but a real delegate would then
    // have had nothing to translate).
    expect(notices.single, 'mountsfailed-text mountswritefailed-text');
    expect(severities.single, InfoBarSeverity.error);
    // Saving is possible again after the failure.
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('test-mounts-save')))
            .onPressed,
        isNotNull);
  });

  testWidgets('an unreachable instance shows the error instead of a list',
      (tester) async {
    driver.listError = const VolumeMountException('mountsunreachable-text');
    await pumpAndOpen(tester);
    expect(find.byKey(const ValueKey('test-mounts-error')), findsOneWidget);
    expect(find.text('mountsunreachable-text'), findsOneWidget);
    expect(find.byKey(const ValueKey('test-mounts-add')), findsNothing);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('test-mounts-save')))
            .onPressed,
        isNull);
  });

  testWidgets('what the guest reported about its shares is shown',
      (tester) async {
    driver.guestProblem = 'host directory missing: /gone';
    await pumpAndOpen(tester);
    expect(find.byKey(const ValueKey('test-mounts-guest-problem')), findsOneWidget);
    expect(find.text('host directory missing: /gone'), findsOneWidget);
  });

  testWidgets('the folder picker is offered only for a local instance',
      (tester) async {
    await pumpAndOpen(tester, remote: true);
    expect(find.byKey(const ValueKey('test-mounts-browse')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
    await tester.pumpAndSettle();

    await pumpAndOpen(tester, remote: false);
    expect(find.byKey(const ValueKey('test-mounts-browse')), findsOneWidget);
  });
}
