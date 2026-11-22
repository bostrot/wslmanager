/// Widget tests for lib/dialogs/file_transfer_dialog.dart
/// (bostrot/ai-tasks#92).
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was given — which is what the label assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/file_transfer_service.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/file_transfer_dialog.dart';

import 'fake_provisioning_backend.dart';

class _StubBackend extends ScriptedBackend {
  _StubBackend() : super(instances: const ['old-ubuntu', 'new-ubuntu']);

  List<String> names = const ['old-ubuntu', 'new-ubuntu'];

  /// Which of [names] are up. Everything, unless a test says otherwise — a
  /// stopped one is offered as a target but labelled as stopped.
  List<String>? running;

  @override
  Future<Instances> list(bool showDocker) async =>
      Instances(names, running ?? names);
}

/// Stands in for the real service: the dialog's job is which folder is shown,
/// what is ticked and where it is sent, not what tar does with it.
class _StubService extends FileTransferService {
  _StubService(VmBackend backend) : super(backend: backend);

  /// Folder path to what it holds. A path that is not here fails the way an
  /// unreadable one does.
  final Map<String, List<InstanceFileEntry>> tree = {
    '/home/eric': const [
      InstanceFileEntry(name: 'projects', isDirectory: true),
      InstanceFileEntry(name: 'notes.txt', isDirectory: false, sizeBytes: 12),
    ],
    '/home/eric/projects': const [
      InstanceFileEntry(name: 'app.dart', isDirectory: false, sizeBytes: 40),
    ],
  };

  String home = '/home/eric';
  final List<String> listed = [];

  /// Holds a transfer open, so a test can look at the dialog mid-run.
  Completer<void>? gate;
  Object? transferFails;

  String? fromDirectory;
  List<String>? sentNames;
  String? toInstance;
  String? toDirectory;
  CancelSignal? sawCancel;
  void Function(TransferStep step)? reporter;

  /// Instances [ensureRunning] reports as needing a start, and the gate that
  /// holds that start open so a test can look at the dialog mid-boot.
  final Set<String> needsStart = <String>{};
  Completer<void>? startGate;
  Object? startFails;
  final List<String> ensured = [];

  @override
  Future<void> ensureRunning(String instance,
      {CancelSignal? cancel, void Function()? onStarting}) async {
    ensured.add(instance);
    if (startFails != null) throw startFails!;
    if (!needsStart.contains(instance)) return;
    onStarting?.call();
    await startGate?.future;
    needsStart.remove(instance);
  }

  @override
  Future<String> homeDirectory(String instance) async => home;

  @override
  Future<List<InstanceFileEntry>> list(String instance, String path) async {
    listed.add(path);
    final entries = tree[path];
    if (entries == null) {
      throw WslFailure(details: 'Could not open $path in $instance.');
    }
    return entries;
  }

