import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_chat_sessions.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Records every request it sees and replies based on the path, so tests can
/// assert both "which endpoint got hit" and "what happened with the reply"
/// without making a real network call.
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  ResponseBody Function(RequestOptions options) responder;

  _RecordingAdapter(this.responder);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

/// An adapter whose answer the test releases by hand, so a run can be
/// observed — and cancelled — while it is in flight. Like the real adapter,
/// a held answer is dropped once the request is cancelled.
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
}

/// A complete (non-streamed) chat completion body.
ResponseBody jsonBody(Map<String, dynamic> body) => ResponseBody.fromString(
      json.encode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The first-start AI question is answered with a yes here: these tests
    // are about what happens once the features are on (bostrot/ai-tasks#98).
    AiService.setFeaturesEnabled(true);
    // Not Pro by default; tests that need it flip the override and re-init.
    // The Store copies these tests stand up are paid-era ones, so the flip
    // is held in the future: package identity alone is Pro here.
    LicenseManager.storeInstallCheckOverride = () => false;
    LicenseManager.storeFreeFromOverride =
        DateTime.now().toUtc().add(const Duration(days: 1));
    await LicenseManager().init();
  });

  tearDown(() {
    LicenseManager.storeInstallCheckOverride = null;
    LicenseManager.storeFreeFromOverride = null;
  });

  group('AiService BYOK configuration', () {
    test('not configured without a key', () {
      final ai = AiService();
      expect(ai.hasByokConfigured, false);
    });

    test('a stored key means configured, independent of Pro status', () {
      final ai = AiService();
      ai.setByokApiKey('sk-test');

      // Configuration is a pure "is the key there" signal — Pro gating
      // happens in sendMessage, not here, so Settings can manage the key
      // regardless of entitlement.
      expect(ai.hasByokConfigured, true);
    });

    test('base URL and model fall back to defaults when unset', () {
      final ai = AiService();
      expect(ai.byokBaseUrl, AiService.defaultByokBaseUrl);
      expect(ai.byokModel, AiService.defaultByokModel);
    });

    test('base URL, key, and model are trimmed and persisted', () {
      final ai = AiService();
      ai.setByokBaseUrl('  https://my-proxy.example.com/v1  ');
      ai.setByokApiKey('  sk-abc123  ');
      ai.setByokModel('  gpt-4o  ');

      expect(ai.byokBaseUrl, 'https://my-proxy.example.com/v1');
      expect(ai.byokApiKey, 'sk-abc123');
      expect(ai.byokModel, 'gpt-4o');
    });

    test('setting an empty value clears the stored override', () {
      final ai = AiService();
      ai.setByokBaseUrl('https://my-proxy.example.com/v1');
      ai.setByokBaseUrl('');

      expect(ai.byokBaseUrl, AiService.defaultByokBaseUrl);
    });
  });

  group('AiService sendMessage', () {
    test('throws pro-required when not Pro', () async {
      final ai = AiService();
      await ai.init();

      expect(
        () => ai.sendMessage('hello'),
        throwsA(predicate((e) => e.toString().contains('pro-required'))),
      );
    });

    test('throws byok-required when Pro but no key is configured', () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      await ai.init();

      expect(
        () => ai.sendMessage('hello'),
        throwsA(predicate((e) => e.toString().contains('byok-required'))),
      );
    });

    test('sends via the configured endpoint with the bearer key', () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      ai.setByokBaseUrl('https://my-proxy.example.com/v1');
      ai.setByokModel('gpt-4o');
      await ai.init();
      ai.clearHistory();

      final adapter = _RecordingAdapter((options) {
        expect(options.headers['Authorization'], 'Bearer sk-test');
        return ResponseBody.fromString(
          json.encode({
            'choices': [
              {
                'message': {'content': 'byok reply'}
              }
            ]
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      ai.dioForTesting.httpClientAdapter = adapter;

      final reply = await ai.sendMessage('hello');

      expect(reply, 'byok reply');
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.path,
          'https://my-proxy.example.com/v1/chat/completions');
      final body = json.decode(adapter.requests.single.data as String)
          as Map<String, dynamic>;
      expect(body['model'], 'gpt-4o');
    });

    test('the system prompt names the read-only families only while they are '
        'registered', () async {
      // A prompt that advertises tools the model cannot call earns a round of
      // invented tool calls and an apology (bostrot/ai-tasks#67), so the
      // guidance rides the same gate the tools do.
      Future<String> promptWith(bool? gateOpen) async {
        ExperimentalFeatures.overrideAll = gateOpen;
        addTearDown(() => ExperimentalFeatures.overrideAll = null);
        final ai = AiService();
        LicenseManager.storeInstallCheckOverride = () => true;
        await LicenseManager().init();
        ai.setByokApiKey('sk-test');
        ai.setByokModel('gpt-4o');
        await ai.init();
        ai.clearHistory();
        final adapter = _RecordingAdapter((options) => ResponseBody.fromString(
              json.encode({
                'choices': [
                  {
                    'message': {'content': 'ok'}
                  }
                ]
              }),
              200,
              headers: {
                Headers.contentTypeHeader: [Headers.jsonContentType],
              },
            ));
        ai.dioForTesting.httpClientAdapter = adapter;
        await ai.sendMessage('hello');
        final body = json.decode(adapter.requests.last.data as String)
            as Map<String, dynamic>;
        final messages = body['messages'] as List;
        return messages
            .whereType<Map>()
            .firstWhere((m) => m['role'] == 'system')['content'] as String;
      }

      final open = await promptWith(true);
      expect(open, contains('kube_pod_logs'));
      expect(open, contains('cloud_servers'));
      expect(open, contains('container_disk_usage'));
      // The read-only promise is in the prompt too, so the model says "open
      // the Kubernetes screen" rather than hunting for a tool that scales.
      expect(open, contains('READ-ONLY'));

      final closed = await promptWith(false);
      expect(closed, isNot(contains('kube_')));
      expect(closed, isNot(contains('cloud_servers')));
      expect(closed, isNot(contains('container_')));

      // Each family has its own switch in Settings (bostrot/ai-tasks#87), so
      // the prompt names only the families that are actually on.
      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, true);
      final kubeOnly = await promptWith(null);
      expect(kubeOnly, contains('kube_pod_logs'));
      expect(kubeOnly, isNot(contains('cloud_servers')));
      expect(kubeOnly, isNot(contains('container_')));
    });

    test('a request failure keeps the user message so retry can re-run it',
        () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      await ai.init();
      ai.clearHistory();

      final adapter = _RecordingAdapter((options) {
        return ResponseBody.fromString('server error', 500);
      });
      ai.dioForTesting.httpClientAdapter = adapter;

      await expectLater(ai.sendMessage('hello'), throwsException);
      // The question stays — retryLast re-runs it without a retype.
      expect(ai.conversationHistory, hasLength(1));
      expect(ai.conversationHistory.single.role, 'user');
      expect(ai.conversationHistory.single.content, 'hello');

      // And a retry over the same history reaches the provider again.
      final retryAdapter = _RecordingAdapter((options) => ResponseBody.fromString(
          json.encode({
            'choices': [
              {'message': {'content': 'ok now'}}
            ]
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          }));
      ai.dioForTesting.httpClientAdapter = retryAdapter;
      final reply = await ai.retryLast();
      expect(reply, 'ok now');
      expect(ai.conversationHistory, hasLength(2));
    });
  });

  group('AiService run state', () {
    // The desktop panel and the web dashboard share this one service
    // (ai-tasks#83); these are what lets each side see the other's run.
    Future<AiService> proWithKey() async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      await ai.init();
      ai.clearHistory();
      return ai;
    }

    ResponseBody reply(String text) => jsonBody({
          'choices': [
            {
              'message': {'content': text}
            }
          ]
        });

    test('isRunning is up only while a run is in flight', () async {
      final ai = await proWithKey();
      final adapter = _GatedAdapter();
      ai.dioForTesting.httpClientAdapter = adapter;
      expect(ai.isRunning, false);

      final run = ai.sendMessage('hello');
      expect(ai.isRunning, true);

      adapter.gate.complete(reply('hi'));
      await run;
      expect(ai.isRunning, false);
    });

    test('cancelRun() stops a run that was started without a signal',
        () async {
      final ai = await proWithKey();
      ai.dioForTesting.httpClientAdapter = _GatedAdapter();
      final run = ai.sendMessage('hello');
      expect(ai.isRunning, true);

      ai.cancelRun();

      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(ai.isRunning, false);
      // The question stays for a retry, as after any interrupted run.
      expect(ai.conversationHistory.map((m) => m.role), ['user']);
    });

    test('transcriptRevision moves with every change to the transcript',
        () async {
      final ai = await proWithKey();
      ai.dioForTesting.httpClientAdapter =
          _RecordingAdapter((_) => reply('hi'));
      final start = ai.transcriptRevision.value;

      await ai.sendMessage('hello');
      final afterTurn = ai.transcriptRevision.value;
      ai.clearHistory();

      expect(afterTurn, greaterThan(start));
      expect(ai.transcriptRevision.value, greaterThan(afterTurn));
    });
  });

  group('AiService without the retired Claude provider', () {
    test('configured state and its message follow the API key alone', () {
      final ai = AiService();
      expect(ai.hasAiConfigured, false);
      expect(ai.configRequiredKey, 'byok-required-text');

      ai.setByokApiKey('sk-test');
      expect(ai.hasAiConfigured, true);
    });

    test('init purges the Sign in with Claude leftovers, keeps the key',
        () async {
      // A profile written by a build that still had the provider: the
      // selection, the client ID and — the part that matters — OAuth tokens.
      prefs.setString('AiProvider', 'claude');
      prefs.setString('ClaudeOAuthClientId', 'cid');
      prefs.setString('ClaudeModel', 'claude-x');
      prefs.setString('ClaudeAccessToken', 'at-1');
      prefs.setString('ClaudeRefreshToken', 'rt-1');
      prefs.setInt('ClaudeTokenExpiry', 1);
      prefs.setString('ByokApiKey', 'sk-kept');

      final ai = AiService();
      await ai.init();

      for (final key in AiService.retiredClaudePrefKeys) {
        expect(prefs.containsKey(key), false, reason: key);
      }
      expect(ai.byokApiKey, 'sk-kept');
      // The stale provider choice no longer blocks the key path.
      expect(ai.hasAiConfigured, true);
    });

    test('a stale Claude selection without a key asks for the key, not a sign-in',
        () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      prefs.setString('AiProvider', 'claude');
      await ai.init();

      await expectLater(
        ai.sendMessage('hello'),
        throwsA(predicate((e) => e.toString().contains('byok-required'))),
      );
    });
  });

  group('AiService model list and test probe', () {
    test('lists BYOK models from /models with the typed key', () async {
      final ai = AiService();
      final adapter = _RecordingAdapter((options) {
        expect(options.path, 'https://typed.example.com/v1/models');
        expect(options.headers['Authorization'], 'Bearer typed-key');
        return ResponseBody.fromString(
          json.encode({
            'data': [
              {'id': 'b-model'},
              {'id': 'a-model'}
            ]
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
      ai.dioForTesting.httpClientAdapter = adapter;

      final models = await ai.listModels(
          baseUrl: 'https://typed.example.com/v1', apiKey: 'typed-key');

      expect(models, ['a-model', 'b-model']);
    });

    test('the test probe posts one tiny chat request as typed', () async {
      final ai = AiService();
      final adapter = _RecordingAdapter((options) {
        final body =
            json.decode(options.data as String) as Map<String, dynamic>;
        expect(body['model'], 'typed-model');
        expect(body['max_tokens'], 16);
        return ResponseBody.fromString(json.encode({'choices': []}), 200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            });
      });
      ai.dioForTesting.httpClientAdapter = adapter;

      await ai.testConnection(
          baseUrl: 'https://typed.example.com/v1',
          apiKey: 'k',
          model: 'typed-model');

      expect(adapter.requests.single.path,
          'https://typed.example.com/v1/chat/completions');
    });

    test('a refused probe throws ai-test-failed', () async {
      final ai = AiService();
      ai.dioForTesting.httpClientAdapter =
          _RecordingAdapter((_) => ResponseBody.fromString('denied', 401));

      await expectLater(
        ai.testConnection(
            baseUrl: 'https://x.example.com/v1', apiKey: 'k', model: 'm'),
        throwsA(predicate((e) => e.toString().contains('ai-test-failed'))),
      );
    });
  });

  group('AiService tool-use agent', () {
    late McpTool echoTool;
    late List<Map<String, dynamic>> echoArgs;

    setUp(() {
      echoArgs = [];
      echoTool = McpTool(
        name: 'echo',
        description: 'echoes text',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'}
          },
          'required': ['text'],
        },
        handler: (args) async {
          echoArgs.add(args);
          return 'echoed:${args['text']}';
        },
      );
    });

    test('BYOK: a tool call runs, its result is fed back, answer returns',
        () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      ai.toolsForTesting = [echoTool];
      await ai.init();
      ai.clearHistory();

      var call = 0;
      final adapter = _RecordingAdapter((options) {
        call++;
        if (call == 1) {
          // First turn: ask to call the tool.
          return jsonBody({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'c1',
                      'type': 'function',
                      'function': {
                        'name': 'echo',
                        'arguments': '{"text":"hi"}',
                      },
                    }
                  ],
                }
              }
            ]
          });
        }
        // Second turn: the tool result must be present, then answer.
        final body = json.decode(options.data as String) as Map<String, dynamic>;
        final msgs = body['messages'] as List;
        expect(
            msgs.any((m) => m['role'] == 'tool' && m['content'] == 'echoed:hi'),
            true);
        return jsonBody({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'done: hi'}
            }
          ]
        });
      });
      ai.dioForTesting.httpClientAdapter = adapter;

      var updates = 0;
      final reply = await ai.sendMessage('echo hi', onUpdate: () => updates++);

      expect(reply, 'done: hi');
      expect(echoArgs.single['text'], 'hi');
      expect(adapter.requests, hasLength(2));
      expect(updates, greaterThan(0));
      // The transcript carries a tool note.
      expect(ai.conversationHistory.any((m) => m.role == 'tool'), true);
    });

    test('BYOK: an SSE stream assembles text deltas into the reply', () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      ai.toolsForTesting = [];
      await ai.init();
      ai.clearHistory();

      const sse = 'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"lo!"}}]}\n\n'
          'data: {"usage":{"total_tokens":42},"choices":[]}\n\n'
          'data: [DONE]\n\n';
      ai.dioForTesting.httpClientAdapter = _RecordingAdapter((options) {
        // The request opts into streaming…
        final body =
            json.decode(options.data as String) as Map<String, dynamic>;
        expect(body['stream'], true);
        return ResponseBody.fromString(sse, 200, headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        });
      });

      expect(await ai.sendMessage('hi'), 'Hello!');
    });

    test('BYOK: streamed tool_call fragments reassemble and execute',
        () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      ai.toolsForTesting = [echoTool];
      await ai.init();
      ai.clearHistory();

      var call = 0;
      ai.dioForTesting.httpClientAdapter = _RecordingAdapter((options) {
        call++;
        if (call == 1) {
          // The name arrives whole, the arguments split across two deltas —
          // exactly how providers stream function calls.
          const sse =
              'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"echo","arguments":"{\\"te"}}]}}]}\n\n'
              'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"xt\\":\\"hi\\"}"}}]}}]}\n\n'
              'data: [DONE]\n\n';
          return ResponseBody.fromString(sse, 200, headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          });
        }
        // Round two must carry the executed tool result back.
        final body =
            json.decode(options.data as String) as Map<String, dynamic>;
        final msgs = body['messages'] as List;
        expect(
            msgs.any((m) => m['role'] == 'tool' && m['content'] == 'echoed:hi'),
            true);
        return ResponseBody.fromString(
            'data: {"choices":[{"delta":{"content":"done"}}]}\n\ndata: [DONE]\n\n',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            });
      });

      expect(await ai.sendMessage('echo hi'), 'done');
      expect(echoArgs.single['text'], 'hi');
    });

    test('cancel stops the loop: no further request, transcript kept',
        () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      ai.clearHistory();

      final signal = CancelSignal();
      ai.toolsForTesting = [
        McpTool(
          name: 'echo',
          description: 'echoes',
          inputSchema: const {'type': 'object', 'properties': {}},
          handler: (_) async {
            // The user presses Cancel while a tool is running: the loop must
            // stop before the next provider request fires.
            signal.cancel();
            return 'done anyway';
          },
        )
      ];
      await ai.init();

      final adapter = _RecordingAdapter((_) => ResponseBody.fromString(
            json.encode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'c1',
                        'type': 'function',
                        'function': {'name': 'echo', 'arguments': '{}'},
                      }
                    ],
                  }
                }
              ]
            }),
            200,
            headers: {
              Headers.contentTypeHeader: [Headers.jsonContentType],
            },
          ));
      ai.dioForTesting.httpClientAdapter = adapter;

      await expectLater(
          ai.sendMessage('go', cancel: signal), throwsA(isA<CancelledException>()));

      // Exactly one request — the loop never came back for round two.
      expect(adapter.requests, hasLength(1));
      // What ran, ran: the user turn and the tool note survive the cancel.
      expect(ai.conversationHistory.any((m) => m.role == 'user'), true);
      expect(ai.conversationHistory.any((m) => m.role == 'tool'), true);
    });

    test('capTranscript keeps only the newest turns within both budgets', () {
      final msgs = [
        for (var i = 0; i < 100; i++)
          AiMessage(
              role: i.isEven ? 'user' : 'assistant',
              content: 'message $i',
              timestamp: DateTime.now()),
        // Tool notes never go over the wire at all.
        AiMessage(role: 'tool', content: 'wsl_run_command', timestamp: DateTime.now()),
      ];
      final capped = AiService.capTranscript(msgs);
      expect(capped.length, 30);
      expect(capped.last.content, 'message 99');
      expect(capped.first.content, 'message 70');
      expect(capped.any((m) => m.role == 'tool'), false);

      // One enormous old message cannot smuggle the char budget away from
      // the recent turns — the newest message always survives.
      final huge = [
        AiMessage(
            role: 'user', content: 'x' * 100000, timestamp: DateTime.now()),
        AiMessage(role: 'assistant', content: 'small', timestamp: DateTime.now()),
      ];
      final cappedHuge = AiService.capTranscript(huge);
      expect(cappedHuge.last.content, 'small');
      expect(cappedHuge.length, 1);
    });

    test('with no tools it still answers in one turn', () async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      ai.toolsForTesting = [];
      await ai.init();
      ai.clearHistory();

      ai.dioForTesting.httpClientAdapter = _RecordingAdapter((_) => jsonBody({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'plain answer'}
              }
            ]
          }));

      expect(await ai.sendMessage('hi'), 'plain answer');
    });
  });
  group('AiService records instance-changing runs as a snippet', () {
    McpTool fakeTool(String name, {ToolRecording? recording}) => McpTool(
          name: name,
          description: name,
          inputSchema: const {'type': 'object', 'properties': {}},
          handler: (args) async => 'ok from $name',
          recording: recording,
        );

    Map<String, dynamic> toolCallTurn(List<Map<String, String>> calls) => {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': null,
                'tool_calls': [
                  for (var i = 0; i < calls.length; i++)
                    {
                      'id': 'c$i',
                      'type': 'function',
                      'function': {
                        'name': calls[i]['name'],
                        'arguments': calls[i]['args'],
                      },
                    }
                ],
              }
            }
          ]
        };

    Future<AiService> proService(List<McpTool> tools) async {
      final ai = AiService();
      LicenseManager.storeInstallCheckOverride = () => true;
      await LicenseManager().init();
      ai.setByokApiKey('sk-test');
      ai.toolsForTesting = tools;
      await ai.init();
      ai.clearHistory();
      return ai;
    }

    test(
        'a run that created and set up an instance is filed as a snippet '
        'and noted in the transcript', () async {
      final ai = await proService([
        fakeTool('wsl_list_distros'),
        fakeTool('vm_create_linux',
            recording: const ToolRecording(target: 'name')),
        fakeTool('wsl_run_command',
            recording: const ToolRecording(target: 'distro', shell: 'command')),
      ]);

      var call = 0;
      final adapter = _RecordingAdapter((options) {
        call++;
        if (call == 1) {
          return jsonBody(toolCallTurn([
            {'name': 'wsl_list_distros', 'args': '{}'},
            {'name': 'vm_create_linux', 'args': '{"name":"dev","cpus":2}'},
            {
              'name': 'wsl_run_command',
              'args': '{"distro":"dev","command":"apt-get install -y nginx"}'
            },
          ]));
        }
        // The note is UI-only: the second request must not carry it.
        final body =
            json.decode(options.data as String) as Map<String, dynamic>;
        final roles = (body['messages'] as List).map((m) => m['role']);
        expect(roles, isNot(contains('snippet')));
        return jsonBody({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'dev is ready'}
            }
          ]
        });
      });
      ai.dioForTesting.httpClientAdapter = adapter;

      final reply = await ai.sendMessage('set up a dev VM with nginx');
      expect(reply, 'dev is ready');

      final snippets = QuickAction().getFromPrefs();
      expect(snippets, hasLength(1));
      final snippet = snippets.single;
      expect(snippet.name, startsWith('ai-run-dev-'));
      expect(snippet.description, 'set up a dev VM with nginx');
      expect(snippet.content, contains('vm_create_linux name="dev" cpus=2'));
      expect(snippet.content, contains('#    ok from vm_create_linux'));
      expect(snippet.content.split('\n'), contains('apt-get install -y nginx'));
      // The read-only call is not part of the record.
      expect(snippet.content, isNot(contains('wsl_list_distros')));

      final roles = ai.conversationHistory.map((m) => m.role).toList();
      expect(roles, [
        'user',
        'tool',
        'tool',
        'tool',
        'snippet',
        'assistant',
      ]);
      expect(ai.conversationHistory[4].content, snippet.name);

      // And it survives a restart: the note is in the stored transcript.
      final other = AiService();
      await other.init();
      expect(other.conversationHistory.any((m) => m.role == 'snippet'), true);
    });

    test('a run that failed after changing the machine still leaves the '
        'snippet, even though its transcript notes are rolled back', () async {
      final ai = await proService([
        fakeTool('vm_create_linux',
            recording: const ToolRecording(target: 'name'))
      ]);
      var call = 0;
      ai.dioForTesting.httpClientAdapter = _RecordingAdapter((options) {
        call++;
        if (call == 1) {
          return jsonBody(toolCallTurn([
            {'name': 'vm_create_linux', 'args': '{"name":"dev"}'},
          ]));
        }
        return ResponseBody.fromString('upstream down', 502);
      });

      await expectLater(
        ai.sendMessage('create dev'),
        throwsA(predicate((e) => e.toString().contains('byok-request-failed'))),
      );

      // The VM was created, and the record says so.
      final snippets = QuickAction().getFromPrefs();
      expect(snippets, hasLength(1));
      expect(snippets.single.content, contains('vm_create_linux name="dev"'));
      // The rollback that clears a failed run's notes stops at the snippet
      // link: with no reply describing what happened, that link is what the
      // user has. Only user/assistant turns reach the provider, so a retry
      // is unaffected.
      expect(ai.conversationHistory.map((m) => m.role).toList(),
          ['user', 'tool', 'snippet']);
    });

    test('a run that only looked around files nothing', () async {
      final ai = await proService([fakeTool('wsl_list_distros')]);
      var call = 0;
      ai.dioForTesting.httpClientAdapter = _RecordingAdapter((options) {
        call++;
        if (call == 1) {
          return jsonBody(toolCallTurn([
            {'name': 'wsl_list_distros', 'args': '{}'},
          ]));
        }
        return jsonBody({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'two distros'}
            }
          ]
        });
      });

      await ai.sendMessage('what do I have?');

      expect(QuickAction().getFromPrefs(), isEmpty);
      expect(ai.conversationHistory.any((m) => m.role == 'snippet'), false);
    });

    test('a caller that opts out — the sandbox chat — files nothing', () async {
      final ai = await proService([]);
      final create = fakeTool('vm_create_linux',
          recording: const ToolRecording(target: 'name'));
      var call = 0;
      ai.dioForTesting.httpClientAdapter = _RecordingAdapter((options) {
        call++;
        if (call == 1) {
          return jsonBody(toolCallTurn([
            {'name': 'vm_create_linux', 'args': '{"name":"dev"}'},
          ]));
        }
        return jsonBody({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'made'}
            }
          ]
        });
      });

      final transcript = [
        AiMessage(role: 'user', content: 'make dev', timestamp: DateTime.now())
      ];
      final reply = await ai.runAgentOn(transcript, [create], recordRun: false);

      expect(reply, 'made');
      expect(QuickAction().getFromPrefs(), isEmpty);
      expect(transcript.map((m) => m.role).toList(), ['user', 'tool']);
    });

    group('one chat session keeps one snippet', () {
      final runCommand = fakeTool('wsl_run_command',
          recording: const ToolRecording(target: 'distro', shell: 'command'));

      /// Answers each turn with one tool-call response running [commands]
      /// (as `distro`/`command` pairs), then a plain reply.
      void script(AiService ai, List<List<List<String>>> turns) {
        final bodies = <Map<String, dynamic>>[];
        for (final turn in turns) {
          bodies.add(toolCallTurn([
            for (final c in turn)
              {
                'name': 'wsl_run_command',
                'args': json.encode({'distro': c[0], 'command': c[1]}),
              }
          ]));
          bodies.add({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'done'}
              }
            ]
          });
        }
        var i = 0;
        ai.dioForTesting.httpClientAdapter =
            _RecordingAdapter((_) => jsonBody(bodies[i++]));
      }

      List<String> commandLines(String content) => content
          .split('\n')
          .where((l) => l.startsWith('echo '))
          .toList();

      setUp(() => AiChatSessions.instance.clear());

      test('several turns and tool calls in one chat file one snippet with '
          'every command in order', () async {
        final ai = await proService([runCommand]);
        script(ai, [
          [
            ['dev', 'echo one'],
            ['dev', 'echo two'],
          ],
          [
            ['dev', 'echo three'],
          ],
          [
            ['web', 'echo four'],
          ],
        ]);

        await ai.sendMessage('first');
        await ai.sendMessage('second');
        await ai.sendMessage('third');

        final snippets = QuickAction().getFromPrefs();
        expect(snippets, hasLength(1));
        final snippet = snippets.single;
        expect(commandLines(snippet.content),
            ['echo one', 'echo two', 'echo three', 'echo four']);
        // The first turn names and describes it; each instance the session
        // touched is listed, and each follow-up says where it ran.
        expect(snippet.description, 'first');
        expect(snippet.name, startsWith('ai-run-dev-'));
        expect(snippet.distro, ['dev', 'web']);
        expect(snippet.content, contains('# Request: second'));
        expect(snippet.content, contains('# Request: third\n# Instances: web'));
        expect('#!/bin/bash'.allMatches(snippet.content), hasLength(1));
        // Every turn still links to it.
        final notes = ai.conversationHistory
            .where((m) => m.role == 'snippet')
            .map((m) => m.content)
            .toList();
        expect(notes, [snippet.name, snippet.name, snippet.name]);
      });

      test('a new chat starts a second snippet', () async {
        final ai = await proService([runCommand]);
        script(ai, [
          [
            ['dev', 'echo one'],
          ],
          [
            ['dev', 'echo two'],
          ],
        ]);

        await ai.sendMessage('first chat');
        // What "New chat" does: file the transcript, then clear it.
        AiChatSessions.instance.archive(ai.conversationHistory);
        ai.clearHistory();
        await ai.sendMessage('second chat');

        final snippets = QuickAction().getFromPrefs();
        expect(snippets, hasLength(2));
        expect(snippets.map((s) => s.description),
            ['first chat', 'second chat']);
        expect(commandLines(snippets[0].content), ['echo one']);
        expect(commandLines(snippets[1].content), ['echo two']);
      });

      test('a chat reopened from history appends to its own snippet',
          () async {
        final ai = await proService([runCommand]);
        script(ai, [
          [
            ['dev', 'echo one'],
          ],
          [
            ['web', 'echo two'],
          ],
          [
            ['dev', 'echo three'],
          ],
        ]);

        await ai.sendMessage('first chat');
        AiChatSessions.instance.archive(ai.conversationHistory);
        ai.clearHistory();
        await ai.sendMessage('second chat');

        // Reopen the first chat, as the history flyout does.
        final firstId = AiChatSessions.instance
            .list()
            .singleWhere((s) => s.title == 'first chat')
            .id;
        final restored = AiChatSessions.instance
            .switchTo(firstId, ai.conversationHistory)!;
        ai.restoreHistory(restored);
        await ai.sendMessage('back to the first');

        final snippets = QuickAction().getFromPrefs();
        expect(snippets, hasLength(2));
        final first = snippets.singleWhere((s) => s.description == 'first chat');
        final second =
            snippets.singleWhere((s) => s.description == 'second chat');
        expect(commandLines(first.content), ['echo one', 'echo three']);
        expect(commandLines(second.content), ['echo two']);
      });

      test('a session whose snippet was deleted starts a new one', () async {
        final ai = await proService([runCommand]);
        script(ai, [
          [
            ['dev', 'echo one'],
          ],
          [
            ['dev', 'echo two'],
          ],
        ]);

        await ai.sendMessage('first');
        QuickAction.removeFromPrefs(QuickAction().getFromPrefs().single);
        await ai.sendMessage('second');

        final snippets = QuickAction().getFromPrefs();
        expect(snippets, hasLength(1));
        expect(snippets.single.description, 'second');
        expect(commandLines(snippets.single.content), ['echo two']);
      });
    });
  });
}
