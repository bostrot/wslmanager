import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/store_acquisition.dart';
import 'package:wsl2distromanager/api/updater.dart' show compareVersions;
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/dialogs/rating_dialog.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The singleton's in-memory store flag survives across tests — pin the
    // package-identity check to a known value and re-init every time.
    LicenseManager.storeInstallCheckOverride = () => false;
    await LicenseManager().init();
  });

  tearDown(() {
    LicenseManager.storeInstallCheckOverride = null;
    LicenseManager.storeFreeFromOverride = null;
    LicenseManager.storeAcquisitionOverride = null;
  });

  /// A moment safely either side of any flip these tests schedule.
  final past = DateTime.utc(2000);
  final future = DateTime.utc(2999);

  /// What a released build reports. The repo's copy says 1.0.0 until the
  /// release workflow stamps the tag in, and the grandfather rule refuses to
  /// judge a version stamp from a build that has not been stamped itself.
  final stampedVersion = '2.9.0';

  group('Store entitlement', () {
    test('no package identity means free plan', () {
      final manager = LicenseManager();

      expect(manager.isPro, false);
      expect(manager.isStoreLicensed, false);
      expect(manager.plan, LicensePlan.none);
      expect(manager.getPlanText(), 'plan-free');
    });

    // Regression guard for the ship-blocker: `_detectStoreInstall()` once
    // began with an unconditional `return true;`, granting Pro to every
    // install. With the test seam cleared this runs the real check — an
    // unpackaged test runner, and no --dart-define=WSLM_FORCE_PRO — so it
    // only passes while neither shortcut is hard-coded on.
    test('the real detection grants nothing to an unpackaged process',
        () async {
      LicenseManager.storeInstallCheckOverride = null;

      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
      expect(LicenseManager().plan, LicensePlan.none);
    });

    test('package identity (Store install) grants Pro before the flip',
        () async {
      LicenseManager.storeInstallCheckOverride = () => true;
      LicenseManager.storeFreeFromOverride =
          DateTime.now().toUtc().add(const Duration(days: 1));
      await LicenseManager().init();

      final manager = LicenseManager();
      expect(manager.isPro, true);
      expect(manager.isStoreLicensed, true);
      expect(manager.plan, LicensePlan.store);
      expect(manager.getPlanText(), 'plan-store');
    });

    test('a Store install is recorded as entitled the first time it runs',
        () async {
      // The evidence is perishable — the flip passes and the stored version
      // is overwritten on every start — so the answer is written down.
      LicenseManager.storeInstallCheckOverride = () => true;
      LicenseManager.storeFreeFromOverride =
          DateTime.now().toUtc().add(const Duration(days: 1));
      await LicenseManager().init();

      expect(prefs.getBool(storeGrandfatheredPref), true);
    });

    test('a portable build records nothing, even next to a stale flag',
        () async {
      // The flag is about a Store copy that was paid for; on an unpackaged
      // build it is not evidence of anything.
      prefs.setBool(storeGrandfatheredPref, true);
      LicenseManager.storeInstallCheckOverride = () => false;
      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
      expect(LicenseManager().isStoreLicensed, false);
    });

    test('init clears leftover prefs from the retired Stripe experiment',
        () async {
      prefs.setString('LicenseKey', 'OLD-KEY');
      prefs.setString('LicenseStatus', 'active');
      prefs.setString('LicensePlan', 'monthly');

      await LicenseManager().init();

      expect(prefs.getString('LicenseKey'), isNull);
      expect(prefs.getString('LicenseStatus'), isNull);
      expect(prefs.getString('LicensePlan'), isNull);
    });
  });

  group('when the Store listing goes free', () {
    late String realVersion;

    setUp(() {
      LicenseManager.storeInstallCheckOverride = () => true;
      realVersion = currentVersion;
      currentVersion = stampedVersion;
    });

    tearDown(() => currentVersion = realVersion);

    test('a copy running before the flip is Pro, and stays Pro afterwards',
        () async {
      LicenseManager.storeFreeFromOverride = future;
      await LicenseManager().init();
      expect(LicenseManager().isPro, true,
          reason: 'bought while it cost money');

      // The same install, some time after the listing went free. Nothing
      // about it changed except the date.
      LicenseManager.storeFreeFromOverride = past;
      prefs.setString('version', currentVersion);
      await LicenseManager().init();

      expect(LicenseManager().isPro, true);
      expect(LicenseManager().plan, LicensePlan.store);
    });

    test('a copy that only ever ran a pre-freemium build is Pro', () async {
      // It updated for the first time after the flip, so it never got to
      // record the flip passing — but a free download cannot have been
      // running 2.1.0, because free downloads did not exist then.
      LicenseManager.storeFreeFromOverride = past;
      prefs.setString('version', '2.1.0');
      await LicenseManager().init();

      expect(LicenseManager().isPro, true);
      expect(prefs.getBool(storeGrandfatheredPref), true);
    });

    test('a fresh free install is not Pro', () async {
      LicenseManager.storeFreeFromOverride = past;
      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
      expect(LicenseManager().plan, LicensePlan.none);
      expect(prefs.getBool(storeGrandfatheredPref), isNull);
    });

    test('an unstamped build grandfathers nobody', () async {
      // 1.0.0 is what the repo says before the release workflow replaces it.
      // Judged against it, the second start of a fresh free install looks
      // like a copy from the paid era — so such a build declines to judge.
      currentVersion = '1.0.0';
      LicenseManager.storeFreeFromOverride = past;
      prefs.setString('version', '1.0.0');
      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
    });

    test('a free install that has been updated since is still not Pro',
        () async {
      // The version it last ran is from the freemium era, so it says
      // nothing about a purchase.
      LicenseManager.storeFreeFromOverride = past;
      prefs.setString('version', storeFreemiumVersion);
      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
    });

    test('a licence key still unlocks a free Store copy', () async {
      // The Store build has to be able to redeem a website purchase like
      // any other, or a buyer who installed from the Store has nowhere to
      // put their key.
      LicenseManager.storeFreeFromOverride = past;
      await LicenseManager().init();
      expect(LicenseManager().isPro, false);

      prefs.setString('WebLicenseKey', 'AAAA-BBBB');
      prefs.setBool('WebLicenseValid', true);
      prefs.setString('WebLicensePlan', 'pro');
      prefs.setInt(
          'WebLicenseCheckedAt', DateTime.now().millisecondsSinceEpoch);
      await LicenseManager().init();

      expect(LicenseManager().isPro, true);
      expect(LicenseManager().plan, LicensePlan.pro);
    });

    test('a key answers to the plan the server named it', () async {
      // Commercial and Team both come back from the server as a plan name
      // the screen turns into a label; both unlock the same features.
      LicenseManager.storeFreeFromOverride = past;
      const plans = {
        'commercial': LicensePlan.commercial,
        'team': LicensePlan.team,
        // An unknown name still came from a validated key: plain Pro.
        'something-new': LicensePlan.pro,
      };
      const labels = {
        'commercial': 'plan-commercial',
        'team': 'plan-team',
        'something-new': 'plan-pro',
      };
      for (final name in plans.keys) {
        final plan = plans[name];
        final label = labels[name];
        prefs.setString('WebLicenseKey', 'AAAA-BBBB');
        prefs.setBool('WebLicenseValid', true);
        prefs.setString('WebLicensePlan', name);
        prefs.setInt(
            'WebLicenseCheckedAt', DateTime.now().millisecondsSinceEpoch);
        await LicenseManager().init();

        expect(LicenseManager().isPro, true, reason: name);
        expect(LicenseManager().plan, plan, reason: name);
        expect(LicenseManager().getPlanText(), label, reason: name);
      }
    });

    test('the Store is only advertised as selling Pro until the flip', () {
      LicenseManager.storeFreeFromOverride = future;
      expect(LicenseManager.storeSellsPro, true);

      LicenseManager.storeFreeFromOverride = past;
      expect(LicenseManager.storeSellsPro, false);

      // With no override the shipped constant decides, and its instant has
      // passed: no build carrying it advertises the Store as selling Pro.
      LicenseManager.storeFreeFromOverride = null;
      expect(LicenseManager.storeSellsPro, false);
    });

    test('the shipped build flips at the instant the listing goes free', () {
      // store/pricing.json says Free and the release workflow publishes it,
      // so the app has to carry a flip instant that is no later than the
      // moment that submission clears certification. One in the past is
      // the safe side: no paid-era build knows about it, and every build
      // that does arrives together with the price change.
      LicenseManager.storeFreeFromOverride = null;
      final flip = LicenseManager.storeFreeFrom;
      expect(flip, isNotNull,
          reason: 'storeFreeFromUtc is null - store/pricing.json says Free');
      expect(flip!.isUtc, true);
      expect(flip, DateTime.utc(2026, 9, 13));
      expect(flip.isBefore(DateTime.now().toUtc()), true,
          reason: 'an instant certification could overshoot would hand Pro '
              'to free downloads made before it');
    });

    test('the freemium version is newer than every paid-era release', () {
      // 2.1.0 was the last release sold in the Store. A free download can
      // never have run it, which is what the last-ran-version fallback
      // relies on.
      expect(compareVersions(storeFreemiumVersion, '2.1.0'), greaterThan(0));
    });

    test('the shipped build is new enough to judge', () {
      // The release workflow stamps currentVersion from pubspec.yaml, and
      // storeGrandfathers declines to grandfather anyone from a build older
      // than storeFreemiumVersion — so a pubspec behind the constant would
      // ship a free listing whose updated buyers all land on Free.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(r'^version:\s*([^\s#]+)', multiLine: true)
          .firstMatch(pubspec)!
          .group(1)!;
      expect(compareVersions(version, storeFreemiumVersion),
          greaterThanOrEqualTo(0),
          reason: 'pubspec.yaml says $version, '
              'storeFreemiumVersion is $storeFreemiumVersion');
    });

    test('a Store install still counts as a Store install', () async {
      // Updates and the rating prompt follow the package, not the
      // entitlement: a free Store copy is updated by the Store and can post
      // a review just as well as a paid one.
      LicenseManager.storeFreeFromOverride = past;
      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
      expect(LicenseManager().isStorePackaged, true);
    });
  });

  group('parseFlipInstant', () {
    test('nothing scheduled reads as nothing scheduled', () {
      expect(parseFlipInstant(null), isNull);
      expect(parseFlipInstant(''), isNull);
      expect(parseFlipInstant('   '), isNull);
      expect(parseFlipInstant('not a date'), isNull);
    });

    test('an instant is the same instant everywhere', () {
      // Without a zone DateTime.parse reads local time, and the app would
      // flip at a different moment in every time zone while the listing
      // flips at one.
      final withZone = parseFlipInstant('2026-10-01T09:00:00Z')!;
      final withoutZone = parseFlipInstant('2026-10-01T09:00:00')!;

      expect(withZone.isUtc, true);
      expect(withoutZone.isUtc, true);
      expect(withoutZone, withZone);
      expect(withZone, DateTime.utc(2026, 10, 1, 9));
    });

    test('an offset is honoured rather than ignored', () {
      expect(parseFlipInstant('2026-10-01T11:00:00+02:00'),
          DateTime.utc(2026, 10, 1, 9));
    });
  });

  group('storeGrandfathers', () {
    late String realVersion;

    setUp(() {
      realVersion = currentVersion;
      currentVersion = stampedVersion;
    });

    tearDown(() => currentVersion = realVersion);

    bool decide({
      bool packaged = true,
      DateTime? freeFrom,
      String? lastRanVersion,
      bool alreadyGranted = false,
      DateTime? now,
      DateTime? acquiredAt,
    }) =>
        storeGrandfathers(
          packaged: packaged,
          now: now ?? DateTime.utc(2026, 10, 1),
          freeFrom: freeFrom,
          lastRanVersion: lastRanVersion,
          alreadyGranted: alreadyGranted,
          acquiredAt: acquiredAt,
        );

    test('an unpackaged build is never grandfathered', () {
      expect(decide(packaged: false, alreadyGranted: true), false);
      expect(decide(packaged: false, lastRanVersion: '1.0.0'), false);
    });

    test('with no flip scheduled every Store install is a paid one', () {
      expect(decide(), true);
    });

    test('the flip is the dividing line', () {
      final flip = DateTime.utc(2026, 10, 1, 9);
      final justBefore = flip.subtract(const Duration(minutes: 1));
      expect(decide(freeFrom: flip, now: justBefore), true);
      expect(decide(freeFrom: flip, now: flip), false);
    });

    test('an already granted install is never re-judged', () {
      expect(
          decide(
              freeFrom: DateTime.utc(2020),
              lastRanVersion: '9.9.9',
              alreadyGranted: true),
          true);
    });

    test('after the flip, only a pre-freemium version grandfathers', () {
      final after = DateTime.utc(2026, 11);
      final flip = DateTime.utc(2026, 10);

      expect(decide(freeFrom: flip, now: after, lastRanVersion: '2.1.0'), true);
      expect(
          decide(freeFrom: flip, now: after, lastRanVersion: '1.11.9'), true);
      expect(
          decide(
              freeFrom: flip, now: after, lastRanVersion: storeFreemiumVersion),
          false);
      expect(
          decide(freeFrom: flip, now: after, lastRanVersion: '3.0.0'), false);
      expect(decide(freeFrom: flip, now: after, lastRanVersion: null), false);
    });

    test("the Store's acquisition date outranks every local clue", () {
      final flip = DateTime.utc(2026, 10);
      final after = DateTime.utc(2026, 11);

      // Bought in 2024, reinstalled on a fresh PC: nothing local, but the
      // Store remembers.
      expect(
          decide(
              freeFrom: flip,
              now: after,
              lastRanVersion: null,
              acquiredAt: DateTime.utc(2024, 3, 1)),
          true);
      // Downloaded for nothing after the flip — even next to a version
      // preference that claims a paid-era build.
      expect(
          decide(
              freeFrom: flip,
              now: after,
              lastRanVersion: '2.1.0',
              acquiredAt: DateTime.utc(2026, 10, 2)),
          false);
      // The flip instant itself is the first free download.
      expect(
          decide(freeFrom: flip, now: after, acquiredAt: flip), false);
      expect(
          decide(
              freeFrom: flip,
              now: after,
              acquiredAt: flip.subtract(const Duration(seconds: 1))),
          true);
    });

    test("the Store's date changes nothing outside the free era", () {
      final flip = DateTime.utc(2026, 10);
      final late = DateTime.utc(2027);

      // Not a Store copy: the Store has no say.
      expect(decide(packaged: false, acquiredAt: DateTime.utc(2024)), false);
      // Already granted: never re-judged, whatever the Store says now.
      expect(
          decide(
              freeFrom: flip, now: late, alreadyGranted: true, acquiredAt: late),
          true);
      // Before the flip every Store copy was paid for.
      expect(
          decide(
              freeFrom: flip,
              now: flip.subtract(const Duration(days: 1)),
              acquiredAt: late),
          true);
    });

    test('a build that predates the freemium release judges nobody', () {
      currentVersion = '1.0.0';

      expect(
          decide(
              freeFrom: DateTime.utc(2026, 10),
              now: DateTime.utc(2026, 11),
              lastRanVersion: '1.0.0'),
          false);
      // The sticky flag is still honoured: it was earned by an earlier,
      // properly stamped build and is not re-derived here.
      expect(
          decide(
              freeFrom: DateTime.utc(2026, 10),
              now: DateTime.utc(2026, 11),
              lastRanVersion: '1.0.0',
              alreadyGranted: true),
          true);
    });
  });

  group('restoreFromStore', () {
    late String realVersion;
    int asked = 0;

    /// A flip safely in the past, with a purchase before it and a free
    /// download after it.
    final flip = DateTime.utc(2010);
    final bought = DateTime.utc(2009, 6, 1);
    final downloaded = DateTime.utc(2011, 2, 1);

    /// A Store copy after the flip with nothing local to prove a purchase:
    /// the reinstall case.
    setUp(() async {
      realVersion = currentVersion;
      currentVersion = stampedVersion;
      asked = 0;
      LicenseManager.storeInstallCheckOverride = () => true;
      LicenseManager.storeFreeFromOverride = flip;
    });

    tearDown(() => currentVersion = realVersion);

    /// Lets a lookup that init() started in the background finish: it
    /// awaits the preferences and the Store in turn.
    Future<void> settle() => pumpEventQueue();

    void storeSays(StoreAcquisition? answer) {
      LicenseManager.storeAcquisitionOverride = () async {
        asked++;
        return answer;
      };
    }

    test('a copy the Store says was bought before the flip is restored',
        () async {
      storeSays(StoreAcquisition(acquiredAt: bought));
      await LicenseManager().init();
      // init() asks in the background; wait for that answer to land.
      await settle();

      expect(asked, 1);
      expect(LicenseManager().isPro, true);
      expect(LicenseManager().plan, LicensePlan.store);
      expect(prefs.getBool(storeGrandfatheredPref), true,
          reason: 'written down, so the Store is never needed again');
    });

    test('a copy the Store says was downloaded for nothing stays Free',
        () async {
      storeSays(StoreAcquisition(acquiredAt: downloaded));
      await LicenseManager().init();
      await settle();

      expect(asked, 1);
      expect(LicenseManager().isPro, false);
      expect(prefs.getBool(storeGrandfatheredPref), isNull);
    });

    test('a Store that does not answer changes nothing', () async {
      // Signed out of the Store, or no runner: the local rule's verdict
      // stands, and nothing is written down as if it were an answer.
      storeSays(const StoreAcquisition(error: 'not-in-collection'));
      await LicenseManager().init();
      await settle();
      expect(LicenseManager().isPro, false);

      storeSays(null);
      expect(await LicenseManager().restoreFromStore(force: true), false);
      expect(LicenseManager().isPro, false);
      expect(prefs.getBool(storeGrandfatheredPref), isNull);
    });

    test('a trial is not a purchase', () async {
      storeSays(StoreAcquisition(acquiredAt: bought, isTrial: true));

      expect(await LicenseManager().restoreFromStore(force: true), false);
      expect(LicenseManager().isPro, false);
    });

    test('the Store is asked once a day, not on every start', () async {
      storeSays(const StoreAcquisition(error: 'not-in-collection'));
      await LicenseManager().init();
      await settle();
      await LicenseManager().init();
      await settle();
      expect(asked, 1);

      // Unless the user asks — the licence screen's "Check again".
      await LicenseManager().restoreFromStore(force: true);
      expect(asked, 2);

      // A copy unlocked by a website key has nothing to gain: not asked.
      prefs.setString('WebLicenseKey', 'AAAA-BBBB');
      prefs.setBool('WebLicenseValid', true);
      prefs.setInt(
          'WebLicenseCheckedAt', DateTime.now().millisecondsSinceEpoch);
      prefs.remove(storeAcquisitionCheckedPref);
      await LicenseManager().init();
      await settle();
      expect(asked, 2);
      await LicenseManager().clearLicense();

      // A day later it is due again on its own.
      prefs.setInt(
          storeAcquisitionCheckedPref,
          DateTime.now()
              .subtract(LicenseManager.storeProbeEvery +
                  const Duration(minutes: 1))
              .millisecondsSinceEpoch);
      await LicenseManager().init();
      await settle();
      expect(asked, 3);
    });

    test('a lookup already in flight is joined, not repeated', () async {
      // "Check again" pressed while the start-up probe is still out: one
      // Store call, one answer, both callers see it.
      final answer = Completer<StoreAcquisition?>();
      LicenseManager.storeAcquisitionOverride = () {
        asked++;
        return answer.future;
      };
      await LicenseManager().init();
      await settle();
      final forced = LicenseManager().restoreFromStore(force: true);
      await settle();
      expect(asked, 1);

      answer.complete(StoreAcquisition(acquiredAt: bought));
      expect(await forced, true);
      expect(LicenseManager().isPro, true);

      // Once answered, a forced ask goes to the Store again... except that
      // there is nothing left to ask.
      expect(await LicenseManager().restoreFromStore(force: true), true);
      expect(asked, 1);
    });

    test('the Store is not asked when there is no question', () async {
      storeSays(StoreAcquisition(acquiredAt: bought));

      // A portable build: no package, nothing to restore.
      LicenseManager.storeInstallCheckOverride = () => false;
      await LicenseManager().init();
      await LicenseManager().restoreFromStore(force: true);
      expect(asked, 0);
      expect(LicenseManager().isPro, false);

      // Before the flip package identity is the licence; the Store's date
      // would only say the same thing.
      LicenseManager.storeInstallCheckOverride = () => true;
      LicenseManager.storeFreeFromOverride = future;
      await LicenseManager().init();
      await LicenseManager().restoreFromStore(force: true);
      expect(asked, 0);
      expect(LicenseManager().isPro, true);

      // Already Pro through the local rule: nothing to ask either. (The
      // previous block wrote the sticky flag; drop it so the version clue
      // is what grants here.)
      LicenseManager.storeFreeFromOverride = flip;
      prefs.remove(storeGrandfatheredPref);
      prefs.setString('version', '2.1.0');
      await LicenseManager().init();
      await LicenseManager().restoreFromStore(force: true);
      expect(asked, 0);
      expect(LicenseManager().isPro, true);
    });
  });

  group('stale prefs', () {
    test('a leftover legacy grant no longer unlocks Pro', () async {
      prefs.setBool('LegacyProGranted', true);
      await LicenseManager().init();

      expect(LicenseManager().isPro, false);
      expect(prefs.getBool('LegacyProGranted'), isNull);
    });
  });

  group('rating prompt gate', () {
    test('a GitHub build is never asked - it cannot post a Store review',
        () async {
      LicenseManager.storeInstallCheckOverride = () => false;
      await LicenseManager().init();
      prefs.setInt('InstancesCreated', 99);

      await maybeShowRatingPrompt();

      // Nothing was recorded, because the prompt bailed before showing.
      expect(prefs.getBool('RatingPromptDone'), isNull);
      expect(prefs.getInt('RatingPromptNextAt'), isNull);
    });

    test('a Store install below the threshold is not asked yet', () async {
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      prefs.setInt('InstancesCreated', 1);

      await maybeShowRatingPrompt();

      expect(prefs.getBool('RatingPromptDone'), isNull);
    });

    test('recordInstanceCreated counts up', () {
      prefs.setInt('InstancesCreated', 2);
      recordInstanceCreated();
      expect(prefs.getInt('InstancesCreated'), 3);
    });

    test('a dismissed prompt stays dismissed', () async {
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      prefs.setBool('RatingPromptDone', true);
      prefs.setInt('InstancesCreated', 99);

      await maybeShowRatingPrompt();

      expect(prefs.getBool('RatingPromptDone'), true);
    });
  });
}
