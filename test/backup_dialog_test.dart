/// Widget tests for lib/dialogs/backup_dialog.dart (bostrot/ai-tasks#89).
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was given — which is what the label assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/backup_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/backup_dialog.dart';

import 'fake_provisioning_backend.dart';

class _StubBackend extends ScriptedBackend {
  _StubBackend() : super(instances: const ['Ubuntu', 'alpine']);

  bool remote = false;

  @override
  bool get isRemote => remote;

  @override
  Future<Instances> list(bool showDocker) async => Instances(instances, []);
}

/// Stands in for the real service: the dialog's job is which folder, which
/// instances and what it says afterwards, not what wsl.exe does with them.
class _StubService extends BackupService {
  _StubService(VmBackend backend) : super(backend: backend);

  BackupManifest found = const BackupManifest(entries: []);
  BackupOutcome outcome = BackupOutcome();
  final List<BackupStep> steps = [];

  /// Holds a run open, so a test can look at the dialog mid-export.
  Completer<void>? gate;

  String? backedUpTo;
  List<String>? backedUp;
  String? restoredFrom;
  List<String>? restoredOnly;
  String? inspected;

  @override
  Future<BackupOutcome> backup({
    required String directory,
    required List<String> instances,
    CancelSignal? cancel,
    void Function(BackupStep step)? onStep,
  }) async {
    backedUpTo = directory;
    backedUp = instances;
    for (final step in steps) {
      onStep?.call(step);
    }
    await gate?.future;
    return outcome;
  }

  @override
  Future<BackupManifest> inspect(String directory) async {
    inspected = directory;
    return found;
  }

  @override
  Future<BackupOutcome> restore({
    required String directory,
    List<String>? only,
    CancelSignal? cancel,
    void Function(BackupStep step)? onStep,
  }) async {
    restoredFrom = directory;
    restoredOnly = only;
    return outcome;
  }
}

