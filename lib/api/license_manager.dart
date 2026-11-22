// Pro entitlement, from one of two places depending on where the app came
// from.
//
// Windows: the app has been a one-time Microsoft Store purchase, and being
// installed from the Store *is* the licence, detected via MSIX package
// identity. The portable GitHub build runs unpackaged and stays free.
//
// That equation only holds while the listing costs money. When it stops —
// see [storeFreeFromUtc] — a Store install is just a download, and Pro on
// Windows is bought the same way it is on the Mac. Every Store install that
// predates the flip keeps Pro for good: [storeGrandfathers] decides that
// once, and the answer is written down rather than re-derived, so it cannot
// be lost to a later release. When nothing local proves the purchase — a
// buyer reinstalling on a fresh PC — the Store's own record of when the app
// was acquired is asked for through the runner ([restoreFromStore]).
//
// macOS: there is no Store and no package identity, so Pro is bought on
// wslmanager.com and arrives as a licence key — typed in, or handed over by
// the browser through `wslmanager://license?key=...` after checkout. The key
// is validated once against the licence service and then cached, so the app
// keeps working offline.
//
// A key comes with seats — one for Pro — and the service hands them to
// installs, newest activation first. Every request names this install with a
// random id made here (see [_deviceId]) and says whether the user typed the
// key in or the app is re-checking it in the background; a re-check from an
// install that lost its seat comes back invalid, which is how a key shared
// between two PCs keeps bouncing between them.
//
// Neither path is protection. The repo is open source; both are a nudge.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:win32/win32.dart';
// compareVersions only; the grandfather rule reads the version this install
// last ran, and there is no second implementation of that ordering.
import 'package:wsl2distromanager/api/store_acquisition.dart';
import 'package:wsl2distromanager/api/updater.dart' show compareVersions;
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';

enum LicensePlan { none, store, pro, commercial, team }

/// Outcome of trying to turn a licence key into an entitlement.
enum LicenseActivation {
  /// The key checked out and Pro is now unlocked.
  success,

  /// The service answered, and said no.
  invalid,

  /// The service could not be reached. The key is not rejected — a laptop on
  /// a plane must not lose Pro — but nothing is stored either.
  network,
}

/// GetCurrentPackageFullName's "this process has no package identity" code
/// (APPMODEL_ERROR_NO_PACKAGE) — not exported by package:win32.
const int _appModelErrorNoPackage = 15700;

/// Where the answer to [storeGrandfathers] is kept once it has been earned.
const String storeGrandfatheredPref = 'StoreProGrandfathered';

/// When the Store was last asked for its acquisition record, in
/// milliseconds since the epoch — see [LicenseManager.restoreFromStore].
const String storeAcquisitionCheckedPref = 'StoreAcquisitionCheckedAt';

/// Reads [storeFreeFromUtc] — an ISO-8601 instant, or null when no price
/// change is scheduled.
///
/// Anything without a zone is read as UTC, which is what the constant says it
/// is. Left to `DateTime.parse` it would be taken as the *reader's* local
/// time, and a listing that goes free at one instant would be matched by an
/// app that flips at a different one in every time zone.
DateTime? parseFlipInstant(String? iso) => parseUtcInstant(iso);

