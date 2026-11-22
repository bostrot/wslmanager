import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/sandbox_service.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/ai_diagnosis.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/panelist.dart';

import 'vm_backend_test.dart' show FakeBackend;

/// A backend that offers the AI Workspace, whatever the host platform: the
/// pane entry's *backend* gate is covered elsewhere; here only the AI switch
/// is under test.
class _WorkspaceBackend extends FakeBackend {
  @override
  VmFeatures get features => const VmFeatures(aiWorkspace: true);
}

/// A provider that never answers: a run stays in flight until it is
/// cancelled, which is the state the switch has to deal with.
class _HangingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    final gate = Completer<ResponseBody>();
    if (cancelFuture == null) return gate.future;
    return Future.any([
      gate.future,
      cancelFuture.then((_) => throw DioException.requestCancelled(
          requestOptions: options, reason: 'cancelled')),
    ]);
  }

  @override
  void close({bool force = false}) {}
}

/// The "AI features" switch (bostrot/ai-tasks#85): a user who does not want
/// an assistant leaves it off, and every AI entry point — the chat, the
/// sandbox chat, the diagnosis button, the nav pane entry — goes with it.
///
/// Off until the first-start question is answered (bostrot/ai-tasks#98), so
/// an install that has never been asked behaves exactly like one that said
/// no. The question itself lives in ai_consent_prompt_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    GlobalVariable.aiPanel.value = false;
    // Pro throughout: the switch is only meaningful with something to turn
    // off, and a non-Pro refusal would mask the one under test.
    LicenseManager.storeInstallCheckOverride = () => true;
    LicenseManager.storeFreeFromOverride =
        DateTime.now().toUtc().add(const Duration(days: 1));
    await LicenseManager().init();
    AiService()
      ..clearHistory()
      ..setByokApiKey('sk-test');
  });

  tearDown(() {
    GlobalVariable.aiPanel.value = false;
    LicenseManager.storeInstallCheckOverride = null;
    LicenseManager.storeFreeFromOverride = null;
  });

  group('the switch', () {
    test('is off until the user says yes', () {
      expect(AiService.featuresEnabled, isFalse);
      expect(AiService.featuresDecided, isFalse);
      expect(prefs.getBool(AiService.enabledPrefKey), isNull,
          reason: 'nothing is written until the user decides');
    });

    test('a "no" is written even though it matches the undecided value', () {
      // Otherwise the prompt has nothing to read and comes back on the next
      // start, which is exactly what "asked once" rules out.
      AiService.setFeaturesEnabled(false);
      expect(prefs.getBool(AiService.enabledPrefKey), isFalse);
      expect(AiService.featuresDecided, isTrue);
    });

    test('persists and comes back', () {
      AiService.setFeaturesEnabled(false);
      expect(prefs.getBool(AiService.enabledPrefKey), isFalse);
      expect(AiService.featuresEnabled, isFalse);
      AiService.setFeaturesEnabled(true);
      expect(AiService.featuresEnabled, isTrue);
      expect(AiService.featuresDecided, isTrue);
    });

    test('closes an open chat dock and tells the shell', () {
      AiService.setFeaturesEnabled(true);
      var fired = 0;
      void listener() => fired++;
      AiService.featuresChanged.addListener(listener);
      addTearDown(() => AiService.featuresChanged.removeListener(listener));

      GlobalVariable.aiPanel.value = true;
      AiService.setFeaturesEnabled(false);
      expect(GlobalVariable.aiPanel.value, isFalse);
      expect(fired, 1);

      // Turning it back on does not reopen a dock the user closed.
      AiService.setFeaturesEnabled(true);
      expect(GlobalVariable.aiPanel.value, isFalse);
      expect(fired, 2);

      // Re-asserting the current value is not a change.
      AiService.setFeaturesEnabled(true);
      expect(fired, 2);
    });

    test('turning it off stops a run that is still executing', () async {
      // The dock and its Stop button go with the switch; a run left going
      // would keep calling tools and billing the key with nothing to halt it.
      AiService.setFeaturesEnabled(true);
      final ai = AiService();
      ai.dioForTesting.httpClientAdapter = _HangingAdapter();
      final run = ai.sendMessage('hello');
      expect(ai.isRunning, isTrue);

      AiService.setFeaturesEnabled(false);

      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(ai.isRunning, isFalse);
    });
  });

  group('with AI switched off', () {
    setUp(() => AiService.setFeaturesEnabled(false));

    test('the chat refuses before Pro or the key are even looked at',
        () async {
      final ai = AiService();
      expect(ai.hasAiConfigured, isTrue);
      expect(LicenseManager().isPro, isTrue);
      await expectLater(ai.sendMessage('hi'),
          throwsA(predicate((e) => e.toString().contains('ai-disabled'))));
      await expectLater(ai.retryLast(),
          throwsA(predicate((e) => e.toString().contains('ai-disabled'))));
      expect(ai.conversationHistory, isEmpty,
          reason: 'a refused message must not land in the transcript');
    });

    test('the sandbox chat refuses the same way', () async {
      final chat = SandboxChat.forTesting('wslm-sandbox-box');
      expect(chat.canSend, isFalse);
      await expectLater(chat.send('hi'),
          throwsA(predicate((e) => e.toString().contains('ai-disabled'))));
      expect(chat.history, isEmpty);
    });

    test('the diagnosis button is not offered', () {
      expect(canDiagnoseWithAi(), isFalse);
      AiService.setFeaturesEnabled(true);
      expect(canDiagnoseWithAi(), isTrue);
    });

    test('the AI Workspace leaves the navigation pane', () {
      vmBackendBuilder = _WorkspaceBackend.new;
      addTearDown(() => vmBackendBuilder = defaultVmBackendBuilder);
      Set<String> paneKeys() => originalItems
          .map((item) => item.key)
          .whereType<Key>()
          .map((key) => key.toString())
          .toSet();

      expect(paneKeys(), isNot(contains("[<'/ai-workspace'>]")));
      AiService.setFeaturesEnabled(true);
      expect(paneKeys(), contains("[<'/ai-workspace'>]"));
    });
  });
}
