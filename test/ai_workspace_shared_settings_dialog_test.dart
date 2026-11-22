import 'dart:convert';
import 'dart:io' show Process, ProcessResult, ProcessStartMode;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localization/localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/runtime.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/ai_workspace/shared_settings.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/ai_workspace_shared_settings_dialog.dart';

import 'mocks.dart';

/// Answers per command, like the service test's shell: the dialog reads
/// files, patches OpenClaw and runs Hermes' CLI through the same broker.
class _ScriptedShell extends TestShell {
  final Map<String, String> failures = {};
  final List<String> scripts = [];

  String _answer(List<String> arguments) {
    final line = arguments.join(' ');
    if (arguments.contains('--list')) return 'ai-workspace\n';
    scripts.add(line);
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
}

const Size _kSurface = Size(1200, 1000);

void main() {
  late _ScriptedShell shell;
  late AiWorkspaceService workspace;
  late AiWorkspaceSharedSettingsService service;
  late String lastMessage;
  late int settingsOpened;

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
    settingsOpened = 0;
    shell = _ScriptedShell();
    workspace = AiWorkspaceService(broker: ExecutionBroker(shell: shell));
    service = AiWorkspaceSharedSettingsService(
      workspace: workspace,
      config: AiWorkspaceConfigService(
        workspace: workspace,
        fetchSchema: (url) async => throw Exception('no network in tests'),
      ),
    );
  });

  tearDown(() {
    workspaceRuntimeBuilder = defaultWorkspaceRuntime;
  });

  void install(AiWorkspaceTool tool, [ToolStatus status = ToolStatus.stopped]) {
    if (workspace.toolStates.isEmpty) workspace.seedToolStates();
    workspace.getState(tool)!.status = status;
  }

  /// The assistant's "Bring Your Own AI Key" fields, which are the only
  /// place these values are edited.
  void configureAssistant({
    String endpoint = 'https://llm.example.com/v1',
    String model = 'gpt-4.1',
    String apiKey = 'sk-byok',
  }) {
    AiService()
      ..setByokBaseUrl(endpoint)
      ..setByokModel(model)
      ..setByokApiKey(apiKey);
  }

  /// Opens the dialog the way the page does, on a route of its own, so
  /// closing it is something the test can observe.
  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(_kSurface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Builder(
          builder: (context) => Button(
            key: const ValueKey('test-open'),
            onPressed: () => showAiWorkspaceSharedSettingsDialog(
              context: context,
              service: service,
              toolName: (tool) => tool.name,
              openSettings: () => settingsOpened++,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('test-open')));
    await tester.pumpAndSettle();
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-ai-shared-apply')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      "shows the assistant's endpoint and model, never its key, and applies "
      'them to every installed tool', (tester) async {
    configureAssistant();
    install(AiWorkspaceTool.openClaw);
    install(AiWorkspaceTool.hermesAgent, ToolStatus.running);
    install(AiWorkspaceTool.openWebUi, ToolStatus.running);
    await open(tester);

    expect(find.text('https://llm.example.com/v1'), findsOneWidget);
    expect(find.text('gpt-4.1'), findsOneWidget);
    expect(find.text('sk-byok'), findsNothing);
    expect(find.text('ai-workspace-shared-key-set-text'.i18n()),
        findsOneWidget);
    expect(find.byType(TextBox), findsNothing,
        reason: 'the values are edited in Settings, nowhere else');

    await apply(tester);

    expect(shell.scriptContaining('openclaw config patch'), isNotEmpty);
    expect(shell.scriptContaining('hermes config set'),
        contains("model.api_key 'sk-byok'"));
    // One line per tool, and the unsupported one says what to do instead.
    expect(find.byKey(const ValueKey('test-ai-shared-result-openClaw')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-shared-result-hermesAgent')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-shared-result-openWebUi')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-shared-result-openCode')),
        findsNothing,
        reason: 'not installed, so not touched');
    expect(
        find.text('ai-workspace-shared-openwebui-text'.i18n()), findsOneWidget);
    expect(find.text('ai-workspace-shared-restart-hint-text'.i18n()),
        findsOneWidget);
    expect(lastMessage, 'ai-workspace-shared-tools-updated-text'.i18n());
  });

  testWidgets(
      'a tool that refuses the write is reported without hiding the rest',
      (tester) async {
    shell.failures['openclaw config patch'] = 'invalid config: nope';
    configureAssistant();
    install(AiWorkspaceTool.openClaw);
    install(AiWorkspaceTool.hermesAgent);
    await open(tester);

    await apply(tester);

    // Translations are not loaded under test, so `.i18n` returns the key and
    // the failure line is told apart from the others by its key alone.
    expect(find.byKey(const ValueKey('test-ai-shared-result-openClaw')),
        findsOneWidget);
    expect(
        find.text('ai-workspace-shared-failed-text'
            .i18n(['openClaw', 'invalid config: nope'])),
        findsOneWidget);
    expect(find.text('ai-workspace-shared-applied-text'.i18n(['hermesAgent'])),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-shared-result-hermesAgent')),
        findsOneWidget);
    expect(lastMessage, isNot('ai-workspace-shared-tools-updated-text'.i18n()));
  });

  testWidgets('with nothing set up, Apply is off and Settings is the way in',
      (tester) async {
    install(AiWorkspaceTool.openClaw);
    await open(tester);

    expect(find.byKey(const ValueKey('test-ai-shared-unset')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-ai-shared-endpoint')), findsNothing,
        reason: 'the assistant defaults are not worth showing as "set"');
    final applyButton = tester
        .widget<BusyButton>(find.byKey(const ValueKey('test-ai-shared-apply')));
    expect(applyButton.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('test-ai-shared-settings')));
    await tester.pumpAndSettle();

    expect(settingsOpened, 1);
    expect(find.byType(AiWorkspaceSharedSettingsDialog), findsNothing,
        reason: 'the dialog closes before Settings opens');
    expect(shell.scripts, isEmpty);
  });

  testWidgets('a keyless local endpoint is applied without a key',
      (tester) async {
    configureAssistant(
        endpoint: 'http://ollama.lan:11434/v1', model: 'llama3', apiKey: '');
    install(AiWorkspaceTool.hermesAgent);
    await open(tester);

    expect(find.text('ai-workspace-shared-key-unset-text'.i18n()),
        findsOneWidget);

    await apply(tester);

    final script = shell.scriptContaining('hermes config set');
    expect(script, contains("model.base_url 'http://ollama.lan:11434/v1'"));
    expect(script, isNot(contains('api_key')));
    expect(find.byKey(const ValueKey('test-ai-shared-result-hermesAgent')),
        findsOneWidget);
  });

  testWidgets('refuses a value a shell line could not hold', (tester) async {
    configureAssistant(model: "gpt'; rm -rf /");
    install(AiWorkspaceTool.openClaw);
    await open(tester);

    await apply(tester);

    expect(lastMessage, 'ai-workspace-shared-invalid-text'.i18n());
    expect(shell.scripts, isEmpty);
  });

  testWidgets('with nothing installed there is nothing to apply, and it says so',
      (tester) async {
    configureAssistant();
    await open(tester);

    await apply(tester);

    expect(find.byKey(const ValueKey('test-ai-shared-none')), findsOneWidget);
    expect(shell.scripts, isEmpty);
  });
}
