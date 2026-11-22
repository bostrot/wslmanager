import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Receives `wslmanager://` links from the macOS runner.
///
/// Only macOS registers the scheme (see `macos/Runner/Info.plist`), so on
/// every other platform the channel simply has nothing on the other end and
/// every call here answers null rather than throwing.
class DeepLinkService {
  /// Matches `AppDelegate.channelName` in the macOS runner.
  static const String channelName = 'com.bostrot.wsl2distromanager/deeplink';

  DeepLinkService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  final MethodChannel _channel;

  /// Calls [onLink] for every link that arrives while the app is running.
  ///
  /// A link that arrives while the app was *not* running is not delivered
  /// here — the runner holds it and [takePendingLink] collects it once Dart
  /// is listening.
  void listen(void Function(Uri link) onLink) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onLink') return null;
      final raw = call.arguments;
      if (raw is! String) return null;
      final uri = Uri.tryParse(raw);
      if (uri != null) onLink(uri);
      return null;
    });
  }

  /// The link that cold-started the app, if any. Clears it on the runner side,
  /// so a second call returns null.
  Future<Uri?> takePendingLink() async {
    try {
      final raw = await _channel.invokeMethod<String>('getPendingLink');
      if (raw == null || raw.isEmpty) return null;
      return Uri.tryParse(raw);
    } on MissingPluginException {
      // Windows and Linux: no runner side, and nothing to collect.
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('Deep link probe failed: $e');
      return null;
    }
  }

  /// The licence key carried by `wslmanager://license?key=...`, or null when
  /// the link is something else.
  ///
  /// `Uri` parses `wslmanager://license?key=x` with "license" as the *host*,
  /// but a link written as `wslmanager:license?key=x` puts it in the path, so
  /// both spellings are accepted rather than silently dropping a purchase.
  static String? licenseKeyOf(Uri link) {
    if (link.scheme != 'wslmanager') return null;
    final target = link.host.isNotEmpty
        ? link.host
        : link.path.replaceAll('/', '');
    if (target != 'license') return null;
    final key = link.queryParameters['key']?.trim();
    if (key == null || key.isEmpty) return null;
    return key;
  }
}
