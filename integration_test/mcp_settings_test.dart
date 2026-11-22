import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:localization/localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_service.dart';
import 'package:wsl2distromanager/main.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Coverage for the "MCP Server (WSL API)" settings section: gated behind
/// Pro (upgrade prompt instead of a usable toggle when not Pro), and Pro
/// users can actually flip it on and see the endpoint/token appear.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('MCP server settings', () {
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
      // WslMcpService's server handle is static (see wsl_mcp_service.dart) —
      // stop it so a server "started" in one test doesn't leak into the
      // next test's isRunning/UI-visible state.
      await WslMcpService().stop();
    });

    testWidgets('shows an upgrade prompt when not Pro', (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('settings');
      await tester.pump(const Duration(seconds: 1));

      final expander = find.text((Platform.isMacOS ? 'mcp-settings-vm-text' : 'mcp-settings-text').i18n());
      expect(expander, findsOneWidget);
      await tester.tap(expander, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-mcp-upgrade')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-mcp-endpoint')), findsNothing);
    });

    testWidgets(
        'Pro users can enable the server and see the endpoint and token',
        (tester) async {
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();

      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('settings');
      await tester.pump(const Duration(seconds: 1));

      final expander = find.text((Platform.isMacOS ? 'mcp-settings-vm-text' : 'mcp-settings-text').i18n());
      await tester.tap(expander, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-mcp-upgrade')), findsNothing);

      final toggle = find.byKey(const ValueKey('test-mcp-toggle'));
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle, warnIfMissed: false);
      // Starting the real HTTP server is an async I/O step.
      await tester.pump(const Duration(seconds: 1));

      expect(WslMcpService().enabled, true);
      expect(find.byKey(const ValueKey('test-mcp-endpoint')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-mcp-token')), findsOneWidget);

      // The Cloudflare Tunnel sub-section should appear alongside the
      // endpoint/token once the server itself is on — but don't tap its
      // toggle here: that would trigger a real cloudflared download/spawn,
      // which doesn't belong in an automated test.
      expect(find.byKey(const ValueKey('test-mcp-tunnel-toggle')),
          findsOneWidget);
      // The public-exposure warning is tied to the tunnel actually running
      // (audit ST-20), so merely enabling the server must not show it.
      expect(find.text('mcp-tunnel-warning-text'.i18n()), findsNothing);
    });
  });
}
