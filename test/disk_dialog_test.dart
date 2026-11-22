/// Tests for lib/dialogs/disk_dialog.dart — the disk-space surface
/// (doc/audit/wsl-docs/features.md F-11, F-3; P05-16).
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// handed. That makes the gating assertions readable: a dialog that renders
/// `requireswsl-text` is telling the user why the buttons are dead, and one
/// that does not is the "Invalid command line option" experience the audit is
/// trying to remove.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/disk_dialog.dart';

import 'mocks.dart';

const String _df =
    'Filesystem     1K-blocks     Used Available Use% Mounted on\n'
    '/dev/sdd        104857600 12582912  92274688  12% /mnt/wslg/distro\n';

void main() {
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
    mockShell = MockShell();
    mockShell.dfOutput = _df;
    diskApiBuilder = () => WSLApi(shell: mockShell);
  });

  tearDown(() {
    diskApiBuilder = () => WSLApi();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const FluentApp(
      home: ScaffoldPage(content: DiskDialogContent(item: 'Ubuntu')),
    ));
    await tester.pumpAndSettle();
  }

  /// `disk-space.md:52-58` is explicit that decimals are unsupported —
  /// `2.5TB` is rejected by wsl.exe — so the dialog refuses them where the
  /// reason can be shown rather than letting a command fail.
  group('resize sizes (disk-space.md:52-58)', () {
    test('accepts whole numbers with a documented unit', () {
      expect(normalizeResizeSize('256GB'), '256GB');
      expect(normalizeResizeSize(' 512 mb '), '512MB');
      expect(normalizeResizeSize('2TB'), '2TB');
      expect(normalizeResizeSize('1048576B'), '1048576B');
    });

    test('a bare number is read as GB, the unit the field asks for', () {
      expect(normalizeResizeSize('256'), '256GB');
    });

    test('a decimal is refused, because wsl.exe refuses it', () {
      expect(normalizeResizeSize('2.5TB'), isNull);
      expect(normalizeResizeSize('0.5GB'), isNull);
    });

    test('nonsense and zero are refused', () {
      expect(normalizeResizeSize(''), isNull);
      expect(normalizeResizeSize('big'), isNull);
      expect(normalizeResizeSize('0GB'), isNull);
      expect(normalizeResizeSize('-5GB'), isNull);
      expect(normalizeResizeSize('12PB'), isNull);
    });
  });

  group('byte formatting', () {
    test('matches the compact message it sits next to', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(12 * 1024 * 1024 * 1024), '12 GB');
    });
  });

  group('the dialog', () {
    testWidgets('shows what the distro actually uses', (tester) async {
      mockShell.wslVersionOutput = 'WSL version: 2.6.3.0\n';
      await pump(tester);

      expect(find.text('diskused-text'), findsOneWidget);
      expect(find.text('diskfree-text'), findsOneWidget);
      // 12582912 KB used, 92274688 KB free.
      expect(find.text('12 GB'), findsOneWidget);
      expect(find.text('88 GB'), findsOneWidget);
    });

    testWidgets('says why the actions are unavailable below WSL 2.5',
        (tester) async {
      // The inbox build rejects `--version` outright (systemd.md:30).
      mockShell.wslVersionExitCode = 1;
      await pump(tester);

      expect(find.text('requireswsl-text'), findsOneWidget);

      final resize = tester.widget<Button>(find.ancestor(
          of: find.text('resizedisk-text').last,
          matching: find.byType(Button)));
      expect(resize.onPressed, isNull);
    });

    /// The inbox build above is the *unknown*-version case. A Store build
    /// that is merely older answers `--version` perfectly well, and 2.4.13 is
    /// the version a lexical compare reads as newer than 2.5.
    testWidgets('a known pre-2.5 build is gated the same way', (tester) async {
      mockShell.wslVersionOutput = 'WSL version: 2.4.13.0\n';
      await pump(tester);

      expect(find.text('requireswsl-text'), findsOneWidget);

      for (final label in const ['setsparseon-text', 'setsparseoff-text']) {
        final button = tester.widget<Button>(find
            .ancestor(of: find.text(label), matching: find.byType(Button)));
        expect(button.onPressed, isNull, reason: '$label is not gated');
      }

      // Disabled is only half of it: nothing may reach wsl.exe, because what
      // an older wsl.exe answers is `Invalid command line option`.
      await tester.enterText(find.byType(TextBox), '256');
      await tester.tap(find.text('resizedisk-text').last);
      await tester.pumpAndSettle();
      expect(mockShell.manageCalls, isEmpty);
    });

    /// 2.5.0 exactly is the floor `disk-space.md:48-58` documents, so it is
    /// the version the gate must let through rather than round down.
    testWidgets('2.5.0 exactly is enough', (tester) async {
      mockShell.wslVersionOutput = 'WSL version: 2.5.0.0\n';
      await pump(tester);

      expect(find.text('requireswsl-text'), findsNothing);
    });

    testWidgets('offers the actions on WSL 2.5+', (tester) async {
      mockShell.wslVersionOutput = 'WSL version: 2.6.3.0\n';
      await pump(tester);

      expect(find.text('requireswsl-text'), findsNothing);

      final sparseOn = tester.widget<Button>(find.ancestor(
          of: find.text('setsparseon-text'), matching: find.byType(Button)));
      expect(sparseOn.onPressed, isNotNull);
    });

    testWidgets('set-sparse terminates the distro and then runs --manage',
        (tester) async {
      mockShell.wslVersionOutput = 'WSL version: 2.6.3.0\n';
      await pump(tester);

      await tester.tap(find.text('setsparseon-text'));
      await tester.pumpAndSettle();

      expect(mockShell.manageCalls.single,
          ['--manage', 'Ubuntu', '--set-sparse', 'true']);
      final terminate =
          mockShell.runCalls.indexWhere((c) => c.contains('--terminate'));
      final manage =
          mockShell.runCalls.indexWhere((c) => c.contains('--set-sparse'));
      expect(terminate, greaterThanOrEqualTo(0));
      expect(manage, greaterThan(terminate));
    });

    testWidgets('an invalid resize never reaches wsl.exe', (tester) async {
      mockShell.wslVersionOutput = 'WSL version: 2.6.3.0\n';
      await pump(tester);

      await tester.enterText(find.byType(TextBox), '2.5TB');
      await tester.tap(find.text('resizedisk-text').last);
      await tester.pumpAndSettle();

      expect(mockShell.manageCalls, isEmpty);
    });

    testWidgets('a valid resize shuts WSL down first, as the docs require',
        (tester) async {
      mockShell.wslVersionOutput = 'WSL version: 2.6.3.0\n';
      await pump(tester);

      await tester.enterText(find.byType(TextBox), '256');
      await tester.tap(find.text('resizedisk-text').last);
      await tester.pumpAndSettle();

      expect(mockShell.manageCalls.single,
          ['--manage', 'Ubuntu', '--resize', '256GB']);
      final shutdown =
          mockShell.runCalls.indexWhere((c) => c.contains('--shutdown'));
      final resize =
          mockShell.runCalls.indexWhere((c) => c.contains('--resize'));
      expect(shutdown, greaterThanOrEqualTo(0));
      expect(resize, greaterThan(shutdown));
    });

    testWidgets('a distro that cannot answer df still renders', (tester) async {
      mockShell.dfOutput = '';
      mockShell.wslVersionOutput = 'WSL version: 2.6.3.0\n';
      await pump(tester);

      expect(find.text('diskusageunavailable-text'), findsOneWidget);
      expect(find.text('diskused-text'), findsNothing);
    });
  });
}