/// Whether a Store install carries Pro on its own, with no licence key.
///
/// Pure, and the whole of the freemium rule. [packaged] is MSIX package
/// identity, [freeFrom] the instant the listing stops selling Pro,
/// [acquiredAt] when the Store says this user acquired the app (null when
/// it has not been asked or did not say), and [lastRanVersion] the version
/// this install last started — which, on the run that decides this, is
/// still the *previous* one (see the note in nav/init.dart).
///
/// The cases, in the order they are asked:
///
///  * Not a Store install. Nothing to grandfather; Pro comes from a key.
///  * Already granted. Decided on an earlier run and never revisited: a
///    buyer must not lose Pro because a later release changed its mind.
///  * No flip scheduled. The listing still sells the app, so every Store
///    install was paid for — today's behaviour, unchanged.
///  * Before the flip. Same thing: this copy was bought while it cost money.
///  * The Store says when the app entered this user's collection. That is
///    the purchase for anything acquired while the listing cost money, and
///    it survives a reinstall — the one clue a fresh PC still has. It is
///    only ever asked for once the local clues below have said no (see
///    [LicenseManager.restoreFromStore]), so a local yes is never revisited.
///  * After the flip, but this install last ran a build from before the
///    freemium era. It cannot be a free download — free downloads only exist
///    from [storeFreemiumVersion] onwards — so it was bought. Only a build
///    that knows its own version may answer this one.
///  * Anything else: a free Store copy.
bool storeGrandfathers({
  required bool packaged,
  required DateTime now,
  required DateTime? freeFrom,
  required String? lastRanVersion,
  required bool alreadyGranted,
  DateTime? acquiredAt,
}) {
  if (!packaged) return false;
  if (alreadyGranted) return true;
  if (freeFrom == null) return true;
  if (now.isBefore(freeFrom)) return true;
  if (acquiredAt != null) return acquiredAt.isBefore(freeFrom);
  if (lastRanVersion == null) return false;
  // A build that cannot name its own version is in no position to judge
  // anyone else's. `currentVersion` is stamped in by the release workflow
  // and an unstamped build reports 1.0.0 — under which the second start of
  // a brand-new free install looks exactly like a copy from the paid era,
  // and every free download would be granted Pro.
  if (compareVersions(currentVersion, storeFreemiumVersion) < 0) return false;
  return compareVersions(lastRanVersion, storeFreemiumVersion) < 0;
}

class LicenseManager extends ChangeNotifier {
  static final LicenseManager _instance = LicenseManager._internal();
  factory LicenseManager() => _instance;
  LicenseManager._internal();

  /// How long a cached validation is trusted before the app quietly asks the
  /// service again.
  static const Duration revalidateAfter = Duration(days: 14);

  /// How long a cached validation keeps working when the service cannot be
  /// reached at all. Past this, the key has to check in again.
  static const Duration offlineGrace = Duration(days: 60);

  bool _storePackaged = false;
  bool _storeLicensed = false;
  String? _licenseKey;
  String? _licenseEmail;
  int _licenseSeats = 0;
  LicensePlan _keyPlan = LicensePlan.none;
  bool _keyLicensed = false;

  /// Whether this process runs as a Store-installed (MSIX-packaged) app.
  ///
  /// Where the build came from, not what it is entitled to — the Store
  /// updates it and its reviews live on the listing whether or not it has
  /// Pro. [isStoreLicensed] is the entitlement.
  bool get isStorePackaged => _storePackaged;

  /// Whether being a Store install is, by itself, unlocking Pro here.
  bool get isStoreLicensed => _storeLicensed;

  /// Whether a licence key bought on the website is unlocking Pro.
  bool get isKeyLicensed => _keyLicensed;

  /// The stored key, upper-cased for display. Null when none is stored.
  String? get licenseKey => _licenseKey;

  /// Email the licence was sold to, when the service reported one.
  String? get licenseEmail => _licenseEmail;

  /// Seats on a commercial licence; 0 when not applicable.
  int get licenseSeats => _licenseSeats;

  /// Test seam — the real check asks about the test runner's process, which
  /// is never packaged. Reset to null in tearDown.
  @visibleForTesting
  static bool Function()? storeInstallCheckOverride;

  /// Test seam for the licence service. Reset to null in tearDown.
  @visibleForTesting
  static Dio? httpOverride;

  /// Test seam for the Store's acquisition record: stands in for the runner
  /// channel, which has nothing on the other end outside a Windows build.
  /// Reset to null in tearDown.
  @visibleForTesting
  static Future<StoreAcquisition?> Function()? storeAcquisitionOverride;

  /// How often a Store copy that is not Pro asks the Store whether it should
  /// be. Once a day is plenty: the answer only changes when the user signs
  /// in to the Store with the account that bought the app, and the licence
  /// screen's "Check again" asks straight away regardless.
  static const Duration storeProbeEvery = Duration(days: 1);

  static final StoreAcquisitionProbe _storeProbe = StoreAcquisitionProbe();

  /// The Store lookup in flight, if any: a second caller — the licence
  /// screen's "Check again" landing while the start-up probe is still out —
  /// waits for that answer instead of asking twice.
  Future<bool>? _storeRestoreInFlight;

  /// Test seam for [storeFreeFromUtc]: a non-null value wins over the
  /// constant. Production leaves it null, where the constant decides — and
  /// while that is null too, nothing about the Store path changes. Reset to
  /// null in tearDown.
  @visibleForTesting
  static DateTime? storeFreeFromOverride;

