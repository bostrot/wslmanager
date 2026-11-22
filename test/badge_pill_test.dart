import 'dart:ui' as ui;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/badge_pill.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';

/// The width the label's ink actually occupies, as opposed to the width of
/// its layout box: Flutter appends [BadgePill.letterSpacing] after the final
/// glyph too, and that trailing space is part of the box but not of the ink.
double _inkWidth(String label, {double scale = 1}) {
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
    fontSize: BadgePill.fontSize * scale,
    fontWeight: FontWeight.bold,
  ))
    ..pushStyle(ui.TextStyle(
      fontSize: BadgePill.fontSize * scale,
      fontWeight: FontWeight.bold,
      letterSpacing: BadgePill.letterSpacing,
    ))
    ..addText(label);
  final paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: double.infinity));
  return paragraph.longestLine - BadgePill.letterSpacing;
}

void main() {
  group('BadgePill', () {
    testWidgets('centres the label ink, not just its layout box',
        (tester) async {
      await tester.pumpWidget(const FluentApp(
        home: Center(
          child: BadgePill(
            label: 'BETA',
            foreground: Color(0xFF7A5C00),
            background: Color(0x2EFFBF00),
          ),
        ),
      ));

      final pill = tester.getRect(find.byType(BadgePill));
      final box = tester.getRect(find.text('BETA'));
      // The ink starts at the box's leading edge and stops one letter-space
      // short of its trailing one.
      final inkLeft = box.left;
      final inkRight = box.left + _inkWidth('BETA');

      expect(inkLeft - pill.left, closeTo(pill.right - inkRight, 0.01),
          reason: 'the ink sits off centre inside the pill');
    });

    testWidgets('is as tall as BadgePill.height says, whatever the font',
        (tester) async {
      // height: 1 with even leading takes the platform font's ascent,
      // descent and line gap out of the pill's size, so callers can rely on
      // BadgePill.height and two pills always line up.
      await tester.pumpWidget(const FluentApp(
        home: Center(
          child: BadgePill(
            label: 'NEW',
            foreground: Color(0xFF002050),
            background: Color(0x260078D4),
          ),
        ),
      ));

      expect(tester.getRect(find.byType(BadgePill)).height, BadgePill.height);

      final style = tester.widget<Text>(find.text('NEW')).style!;
      expect(style.height, 1);
      expect(style.leadingDistribution, TextLeadingDistribution.even);
    });

    testWidgets('keeps the ink centred when the user scales text up',
        (tester) async {
      // letterSpacing is not scaled by the text scaler while fontSize is, so
      // the correction stays exactly half a letter-space at any scale — and
      // the pill grows past BadgePill.height, which is the unscaled figure.
      await tester.pumpWidget(const FluentApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Center(
            child: BadgePill(
              label: 'BETA',
              foreground: Color(0xFF7A5C00),
              background: Color(0x2EFFBF00),
            ),
          ),
        ),
      ));

      final pill = tester.getRect(find.byType(BadgePill));
      final box = tester.getRect(find.text('BETA'));
      expect(box.left - pill.left,
          closeTo(pill.right - (box.left + _inkWidth('BETA', scale: 2)), 0.01));
      expect(pill.height, greaterThan(BadgePill.height));
    });

    testWidgets('two pills with different labels share one height',
        (tester) async {
      await tester.pumpWidget(const FluentApp(
        home: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BadgePill(
                label: 'BETA',
                foreground: Color(0xFF7A5C00),
                background: Color(0x2EFFBF00),
                border: Color(0x80FFBF00),
              ),
              BadgePill(
                label: 'NEW',
                foreground: Color(0xFF002050),
                background: Color(0x260078D4),
              ),
            ],
          ),
        ),
      ));

      final heights = tester
          .widgetList<BadgePill>(find.byType(BadgePill))
          .map((pill) => tester.getRect(find.byWidget(pill)).height)
          .toSet();
      expect(heights, {BadgePill.height},
          reason: 'a border must not make one pill taller than the other');
    });

    testWidgets('paints its border over the child, never around it',
        (tester) async {
      for (final border in <Color?>[null, const Color(0x80FFBF00)]) {
        await tester.pumpWidget(FluentApp(
          home: Center(
            child: BadgePill(
              label: 'NEW',
              foreground: const Color(0xFF002050),
              background: const Color(0x260078D4),
              border: border,
            ),
          ),
        ));

        final container = tester.widget<Container>(find.descendant(
          of: find.byType(BadgePill),
          matching: find.byType(Container),
        ));
        // The fill never carries the border — that would cost layout space.
        expect((container.decoration! as BoxDecoration).border, isNull);
        expect(
          (container.foregroundDecoration as BoxDecoration?)?.border,
          border == null ? isNull : isNotNull,
        );
      }
    });

    testWidgets('BetaBadge is a BadgePill and stays centred', (tester) async {
      await tester
          .pumpWidget(const FluentApp(home: Center(child: BetaBadge())));

      final pill = tester.getRect(find.byType(BadgePill));
      final box = tester.getRect(find.text('BETA'));
      expect(box.left - pill.left,
          closeTo(pill.right - (box.left + _inkWidth('BETA')), 0.01));
      expect(pill.height, BadgePill.height);
    });
  });
}
