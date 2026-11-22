import 'dart:convert';
import 'dart:io' show Process, ProcessResult, ProcessStartMode;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_schema.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/runtime.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

/// A shell that answers per command instead of handing the same canned
/// stdout to everything: reading a config, printing a schema and writing a
/// patch all run through the same broker, and a test that cannot tell them
/// apart cannot assert on any of them.
class _ScriptedShell extends TestShell {
  /// stdout by substring of the command line, first match wins.
  final List<MapEntry<String, String>> responses = [];

  /// Commands whose match should exit non-zero, by substring.
  final Map<String, String> failures = {};

  /// Every workspace command, in order.
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

  /// The script the workspace was asked to run that mentions [needle].
  String scriptContaining(String needle) =>
      scripts.firstWhere((script) => script.contains(needle),
          orElse: () => '');

  /// The JSON a `printf … | base64 -d` pipeline carries into the workspace.
  String decodedPayload(String needle) {
    final script = scriptContaining(needle);
    final match = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'").firstMatch(script);
    if (match == null) return '';
    return utf8.decode(base64.decode(match.group(1)!));
  }
}

const String _openClawSchema = '''
{
  "type": "object",
  "properties": {
    "gateway": {
      "type": "object",
      "title": "Gateway",
      "properties": {
        "port": {"type": "integer", "default": 18789},
        "mode": {
          "anyOf": [
            {"type": "string", "const": "local"},
            {"type": "string", "const": "remote"}
          ]
        },
        "auth": {
          "type": "object",
          "properties": {
            "mode": {"type": "string"},
            "token": {"type": "string"}
          }
        }
      }
    }
  }
}
''';

