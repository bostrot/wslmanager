import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Matches `DeepLinkService.channelName` on the Dart side.
  private static let channelName = "com.bostrot.wsl2distromanager/deeplink"

  /// A `wslmanager://` link can arrive before Dart is listening: clicking
  /// "Activate in WSL Manager" in the browser cold-starts the app, and the
  /// engine attaches its channels a few frames later. Hold the link until the
  /// Dart side comes asking, rather than dropping the purchase on the floor.
  private(set) var pendingLink: String?
  private var channel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// `flutter_acrylic` nests the Flutter view controller inside one of its own
  /// (see `MainFlutterWindow`), so the window's content view controller is not
  /// the one holding the engine any more. Look one level down rather than
  /// giving up and losing the deep-link channel.
  private var flutterViewController: FlutterViewController? {
    guard let root = mainFlutterWindow?.contentViewController else { return nil }
    if let controller = root as? FlutterViewController {
      return controller
    }
    return root.children.compactMap { $0 as? FlutterViewController }.first
  }

  /// `override` is required even though `FlutterAppDelegate` does not
  /// implement this selector: Swift imports every optional
  /// `NSApplicationDelegate` method as an overridable member of an ObjC
  /// superclass that adopts the protocol. For the same reason `super` is not
  /// called here — the selector has no implementation up the chain, so the
  /// call would raise "unrecognized selector". Flutter's lifecycle registrar
  /// observes `NSApplication.didFinishLaunchingNotification` itself and does
  /// not depend on this method being forwarded.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = flutterViewController else {
      return
    }

    let channel = FlutterMethodChannel(
      name: AppDelegate.channelName,
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getPendingLink":
        // Read-and-clear: a link must activate once, not on every rebuild of
        // the licence screen.
        result(self?.pendingLink)
        self?.pendingLink = nil
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    // Plugins get first refusal; `wslmanager://` is ours alone, so nothing
    // else claims it, but skipping super would break any plugin that does
    // handle URLs later.
    super.application(application, open: urls)

    guard let link = urls.first(where: { $0.scheme == "wslmanager" }) else {
      return
    }

    if let channel = channel {
      channel.invokeMethod("onLink", arguments: link.absoluteString)
    } else {
      pendingLink = link.absoluteString
    }
  }
}
