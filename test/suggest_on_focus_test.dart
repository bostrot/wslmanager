/// Tests for lib/components/suggest_on_focus.dart — the wrapper that opens an
/// AutoSuggestBox's list on click/focus rather than on the first keystroke
/// (bostrot/ai-tasks#4).
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/suggest_on_focus.dart';

void main() {
  const items = ['Alpine Linux', 'Debian', 'Ubuntu'];
  const boxKey = ValueKey('box');

  Future<TextEditingController> pump(WidgetTester tester,
      {bool enabled = true, FocusNode? focusNode}) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    // The default test view is 266x200 logical pixels — too small for a
    // 300-wide box and a popup under it.
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Align(
          alignment: Alignment.topCenter,
          // A bounded box: left loose, the field fills the page and pushes
          // its popup below the bottom edge of the test window.
          child: SizedBox(
            width: 300,
            height: 36,
            child: SuggestOnFocus<String>(
              key: boxKey,
              focusNode: focusNode,
              builder: (context, key, node) => AutoSuggestBox<String>(
                key: key,
                focusNode: node,
                controller: controller,
                enabled: enabled,
                items: [
                  for (final name in items)
                    AutoSuggestBoxItem<String>(value: name, label: name),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    // fluent_ui's own post-frame size check dismisses any overlay open
    // during the very first frame; settle past it like a real launch does.
    await tester.pumpAndSettle();
    return controller;
  }

  /// The overlay tiles are the only place an item label is rendered while
  /// the text box is empty. The popup hangs off a CompositedTransformFollower
  /// in the root overlay, which the default on-stage walk skips.
  Finder tile(String label) => find.text(label, skipOffstage: false);

  testWidgets('a click on the empty field lists every item', (tester) async {
    await pump(tester);
    expect(tile('Alpine Linux'), findsNothing);

    await tester.tap(find.byKey(boxKey));
    await tester.pumpAndSettle();

    for (final name in items) {
      expect(tile(name), findsOneWidget, reason: '$name should be listed');
    }
  });

  testWidgets('keyboard focus opens the list too', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pump(tester, focusNode: node);

    node.requestFocus();
    await tester.pumpAndSettle();

    expect(tile('Debian'), findsOneWidget);
  });

  testWidgets('a click on an already-focused field reopens a closed list',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(boxKey));
    await tester.pumpAndSettle();
    expect(tile('Ubuntu'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tile('Ubuntu'), findsNothing, reason: 'Escape closes the list');

    // No focus change happens here — the field kept focus through Escape.
    await tester.tap(find.byKey(boxKey));
    await tester.pumpAndSettle();
    expect(tile('Ubuntu'), findsOneWidget);
  });

  testWidgets('typing still filters the open list', (tester) async {
    final controller = await pump(tester);
    await tester.tap(find.byKey(boxKey));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(boxKey), 'ubu');
    await tester.pumpAndSettle();

    expect(tile('Ubuntu'), findsOneWidget);
    expect(tile('Debian'), findsNothing);
    expect(controller.text, 'ubu');
  });

  testWidgets('choosing an item closes the list and fills the field',
      (tester) async {
    final controller = await pump(tester);
    await tester.tap(find.byKey(boxKey));
    await tester.pumpAndSettle();

    await tester.tap(tile('Debian'));
    await tester.pumpAndSettle();

    expect(controller.text, 'Debian');
    expect(
        tester
            .state<AutoSuggestBoxState<String>>(
                find.byType(AutoSuggestBox<String>))
            .isOverlayVisible,
        isFalse,
        reason: 'the click on the tile must not reopen the list');
    // The chosen label is now in the text box; the tile must be gone, so
    // exactly one rendering of it remains.
    expect(tile('Debian'), findsOneWidget);
    expect(tile('Ubuntu'), findsNothing);
  });

  testWidgets('a disabled field does not open anything', (tester) async {
    await pump(tester, enabled: false);

    await tester.tap(find.byKey(boxKey), warnIfMissed: false);
    await tester.pumpAndSettle();

    for (final name in items) {
      expect(tile(name), findsNothing);
    }
  });
}
