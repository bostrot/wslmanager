// One model and endpoint for every AI Workspace tool (bostrot/ai-tasks#81).
//
// The endpoint, key and model are the assistant's own "Bring Your Own AI
// Key" settings — the same three values the chat panel uses, edited in
// Settings and nowhere else, so there is one place to set them and the
// tools and the chat can never disagree. Each tool spells them
// differently: OpenCode wants a provider block plus `model`, OpenClaw a
// `models.providers` entry plus `agents.defaults.model.primary`, Hermes a
// handful of `hermes config set` calls. This file translates.
//
// Nothing here writes a config file itself. Everything goes through the
// tool's own supported entry point, the same way the settings dialog does:
// [AiWorkspaceConfigService.save] for the file-backed and patch-backed tools,
// and the tool's CLI for Hermes, whose settings live in YAML and an `.env`
// file that only its CLI knows how to route between.

import 'package:localization/localization.dart';

import '../../components/notify.dart';
import '../ai_service.dart';
import '../provisioning.dart' show shellQuote;
import 'config_schema.dart';
import 'config_service.dart';
import 'service.dart';

/// The provider id written into every tool that keeps a provider catalog.
/// Fixed so a second apply updates the entry the first one made rather than
/// adding another; a tool's own built-in providers are never touched.
const String kSharedProviderId = 'wslmanager';

/// The display name those tools show for that provider.
const String kSharedProviderName = 'WSL Manager shared endpoint';

/// The three facts every tool is given.
class AiWorkspaceSharedSettings {
  /// Base URL of an OpenAI-compatible API, e.g. `https://api.openai.com/v1`.
  final String endpoint;

  /// Model id as the endpoint knows it, e.g. `gpt-4o-mini`.
  final String model;

  /// Empty for an endpoint that needs none (a local Ollama, say). An empty
  /// key is never written, so a key a tool already holds survives an apply
  /// that did not set one.
  final String apiKey;

  const AiWorkspaceSharedSettings({
    this.endpoint = '',
    this.model = '',
    this.apiKey = '',
  });

  /// What the assistant is set to right now: its stored base URL, model and
  /// key, with the assistant's own defaults where nothing is stored — so a
  /// tool asks the same endpoint the same question the chat would.
  factory AiWorkspaceSharedSettings.fromAssistant() {
    final assistant = AiService();
    return AiWorkspaceSharedSettings(
      endpoint: assistant.byokBaseUrl,
      model: assistant.byokModel,
      apiKey: assistant.byokApiKey,
    );
  }

  /// Whether the user has set anything up: a key, or an endpoint other than
  /// the assistant's default (a local model needs no key). Until then there
  /// is nothing worth writing into a tool, and a fresh install keeps its
  /// own defaults rather than being pointed at OpenAI without a key.
  bool get isConfigured =>
      apiKey.isNotEmpty || endpoint != AiService.defaultByokBaseUrl;

  /// Enough to configure a tool with. The key is optional; the other two are
  /// not, since a provider entry without an endpoint or a default model
  /// without a name would leave the tool worse off than before.
  bool get isComplete => endpoint.isNotEmpty && model.isNotEmpty;

  /// The i18n key of the first thing wrong with these settings, or null when
  /// they can be handed to a tool. One check for the dialog and the writer,
  /// so the two cannot disagree about what is acceptable.
  String? get problemKey {
    if (!isComplete) return 'ai-workspace-shared-required-text';
    if (![endpoint, model, apiKey].every(isShellSafeValue)) {
      return 'ai-workspace-shared-invalid-text';
    }
    return null;
  }

  /// `provider/model`, the form both OpenCode and OpenClaw pick a default by.
  String get qualifiedModel => '$kSharedProviderId/$model';

  @override
  bool operator ==(Object other) =>
      other is AiWorkspaceSharedSettings &&
      other.endpoint == endpoint &&
      other.model == model &&
      other.apiKey == apiKey;

