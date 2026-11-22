import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/dialogs/ai_consent_dialog.dart';

class _MockPlausible implements Plausible {
  @override
  Future<int> event(
          {String? name,
          String? page,
          Map<String, String>? props,
          String? referrer,
          PlausibleRevenue? revenue,
          bool interactive = true}) async =>
      200;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The first-start question (bostrot/ai-tasks#98): nothing AI-shaped is on
/// until it has been answered, it is asked once whichever way it is
/// answered, and Settings carries the same switch afterwards.
///
/// No localization delegate here, so `.i18n()` hands back the key, which is
/// what the finders match on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    plausible = _MockPlausible();
    GlobalVariable.aiPanel.value = false;
  });

  tearDown(() => GlobalVariable.aiPanel.value = false);

  /// The shell the prompt needs: it opens on the home screen's navigator
  /// key, not on a context of its own.
  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(key: (GlobalVariable.infobox = GlobalKey())),
    ));
    await tester.pump();
  }

  testWidgets('asks when nothing has been decided', (tester) async {
    await pumpShell(tester);
    final asked = maybeAskAiConsent();
    await tester.pumpAndSettle();

    expect(find.text('ai-consent-title'), findsOneWidget);
    expect(find.text('ai-consent-text'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('test-ai-consent-accept')));
    await tester.pumpAndSettle();
    await asked;
  });

  testWidgets('a yes switches the features on and is remembered',
      (tester) async {
    await pumpShell(tester);
    final asked = maybeAskAiConsent();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-consent-accept')));
    await tester.pumpAndSettle();
    await asked;

    expect(AiService.featuresEnabled, isTrue);
    expect(AiService.featuresDecided, isTrue);
    expect(find.text('ai-consent-title'), findsNothing);
  });

  testWidgets('a no leaves them off and is remembered just as firmly',
      (tester) async {
    await pumpShell(tester);
    final asked = maybeAskAiConsent();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-consent-decline')));
    await tester.pumpAndSettle();
    await asked;

    expect(AiService.featuresEnabled, isFalse);
    // The edge case the whole thing turns on: "no" matches the value an
    // undecided install already reports, so a switch that only wrote real
    // changes would leave nothing behind and ask again tomorrow.
    expect(AiService.featuresDecided, isTrue);
    expect(prefs.getBool(AiService.enabledPrefKey), isFalse);
  });

  testWidgets('never asks twice, whichever way it was answered',
      (tester) async {
    for (final answer in [true, false]) {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      AiService.setFeaturesEnabled(answer);

      await pumpShell(tester);
      await maybeAskAiConsent();
      await tester.pumpAndSettle();

      expect(find.text('ai-consent-title'), findsNothing,
          reason: 'answered with $answer, so there is nothing left to ask');
      expect(AiService.featuresEnabled, answer);
    }
  });

  testWidgets('waits for the dialog it was queued behind', (tester) async {
    // On a genuine first run the welcome dialog is up; the question lands
    // after it rather than on top of it.
    final welcome = Completer<void>();
    await pumpShell(tester);
    final asked = maybeAskAiConsent(after: welcome.future);
    await tester.pumpAndSettle();
    expect(find.text('ai-consent-title'), findsNothing);

    welcome.complete();
    await tester.pumpAndSettle();
    expect(find.text('ai-consent-title'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('test-ai-consent-decline')));
    await tester.pumpAndSettle();
    await asked;
  });

  testWidgets('a yes closes nothing, a later no closes the chat dock',
      (tester) async {
    await pumpShell(tester);
    final asked = maybeAskAiConsent();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-consent-accept')));
    await tester.pumpAndSettle();
    await asked;

    GlobalVariable.aiPanel.value = true;
    AiService.setFeaturesEnabled(false);
    expect(GlobalVariable.aiPanel.value, isFalse);
  });
}
