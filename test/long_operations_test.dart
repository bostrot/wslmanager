/// Regression tests for FIX-04 in doc/audit/ui-ux/index.md: the long
/// operations that could not be stopped and whose only progress indicator
/// stood still.
///
/// The findings, and what pins each one here:
///
/// * **CI-14** — Cancel was `onPressed: null` for the whole install. A create
///   now takes a [CancelSignal]; cancelling it stops the download at the
///   socket and never reaches `wsl --import`.
/// * **CI-16** — the status line read `Downloading 100%` for the whole import.
///   `create` now emits a [CreateProgress] whose phase changes to
///   [CreatePhase.importing], so the last thing the UI is told is not a
///   finished download.
/// * **CI-13** — the `passwd` console was spawned and not awaited, and closing
///   it left the account passwordless in silence. [WSLApi.hasPassword] is what
///   the create flow asks afterwards.
/// * **CI-15** — the Create button became a 38 px spinner square. [BusyButton]
///   keeps a label and a floor width.
/// * **ST-36** — the per-distro dialog's spinner was unlabelled and Save was
///   live over settings that had not been read yet.

import 'dart:io';

import 'package:chunked_downloader/chunked_downloader.dart' as cd;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/settings_dialog.dart';

import 'mocks.dart';

/// A download that reports progress in steps, so a cancel can land in the
/// middle of one the way it does against a real multi-GB rootfs.
///
/// [stop] mirrors the package: it breaks the read loop, deletes its own
/// `.tmp`, and `start()` then returns *normally* — which is exactly the shape
/// that made a cancel look like "the server returned an empty file".
class _SteppedDownloader extends MockChunkedDownloader {
  _SteppedDownloader({required this.steps, required this.total});

  final int steps;
  final int total;
  bool stopped = false;

  @override
  void stop() => stopped = true;

  @override
  Future<cd.ChunkedDownloader> start() async {
    for (var i = 1; i <= steps; i++) {
      if (stopped) return this;
      onProgress?.call((total ~/ steps) * i, total, 1024 * 1024);
      await Future<void>.delayed(Duration.zero);
    }
    if (stopped) return this;
    final file = File(saveFilePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(total, 0));
    done = true;
    return this;
  }
}

