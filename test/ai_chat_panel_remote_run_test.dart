/// The desktop panel and the web dashboard share one AiService and one
/// transcript (ai-tasks#83). A turn that a dashboard-started run adds must
/// show up in the panel without the panel having been involved, and while
/// such a run is in flight the panel must wait — and be able to stop it —
/// rather than start a second run on the same service.
///
/// The provider round trip goes through dio, which does not complete inside
/// the widget test's fake-async zone, so every run is started and awaited
/// under `runAsync`. There is no localization delegate here, so `.i18n()`
/// returns the key it was handed — which is what the finders match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

/// The provider, answering when the test says so. Like the real adapter, a
/// held answer is dropped once the request is cancelled.
class _GatedAdapter implements HttpClientAdapter {
  final Completer<ResponseBody> gate = Completer<ResponseBody>();

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    if (cancelFuture == null) return gate.future;
    return Future.any([
      gate.future,
      cancelFuture.then((_) => throw DioException.requestCancelled(
          requestOptions: options, reason: 'cancelled')),
    ]);
  }

  @override
  void close({bool force = false}) {}

  void reply(String text) => gate.complete(ResponseBody.fromString(
        json.encode({
          'choices': [
            {
              'message': {'content': text}
            }
          ]
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ));
}

void main() {
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

  late AiService ai;
  late _GatedAdapter provider;

  setUp(() async {
    vmBackendBuilder = () => WSLApi(shell: MockShell());
    SharedPreferences.setMockInitialValues({'ByokApiKey': 'sk-test'});
    prefs = await SharedPreferences.getInstance();
    // The first-start AI question is answered with a yes here: these tests
    // are about what happens once the features are on (bostrot/ai-tasks#98).
    AiService.setFeaturesEnabled(true);
    LicenseManager.storeInstallCheckOverride = () => true;
    LicenseManager.storeFreeFromOverride =
        DateTime.now().toUtc().add(const Duration(days: 1));
    await LicenseManager().init();
    ai = AiService();
    await ai.init();
    ai.clearHistory();
    ai.toolsForTesting = const [];
    provider = _GatedAdapter();
    ai.dioForTesting.httpClientAdapter = provider;
  });

  tearDown(() {
    ai.cancelRun();
    ai.clearHistory();
    vmBackendBuilder = defaultVmBackendBuilder;
    LicenseManager.storeInstallCheckOverride = null;
    LicenseManager.storeFreeFromOverride = null;
  });

  Future<void> pumpDock(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
        const FluentApp(home: ScaffoldPage(content: AiChatPanel())));
    await tester.pumpAndSettle();
  }

  /// Starts a run the way the web dashboard does — on the service, with no
  /// panel involvement — and returns it still in flight.
  Future<Future<String>> startRemoteRun(
      WidgetTester tester, String text) async {
    late Future<String> run;
    await tester.runAsync(() async {
      run = ai.sendMessage(text);
      // Let the request reach the (gated) provider.
      await Future<void>.delayed(Duration.zero);
    });
    return run;
  }

  /// Send and Stop share one slot in the composer: Send while idle, Stop
  /// while a run is in flight.
  Finder sendButton() => find.byKey(const ValueKey('test-chat-send'));
  Finder cancelButton() =>
      find.byKey(const ValueKey('test-chat-cancel-request'));

  testWidgets('a turn added by a run the panel did not start is shown',
      (tester) async {
    await pumpDock(tester);
    expect(find.textContaining('Ubuntu is running.'), findsNothing);

    final run = await startRemoteRun(tester, 'is ubuntu up?');
    await tester.runAsync(() async {
      provider.reply('Ubuntu is running.');
      await run;
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('is ubuntu up?'), findsOneWidget);
    expect(find.textContaining('Ubuntu is running.'), findsOneWidget);
  });

  testWidgets('Send waits while a run started elsewhere is in flight',
      (tester) async {
    await pumpDock(tester);
    await tester.enterText(find.byType(TextBox), 'another question');
    await tester.pump();
    expect(tester.widget<Button>(sendButton()).onPressed, isNotNull);

    final run = await startRemoteRun(tester, 'slow question');
    await tester.pump();

    expect(ai.isRunning, true);
    expect(sendButton(), findsNothing,
        reason: 'Send turns into Stop instead of offering a second run');
    expect(cancelButton(), findsOneWidget);
    expect(tester.widget<Button>(cancelButton()).onPressed, isNotNull);

    await tester.runAsync(() async {
      provider.reply('done');
      await run;
    });
    await tester.pumpAndSettle();

    expect(tester.widget<Button>(sendButton()).onPressed, isNotNull);
    expect(cancelButton(), findsNothing);
    // The typed question survived the wait.
    expect(find.text('another question'), findsOneWidget);
  });

  testWidgets('Cancel stops a run started elsewhere', (tester) async {
    await pumpDock(tester);
    final run = await startRemoteRun(tester, 'slow question');
    await tester.pump();
    expect(ai.isRunning, true);

    await tester.tap(cancelButton());
    await tester
        .runAsync(() => expectLater(run, throwsA(isA<CancelledException>())));
    await tester.pumpAndSettle();

    expect(ai.isRunning, false);
    expect(cancelButton(), findsNothing);
  });
}
