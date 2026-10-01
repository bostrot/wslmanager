import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/pricing.dart';
import 'package:wsl2distromanager/api/purchase_routes.dart';
import 'package:wsl2distromanager/api/store_acquisition.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/license_screen.dart';

/// The License page renders one card per purchase route this host offers, and
/// — since Windows now also sells a key on the website — the key-entry box on
/// every host, not just the Mac.
///
/// Without a localization delegate every label renders as its raw i18n key,
/// which is what the copy assertions below look for.
const Size _kSurface = Size(1200, 2400);

/// One reported event, kept rather than posted.
class _Reported {
  const _Reported(this.name, this.page, this.props);

  final String name;
  final String page;
  final Map<String, String> props;
}

/// Records what the screen reports instead of posting it, so the paywall's
/// own numbers can be asserted rather than taken on trust.
class _RecordingPlausible implements Plausible {
  final List<_Reported> events = [];

  @override
  Future<int> event({
    String name = 'pageview',
    String referrer = '',
    String page = '',
    Map<String, String> props = const {},
    PlausibleRevenue? revenue,
    bool interactive = true,
  }) async {
    events.add(_Reported(name, page, props));
    return 200;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// [storeSellsPro] defaults to the paid era, where the Windows layout has two
// buy cards; the free-era tests pass false, and one passes null to check the
// screen follows the shipped constant when nothing is decided for it.
Widget _page({bool? appleHost, bool? storeSellsPro = true}) => FluentApp(
    home: ScaffoldPage(
        content: LicenseScreen(
            appleHost: appleHost, storeSellsPro: storeSellsPro)));

void main() {
  late _RecordingPlausible analytics;
  late Plausible realPlausible;
  late int quotesRequested;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LicenseManager.storeInstallCheckOverride = () => false;
    LicenseManager.httpOverride = null;
    await LicenseManager().init();
    realPlausible = plausible;
    analytics = _RecordingPlausible();
    plausible = analytics;
    // The quote is what the pricing service would answer with no network
    // and no OS to ask: the compiled-in dollars. Counted, so the screen can
    // be held to asking only when it has a price to show.
    quotesRequested = 0;
    PricingService.quoteOverride = () async {
      quotesRequested++;
      return PricingQuote.bundled();
    };
  });

  tearDown(() async {
    PricingService.quoteOverride = null;
    plausible = realPlausible;
    LicenseManager.storeInstallCheckOverride = null;
    LicenseManager.storeFreeFromOverride = null;
    LicenseManager.storeAcquisitionOverride = null;
    LicenseManager.httpOverride = null;
    await LicenseManager().clearLicense();
  });