  /// The instant the Store listing stops selling Pro, or null while no such
  /// change is scheduled.
  static DateTime? get storeFreeFrom =>
      storeFreeFromOverride ?? parseFlipInstant(storeFreeFromUtc);

  /// Whether the Microsoft Store listing still sells Pro.
  ///
  /// Read by the licence screen as well: once the listing is free there is
  /// nothing to send a buyer to the Store for, on any Windows build.
  static bool get storeSellsPro {
    final freeFrom = storeFreeFrom;
    return freeFrom == null || DateTime.now().toUtc().isBefore(freeFrom);
  }

  Dio get _dio => httpOverride ?? Dio();

  /// Debug builds run as Pro, so every gated feature is testable straight
  /// from `flutter run` — but never inside tests, whose assertions cover
  /// both sides of the gate. Unit runs carry FLUTTER_TEST in the
  /// environment; integration runs do not, but their binding is a test
  /// binding, which a `flutter run` never has.
  ///
  /// Public because the experimental features default to the same rule
  /// (see lib/api/experimental_features.dart).
  static bool get isDebugRun {
    if (!kDebugMode) return false;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    try {
      if (WidgetsBinding.instance.runtimeType.toString().contains('Test')) {
        return false;
      }
    } catch (_) {
      // No binding yet — nothing test-flavoured is running.
    }
    return true;
  }

  bool get isPro => isDebugRun || _storeLicensed || _keyLicensed;

  LicensePlan get plan {
    if (_storeLicensed) return LicensePlan.store;
    if (_keyLicensed) return _keyPlan;
    return LicensePlan.none;
  }

  Future<void> init() async {
    _storePackaged = _detectStoreInstall();
    await _resolveStoreEntitlement();
    _loadStoredLicense();

    // Cleanup of prefs from the retired subscription and legacy-claim
    // experiments. The current key-based licence uses the `WebLicense*`
    // names below, so nothing here touches it.
    for (final key in [
      'LicenseKey',
      'LicenseLastCheck',
      'LicenseStatus',
      'LicensePlan',
      'LicenseExpiresAt',
      'LicenseIsTrial',
      'LegacyProGranted',
      'LegacyProEmail',
      'LegacyProClaimedAt',
    ]) {
      prefs.remove(key);
    }

    notifyListeners();

    // A stored key that has not checked in for a while re-validates in the
    // background: the answer must not hold up app startup, and a revoked or
    // refunded licence should still stop working eventually.
    if (_licenseKey != null && _isStale) {
      unawaited(revalidate());
    }

    // A Store copy that the local evidence did not recognise as bought may
    // still be one — reinstalled on a fresh PC, say. The Store's answer goes
    // to the network, so it is asked in the background and Pro switches on
    // when it arrives rather than holding up startup.
    unawaited(restoreFromStore());
  }

  /// Whether there is anything to ask the Store: a Store copy, after the
  /// flip, that is not Pro by any other means. A copy unlocked by a website
  /// key has nothing to gain from the answer.
  bool get _storeQuestionOpen =>
      _storePackaged && !_storeLicensed && !_keyLicensed && !storeSellsPro;

  /// Whether the last time the Store was asked is long enough ago.
  bool get _storeProbeDue {
    final checked = prefs.getInt(storeAcquisitionCheckedPref);
    if (checked == null) return true;
    final at = DateTime.fromMillisecondsSinceEpoch(checked);
    return DateTime.now().difference(at) > storeProbeEvery;
  }

  /// Asks the Store when this user acquired the app and, if that was while
  /// the listing still cost money, grants Pro and records it for good.
  ///
  /// The one piece of evidence that survives a reinstall: nothing local is
  /// left on a fresh PC, but the Store's collection still says when the app
  /// was bought. It needs the PC signed in to the Store with the account
  /// that bought it; otherwise the Store reports nothing and this changes
  /// nothing — the app keeps whatever the local rule decided.
  ///
  /// Returns whether Pro is on afterwards. Only asks when there is a
  /// question to ask (a Store copy, not Pro, after the flip), and — unless
  /// [force] — at most every [storeProbeEvery]; the licence screen's "Check
  /// again" forces it, since that is the user asking. A lookup already in
  /// flight is joined rather than repeated.
  Future<bool> restoreFromStore({bool force = false}) {
    if (!_storeQuestionOpen) return Future.value(_storeLicensed);
    final inFlight = _storeRestoreInFlight;
    if (inFlight != null) return inFlight;
    if (!force && !_storeProbeDue) return Future.value(false);

    final lookup = _askStore();
    _storeRestoreInFlight = lookup;
    return lookup.whenComplete(() => _storeRestoreInFlight = null);
  }

