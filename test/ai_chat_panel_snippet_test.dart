/// The note the AI dock leaves after a run that changed an instance: which
/// snippet holds the record, with a link into the editor (ai-tasks#77).
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed — which is what the finders match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

void main() {
  const snippetName = 'ai-run-dev-2026-09-14-1007';

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

  /// A stored transcript that ends on the note a recorded run leaves.
  String transcriptWithNote() => json.encode([
        AiMessage(
                role: 'user',
                content: 'set up dev',
                timestamp: DateTime(2026, 9, 14, 10, 7))
            .toJson(),
        AiMessage(
                role: 'tool',
                content: 'vm_create_linux',
                timestamp: DateTime(2026, 9, 14, 10, 7))
            .toJson(),
        AiMessage(
                role: 'snippet',
                content: snippetName,
                timestamp: DateTime(2026, 9, 14, 10, 8))
            .toJson(),
        AiMessage(
                role: 'assistant',
                content: 'Done.',
                timestamp: DateTime(2026, 9, 14, 10, 8))
            .toJson(),
      ]);

  Future<void> pumpDock(WidgetTester tester,
      {required bool snippetExists}) async {
    SharedPreferences.setMockInitialValues({
      'ByokApiKey': 'sk-test',
      'AiConversation': transcriptWithNote(),
    });
    prefs = await SharedPreferences.getInstance();
    if (snippetExists) {
      QuickAction.addToPrefs(
          QuickActionItem(name: snippetName, content: '#!/bin/bash\necho hi'));
    }
    await AiService().init();
    addTearDown(AiService().clearHistory);

    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        const FluentApp(home: ScaffoldPage(content: AiChatPanel())));
    await tester.pumpAndSettle();
  }

  testWidgets('a saved run shows its snippet name and an Open link',
      (tester) async {
    await pumpDock(tester, snippetExists: true);

    final note = find.byKey(const ValueKey('test-aichat-snippet-$snippetName'));
    expect(note, findsOneWidget);
    expect(
        find.descendant(
            of: note, matching: find.text('ai-run-snippet-saved-text')),
        findsOneWidget);
    expect(
        find.descendant(
            of: note, matching: find.text('ai-run-snippet-open-text')),
        findsOneWidget);
    expect(find.text('ai-run-snippet-missing-text'), findsNothing);
    // It is a note, not a bubble: no avatar next to it, unlike the reply.
    expect(find.byIcon(FluentIcons.code), findsOneWidget);
  });

  testWidgets('once the snippet is deleted the note says so and loses the link',
      (tester) async {
    await pumpDock(tester, snippetExists: false);

    final note = find.byKey(const ValueKey('test-aichat-snippet-$snippetName'));
    expect(note, findsOneWidget);
    expect(
        find.descendant(
            of: note, matching: find.text('ai-run-snippet-missing-text')),
        findsOneWidget);
    expect(find.text('ai-run-snippet-open-text'), findsNothing);
    expect(find.byType(HyperlinkButton), findsNothing);
  });

  test('the note is never sent to the provider', () {
    final transcript = [
      AiMessage(role: 'user', content: 'hi', timestamp: DateTime.now()),
      AiMessage(
          role: 'snippet', content: snippetName, timestamp: DateTime.now()),
      AiMessage(role: 'assistant', content: 'done', timestamp: DateTime.now()),
    ];
    expect(AiService.capTranscript(transcript).map((m) => m.role).toList(),
        ['user', 'assistant']);
  });
}
