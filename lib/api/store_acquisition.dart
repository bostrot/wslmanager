// What the Microsoft Store knows about how this install was acquired.
//
// Once the listing is free, package identity says only "installed from the
// Store", not "paid for". The Store still knows the difference: every SKU
// in a user's collection carries the date it was acquired, and for a copy
// bought while the listing cost money that date is the purchase. The runner
// (windows/runner/store_channel.cpp) reads it through WinRT and hands it
// over here.
//
// This is the answer for the one case the local evidence cannot cover — a
// buyer who reinstalls on a fresh PC after the flip (see
// doc/microsoft-store-freemium.md). It needs the PC to be signed in to the
// Store with the account that bought the app; otherwise the Store reports
// nothing and the app falls back to what it can see locally.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads an ISO-8601 instant as UTC, or null when there is none.
///
/// Anything without a zone is read as UTC rather than, as `DateTime.parse`
/// would have it, the *reader's* local time — an instant that means one
/// moment everywhere must not become a different one in every time zone.
DateTime? parseUtcInstant(String? iso) {
  if (iso == null || iso.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(iso.trim());
  if (parsed == null) return null;
  if (parsed.isUtc) return parsed;
  return DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour,
      parsed.minute, parsed.second, parsed.millisecond);
}

/// The Store's record of this install, or the reason there is none.
@immutable
class StoreAcquisition {
  const StoreAcquisition({this.acquiredAt, this.isTrial = false, this.error});

  /// When the app entered the user's Store collection, in UTC. Null when
  /// the Store did not say.
  final DateTime? acquiredAt;

  /// Whether what the user holds is a trial rather than the app itself.
  /// The listing never offered one; a trial would prove nothing anyway.
  final bool isTrial;

  /// Why nothing was found: not packaged, signed out of the Store, an
  /// error code. Null when [acquiredAt] is set.
  final String? error;

  /// Whether this is evidence the freemium rule may act on.
  bool get isKnown => acquiredAt != null && !isTrial;

  /// Reads the runner's answer. Anything malformed reads as "unknown".
  factory StoreAcquisition.fromChannel(Object? raw) {
    if (raw is! Map) {
      return const StoreAcquisition(error: 'malformed');
    }
    final acquired = raw['acquiredAt'];
    final acquiredAt = acquired is String ? parseUtcInstant(acquired) : null;
    final error = raw['error'];
    return StoreAcquisition(
      acquiredAt: acquiredAt,
      isTrial: raw['isTrial'] == true,
      error: error is String && error.isNotEmpty
          ? error
          : (acquiredAt == null ? 'no-date' : null),
    );
  }

  @override
  String toString() =>
      'StoreAcquisition(acquiredAt: $acquiredAt, isTrial: $isTrial, '
      'error: $error)';
}

/// Asks the Windows runner for the Store's acquisition record.
class StoreAcquisitionProbe {
  /// Matches `StoreChannel::kChannelName` in the Windows runner.
  static const String channelName = 'com.bostrot.wsl2distromanager/store';

  /// The Store call goes to the network; a PC that cannot reach it should
  /// not hold the licence screen for long.
  static const Duration defaultTimeout = Duration(seconds: 20);

  StoreAcquisitionProbe({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  final MethodChannel _channel;

  /// What the Store says, or null when nothing can be said at all: no
  /// runner on this platform (macOS, Linux, tests), a runner that does not
  /// answer in time, or a failure in the call itself.
  ///
  /// An answer with [StoreAcquisition.error] set is still an answer — the
  /// runner was there and looked — which callers may want to log; either
  /// way only [StoreAcquisition.isKnown] carries any weight.
  Future<StoreAcquisition?> query({Duration timeout = defaultTimeout}) async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>('getAcquisition')
          .timeout(timeout);
      return StoreAcquisition.fromChannel(raw);
    } on MissingPluginException {
      // No runner side on this platform.
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('Store acquisition probe failed: $e');
      return null;
    }
  }
}
