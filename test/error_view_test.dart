import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/error_view.dart';

/// Without a localization delegate `.i18n()` answers with the key, which is
/// exactly what these tests want to see: it proves which sentence was chosen
/// without pinning the English wording.
void main() {
  const pathNotFound = WslFailure(
    code: 'Wsl/ERROR_PATH_NOT_FOUND',
    details: 'Das System kann den angegebenen Pfad nicht finden.\n'
        'Fehlercode: Wsl/ERROR_PATH_NOT_FOUND',
  );

  testWidgets('shows the mapped sentence, not the raw output', (tester) async {
    await tester.pumpWidget(
      const FluentApp(home: ScaffoldPage(content: ErrorBody(failure: pathNotFound))),
    );

    expect(find.text('wslerror-pathnotfound-text'), findsOneWidget);
    // The blocker being fixed: the tool's own words were the whole message.
    expect(find.textContaining('Fehlercode'), findsNothing);
  });

  testWidgets('keeps the raw output one tap away', (tester) async {
    await tester.pumpWidget(
      const FluentApp(home: ScaffoldPage(content: ErrorBody(failure: pathNotFound))),
    );

    expect(find.text('errordetails-text'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('test-error-details-toggle')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Fehlercode'), findsOneWidget);
  });

  testWidgets('offers no disclosure when the tool said nothing',
      (tester) async {
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(content: ErrorBody(failure: WslFailure())),
      ),
    );

    expect(find.text('wslerror-generic-text'), findsOneWidget);
    expect(find.byKey(const ValueKey('test-error-details-toggle')),
        findsNothing);
  });

  testWidgets('renders the caller lead sentence and hint around it',
      (tester) async {
    await tester.pumpWidget(
      const FluentApp(
        home: ScaffoldPage(
          content: ErrorBody(
            failure: pathNotFound,
            leading: 'lead sentence.',
            hint: 'hint sentence.',
          ),
        ),
      ),
    );

    expect(find.text('lead sentence. wslerror-pathnotfound-text'),
        findsOneWidget);
    expect(find.text('hint sentence.'), findsOneWidget);
  });
}
