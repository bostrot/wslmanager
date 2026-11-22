import 'dart:ui';

import 'package:window_manager/window_manager.dart';

/// Every `window_manager` call goes through the plugin's native `WindowManager`
/// object, whose window reference is a force-unwrapped optional that only
/// `ensureInitialized` ever fills in. On macOS a method that reaches an
/// instance without one traps inside Swift — `WindowManager.mainWindow.getter`
/// on `_mainWindow!` — and the process dies with `EXC_BREAKPOINT`. There is no
/// Dart-side exception to catch: the app is simply gone, which is the crash
/// reported in bostrot/ai-tasks#49, arriving by way of `isMinimized` (the first
/// thing `show()` asks the plugin for).
///
/// Calling `ensureInitialized` once during startup is not enough, because the
/// `_inited` flag and the window it guards live on the plugin *instance* that
/// currently owns the `window_manager` channel, not on the channel. Re-sending
/// it costs one platform-channel round trip and is a no-op whenever the plugin
/// already has its window, so every call the app makes is prefixed with it.
///
/// Only the methods the app actually uses are wrapped; adding an unguarded call
/// elsewhere is what this class exists to prevent, so route new ones through
/// here. Listener registration is deliberately absent — it never crosses to the
/// native side.
class AppWindow {
  AppWindow._();

  static final AppWindow instance = AppWindow._();

  /// Hands the plugin a window before [action] can ask it for one.
  Future<T> _guarded<T>(Future<T> Function() action) async {
    await windowManager.ensureInitialized();
    return action();
  }

  Future<void> waitUntilReadyToShow() =>
      _guarded(windowManager.waitUntilReadyToShow);

  Future<void> setTitleBarStyle(
    TitleBarStyle style, {
    bool windowButtonVisibility = true,
  }) =>
      _guarded(() => windowManager.setTitleBarStyle(
            style,
            windowButtonVisibility: windowButtonVisibility,
          ));

  Future<void> setAsFrameless() => _guarded(windowManager.setAsFrameless);

  Future<void> setMinimumSize(Size size) =>
      _guarded(() => windowManager.setMinimumSize(size));

  Future<void> setSize(Size size) => _guarded(() => windowManager.setSize(size));

  Future<Size> getSize() => _guarded(windowManager.getSize);

  Future<void> setPosition(Offset position) =>
      _guarded(() => windowManager.setPosition(position));

  Future<Offset> getPosition() => _guarded(windowManager.getPosition);

  Future<Rect> getBounds() => _guarded(windowManager.getBounds);

  Future<void> center() => _guarded(windowManager.center);

  Future<void> maximize() => _guarded(windowManager.maximize);

  Future<bool> isMaximized() => _guarded(windowManager.isMaximized);

  Future<void> show() => _guarded(windowManager.show);

  Future<void> setPreventClose(bool isPreventClose) =>
      _guarded(() => windowManager.setPreventClose(isPreventClose));

  Future<void> setSkipTaskbar(bool isSkipTaskbar) =>
      _guarded(() => windowManager.setSkipTaskbar(isSkipTaskbar));
}

/// Shorthand mirroring the plugin's own top-level `windowManager`.
final AppWindow appWindow = AppWindow.instance;