  @override
  int get hashCode => Object.hash(endpoint, model, apiKey);
}

/// Whether [value] can sit on a shell line.
///
/// The Hermes values end up inside single quotes on a line that crosses the
/// Windows command line into `wsl.exe` on one backend and SSH on the other
/// (see [AiWorkspaceConfigService] on why single quotes are the only safe
/// ones). A quote, a backslash, whitespace or a control character is the
/// one thing that could break out of them, and no endpoint, model id or API
/// key legitimately contains any of those — so the same rule applies to
/// every tool rather than the writer accepting for one what it refuses for
/// another.
bool isShellSafeValue(String value) =>
    !RegExp(r'''['"\\\s]''').hasMatch(value) &&
    !value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

/// What happened to one tool during an apply.
enum SharedSettingsOutcome {
  /// The tool now points at the shared endpoint and model.
  applied,

  /// The tool cannot take them from here — [SharedSettingsResult.reasonKey]
  /// says why and what to do instead.
  skipped,

  /// The tool was asked and refused — [SharedSettingsResult.error] is what
  /// it said.
  failed,
}

class SharedSettingsResult {
  final AiWorkspaceTool tool;
  final SharedSettingsOutcome outcome;

  /// i18n key for a [SharedSettingsOutcome.skipped] tool.
  final String? reasonKey;

  /// The environment's message for a [SharedSettingsOutcome.failed] tool.
  final String? error;

  const SharedSettingsResult({
    required this.tool,
    required this.outcome,
    this.reasonKey,
    this.error,
  });
}

/// How the shared settings reach one tool. Exactly one of [changes],
/// [command] and [unsupportedReasonKey] is set.
class _Binding {
  /// Dotted keys for [AiWorkspaceConfigService.save], which merges them into
  /// the tool's own file (OpenCode) or hands them to its patch command
  /// (OpenClaw). Only these keys change; everything else the tool holds
  /// stays as it is. [current] is what the tool holds now, secrets removed.
  final Map<String, Object?> Function(
    AiWorkspaceSharedSettings settings,
    Map<String, dynamic> current,
  )? changes;

  /// A shell line for a tool whose settings only its CLI should write.
  final String Function(AiWorkspaceSharedSettings settings)? command;

  /// i18n key explaining a tool this cannot configure at all.
  final String? unsupportedReasonKey;

  const _Binding({this.changes, this.command, this.unsupportedReasonKey});

  bool get supported => changes != null || command != null;
}

/// One entry in a provider's model list, as OpenClaw declares one
/// (`docs.openclaw.ai/gateway/config-tools/custom-providers`). The limits
/// are the example's, and the cost is zero because this app has no idea what
/// the endpoint charges; both are the tool's own to refine.
Map<String, Object?> _openClawModelEntry(String model) => {
      'id': model,
      'name': model,
      'reasoning': false,
      'input': ['text'],
      'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
      'contextWindow': 128000,
      'maxTokens': 32000,
    };

