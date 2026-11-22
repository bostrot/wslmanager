/// A primary button may never silently do nothing.
///
/// Both surfaces here shipped the same defect from two different files: the
/// mount dialog opened `_execute` with `if (…text.isEmpty) return;` *inside* a
/// try that had already set `_loading` (audit ST-45), and the snippet editor's
/// Save had an else branch whose entire body was the comment `// Error`
/// (audit ST-53). Pressing either one on an empty required field left the
/// screen pixel-identical.
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// handed — which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/mount_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/mount_dialog.dart';
import 'package:wsl2distromanager/screens/snippet_editor_screen.dart';

import 'mocks.dart';

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
  });

  Future<void> pumpMount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: MountDialog(service: MountService(shell: mockShell)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('mount dialog', () {
    testWidgets('Unmount with an empty path says what is missing',
        (tester) async {
      await pumpMount(tester);

      // The third radio is the Unmount "tab".
      await tester.tap(find.text('unmount-text').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('test-mount-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-mount-field-error')),
          findsOneWidget);
      expect(find.text('unmountpathrequired-text'), findsOneWidget);
      // And nothing was run: the old code flashed a progress bar over a
      // command it never issued.
      expect(
        mockShell.runCalls.any((args) => args.contains('--unmount')),
        false,
        reason: 'an empty path may not reach wsl.exe',
      );
    });

    testWidgets('typing a path clears the message again', (tester) async {
      await pumpMount(tester);

      await tester.tap(find.text('unmount-text').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-mount-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-mount-field-error')),
          findsOneWidget);

      await tester.enterText(find.byType(TextBox).last, r'\\.\PHYSICALDRIVE1');
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('test-mount-field-error')), findsNothing);
    });

    testWidgets('switching tab drops a message about the other tab',
        (tester) async {
      await pumpMount(tester);

      await tester.tap(find.text('unmount-text').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-mount-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-mount-field-error')),
          findsOneWidget);

      await tester.tap(find.text('vhdimage-text'));
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('test-mount-field-error')), findsNothing);
    });
  });

  group('snippet editor', () {
    Future<void> pumpEditor(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const FluentApp(home: SnippetEditorPage()));
      await tester.pumpAndSettle();
    }

    testWidgets('Save with an empty name asks for one', (tester) async {
      await pumpEditor(tester);

      await tester.tap(find.byKey(const ValueKey('test-snippet-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-snippet-error')), findsOneWidget);
      expect(find.text('snippetnamerequired-text'), findsOneWidget);
      // Still on the editor, with nothing written.
      expect(prefs.getStringList('quickSettingsTitles'), null);
    });

    testWidgets('a named snippet with no script says so instead',
        (tester) async {
      await pumpEditor(tester);

      await tester.enterText(
          find.byKey(const ValueKey('test-snippet-name')), 'audit-demo');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-snippet-save')));
      await tester.pumpAndSettle();

      expect(find.text('snippetcontentrequired-text'), findsOneWidget);
      expect(prefs.getStringList('quickSettingsTitles'), null);
    });

    testWidgets('typing a name clears the message', (tester) async {
      await pumpEditor(tester);

      await tester.tap(find.byKey(const ValueKey('test-snippet-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-snippet-error')), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('test-snippet-name')), 'audit-demo');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-snippet-error')), findsNothing);
    });

    testWidgets('a name that cannot be a folder is refused', (tester) async {
      // The name becomes a directory in the community repo, so the editor
      // rejects anything that would not survive as a path segment.
      await pumpEditor(tester);
      await tester.enterText(
          find.byKey(const ValueKey('test-snippet-name')), 'not a folder!');
      await tester.enterText(
          find.byKey(const ValueKey('test-snippet-description')), 'x');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-snippet-save')));
      await tester.pumpAndSettle();

      expect(find.text('snippetnameinvalid-text'), findsOneWidget);
      expect(prefs.getStringList('quickSettingsTitles'), null);
    });
  });
}
