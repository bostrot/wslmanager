/// The expanded instance row has to fit the window the app lets the user
/// make (`main.dart` sets a 700x500 minimum).
///
/// A `Row` that runs out of room neither scrolls nor wraps: it paints the
/// yellow overflow stripes and hides whatever is past the edge. At the
/// minimum width the "no snippets yet" hint on the left of the expanded row
/// was pushing the last ~43px of the action strip out of view, and the strip
/// keeps growing with every feature that ships — eleven buttons now
/// (bostrot/ai-tasks#109).
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list_item.dart';

import 'mocks.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // Built outside the pump: the first WSLApi ever constructed starts the
    // distro-catalogue fetch, and a Dio timer left pending in a widget
    // test's fake zone fails it.
    final backend = WSLApi(shell: MockShell());
    vmBackendBuilder = () => backend;
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
  });

  /// The body width left over at the app's minimum window width, once the
  /// collapsed navigation pane and the page's own padding are taken off.
  const double narrowBody = 640.0;

  /// Pumps one expanded row at [width] and hands back the action strip's
  /// bounds.
  Future<Rect> expandedStrip(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const FluentApp(
      home: ScaffoldPage(
        content: ListItem(
            item: 'Ubuntu', running: ['Ubuntu'], trailing: '2.1 GB'),
      ),
    ));
    // The strip lives in the expander's content, so the row has to be open.
    await tester.tap(find.text('Ubuntu (running-text)'));
    await tester.pumpAndSettle();
    return tester.getRect(
        find.byKey(const ValueKey('test-listitem-resources-Ubuntu')));
  }

  testWidgets('the whole action strip is reachable at the minimum width',
      (tester) async {
    final button = await expandedStrip(tester, narrowBody);
    // An overflowing RenderFlex reports itself through the binding rather
    // than by failing a finder.
    expect(tester.takeException(), isNull);
    // And the strip really is on screen, not merely un-clipped.
    expect(button.left, greaterThanOrEqualTo(0.0));
    expect(button.right, lessThanOrEqualTo(narrowBody));
  });

  testWidgets('and on a window the size of the app\'s own default',
      (tester) async {
    final button = await expandedStrip(tester, 1100.0);
    expect(tester.takeException(), isNull);
    expect(button.right, lessThanOrEqualTo(1100.0));
  });
}
