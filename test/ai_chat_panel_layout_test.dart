/// The notices at the top of the AI dock ("needs a key", "why Send did
/// nothing", "request failed") carry a button. In a 360px dock the sentence
/// always wraps, and fluent's short InfoBar layout — a Wrap with no run
/// spacing — dropped the button straight onto the last line of text
/// (ai-tasks#15). The long layout stacks title and button with a gap.
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed — which is what the finders match on.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/todo_store.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

void main() {
  /// The dock's width on a wide window (root_screen.dart).
  const dockWidth = 360.0;

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {};
  });

  setUp(() {
    vmBackendBuilder = () => WSLApi(shell: MockShell());
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
  });

  Future<void> pumpDock(WidgetTester tester,
      {Map<String, Object> prefsValues = const {}}) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    prefs = await SharedPreferences.getInstance();
    // The first-start AI question is answered with a yes here: these tests
    // are about what happens once the features are on (bostrot/ai-tasks#98).
    AiService.setFeaturesEnabled(true);
    await AiService().init();
    addTearDown(AiService().clearHistory);

    await tester.binding.setSurfaceSize(const Size(dockWidth, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        const FluentApp(home: ScaffoldPage(content: AiChatPanel())));
    await tester.pumpAndSettle();
  }

  /// The button of the InfoBar at [bar] must start below the bar's title
  /// with visible breathing room, rather than touching or overlapping it.
  void expectButtonBelowTitle(WidgetTester tester, Finder bar, String title) {
    final titleRect =
        tester.getRect(find.descendant(of: bar, matching: find.text(title)));
    final buttonRect =
        tester.getRect(find.descendant(of: bar, matching: find.byType(Button)));
    expect(buttonRect.top - titleRect.bottom, greaterThanOrEqualTo(8.0),
        reason: 'the button must not sit hard against the text above it');
    expect(buttonRect.left, closeTo(titleRect.left, 1.0),
        reason: 'stacked under the title, not trailing its last line');
    // And it still fits the dock.
    expect(buttonRect.right, lessThanOrEqualTo(dockWidth));
  }

  group('AI dock notices', () {
    testWidgets('"needs a key" keeps a gap above Open settings',
        (tester) async {
      await pumpDock(tester);

      final bar = find.byKey(const ValueKey('test-aichat-needs-key'));
      expect(bar, findsOneWidget);
      expect(tester.widget<InfoBar>(bar).isLong, isTrue);
      expectButtonBelowTitle(tester, bar, 'byok-required-text');
    });

    testWidgets('"needs a key" is gone once a key is configured',
        (tester) async {
      await pumpDock(tester, prefsValues: {'ByokApiKey': 'sk-test'});
      expect(find.byKey(const ValueKey('test-aichat-needs-key')), findsNothing);
    });

    testWidgets('a blocked Send keeps a gap above its action', (tester) async {
      await pumpDock(tester);

      await tester.enterText(find.byType(TextBox).first, 'hello');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-chat-send')));
      await tester.pumpAndSettle();

      // Blocking replaces the standing notice rather than doubling it. Under
      // the test binding the licence check is what blocks first, so the
      // notice is the Pro one with its Upgrade action.
      expect(find.byKey(const ValueKey('test-aichat-needs-key')), findsNothing);
      final bar = find.byKey(const ValueKey('test-aichat-blocked'));
      expect(bar, findsOneWidget);
      expect(tester.widget<InfoBar>(bar).isLong, isTrue);
      expectButtonBelowTitle(tester, bar, 'ai-chat-pro-required-text');
    });
  });

  // One geometry for the whole panel: the header's actions, the composer's
  // Send and the task row's buttons used to be three sizes, with a text Send
  // and a separate Cancel beside a box of yet another height
  // (user-reported).
  group('AI dock geometry', () {
    testWidgets('header actions are one size and on one line',
        (tester) async {
      await pumpDock(tester);

      final rects = [
        for (final key in ['test-chat-new', 'test-chat-clear'])
          tester.getRect(find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(IconButton))),
      ];
      for (final rect in rects) {
        expect(rect.size, const Size.square(AiChatPanel.controlSize));
        expect(rect.center.dy, closeTo(rects.first.center.dy, 0.5));
      }
    });

    testWidgets('the title gets all the room the actions leave',
        (tester) async {
      await pumpDock(tester);

      // A Flexible title beside a Spacer split the spare width in half, so
      // "AI Assistant" was cut to "AI Assis…" with room to spare. Without a
      // localization delegate the title is its (long) key, which is cut
      // either way — what matters is that the badge ends where the actions
      // start, i.e. no width was handed to anything else.
      final badge = tester.getRect(find.byType(BetaBadge));
      final firstAction = tester.getRect(find.descendant(
          of: find.byKey(const ValueKey('test-chat-new')),
          matching: find.byType(IconButton)));
      expect(firstAction.left - badge.right, lessThanOrEqualTo(4.0));
    });

    testWidgets('Send sits inside the composer at the control size',
        (tester) async {
      await pumpDock(tester);

      final send = tester.getRect(find.byKey(const ValueKey('test-chat-send')));
      final input =
          tester.getRect(find.byKey(const ValueKey('test-chat-input')));
      expect(send.size, const Size.square(AiChatPanel.controlSize));
      expect(input.height, greaterThanOrEqualTo(AiChatPanel.controlSize));
      // Flush with the box's bottom edge, to the right of it.
      expect(send.bottom, closeTo(input.bottom, 0.5));
      expect(send.left, greaterThan(input.right));
      expect(send.right, lessThanOrEqualTo(dockWidth));
    });

    testWidgets('a task is added from the button as well as Enter',
        (tester) async {
      await pumpDock(tester);
      addTearDown(() {
        for (final t in TodoStore.instance.items) {
          TodoStore.instance.remove(t.id);
        }
      });

      await tester.tap(find.byKey(const ValueKey('test-chat-tasks-toggle')));
      await tester.pumpAndSettle();
      final add = find.descendant(
          of: find.byKey(const ValueKey('test-chat-task-add')),
          matching: find.byType(IconButton));
      expect(tester.widget<IconButton>(add).onPressed, isNull,
          reason: 'nothing to add yet');

      await tester.enterText(
          find.byKey(const ValueKey('test-chat-task-input')), 'check disk');
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();

      expect(TodoStore.instance.items.map((t) => t.text), ['check disk']);
      expect(find.text('check disk'), findsOneWidget);
    });
  });
}
