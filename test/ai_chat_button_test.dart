/// The redesigned entry point to the AI dock (ai-tasks#27): a labelled
/// sparkle pill built on fluent's HoverButton, so it keeps the keyboard and
/// screen-reader reach of the plain accent circle it replaces.
// ignore_for_file: dangling_library_doc_comments

import 'dart:ui' show Tristate;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/ai_chat_button.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  return FluentApp(
    theme: FluentThemeData(brightness: brightness),
    home: ScaffoldPage(content: Center(child: child)),
  );
}

Finder _sparklePaint() => find.descendant(
      of: find.byType(SparkleIcon),
      matching: find.byType(CustomPaint),
    );

AnimatedContainer _pill(WidgetTester tester) =>
    tester.widget<AnimatedContainer>(find.descendant(
      of: find.byType(AiChatButton),
      matching: find.byType(AnimatedContainer),
    ));

BoxDecoration _decoration(WidgetTester tester) =>
    _pill(tester).decoration as BoxDecoration;

void main() {
  group('AiChatButton', () {
    testWidgets('shows the sparkle mark and the localized verb',
        (tester) async {
      await tester.pumpWidget(_host(AiChatButton(onPressed: () {})));

      // No localization delegate in the test, so the key itself is the
      // label — which also proves the text is not hardcoded English.
      expect(find.text('ai-chat-button-text'), findsOneWidget);
      expect(find.byType(SparkleIcon), findsOneWidget);
      // fluent's generic chat bubble is gone; it meant "conversation", not
      // "assistant", and it is what the old circle had (ai-tasks#27).
      expect(find.byIcon(FluentIcons.chat), findsNothing);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('is a pill, not a circle, and fills with a gradient',
        (tester) async {
      await tester.pumpWidget(_host(AiChatButton(onPressed: () {})));

      final decoration = _decoration(tester);
      expect(decoration.gradient, isA<LinearGradient>());
      expect(decoration.borderRadius,
          BorderRadius.circular(AiChatButton.height / 2));
      expect(decoration.boxShadow, isNotEmpty);
      expect(tester.getSize(find.byType(AnimatedContainer)).height,
          AiChatButton.height);
      // Wider than tall: the label is part of the control, not a tooltip.
      expect(tester.getSize(find.byType(AnimatedContainer)).width,
          greaterThan(AiChatButton.height));
    });

    testWidgets('a click toggles the dock', (tester) async {
      var presses = 0;
      await tester.pumpWidget(_host(AiChatButton(onPressed: () => presses++)));

      await tester.tap(find.byType(AiChatButton));
      await tester.pumpAndSettle();

      expect(presses, 1);
    });

    testWidgets('is reachable and activated from the keyboard', (tester) async {
      // IA-04: the only way into the panel must not be mouse-only.
      var presses = 0;
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(_host(
        AiChatButton(onPressed: () => presses++, focusNode: node),
      ));

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(node.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(presses, 2);
    });

    testWidgets('is named, is a button, and announces the dock state',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(AiChatButton(onPressed: () {})));

      // HoverButton merges the label, the button role and the toggle state
      // from separate nodes into one, so read the merged data — and the
      // name has to be there exactly once, not once per merged node.
      var data =
          tester.getSemantics(find.byType(AiChatButton)).getSemanticsData();
      expect(data.label, 'ai-chat-button-text');
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.flagsCollection.isToggled, Tristate.isFalse);

      await tester
          .pumpWidget(_host(AiChatButton(onPressed: () {}, open: true)));
      data = tester.getSemantics(find.byType(AiChatButton)).getSemanticsData();
      expect(data.flagsCollection.isToggled, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('lifts on hover and settles on press', (tester) async {
      // Hover highlights only show in the traditional (mouse) mode; the test
      // binding starts in touch mode and a synthetic move does not switch it.
      final strategy = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
      await tester.pumpWidget(_host(AiChatButton(onPressed: () {})));
      final resting = _decoration(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(AiChatButton)));
      await tester.pumpAndSettle();
      final hovered = _decoration(tester);

      expect(hovered.gradient, isNot(resting.gradient));
      expect(hovered.boxShadow!.single.blurRadius,
          greaterThan(resting.boxShadow!.single.blurRadius));

      await gesture.down(tester.getCenter(find.byType(AiChatButton)));
      await tester.pumpAndSettle();
      final pressed = _decoration(tester);
      expect(pressed.boxShadow!.single.blurRadius,
          lessThan(resting.boxShadow!.single.blurRadius));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('keeps a white label on the accent in both themes',
        (tester) async {
      // The fill is the accent in light and dark alike, so the label colour
      // does not change with the theme — the old circle's one strength
      // (audit TL-06) that the redesign has to keep.
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
            _host(AiChatButton(onPressed: () {}), brightness: brightness));
        final text = tester.widget<Text>(find.text('ai-chat-button-text'));
        expect(text.style?.color, AiChatButton.foreground,
            reason: '$brightness');
        expect(_decoration(tester).gradient, isNotNull);
      }
    });

    testWidgets('a disabled button drops the shadow and stays named',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const AiChatButton(onPressed: null)));

      expect(_decoration(tester).boxShadow, isEmpty);
      final data =
          tester.getSemantics(find.byType(AiChatButton)).getSemanticsData();
      expect(data.label, 'ai-chat-button-text');
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
      handle.dispose();
    });

    test('every interaction state resolves to a distinct fill', () {
      final accent = Colors.blue;
      final fills = {
        for (final states in [
          <WidgetState>{},
          {WidgetState.hovered},
          {WidgetState.pressed},
          {WidgetState.disabled},
        ])
          AiChatButton.fillFor(accent, states).colors.toString(),
      };
      expect(fills, hasLength(4));
    });
  });

  group('SparkleIcon', () {
    testWidgets('paints two four-point stars in the given colour',
        (tester) async {
      await tester.pumpWidget(_host(
        const SparkleIcon(size: 24, color: Color(0xFF123456)),
      ));

      expect(_sparklePaint(), findsOneWidget);
      expect(
        _sparklePaint(),
        paints
          ..path(color: const Color(0xFF123456))
          ..path(color: const Color(0xFF123456)),
      );
      expect(tester.getSize(find.byType(SparkleIcon)), const Size(24, 24));
    });

    testWidgets('takes the ambient icon colour when none is given',
        (tester) async {
      await tester.pumpWidget(_host(
        const IconTheme(
          data: IconThemeData(color: Color(0xFF00FF00)),
          child: SparkleIcon(),
        ),
      ));

      final painter =
          tester.widget<CustomPaint>(_sparklePaint()).painter as SparklePainter;
      expect(painter.color, const Color(0xFF00FF00));
    });

    test('a star is symmetric about its centre and spans its radius', () {
      final bounds = SparklePainter.star(const Offset(10, 10), 5).getBounds();
      expect(bounds, const Rect.fromLTRB(5, 5, 15, 15));
      // The sides pinch inwards: a point halfway along the top-right edge
      // of the bounding box is outside the star.
      expect(
        SparklePainter.star(const Offset(10, 10), 5)
            .contains(const Offset(12.5, 7.5)),
        isFalse,
      );
      // ...while the centre is inside it.
      expect(
        SparklePainter.star(const Offset(10, 10), 5)
            .contains(const Offset(10, 10)),
        isTrue,
      );
    });

    test('repaints only when the colour changes', () {
      const a = SparklePainter(Color(0xFF000000));
      const b = SparklePainter(Color(0xFF000000));
      const c = SparklePainter(Color(0xFFFFFFFF));
      expect(a.shouldRepaint(b), isFalse);
      expect(a.shouldRepaint(c), isTrue);
    });
  });
}