  testWidgets('a free install is offered every route this host sells',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    final routes = purchaseRoutesFor(apple: isAppleHost);
    for (final route in routes) {
      expect(find.text(route.buttonKey), findsOneWidget,
          reason: 'no CTA for ${route.id}');
      expect(find.text(route.priceKey), findsOneWidget,
          reason: 'no price for ${route.id}');
    }
    // The lead CTA keeps the key the rest of the suite already looks for.
    expect(find.byKey(const ValueKey('test-license-store-button')),
        findsOneWidget);
  });

  testWidgets('the key box is offered on every host, not only the Mac',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-license-key-field')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-license-activate')), findsOneWidget);
    expect(find.text(activateDetailKeyFor(apple: isAppleHost)), findsOneWidget);
  });

  testWidgets('the plan comparison is shown once, not once per buy card',
      (tester) async {
    // It used to live inside the single buy card; with two cards on Windows
    // that would print the whole table twice.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(find.text('compare-plans-text'), findsOneWidget);
  });

  testWidgets('Windows is offered the Store and the website, in that order',
      (tester) async {
    // The point of the change, and unreachable from a Mac dev host without
    // the screen's host seam.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page(appleHost: false));
    await tester.pumpAndSettle();

    final routes = purchaseRoutesFor(apple: false);
    expect(routes.length, 2);
    for (final route in routes) {
      expect(find.text(route.buttonKey), findsOneWidget);
      expect(find.text(route.priceKey), findsOneWidget);
    }
    // Both CTAs are present and separately addressable.
    expect(find.byKey(const ValueKey('test-license-store-button')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-license-web-buy-button')),
        findsOneWidget);
    // One table under both cards, and the key box a Store-only Windows build
    // never used to show.
    expect(find.text('compare-plans-text'), findsOneWidget);
    expect(find.byKey(const ValueKey('test-license-key-field')), findsOneWidget);
    expect(find.text(activateDetailKeyFor(apple: false)), findsOneWidget);
  });

  testWidgets('the Store CTA sits above the website one on Windows',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page(appleHost: false));
    await tester.pumpAndSettle();

    final store = tester.getTopLeft(
        find.byKey(const ValueKey('test-license-store-button')));
    final web = tester.getTopLeft(
        find.byKey(const ValueKey('test-license-web-buy-button')));

    // The Store stays the primary, cheaper route; the website is the way out
    // of it, not the headline.
    expect(store.dy, lessThan(web.dy));
  });

  testWidgets('opening the paywall is reported, like every other screen',
      (tester) async {
    // Without it there is no denominator: the share of people who reach the
    // paywall and never buy cannot be told from the share who never got here.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(analytics.events.where((e) => e.page == 'license').length, 1);
  });

  testWidgets('each buy CTA reports which route was taken', (tester) async {
    // The Store and the website are counted apart deliberately: the Store is
    // the cheaper Windows route and its sales never touch the website, so a
    // single "clicked buy" total cannot be compared with anything.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page(appleHost: false));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('test-license-store-button')));
    // Settled, not pumped: the CTA leaves a short press-feedback timer behind
    // and an unfinished one fails the test on its own.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-license-web-buy-button')));
    await tester.pumpAndSettle();

    final clicks =
        analytics.events.where((e) => e.name == 'license_buy_clicked').toList();
    expect(clicks.map((e) => e.props['route']).toList(), ['store', 'direct']);
    for (final click in clicks) {
      expect(click.props['host'], 'windows');
    }
    // The website route is quoted on the card, so its click carries what
    // the buyer saw; the Store shows its own price and sends none.
    expect(clicks[0].props.containsKey('amount'), isFalse);
    expect(clicks[0].props.containsKey('currency'), isFalse);
    expect(clicks[1].props['currency'], 'USD');
    expect(double.parse(clicks[1].props['amount']!), 29);
  });

  testWidgets('left undecided, the screen follows the shipped flip instant',
      (tester) async {
    // Nothing passed for storeSellsPro means LicenseManager.storeSellsPro,
    // which reads storeFreeFromUtc — and that instant has passed, so a
    // Windows build shows the single website card and no Store button.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page(appleHost: false, storeSellsPro: null));
    await tester.pumpAndSettle();

    final store = purchaseRoutesFor(apple: false).first;
    expect(find.text(store.buttonKey), findsNothing);
    final only = purchaseRoutesFor(apple: false, storeSellsPro: false).single;
    expect(find.text(only.buttonKey), findsOneWidget);
    // One card, so only the lead CTA's key is on screen.
    expect(find.byKey(const ValueKey('test-license-web-buy-button')),
        findsNothing);
  });

  testWidgets('a free Store listing leaves Windows one card, the website one',
      (tester) async {
    // The Store card would open a listing that no longer sells Pro, so it
    // goes — and the website card is promoted into the lead, keys and all.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page(appleHost: false, storeSellsPro: false));
    await tester.pumpAndSettle();

    final store = purchaseRoutesFor(apple: false).first;
    expect(find.text(store.buttonKey), findsNothing);
    expect(find.text(store.priceKey), findsNothing);

    final only =
        purchaseRoutesFor(apple: false, storeSellsPro: false).single;
    expect(find.text(only.buttonKey), findsOneWidget);
    expect(find.text(only.priceKey), findsOneWidget);
    // The lead CTA keeps the key the rest of the suite looks for, whichever
    // route happens to be leading.
    expect(find.byKey(const ValueKey('test-license-store-button')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-license-web-buy-button')),
        findsNothing);
  });

  testWidgets('a free Store listing points a legacy buyer at the key box',
      (tester) async {
    // The paid-era blurb promises that a Store copy unlocks itself, which is
    // exactly what has stopped being true for the person reading it.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page(appleHost: false, storeSellsPro: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-license-key-field')), findsOneWidget);
    expect(
        find.text(activateDetailKeyFor(apple: false, storeSellsPro: false)),
        findsOneWidget);
    expect(find.text(activateDetailKeyFor(apple: false)), findsNothing);
  });

  testWidgets('"Check again" asks the Store whether this copy was bought',
      (tester) async {
    // The reinstall case: a Store copy on a fresh PC, nothing local to show
    // for the purchase, and the user pressing the one button there is. The
    // screen has to ask the Store then and there — not wait for the daily
    // background check — and report what it said.
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // The screen reports the outcome through the app-wide infobar, which
    // nothing has wired up in a test; record what it would have said.
    final notified = <String>[];
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      notified.add(msg);
    };

    var asked = 0;
    LicenseManager.storeInstallCheckOverride = () => true;
    LicenseManager.storeFreeFromOverride = DateTime.utc(2010);
    LicenseManager.storeAcquisitionOverride = () async {
      asked++;
      return StoreAcquisition(acquiredAt: DateTime.utc(2009, 6, 1));
    };
    // The daily check already ran and got nothing — a signed-out Store,
    // say — so only a forced lookup can find the purchase.
    await prefs.setInt(
        storeAcquisitionCheckedPref, DateTime.now().millisecondsSinceEpoch);
    await LicenseManager().init();
    expect(LicenseManager().isPro, false);

    await tester.pumpWidget(_page(appleHost: false, storeSellsPro: false));
    await tester.pumpAndSettle();
    expect(asked, 0);

    await tester.tap(find.byKey(const ValueKey('test-license-recheck')));
    await tester.pumpAndSettle();

    expect(asked, 1);
    expect(LicenseManager().isPro, true);
    expect(notified, ['restore-found-text']);
    // Sold nothing any more: the key box and the buy cards are gone.
    expect(find.byKey(const ValueKey('test-license-key-field')), findsNothing);
  });

  testWidgets('a licensed install is sold nothing and asked for no key',
      (tester) async {
    LicenseManager.storeInstallCheckOverride = () => true;
    // A Store copy from before the flip.
    LicenseManager.storeFreeFromOverride =
        DateTime.now().toUtc().add(const Duration(days: 1));
    addTearDown(() => LicenseManager.storeFreeFromOverride = null);
    await LicenseManager().init();

    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    expect(LicenseManager().isPro, true);
    for (final route in purchaseRoutesFor(apple: isAppleHost)) {
      expect(find.text(route.buttonKey), findsNothing);
    }
    expect(find.byKey(const ValueKey('test-license-key-field')), findsNothing);
    // The feature list stays, so a paying user can still see what they have.
    expect(find.text('compare-plans-text'), findsOneWidget);
    // And nothing was fetched: there is no price on this screen to quote.
    expect(quotesRequested, 0);
  });

  testWidgets('a free install asks for the prices exactly once',
      (tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(quotesRequested, 1);

    // "Check again" re-reads the entitlement, not the prices.
    await tester.tap(find.byKey(const ValueKey('test-license-recheck')));
    await tester.pumpAndSettle();
    expect(quotesRequested, 1);
  });
}
