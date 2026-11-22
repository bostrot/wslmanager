import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/purchase_routes.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/main.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Regression coverage for the LicenseManager singleton lifecycle.
///
/// LicenseScreen used to wrap LicenseManager() — an app-wide singleton — in
/// a ChangeNotifierProvider(create: ...), which disposes whatever it creates
/// when the screen unmounts. Since the "created" value was the shared
/// singleton, leaving the License page once permanently broke Pro-gating
/// (AI chat, AI Workspace, etc.) everywhere else in the app for the rest of
/// the session. Fixed via ChangeNotifierProvider.value(), which does not
/// take ownership of the instance's lifecycle.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('LicenseManager singleton lifecycle', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      GlobalVariable.aiPanelVisible = false;
      GlobalVariable.testProEnabled = false;
      LicenseManager.storeInstallCheckOverride = () => false;
      await LicenseManager().init();
    });

    tearDown(() {
      GlobalVariable.aiPanelVisible = false;
      GlobalVariable.testProEnabled = false;
      LicenseManager.storeInstallCheckOverride = null;
    });

    testWidgets('Navigating to License and back does not crash the app',
        (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('license');
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(WSLManager), findsOneWidget);

      router.pushNamed('home');
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(WSLManager), findsOneWidget);

      // No exceptions should have been recorded during teardown of the
      // license screen's provider.
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'LicenseManager remains usable after leaving the License screen',
        (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Visit License, then leave it — this used to dispose() the shared
      // singleton.
      router.pushNamed('license');
      await tester.pump(const Duration(seconds: 1));
      router.pushNamed('home');
      await tester.pump(const Duration(seconds: 1));

      // The singleton must still be a live, listenable ChangeNotifier —
      // calling a method that notifies listeners must not throw.
      expect(() => LicenseManager().init(), returnsNormally);
      await tester.pump();

      // A second screen that depends on LicenseManager (AI Workspace's
      // paywall) must still be able to read it without crashing.
      router.pushNamed('ai-workspace');
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(WSLManager), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Purchase sections', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      GlobalVariable.aiPanelVisible = false;
      GlobalVariable.testProEnabled = false;
      LicenseManager.storeInstallCheckOverride = () => false;
      await LicenseManager().init();
    });

    tearDown(() {
      GlobalVariable.aiPanelVisible = false;
      GlobalVariable.testProEnabled = false;
      LicenseManager.storeInstallCheckOverride = null;
    });

    testWidgets('offers every purchase route when not Pro', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('license');
      await tester.pump(const Duration(seconds: 1));

      // The leading CTA: the Microsoft Store on Windows, the website on macOS.
      expect(find.byKey(const ValueKey('test-license-store-button')),
          findsOneWidget);
      // Windows also sells a key on the website, as a second card.
      expect(
          find.byKey(const ValueKey('test-license-web-buy-button')),
          purchaseRoutesFor(apple: isAppleHost).length > 1
              ? findsOneWidget
              : findsNothing);
      // And a key bought there has to be redeemable here, on any host.
      expect(find.byKey(const ValueKey('test-license-key-field')),
          findsOneWidget);
    });

    testWidgets('hides the purchase CTA once the Store licence is detected',
        (tester) async {
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();

      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('license');
      await tester.pump(const Duration(seconds: 1));

      expect(LicenseManager().isPro, true);
      expect(find.byKey(const ValueKey('test-license-store-button')),
          findsNothing);
      expect(find.byKey(const ValueKey('test-license-web-buy-button')),
          findsNothing);
      expect(find.byKey(const ValueKey('test-license-key-field')),
          findsNothing);
    });
  });
}
