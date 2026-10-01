// What Pro costs, in the buyer's own currency.
//
// The prices live in Stripe, and wslmanager.com publishes them once a day
// as https://wslmanager.com/pricing.json — every price in every currency it
// is offered in, plus the maps from a region and a time zone to a currency
// that the website itself quotes with. The app fetches that document, keeps
// the last one it saw, and ships US dollar amounts as the fallback, so the
// licence screen always has a number even offline and on first launch.
//
// The currency is decided the way the website decides it: from where the
// machine says it is, never from the UI language. A German developer runs
// an English app more often than not and would otherwise be quoted dollars.
// Stripe settles the real currency at checkout from the billing address, so
// a wrong guess costs nothing worse than a price in dollars.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';

/// The currency every price is guaranteed to carry.
const String defaultCurrency = 'USD';

/// The Stripe lookup keys the document is keyed by.
const String proWindowsLookupKey = 'pro_windows';
const String proMacosLookupKey = 'pro_macos';
const String commercialSeatLookupKey = 'commercial_seat';

const List<String> _lookupKeys = [
  proWindowsLookupKey,
  proMacosLookupKey,
  commercialSeatLookupKey,
];

/// One price in one currency, with the string to show for it.
@immutable
class LocalizedPrice {
  LocalizedPrice({required this.amount, required this.currency})
      : text = formatPrice(amount, currency);

  final num amount;

  /// ISO 4217, upper case.
  final String currency;

  /// "€14.99", "CHF 15", "¥2,200".
  final String text;

  @override
  String toString() => text;
}

// Symbols for the currencies the prices are offered in. Anything else is
// written with its code, the way the website does it: "SEK 159".
const Map<String, String> _symbols = {
  'USD': '\$',
  'EUR': '€',
  'GBP': '£',
  'JPY': '¥',
  'KRW': '₩',
  'INR': '₹',
  'BRL': 'R\$',
  'CAD': 'CA\$',
  'AUD': 'A\$',
  'NZD': 'NZ\$',
  'MXN': 'MX\$',
  'HKD': 'HK\$',
  'SGD': 'SG\$',
  'PHP': '₱',
  'THB': '฿',
  'VND': '₫',
  'TRY': '₺',
  'PLN': 'zł',
  'CZK': 'Kč',
  'ZAR': 'R',
};

/// "€14.99", "CHF 15", "¥2,200": the amount as a price, formatted the
/// English way whatever the UI language, because the rest of the licence
/// screen's copy is what decides the punctuation around it. Whole amounts
/// drop the fraction, so a commercial seat reads "$99" and not "$99.00".
/// A currency without a well-known symbol is written with its code and a
/// non-breaking space, so "SEK" and "159" never end up on different lines.
String formatPrice(num amount, String currency) {
  final code = currency.toUpperCase();
  final whole = amount == amount.roundToDouble();
  final number = NumberFormat(whole ? '#,##0' : '#,##0.00', 'en_US')
      .format(amount);
  final symbol = _symbols[code];
  if (symbol == null) return '$code $number';
  // Symbols that end in a letter or a currency sign read as one word with
  // the number; "zł" and "Kč" go after it, as they are written.
  if (code == 'PLN' || code == 'CZK') return '$number $symbol';
  return '$symbol$number';
}

/// The document wslmanager.com publishes: the prices and the two maps.
@immutable
class PricingCatalog {
  const PricingCatalog({
    required this.fetchedAt,
    required this.prices,
    this.regions = const {},
    this.timeZones = const {},
    this.timeZonePrefixes = const {},
  });

  /// When the website last read the prices out of Stripe; null for the
  /// amounts compiled into the app.
  final DateTime? fetchedAt;

  /// Lookup key → currency (lower case) → amount in that currency.
  final Map<String, Map<String, num>> prices;

  /// Region ("DE") → currency ("EUR").
  final Map<String, String> regions;

  /// IANA time zone ("Europe/Berlin") → currency.
  final Map<String, String> timeZones;

  /// Time zone prefix ("Australia/") → currency.
  final Map<String, String> timeZonePrefixes;

  /// The US dollar amounts the app ships with, for before the first fetch
  /// and for when the website cannot be reached. Update these when the
  /// Stripe prices change; a stale fallback only shows until the next
  /// successful fetch.
  static const PricingCatalog bundled = PricingCatalog(
    fetchedAt: null,
    prices: {
      proWindowsLookupKey: {'usd': 29},
      proMacosLookupKey: {'usd': 34},
      commercialSeatLookupKey: {'usd': 99},
    },
  );