void main() {
  group('CancelSignal', () {
    test('runs every listener once, however often it is cancelled', () {
      final signal = CancelSignal();
      var calls = 0;
      signal.onCancel(() => calls++);
      signal.cancel();
      signal.cancel();
      expect(calls, 1);
      expect(signal.isCancelled, isTrue);
    });

    test('a listener registered after the fact still runs', () {
      // The window that matters: a worker registers only once it holds the
      // handle it wants to kill, by which time the user may already have
      // pressed Cancel.
      final signal = CancelSignal()..cancel();
      var called = false;
      signal.onCancel(() => called = true);
      expect(called, isTrue);
    });

    test('a removed listener is not called', () {
      final signal = CancelSignal();
      void listener() => fail('the step this belonged to is over');
      signal.onCancel(listener);
      signal.removeListener(listener);
      signal.cancel();
    });

    test('throwIfCancelled throws only after a cancel', () {
      final signal = CancelSignal();
      expect(signal.throwIfCancelled, returnsNormally);
      signal.cancel();
      expect(signal.throwIfCancelled, throwsA(isA<CancelledException>()));
    });
  });

  group('progress formatting', () {
    test('transfer sizes switch to GB above a gigabyte', () {
      expect(formatTransferSize(0), '0.0 MB');
      expect(formatTransferSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatTransferSize(3 * 1024 * 1024 * 1024), '3.00 GB');
    });

    test('elapsed is m:ss, and h:mm:ss past an hour', () {
      expect(formatElapsed(const Duration(seconds: 7)), '0:07');
      expect(formatElapsed(const Duration(minutes: 6, seconds: 3)), '6:03');
      expect(formatElapsed(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
    });
  });

  group('create() progress and cancellation', () {
    late Directory tempDir;
    late MockShell mockShell;
    late List<String> statusMessages;
    late List<CreateProgress> progress;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempDir = await Directory.systemTemp.createTemp('long_ops_test');
      SharedPreferences.setMockInitialValues({'DataPath': tempDir.path});
      await initPrefs();
      mockShell = MockShell();
      statusMessages = [];
      progress = [];
      distroRootfsLinks = {
        'Test Distro': 'https://example.invalid/rootfs.tar.gz'
      };
    });

    tearDown(() async {
      distroRootfsLinks = {};
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    WSLApi apiWith(_SteppedDownloader downloader) => WSLApi(
          shell: mockShell,
          downloaderFactory: ({
            required String url,
            required String saveFilePath,
            Map<String, String>? headers,
            int? chunkSize,
            Function(int, int, double)? onProgress,
            Function(File)? onDone,
            Function(dynamic)? onError,
          }) {
            downloader.saveFilePath = saveFilePath;
            downloader.onProgress = onProgress;
            return downloader;
          },
        );

    test('a cancel during the download stops it and never imports', () async {
      final downloader = _SteppedDownloader(steps: 20, total: 4096);
      final signal = CancelSignal();
      final api = apiWith(downloader);

      // Cancel on the third progress callback — mid-download, which is where
      // a user actually presses it.
      var seen = 0;
      final future = api.create(
        'TestInstance',
        'Test Distro',
        tempDir.path,
        statusMessages.add,
        cancelSignal: signal,
        onProgress: (p) {
          progress.add(p);
          if (++seen == 3) signal.cancel();
        },
      );

      await expectLater(future, throwsA(isA<CancelledException>()));
      expect(downloader.stopped, isTrue,
          reason: 'the socket has to be closed, not just the future abandoned');
      expect(mockShell.runCalls.any((c) => c.contains('--import')), isFalse);
    });

    test('a cancel before anything starts never touches the network',
        () async {
      final downloader = _SteppedDownloader(steps: 4, total: 4096);
      final api = apiWith(downloader);

      await expectLater(
        api.create('TestInstance', 'Test Distro', tempDir.path,
            statusMessages.add,
            cancelSignal: CancelSignal()..cancel()),
        throwsA(isA<CancelledException>()),
      );
      expect(mockShell.runCalls.any((c) => c.contains('--import')), isFalse);
    });

    test('progress moves off the finished download and onto the import',
        () async {
      final downloader = _SteppedDownloader(steps: 4, total: 4096);
      final api = apiWith(downloader);

      final result = await api.create(
        'TestInstance',
        'Test Distro',
        tempDir.path,
        statusMessages.add,
        onProgress: progress.add,
      );

      expect(result.exitCode, 0);
      expect(progress.map((p) => p.phase), contains(CreatePhase.downloading));
      // The measured bug: the last thing the UI was told was
      // "Downloading 100%", for the whole of the slowest step (CI-16).
      expect(progress.last.phase, CreatePhase.importing);
      expect(progress.last.fraction, isNull,
          reason: 'an import has no percentage; inventing one is the bug');
      final downloads =
          progress.where((p) => p.phase == CreatePhase.downloading);
      expect(downloads.last.fraction, 1.0);
      expect(downloads.last.label, contains('MB'),
          reason: 'a percentage alone cannot tell slow from stopped');
    });

    test('a plain create still runs through the cheap path', () async {
      // No progress sink and no cancel: nothing to watch and nothing to kill,
      // so `wsl --import` must not be rewired for it.
      final downloader = _SteppedDownloader(steps: 2, total: 2048);
      final api = apiWith(downloader);

      final result = await api.create(
          'TestInstance', 'Test Distro', tempDir.path, statusMessages.add);

      expect(result.exitCode, 0);
      expect(mockShell.runCalls.any((c) => c.contains('--import')), isTrue);
    });
  });

  group('hasPassword()', () {
    late MockShell mockShell;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await initPrefs();
      mockShell = MockShell();
    });

    test('reads the status field of passwd -S', () async {
      final api = WSLApi(shell: mockShell);
      mockShell.commandOutputs['passwd -S tester 2>/dev/null'] =
          'tester P 08/30/2026 0 99999 7 -1';
      expect(await api.hasPassword('Ubuntu', 'tester'), isTrue);

      // `NP` is "no password" and `L` is "locked" — two ways of having none,
      // which is what closing the console window without typing leaves behind.
      mockShell.commandOutputs['passwd -S tester 2>/dev/null'] =
          'tester NP 08/30/2026 0 99999 7 -1';
      expect(await api.hasPassword('Ubuntu', 'tester'), isFalse);

      mockShell.commandOutputs['passwd -S tester 2>/dev/null'] =
          'tester L 08/30/2026 0 99999 7 -1';
      expect(await api.hasPassword('Ubuntu', 'tester'), isFalse);
    });

    test('unanswerable is null, not "no password"', () async {
      final api = WSLApi(shell: mockShell);
      // busybox `passwd` has no `-S`; warning there would flag a distro that
      // is perfectly fine.
      mockShell.commandOutputs['passwd -S tester 2>/dev/null'] = '';
      expect(await api.hasPassword('Ubuntu', 'tester'), isNull);
      // A name that would be shell code never reaches the distro at all.
      expect(await api.hasPassword('Ubuntu', 'a; rm -rf /'), isNull);
    });
  });

  group('BusyButton (CI-15)', () {
    testWidgets('keeps a label and its width when it starts working',
        (tester) async {
      Future<Size> pump({required bool busy}) async {
        await tester.pumpWidget(FluentApp(
          home: ScaffoldPage(
            content: Center(
              child: BusyButton(
                key: const ValueKey('busy'),
                label: 'Create',
                busyLabel: 'Creating...',
                busy: busy,
                onPressed: busy ? null : () {},
              ),
            ),
          ),
        ));
        await tester.pump();
        return tester.getSize(find.byKey(const ValueKey('busy')));
      }

      final idle = await pump(busy: false);
      expect(find.text('Create'), findsOneWidget);
      expect(find.byType(ProgressRing), findsNothing);

      final working = await pump(busy: true);
      // The old code replaced the label with a bare 16 px spinner, which took
      // the button from 64 px to 38 px and dragged Cancel sideways with it.
      expect(find.text('Creating...'), findsOneWidget);
      expect(find.byType(ProgressRing), findsOneWidget);
      expect(working.width, greaterThanOrEqualTo(idle.width));
    });
  });

  group('per-distro settings dialog loading state (ST-36)', () {
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
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mockShell = MockShell();
      mockShell.wslConfContents = '';
      wslApiBuilder = () => WSLApi(shell: mockShell);
    });

    tearDown(() => wslApiBuilder = () => WSLApi());

    Future<ValueNotifier<bool>> pump(WidgetTester tester) async {
      final loaded = ValueNotifier<bool>(false);
      addTearDown(loaded.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: SettingsDialogContent(
            item: 'Ubuntu',
            pathController: TextEditingController(),
            startCmdController: TextEditingController(),
            userController: TextEditingController(),
            draft: WslConfDraft(),
            loaded: loaded,
          ),
        ),
      ));
      return loaded;
    }

    testWidgets('the spinner says what it is waiting for', (tester) async {
      final loaded = await pump(tester);
      // First frame: still asking whether the distro is running. Four-plus
      // seconds of a bare ProgressRing is what ST-36 measured.
      expect(find.byType(ProgressRing), findsOneWidget);
      expect(
          find.byKey(const ValueKey('test-settings-loading-label')),
          findsOneWidget);
      expect(loaded.value, isFalse,
          reason: 'Save must not be live over settings that were not read');
      await tester.pumpAndSettle();
    });

    testWidgets('Save unlocks only once wsl.conf has been read',
        (tester) async {
      mockShell.distros.add('Ubuntu');
      final loaded = await pump(tester);
      await tester.pumpAndSettle();
      expect(loaded.value, isTrue);
      expect(find.byType(ProgressRing), findsNothing);
    });
  });
}