  @override
  Future<int> transfer({
    required String sourceInstance,
    required String sourceDirectory,
    required List<String> names,
    required String targetInstance,
    required String targetDirectory,
    CancelSignal? cancel,
    void Function(TransferStep step)? onStep,
  }) async {
    fromDirectory = sourceDirectory;
    sentNames = names;
    toInstance = targetInstance;
    toDirectory = targetDirectory;
    sawCancel = cancel;
    reporter = onStep;
    await gate?.future;
    if (transferFails != null) throw transferFails!;
    return 4096;
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
  });

  tearDown(() => fileTransferServiceBuilder = null);

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: FileTransferDialog(instance: 'old-ubuntu', service: service),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('test-transfer-pick-$name')));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the home folder and lists what it holds',
      (tester) async {
    await pump(tester);

    expect(service.listed, ['/home/eric']);
    expect(find.text('projects'), findsOneWidget);
    expect(find.textContaining('notes.txt'), findsOneWidget);
    // The size belongs to the file, not to the folder.
    expect(find.textContaining('12 B'), findsOneWidget);
  });

  testWidgets('a folder opens by its name and stays pickable by its box',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('test-transfer-pick-projects')));
    await tester.pumpAndSettle();
    expect(service.listed, ['/home/eric']);

    await tester.tap(find.byKey(const ValueKey('test-transfer-open-projects')));
    await tester.pumpAndSettle();

    expect(service.listed, ['/home/eric', '/home/eric/projects']);
    expect(find.textContaining('app.dart'), findsOneWidget);
  });

  testWidgets('navigating clears what was ticked in the folder left behind',
      (tester) async {
    await pump(tester);
    await pick(tester, 'notes.txt');

    await tester.tap(find.byKey(const ValueKey('test-transfer-open-projects')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-transfer-up')));
    await tester.pumpAndSettle();

    final box = tester.widget<Checkbox>(
        find.byKey(const ValueKey('test-transfer-pick-notes.txt')));
    expect(box.checked, isFalse);
  });

  testWidgets('an unreadable folder says so instead of looking empty',
      (tester) async {
    await pump(tester);
    service.tree.remove('/home/eric/projects');

    await tester.tap(find.byKey(const ValueKey('test-transfer-open-projects')));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('test-transfer-list-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-transfer-empty')), findsNothing);
  });

  testWidgets('nothing ticked says so and transfers nothing', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('test-transfer-submit')));
    await tester.pumpAndSettle();

    expect(find.text('transfernothingpicked-text'), findsOneWidget);
    expect(service.sentNames, isNull);
  });

  testWidgets('sends the ticked names to the chosen instance and folder',
      (tester) async {
    await pump(tester);
    await pick(tester, 'notes.txt');
    await pick(tester, 'projects');

    await tester.enterText(
        find.byKey(const ValueKey('test-transfer-destination')), '/root/keep');
    await tester.tap(find.byKey(const ValueKey('test-transfer-submit')));
    await tester.pumpAndSettle();

    expect(service.fromDirectory, '/home/eric');
    expect(service.sentNames, containsAll(['notes.txt', 'projects']));
    // The source instance is never offered as its own destination.
    expect(service.toInstance, 'new-ubuntu');
    expect(service.toDirectory, '/root/keep');
    expect(messages.single, contains('transferdone-text'));
  });

  testWidgets('a half-typed path does not change where the ticks came from',
      (tester) async {
    await pump(tester);
    await pick(tester, 'notes.txt');

    // Typed but never submitted: the list on screen is still /home/eric's.
    await tester.enterText(
        find.byKey(const ValueKey('test-transfer-path')), '/etc');
    await tester.tap(find.byKey(const ValueKey('test-transfer-submit')));
    await tester.pumpAndSettle();

    expect(service.fromDirectory, '/home/eric');
    expect(service.sentNames, ['notes.txt']);
  });

  testWidgets('a failed transfer stays open and says why', (tester) async {
    await pump(tester);
    service.transferFails =
        const WslFailure(details: 'No space left on device');
    await pick(tester, 'notes.txt');

    await tester.tap(find.byKey(const ValueKey('test-transfer-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-transfer-error')), findsOneWidget);
    expect(find.text('No space left on device'), findsOneWidget);
    expect(messages, isEmpty);
  });

  testWidgets('while it runs, Cancel stops the transfer and not the dialog',
      (tester) async {
    await pump(tester);
    service.gate = Completer<void>();
    await pick(tester, 'notes.txt');

    await tester.tap(find.byKey(const ValueKey('test-transfer-submit')));
    await tester.pump();

    expect(find.byKey(const ValueKey('test-transfer-status')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('test-transfer-cancel')));
    await tester.pump();
    expect(service.sawCancel!.isCancelled, isTrue);

    service.gate!.complete();
    await tester.pumpAndSettle();
  });

  // The rework round: a stopped instance, and the progress bar's width.
  testWidgets('the progress bar fills the dialog instead of sitting in a stub',
      (tester) async {
    await pump(tester);
    service.gate = Completer<void>();
    await pick(tester, 'notes.txt');

    await tester.tap(find.byKey(const ValueKey('test-transfer-submit')));
    await tester.pump();

    final bar = tester.getSize(find.byType(ProgressBar));
    final content =
        tester.getSize(find.byKey(const ValueKey('test-transfer-status')));
    // fluent_ui's ProgressBar only sets a *minimum* width (~130), so a bar
    // that was not told to fill would come out far narrower than the text
    // beside it in a 620px dialog.
    expect(bar.width, greaterThan(400.0));
    expect(bar.width, greaterThanOrEqualTo(content.width));

    service.gate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a stopped instance is offered as a target but labelled as one',
      (tester) async {
    backend.names = const ['old-ubuntu', 'new-ubuntu'];
    backend.running = const ['old-ubuntu'];
    await pump(tester);

    expect(find.text('transferstoppedtarget-text'), findsWidgets);
  });

  testWidgets('a running instance is preferred as the default target',
      (tester) async {
    backend.names = const ['old-ubuntu', 'stopped-one', 'running-one'];
    backend.running = const ['old-ubuntu', 'running-one'];
    await pump(tester);

    final combo = tester.widget<ComboBox<String>>(
        find.byKey(const ValueKey('test-transfer-target')));
    expect(combo.value, 'running-one');
  });

  testWidgets('with nothing else running the first target is still offered',
      (tester) async {
    backend.names = const ['old-ubuntu', 'stopped-one'];
    backend.running = const ['old-ubuntu'];
    await pump(tester);

    final combo = tester.widget<ComboBox<String>>(
        find.byKey(const ValueKey('test-transfer-target')));
    expect(combo.value, 'stopped-one');
  });

  testWidgets('a start during a transfer says which instance is starting',
      (tester) async {
    await pump(tester);
    service.gate = Completer<void>();
    await pick(tester, 'notes.txt');

    await tester.tap(find.byKey(const ValueKey('test-transfer-submit')));
    await tester.pump();

    service.reporter!(const TransferStep(
        stage: TransferStage.starting, instance: 'new-ubuntu'));
    await tester.pump();
    expect(find.text('startinginstance-text'), findsOneWidget);

    service.gate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a stopped source is started before its folder is listed',
      (tester) async {
    service.needsStart.add('old-ubuntu');
    service.startGate = Completer<void>();

    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: FileTransferDialog(instance: 'old-ubuntu', service: service),
      ),
    ));
    await tester.pump();

    // Still booting: it says so, and it has not asked for a listing yet.
    expect(find.byKey(const ValueKey('test-transfer-opening-status')),
        findsOneWidget);
    expect(service.listed, isEmpty);
    // An empty target list while still booting is not "there is no other
    // instance"; it is a list that has not been read yet.
    expect(
        find.byKey(const ValueKey('test-transfer-no-targets')), findsNothing);

    service.startGate!.complete();
    await tester.pumpAndSettle();

    expect(service.ensured, contains('old-ubuntu'));
    expect(service.listed, ['/home/eric']);
    expect(find.byKey(const ValueKey('test-transfer-opening-status')),
        findsNothing);
  });

  testWidgets(
      'a source that cannot be started says so instead of looking empty',
      (tester) async {
    service.startFails =
        const WslFailure(details: 'old-ubuntu did not come up in time.');
    await pump(tester);

    expect(find.textContaining('did not come up in time'), findsOneWidget);
    expect(service.listed, isEmpty);
  });

  testWidgets('with no other instance it explains rather than offering one',
      (tester) async {
    backend.names = const ['old-ubuntu'];
    await pump(tester);

    expect(
        find.byKey(const ValueKey('test-transfer-no-targets')), findsOneWidget);
    final submit = tester.widget<FilledButton>(
        find.byKey(const ValueKey('test-transfer-submit')));
    expect(submit.onPressed, isNull);
  });
}
