import 'dart:convert';
import 'dart:io' show Process, ProcessResult, ProcessStartMode;

import 'package:flutter_test/flutter_test.dart';
import 'package:localization/localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/runtime.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/ai_workspace/shared_settings.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'mocks.dart';

/// Answers per command, like the config service test's shell: an apply reads
/// one tool's file, patches another and runs a third's CLI, and each has to
/// be told apart.
class _ScriptedShell extends TestShell {
  final List<MapEntry<String, String>> responses = [];
  final Map<String, String> failures = {};
  final List<String> scripts = [];

  String _answer(List<String> arguments) {
    final line = arguments.join(' ');
    if (arguments.contains('--list')) return 'ai-workspace\n';
    scripts.add(line);
    for (final entry in responses) {
      if (line.contains(entry.key)) return entry.value;
    }
    return '';
  }

  String? _failure(List<String> arguments) {
    final line = arguments.join(' ');
    for (final entry in failures.entries) {
      if (line.contains(entry.key)) return entry.value;
    }
    return null;
  }

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      Encoding? stdoutEncoding,
      Encoding? stderrEncoding}) async {
    final stdout = _answer(arguments);
    final failure = _failure(arguments);
    return ProcessResult(-1, failure == null ? 0 : 1, utf8.encode(stdout),
        utf8.encode(failure ?? ''));
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    ProcessStartMode mode = ProcessStartMode.inheritStdio,
    bool runInShell = false,
  }) async {
    final stdout = _answer(arguments);
    final failure = _failure(arguments);
    return MockProcess(
      exitCode: failure == null ? 0 : 1,
      stdout: stdout,
      stderr: failure ?? '',
    );
  }

  String scriptContaining(String needle) =>
      scripts.firstWhere((script) => script.contains(needle), orElse: () => '');

  /// The JSON a `printf … | base64 -d` pipeline carries into the workspace.
  Map<String, dynamic> decodedPayload(String needle) {
    final script = scriptContaining(needle);
    final match = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'").firstMatch(script);
    if (match == null) return const {};
    return jsonDecode(utf8.decode(base64.decode(match.group(1)!)))
        as Map<String, dynamic>;
  }
}

const _settings = AiWorkspaceSharedSettings(
  endpoint: 'https://llm.example.com/v1',
  model: 'gpt-4.1',
  apiKey: 'sk-test-123',
);