void main() {
  late _ScriptedShell shell;
  late AiWorkspaceService workspace;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    workspaceRuntimeBuilder = WslWorkspaceRuntime.new;
    shell = _ScriptedShell();
    workspace = AiWorkspaceService(broker: ExecutionBroker(shell: shell));
  });

  tearDown(() {
    workspaceRuntimeBuilder = defaultWorkspaceRuntime;
  });

  AiWorkspaceConfigService build({
    Map<AiWorkspaceTool, ToolConfigSpec>? specs,
    SchemaFetcher? fetchSchema,
  }) =>
      AiWorkspaceConfigService(
        workspace: workspace,
        specs: specs,
        fetchSchema: fetchSchema ??
            (url) async => throw Exception('no network in tests'),
      );

  group('schema pull', () {
    test('takes a published schema over HTTP', () async {
      var requested = '';
      final service = build(
        specs: const {
          AiWorkspaceTool.openCode: ToolConfigSpec(
            schemaUrl: 'https://opencode.ai/config.json',
            configPaths: [r'$HOME/.config/opencode/opencode.jsonc'],
          ),
        },
        fetchSchema: (url) async {
          requested = url;
          return '{"type":"object","properties":{"model":{"type":"string"}}}';
        },
      );

      await service.ensureSchemas();

      expect(requested, 'https://opencode.ai/config.json');
      expect(service.publishedSchema(AiWorkspaceTool.openCode)?.fieldAt('model'),
          isNotNull);
      expect(service.schemaError(AiWorkspaceTool.openCode), isNull);
    });

    test('takes a schema the tool prints inside the workspace', () async {
      shell.responses.add(MapEntry('openclaw config schema', _openClawSchema));
      final service = build(specs: const {
        AiWorkspaceTool.openClaw: ToolConfigSpec(
          schemaCommand: 'openclaw config schema',
          configPaths: [r'$HOME/.openclaw/openclaw.json'],
          writeMode: ConfigWriteMode.openClawPatch,
        ),
      });

      await service.ensureSchemas();

      final schema = service.publishedSchema(AiWorkspaceTool.openClaw);
      expect(schema?.fieldAt('gateway.mode')?.choices, ['local', 'remote']);
      expect(schema?.fieldAt('gateway.port')?.defaultValue, 18789);
    });

    test('skips the banner a CLI prints before its JSON', () async {
      shell.responses.add(MapEntry('openclaw config schema',
          'OpenClaw 2026.9.4 (3a9d69d)\n$_openClawSchema'));
      final service = build(specs: const {
        AiWorkspaceTool.openClaw:
            ToolConfigSpec(schemaCommand: 'openclaw config schema'),
      });

      await service.ensureSchemas();

      expect(service.publishedSchema(AiWorkspaceTool.openClaw), isNotNull);
    });

    test('records why a schema is missing without failing the pull', () async {
      shell.failures['openclaw config schema'] = 'command not found';
      final service = build(specs: const {
        AiWorkspaceTool.openClaw:
            ToolConfigSpec(schemaCommand: 'openclaw config schema'),
      });

      await service.ensureSchemas();

      expect(service.publishedSchema(AiWorkspaceTool.openClaw), isNull);
      expect(service.schemaError(AiWorkspaceTool.openClaw),
          contains('command not found'));
    });

    test('is pulled once per app start and again only on request', () async {
      var pulls = 0;
      final service = build(
        specs: const {
          AiWorkspaceTool.openCode: ToolConfigSpec(schemaUrl: 'https://x/y'),
        },
        fetchSchema: (_) async {
          pulls++;
          return '{"type":"object","properties":{}}';
        },
      );

      await service.ensureSchemas();
      await service.ensureSchemas();
      expect(pulls, 1);

      // A tool installed after startup had nothing to answer the first time.
      await service.refreshSchema(AiWorkspaceTool.openCode);
      expect(pulls, 2);
    });

    test('a tool installed after startup gets its schema on first open',
        () async {
      shell.failures['openclaw config schema'] = 'command not found';
      shell.responses.add(const MapEntry(
        'openclaw.json',
        'AIWS_CONFIG_PATH:/root/.openclaw/openclaw.json\n'
            '{"gateway": {"mode": "local"}}',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.openClaw: ToolConfigSpec(
          schemaCommand: 'openclaw config schema',
          configPaths: [r'$HOME/.openclaw/openclaw.json'],
          writeMode: ConfigWriteMode.openClawPatch,
        ),
      });

      // App start: nothing installed, nothing to describe itself.
      await service.ensureSchemas();
      expect(service.publishedSchema(AiWorkspaceTool.openClaw), isNull);

      // The user installs it, then opens the dialog.
      shell.failures.clear();
      shell.responses.add(MapEntry('openclaw config schema', _openClawSchema));
      final document = await service.load(AiWorkspaceTool.openClaw);

      expect(document.schemaFromTool, isTrue);
      expect(document.schema.fieldAt('gateway.mode')?.choices,
          ['local', 'remote']);
    });
  });

  group('load', () {
    ToolConfigSpec openCodeSpec() => const ToolConfigSpec(
          schemaUrl: 'https://opencode.ai/config.json',
          configPaths: [
            r'$HOME/.config/opencode/opencode.jsonc',
            r'$HOME/.config/opencode/opencode.json',
          ],
        );

    test('reads the file the environment reported and strips the marker',
        () async {
      shell.responses.add(const MapEntry(
        'opencode.jsonc',
        'AIWS_CONFIG_PATH:/root/.config/opencode/opencode.jsonc\n'
            '{ // comment\n "model": "anthropic/claude", "share": "manual" }',
      ));
      final service = build(
        specs: {AiWorkspaceTool.openCode: openCodeSpec()},
        fetchSchema: (_) async =>
            '{"type":"object","properties":{"model":{"type":"string"},'
            '"share":{"type":"string","enum":["manual","auto"]}}}',
      );
      await service.ensureSchemas();

      final document = await service.load(AiWorkspaceTool.openCode);

      expect(document.source, '/root/.config/opencode/opencode.jsonc');
      expect(document.values['model'], 'anthropic/claude');
      expect(document.schemaFromTool, isTrue);
      expect(document.missing, isFalse);
      expect(document.schema.fieldAt('share')?.kind, ConfigFieldKind.choice);
    });

    test('falls back to a schema inferred from the file itself', () async {
      shell.responses.add(const MapEntry(
        '.hermes',
        'AIWS_CONFIG_PATH:/root/.hermes/config.json\n'
            '{"model": "hermes-4", "port": 9119, "verbose": true}',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.hermesAgent: ToolConfigSpec(
          configPaths: [r'$HOME/.hermes/config.json'],
        ),
      });
      await service.ensureSchemas();

      final document = await service.load(AiWorkspaceTool.hermesAgent);

      expect(document.schemaFromTool, isFalse);
      expect(document.schema.fieldAt('port')?.kind, ConfigFieldKind.integer);
      expect(document.schema.fieldAt('verbose')?.kind, ConfigFieldKind.boolean);
    });

    test('reports a tool that has no config file yet', () async {
      final service = build(specs: const {
        AiWorkspaceTool.hermesAgent: ToolConfigSpec(
          configPaths: [r'$HOME/.hermes/config.json'],
        ),
      });
      await service.ensureSchemas();

      final document = await service.load(AiWorkspaceTool.hermesAgent);

      expect(document.missing, isTrue);
      expect(document.values, isEmpty);
      expect(document.schema.isEmpty, isTrue);
    });

    test('withholds every secret value from the document it hands out',
        () async {
      shell.responses.add(const MapEntry(
        'openclaw.json',
        'AIWS_CONFIG_PATH:/root/.openclaw/openclaw.json\n'
            '{"gateway": {"mode": "local", "port": 18789,'
            ' "auth": {"mode": "token", "token": "t0ps3cret"}}}',
      ));
      shell.responses.add(MapEntry('openclaw config schema', _openClawSchema));
      final service = build(specs: const {
        AiWorkspaceTool.openClaw: ToolConfigSpec(
          schemaCommand: 'openclaw config schema',
          configPaths: [r'$HOME/.openclaw/openclaw.json'],
          writeMode: ConfigWriteMode.openClawPatch,
        ),
      });
      await service.ensureSchemas();

      final document = await service.load(AiWorkspaceTool.openClaw);

      expect(jsonEncode(document.values), isNot(contains('t0ps3cret')));
      expect(document.secretKeys, contains('gateway.auth.token'));
      expect(document.values['gateway']['mode'], 'local');
    });

    test('turns a container environment into read-only fields', () async {
      shell.responses.add(const MapEntry(
        'docker inspect',
        '["WEBUI_NAME=Open WebUI","OLLAMA_BASE_URL=http://host:11434"]',
      ));
      final service = build(specs: {
        AiWorkspaceTool.openWebUi: defaultConfigSpecs[AiWorkspaceTool.openWebUi]!,
      });
      await service.ensureSchemas();

      final document = await service.load(AiWorkspaceTool.openWebUi);

      expect(document.readOnly, isTrue);
      expect(document.readOnlyReasonKey,
          'ai-workspace-config-container-env-text');
      expect(document.values['WEBUI_NAME'], 'Open WebUI');
      expect(document.schema.fieldAt('OLLAMA_BASE_URL')?.readOnly, isTrue);
    });

    test('an empty container environment is not a missing config file',
        () async {
      shell.responses.add(const MapEntry('docker inspect', '[]'));
      final service = build(specs: {
        AiWorkspaceTool.openWebUi: defaultConfigSpecs[AiWorkspaceTool.openWebUi]!,
      });

      final document = await service.load(AiWorkspaceTool.openWebUi);

      // Nothing here could create one, so the dialog must not offer to.
      expect(document.missing, isFalse);
      expect(document.readOnly, isTrue);
    });

    test('a config file that is not JSON surfaces as an error', () async {
      shell.responses.add(const MapEntry(
        '.hermes',
        'AIWS_CONFIG_PATH:/root/.hermes/config.json\nnot json at all',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.hermesAgent:
            ToolConfigSpec(configPaths: [r'$HOME/.hermes/config.json']),
      });
      await service.ensureSchemas();

      expect(() => service.load(AiWorkspaceTool.hermesAgent),
          throwsA(isA<FormatException>()));
    });

    test('a failed read is an error, not an empty config', () async {
      shell.failures['.hermes'] = 'wsl: distro not found';
      final service = build(specs: const {
        AiWorkspaceTool.hermesAgent:
            ToolConfigSpec(configPaths: [r'$HOME/.hermes/config.json']),
      });

      expect(
        () => service.load(AiWorkspaceTool.hermesAgent),
        throwsA(predicate(
            (e) => e.toString().contains('wsl: distro not found'))),
      );
    });
  });

  group('save', () {
    Future<AiWorkspaceConfigService> loadedOpenClaw() async {
      shell.responses.add(const MapEntry(
        'openclaw.json',
        'AIWS_CONFIG_PATH:/root/.openclaw/openclaw.json\n'
            '{"gateway": {"mode": "local", "port": 18789}}',
      ));
      shell.responses.add(MapEntry('openclaw config schema', _openClawSchema));
      final service = build(specs: const {
        AiWorkspaceTool.openClaw: ToolConfigSpec(
          schemaCommand: 'openclaw config schema',
          configPaths: [r'$HOME/.openclaw/openclaw.json'],
          writeMode: ConfigWriteMode.openClawPatch,
        ),
      });
      await service.ensureSchemas();
      await service.load(AiWorkspaceTool.openClaw);
      return service;
    }

    test('hands OpenClaw only the changed keys, through its own patch command',
        () async {
      final service = await loadedOpenClaw();

      await service.save(AiWorkspaceTool.openClaw, {'gateway.port': 19001});

      final script = shell.scriptContaining('config patch');
      expect(script, contains('openclaw config patch --stdin'));
      final payload = jsonDecode(shell.decodedPayload('config patch'));
      expect(payload, {
        'gateway': {'port': 19001}
      });
    });

    test('merges a file-backed change into the document it read', () async {
      shell.responses.add(const MapEntry(
        'opencode.jsonc',
        'AIWS_CONFIG_PATH:/root/.config/opencode/opencode.jsonc\n'
            '{"\$schema": "https://opencode.ai/config.json",'
            ' "model": "anthropic/claude"}',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.openCode: ToolConfigSpec(
          configPaths: [r'$HOME/.config/opencode/opencode.jsonc'],
        ),
      });
      await service.ensureSchemas();
      await service.load(AiWorkspaceTool.openCode);

      await service.save(AiWorkspaceTool.openCode, {
        'model': 'anthropic/opus',
        'server.port': 4096,
      });

      final script = shell.scriptContaining('aiws-new');
      // Written to the file the environment reported, not to the first
      // candidate, and moved into place rather than truncated first.
      expect(script,
          contains('mv /root/.config/opencode/opencode.jsonc.aiws-new '
              '/root/.config/opencode/opencode.jsonc'));
      final written = jsonDecode(shell.decodedPayload('aiws-new'));
      expect(written, {
        r'$schema': 'https://opencode.ai/config.json',
        'model': 'anthropic/opus',
        'server': {'port': 4096},
      });
    });

    test('the write script uses no command substitution or double quotes',
        () async {
      shell.responses.add(const MapEntry(
        'opencode.jsonc',
        'AIWS_CONFIG_PATH:/root/.config/opencode/opencode.jsonc\n{}',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.openCode: ToolConfigSpec(
          configPaths: [r'$HOME/.config/opencode/opencode.jsonc'],
        ),
      });
      await service.load(AiWorkspaceTool.openCode);

      await service.save(AiWorkspaceTool.openCode, {'model': 'm'});

      final script = shell.scriptContaining('aiws-new');
      // Both constructs came back mangled through the Windows command line
      // into wsl.exe; the directory is computed in Dart instead.
      expect(script, contains('mkdir -p /root/.config/opencode;'));
      expect(script, isNot(contains(r'$(')));
      expect(script, isNot(contains('"')));
    });

    test('a secret nobody retyped is not part of the write', () async {
      shell.responses.add(const MapEntry(
        'opencode.jsonc',
        'AIWS_CONFIG_PATH:/root/.config/opencode/opencode.jsonc\n'
            '{"model": "anthropic/claude", "apiKey": "sk-live-123"}',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.openCode: ToolConfigSpec(
          configPaths: [r'$HOME/.config/opencode/opencode.jsonc'],
        ),
      });
      await service.ensureSchemas();
      final document = await service.load(AiWorkspaceTool.openCode);
      expect(document.values.containsKey('apiKey'), isFalse);

      await service.save(AiWorkspaceTool.openCode, {'model': 'anthropic/opus'});

      // The key the app never showed is still in the file it wrote back.
      final written = jsonDecode(shell.decodedPayload('aiws-new'))
          as Map<String, dynamic>;
      expect(written['apiKey'], 'sk-live-123');
      expect(written['model'], 'anthropic/opus');
    });

    test('carries the document as base64 so quotes cannot escape it',
        () async {
      shell.responses.add(const MapEntry(
        'opencode.jsonc',
        'AIWS_CONFIG_PATH:/root/.config/opencode/opencode.jsonc\n{}',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.openCode: ToolConfigSpec(
          configPaths: [r'$HOME/.config/opencode/opencode.jsonc'],
        ),
      });
      await service.ensureSchemas();
      await service.load(AiWorkspaceTool.openCode);

      await service.save(AiWorkspaceTool.openCode,
          {'username': r'"; rm -rf / #$(whoami)`id`'});

      final script = shell.scriptContaining('aiws-new');
      expect(script, isNot(contains('rm -rf')));
      expect(script, isNot(contains('whoami')));
      final written = jsonDecode(shell.decodedPayload('aiws-new'));
      expect(written['username'], r'"; rm -rf / #$(whoami)`id`');
    });

    test('clearing a field drops the key from the file', () async {
      shell.responses.add(const MapEntry(
        'opencode.jsonc',
        'AIWS_CONFIG_PATH:/root/.config/opencode/opencode.jsonc\n'
            '{"model": "anthropic/claude", "share": "manual"}',
      ));
      final service = build(specs: const {
        AiWorkspaceTool.openCode: ToolConfigSpec(
          configPaths: [r'$HOME/.config/opencode/opencode.jsonc'],
        ),
      });
      await service.load(AiWorkspaceTool.openCode);

      await service.save(AiWorkspaceTool.openCode, {'share': null});

      expect(shell.decodedPayload('aiws-new'),
          '{\n  "model": "anthropic/claude"\n}');
    });

    test('a whole-file write refuses to run before a read', () async {
      final service = build(specs: const {
        AiWorkspaceTool.openCode: ToolConfigSpec(
          configPaths: [r'$HOME/.config/opencode/opencode.jsonc'],
        ),
      });

      // Writing the patch on its own would replace the file rather than
      // update it, taking every setting the app never saw with it.
      expect(() => service.save(AiWorkspaceTool.openCode, {'model': 'x'}),
          throwsA(isA<Exception>()));
      expect(shell.scriptContaining('aiws-new'), isEmpty);
    });

    test('a write that fails reports what the environment said', () async {
      final service = await loadedOpenClaw();
      shell.failures['config patch'] = 'invalid config: gateway.port';

      expect(
        () => service.save(AiWorkspaceTool.openClaw, {'gateway.port': -1}),
        throwsA(predicate(
            (e) => e.toString().contains('invalid config: gateway.port'))),
      );
    });

    test('nothing edited writes nothing', () async {
      final service = await loadedOpenClaw();
      final before = shell.scripts.length;

      await service.save(AiWorkspaceTool.openClaw, const {});

      expect(shell.scripts.length, before);
    });

    test('a read-only tool refuses to be written', () async {
      shell.responses.add(const MapEntry('docker inspect', '["A=b"]'));
      final service = build(specs: {
        AiWorkspaceTool.openWebUi: defaultConfigSpecs[AiWorkspaceTool.openWebUi]!,
      });
      await service.load(AiWorkspaceTool.openWebUi);

      expect(() => service.save(AiWorkspaceTool.openWebUi, {'A': 'c'}),
          throwsA(isA<Exception>()));
    });
  });

  group('defaults', () {
    test('every tool on the card has a configuration source', () {
      for (final tool in AiWorkspaceTool.values) {
        expect(defaultConfigSpecs.containsKey(tool), isTrue,
            reason: '$tool has no ToolConfigSpec');
      }
    });

    test('the read command looks for each candidate in order', () async {
      final service = build(specs: {
        AiWorkspaceTool.openCode: defaultConfigSpecs[AiWorkspaceTool.openCode]!,
      });
      await service.load(AiWorkspaceTool.openCode);

      final script = shell.scriptContaining('opencode.jsonc');
      expect(
        script.indexOf('opencode.jsonc'),
        lessThan(script.indexOf('opencode.json;')),
      );
      // No double quote anywhere: one reaches bash literally through the
      // Windows command line and breaks the script (see service.dart).
      expect(script, isNot(contains('"')));
    });
  });
}
