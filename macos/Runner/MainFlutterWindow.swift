import Cocoa
import FlutterMacOS
import macos_window_utils

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // The standalone Dart VM ignores SIGPIPE; Flutter's macOS embedder does
    // not, so a write to a socket whose peer already hung up — a keep-alive
    // connection the analytics host had closed, in the case that killed the
    // notarized 2.0.1 the moment Settings opened — takes the whole process
    // down with no crash report instead of surfacing as a SocketException
    // the caller can handle. Set before the engine exists so nothing can
    // race the first write (bostrot/ai-tasks#49).
    signal(SIGPIPE, SIG_IGN)

    let windowFrame = self.frame

    // `flutter_acrylic` needs its own view controller between the window and
    // the Flutter view. Building it here is the setup macos_window_utils
    // documents, and the point is the ordering: left to initialise itself at
    // runtime the plugin picks `NSApp.windows.first` — not necessarily this
    // window — force-casts its content view controller to a
    // `FlutterViewController`, and swaps the window's content out from under
    // every plugin that was handed the Flutter view at registration. Doing it
    // before `RegisterGeneratedPlugins` means the hierarchy plugins record is
    // the one they keep (bostrot/ai-tasks#49).
    let windowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = windowUtilsViewController
    self.setFrame(windowFrame, display: true)

    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    RegisterGeneratedPlugins(registry: windowUtilsViewController.flutterViewController)

    super.awakeFromNib()
  }
}
