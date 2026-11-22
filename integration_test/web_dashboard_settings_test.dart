import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:localization/localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/web/web_dashboard_service.dart';
import 'package:wsl2distromanager/main.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Coverage for the "Web Dashboard" settings section: gated behind Pro
/// (upgrade prompt instead of a usable toggle when not Pro), and Pro users
/// can flip it on and get a link plus a QR code to scan.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Web dashboard settings', () {
    setUp(() async {
      // A first start would open the welcome dialog, whose modal barrier
      // swallows every tap this test performs.
      SharedPreferences.setMockInitialValues({
        'version': currentVersion,
        'LastChangelogVersion': currentVersion,
      });
      prefs = await SharedPreferences.getInstance();
      GlobalVariable.aiPanelVisible = false;
      GlobalVariable.testProEnabled = false;
      LicenseManager.storeInstallCheckOverride = () => false;
      await LicenseManager().init();
    });

    tearDown(() async {
      GlobalVariable.aiPanelVisible = false;
      GlobalVariable.testProEnabled = false;
      LicenseManager.storeInstallCheckOverride = null;
      // The server handle is static (see web_dashboard_service.dart) — stop
      // it so a server started in one test doesn't leak into the next.
      await WebDashboardService().stop();
    });

    Future<void> openSection(WidgetTester tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('settings');
      await tester.pump(const Duration(seconds: 1));

      final expander = find.text('web-dashboard-settings-text'.i18n());
      expect(expander, findsOneWidget);
      await tester.ensureVisible(expander);
      await tester.tap(expander, warnIfMissed: false);
      await tester.pumpAndSettle();
    }

    testWidgets('shows an upgrade prompt when not Pro', (tester) async {
      await openSection(tester);

      expect(find.byKey(const ValueKey('test-web-upgrade')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-web-url')), findsNothing);
      expect(find.byKey(const ValueKey('test-web-qr')), findsNothing);
    });

    testWidgets('Pro users can enable the dashboard and get a link and QR code',
        (tester) async {
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();

      await openSection(tester);

      expect(find.byKey(const ValueKey('test-web-upgrade')), findsNothing);

      final toggle = find.byKey(const ValueKey('test-web-toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle, warnIfMissed: false);
      // Binding the real HTTP server and listing interfaces are async I/O.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(WebDashboardService().enabled, true);
      expect(WebDashboardService().isRunning, true);
      expect(find.byKey(const ValueKey('test-web-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-web-qr')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-web-token')), findsOneWidget);

      // The shown link is a complete dashboard URL carrying the token.
      final urlBox = tester.widget<TextBox>(
          find.byKey(const ValueKey('test-web-url')));
      final url = urlBox.controller!.text;
      expect(url, startsWith('http://'));
      expect(url, contains(':${WebDashboardService.port}/'));
      expect(url, contains('token=${WebDashboardService().token}'));

      // The tunnel sub-section appears alongside — but its toggle is never
      // tapped here: that would download and spawn a real cloudflared.
      expect(find.byKey(const ValueKey('test-web-tunnel-toggle')),
          findsOneWidget);
      expect(find.text('web-dashboard-tunnel-warning-text'.i18n()),
          findsNothing);
    });
  });
}
