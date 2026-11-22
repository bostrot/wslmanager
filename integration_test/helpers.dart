import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Unique keys for widgets that need to be found by integration tests.
class TestKeys {
  // Navigation pane items
  static const Key navHome = ValueKey('test-nav-home');
  static const Key navQuickActions = ValueKey('test-nav-quickactions');
  static const Key navTemplates = ValueKey('test-nav-templates');
  static const Key navAiWorkspace = ValueKey('test-nav-ai-workspace');
  static const Key navAddInstance = ValueKey('test-nav-addinstance');
  static const Key navMount = ValueKey('test-nav-mount');

  // Footer items
  static const Key navLicense = ValueKey('test-nav-license');
  static const Key navSettings = ValueKey('test-nav-settings');
  static const Key navAbout = ValueKey('test-nav-about');

  // Home page
  static const Key distroList = ValueKey('test-distro-list');
  static const Key recommendationsPanel = ValueKey('test-recommendations-panel');

  // App bar actions
  static const Key aiChatToggle = ValueKey('test-ai-chat-toggle');
  static const Key darkModeToggle = ValueKey('test-dark-mode-toggle');
  static const Key bugReportButton = ValueKey('test-bug-report-button');

  // License screen. Two purchase routes on Windows — the Microsoft Store and
  // the website that sells a licence key — so two CTAs; on macOS the website
  // is the only route and carries [licenseStoreButton], the leading CTA key.
  static const Key licenseStoreButton = ValueKey('test-license-store-button');
  static const Key licenseWebBuyButton =
      ValueKey('test-license-web-buy-button');
  static const Key licenseKeyField = ValueKey('test-license-key-field');

  // Create dialog
  static const Key createDialogNameInput = ValueKey('test-create-name-input');
  static const Key createDialogLocationInput = ValueKey('test-create-location-input');
  static const Key createDialogCreateButton = ValueKey('test-create-button');
  static const Key createDialogCancelButton = ValueKey('test-cancel-button');

  // List item actions
  static const Key listItemStart = ValueKey('test-listitem-start');
  static const Key listItemStop = ValueKey('test-listitem-stop');
}

/// Extension on WidgetTester to provide convenience methods for common test operations.
extension WslManagerTesters on WidgetTester {
  /// Waits for all pending frames and animations to complete, with a timeout.
  Future<void> pumpAndSettleWithTimeout([Duration? duration]) async {
    await pumpAndSettle(duration ?? const Duration(seconds: 5));
  }

  /// Finds the navigation pane item by its key.
  Finder findNavItem(Key key) => find.byKey(key);

  /// Taps on a widget found by key and waits for settlement.
  Future<void> tapByKey(Key key, [Duration? duration]) async {
    await tap(find.byKey(key));
    await pumpAndSettleWithTimeout(duration);
  }

  /// Enters text into a TextField/FormField found by key.
  Future<void> enterTextByKey(Key key, String text) async {
    await enterText(find.byKey(key), text);
    await pump();
  }
}

/// Resets global test state between tests to ensure isolation.
void resetTestState() {
  GlobalVariable.aiPanelVisible = false;
}