  Future<bool> _askStore() async {
    // Written before asking, so a runner that never answers is not asked
    // again on every single start.
    await prefs.setInt(
        storeAcquisitionCheckedPref, DateTime.now().millisecondsSinceEpoch);

    final acquisition = await (storeAcquisitionOverride?.call() ??
        _storeProbe.query());
    // Into the log file, not just the debug console: this is the line a
    // support request from a reinstalled Store copy turns on. Asked at most
    // once a day, so it cannot flood anything — and a log that cannot be
    // written must not cost anyone the answer.
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        logInfo('Store acquisition: $acquisition\n');
      } catch (_) {}
    }
    if (acquisition == null || !acquisition.isKnown) return false;

    await _resolveStoreEntitlement(acquiredAt: acquisition.acquiredAt);
    if (_storeLicensed) notifyListeners();
    return _storeLicensed;
  }

  /// Settles whether this Store install carries Pro on its own, and writes
  /// the answer down the first time it does. With [acquiredAt], the Store's
  /// own record joins the evidence (see [restoreFromStore]).
  ///
  /// Recorded rather than recomputed because the evidence is perishable: the
  /// version this install last ran is overwritten on every start, and the
  /// flip instant passes. A copy that was bought has to keep Pro long after
  /// both have gone.
  Future<void> _resolveStoreEntitlement({DateTime? acquiredAt}) async {
    final granted = prefs.getBool(storeGrandfatheredPref) ?? false;
    _storeLicensed = storeGrandfathers(
      packaged: _storePackaged,
      now: DateTime.now().toUtc(),
      freeFrom: storeFreeFrom,
      lastRanVersion: prefs.getString('version'),
      alreadyGranted: granted,
      acquiredAt: acquiredAt,
    );
    if (_storeLicensed && !granted) {
      await prefs.setBool(storeGrandfatheredPref, true);
    }
  }

  /// Reads the cached entitlement written by [activate].
  void _loadStoredLicense() {
    final key = prefs.getString('WebLicenseKey')?.trim();
    if (key == null || key.isEmpty) {
      _licenseKey = null;
      _licenseEmail = null;
      _licenseSeats = 0;
      _keyPlan = LicensePlan.none;
      _keyLicensed = false;
      return;
    }

    _licenseKey = key;
    _licenseEmail = prefs.getString('WebLicenseEmail');
    _licenseSeats = prefs.getInt('WebLicenseSeats') ?? 0;
    _keyPlan = _planFromName(prefs.getString('WebLicensePlan'));

    final valid = prefs.getBool('WebLicenseValid') ?? false;
    _keyLicensed = valid && !_isBeyondGrace;
  }

  DateTime? get _checkedAt {
    final ms = prefs.getInt('WebLicenseCheckedAt');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  bool get _isStale {
    final at = _checkedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > revalidateAfter;
  }

  bool get _isBeyondGrace {
    final at = _checkedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > offlineGrace;
  }

  static LicensePlan _planFromName(String? name) {
    switch (name) {
      case 'commercial':
        return LicensePlan.commercial;
      case 'team':
        return LicensePlan.team;
      case 'pro':
        return LicensePlan.pro;
      default:
        // An unknown plan name still came from a validated key, so treat it
        // as plain Pro rather than dropping the entitlement.
        return LicensePlan.pro;
    }
  }

  /// Validates [key] against the licence service and, if it checks out,
  /// stores it as this install's entitlement. A typed-in key takes a seat,
  /// displacing the install that has held one the longest if none is free.
  Future<LicenseActivation> activate(String key) =>
      _check(key, action: 'activate');

  Future<LicenseActivation> _check(String key, {required String action}) async {
    final trimmed = key.trim().toUpperCase();
    if (trimmed.isEmpty) return LicenseActivation.invalid;

    final Response<dynamic> response;
    try {
      response = await _dio.get(
        licenseValidateUrl,
        queryParameters: {
          'license': trimmed,
          'device': await _deviceId(),
          'action': action,
        },
        options: Options(
          // The service answers 200 for both verdicts; anything else is a
          // transport problem, not a rejection.
          validateStatus: (status) => status != null && status < 500,
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 15),
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Licence validation failed: $e');
      return LicenseActivation.network;
    }

    final data = response.data;
    if (data is! Map) return LicenseActivation.network;
    if (data['valid'] != true) return LicenseActivation.invalid;

    final seats = data['seats'];
    await prefs.setString('WebLicenseKey', trimmed);
    await prefs.setBool('WebLicenseValid', true);
    await prefs.setString('WebLicensePlan', '${data['plan'] ?? 'pro'}');
    await prefs.setInt(
        'WebLicenseCheckedAt', DateTime.now().millisecondsSinceEpoch);
    if (data['email'] is String) {
      await prefs.setString('WebLicenseEmail', data['email'] as String);
    }
    if (seats is int) {
      await prefs.setInt('WebLicenseSeats', seats);
    } else if (seats is String && int.tryParse(seats) != null) {
      await prefs.setInt('WebLicenseSeats', int.parse(seats));
    }

    _loadStoredLicense();
    notifyListeners();
    return LicenseActivation.success;
  }

  /// Re-checks the stored key. A rejection drops the entitlement; an
  /// unreachable service leaves it exactly as it was.
  ///
  /// Sent as a re-check, not an activation, so it never takes a seat from
  /// another install: if this one has lost its seat, the answer is invalid
  /// and Pro switches off here until the user enters the key again.
  Future<LicenseActivation> revalidate() async {
    final key = _licenseKey;
    if (key == null) return LicenseActivation.invalid;

    final result = await _check(key, action: 'revalidate');
    if (result == LicenseActivation.invalid) {
      await prefs.setBool('WebLicenseValid', false);
      _loadStoredLicense();
      notifyListeners();
    }
    return result;
  }

  /// Forgets the stored licence — "sign out" for a machine being handed on.
  /// The install id goes too, so the next owner is a new device to the
  /// service.
  ///
  /// [storeGrandfatheredPref] deliberately stays: it is not this licence, it
  /// is the record that this Store copy was bought, and once dropped there
  /// is no way to work it out again.
  Future<void> clearLicense() async {
    for (final key in [
      'WebLicenseKey',
      'WebLicenseValid',
      'WebLicensePlan',
      'WebLicenseEmail',
      'WebLicenseSeats',
      'WebLicenseCheckedAt',
      'WebLicenseDevice',
    ]) {
      await prefs.remove(key);
    }
    _loadStoredLicense();
    notifyListeners();
  }

  /// Names this install to the licence service so a seat can follow it.
  ///
  /// A random id, made here the first time it is needed and kept in prefs —
  /// not a machine GUID, serial or MAC, so nothing that identifies the
  /// hardware or its owner leaves the PC. Wiping prefs or reinstalling makes
  /// a fresh one, and a fresh one simply activates, the same as a new PC.
  Future<String> _deviceId() async {
    final stored = prefs.getString('WebLicenseDevice');
    if (stored != null && stored.isNotEmpty) return stored;
    final id = _randomUuid();
    await prefs.setString('WebLicenseDevice', id);
    return id;
  }

  /// A version-4 UUID from the platform's secure random source.
  static String _randomUuid() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  bool _detectStoreInstall() {
    final override = storeInstallCheckOverride;
    if (override != null) return override();

    // Developer escape hatch for click-throughs of the Pro-gated screens:
    // `flutter run -d windows --dart-define=WSLM_FORCE_PRO=true`. Gated behind
    // kDebugMode, so a release build always ignores it.
    if (kDebugMode && const bool.fromEnvironment('WSLM_FORCE_PRO')) {
      return true;
    }

    if (!Platform.isWindows) return false;

    try {
      return using((arena) {
        final length = arena<Uint32>();
        // Without identity: APPMODEL_ERROR_NO_PACKAGE. With it:
        // ERROR_INSUFFICIENT_BUFFER, since we pass no buffer.
        final result = GetCurrentPackageFullName(length, nullptr);
        return result != _appModelErrorNoPackage;
      });
    } catch (_) {
      // Assume unpackaged rather than crashing the gate.
      return false;
    }
  }

  String getPlanText() {
    switch (plan) {
      case LicensePlan.store:
        return 'plan-store';
      case LicensePlan.commercial:
        return 'plan-commercial';
      case LicensePlan.team:
        return 'plan-team';
      case LicensePlan.pro:
        return 'plan-pro';
      case LicensePlan.none:
        return 'plan-free';
    }
  }
}
