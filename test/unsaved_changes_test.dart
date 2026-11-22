/// Tests for lib/components/unsaved_changes.dart — the exit guard that closes
/// audit ST-01, where leaving Settings by any route other than Save silently
/// discarded every edit.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';

void main() {
  setUp(UnsavedChangesGuard.reset);
  tearDown(UnsavedChangesGuard.reset);

  group('UnsavedChangesGuard', () {
    test('an unguarded screen leaves without being asked', () async {
      expect(UnsavedChangesGuard.isDirty, false);
      expect(await UnsavedChangesGuard.confirmLeave(), true);
    });

    test('a registered guard decides', () async {
      UnsavedChangesGuard.register(() async => false);

      expect(UnsavedChangesGuard.isDirty, true);
      expect(await UnsavedChangesGuard.confirmLeave(), false);
    });

    test('releasing a guard lets navigation through again', () async {
      Future<bool> guard() async => false;
      UnsavedChangesGuard.register(guard);
      UnsavedChangesGuard.release(guard);

      expect(UnsavedChangesGuard.isDirty, false);
      expect(await UnsavedChangesGuard.confirmLeave(), true);
    });

    test('a stale screen disposing cannot clear the live guard', () async {
      // The replacement registers before the screen it replaced disposes, so
      // release has to be identity-checked or the new screen loses its guard.
      Future<bool> stale() async => true;
      Future<bool> live() async => false;
      UnsavedChangesGuard.register(stale);
      UnsavedChangesGuard.register(live);
      UnsavedChangesGuard.release(stale);

      expect(UnsavedChangesGuard.isDirty, true);
      expect(await UnsavedChangesGuard.confirmLeave(), false);
    });
  });

  group('showUnsavedChangesDialog', () {
    Future<UnsavedChangesChoice?> open(WidgetTester tester,
        {required String tapKey}) async {
      UnsavedChangesChoice? choice;
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              onPressed: () async {
                choice = await showUnsavedChangesDialog(context);
              },
              child: const Text('leave'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(tapKey)));
      await tester.pumpAndSettle();
      return choice;
    }

    testWidgets('offers all three answers', (tester) async {
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              onPressed: () => showUnsavedChangesDialog(context),
              child: const Text('leave'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-unsaved-save')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('test-unsaved-discard')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-unsaved-cancel')), findsOneWidget);
      // The dialog says which screen state is at stake, not just "are you
      // sure": ST-01's complaint was that nothing signalled the loss at all.
      expect(find.text('unsavedchanges-title'), findsOneWidget);
      expect(find.text('unsavedchanges-text'), findsOneWidget);
    });

    testWidgets('Save answers save', (tester) async {
      expect(await open(tester, tapKey: 'test-unsaved-save'),
          UnsavedChangesChoice.save);
    });

    testWidgets('Discard answers discard', (tester) async {
      expect(await open(tester, tapKey: 'test-unsaved-discard'),
          UnsavedChangesChoice.discard);
    });

    testWidgets('Cancel answers cancel', (tester) async {
      expect(await open(tester, tapKey: 'test-unsaved-cancel'),
          UnsavedChangesChoice.cancel);
    });
  });
}