  /// Parses the published document. Throws [FormatException] rather than
  /// returning a partial catalogue: a document missing a plan, or a plan
  /// missing its US dollar amount, would leave a card with no price, and
  /// the caller has a good catalogue to keep instead.
  factory PricingCatalog.fromJson(Map<String, dynamic> json) {
    final rawPrices = json['prices'];
    if (rawPrices is! Map) {
      throw const FormatException('pricing document has no "prices"');
    }
    final prices = <String, Map<String, num>>{};
    for (final key in _lookupKeys) {
      final table = rawPrices[key];
      if (table is! Map) {
        throw FormatException('pricing document has no price "$key"');
      }
      final amounts = <String, num>{};
      table.forEach((currency, amount) {
        if (currency is String && amount is num && amount > 0) {
          amounts[currency.toLowerCase()] = amount;
        }
      });
      if (amounts['usd'] == null) {
        throw FormatException('price "$key" has no US dollar amount');
      }
      prices[key] = amounts;
    }

    Map<String, String> strings(Object? raw) {
      if (raw is! Map) return const {};
      return {
        for (final entry in raw.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: (entry.value as String).toUpperCase(),
      };
    }

    final fetchedAt = json['fetchedAt'];
    return PricingCatalog(
      fetchedAt: fetchedAt is String ? DateTime.tryParse(fetchedAt) : null,
      prices: prices,
      regions: strings(json['regions']),
      timeZones: strings(json['timeZones']),
      timeZonePrefixes: strings(json['timeZonePrefixes']),
    );
  }

  /// The currency for a machine in [region] and [timeZone], the region
  /// first. The region is the OS's own "country or region" setting, which
  /// is what a person in Germany with an English system has set to
  /// Germany; the time zone is the fallback when the region is unknown
  /// or not one the prices are offered in. Anything else is US dollars.
  String currencyFor({String? region, String? timeZone}) {
    final byRegion = regions[region?.toUpperCase()];
    if (byRegion != null) return byRegion;
    if (timeZone != null && timeZone.isNotEmpty) {
      final byZone = timeZones[timeZone];
      if (byZone != null) return byZone;
      for (final entry in timeZonePrefixes.entries) {
        if (timeZone.startsWith(entry.key)) return entry.value;
      }
    }
    return defaultCurrency;
  }

  /// The price for [lookupKey] in [currency], or in US dollars when it is
  /// not offered in that currency, or null for a plan the catalogue does
  /// not have.
  LocalizedPrice? priceOf(String lookupKey, String currency) {
    final amounts = prices[lookupKey];
    if (amounts == null) return null;
    final code = currency.toLowerCase();
    final amount = amounts[code];
    if (amount != null) {
      return LocalizedPrice(amount: amount, currency: code.toUpperCase());
    }
    final usd = amounts['usd'];
    if (usd == null) return null;
    return LocalizedPrice(amount: usd, currency: defaultCurrency);
  }

  Map<String, dynamic> toJson() => {
        if (fetchedAt != null) 'fetchedAt': fetchedAt!.toIso8601String(),
        'prices': prices,
        'regions': regions,
        'timeZones': timeZones,
        'timeZonePrefixes': timeZonePrefixes,
      };
}

/// Where the machine says it is: the OS region setting and the IANA time
/// zone, either of which may be unknown.
@immutable
class SystemLocation {
  const SystemLocation({this.region, this.timeZone});

  final String? region;
  final String? timeZone;

  /// Reads the location off the running OS. Every probe is best effort and
  /// none throws: a machine that answers nothing is quoted in dollars.
  static Future<SystemLocation> detect({Shell? shell}) async {
    final sh = shell ?? ProcessShell();
    String? region;
    String? timeZone;
    try {
      if (Platform.isWindows) {
        // "Country or region" in Settings, which is where a person's home
        // is, independent of the display language.
        final result = await sh.run('reg', [
          'query',
          r'HKCU\Control Panel\International\Geo',
          '/v',
          'Name',
        ]);
        region = regionFromRegQuery(result.stdout.toString());
      } else if (Platform.isMacOS) {
        // The region half of the system locale: "en_DE" for English in
        // Germany, which is exactly the case the UI language gets wrong.
        final locale = await sh.run('defaults', ['read', '-g', 'AppleLocale']);
        region = regionFromLocale(locale.stdout.toString());
        final link = await sh.run('readlink', ['/etc/localtime']);
        timeZone = timeZoneFromLocaltime(link.stdout.toString());
      } else {
        timeZone = Platform.environment['TZ'];
        if (timeZone == null || timeZone.isEmpty) {
          final link = await sh.run('readlink', ['-f', '/etc/localtime']);
          timeZone = timeZoneFromLocaltime(link.stdout.toString());
        }
      }
    } catch (e) {
      logInfo('pricing: could not read the system region: $e');
    }
    region ??= regionFromLocale(Platform.localeName);
    return SystemLocation(region: region, timeZone: timeZone);
  }

  /// The region in `reg query` output such as
  /// `    Name    REG_SZ    DE`, or null.
  static String? regionFromRegQuery(String output) {
    final match = RegExp(r'^\s*Name\s+REG_SZ\s+(\S+)\s*$', multiLine: true)
        .firstMatch(output);
    return _region(match?.group(1));
  }

