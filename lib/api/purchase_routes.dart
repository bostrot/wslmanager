// The ways a user can buy Pro, and which of them a given host offers.
//
// Windows has had two: the Microsoft Store listing the app has always had,
// and — for buyers who would rather not go through the Store at all — the
// same website shop the Mac uses, which sells a licence key instead. macOS
// has only the website, since there is no Store to sell through.
//
// Once the Store listing goes free it sells nothing, and Windows is left
// with the website too: the same single card the Mac shows, at the Windows
// price. Nothing sends a buyer to a Store page that cannot take their money.
//
// The copy lives here as i18n keys rather than strings so the screen stays a
// plain renderer and the route set itself is testable without a UI.

import 'package:wsl2distromanager/api/pricing.dart';
import 'package:wsl2distromanager/components/constants.dart';

/// How a route is identified in the UI — used for widget test keys and to
/// tell the two cards apart.
enum PurchaseRouteId {
  /// The Microsoft Store listing. Being installed from it *is* the licence.
  store,

  /// wslmanager.com, which sells a licence key the user activates in-app.
  direct,
}

/// One way to buy Pro: where to send the buyer, and the copy describing it.
class PurchaseRoute {
  const PurchaseRoute({
    required this.id,
    required this.url,
    required this.titleKey,
    required this.detailKey,
    required this.priceKey,
    required this.buttonKey,
    this.lookupKey,
  });

  final PurchaseRouteId id;

  /// Opened in the user's browser (or the Store app) when they buy.
  final String url;

  final String titleKey;
  final String detailKey;

  /// The price line. With a [lookupKey] this is a format with one `%s`,
  /// filled with the live price in the buyer's currency; without one it
  /// is the whole line, for a route whose price the app does not know.
  final String priceKey;
  final String buttonKey;

  /// The Stripe lookup key of the price this route sells at, for the
  /// website routes: what `lib/api/pricing.dart` quotes. Null for the
  /// Store, whose own page shows the price.
  final String? lookupKey;
}

/// The routes offered on this host, in the order they should be shown.
///
/// [apple] is `isAppleHost`, passed in rather than read here so the whole
/// set is testable from a Windows *or* a Mac test host.
///
/// [storeSellsPro] is `LicenseManager.storeSellsPro` — false once the Store
/// listing has gone free. It is about the listing, not about this install,
/// so a portable build loses the Store card at the same moment a packaged
/// one does: neither can buy Pro there any more.
List<PurchaseRoute> purchaseRoutesFor({
  required bool apple,
  bool storeSellsPro = true,
}) {
  const direct = PurchaseRoute(
    id: PurchaseRouteId.direct,
    url: macBuyUrl,
    // The website is the only route on the Mac, so it carries the plain
    // "Get Pro" heading there.
    titleKey: 'store-buy-title',
    detailKey: 'web-buy-detail-text',
    priceKey: 'web-price-format',
    buttonKey: 'web-buy-btn',
    lookupKey: proMacosLookupKey,
  );

  if (apple) return const [direct];

  if (!storeSellsPro) {
    // The Windows price, in the Mac's copy: with the Store gone this is the
    // only way to buy, so it is no longer "the alternative" and must not be
    // headed as one.
    return const [
      PurchaseRoute(
        id: PurchaseRouteId.direct,
        url: windowsBuyUrl,
        titleKey: 'store-buy-title',
        detailKey: 'web-buy-detail-text',
        priceKey: 'web-price-format',
        buttonKey: 'web-buy-btn',
        lookupKey: proWindowsLookupKey,
      ),
    ];
  }

  return const [
    PurchaseRoute(
      id: PurchaseRouteId.store,
      url: windowsStoreUrl,
      titleKey: 'store-buy-title',
      detailKey: 'store-buy-detail-text',
      priceKey: 'store-price-text',
      buttonKey: 'store-buy-btn',
    ),
    // Second, and headed as the alternative it is: the Store stays the
    // cheaper, primary route on Windows.
    PurchaseRoute(
      id: PurchaseRouteId.direct,
      url: windowsBuyUrl,
      titleKey: 'web-buy-title',
      detailKey: 'win-web-buy-detail-text',
      priceKey: 'web-price-format',
      buttonKey: 'web-buy-btn',
      lookupKey: proWindowsLookupKey,
    ),
  ];
}

/// The i18n key for the licence-key entry blurb. Only the Mac hands the key
/// over automatically after checkout, so only the Mac's copy says so.
///
/// The Windows copy also has to stop claiming that a Store copy unlocks
/// itself once that is only true of the ones bought before the listing went
/// free — anyone reading this text is not entitled, so for them it is
/// simply wrong, and it is where they are told what to do instead.
String activateDetailKeyFor({required bool apple, bool storeSellsPro = true}) {
  if (apple) return 'activate-detail-text';
  return storeSellsPro
      ? 'win-activate-detail-text'
      : 'win-activate-free-detail-text';
}

/// The i18n key for "we looked and found nothing" after a re-check.
///
/// While the Store sells Pro, not finding it means the user is on the wrong
/// build and the copy says so. Once it is free that advice would send them
/// to a download that grants nothing, so the free-era copy points at the
/// licence key instead.
String restoreNotFoundKeyFor({required bool storeSellsPro}) =>
    storeSellsPro ? 'restore-notfound-text' : 'restore-notfound-free-text';
