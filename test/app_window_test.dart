import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:wsl2distromanager/api/app_window.dart';

/// The macOS half of `window_manager` force-unwraps the window it was handed by
/// `ensureInitialized`, so any method that reaches a plugin without one kills
/// the process from Swift — no Dart exception, nothing to catch
/// (bostrot/ai-tasks#49). [AppWindow] exists to make that unreachable, and what
/// these tests pin is the guarantee itself: no call leaves for the native side
/// unless `ensureInitialized` went first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('window_manager');
  // `center()` measures the display before it moves the window.
  const screenChannel = MethodChannel('dev.leanflutter.plugins/screen_retriever');

  late List<String> calls;
  /// Methods the fake plugin should fail, the way an uninitialised native side
  /// would reject work.
  late Set<String> failing;

  setUp(() {
    calls = [];
    failing = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (failing.contains(call.method)) {
        throw PlatformException(code: 'no-window');
      }
      if (call.method.startsWith('is')) return false;
      if (call.method == 'getBounds') {
        return {'x': 0.0, 'y': 0.0, 'width': 800.0, 'height': 600.0};
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, (call) async {
      const display = {
        'id': '0',
        'size': {'width': 1920.0, 'height': 1080.0},
        'visiblePosition': {'dx': 0.0, 'dy': 0.0},
        'visibleSize': {'width': 1920.0, 'height': 1080.0},
        'scaleFactor': 1.0,
      };
      switch (call.method) {
        case 'getAllDisplays':
          return {
            'displays': [display]
          };
        case 'getCursorScreenPoint':
          return {'dx': 0.0, 'dy': 0.0};
        default:
          return display;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, null);
  });

  /// Every entry point the app has onto the plugin, so a new unguarded wrapper
  /// shows up here as a failure rather than as a crash on a user's machine.
  final operations = <String, Future<void> Function()>{
    'waitUntilReadyToShow': () => appWindow.waitUntilReadyToShow(),
    'setTitleBarStyle': () =>
        appWindow.setTitleBarStyle(TitleBarStyle.hidden),
    'setAsFrameless': () => appWindow.setAsFrameless(),
    'setMinimumSize': () => appWindow.setMinimumSize(const Size(700, 500)),
    'setSize': () => appWindow.setSize(const Size(1180, 780)),
    'getSize': () => appWindow.getSize(),
    'setPosition': () => appWindow.setPosition(const Offset(10, 20)),
    'getPosition': () => appWindow.getPosition(),
    'getBounds': () => appWindow.getBounds(),
    'center': () => appWindow.center(),
    'maximize': () => appWindow.maximize(),
    'isMaximized': () => appWindow.isMaximized(),
    'show': () => appWindow.show(),
    'setPreventClose': () => appWindow.setPreventClose(true),
    'setSkipTaskbar': () => appWindow.setSkipTaskbar(false),
  };

  for (final entry in operations.entries) {
    test('${entry.key} initialises the plugin first', () async {
      await entry.value();

      expect(calls.first, 'ensureInitialized',
          reason: '${entry.key} reached the plugin before it had a window');
      expect(calls.length, greaterThan(1),
          reason: '${entry.key} never reached the plugin at all');
    });
  }

  /// `show()` is the call in the crash report: window_manager asks the native
  /// side whether the window is minimised before it shows anything, which is
  /// what trapped on the force-unwrapped window.
  test('show does not query the window before initialising it', () async {
    await appWindow.show();

    expect(calls.indexOf('ensureInitialized'), 0);
    expect(calls.indexOf('isMinimized'), greaterThan(0));
  });

  test('re-initialises on every call, not just the first', () async {
    await appWindow.setSize(const Size(1180, 780));
    await appWindow.show();

    expect(calls.where((c) => c == 'ensureInitialized').length, 2,
        reason: 'a plugin instance swapped in later would never be initialised');
  });

  test('a failed call still initialises the one after it', () async {
    failing = {'setBounds'};
    await expectLater(appWindow.setSize(const Size(1180, 780)),
        throwsA(isA<PlatformException>()));

    calls.clear();
    failing = {};
    await appWindow.show();

    expect(calls.first, 'ensureInitialized');
  });
}