void main() {
  late _StubBackend backend;
  late _StubService service;
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
    backend = _StubBackend();
    service = _StubService(backend);
    backupFolderPicker = () => '/tmp/backups';
  });

  tearDown(() {
    backupFolderPicker = null;
    backupServiceBuilder = null;
  });

  Future<void> pump(WidgetTester tester, {bool restore = false}) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: BackupDialog(restore: restore, service: service),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> browse(WidgetTester tester) async {
    await tester.tap(find.text('choosefolder-text').first);
    await tester.pumpAndSettle();
  }

  group('backing up', () {
    testWidgets('lists every instance, ticked', (tester) async {
      await pump(tester);

      expect(find.text('Ubuntu'), findsOneWidget);
      expect(find.text('alpine'), findsOneWidget);
      final boxes =
          tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes.length, 2);
      expect(boxes.every((box) => box.checked ?? false), true);
    });

    testWidgets('a backup with no folder says so and runs nothing',
        (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-backup-field-error')),
          findsOneWidget);
      expect(find.text('backupnofolder-text'), findsOneWidget);
      expect(service.backedUpTo, isNull);
    });

    testWidgets('an empty selection says so and runs nothing', (tester) async {
      await pump(tester);
      await browse(tester);

      for (final label in ['Ubuntu', 'alpine']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      await tester.pumpAndSettle();

      expect(find.text('backupnoinstances-text'), findsOneWidget);
      expect(service.backedUpTo, isNull);
    });

    testWidgets('backs the ticked instances up to the chosen folder',
        (tester) async {
      service.outcome = BackupOutcome()..succeeded.addAll(['alpine']);
      await pump(tester);
      await browse(tester);

      await tester.tap(find.text('Ubuntu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      await tester.pumpAndSettle();

      expect(service.backedUpTo, '/tmp/backups');
      expect(service.backedUp, ['alpine']);
      expect(messages.single, contains('backupsucceeded-text'));
    });

    testWidgets('what failed is named next to what worked', (tester) async {
      service.outcome = BackupOutcome()
        ..succeeded.add('alpine')
        ..failed['Ubuntu'] = 'the disk is full';
      await pump(tester);
      await browse(tester);

      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-backup-outcome')), findsOneWidget);
      expect(find.textContaining('backupfailedone-text'), findsOneWidget);
    });

    testWidgets('says which instance it is on while it works', (tester) async {
      service.steps.add(const BackupStep(
        instance: 'Ubuntu',
        index: 1,
        total: 2,
        stage: BackupStage.exporting,
      ));
      final gate = Completer<void>();
      service.gate = gate;
      await pump(tester);
      await browse(tester);

      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      // One frame: the run is still going, which is when the line matters.
      await tester.pump();

      expect(find.byKey(const ValueKey('test-backup-status')), findsOneWidget);
      expect(find.textContaining('backupexporting-text'), findsOneWidget);
      // Stop, not Cancel, while a run is going: closing the dialog would
      // leave the export running with nothing to report to.
      expect(find.text('stop-text'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-backup-status')), findsNothing);
    });
  });

  group('restoring', () {
    setUp(() {
      service.found = const BackupManifest(
        entries: [
          BackupEntry(name: 'fedora', file: 'fedora.ext4', bytes: 2048),
          BackupEntry(name: 'Ubuntu', file: 'Ubuntu.ext4', bytes: 4096),
          BackupEntry(name: 'gone', file: 'gone.ext4', missing: true),
        ],
        backend: 'fake',
      );
    });

    testWidgets('an archive already on this machine cannot be ticked',
        (tester) async {
      await pump(tester, restore: true);
      await browse(tester);

      expect(service.inspected, '/tmp/backups');
      expect(find.textContaining('backupalreadyhere-text'), findsOneWidget);
      final boxes =
          tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      // fedora is restorable; the instance that exists here and the archive
      // the folder lost are both dead.
      expect(boxes.where((box) => box.onChanged != null).length, 1);
      expect(boxes.where((box) => box.checked ?? false).length, 1);
    });

    testWidgets('an archive the folder lost says so', (tester) async {
      await pump(tester, restore: true);
      await browse(tester);

      expect(
          find.textContaining('backupmissingarchive-text'), findsOneWidget);
    });

    testWidgets('restores only the ticked archives', (tester) async {
      service.outcome = BackupOutcome()..succeeded.add('fedora');
      await pump(tester, restore: true);
      await browse(tester);

      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      await tester.pumpAndSettle();

      expect(service.restoredFrom, '/tmp/backups');
      expect(service.restoredOnly, ['fedora']);
      expect(messages.single, contains('backuprestored-text'));
    });

    testWidgets('a typed folder is read before the run gives up',
        (tester) async {
      service.outcome = BackupOutcome()..succeeded.add('fedora');
      await pump(tester, restore: true);

      await tester.enterText(
          find.byKey(const ValueKey('test-restore-folder')), '/tmp/typed');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      await tester.pumpAndSettle();

      expect(service.inspected, '/tmp/typed');
      expect(service.restoredFrom, '/tmp/typed');
      expect(service.restoredOnly, ['fedora']);
    });

    testWidgets('retyping the folder drops the old listing', (tester) async {
      await pump(tester, restore: true);
      await browse(tester);
      // The row reads "fedora — <size>", so the name is a fragment of it.
      expect(find.textContaining('fedora'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('test-restore-folder')), '/tmp/other');
      await tester.pumpAndSettle();

      expect(find.textContaining('fedora'), findsNothing);
    });

    testWidgets('a folder from another backend is called out', (tester) async {
      await pump(tester, restore: true);
      await browse(tester);

      expect(find.byKey(const ValueKey('test-restore-foreign-backend')),
          findsOneWidget);
    });

    testWidgets('a folder with no manifest explains where names come from',
        (tester) async {
      service.found = const BackupManifest(
        entries: [BackupEntry(name: 'fedora', file: 'fedora.tar', bytes: 10)],
        fromManifest: false,
      );
      await pump(tester, restore: true);
      await browse(tester);

      expect(find.byKey(const ValueKey('test-restore-no-manifest')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('test-restore-foreign-backend')),
          findsNothing);
    });

    testWidgets('an empty folder says so instead of offering a run',
        (tester) async {
      service.found = const BackupManifest(entries: []);
      await pump(tester, restore: true);
      await browse(tester);

      expect(find.byKey(const ValueKey('test-backup-empty')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('test-backup-submit')));
      await tester.pumpAndSettle();
      expect(service.restoredFrom, isNull);
    });
  });

  testWidgets('a remote host is told it cannot do this here', (tester) async {
    backend.remote = true;
    await pump(tester);

    expect(find.byKey(const ValueKey('test-backup-remote')), findsOneWidget);
    final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('test-backup-submit')));
    expect(submit.onPressed, isNull);
  });

  testWidgets('the mode switch moves between the two sides', (tester) async {
    await pump(tester);

    expect(find.text('backupinfo-text'), findsOneWidget);
    await tester.tap(find.text('restore-text').first);
    await tester.pumpAndSettle();

    expect(find.text('restoreinfo-text'), findsOneWidget);
    expect(find.text('backupinfo-text'), findsNothing);
  });
}
