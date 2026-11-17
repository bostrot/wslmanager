import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/pricing.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/sale_banner.dart';

final _sale = PricingSale(
  id: 'black-friday-2026',
  name: 'Black Friday',
  percentOff: 50,
  startsAt: DateTime.utc(2026, 11, 23),
  endsAt: DateTime.utc(2026, 12, 1, 8),
  lookupKeys: const ['pro_windows', 'pro_macos'],
);

Widget _app() => const FluentApp(home: ScaffoldPage(content: SaleBanner()));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() => PricingService.saleOverride = null);

  testWidgets('says nothing while no sale is running', (tester) async {
    PricingService.saleOverride = () async => null;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-sale-banner')), findsNothing);
  });

  testWidgets('announces a running sale and stays closed once closed',
      (tester) async {
    PricingService.saleOverride = () async => _sale;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-sale-banner')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-sale-banner-button')),
        findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('test-sale-banner')),
        matching: find.byType(IconButton)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-sale-banner')), findsNothing);
    expect(prefs.getString(SaleBanner.dismissedPref), 'black-friday-2026');

    // A fresh mount — the next visit to Home — keeps it closed.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-sale-banner')), findsNothing);
  });

  testWidgets('a closed sale does not silence the next one', (tester) async {
    SharedPreferences.setMockInitialValues(
        {SaleBanner.dismissedPref: 'summer-2026'});
    prefs = await SharedPreferences.getInstance();
    PricingService.saleOverride = () async => _sale;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-sale-banner')), findsOneWidget);
  });
}
