import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/deep_link.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Stands in for the licence service. [body] is what the next call answers;
/// [lastLicense] and [lastQuery] record what the app actually sent.
class _LicenseAdapter implements HttpClientAdapter {
  _LicenseAdapter(this.body);

  final Map<String, Object?> body;

  String? lastLicense;
  Map<String, dynamic> lastQuery = const {};
  int calls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    lastLicense = options.queryParameters['license'] as String?;
    lastQuery = Map<String, dynamic>.of(options.queryParameters);
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) => Dio()..httpClientAdapter = adapter;

/// An adapter whose every call fails, as if the machine were offline.
class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException.connectionError(
        requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LicenseManager.storeInstallCheckOverride = () => false;
    LicenseManager.httpOverride = null;
    await LicenseManager().init();
  });

  tearDown(() async {
    LicenseManager.storeInstallCheckOverride = null;
    LicenseManager.httpOverride = null;
    await LicenseManager().clearLicense();
  });

  group('deep link parsing', () {
    test('reads the key out of the link the website hands over', () {
      final key = DeepLinkService.licenseKeyOf(
          Uri.parse('wslmanager://license?key=WSLM-ABCDE-FGHJK-LMNPQ-RSTUV'));

      expect(key, 'WSLM-ABCDE-FGHJK-LMNPQ-RSTUV');
    });

    test('accepts the path spelling as well as the host spelling', () {
      expect(
          DeepLinkService.licenseKeyOf(Uri.parse('wslmanager:license?key=K')),
          'K');
    });

    test('ignores a link that is not ours', () {
      expect(
          DeepLinkService.licenseKeyOf(Uri.parse('https://example.com/?key=K')),
          isNull);
      expect(DeepLinkService.licenseKeyOf(Uri.parse('wslmanager://open?key=K')),
          isNull);
    });

    test('a link with no key activates nothing', () {
      expect(DeepLinkService.licenseKeyOf(Uri.parse('wslmanager://license')),
          isNull);
      expect(
          DeepLinkService.licenseKeyOf(Uri.parse('wslmanager://license?key=')),
          isNull);
    });

    test('a platform with no runner side reports no pending link', () async {
      // Windows and Linux never register the scheme, so the channel throws
      // MissingPluginException rather than answering.
      final service = DeepLinkService(
          channel: const MethodChannel('wslmanager/absent-channel'));

      expect(await service.takePendingLink(), isNull);
    });
  });

  group('key activation', () {
    test('a valid key unlocks Pro and is remembered', () async {
      final adapter =
          _LicenseAdapter({'valid': true, 'plan': 'pro', 'is_trial': false});
      LicenseManager.httpOverride = _dioWith(adapter);

      final result =
          await LicenseManager().activate('wslm-abcde-fghjk-lmnpq-rstuv');

      expect(result, LicenseActivation.success);
      expect(LicenseManager().isPro, true);
      expect(LicenseManager().isKeyLicensed, true);
      expect(LicenseManager().plan, LicensePlan.pro);
      expect(LicenseManager().getPlanText(), 'plan-pro');
      // Stored upper-cased, which is how the website prints it.
      expect(prefs.getString('WebLicenseKey'), 'WSLM-ABCDE-FGHJK-LMNPQ-RSTUV');
    });

    test('the key is sent upper-cased, whatever the user pasted', () async {
      final adapter = _LicenseAdapter({'valid': true});
      LicenseManager.httpOverride = _dioWith(adapter);

      await LicenseManager().activate('  wslm-abcde-fghjk-lmnpq-rstuv  ');

      expect(adapter.lastLicense, 'WSLM-ABCDE-FGHJK-LMNPQ-RSTUV');
    });

    test('a commercial key reports its plan and seats', () async {
      LicenseManager.httpOverride = _dioWith(
          _LicenseAdapter({'valid': true, 'plan': 'commercial', 'seats': 25}));

      await LicenseManager().activate('WSLM-COMME-RCIAL-KEYXX-YYYYY');

      expect(LicenseManager().plan, LicensePlan.commercial);
      expect(LicenseManager().licenseSeats, 25);
      expect(LicenseManager().getPlanText(), 'plan-commercial');
    });

    test('a rejected key unlocks nothing and is not stored', () async {
      LicenseManager.httpOverride =
          _dioWith(_LicenseAdapter({'valid': false, 'reason': 'expired'}));

      final result =
          await LicenseManager().activate('WSLM-NOPE0-NOPE0-NOPE0-NOPE0');

      expect(result, LicenseActivation.invalid);
      expect(LicenseManager().isPro, false);
      expect(prefs.getString('WebLicenseKey'), isNull);
    });

    test('an empty key never reaches the network', () async {
      final adapter = _LicenseAdapter({'valid': true});
      LicenseManager.httpOverride = _dioWith(adapter);

      expect(await LicenseManager().activate('   '), LicenseActivation.invalid);
      expect(adapter.calls, 0);
    });

    test('an unreachable service is not a rejection', () async {
      LicenseManager.httpOverride = _dioWith(_OfflineAdapter());

      final result =
          await LicenseManager().activate('WSLM-AAAAA-AAAAA-AAAAA-AAAAA');

      expect(result, LicenseActivation.network);
      expect(prefs.getString('WebLicenseKey'), isNull);
    });
  });

  group('cached entitlement', () {
    test('a licence validated recently survives a restart offline', () async {
      LicenseManager.httpOverride = _dioWith(_LicenseAdapter({'valid': true}));
      await LicenseManager().activate('WSLM-CACHE-DCACH-EDCAC-HEDXX');
      expect(LicenseManager().isPro, true);

      // Restart with no network at all.
      LicenseManager.httpOverride = _dioWith(_OfflineAdapter());
      await LicenseManager().init();

      expect(LicenseManager().isPro, true);
    });

    test('a licence that has not checked in past the grace window stops',
        () async {
      LicenseManager.httpOverride = _dioWith(_LicenseAdapter({'valid': true}));
      await LicenseManager().activate('WSLM-STALE-STALE-STALE-STALE');

      // Backdate the last successful check beyond the offline grace.
      final longAgo = DateTime.now()
          .subtract(LicenseManager.offlineGrace + const Duration(days: 1));
      await prefs.setInt('WebLicenseCheckedAt', longAgo.millisecondsSinceEpoch);

      LicenseManager.httpOverride = _dioWith(_OfflineAdapter());
      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
    });

    test('revalidation that comes back invalid drops Pro', () async {
      LicenseManager.httpOverride = _dioWith(_LicenseAdapter({'valid': true}));
      await LicenseManager().activate('WSLM-REFUN-DEDXX-XXXXX-XXXXX');
      expect(LicenseManager().isPro, true);

      LicenseManager.httpOverride =
          _dioWith(_LicenseAdapter({'valid': false, 'reason': 'revoked'}));
      await LicenseManager().revalidate();

      expect(LicenseManager().isPro, false);
      expect(prefs.getBool('WebLicenseValid'), false);
    });

    test('clearing forgets the licence entirely', () async {
      LicenseManager.httpOverride = _dioWith(_LicenseAdapter({'valid': true}));
      await LicenseManager().activate('WSLM-BYEBY-EBYEB-YEBYE-BYEXX');

      await LicenseManager().clearLicense();

      expect(LicenseManager().isPro, false);
      expect(LicenseManager().licenseKey, isNull);
      expect(prefs.getString('WebLicenseKey'), isNull);
    });

    test('init no longer wipes the key it depends on', () async {
      // The legacy-prefs cleanup removes 'LicenseKey'; the live entitlement
      // deliberately lives under a different name so the two cannot collide.
      LicenseManager.httpOverride = _dioWith(_LicenseAdapter({'valid': true}));
      await LicenseManager().activate('WSLM-KEEPK-EEPKE-EPKEE-PKEEP');

      await LicenseManager().init();

      expect(prefs.getString('WebLicenseKey'), 'WSLM-KEEPK-EEPKE-EPKEE-PKEEP');
      expect(LicenseManager().isPro, true);
    });
  });

  group('seats', () {
    final uuidV4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

    test('a typed-in key activates and names this install', () async {
      final adapter = _LicenseAdapter({'valid': true});
      LicenseManager.httpOverride = _dioWith(adapter);

      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');

      expect(adapter.lastQuery['action'], 'activate');
      final device = adapter.lastQuery['device'] as String;
      expect(device, matches(uuidV4));
      expect(prefs.getString('WebLicenseDevice'), device);
    });

    test('the install id is random, not read off the hardware, and is kept',
        () async {
      final adapter = _LicenseAdapter({'valid': true});
      LicenseManager.httpOverride = _dioWith(adapter);

      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      final first = adapter.lastQuery['device'];
      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      expect(adapter.lastQuery['device'], first,
          reason: 'one install, one id, however often it activates');

      // A different install — fresh prefs — gets a different id.
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      expect(adapter.lastQuery['device'], isNot(first));
    });

    test('the background re-check says so, and never takes a seat', () async {
      final adapter = _LicenseAdapter({'valid': true});
      LicenseManager.httpOverride = _dioWith(adapter);
      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      final device = adapter.lastQuery['device'];

      await LicenseManager().revalidate();

      expect(adapter.calls, 2);
      expect(adapter.lastQuery['action'], 'revalidate');
      expect(adapter.lastQuery['device'], device);
      expect(adapter.lastLicense, 'WSLM-SEATS-SEATS-SEATS-SEATS');
    });

    test(
        'a seat lost to another PC switches Pro off until the key is entered again',
        () async {
      LicenseManager.httpOverride =
          _dioWith(_LicenseAdapter({'valid': true, 'seats': 1}));
      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      expect(LicenseManager().isPro, true);

      // The other PC activated meanwhile; our re-check is turned away.
      LicenseManager.httpOverride = _dioWith(_LicenseAdapter(
          {'valid': false, 'reason': 'seat_taken', 'seats_used': 1}));
      await LicenseManager().revalidate();
      expect(LicenseManager().isPro, false);
      expect(prefs.getString('WebLicenseKey'), 'WSLM-SEATS-SEATS-SEATS-SEATS',
          reason: 'the key stays so the user can move the seat back');

      // Entering the key again is an activation, and activations win.
      final adapter = _LicenseAdapter({'valid': true});
      LicenseManager.httpOverride = _dioWith(adapter);
      final result =
          await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      expect(result, LicenseActivation.success);
      expect(adapter.lastQuery['action'], 'activate');
      expect(LicenseManager().isPro, true);
    });

    test('clearing the licence forgets the install id too', () async {
      final adapter = _LicenseAdapter({'valid': true});
      LicenseManager.httpOverride = _dioWith(adapter);
      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      final before = adapter.lastQuery['device'];

      await LicenseManager().clearLicense();
      expect(prefs.getString('WebLicenseDevice'), isNull);

      await LicenseManager().activate('WSLM-SEATS-SEATS-SEATS-SEATS');
      expect(adapter.lastQuery['device'], isNot(before));
    });
  });
}
