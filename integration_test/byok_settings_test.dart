import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:localization/localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/main.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Coverage for the "Bring Your Own AI Key" settings section: it must stay
/// gated behind Pro (an upgrade prompt instead of usable fields when not
/// Pro), and must actually persist what the user types once they are Pro.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('BYOK settings', () {
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

    tearDown(() {
      GlobalVariable.aiPanelVisible = false;
      GlobalVariable.testProEnabled = false;
      LicenseManager.storeInstallCheckOverride = null;
    });

    testWidgets('shows an upgrade prompt and disabled fields when not Pro',
        (tester) async {
      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('settings');
      await tester.pump(const Duration(seconds: 1));

      final expander = find.text('byok-settings-text'.i18n());
      expect(expander, findsOneWidget);
      await tester.tap(expander, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-byok-upgrade')), findsOneWidget);

      final apiKeyBox = tester.widget<TextBox>(
        find.byKey(const ValueKey('test-byok-apikey-input')),
      );
      expect(apiKeyBox.enabled, false);
    });

    testWidgets('Pro users can enter their API key and it is saved',
        (tester) async {
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();

      await tester.pumpWidget(const WSLManager());
      await tester.pumpAndSettle(const Duration(seconds: 3));

      router.pushNamed('settings');
      await tester.pump(const Duration(seconds: 1));

      final expander = find.text('byok-settings-text'.i18n());
      await tester.tap(expander, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-byok-upgrade')), findsNothing);

      // No enable toggle anymore — the key is the only chat path, so
      // entering it is all there is to configure.
      await tester.enterText(
          find.byKey(const ValueKey('test-byok-apikey-input')), 'sk-test123');
      await tester.enterText(
          find.byKey(const ValueKey('test-byok-baseurl-input')),
          'https://my-proxy.example.com/v1');

      await tester.tap(find.text('save-text'.i18n()), warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));

      expect(AiService().byokApiKey, 'sk-test123');
      expect(AiService().byokBaseUrl, 'https://my-proxy.example.com/v1');
      expect(AiService().hasByokConfigured, true);
    });
  });
}
