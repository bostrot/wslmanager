/// What the app tells the user has to be copyable: the assistant's replies —
/// addresses, URLs, commands — and the IP/size label on a VM row were plain,
/// unselectable labels. These tests select and copy both through the same
/// paths the mouse and Ctrl/Cmd+C use.
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// handed — which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list_item.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

void main() {
  /// Every text handed to the system clipboard, in order.
  late List<String> copied;

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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    vmBackendBuilder = () => WSLApi(shell: MockShell());

    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('AI chat transcript', () {
    // A paragraph, a fenced block and a paragraph after it: the block is
    // rendered by the panel's own builder, and the text after it is what
    // used to inherit a broken inline stack from that builder.
    const reply = 'Nginx answers at **192.168.64.20** now.\n\n'
        '```\ncurl http://192.168.64.20\n```\n\nOpen it in a browser.';

    Future<void> pumpChat(WidgetTester tester,
        {List<Map<String, String>> history = const []}) async {
      SharedPreferences.setMockInitialValues(
          {'AiConversation': json.encode(history)});
      prefs = await SharedPreferences.getInstance();
      await AiService().init();
      addTearDown(AiService().clearHistory);

      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
          const FluentApp(home: ScaffoldPage(content: AiChatPanel())));
      await tester.pumpAndSettle();
    }

    final conversation = [
      {
        'role': 'user',
        'content': 'where does nginx listen',
        'timestamp': '2026-08-30T10:00:00.000',
      },
      {
        'role': 'tool',
        'content': 'wsl_run_command',
        'timestamp': '2026-08-30T10:00:01.000',
      },
      {
        'role': 'assistant',
        'content': reply,
        'timestamp': '2026-08-30T10:00:02.000',
      },
    ];

    /// The transcript's own focus node — the selection region's, reached
    /// from any text inside it.
    FocusNode transcriptFocus(WidgetTester tester) =>
        Focus.of(tester.element(find.text('where does nginx listen')));

    /// Drags the mouse from the start of [from] to the end of [to], the way
    /// a user selects a stretch of the transcript.
    Future<void> dragSelect(WidgetTester tester, Finder from, Finder to) async {
      final gesture = await tester.startGesture(
          tester.getTopLeft(from) + const Offset(1, 1),
          kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(tester.getBottomRight(to) - const Offset(1, 1));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    /// Ctrl+C. Tests run as Android, where the copy chord is Control.
    Future<void> pressCopy(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('can be selected across bubbles and copied', (tester) async {
      await pumpChat(tester, history: conversation);

      await dragSelect(tester, find.text('where does nginx listen'),
          find.textContaining('Open it in a browser.'));
      expect(primaryFocus, transcriptFocus(tester),
          reason: 'selecting must focus the region so Ctrl+C reaches it');
      await pressCopy(tester);

      // One line per bubble, tool note, paragraph and code block — Flutter
      // on its own glues neighbouring widgets' text into one run of words.
      expect(copied, [
        'where does nginx listen\n'
            'ai-ran-tool-text\n'
            'Nginx answers at 192.168.64.20 now.\n'
            'curl http://192.168.64.20\n'
            'Open it in a browser.'
      ]);
    });

    testWidgets('renders a reply with a fenced block, and what follows it',
        (tester) async {
      await pumpChat(tester, history: conversation);

      // The panel's code block builder used to leave flutter_markdown's
      // inline stack dirty, which fails an assertion in a debug build and
      // swallowed the paragraph after the block into the block's own run.
      expect(find.byIcon(FluentIcons.copy), findsOneWidget);
      final after =
          tester.widget<Text>(find.textContaining('Open it in a browser.'));
      expect(after.textSpan!.style?.fontSize, AiChatPanel.bodyFontSize,
          reason: 'the paragraph after the block keeps the paragraph style');
    });

    testWidgets('keeps the line breaks when dragged bottom to top',
        (tester) async {
      await pumpChat(tester, history: conversation);

      // From inside the last paragraph up into the first bubble, passing
      // over each entry on the way as a real drag does.
      final gesture = await tester.startGesture(
          tester.getCenter(find.textContaining('Open it in a browser.')),
          kind: PointerDeviceKind.mouse);
      await tester.pump();
      for (final stop in [
        find.textContaining('Nginx answers at'),
        find.text('ai-ran-tool-text'),
        find.text('where does nginx listen'),
      ]) {
        await gesture.moveTo(tester.getCenter(stop));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      await pressCopy(tester);

      // Flutter's own selection keeps only part of the bubble the drag
      // started in on a synthetic drag like this one (the same happens
      // without the per-entry containers), so only the head is asserted:
      // the entries above it, each on its own line.
      final lines = copied.single.split('\n');
      expect(lines.length, greaterThanOrEqualTo(3));
      expect(lines.first, isNotEmpty);
      expect('where does nginx listen', endsWith(lines.first));
      expect(lines[1], 'ai-ran-tool-text');
      expect(lines[2], 'Nginx answers at 192.168.64.20 now.');
    });

    testWidgets('copies one paragraph without a line break', (tester) async {
      await pumpChat(tester, history: conversation);

      final paragraph = find.textContaining('Nginx answers at');
      await dragSelect(tester, paragraph, paragraph);
      await pressCopy(tester);

      expect(copied, ['Nginx answers at 192.168.64.20 now.']);
    });

    testWidgets('select all copies every line, with no trailing break',
        (tester) async {
      await pumpChat(tester, history: conversation);

      // Click into the transcript, then Ctrl+A.
      await tester.tapAt(tester.getCenter(find.text('where does nginx listen')),
          kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await pressCopy(tester);

      expect(copied, [
        'where does nginx listen\n'
            'ai-ran-tool-text\n'
            'Nginx answers at 192.168.64.20 now.\n'
            'curl http://192.168.64.20\n'
            'Open it in a browser.'
      ]);
    });

    testWidgets('copies nothing while nothing is selected', (tester) async {
      await pumpChat(tester, history: conversation);

      transcriptFocus(tester).requestFocus();
      await tester.pump();
      await pressCopy(tester);

      expect(copied, isEmpty);
    });

    testWidgets('keeps the code block copy button working inside the region',
        (tester) async {
      await pumpChat(tester, history: conversation);

      await tester.tap(find.byIcon(FluentIcons.copy));
      // Let the button's pressed-state flash (a 100ms timer) run out.
      await tester.pump(const Duration(milliseconds: 200));

      expect(copied, ['curl http://192.168.64.20']);
    });

    testWidgets('has no selection region over the empty state', (tester) async {
      await pumpChat(tester);

      expect(find.byKey(const ValueKey('test-chat-transcript')), findsNothing);
      expect(find.text('ai-assistant-hint'), findsOneWidget);
    });
  });

  group('VM row size/IP label', () {
    const label = '192.168.64.20 · 1.65 GB';

    Widget row({String trailing = label}) => FluentApp(
          home: ScaffoldPage(
            content: ListItem(
                item: 'alpine-web',
                running: const ['alpine-web'],
                trailing: trailing),
          ),
        );

    Finder labelText() => find.descendant(
          of: find.byKey(const ValueKey('test-listitem-meta-alpine-web')),
          matching: find.byType(EditableText),
        );

    testWidgets('is selectable text that copies as written', (tester) async {
      await tester.pumpWidget(row());
      await tester.pumpAndSettle();

      expect(find.widgetWithText(SelectableText, label), findsOneWidget);

      final editable = tester.state<EditableTextState>(labelText());
      editable.selectAll(SelectionChangedCause.keyboard);
      await tester.pump();
      editable.copySelection(SelectionChangedCause.keyboard);
      await tester.pump();

      expect(copied, [label]);
    });

    testWidgets('is not a Tab stop of its own', (tester) async {
      await tester.pumpWidget(row());
      await tester.pumpAndSettle();

      // Walk the whole cycle: the row, its buttons, and back round.
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(tester.widget<EditableText>(labelText()).focusNode.hasFocus,
            isFalse,
            reason: 'Tab press ${i + 1} landed on the size/IP label');
      }
    });

    testWidgets('still shows a dash when the size is unknown', (tester) async {
      await tester.pumpWidget(row(trailing: ''));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(SelectableText, '—'), findsOneWidget);
    });
  });
}
