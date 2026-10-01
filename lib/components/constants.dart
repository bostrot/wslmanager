import 'package:fluent_ui/fluent_ui.dart';

const String title = 'WSL Distro Manager by Bostrot';

/// Where macOS users buy Pro. No Microsoft Store on the Mac, so the licence
/// is sold on the website and comes back as a key.
///
/// The `utm_` pair is what tells the website's analytics that a visit came
/// from the app rather than from someone clicking "Pricing" on the site:
/// without it every arrival on /buy/ looked the same, and the app's share of
/// that traffic — and of the drop-off after it — could not be read off at
/// all. Source says it was the app, medium which build it came from, so
/// Windows and macOS users can be told apart in the same report.
const String macBuyUrl =
    "https://wslmanager.com/buy/?platform=macos&utm_source=app&utm_medium=macos";

/// Where Windows users buy Pro without going through the Microsoft Store.
/// Same shop and the same kind of key as the Mac licence; the `platform`
/// hint lets the page show the Windows price, and is ignored if it cannot.
const String windowsBuyUrl =
    "https://wslmanager.com/buy/?platform=windows&utm_source=app&utm_medium=windows";

/// The prices, in every currency they are offered in, as wslmanager.com
/// publishes them from Stripe once a day. See lib/api/pricing.dart.
const String pricingUrl = 'https://wslmanager.com/pricing.json';

/// Turns a licence key into an entitlement. Answers
/// `{"valid": true, "plan": "pro", ...}` or `{"valid": false, ...}`.
const String licenseValidateUrl =
    'https://n8n.aachen.dev/webhook/wsl-manager/validate';
const String windowsStoreUrl = "https://www.microsoft.com/store/"
    "productId/9NWS9K95NMJB";

/// When the Microsoft Store listing stops selling Pro, as an ISO-8601 UTC
/// instant — the moment the listing's base price becomes Free.
///
/// Null would mean "not scheduled", and while it was null nothing about the
/// app changed: a Store install was a paid copy, so package identity alone
/// kept granting Pro exactly as it always had. Set, the app flips with the
/// listing, without a server and without waiting for anyone to update
/// first — see doc/microsoft-store-freemium.md for the order of operations.
///
/// The instant only has to be no later than the moment the listing actually
/// goes free. Every build that carries it reaches a Store install together
/// with the price change, so an earlier instant costs nothing; a later one
/// would hand Pro to free downloads made in between.
///
/// Everything before that instant is a purchase; everything after it is a
/// free download. That single fact is what lets the two be told apart later.
// Nullable on purpose: null is the rollback (see doc/microsoft-store-freemium.md).
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? storeFreeFromUtc = '2026-09-13T00:00:00Z';

/// The first release whose Store build stops treating package identity as a
/// licence — the one that ships [storeFreeFromUtc].
///
/// An install that last ran something older than this has only ever run a
/// build from the paid era, so whoever is sitting at it bought the app. It
/// is the fallback for copies that update for the first time *after* the
/// flip and so never got the chance to record [storeFreeFromUtc] passing.
/// The last paid-era release was 2.1.0; this has to be newer than that and
/// no newer than the version in pubspec.yaml, or the shipped build declines
/// to judge (see storeGrandfathers).
const String storeFreemiumVersion = '2.2.0';

/// Opens the Store app straight on the review pane for this product.
const String storeReviewUrl =
    "ms-windows-store://review?ProductId=9NWS9K95NMJB";
const String defaultPath = 'C:\\WSL2-Distros';
const int chunkSize = 16 * 1024;
const String updateUrl =
    'https://api.github.com/repos/bostrot/wslmanager/releases';

const String motdUrl =
    'https://raw.githubusercontent.com/bostrot/wslmanager/main/motd.json';

const String defaultRepoLink =
    'http://ftp.halifax.rwth-aachen.de/turnkeylinux/images/proxmox/';

const String gitRepoLink = 'https://n8n.aachen.dev/webhook/cdn/images.json';

/// Where [gitRepoLink] caches from. Tried when the CDN answers with nothing
/// usable — on 2026-09-09 it served 200 with an empty body, and every client
/// quietly fell back to the copy bundled at build time.
const String gitRepoRawLink =
    'https://raw.githubusercontent.com/bostrot/wslmanager/main/images.json';

/// The whole community catalogue in one response: every folder's `info.yml`
/// already collected, so the browser makes one request where it used to make
/// one per script. Published on this repository's `catalogue` branch by the
/// Community catalogue workflow and read raw from there; [gitApiScriptsLink]
/// and [repoScripts] stay the fallback when it is unreachable.
String communityCatalogUrl =
    'https://raw.githubusercontent.com/bostrot/wsl2-distro-manager/catalogue/cdn/scripts.json';

String gitApiScriptsLink =
    'https://api.github.com/repos/bostrot/wsl-scripts/contents/scripts';

String repoScripts =
    'https://rawcdn.githack.com/bostrot/wsl-scripts/main/scripts/';

String gitApiCommitsLink =
    'https://api.github.com/repos/bostrot/wsl-scripts/commits';

const String githubIssues =
    'https://github.com/bostrot/wslmanager/issues/new/choose';

const String errorUrl =
    'https://n8n.aachen.dev/webhook/error-logging-1866548e-233f-4c09-a257-9f3deab055b3';

String explorerPath = '\\\\wsl.localhost';

// Wiki links
const String wikiDocker =
    'https://github.com/bostrot/wslmanager/wiki/Features#docker-images';

// Runtime cache for distro links loaded from remote source or local images.json.
Map<String, String> distroRootfsLinks = {};

/// Locales the app ships translations for.
///
/// Every entry must have a lib/i18n/<locale>.json whose name matches the
/// locale's toString(): the localization delegate throws on a missing file and
/// the failed load leaves the app rendering nothing at all. Anything else is
/// mapped onto one of these by localeResolutionCallback in main.dart.
const supportedLocalesList = [
  Locale('en', ''), // en.json
  Locale('de', ''), // de.json
  Locale('es', ''), // es.json
  Locale('hu', ''), // hu.json
  Locale('ja', ''), // ja.json
  Locale('ko', ''), // ko.json
  Locale('pt', ''), // pt.json
  Locale('tr', ''), // tr.json
  Locale('zh', 'CN'), // zh_CN.json, simplified
  Locale('zh', 'TW'), // zh_TW.json, traditional
];

/// Language picker entries: the value stored in the `language` preference
/// mapped to the language's own name.
///
/// Keys are locale tags that name a file in lib/i18n, so a picked language
/// always has a translation to load.
const languageOptions = {
  'en': 'English',
  'de': 'Deutsch',
  'es': 'Español',
  'hu': 'Magyar',
  'ja': '日本語',
  'ko': '한국어',
  'pt': 'Português',
  'tr': 'Türkçe',
  'zh_CN': '简体中文',
  'zh_TW': '繁體中文',
};

String currentVersion = "1.0.0";
