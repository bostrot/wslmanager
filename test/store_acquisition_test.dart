import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/store_acquisition.dart';

/// The Store's acquisition record arrives from the Windows runner over a
/// method channel (windows/runner/store_channel.cpp). These tests stand in
/// for the runner and check that whatever it sends — an answer, an excuse,
/// nothing at all — turns into something the licence rule can act on
/// without ever throwing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(StoreAcquisitionProbe.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The last call the fake runner saw.
  MethodCall? seen;

  void runnerAnswers(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      seen = call;
      return handler(call);
    });
  }

  setUp(() => seen = null);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('StoreAcquisition.fromChannel', () {
    test('an acquisition date is read as a UTC instant', () {
      final acquisition = StoreAcquisition.fromChannel({
        'acquiredAt': '2024-03-01T10:20:30Z',
        'isTrial': false,
        'error': null,
      });

      expect(acquisition.isKnown, true);
      expect(acquisition.acquiredAt, DateTime.utc(2024, 3, 1, 10, 20, 30));
      expect(acquisition.acquiredAt!.isUtc, true);
      expect(acquisition.error, isNull);
    });

    test('a trial is not evidence of a purchase', () {
      final acquisition = StoreAcquisition.fromChannel({
        'acquiredAt': '2024-03-01T10:20:30Z',
        'isTrial': true,
      });

      expect(acquisition.acquiredAt, isNotNull);
      expect(acquisition.isKnown, false);
    });

    test("the runner's excuse is kept", () {
      final acquisition = StoreAcquisition.fromChannel({
        'acquiredAt': null,
        'isTrial': false,
        'error': 'not-in-collection',
      });

      expect(acquisition.isKnown, false);
      expect(acquisition.error, 'not-in-collection');
    });

    test('an unreadable date is unknown, not a crash', () {
      final acquisition = StoreAcquisition.fromChannel({
        'acquiredAt': 'yesterday-ish',
      });

      expect(acquisition.acquiredAt, isNull);
      expect(acquisition.isKnown, false);
      expect(acquisition.error, 'no-date');
    });

    test('anything that is not a map is unknown', () {
      expect(StoreAcquisition.fromChannel(null).isKnown, false);
      expect(StoreAcquisition.fromChannel('2024-03-01').isKnown, false);
      expect(StoreAcquisition.fromChannel(42).error, 'malformed');
    });
  });

  group('StoreAcquisitionProbe.query', () {
    test('asks the runner for the acquisition and reads its answer',
        () async {
      runnerAnswers((_) => {
            'acquiredAt': '2023-11-05T08:00:00Z',
            'isTrial': false,
            'error': null,
          });

      final acquisition = await StoreAcquisitionProbe().query();

      expect(seen?.method, 'getAcquisition');
      expect(acquisition, isNotNull);
      expect(acquisition!.isKnown, true);
      expect(acquisition.acquiredAt, DateTime.utc(2023, 11, 5, 8));
    });

    test('no runner on this platform reads as nothing to say', () async {
      // macOS, Linux and the test host: the channel has no other end, and
      // that must be a null rather than a MissingPluginException reaching
      // the licence manager.
      final acquisition = await StoreAcquisitionProbe().query();

      expect(acquisition, isNull);
    });

    test('a runner that fails reads as nothing to say', () async {
      runnerAnswers((_) => throw PlatformException(code: 'boom'));

      final acquisition = await StoreAcquisitionProbe().query();

      expect(acquisition, isNull);
    });

    test('a runner that never answers is given up on', () async {
      runnerAnswers((_) => Future<Object?>.delayed(const Duration(days: 1)));

      final acquisition = await StoreAcquisitionProbe()
          .query(timeout: const Duration(milliseconds: 50));

      expect(acquisition, isNull);
    });

    test("a runner's excuse is still an answer", () async {
      runnerAnswers((_) => {'acquiredAt': null, 'error': 'winrt 0x80070490'});

      final acquisition = await StoreAcquisitionProbe().query();

      expect(acquisition, isNotNull);
      expect(acquisition!.isKnown, false);
      expect(acquisition.error, 'winrt 0x80070490');
    });
  });
}
