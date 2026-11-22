/// The chat dock's split: a draggable, remembered width and an expand toggle
/// that hands the chat the whole page area (ai-tasks#104). The dock sits
/// inside the shell's pane body, so expanding it never touches the
/// navigation pane on the left — there is nothing of the pane in this tree.
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/components/ai_chat_dock.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  const pageKey = ValueKey('dock-test-page');
  const panelKey = ValueKey('dock-test-panel');
  const statusKey = ValueKey('dock-test-status');
  const handleKey = ValueKey('test-chat-resize');

  /// The toggle the panel's header would own, so a test can flip it.
  late VoidCallback toggle;
  late bool expanded;

  Future<void> pumpDock(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    Map<String, Object> prefsValues = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        padding: EdgeInsets.zero,
        content: AiChatDock(
          page: const ColoredBox(color: Color(0xFF101010), key: pageKey),
          statusBar: const SizedBox(height: 24, key: statusKey),
          panelBuilder: (context, isExpanded, toggleExpanded) {
            expanded = isExpanded;
            toggle = toggleExpanded;
            return const ColoredBox(color: Color(0xFF202020), key: panelKey);
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  double panelWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(panelKey)).width;

  group('width', () {
    testWidgets('starts at the dock width it always had', (tester) async {
      await pumpDock(tester);
      expect(panelWidth(tester), AiChatDock.defaultWidth);
    });

    testWidgets('scales with a narrow window instead of eating it',
        (tester) async {
      await pumpDock(tester, size: const Size(900, 800));
      expect(panelWidth(tester), (900 * 0.36).roundToDouble());
    });

    testWidgets('a stored width is used and clamped to the window',
        (tester) async {
      await pumpDock(tester,
          prefsValues: {AiChatDock.widthPrefsKey: 640.0});
      expect(panelWidth(tester), 640);

      // The same preference on a window that cannot spare 640 leaves the
      // page its minimum rather than squeezing it out.
      await pumpDock(tester,
          size: const Size(700, 800),
          prefsValues: {AiChatDock.widthPrefsKey: 640.0});
      expect(panelWidth(tester), 700 - AiChatDock.minPageWidth);
    });

    testWidgets('dragging the handle left widens the chat and is remembered',
        (tester) async {
      await pumpDock(tester);

      await tester.drag(find.byKey(handleKey), const Offset(-120, 0));
      await tester.pumpAndSettle();

      // Not exactly 120: a drag only starts once it clears the touch slop,
      // which is what keeps a click on the handle from nudging the split.
      final widened = panelWidth(tester);
      expect(widened, greaterThan(AiChatDock.defaultWidth));
      expect(widened, lessThanOrEqualTo(AiChatDock.defaultWidth + 120));
      expect(prefs.getDouble(AiChatDock.widthPrefsKey), widened);
    });

    testWidgets('dragging right narrows it, but never past the minimum',
        (tester) async {
      await pumpDock(tester);

      await tester.drag(find.byKey(handleKey), const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(panelWidth(tester), AiChatDock.minWidth);
    });

    testWidgets('the handle is keyboard operable, not drag-only',
        (tester) async {
      await pumpDock(tester);

      // Focus it the way Tab would, then nudge.
      final handleFocus = tester
          .widgetList<Focus>(find.descendant(
              of: find.byKey(handleKey), matching: find.byType(Focus)))
          .map((focus) => focus.focusNode)
          .whereType<FocusNode>()
          .first;
      handleFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(handleFocus.hasPrimaryFocus, isTrue,
          reason: 'the split must be reachable without a mouse (IA-04)');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      expect(panelWidth(tester),
          AiChatDock.defaultWidth + AiChatDock.keyboardStep);
    });
  });

  group('expanding', () {
    testWidgets('gives the chat the whole page area', (tester) async {
      await pumpDock(tester);
      expect(expanded, isFalse);
      expect(find.byKey(pageKey), findsOneWidget);

      toggle();
      await tester.pumpAndSettle();

      expect(expanded, isTrue);
      expect(panelWidth(tester), 1200);
      // Nothing of the page is left beside it — and no handle either, there
      // is no split to drag.
      expect(find.byKey(pageKey), findsNothing);
      expect(find.byKey(handleKey), findsNothing);
      expect(prefs.getBool(AiChatDock.expandedPrefsKey), isTrue);
      // The status row survives the page it normally sits under, so a
      // message about what the assistant just started is still readable.
      expect(find.byKey(statusKey), findsOneWidget);
    });

    testWidgets('collapsing returns to the width from before',
        (tester) async {
      await pumpDock(tester,
          prefsValues: {AiChatDock.widthPrefsKey: 500.0});

      toggle();
      await tester.pumpAndSettle();
      toggle();
      await tester.pumpAndSettle();

      expect(expanded, isFalse);
      expect(panelWidth(tester), 500);
      expect(prefs.getBool(AiChatDock.expandedPrefsKey), isFalse);
    });

    testWidgets('a dock left expanded opens expanded', (tester) async {
      await pumpDock(tester,
          prefsValues: {AiChatDock.expandedPrefsKey: true});

      expect(expanded, isTrue);
      expect(find.byKey(pageKey), findsNothing);
    });
  });

  group('clampWidth', () {
    test('keeps the page its minimum', () {
      expect(AiChatDock.clampWidth(900, 1000),
          1000 - AiChatDock.minPageWidth);
    });

    test('keeps the chat its minimum', () {
      expect(AiChatDock.clampWidth(10, 1000), AiChatDock.minWidth);
    });

    test('a window too small for both never overflows it', () {
      expect(AiChatDock.clampWidth(900, 200), lessThanOrEqualTo(200));
    });
  });
}
