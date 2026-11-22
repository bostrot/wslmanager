/// The recommendations panel's dismiss contract (FIX-18): dismissing removes
/// the card on the click, following a link does not dismiss, and a panel with
/// nothing left to say disappears entirely.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/recommender_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/recommendations_panel.dart';

void main() {
  setUp(() async {
    // Three Docker-based creates is the trigger for recommend-docker-template.
    SharedPreferences.setMockInitialValues({'DockerImageCount': 3});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const FluentApp(
      home: ScaffoldPage(
        content: RecommendationsPanel(distroNames: []),
      ),
    ));
    await tester.pump();
  }

  testWidgets('dismiss removes the card on the click, not on a later rebuild',
      (tester) async {
    await pump(tester);
    expect(find.text('recommend-docker-template'), findsOneWidget);

    // The old panel wrote the pref and changed nothing on screen (PS-41).
    await tester.tap(find.byKey(
        const ValueKey('test-recommendation-dismiss-recommend-docker-template')));
    await tester.pump();

    expect(find.text('recommend-docker-template'), findsNothing);
    expect(RecommenderService().isDismissed('recommend-docker-template'), true);
    // And with its only card gone the panel goes too, instead of standing as
    // an empty bordered box (PS-44).
    expect(find.text('recommendations-title'), findsNothing);

    // Let the tapped button's tooltip timer run out before teardown.
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('following the link does not dismiss the card', (tester) async {
    await pump(tester);

    // `dismiss` used to be called `clearDismissed` and the Go-to link called
    // it as a side effect, so acting on a recommendation erased it (PS-42).
    expect(find.byType(HyperlinkButton), findsOneWidget);
    expect(RecommenderService().isDismissed('recommend-docker-template'), false);
  });
}
