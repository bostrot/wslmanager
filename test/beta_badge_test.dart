import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';

void main() {
  testWidgets('BetaBadge renders a fixed, untranslated BETA label',
      (tester) async {
    await tester.pumpWidget(const FluentApp(home: BetaBadge()));

    // The label is deliberately hardcoded (like ProBadge's "Pro") so it
    // reads the same in every locale and is findable without a
    // localization delegate.
    expect(find.text('BETA'), findsOneWidget);
    expect(find.byType(Tooltip), findsOneWidget);
  });

  testWidgets('BetaBanner renders as a warning InfoBar', (tester) async {
    await tester.pumpWidget(const FluentApp(home: BetaBanner()));

    final infoBar = tester.widget<InfoBar>(find.byType(InfoBar));
    expect(infoBar.severity, InfoBarSeverity.warning);
  });

  group('BetaPaneBadge', () {
    Future<void> pumpAt(WidgetTester tester, double width) async {
      await tester.pumpWidget(FluentApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 800)),
          child: const Center(child: BetaPaneBadge()),
        ),
      ));
    }

    testWidgets('shows the full pill while the pane is open', (tester) async {
      await pumpAt(tester, BetaPaneBadge.compactPaneThreshold);

      expect(find.byType(BetaBadge), findsOneWidget);
      expect(find.text('BETA'), findsOneWidget);
    });

    testWidgets('shrinks to a dot once the pane is an icon rail',
        (tester) async {
      // Below the threshold the pill would be painted over the item's glyph,
      // hiding the destination's only affordance (audit LN-10, PS-10).
      await pumpAt(tester, BetaPaneBadge.compactPaneThreshold - 1);

      expect(find.byType(BetaBadge), findsNothing);
      expect(find.text('BETA'), findsNothing);
      expect(tester.getSize(find.byType(BetaPaneBadge)),
          const Size(BetaPaneBadge.dotSize, BetaPaneBadge.dotSize));
    });

    testWidgets('is announced the same way at either width', (tester) async {
      final handle = tester.ensureSemantics();
      for (final width in [
        BetaPaneBadge.compactPaneThreshold,
        BetaPaneBadge.compactPaneThreshold - 1,
      ]) {
        await pumpAt(tester, width);
        expect(tester.getSemantics(find.byType(BetaPaneBadge)).label,
            'beta-badge-label-text',
            reason: 'the dot must carry the pill\'s name too');
      }
      handle.dispose();
    });
  });
}
