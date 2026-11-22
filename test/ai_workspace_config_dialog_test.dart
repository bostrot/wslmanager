import 'dart:convert';
import 'dart:io' show Process, ProcessResult, ProcessStartMode;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/runtime.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/ai_workspace_config_dialog.dart';

import 'mocks.dart';

/// Answers per command, like the service test's shell — the dialog reads a
/// config and writes a patch through the same broker.
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

  String scriptContaining(String needle) => scripts.firstWhere(
      (script) => script.contains(needle),
      orElse: () => '');

  Object? payloadOf(String needle) {
    final match = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'")
        .firstMatch(scriptContaining(needle));
    if (match == null) return null;
    return jsonDecode(utf8.decode(base64.decode(match.group(1)!)));
  }
}

/// The dialog renders long descriptions and a scrolling field list; the
/// 800x600 default clips them into overflow errors before an assertion runs.
const Size _kSurface = Size(1200, 1000);

const String _schema = '''
{
  "type": "object",
  "properties": {
    "model": {"type": "string", "description": "Model to use"},
    "snapshot": {"type": "boolean"},
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
        "token": {"type": "string"}
      }
    }
  }
}
''';

void main() {
  late _ScriptedShell shell;
  late AiWorkspaceService workspace;
  late String lastMessage;

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      lastMessage = msg;
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    workspaceRuntimeBuilder = WslWorkspaceRuntime.new;
    lastMessage = '';
    shell = _ScriptedShell();
    workspace = AiWorkspaceService(broker: ExecutionBroker(shell: shell));
  });

  tearDown(() {
    workspaceRuntimeBuilder = defaultWorkspaceRuntime;
  });

  AiWorkspaceConfigService configService({String? config, String? schema}) {
    shell.responses.add(MapEntry(
      'tool.json',
      config == null
          ? ''
          : 'AIWS_CONFIG_PATH:/root/.tool/tool.json\n$config',
    ));
    if (schema != null) {
      shell.responses.add(MapEntry('print-schema', schema));
    }
    return AiWorkspaceConfigService(
      workspace: workspace,
      fetchSchema: (_) async => throw Exception('no network in tests'),
      specs: {
        AiWorkspaceTool.openCode: ToolConfigSpec(
          schemaCommand: schema == null ? null : 'print-schema',
          configPaths: const [r'$HOME/.tool/tool.json'],
        ),
      },
    );
  }

  Future<void> open(WidgetTester tester, AiWorkspaceConfigService service)
      async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: AiWorkspaceConfigDialog(
          configService: service,
          tool: AiWorkspaceTool.openCode,
          toolName: 'OpenCode',
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('renders a control per kind from the published schema',
      (tester) async {
    final service = configService(
      config: '{"model": "anthropic/claude", "snapshot": true,'
          ' "gateway": {"port": 18789, "mode": "local"}}',
      schema: _schema,
    );
    await open(tester, service);

    expect(find.byKey(const ValueKey('test-ai-config-field-model')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-config-field-snapshot')),
        findsOneWidget);
    // Nested objects are their own section, closed until asked for.
    expect(find.byKey(const ValueKey('test-ai-config-section-gateway')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-config-field-gateway.port')),
        findsNothing);
    expect(find.byKey(const ValueKey('test-ai-config-schema-origin')),
        findsOneWidget);
  });

  testWidgets('a section builds its fields only once it is opened',
      (tester) async {
    final service = configService(
      config: '{"gateway": {"port": 18789, "mode": "local"}}',
      schema: _schema,
    );
    await open(tester, service);

    await tester.tap(find.byKey(const ValueKey('test-ai-config-section-gateway')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-ai-config-field-gateway.port')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-config-field-gateway.mode')),
        findsOneWidget);
  });

  testWidgets('Save is dead until something actually changes', (tester) async {
    final service = configService(
      config: '{"model": "anthropic/claude"}',
      schema: _schema,
    );
    await open(tester, service);

    BusyButton saveButton() => tester.widget<BusyButton>(
        find.byKey(const ValueKey('test-ai-config-save')));
    expect(saveButton().onPressed, isNull);

    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-field-model')),
        'anthropic/opus');
    await tester.pumpAndSettle();
    expect(saveButton().onPressed, isNotNull);

    // Typing the original value back is not a change.
    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-field-model')),
        'anthropic/claude');
    await tester.pumpAndSettle();
    expect(saveButton().onPressed, isNull);
  });

  testWidgets('saving writes only the edited key', (tester) async {
    final service = configService(
      config: '{"model": "anthropic/claude", "snapshot": true}',
      schema: _schema,
    );
    await open(tester, service);

    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-field-model')),
        'anthropic/opus');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-config-save')));
    await tester.pumpAndSettle();

    final written = shell.payloadOf('aiws-new') as Map<String, dynamic>;
    expect(written['model'], 'anthropic/opus');
    // Untouched, and still exactly what the file had.
    expect(written['snapshot'], true);
  });

  testWidgets('an integer field refuses text instead of writing it',
      (tester) async {
    final service = configService(
      config: '{"gateway": {"port": 18789}}',
      schema: _schema,
    );
    await open(tester, service);
    await tester.tap(find.byKey(const ValueKey('test-ai-config-section-gateway')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-field-gateway.port')),
        'not a port');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-config-save')));
    await tester.pumpAndSettle();

    expect(lastMessage, 'ai-workspace-config-invalid-number-text');
    expect(shell.scriptContaining('aiws-new'), isEmpty);
  });

  testWidgets('a secret is never rendered and stays out of the write',
      (tester) async {
    final service = configService(
      config: '{"model": "m", "gateway": {"token": "t0ps3cret"}}',
      schema: _schema,
    );
    await open(tester, service);
    await tester.tap(find.byKey(const ValueKey('test-ai-config-section-gateway')));
    await tester.pumpAndSettle();

    final box = tester.widget<TextBox>(
        find.byKey(const ValueKey('test-ai-config-field-gateway.token')));
    expect(box.obscureText, isTrue);
    expect(box.controller?.text, isEmpty);

    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-field-model')), 'other');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-config-save')));
    await tester.pumpAndSettle();

    final written = shell.payloadOf('aiws-new') as Map<String, dynamic>;
    // Kept from the file the service read, not re-typed by the form.
    expect(written['gateway']['token'], 't0ps3cret');
  });

  testWidgets('search finds a setting without opening its section',
      (tester) async {
    final service = configService(
      config: '{"gateway": {"mode": "local"}}',
      schema: _schema,
    );
    await open(tester, service);

    // `mode` alone would also match `model` — the search covers keys,
    // labels and descriptions on purpose.
    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-search')), 'gateway.mode');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-ai-config-field-gateway.mode')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-config-field-model')),
        findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-search')), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-ai-config-no-results')),
        findsOneWidget);
  });

  testWidgets('a tool with no config file says so and still saves',
      (tester) async {
    final service = configService(config: null, schema: _schema);
    await open(tester, service);

    expect(find.byKey(const ValueKey('test-ai-config-missing')), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-field-model')), 'anthropic/opus');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-config-save')));
    await tester.pumpAndSettle();

    expect(shell.payloadOf('aiws-new'), {'model': 'anthropic/opus'});
  });

  testWidgets('a read that fails offers a retry rather than an empty form',
      (tester) async {
    shell.failures['tool.json'] = 'wsl: distro not found';
    final service = configService(config: '{}', schema: _schema);
    await open(tester, service);

    expect(find.byKey(const ValueKey('test-ai-config-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-config-save')), findsNothing);

    shell.failures.clear();
    await tester.tap(find.byKey(const ValueKey('test-ai-config-retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-ai-config-error')), findsNothing);
    expect(find.byKey(const ValueKey('test-ai-config-field-model')),
        findsOneWidget);
  });

  testWidgets('a failed write keeps the dialog open with what was typed',
      (tester) async {
    final service = configService(config: '{"model": "m"}', schema: _schema);
    await open(tester, service);

    shell.failures['aiws-new'] = 'read-only file system';
    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-field-model')), 'other');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-ai-config-save')));
    await tester.pumpAndSettle();

    // No localization delegate is mounted in tests, so a message arrives as
    // its own key — which is still the assertion that matters: the failure
    // was reported rather than swallowed.
    expect(lastMessage, 'ai-workspace-config-save-failed-text');
    expect(find.byKey(const ValueKey('test-ai-config-field-model')),
        findsOneWidget);
    final box = tester.widget<TextBox>(
        find.byKey(const ValueKey('test-ai-config-field-model')));
    expect(box.controller?.text, 'other');
  });

  testWidgets('without a published schema the fields come from the file',
      (tester) async {
    final service = configService(
      config: '{"model": "m", "workers": 4, "debug": false}',
    );
    await open(tester, service);

    expect(find.byKey(const ValueKey('test-ai-config-field-workers')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-config-field-debug')),
        findsOneWidget);
  });

  // OpenClaw's real schema carries about two thousand settings across
  // thirty-odd sections. The form has to survive that without laying out
  // every one of them.
  testWidgets('a schema with hundreds of settings still renders',
      (tester) async {
    final properties = <String, dynamic>{};
    for (var i = 0; i < 40; i++) {
      properties['section$i'] = {
        'type': 'object',
        'properties': {
          for (var j = 0; j < 25; j++)
            'field$j': {'type': 'string'},
        },
      };
    }
    final service = configService(
      config: '{"model": "m"}',
      schema: jsonEncode({'type': 'object', 'properties': properties}),
    );
    await open(tester, service);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('test-ai-config-section-section0')),
        findsOneWidget);
    // Closed sections build no fields at all — that is what keeps a
    // thousand-field schema cheap.
    expect(find.byKey(const ValueKey('test-ai-config-field-section0.field0')),
        findsNothing);

    // And searching still reaches into every one of them.
    await tester.enterText(
        find.byKey(const ValueKey('test-ai-config-search')),
        'section39.field24');
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('test-ai-config-field-section39.field24')),
        findsOneWidget);
  });

  testWidgets('a schema the tool could not print is explained, not hidden',
      (tester) async {
    shell.failures['print-schema'] = 'openclaw: command not found';
    final service = configService(config: '{"model": "m"}', schema: _schema);
    await open(tester, service);

    expect(find.byKey(const ValueKey('test-ai-config-schema-error')),
        findsOneWidget);
    // Still editable, off the shape of the file itself.
    expect(find.byKey(const ValueKey('test-ai-config-field-model')),
        findsOneWidget);
  });
}
