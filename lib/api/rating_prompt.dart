// When, and how, a Store install is asked for a rating.
//
// The first version drew its own dialog after three created instances and
// sent a "Rate" click out to the Store app's review page. Across ~1,300 free
// installs since 2026-09-13 that produced practically no ratings
// (docs/store/search-ranking-investigation.md, cause 2): three instances is
// a bar most users never reach, and leaving the app for the Store loses the
// rest. Now the Store's own rating sheet opens inside the app
// (StoreContext.RequestRateAndReviewAppAsync, through the runner's Store
// channel), and the bar is one thing that worked plus a second start.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/store_acquisition.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The shortest gap between two asks, whatever the version.
const Duration ratingPromptInterval = Duration(days: 90);

/// The start on which an install can first be asked. The first one is
/// onboarding.
const int ratingPromptMinLaunches = 2;

/// Why an install is not asked on this start.
enum RatingPromptSkip {
  /// Not a Store install: the sheet rates the Store listing, and outside a
  /// package the Store does not know which one.
  notStore,

  /// The user already rated. Never asked again.
  rated,

  /// The first start, or a start that is putting up the welcome, the
  /// release notes or the AI question.
  onboarding,

  /// Nothing has worked for the user yet.
  noSuccess,

  /// The last thing the user did failed.
  lastActionFailed,

  /// Already asked on this version.
  askedThisVersion,

  /// Asked less than [ratingPromptInterval] ago.
  askedRecently,
}

/// What the prefs say about the rating prompt.
@immutable
class RatingPromptState {
  const RatingPromptState({
    this.launches = 0,
    this.successfulActions = 0,
    this.lastActionFailed = false,
    this.rated = false,
    this.askedVersion,
    this.askedAt,
  });

  /// App starts counted since this logic shipped, this one included.
  final int launches;
  final int successfulActions;
  final bool lastActionFailed;
  final bool rated;
  final String? askedVersion;
  final DateTime? askedAt;

  factory RatingPromptState.fromPrefs() {
    return RatingPromptState(
      launches: prefs.getInt('AppLaunches') ?? 0,
      // Creations counted by the first version still prove the app worked.
      successfulActions: (prefs.getInt('SuccessfulActions') ?? 0) +
          (prefs.getInt('InstancesCreated') ?? 0),
      lastActionFailed: prefs.getBool('LastActionFailed') ?? false,
      // Set by the first version on "Rate" and on "Don't ask again" alike;
      // either way that user has answered and is left alone.
      rated: prefs.getBool('RatingPromptDone') ?? false,
      askedVersion: prefs.getString('RatingPromptVersion'),
      askedAt: parseUtcInstant(prefs.getString('RatingPromptAt')),
    );
  }
}

/// Why this start does not ask, or null when it should.
RatingPromptSkip? ratingPromptSkipReason(
  RatingPromptState state, {
  required bool isStorePackaged,
  required String version,
  required DateTime now,
  bool otherPromptShown = false,
}) {
  if (!isStorePackaged) return RatingPromptSkip.notStore;
  if (state.rated) return RatingPromptSkip.rated;
  if (state.launches < ratingPromptMinLaunches || otherPromptShown) {
    return RatingPromptSkip.onboarding;
  }
  if (state.successfulActions <= 0) return RatingPromptSkip.noSuccess;
  if (state.lastActionFailed) return RatingPromptSkip.lastActionFailed;
  if (state.askedVersion == version) return RatingPromptSkip.askedThisVersion;
  final askedAt = state.askedAt;
  if (askedAt != null && now.difference(askedAt) < ratingPromptInterval) {
    return RatingPromptSkip.askedRecently;
  }
  return null;
}

/// Counts this start. Called once per start, before anything is asked.
void recordAppLaunch() {
  prefs.setInt('AppLaunches', (prefs.getInt('AppLaunches') ?? 0) + 1);
}

/// Something the user asked for worked: an instance created, imported or
/// started.
void recordSuccessfulAction() {
  prefs.setInt(
      'SuccessfulActions', (prefs.getInt('SuccessfulActions') ?? 0) + 1);
  prefs.setBool('LastActionFailed', false);
}

/// Something the user asked for failed. Nobody is asked to rate an app that
/// just let them down; the next success clears it.
void recordFailedAction() {
  prefs.setBool('LastActionFailed', true);
}

/// How the Store's rating sheet ended.
enum StoreRatingStatus { succeeded, canceled, networkError, error }

/// Opens the Store's rating sheet through the Windows runner.
class StoreRatingRequester {
  StoreRatingRequester({MethodChannel? channel})
      : _channel = channel ??
            const MethodChannel(StoreAcquisitionProbe.channelName);

  final MethodChannel _channel;

  /// Test seam for [request]. Reset to null in tearDown.
  @visibleForTesting
  static Future<StoreRatingStatus?> Function()? override;

  /// How the sheet ended, or null when there is no sheet to show: no runner
  /// on this platform, or the call itself failed.
  Future<StoreRatingStatus?> request() async {
    final seam = override;
    if (seam != null) return seam();
    try {
      final raw =
          await _channel.invokeMethod<Object?>('requestRateAndReview');
      if (raw is! Map) return null;
      final error = raw['error'];
      if (kDebugMode && error is String) {
        debugPrint('Store rating sheet: $error');
      }
      switch (raw['status']) {
        case 'succeeded':
          return StoreRatingStatus.succeeded;
        case 'canceled':
          return StoreRatingStatus.canceled;
        case 'networkError':
          return StoreRatingStatus.networkError;
        default:
          return StoreRatingStatus.error;
      }
    } on MissingPluginException {
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('Store rating sheet failed: $e');
      return null;
    }
  }
}

/// Asks for a Store rating when this start qualifies, and stays silent when
/// the sheet cannot be shown.
///
/// [otherPromptShown] is whether this start already put up the welcome, the
/// release notes or the AI question: one prompt per start is plenty.
Future<void> maybeRequestStoreRating({
  bool otherPromptShown = false,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now().toUtc();
  final skip = ratingPromptSkipReason(
    RatingPromptState.fromPrefs(),
    isStorePackaged: LicenseManager().isStorePackaged,
    version: currentVersion,
    now: at,
    otherPromptShown: otherPromptShown,
  );
  if (skip != null) return;

  // The sheet is tied to the app's window, which has to be up.
  while (StoreRatingRequester.override == null &&
      GlobalVariable.infobox.currentContext == null) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  plausible.event(page: 'rating_prompt');

  final status = await StoreRatingRequester().request();
  // No runner to ask: nothing was shown, so nothing counts as asked.
  if (status == null) return;
  if (status == StoreRatingStatus.succeeded) {
    await prefs.setBool('RatingPromptDone', true);
    return;
  }
  // Declined, or the Store could not be reached or failed: either way it
  // waits for the next version and at least the interval.
  await prefs.setString('RatingPromptVersion', currentVersion);
  await prefs.setString('RatingPromptAt', at.toIso8601String());
}