final Map<AiWorkspaceTool, _Binding> _bindings = {
  // A provider block in `opencode.json` plus the top-level `model`
  // (`opencode.ai/docs/providers`). `models` is set as one map so a model
  // id with a dot in it (`gpt-4.1`) is a value rather than a key path;
  // the file writer merges maps, so models the user added stay.
  AiWorkspaceTool.openCode: _Binding(
    changes: (settings, _) => {
      'provider.$kSharedProviderId.npm': '@ai-sdk/openai-compatible',
      'provider.$kSharedProviderId.name': kSharedProviderName,
      'provider.$kSharedProviderId.options.baseURL': settings.endpoint,
      if (settings.apiKey.isNotEmpty)
        'provider.$kSharedProviderId.options.apiKey': settings.apiKey,
      'provider.$kSharedProviderId.models': {
        settings.model: {'name': settings.model},
      },
      'model': settings.qualifiedModel,
    },
  ),
  // `models.providers.<id>` with an `openai-completions` entry, and the
  // agent default pointed at it. Applied through `openclaw config patch`,
  // which validates against the tool's own schema, merges objects and
  // replaces arrays. `models.providers.<id>.models` is one of the paths the
  // CLI protects — a write that would drop an entry from it is refused — so
  // the list sent is the one the tool holds plus this model, never less.
  AiWorkspaceTool.openClaw: _Binding(
    changes: (settings, current) {
      final existing = valueAtPath(
          current, ['models', 'providers', kSharedProviderId, 'models']);
      final kept = existing is List
          ? existing.where((entry) =>
              entry is! Map || entry['id'] != settings.model)
          : const <Object?>[];
      return {
        'models.providers.$kSharedProviderId': {
          'baseUrl': settings.endpoint,
          if (settings.apiKey.isNotEmpty) 'apiKey': settings.apiKey,
          'api': 'openai-completions',
          'models': [...kept, _openClawModelEntry(settings.model)],
        },
        'agents.defaults.model.primary': settings.qualifiedModel,
      };
    },
  ),
  // Hermes keeps `model.*` in `config.yaml`, and `hermes config set` is its
  // documented writer for dotted keys. `provider: custom` with `base_url`
  // and `api_key` under `model` is its shape for an OpenAI-compatible
  // endpoint (`hermes-agent.nousresearch.com/docs/integrations/providers`);
  // the `OPENAI_*` variables are read by its `openai-api` provider only, so
  // they are not what a custom endpoint wants.
  AiWorkspaceTool.hermesAgent: _Binding(
    command: (settings) => [
      'hermes config set model.provider custom',
      'hermes config set model.base_url ${shellQuote(settings.endpoint)}',
      'hermes config set model.default ${shellQuote(settings.model)}',
      if (settings.apiKey.isNotEmpty)
        'hermes config set model.api_key ${shellQuote(settings.apiKey)}',
    ].join(' && '),
  ),
  // Open WebUI's endpoint is part of the container environment it was
  // created with, which this app shows read-only for the reason
  // [defaultConfigSpecs] gives.
  AiWorkspaceTool.openWebUi: const _Binding(
    unsupportedReasonKey: 'ai-workspace-shared-openwebui-text',
  ),
};

/// Pushes the assistant's endpoint, key and model into the tools.
///
/// Holds no settings of its own: [current] reads the assistant's each time,
/// so the tools are given what the chat uses and nothing can drift between
/// the two.
class AiWorkspaceSharedSettingsService {
  final AiWorkspaceService _workspace;
  final AiWorkspaceConfigService _config;

  AiWorkspaceSharedSettingsService({
    required AiWorkspaceService workspace,
    required AiWorkspaceConfigService config,
  })  : _workspace = workspace,
        _config = config;

  /// Makes every install the workspace finishes apply the assistant's
  /// settings to the new tool. App-level, so it does not matter which page
  /// is open when a ten-minute install ends.
  void attach() {
    _workspace.onInstalled = applyAfterInstall;
  }

  /// The assistant's settings as they stand now.
  AiWorkspaceSharedSettings current() =>
      AiWorkspaceSharedSettings.fromAssistant();

  /// Whether [tool] can be pointed at the shared endpoint from here.
  bool supports(AiWorkspaceTool tool) => _bindings[tool]?.supported ?? false;

  /// Whether [tool] is on the machine, so has a configuration to change.
  bool isInstalled(AiWorkspaceTool tool) {
    final status = _workspace.getState(tool)?.status;
    return status != null &&
        status != ToolStatus.notInstalled &&
        status != ToolStatus.error;
  }

  List<AiWorkspaceTool> installedTools() =>
      AiWorkspaceTool.values.where(isInstalled).toList();

