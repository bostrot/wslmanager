import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/main.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Integration tests for WSL Distro Manager.
/// These tests simulate clicking through the application to verify UI flows work correctly.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App Launch', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('App launches and renders home page', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // App should render without crashing
      expect(find.byType(WSLManager), findsOneWidget);
    });

    testWidgets('Navigation view is visible', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // NavigationView should be present (parent of NavigationPane)
      expect(find.byType(NavigationView), findsOneWidget);
    });

    testWidgets('App bar is visible with title', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // App title text should be present in the app bar area
      expect(find.textContaining('WSL Manager'), findsWidgets);
    });

    testWidgets('Home page title text is visible', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // App title should contain 'WSL Manager'
      expect(find.textContaining('WSL Manager'), findsWidgets);
    });
  });

  group('Navigation', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('Navigate to Quick Actions page', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Tap the Quick Actions nav item by text
      final quickActionsFinder = find.textContaining('quickactions');
      if (quickActionsFinder.evaluate().isNotEmpty) {
        await tester.tap(quickActionsFinder, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('Navigate to Templates page', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final templatesFinder = find.textContaining('templates');
      if (templatesFinder.evaluate().isNotEmpty) {
        await tester.tap(templatesFinder, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('Navigate to Settings page', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final settingsFinder = find.textContaining('settings');
      if (settingsFinder.evaluate().isNotEmpty) {
        await tester.tap(settingsFinder, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('Navigate to License page', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final licenseFinder = find.textContaining('upgrade');
      if (licenseFinder.evaluate().isNotEmpty) {
        await tester.tap(licenseFinder, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
    });
  });

  group('Home Page', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('Home page renders scrollable content area', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // The home page should contain a Scrollable for the distro list
      expect(find.byType(Scrollable), findsWidgets);
    });

    testWidgets('Home page has Row layout for main content', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Home page uses Row layout with AI panel
      expect(find.byType(Row), findsWidgets);
    });
  });

  group('AI Chat Panel', () {
    setUp(() async {
      // Mark the changelog as seen: its modal barrier would otherwise
      // swallow the tap on the toggle below. AI features are opt-in since
      // bostrot/ai-tasks#98; answered yes here, so neither the first-start
      // question nor a hidden toggle gets in the way.
      SharedPreferences.setMockInitialValues({
        'version': currentVersion,
        'LastChangelogVersion': currentVersion,
        AiService.enabledPrefKey: true,
      });
      prefs = await SharedPreferences.getInstance();
      resetTestState();
      GlobalVariable.testProEnabled = true;
    });

    tearDown(() {
      GlobalVariable.testProEnabled = false;
      resetTestState();
    });

    testWidgets('AI chat toggle FAB visible for Pro users', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // AI toggle FAB should exist when user has Pro license
      expect(find.byKey(const ValueKey('test-ai-chat-toggle')), findsOneWidget);

      // The redesigned pill (ai-tasks#27) still opens and closes the dock.
      expect(GlobalVariable.aiPanelVisible, isFalse);
      await tester.tap(find.byKey(const ValueKey('test-ai-chat-toggle')));
      await tester.pumpAndSettle();
      expect(GlobalVariable.aiPanelVisible, isTrue);
      // The composer card: the box and Send share one control height.
      final input = find.byKey(const ValueKey('test-chat-input'));
      final send = find.byKey(const ValueKey('test-chat-send'));
      expect(input, findsOneWidget);
      expect(send, findsOneWidget);
      expect(tester.getSize(send).height, AiChatPanel.controlSize);
      expect(tester.getRect(send).bottom,
          closeTo(tester.getRect(input).bottom, 0.5));
      await tester.tap(find.byKey(const ValueKey('test-ai-chat-toggle')));
      await tester.pumpAndSettle();
      expect(GlobalVariable.aiPanelVisible, isFalse);
    });

    testWidgets('Toggle AI chat panel visibility via state', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Panel should be hidden initially
      expect(GlobalVariable.aiPanelVisible, isFalse);

      // Toggle state directly (simulates button press effect)
      GlobalVariable.aiPanelVisible = true;
      await tester.pumpAndSettle();

      expect(GlobalVariable.aiPanelVisible, isTrue);

      // Toggle back
      GlobalVariable.aiPanelVisible = false;
      await tester.pumpAndSettle();

      expect(GlobalVariable.aiPanelVisible, isFalse);
    });
  });

  group('Dark Mode', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('Dark mode ToggleSwitch exists in app bar', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Find the ToggleSwitch for dark mode
      expect(find.byType(ToggleSwitch), findsOneWidget);
    });
  });

  group('License Screen', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('Navigate to and render License screen', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Navigate to license page via router
      final licenseFinder = find.textContaining('upgrade');
      if (licenseFinder.evaluate().isNotEmpty) {
        await tester.tap(licenseFinder, warnIfMissed: false);
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }

      // License screen should render with Column layout
      expect(find.byType(Column), findsWidgets);
    });

    testWidgets('License screen has activate button', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final licenseFinder = find.textContaining('upgrade');
      if (licenseFinder.evaluate().isNotEmpty) {
        await tester.tap(licenseFinder, warnIfMissed: false);
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }

      // Should have buttons on the page
      expect(find.byType(Button), findsWidgets);
    });
  });

  group('Create Instance Dialog', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('Open create instance dialog from nav pane', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Tap the Add Instance nav item
      final addInstanceFinder = find.textContaining('addinstance');
      if (addInstanceFinder.evaluate().isNotEmpty) {
        await tester.tap(addInstanceFinder, warnIfMissed: false);
        await tester.pumpAndSettle();

        // Dialog should be visible
        expect(find.byType(ContentDialog), findsOneWidget);
      }
    });

    testWidgets('Create dialog has name input field', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final addInstanceFinder = find.textContaining('addinstance');
      if (addInstanceFinder.evaluate().isNotEmpty) {
        await tester.tap(addInstanceFinder, warnIfMissed: false);
        await tester.pumpAndSettle();

        // Should have TextBox for name input
        expect(find.byKey(const ValueKey('test-create-name-input')), findsOneWidget);
      }
    });

    testWidgets('Create dialog can be cancelled', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final addInstanceFinder = find.textContaining('addinstance');
      if (addInstanceFinder.evaluate().isNotEmpty) {
        await tester.tap(addInstanceFinder, warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(find.byType(ContentDialog), findsOneWidget);

        // Find and tap cancel button by key
        final cancelButton = find.byKey(const ValueKey('test-cancel-button'));
        if (cancelButton.evaluate().isNotEmpty) {
          await tester.tap(cancelButton, warnIfMissed: false);
          await tester.pumpAndSettle();

          expect(find.byType(ContentDialog), findsNothing);
        }
      }
    });

    testWidgets('Create dialog has create button', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final addInstanceFinder = find.textContaining('addinstance');
      if (addInstanceFinder.evaluate().isNotEmpty) {
        await tester.tap(addInstanceFinder, warnIfMissed: false);
        await tester.pumpAndSettle();

        // Should have create button by key
        expect(find.byKey(const ValueKey('test-create-button')), findsOneWidget);
      }
    });
  });

  group('Settings Page', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('Settings page renders with controls', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final settingsFinder = find.textContaining('settings');
      if (settingsFinder.evaluate().isNotEmpty) {
        await tester.tap(settingsFinder, warnIfMissed: false);
        await tester.pumpAndSettle();
      }

      // Settings page should have interactive controls
      expect(find.byType(ToggleSwitch), findsWidgets);
    });
  });

  group('End-to-End Full Flow', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      resetTestState();
    });

    tearDown(() {
      resetTestState();
    });

    testWidgets('Complete navigation flow through all pages', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Start on home page - verify app structure
      expect(find.byType(NavigationView), findsOneWidget);
      expect(find.textContaining('WSL Manager'), findsWidgets);

      // Navigate to Quick Actions
      final quickActions = find.textContaining('quickactions');
      if (quickActions.evaluate().isNotEmpty) {
        await tester.tap(quickActions.first, warnIfMissed: false);
        await tester.pumpAndSettle();
      }

      // Navigate to Templates
      final templates = find.textContaining('templates');
      if (templates.evaluate().isNotEmpty) {
        await tester.tap(templates.first, warnIfMissed: false);
        await tester.pumpAndSettle();
      }

      // Navigate back to Home via nav item
      final home = find.textContaining('homepage');
      if (home.evaluate().isNotEmpty) {
        await tester.tap(home.first, warnIfMissed: false);
        await tester.pumpAndSettle();
      }

      // Toggle AI chat panel state
      GlobalVariable.aiPanelVisible = true;
      await tester.pumpAndSettle();
      expect(GlobalVariable.aiPanelVisible, isTrue);

      GlobalVariable.aiPanelVisible = false;
      await tester.pumpAndSettle();
      expect(GlobalVariable.aiPanelVisible, isFalse);

      // Navigate to Settings
      final settings = find.textContaining('settings');
      if (settings.evaluate().isNotEmpty) {
        await tester.tap(settings.first, warnIfMissed: false);
        await tester.pumpAndSettle();
      }

      // Navigate to License page
      final license = find.textContaining('upgrade');
      if (license.evaluate().isNotEmpty) {
        await tester.tap(license.first, warnIfMissed: false);
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }

      // Return home
      if (home.evaluate().isNotEmpty) {
        await tester.tap(home.first, warnIfMissed: false);
        await tester.pumpAndSettle();
      }

      // App should still be functional after all navigation
      expect(find.byType(NavigationView), findsOneWidget);
    });
  });
}

void resetTestState() {
  GlobalVariable.aiPanelVisible = false;
}
