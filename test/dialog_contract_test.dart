/// One dialog contract (FIX-09): primary action filled and first, Cancel
/// last, validation before the pop, and no input placeholder that poses as a
/// value.
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed — which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';

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

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    plausible = _MockPlausible();
  });

  Future<void> pumpAndOpen(
    WidgetTester tester, {
    String? Function(String)? validateInput,
    void Function(String)? onSubmit,
    String placeholder = '',
  }) async {
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Builder(
          builder: (context) => Button(
            child: const Text('open'),
            onPressed: () => dialog(
              hostContext: context,
              item: 'Ubuntu',
              title: 'title',
              body: 'body',
              submitText: 'submit',
              placeholder: placeholder,
              validateInput: validateInput,
              onSubmit: onSubmit,
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the submit button is filled and comes before Cancel',
      (tester) async {
    await pumpAndOpen(tester);

    expect(find.byType(FilledButton), findsOneWidget);
    // Order: primary first — the position that means "cancel" must be the
    // same in every dialog (audit ST-62).
    final submitX = tester.getTopLeft(find.byType(FilledButton)).dx;
    final cancelX = tester
        .getTopLeft(find.byKey(const ValueKey('test-dialog-cancel')))
        .dx;
    expect(submitX, lessThan(cancelX));
  });

  testWidgets('the input no longer shows the item as its placeholder',
      (tester) async {
    await pumpAndOpen(tester);

    // The box used to show the *source's own name* in placeholder grey, so an
    // empty field read as pre-filled (audit CI-30, ST-43).
    final box = tester.widget<TextBox>(find.byType(TextBox));
    expect(box.placeholder, isNot('Ubuntu'));
  });

  testWidgets('a failed validation keeps the dialog open with the reason',
      (tester) async {
    var submitted = false;
    await pumpAndOpen(
      tester,
      validateInput: (text) => text.isEmpty ? 'name it first' : null,
      onSubmit: (_) => submitted = true,
    );

    await tester.tap(find.text('submit'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-dialog-validation')), findsOneWidget);
    expect(find.text('name it first'), findsOneWidget);
    expect(submitted, false, reason: 'validation must run before the pop');
    expect(find.text('title'), findsOneWidget, reason: 'dialog stays open');

    // The message clears the moment the input stops being wrong…
    await tester.enterText(find.byType(TextBox), 'new-name');
    await tester.pump();
    expect(find.text('name it first'), findsNothing);

    // …and a valid submit pops and delivers the text.
    await tester.tap(find.text('submit'));
    await tester.pumpAndSettle();
    expect(submitted, true);
    expect(find.text('title'), findsNothing);
  });

  test('the dead createDialog() stayed dead (CI-28)', () {
    final src = File('lib/dialogs/create_dialog.dart').readAsStringSync();
    expect(src, isNot(contains('createDialog()')),
        reason: 'the dialog CreatePage replaced carried the opposite '
            'button order');
  });
}
