import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/rating_prompt.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  final now = DateTime.utc(2026, 11, 19, 12);

  /// An install that qualifies: second start, one success, never asked.
  const due = RatingPromptState(launches: 2, successfulActions: 1);

  RatingPromptSkip? skip(
    RatingPromptState state, {
    bool store = true,
    String version = '2.6.1',
    bool otherPromptShown = false,
  }) =>
      ratingPromptSkipReason(state,
          isStorePackaged: store,
          version: version,
          now: now,
          otherPromptShown: otherPromptShown);

  group('ratingPromptSkipReason', () {
    test('a Store install on its second start after a success is asked', () {
      expect(skip(due), isNull);
    });

    test('a non-Store install is never asked, whatever else holds', () {
      expect(skip(due, store: false), RatingPromptSkip.notStore);
      expect(
          skip(const RatingPromptState(launches: 50, successfulActions: 50),
              store: false),
          RatingPromptSkip.notStore);
    });

    test('the first start is onboarding', () {
      expect(skip(const RatingPromptState(launches: 1, successfulActions: 3)),
          RatingPromptSkip.onboarding);
    });

    test('a start that showed another prompt does not ask', () {
      expect(skip(due, otherPromptShown: true), RatingPromptSkip.onboarding);
    });

    test('nothing worked yet means no ask', () {
      expect(skip(const RatingPromptState(launches: 5)),
          RatingPromptSkip.noSuccess);
    });

    test('a failure as the last action means no ask', () {
      expect(
          skip(const RatingPromptState(
              launches: 5, successfulActions: 3, lastActionFailed: true)),
          RatingPromptSkip.lastActionFailed);
    });

    test('asked once per version', () {
      final state = RatingPromptState(
          launches: 5,
          successfulActions: 1,
          askedVersion: '2.6.1',
          askedAt: now.subtract(const Duration(days: 200)));
      expect(skip(state), RatingPromptSkip.askedThisVersion);
      expect(skip(state, version: '2.7.0'), isNull);
    });

    test('a new version still waits out the 90 days', () {
      RatingPromptState askedDaysAgo(int days) => RatingPromptState(
          launches: 5,
          successfulActions: 1,
          askedVersion: '2.6.0',
          askedAt: now.subtract(Duration(days: days)));
      expect(skip(askedDaysAgo(89)), RatingPromptSkip.askedRecently);
      expect(skip(askedDaysAgo(90)), isNull);
    });

    test('a user who rated is never asked again', () {
      expect(
          skip(const RatingPromptState(
              launches: 100, successfulActions: 100, rated: true)),
          RatingPromptSkip.rated);
    });
  });

  group('prefs', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('launches and actions are counted', () {
      recordAppLaunch();
      recordAppLaunch();
      recordSuccessfulAction();
      final state = RatingPromptState.fromPrefs();
      expect(state.launches, 2);
      expect(state.successfulActions, 1);
      expect(state.lastActionFailed, false);
    });

    test('a failure is cleared by the next success', () {
      recordSuccessfulAction();
      recordFailedAction();
      expect(RatingPromptState.fromPrefs().lastActionFailed, true);
      recordSuccessfulAction();
      expect(RatingPromptState.fromPrefs().lastActionFailed, false);
    });

    test('instances counted by the first version count as successes',
        () async {
      SharedPreferences.setMockInitialValues({'InstancesCreated': 2});
      prefs = await SharedPreferences.getInstance();
      expect(RatingPromptState.fromPrefs().successfulActions, 2);
    });

    test('an earlier "done" from the old dialog reads as rated', () async {
      SharedPreferences.setMockInitialValues({'RatingPromptDone': true});
      prefs = await SharedPreferences.getInstance();
      expect(RatingPromptState.fromPrefs().rated, true);
    });
  });

  group('maybeRequestStoreRating', () {
    var calls = 0;

    setUp(() async {
      SharedPreferences.setMockInitialValues(
          {'AppLaunches': 2, 'SuccessfulActions': 1});
      prefs = await SharedPreferences.getInstance();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      calls = 0;
    });

    tearDown(() {
      LicenseManager.storeInstallCheckOverride = null;
      StoreRatingRequester.override = null;
    });

    void answer(StoreRatingStatus? status) {
      StoreRatingRequester.override = () async {
        calls++;
        return status;
      };
    }

    test('a rating marks the install done for good', () async {
      answer(StoreRatingStatus.succeeded);
      await maybeRequestStoreRating(now: now);
      expect(calls, 1);
      expect(prefs.getBool('RatingPromptDone'), true);

      await maybeRequestStoreRating(now: now.add(const Duration(days: 999)));
      expect(calls, 1);
    });

    test('a decline waits for the next version and 90 days', () async {
      answer(StoreRatingStatus.canceled);
      await maybeRequestStoreRating(now: now);
      expect(calls, 1);
      expect(prefs.getBool('RatingPromptDone'), isNull);
      expect(prefs.getString('RatingPromptVersion'), currentVersion);
      expect(prefs.getString('RatingPromptAt'), now.toIso8601String());

      await maybeRequestStoreRating(now: now.add(const Duration(days: 1)));
      expect(calls, 1);
    });

    test('no sheet to show is silent and does not count as asked', () async {
      answer(null);
      await maybeRequestStoreRating(now: now);
      expect(calls, 1);
      expect(prefs.getString('RatingPromptVersion'), isNull);
      expect(prefs.getBool('RatingPromptDone'), isNull);
    });

    test('a non-Store install never reaches the Store', () async {
      LicenseManager.storeInstallCheckOverride = () => false;
      await LicenseManager().init();
      answer(StoreRatingStatus.succeeded);
      await maybeRequestStoreRating(now: now);
      expect(calls, 0);
      expect(prefs.getBool('RatingPromptDone'), isNull);
    });

    test('a start that showed another prompt does not ask', () async {
      answer(StoreRatingStatus.succeeded);
      await maybeRequestStoreRating(otherPromptShown: true, now: now);
      expect(calls, 0);
    });
  });

  group('StoreRatingRequester', () {
    const channel = MethodChannel('test/store-rating');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<StoreRatingStatus?> reply(Object? Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => handler(call));
      return StoreRatingRequester(channel: channel).request();
    }

    test('reads the runner statuses', () async {
      expect(await reply((call) {
        expect(call.method, 'requestRateAndReview');
        return {'status': 'succeeded', 'error': null};
      }), StoreRatingStatus.succeeded);
      expect(await reply((_) => {'status': 'canceled'}),
          StoreRatingStatus.canceled);
      expect(await reply((_) => {'status': 'networkError'}),
          StoreRatingStatus.networkError);
      expect(await reply((_) => {'status': 'error', 'error': 'winrt 0x1'}),
          StoreRatingStatus.error);
    });

    test('no runner and malformed answers read as nothing', () async {
      // No handler at all: MissingPluginException.
      expect(await StoreRatingRequester(channel: channel).request(), isNull);
      expect(await reply((_) => 'nonsense'), isNull);
      expect(
          await reply((_) => throw PlatformException(code: 'x')), isNull);
    });
  });
}