void main() {
  late _ScriptedShell shell;
  late AiWorkspaceService workspace;
  late AiWorkspaceConfigService config;
  late AiWorkspaceSharedSettingsService service;
  late List<String> messages;

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      messages.add('${severity.name}: $msg');
    };
  });

  setUp(() async {
    messages = [];
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    // The first-start AI question is answered with a yes here: these tests
    // are about what happens once the features are on (bostrot/ai-tasks#98).
    AiService.setFeaturesEnabled(true);
    workspaceRuntimeBuilder = WslWorkspaceRuntime.new;
    shell = _ScriptedShell();
    workspace = AiWorkspaceService(broker: ExecutionBroker(shell: shell));
    config = AiWorkspaceConfigService(
      workspace: workspace,
      fetchSchema: (url) async => throw Exception('no network in tests'),
    );
    service =
        AiWorkspaceSharedSettingsService(workspace: workspace, config: config);
  });

  tearDown(() {
    workspaceRuntimeBuilder = defaultWorkspaceRuntime;
  });

  void install(AiWorkspaceTool tool, [ToolStatus status = ToolStatus.stopped]) {
    if (workspace.toolStates.isEmpty) workspace.seedToolStates();
    workspace.getState(tool)!.status = status;
  }

  /// Puts [_settings] where the assistant keeps its own: the "Bring Your Own
  /// AI Key" fields in Settings. There is no other store.
  void configureAssistant() {
    AiService()
      ..setByokBaseUrl(_settings.endpoint)
      ..setByokModel(_settings.model)
      ..setByokApiKey(_settings.apiKey);
  }

  group('settings', () {
    test('a value with a quote or whitespace cannot reach a shell line', () {
      expect(isShellSafeValue('https://x.example/v1'), isTrue);
      expect(isShellSafeValue('sk-abc_DEF-123'), isTrue);
      expect(isShellSafeValue(r"it's"), isFalse);
      expect(isShellSafeValue('a b'), isFalse);
      expect(isShellSafeValue('a\tb'), isFalse);
      expect(isShellSafeValue('"quoted"'), isFalse);
      expect(isShellSafeValue('back\\slash'), isFalse);
    });

    test('endpoint and model are required, the key is not', () {
      expect(const AiWorkspaceSharedSettings().problemKey,
          'ai-workspace-shared-required-text');
      expect(const AiWorkspaceSharedSettings(endpoint: 'https://x').problemKey,
          'ai-workspace-shared-required-text');
      expect(
          const AiWorkspaceSharedSettings(endpoint: 'https://x', model: 'm')
              .problemKey,
          isNull);
      expect(
          const AiWorkspaceSharedSettings(
                  endpoint: 'https://x', model: 'm', apiKey: "it's")
              .problemKey,
          'ai-workspace-shared-invalid-text');
    });

    test('every tool has a binding, so none is silently ignored', () {
      for (final tool in AiWorkspaceTool.values) {
        expect(service.supports(tool), tool != AiWorkspaceTool.openWebUi,
            reason: tool.name);
      }
    });

    test("reads the assistant's own settings, its defaults included", () {
      var current = service.current();
      expect(current.endpoint, AiService.defaultByokBaseUrl);
      expect(current.model, AiService.defaultByokModel);
      expect(current.apiKey, '');
      expect(current.isConfigured, isFalse, reason: 'nothing set yet');

      AiService()
        ..setByokApiKey('sk-byok')
        ..setByokModel('gpt-4.1');
      current = service.current();
      expect(current.apiKey, 'sk-byok');
      expect(current.model, 'gpt-4.1');
      expect(current.endpoint, AiService.defaultByokBaseUrl,
          reason: 'the assistant asks OpenAI when no endpoint is stored');
      expect(current.isConfigured, isTrue);
    });

    test('a keyless local endpoint is set up; the bare default is not', () {
      expect(
          const AiWorkspaceSharedSettings(
                  endpoint: AiService.defaultByokBaseUrl, model: 'gpt-4.1')
              .isConfigured,
          isFalse);
      expect(
          const AiWorkspaceSharedSettings(
                  endpoint: 'http://ollama.lan:11434/v1', model: 'llama3')
              .isConfigured,
          isTrue);
    });
  });

  group('apply', () {
    test('writes an OpenCode provider block and picks it as the model',
        () async {
      shell.responses.add(MapEntry(
          'opencode.jsonc',
          'AIWS_CONFIG_PATH:\$HOME/.config/opencode/opencode.jsonc\n'
              '{"theme": "dark", "provider": {"other": {"npm": "x"}}}\n'));
      install(AiWorkspaceTool.openCode);

      final result = await service.applyTo(AiWorkspaceTool.openCode, _settings);

      expect(result.outcome, SharedSettingsOutcome.applied,
          reason: result.error);
      final written = shell.decodedPayload('opencode.jsonc.aiws-new');
      expect(written['theme'], 'dark', reason: 'unrelated keys survive');
      final providers = written['provider'] as Map<String, dynamic>;
      expect(providers['other'], {'npm': 'x'},
          reason: 'other providers survive');
      final shared = providers[kSharedProviderId] as Map<String, dynamic>;
      expect(shared['npm'], '@ai-sdk/openai-compatible');
      expect(shared['options'],
          {'baseURL': _settings.endpoint, 'apiKey': _settings.apiKey});
      // A model id with a dot in it is a key of the models map, not a path.
      expect(shared['models'], {
        'gpt-4.1': {'name': 'gpt-4.1'}
      });
      expect(written['model'], '$kSharedProviderId/gpt-4.1');
    });

    test('creates the OpenCode file when the tool has none yet', () async {
      install(AiWorkspaceTool.openCode);

      final result = await service.applyTo(AiWorkspaceTool.openCode, _settings);

      expect(result.outcome, SharedSettingsOutcome.applied,
          reason: result.error);
      final written = shell.decodedPayload('opencode.jsonc.aiws-new');
      expect(written['model'], '$kSharedProviderId/gpt-4.1');
      expect(shell.scriptContaining('opencode.jsonc.aiws-new'),
          contains('mkdir -p'));
    });

    test('hands OpenClaw a provider and a default through its patch command',
        () async {
      install(AiWorkspaceTool.openClaw);
      // No schema pull for a values-only read: the schema command would
      // otherwise be the first thing the apply waits on.
      shell.responses.add(const MapEntry('config schema', 'not-json'));

      final result = await service.applyTo(AiWorkspaceTool.openClaw, _settings);

      expect(result.outcome, SharedSettingsOutcome.applied,
          reason: result.error);
      final patch = shell.decodedPayload('openclaw config patch --stdin');
      final provider = ((patch['models'] as Map)['providers']
          as Map)[kSharedProviderId] as Map<String, dynamic>;
      expect(provider['baseUrl'], _settings.endpoint);
      expect(provider['apiKey'], _settings.apiKey);
      expect(provider['api'], 'openai-completions');
      final models = provider['models'] as List;
      expect(models, hasLength(1));
      expect((models.single as Map)['id'], 'gpt-4.1');
      expect(
          (((patch['agents'] as Map)['defaults'] as Map)['model']
              as Map)['primary'],
          '$kSharedProviderId/gpt-4.1');
      expect(shell.scriptContaining('config schema'), isEmpty);
    });

    // `openclaw config patch` replaces arrays and refuses to shorten the
    // protected `models.providers.<id>.models` list, so a second apply with
    // another model has to send the old entries along.
    test('a second OpenClaw apply keeps the models already listed', () async {
      shell.responses.add(MapEntry(
          'openclaw.json',
          'AIWS_CONFIG_PATH:\$HOME/.openclaw/openclaw.json\n'
              '{"models": {"providers": {"$kSharedProviderId": {"apiKey": "old",'
              ' "models": [{"id": "gpt-4.1", "name": "gpt-4.1"},'
              ' {"id": "o3", "name": "o3"}]}}}}\n'));
      install(AiWorkspaceTool.openClaw);

      final result = await service.applyTo(
          AiWorkspaceTool.openClaw,
          const AiWorkspaceSharedSettings(
              endpoint: 'https://llm.example.com/v1', model: 'gpt-4.1'));

      expect(result.outcome, SharedSettingsOutcome.applied,
          reason: result.error);
      final patch = shell.decodedPayload('openclaw config patch --stdin');
      final provider = ((patch['models'] as Map)['providers']
          as Map)[kSharedProviderId] as Map<String, dynamic>;
      final ids = (provider['models'] as List).map((m) => (m as Map)['id']);
      expect(ids, ['o3', 'gpt-4.1']);
      expect(provider.containsKey('apiKey'), isFalse,
          reason: 'the key read back is a redaction, never re-sent');
    });

    test('configures Hermes through its own CLI, quoting every value',
        () async {
      install(AiWorkspaceTool.hermesAgent);

      final result =
          await service.applyTo(AiWorkspaceTool.hermesAgent, _settings);

      expect(result.outcome, SharedSettingsOutcome.applied,
          reason: result.error);
      final script = shell.scriptContaining('hermes config set');
      expect(script, contains('hermes config set model.provider custom'));
      expect(script,
          contains("hermes config set model.base_url '${_settings.endpoint}'"));
      expect(script, contains("hermes config set model.default 'gpt-4.1'"));
      expect(script,
          contains("hermes config set model.api_key '${_settings.apiKey}'"));
      expect(script, isNot(contains('OPENAI_')),
          reason: 'the custom provider reads model.*, not the openai-api env');
      expect(script, isNot(contains('"')),
          reason: 'a double quote reaches bash literally on Windows');
    });

    test('an empty key leaves the key a tool already holds alone', () async {
      install(AiWorkspaceTool.openClaw);
      install(AiWorkspaceTool.hermesAgent);
      const withoutKey = AiWorkspaceSharedSettings(
          endpoint: 'https://llm.example.com/v1', model: 'gpt-4.1');

      await service.applyTo(AiWorkspaceTool.openClaw, withoutKey);
      await service.applyTo(AiWorkspaceTool.hermesAgent, withoutKey);

      final patch = shell.decodedPayload('openclaw config patch --stdin');
      final provider = ((patch['models'] as Map)['providers']
          as Map)[kSharedProviderId] as Map<String, dynamic>;
      expect(provider.containsKey('apiKey'), isFalse);
      expect(shell.scriptContaining('hermes config set'),
          isNot(contains('api_key')));
    });

    test('Open WebUI is skipped with a reason rather than attempted', () async {
      install(AiWorkspaceTool.openWebUi, ToolStatus.running);

      final result =
          await service.applyTo(AiWorkspaceTool.openWebUi, _settings);

      expect(result.outcome, SharedSettingsOutcome.skipped);
      expect(result.reasonKey, 'ai-workspace-shared-openwebui-text');
      expect(shell.scripts, isEmpty);
    });

    test('refuses incomplete settings and values that cannot be quoted',
        () async {
      install(AiWorkspaceTool.openClaw);

      final incomplete = await service.applyTo(AiWorkspaceTool.openClaw,
          const AiWorkspaceSharedSettings(endpoint: 'https://x'));
      expect(incomplete.outcome, SharedSettingsOutcome.failed);

      final unsafe = await service.applyTo(
          AiWorkspaceTool.openClaw,
          const AiWorkspaceSharedSettings(
              endpoint: 'https://llm.example.com/v1', model: "gpt'; rm -rf"));
      expect(unsafe.outcome, SharedSettingsOutcome.failed);
      expect(shell.scripts, isEmpty);
    });

    test(
        'a tool that refuses the write reports what it said, and only it fails',
        () async {
      shell.failures['openclaw config patch'] = 'invalid config: nope';
      install(AiWorkspaceTool.openClaw);
      install(AiWorkspaceTool.hermesAgent);
      install(AiWorkspaceTool.openWebUi, ToolStatus.running);

      final results = await service.applyToAll(_settings);

      expect(results.map((r) => r.tool), [
        AiWorkspaceTool.hermesAgent,
        AiWorkspaceTool.openClaw,
        AiWorkspaceTool.openWebUi,
      ]);
      expect(results[0].outcome, SharedSettingsOutcome.applied);
      expect(results[1].outcome, SharedSettingsOutcome.failed);
      expect(results[1].error, contains('invalid config: nope'));
      expect(results[2].outcome, SharedSettingsOutcome.skipped);
    });

    test('only installed tools are touched', () async {
      install(AiWorkspaceTool.openClaw);
      workspace.getState(AiWorkspaceTool.openCode)!.status = ToolStatus.error;

      final results = await service.applyToAll(_settings);

      expect(results.map((r) => r.tool), [AiWorkspaceTool.openClaw]);
      expect(shell.scriptContaining('opencode'), isEmpty);
    });

    test('nothing installed applies nothing and says so', () async {
      final results = await service.applyToAll(_settings);
      expect(results, isEmpty);
      expect(shell.scripts, isEmpty);
    });
  });

  // Saving the assistant's settings pushes them into the tools. This is the
  // call Settings makes; it has only the notification bar to report by.
  group('applyCurrentAndNotify', () {
    test('writes the assistant settings into every installed tool and says so',
        () async {
      configureAssistant();
      install(AiWorkspaceTool.hermesAgent);
      install(AiWorkspaceTool.openWebUi, ToolStatus.running);

      final results = await service.applyCurrentAndNotify();

      expect(results.map((r) => r.outcome),
          [SharedSettingsOutcome.applied, SharedSettingsOutcome.skipped]);
      expect(shell.scriptContaining('hermes config set'),
          contains("model.api_key '${_settings.apiKey}'"));
      expect(messages,
          ['success: ${'ai-workspace-shared-tools-updated-text'.i18n()}']);
    });

    test('a tool that refuses is named in an error, with no success line',
        () async {
      shell.failures['hermes config set'] = 'no such key';
      configureAssistant();
      install(AiWorkspaceTool.hermesAgent);

      await service.applyCurrentAndNotify();

      expect(messages,
          ['error: ${'ai-workspace-shared-auto-failed-text'.i18n(['', ''])}']);
    });

    test('an assistant that is not set up writes nothing', () async {
      install(AiWorkspaceTool.hermesAgent);

      final results = await service.applyCurrentAndNotify();

      expect(results, isEmpty);
      expect(shell.scripts, isEmpty);
      expect(messages, isEmpty);
    });

    test('AI switched off writes nothing either, even with tools installed',
        () async {
      // Save is the one path that reaches the workspace distro without the
      // AI Workspace page; with the switch off it must not provision or
      // write into anything (bostrot/ai-tasks#85).
      AiService.setFeaturesEnabled(false);
      addTearDown(() => AiService.setFeaturesEnabled(true));
      configureAssistant();
      install(AiWorkspaceTool.hermesAgent);

      final results = await service.applyCurrentAndNotify();

      expect(results, isEmpty);
      expect(shell.scripts, isEmpty);
      expect(messages, isEmpty);
    });
  });

  // "Set it once": a tool installed after the assistant was set up is pointed
  // at its endpoint by the install itself, before it reports done.
  group('after install', () {
    test('an installed tool is configured before the install returns',
        () async {
      configureAssistant();
      service.attach();
      workspace.seedToolStates();

      expect(await workspace.install(AiWorkspaceTool.hermesAgent), isTrue);

      final script = shell.scriptContaining('hermes config set');
      expect(script, contains("model.base_url '${_settings.endpoint}'"));
      expect(script, contains("model.default 'gpt-4.1'"));
      expect(
          messages.last,
          'success: ${'ai-workspace-shared-auto-applied-text'.i18n([
                'Hermes Agent'
              ])}');
    });

    test('a refused apply is reported as an error and the install still counts',
        () async {
      shell.failures['hermes config set'] = 'no such key';
      configureAssistant();
      service.attach();
      workspace.seedToolStates();

      expect(await workspace.install(AiWorkspaceTool.hermesAgent), isTrue);

      expect(workspace.getState(AiWorkspaceTool.hermesAgent)?.status,
          ToolStatus.stopped);
      // Translations are not loaded under test, so the key is all `.i18n`
      // gives back; the severity is the thing being asserted here.
      expect(messages.last,
          'error: ${'ai-workspace-shared-auto-failed-text'.i18n(['', ''])}');
    });

    test('an assistant that is not set up leaves an install alone', () async {
      service.attach();
      workspace.seedToolStates();

      expect(await workspace.install(AiWorkspaceTool.hermesAgent), isTrue);

      expect(shell.scriptContaining('hermes config set'), isEmpty);
    });

    test('a tool this cannot configure is installed without a word', () async {
      configureAssistant();
      service.attach();
      workspace.seedToolStates();
      shell.responses.add(const MapEntry('docker', 'running'));

      await workspace.install(AiWorkspaceTool.openWebUi);

      expect(
          messages.where((m) => m.contains('ai-workspace-shared-')), isEmpty);
    });
  });
}