  /// Applies [settings] to every installed tool at once — they write
  /// disjoint files — and answers in card order. One tool refusing does not
  /// stop the others; each gets its own result.
  Future<List<SharedSettingsResult>> applyToAll(
          AiWorkspaceSharedSettings settings) =>
      Future.wait(installedTools().map((tool) => applyTo(tool, settings)));

  /// Applies [settings] to one tool. Never throws: a refusal is a result.
  Future<SharedSettingsResult> applyTo(
    AiWorkspaceTool tool,
    AiWorkspaceSharedSettings settings,
  ) async {
    final binding = _bindings[tool]!;
    if (!binding.supported) {
      return SharedSettingsResult(
        tool: tool,
        outcome: SharedSettingsOutcome.skipped,
        reasonKey: binding.unsupportedReasonKey,
      );
    }
    final problem = settings.problemKey;
    if (problem != null) {
      return SharedSettingsResult(
        tool: tool,
        outcome: SharedSettingsOutcome.failed,
        error: problem.i18n(),
      );
    }
    try {
      final changes = binding.changes;
      if (changes != null) {
        // The file writer merges into the document this read; the patch
        // writer needs it for the model list it must not shorten. No schema
        // pull: the shape of the file is not what is being asked.
        final document = await _config.load(tool, pullSchema: false);
        await _config.save(tool, changes(settings, document.values));
      } else {
        final result = await _workspace.runInWorkspace(
          binding.command!(settings),
          timeout: const Duration(seconds: 60),
        );
        if (!result.isSuccess) {
          throw Exception(executionDetail(
              result, 'ai-workspace-shared-no-output-text'.i18n()));
        }
      }
      return SharedSettingsResult(
          tool: tool, outcome: SharedSettingsOutcome.applied);
    } catch (e) {
      return SharedSettingsResult(
        tool: tool,
        outcome: SharedSettingsOutcome.failed,
        error: e.toString(),
      );
    }
  }

  /// Pushes the assistant's settings, as they stand now, into every
  /// installed tool and reports through [Notify] — for the caller with no
  /// result list of its own, Settings saving new values. Nothing is written
  /// while nothing is set up.
  Future<List<SharedSettingsResult>> applyCurrentAndNotify() async {
    // With AI switched off nothing reaches the workspace distro — this is
    // the one path from Save that would otherwise provision it.
    if (!AiService.featuresEnabled) return const [];
    final settings = current();
    if (!settings.isConfigured) return const [];
    final results = await applyToAll(settings);
    for (final result in results) {
      if (result.outcome == SharedSettingsOutcome.failed) {
        _notifyFailure(result);
      }
    }
    if (results.any((r) => r.outcome == SharedSettingsOutcome.applied)) {
      Notify.message(
        'ai-workspace-shared-tools-updated-text'.i18n(),
        severity: InfoBarSeverity.success,
      );
    }
    return results;
  }

  /// A tool that has just been installed gets the assistant's endpoint and
  /// model without being asked, which is what "set it once" means: the
  /// settings existed before the tool did, and the next thing the user
  /// would do is open its form and type them again. Runs before the install
  /// reports done, so Start cannot beat it.
  Future<void> applyAfterInstall(AiWorkspaceTool tool) async {
    final settings = current();
    if (!settings.isConfigured || !supports(tool) || !isInstalled(tool)) {
      return;
    }
    final result = await applyTo(tool, settings);
    switch (result.outcome) {
      case SharedSettingsOutcome.applied:
        Notify.message(
          'ai-workspace-shared-auto-applied-text'
              .i18n([_workspace.toolName(tool)]),
          severity: InfoBarSeverity.success,
        );
        break;
      case SharedSettingsOutcome.failed:
        _notifyFailure(result);
        break;
      case SharedSettingsOutcome.skipped:
        break;
    }
  }

  void _notifyFailure(SharedSettingsResult result) {
    Notify.message(
      'ai-workspace-shared-auto-failed-text'
          .i18n([_workspace.toolName(result.tool), result.error ?? '']),
      severity: InfoBarSeverity.error,
    );
  }
}
