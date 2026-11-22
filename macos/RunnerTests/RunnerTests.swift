import Cocoa
import FlutterMacOS
import XCTest
import macos_window_utils

@testable import WSL_Manager

/// Covers the `wslmanager://` deep-link plumbing in `AppDelegate`.
///
/// Run with `flutter build macos --debug` followed by
/// `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner
/// -configuration Debug`.
class RunnerTests: XCTestCase {
  private func url(_ s: String) -> URL { URL(string: s)! }

  private func launched(_ delegate: AppDelegate) {
    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification))
  }

  /// The macOS build once failed because this method was declared without
  /// `override`. Pin that the delegate still answers the selector, so the
  /// channel that hands links to Dart is actually wired up on launch.
  func testDelegateHandlesDidFinishLaunching() {
    XCTAssertTrue(
      AppDelegate.instancesRespond(
        to: #selector(NSApplicationDelegate.applicationDidFinishLaunching(_:))))
  }

  func testLaunchWithoutAFlutterWindowIsANoOp() {
    let delegate = AppDelegate()
    XCTAssertNil(delegate.mainFlutterWindow)
    launched(delegate)
    XCTAssertNil(delegate.pendingLink)
  }

  func testLinkArrivingBeforeDartListensIsHeld() {
    let delegate = AppDelegate()
    delegate.application(NSApplication.shared, open: [url("wslmanager://activate?key=abc")])
    XCTAssertEqual(delegate.pendingLink, "wslmanager://activate?key=abc")
  }

  func testLinkIsStillHeldWhenLaunchFindsNoWindow() {
    let delegate = AppDelegate()
    delegate.application(NSApplication.shared, open: [url("wslmanager://activate?key=abc")])
    launched(delegate)
    XCTAssertEqual(delegate.pendingLink, "wslmanager://activate?key=abc",
                   "without a channel the link must survive launch for Dart to collect")
  }

  func testForeignSchemesAreIgnored() {
    let delegate = AppDelegate()
    delegate.application(NSApplication.shared, open: [url("https://wslmanager.com/buy")])
    XCTAssertNil(delegate.pendingLink)
  }

  func testOnlyTheWslmanagerLinkIsKeptFromAMixedBatch() {
    let delegate = AppDelegate()
    delegate.application(
      NSApplication.shared,
      open: [url("https://example.com/"), url("wslmanager://activate?key=k"), url("file:///tmp")])
    XCTAssertEqual(delegate.pendingLink, "wslmanager://activate?key=k")
  }

  /// `flutter_acrylic` puts its own view controller between the window and the
  /// Flutter view. Left to do that at runtime it guesses at
  /// `NSApp.windows.first` and swaps the content view out from under plugins
  /// that were already handed the Flutter view, which is how a plugin ends up
  /// holding a window reference it no longer owns (bostrot/ai-tasks#49). The
  /// window has to hand plugins a view that is already in place.
  func testPluginsAreRegisteredAgainstAViewAlreadyInTheWindow() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.awakeFromNib()

    let controller = window.contentViewController as? MacOSWindowUtilsViewController
    XCTAssertNotNil(controller, "flutter_acrylic's view controller must own the content view")
    XCTAssertTrue(
      controller?.flutterViewController.view.window === window,
      "plugins registered against a Flutter view outside the window")
  }

  /// The deep-link channel hangs off the Flutter view controller, which
  /// `flutter_acrylic` nests one level down. Missing it would leave
  /// `wslmanager://` purchases stranded: the delegate would keep holding the
  /// link and Dart would never be given a channel to collect it from.
  func testLaunchFindsTheFlutterControllerNestedByAcrylic() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.awakeFromNib()

    let delegate = AppDelegate()
    delegate.mainFlutterWindow = window
    launched(delegate)

    delegate.application(NSApplication.shared, open: [url("wslmanager://activate?key=abc")])
    XCTAssertNil(
      delegate.pendingLink,
      "the link was parked instead of going out over the deep-link channel")
  }

  /// A write to a socket whose peer has gone away must come back as EPIPE,
  /// not kill the process. The standalone Dart VM arranges that; the Flutter
  /// embedder does not, and the notarized 2.0.1 died of exactly this when
  /// Settings opened (bostrot/ai-tasks#49). Pin that the window's wake-up
  /// leaves SIGPIPE ignored for the whole process.
  func testSigpipeIsIgnoredOnceTheWindowWakes() {
    signal(SIGPIPE, SIG_DFL)  // whatever the test host had, start from fatal
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    window.awakeFromNib()

    // C function pointers are not Equatable in Swift; compare bit patterns.
    var action = sigaction()
    sigaction(SIGPIPE, nil, &action)
    let handler = unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self)
    XCTAssertEqual(handler, unsafeBitCast(SIG_IGN, to: Int.self),
                   "SIGPIPE is still fatal after awakeFromNib")
  }
}
