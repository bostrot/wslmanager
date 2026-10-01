import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/pricing.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Answers every request with one body, or refuses them all.
class _Adapter implements HttpClientAdapter {
  _Adapter({this.body});

  final Object? body;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests++;
    if (body == null) throw const SocketException('offline');
    return ResponseBody.fromString(
        body is String ? body as String : jsonEncode(body), 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

/// Answers `reg`, `defaults` and `readlink` the way one machine would.
class _MachineShell implements Shell {
  _MachineShell(this.answers);

  final Map<String, String> answers;

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      Encoding? stdoutEncoding = systemEncoding,
      Encoding? stderrEncoding = systemEncoding}) async {
    return ProcessResult(0, 0, answers[executable] ?? '', '');
  }

  @override
  Future<Process> start(String executable, List<String> arguments,
          {String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true,
          bool runInShell = false,
          ProcessStartMode mode = ProcessStartMode.normal}) =>
      throw UnimplementedError();
}

/// The document wslmanager.com publishes, cut down.
Map<String, dynamic> document({String fetchedAt = '2026-09-20T16:28:21Z'}) =>
    {
      'fetchedAt': fetchedAt,
      'prices': {
        'pro_windows': {'usd': 14.99, 'eur': 14.99, 'jpy': 2200, 'inr': 499},
        'pro_macos': {'usd': 19.99, 'eur': 19.99, 'jpy': 2900, 'inr': 699},
        'commercial_seat': {'usd': 99, 'eur': 99, 'jpy': 14800, 'inr': 3999},
      },
      'regions': {'DE': 'EUR', 'AT': 'EUR', 'JP': 'JPY', 'IN': 'INR', 'US': 'USD'},
      'timeZones': {'Europe/Berlin': 'EUR', 'Asia/Tokyo': 'JPY'},
      'timeZonePrefixes': {'Australia/': 'AUD'},
    };

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    PricingService.httpOverride = null;
    PricingService.shellOverride = null;
    PricingService.now = DateTime.now;
  });

  tearDown(() {
    PricingService.httpOverride = null;
    PricingService.shellOverride = null;
    PricingService.now = DateTime.now;
  });

  group('formatPrice', () {
    test('keeps cents and drops them from whole amounts', () {
      expect(formatPrice(14.99, 'USD'), '\$14.99');
      expect(formatPrice(14.99, 'EUR'), '€14.99');
      expect(formatPrice(99, 'USD'), '\$99');
      expect(formatPrice(99.0, 'EUR'), '€99');
      expect(formatPrice(2200, 'JPY'), '¥2,200');
      expect(formatPrice(129000, 'VND'), '₫129,000');
    });

    test('writes a currency without a symbol by its code', () {
      expect(formatPrice(15, 'CHF'), 'CHF 15');
      expect(formatPrice(159, 'sek'), 'SEK 159');
      expect(formatPrice(59.99, 'PLN'), '59.99 zł');
    });
  });

  group('PricingCatalog', () {
    test('parses the published document', () {
      final catalog = PricingCatalog.fromJson(document());
      expect(catalog.fetchedAt, DateTime.parse('2026-09-20T16:28:21Z'));
      expect(catalog.prices['pro_windows']!['eur'], 14.99);
      expect(catalog.regions['DE'], 'EUR');
      expect(catalog.timeZones['Asia/Tokyo'], 'JPY');
    });

    test('refuses a document missing a plan or its dollar amount', () {
      final noPlan = document()..['prices'].remove('pro_macos');
      expect(() => PricingCatalog.fromJson(noPlan), throwsFormatException);
      final noUsd = document();
      (noUsd['prices']['pro_windows'] as Map).remove('usd');
      expect(() => PricingCatalog.fromJson(noUsd), throwsFormatException);
      expect(() => PricingCatalog.fromJson({}), throwsFormatException);
    });

    test('the region wins, then the time zone, then dollars', () {
      final catalog = PricingCatalog.fromJson(document());
      expect(catalog.currencyFor(region: 'DE', timeZone: 'Asia/Tokyo'), 'EUR');
      expect(catalog.currencyFor(region: 'de'), 'EUR');
      expect(catalog.currencyFor(region: 'AQ', timeZone: 'Asia/Tokyo'), 'JPY');
      expect(
          catalog.currencyFor(region: null, timeZone: 'Australia/Perth'), 'AUD');
      expect(catalog.currencyFor(region: 'AQ', timeZone: 'UTC'), 'USD');
      expect(catalog.currencyFor(), 'USD');
    });

    test('a plan not offered in the currency is quoted in dollars', () {
      final catalog = PricingCatalog.fromJson(document());
      expect(catalog.priceOf('pro_windows', 'EUR')!.text, '€14.99');
      expect(catalog.priceOf('pro_windows', 'CHF')!.text, '\$14.99');
      expect(catalog.priceOf('pro_windows', 'CHF')!.currency, 'USD');
      expect(catalog.priceOf('no_such_plan', 'EUR'), isNull);
    });

    test('the compiled-in catalogue quotes every plan in dollars', () {
      final quote = PricingQuote.bundled();
      expect(quote.currency, 'USD');
      expect(quote[proWindowsLookupKey]!.text, '\$29');
      expect(quote[proMacosLookupKey]!.text, '\$34');
      expect(quote[commercialSeatLookupKey]!.text, '\$99');
    });

    test('survives a round trip through the cache', () {
      final catalog = PricingCatalog.fromJson(document());
      final again = PricingCatalog.fromJson(
          json.decode(json.encode(catalog.toJson())) as Map<String, dynamic>);
      expect(again.prices, catalog.prices);
      expect(again.regions, catalog.regions);
      expect(again.fetchedAt, catalog.fetchedAt);
    });
  });

  group('SystemLocation', () {
    test('reads the region out of reg query', () {
      expect(
          SystemLocation.regionFromRegQuery('\r\n'
              'HKEY_CURRENT_USER\\Control Panel\\International\\Geo\r\n'
              '    Name    REG_SZ    DE\r\n\r\n'),
          'DE');
      expect(SystemLocation.regionFromRegQuery('ERROR: The system was unable'),
          isNull);
    });

    test('reads the region out of a locale, whatever the language', () {
      expect(SystemLocation.regionFromLocale('en_DE'), 'DE');
      expect(SystemLocation.regionFromLocale('en_DE@rg=chzzzz'), 'DE');
      expect(SystemLocation.regionFromLocale('de-AT\n'), 'AT');
      expect(SystemLocation.regionFromLocale('en_US.UTF-8'), 'US');
      expect(SystemLocation.regionFromLocale('en'), isNull);
      expect(SystemLocation.regionFromLocale('C'), isNull);
      expect(SystemLocation.regionFromLocale(''), isNull);
    });

    test('reads the zone out of the localtime link', () {
      expect(
          SystemLocation.timeZoneFromLocaltime(
              '/var/db/timezone/zoneinfo/Europe/Berlin\n'),
          'Europe/Berlin');
      expect(
          SystemLocation.timeZoneFromLocaltime(
              '/usr/share/zoneinfo/America/Argentina/Buenos_Aires'),
          'America/Argentina/Buenos_Aires');
      expect(SystemLocation.timeZoneFromLocaltime('/usr/share/zoneinfo/UTC'),
          'UTC');
      expect(SystemLocation.timeZoneFromLocaltime(''), isNull);
    });

    test('an English macOS set to Germany is a machine in Germany', () async {
      final location = await SystemLocation.detect(
          shell: _MachineShell({
        'defaults': 'en_DE\n',
        'readlink': '/var/db/timezone/zoneinfo/Europe/Berlin\n',
      }));
      if (Platform.isMacOS) {
        expect(location.region, 'DE');
        expect(location.timeZone, 'Europe/Berlin');
      } else {
        // Off a Mac the probe is not run; whatever the host says stands.
        expect(location, isA<SystemLocation>());
      }
    }, skip: !Platform.isMacOS && !Platform.isWindows);
  });

  group('PricingService', () {
    test('fetches, caches and quotes in the machine\'s currency', () async {
      final adapter = _Adapter(body: document());
      PricingService.httpOverride = Dio()..httpClientAdapter = adapter;
      PricingService.shellOverride = _MachineShell({
        'defaults': 'en_DE\n',
        'reg': '    Name    REG_SZ    DE\r\n',
        'readlink': '/var/db/timezone/zoneinfo/Europe/Berlin\n',
      });

      final catalog = await PricingService().load();
      expect(adapter.requests, 1);
      expect(catalog.prices['pro_macos']!['eur'], 19.99);
      expect(prefs.getString(PricingService.catalogPref), isNotNull);

      // Fresh: the second load never touches the network.
      await PricingService().load();
      expect(adapter.requests, 1);
    });

    test('asks again once the cached document is a day old', () async {
      final adapter = _Adapter(body: document());
      PricingService.httpOverride = Dio()..httpClientAdapter = adapter;
      var clock = DateTime.utc(2026, 9, 20, 12);
      PricingService.now = () => clock;

      await PricingService().load();
      clock = clock.add(const Duration(hours: 23));
      await PricingService().load();
      expect(adapter.requests, 1);
      clock = clock.add(const Duration(hours: 2));
      await PricingService().load();
      expect(adapter.requests, 2);
    });

    test('offline, the last document fetched is what is quoted', () async {
      PricingService.httpOverride = Dio()
        ..httpClientAdapter = _Adapter(body: document());
      await PricingService().load();

      PricingService.httpOverride = Dio()..httpClientAdapter = _Adapter();
      final catalog = await PricingService().load(force: true);
      expect(catalog.prices['pro_windows']!['eur'], 14.99);
    });

    test('offline with nothing cached, the compiled-in dollars are quoted',
        () async {
      PricingService.httpOverride = Dio()..httpClientAdapter = _Adapter();
      final catalog = await PricingService().load();
      expect(catalog.fetchedAt, isNull);
      expect(catalog.prices, PricingCatalog.bundled.prices);
    });

    test('a broken document is not cached over a good one', () async {
      PricingService.httpOverride = Dio()
        ..httpClientAdapter = _Adapter(body: document());
      await PricingService().load();

      PricingService.httpOverride = Dio()
        ..httpClientAdapter = _Adapter(body: {'prices': {}});
      final catalog = await PricingService().load(force: true);
      expect(catalog.prices['pro_windows']!['eur'], 14.99);
    });

    test('the quote is the catalogue read through the machine\'s location',
        () async {
      PricingService.httpOverride = Dio()
        ..httpClientAdapter = _Adapter(body: document());
      PricingService.shellOverride = _MachineShell({
        'defaults': 'ja_JP\n',
        'reg': '    Name    REG_SZ    JP\r\n',
        'readlink': '/var/db/timezone/zoneinfo/Asia/Tokyo\n',
      });
      final quote = await PricingService().quote();
      if (Platform.isMacOS || Platform.isWindows) {
        expect(quote.currency, 'JPY');
        expect(quote[proMacosLookupKey]!.text, '¥2,900');
        expect(quote[commercialSeatLookupKey]!.text, '¥14,800');
      }
      expect(quote.prices.keys, containsAll(PricingCatalog.bundled.prices.keys));
    });

    test('the document is fetched from the website, over https', () {
      final url = Uri.parse(pricingUrl);
      expect(url.scheme, 'https');
      expect(url.host, 'wslmanager.com');
      expect(url.path, '/pricing.json');
    });
  });
}
