/// The chat box and the chat list (ai-tasks#104): Enter writes a new line
/// and the platform's chord sends, "New chat" files the running thread
/// instead of dropping it, and the history flyout puts one back.
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed — which is what the finders match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_chat_sessions.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

/// A stored transcript, in the shape [AiService.init] reads back.
String storedChat(List<String> turns) => json.encode([
      for (var i = 0; i < turns.length; i++)
        {
          'role': i.isEven ? 'user' : 'assistant',
          'content': turns[i],
          'timestamp': DateTime(2026, 9, 20, 10, i).toIso8601String(),
        }
    ]);

void main() {
  /// The dock's default width (ai_chat_dock.dart).
  const dockWidth = 360.0;
  const inputKey = ValueKey('test-chat-input');

  final sessions = AiChatSessions.instance;
  var expanded = false;

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
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    Map<String, Object> prefsValues = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    prefs = await SharedPreferences.getInstance();
    AiService.setFeaturesEnabled(true);
    await AiService().init();
    addTearDown(AiService().clearHistory);

    expanded = false;
    await tester.binding.setSurfaceSize(const Size(dockWidth, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: StatefulBuilder(
          builder: (context, setState) => AiChatPanel(
            expanded: expanded,
            onToggleExpanded: () => setState(() => expanded = !expanded),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Runs [body] as if the app were on [platform]. The override has to be
  /// back off before the test body returns — the binding checks for it
  /// there, ahead of any tearDown.
  Future<void> onPlatform(
      TargetPlatform platform, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Presses Enter with [modifier] held, as a keyboard would.
  Future<void> pressEnter(WidgetTester tester,
      {LogicalKeyboardKey? modifier}) async {
    if (modifier != null) await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    if (modifier != null) await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  /// Send ran: under the test binding the licence check is what stops it,
  /// and that notice is the panel's proof the message was dispatched.
  final sendAttempted = find.byKey(const ValueKey('test-aichat-blocked'));

  group('the chat box', () {
    testWidgets('holds more than one line', (tester) async {
      await pumpPanel(tester);

      final box = tester.widget<TextBox>(find.byKey(inputKey));
      expect(box.minLines, 1);
      expect(box.maxLines, greaterThan(1),
          reason: 'Enter writes a new line now, so the box has to grow');
    });

    testWidgets('Enter alone does not send', (tester) async {
      await onPlatform(TargetPlatform.windows, () async {
        await pumpPanel(tester);

        await tester.enterText(find.byKey(inputKey), 'half a thought');
        await pressEnter(tester);

        expect(sendAttempted, findsNothing);
        expect(AiService().conversationHistory, isEmpty);
      });
    });

    testWidgets('Ctrl+Enter sends off Windows', (tester) async {
      await onPlatform(TargetPlatform.windows, () async {
        await pumpPanel(tester);

        await tester.enterText(find.byKey(inputKey), 'why is it offline');
        await pressEnter(tester, modifier: LogicalKeyboardKey.controlLeft);

        expect(sendAttempted, findsOneWidget);
      });
    });

    testWidgets('Cmd+Enter sends on macOS, Ctrl+Enter does not',
        (tester) async {
      await onPlatform(TargetPlatform.macOS, () async {
        await pumpPanel(tester);

        await tester.enterText(find.byKey(inputKey), 'why is it offline');
        await pressEnter(tester, modifier: LogicalKeyboardKey.controlLeft);
        expect(sendAttempted, findsNothing);

        await pressEnter(tester, modifier: LogicalKeyboardKey.metaLeft);
        expect(sendAttempted, findsOneWidget);
      });
    });

    testWidgets('the hint names the chord of the platform it runs on',
        (tester) async {
      await onPlatform(TargetPlatform.macOS, () async {
        expect(AiChatPanel.sendsWithCommand, isTrue);
        expect(AiChatPanel.sendModifierLabel, '⌘');
      });
      await onPlatform(TargetPlatform.windows, () async {
        expect(AiChatPanel.sendsWithCommand, isFalse);
        expect(AiChatPanel.sendModifierLabel, 'Ctrl');

        await pumpPanel(tester);
        expect(find.text('ai-send-hint-text'), findsOneWidget);
      });
    });

    testWidgets('the Send button still works', (tester) async {
      await pumpPanel(tester);

      await tester.enterText(find.byKey(inputKey), 'hello');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-chat-send')));
      await tester.pumpAndSettle();

      expect(sendAttempted, findsOneWidget);
    });
  });

  group('new chat', () {
    testWidgets('is offered only once there is something to file',
        (tester) async {
      await pumpPanel(tester);
      final button = find.byKey(const ValueKey('test-chat-new'));
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(
              find.descendant(of: button, matching: find.byType(IconButton)))
          .onPressed, isNull);

      await pumpPanel(tester,
          prefsValues: {'AiConversation': storedChat(['older thread'])});
      expect(
          tester.widget<IconButton>(find.descendant(
                  of: find.byKey(const ValueKey('test-chat-new')),
                  matching: find.byType(IconButton)))
              .onPressed,
          isNotNull);
    });

    testWidgets('files the conversation and empties the panel',
        (tester) async {
      await pumpPanel(tester,
          prefsValues: {'AiConversation': storedChat(['older thread'])});
      expect(AiService().conversationHistory, isNotEmpty);

      await tester.tap(find.byKey(const ValueKey('test-chat-new')));
      await tester.pumpAndSettle();

      expect(AiService().conversationHistory, isEmpty);
      expect(sessions.list().map((s) => s.title), ['older thread']);
      // The empty state is back, so the panel really did start over.
      expect(find.text('ai-assistant-hint'), findsOneWidget);
    });
  });

  group('previous chats', () {
    testWidgets('the history button appears once a chat has been filed',
        (tester) async {
      await pumpPanel(tester);
      // No sandboxes and no history yet: nothing to switch between.
      expect(find.byKey(const ValueKey('test-chat-sessions')), findsNothing);

      await pumpPanel(tester, prefsValues: {
        'AiConversation': storedChat(['older thread']),
      });
      await tester.tap(find.byKey(const ValueKey('test-chat-new')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-chat-sessions')), findsOneWidget);
    });

    testWidgets('reopening one puts it back and files what was on screen',
        (tester) async {
      await pumpPanel(tester,
          prefsValues: {'AiConversation': storedChat(['older thread'])});
      await tester.tap(find.byKey(const ValueKey('test-chat-new')));
      await tester.pumpAndSettle();
      final filed = sessions.list().single.id;

      // Something else is being asked in the meantime.
      AiService().restoreHistory([
        AiMessage(
            role: 'user',
            content: 'live thread',
            timestamp: DateTime(2026, 9, 20, 11)),
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('test-chat-sessions')));
      await tester.pumpAndSettle();
      expect(find.text('ai-chat-history-text'), findsOneWidget);

      await tester.tap(find.text('older thread'));
      await tester.pumpAndSettle();

      expect(AiService().conversationHistory.single.content, 'older thread');
      expect(sessions.currentId, filed);
      expect(sessions.list().map((s) => s.title), ['live thread']);
    });
  });

  group('the expand toggle', () {
    testWidgets('reports the state and flips it', (tester) async {
      await pumpPanel(tester);
      final button = find.byKey(const ValueKey('test-chat-expand'));

      expect(find.descendant(of: button, matching: find.byIcon(FluentIcons.full_screen)),
          findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(expanded, isTrue);
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('test-chat-expand')),
              matching: find.byIcon(FluentIcons.back_to_window)),
          findsOneWidget);
    });

    testWidgets('is absent when there is nothing to expand into',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      AiService.setFeaturesEnabled(true);
      await AiService().init();
      await tester.binding.setSurfaceSize(const Size(dockWidth, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
          const FluentApp(home: ScaffoldPage(content: AiChatPanel())));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-chat-expand')), findsNothing);
    });
  });
}