  /// The region in a locale such as `en_DE`, `de-DE`, `en_DE@rg=chzzzz`
  /// or `en_US.UTF-8`, or null when the locale names none.
  static String? regionFromLocale(String locale) {
    final match = RegExp(r'^[A-Za-z]{2,3}[_-]([A-Za-z]{2})(?:[@.\s]|$)')
        .firstMatch(locale.trim());
    return _region(match?.group(1));
  }

  /// The IANA zone in the `/etc/localtime` link target, such as
  /// `/var/db/timezone/zoneinfo/Europe/Berlin`, or null.
  static String? timeZoneFromLocaltime(String target) {
    final match =
        RegExp(r'zoneinfo/([A-Za-z_]+(?:/[A-Za-z_+\-0-9]+)*)\s*$')
            .firstMatch(target.trim());
    return match?.group(1);
  }

  static String? _region(String? raw) {
    if (raw == null) return null;
    final region = raw.toUpperCase();
    return RegExp(r'^[A-Z]{2}$').hasMatch(region) ? region : null;
  }
}

/// The prices to show right now: one per plan, all in one currency.
@immutable
class PricingQuote {
  const PricingQuote({required this.currency, required this.prices});

  final String currency;

  /// Lookup key → price. Every plan in the catalogue is here.
  final Map<String, LocalizedPrice> prices;

  LocalizedPrice? operator [](String lookupKey) => prices[lookupKey];

  /// The compiled-in US dollar prices, for before anything has been read.
  static PricingQuote bundled() => quoteFrom(PricingCatalog.bundled,
      const SystemLocation(region: 'US', timeZone: null));

  static PricingQuote quoteFrom(
      PricingCatalog catalog, SystemLocation location) {
    final currency = catalog.currencyFor(
        region: location.region, timeZone: location.timeZone);
    return PricingQuote(currency: currency, prices: {
      for (final key in catalog.prices.keys)
        if (catalog.priceOf(key, currency) != null)
          key: catalog.priceOf(key, currency)!,
    });
  }
}

/// Fetches, caches and quotes the published prices.
class PricingService {
  factory PricingService() => _instance;
  PricingService._();
  static final PricingService _instance = PricingService._();

  /// Test seams.
  @visibleForTesting
  static Dio? httpOverride;
  @visibleForTesting
  static Shell? shellOverride;
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Test seam for the screen: the whole quote, so a widget test never
  /// reaches for the network or the OS.
  @visibleForTesting
  static Future<PricingQuote> Function()? quoteOverride;

  static const String catalogPref = 'pricingCatalog';
  static const String catalogFetchedPref = 'pricingCatalogFetchedAtMs';

  /// How long a fetched document is trusted before the site is asked again.
  /// The site itself rebuilds daily, so asking more often gains nothing.
  static const Duration maxAge = Duration(hours: 24);

  Dio get _dio => httpOverride ?? Dio();

  /// The last document fetched, or the compiled-in one.
  PricingCatalog cached() {
    final raw = prefs.getString(catalogPref);
    if (raw == null) return PricingCatalog.bundled;
    try {
      return PricingCatalog.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (e) {
      logInfo('pricing: cached document unreadable, using bundled: $e');
      return PricingCatalog.bundled;
    }
  }

  /// Whether the cached document is recent enough to skip the network.
  bool _cacheIsFresh() {
    final at = prefs.getInt(catalogFetchedPref);
    if (at == null || prefs.getString(catalogPref) == null) return false;
    final age = now().difference(DateTime.fromMillisecondsSinceEpoch(at));
    return age >= Duration.zero && age < maxAge;
  }

  /// The catalogue: the cached one while it is fresh, otherwise a fresh
  /// fetch, and the cached or bundled one when the fetch fails. Never
  /// throws, and never blocks for long — the screen shows the fallback
  /// meanwhile.
  Future<PricingCatalog> load({bool force = false}) async {
    if (!force && _cacheIsFresh()) return cached();
    try {
      final response = await _dio.get<dynamic>(
        pricingUrl,
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
        ),
      );
      final body = response.data;
      final map = body is String
          ? json.decode(body) as Map<String, dynamic>
          : body as Map<String, dynamic>;
      final catalog = PricingCatalog.fromJson(map);
      await prefs.setString(catalogPref, json.encode(catalog.toJson()));
      await prefs.setInt(catalogFetchedPref, now().millisecondsSinceEpoch);
      return catalog;
    } catch (e) {
      logInfo('pricing: could not fetch $pricingUrl: $e');
      return cached();
    }
  }

  /// The prices to show this machine, in its currency.
  Future<PricingQuote> quote() async {
    final override = quoteOverride;
    if (override != null) return override();
    final catalog = await load();
    final location = await SystemLocation.detect(shell: shellOverride);
    return PricingQuote.quoteFrom(catalog, location);
  }
}
