// Reads, describes and writes the AI Workspace tools' own configuration.
//
// The schema is pulled at app start rather than shipped: OpenCode publishes
// one over HTTP, OpenClaw prints one from the copy installed in the
// workspace, and a tool that publishes none has its shape inferred from the
// config file it is already using. What the dialog renders is therefore the
// tool that is installed right now, not the one that was current when this
// app was built.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../execution/models.dart';
import 'config_schema.dart';
import 'service.dart';

/// How a change reaches the tool.
enum ConfigWriteMode {
  /// Merge into the config file and write the whole document back.
  file,

  /// Hand the changed keys to `openclaw config patch --stdin`, which
  /// validates them against the schema and does one atomic write. Preferred
  /// over rewriting the file: the app never has to re-serialise a document
  /// that holds the gateway token.
  openClawPatch,

  /// The tool's settings are real but this app has no safe way to change
  /// them.
  readOnly,
}

/// Where one tool keeps its settings, and how to get at them.
class ToolConfigSpec {
  /// JSON Schema served over HTTP. Pulled once per app start.
  final String? schemaUrl;

  /// Command inside the workspace that prints a JSON Schema on stdout.
  final String? schemaCommand;

  /// Config files to look for, in order. The first that exists is the one
  /// edited; the first entry is also where a missing file is created.
  final List<String> configPaths;

  /// Command that prints the current configuration as JSON, for a tool whose
  /// settings are not a file at all.
  final String? readCommand;

  /// Converts [readCommand]'s stdout into a config map.
  final Map<String, dynamic> Function(String stdout)? parseReadOutput;

  final ConfigWriteMode writeMode;

  /// i18n key explaining a [ConfigWriteMode.readOnly] tool.
  final String? readOnlyReasonKey;

  const ToolConfigSpec({
    this.schemaUrl,
    this.schemaCommand,
    this.configPaths = const [],
    this.readCommand,
    this.parseReadOutput,
    this.writeMode = ConfigWriteMode.file,
    this.readOnlyReasonKey,
  });
}

/// Marker prefix [_readCommandFor] prints before the file it found, so one
/// call answers both "which file" and "what is in it".
const String _kPathMarker = 'AIWS_CONFIG_PATH:';

/// Open WebUI takes its settings from the environment its container was
/// created with, so its "config file" is `docker inspect`.
Map<String, dynamic> _parseContainerEnv(String stdout) {
  final start = stdout.indexOf('[');
  if (start < 0) throw const FormatException('No container environment found');
  final decoded = jsonDecode(stdout.substring(start));
  if (decoded is! List) throw const FormatException('Unexpected docker output');
  final values = <String, dynamic>{};
  for (final entry in decoded) {
    if (entry is! String) continue;
    final split = entry.indexOf('=');
    if (split <= 0) continue;
    values[entry.substring(0, split)] = entry.substring(split + 1);
  }
  return values;
}

/// Per-tool configuration facts, gathered from the tools themselves
/// (bostrot/ai-tasks#72) rather than from their docs.
final Map<AiWorkspaceTool, ToolConfigSpec> defaultConfigSpecs = {
  // No CLI of its own for configuration — `opencode --help` lists no config
  // command — but every config file it writes carries
  // `"$schema": "https://opencode.ai/config.json"`, and that URL really is a
  // JSON Schema (2020-12, `$defs` + `$ref`). The installer creates the
  // `.jsonc` file; `.json` is the documented alternative and is checked in
  // case a user wrote one.
  AiWorkspaceTool.openCode: const ToolConfigSpec(
    schemaUrl: 'https://opencode.ai/config.json',
    configPaths: [
      r'$HOME/.config/opencode/opencode.jsonc',
      r'$HOME/.config/opencode/opencode.json',
    ],
  ),
  // `openclaw config schema` prints the schema for `openclaw.json`, and
  // `openclaw config patch --stdin` applies a JSON5 object in one validated
  // write. Both are the tool's own supported entry points, so a release that
  // changes its settings changes this dialog with it.
  AiWorkspaceTool.openClaw: const ToolConfigSpec(
    schemaCommand: 'openclaw config schema',
    configPaths: [r'$HOME/.openclaw/openclaw.json'],
    writeMode: ConfigWriteMode.openClawPatch,
  ),
  // No published schema, and the installer runs with `--no-onboard`, so
  // whatever it keeps under `$HOME/.hermes` is whatever the user's own setup
  // wrote. The shape is inferred from that file; when there is none the
  // dialog says so instead of inventing keys.
  AiWorkspaceTool.hermesAgent: const ToolConfigSpec(
    configPaths: [
      r'$HOME/.hermes/config.json',
      r'$HOME/.hermes/config.jsonc',
      r'$HOME/.hermes/settings.json',
    ],
  ),
  // Environment variables baked into the container at `docker run` time.
  // Shown, not edited: this card's install runs the container with no volume,
  // so re-creating it with different variables would take every conversation
  // stored in it with it.
  AiWorkspaceTool.openWebUi: ToolConfigSpec(
    readCommand:
        'docker inspect --format \'{{json .Config.Env}}\' open-webui 2>/dev/null',
    parseReadOutput: _parseContainerEnv,
    writeMode: ConfigWriteMode.readOnly,
    readOnlyReasonKey: 'ai-workspace-config-container-env-text',
  ),
};

/// One tool's configuration, ready to render.
class ToolConfigDocument {
  final AiWorkspaceTool tool;
  final ConfigSchema schema;

  /// Current values, with every secret removed — see [secretKeys]. The
  /// service keeps the real document to itself so a token is never handed to
  /// a widget.
  final Map<String, dynamic> values;

  /// Dotted keys whose value exists but was withheld.
  final Set<String> secretKeys;

  /// The file (or command) the values came from.
  final String source;

  /// True when the tool described its own settings, false when the shape was
  /// inferred from the current values. The dialog says which.
  final bool schemaFromTool;

  /// No config file yet: the tool is running on its defaults.
  final bool missing;

  final bool readOnly;
  final String? readOnlyReasonKey;

  const ToolConfigDocument({
    required this.tool,
    required this.schema,
    required this.values,
    required this.source,
    this.secretKeys = const {},
    this.schemaFromTool = false,
    this.missing = false,
    this.readOnly = false,
    this.readOnlyReasonKey,
  });
}

/// What a failed workspace command has to say for itself: stderr, else
/// stdout, else [fallback].
String executionDetail(ExecutionResult result, String fallback) {
  final stderr = result.stderr.trim();
  if (stderr.isNotEmpty) return stderr;
  final stdout = result.stdout.trim();
  if (stdout.isNotEmpty) return stdout;
  return fallback;
}

/// Fetches a schema document over HTTP. Replaced in tests.
typedef SchemaFetcher = Future<String> Function(String url);

Future<String> _defaultFetchSchema(String url) async {
  final response = await Dio().get<String>(
    url,
    options: Options(
      responseType: ResponseType.plain,
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
    ),
  );
  return response.data ?? '';
}

class AiWorkspaceConfigService {
  final AiWorkspaceService _workspace;
  final SchemaFetcher _fetchSchema;
  final Map<AiWorkspaceTool, ToolConfigSpec> _specs;

  /// Schemas the tools published this session, by tool. A tool missing from
  /// here falls back to a schema inferred from its own config file.
  final Map<AiWorkspaceTool, ConfigSchema> _schemas = {};
  final Map<AiWorkspaceTool, String> _schemaErrors = {};

  /// The last document read per tool, secrets included. Never leaves this
  /// object: [load] hands out a copy without them, and [save] merges changes
  /// back into this one.
  final Map<AiWorkspaceTool, Map<String, dynamic>> _rawDocuments = {};
  final Map<AiWorkspaceTool, String> _resolvedPaths = {};

  Future<void>? _schemaFuture;

  AiWorkspaceConfigService({
    required AiWorkspaceService workspace,
    SchemaFetcher? fetchSchema,
    Map<AiWorkspaceTool, ToolConfigSpec>? specs,
  })  : _workspace = workspace,
        _fetchSchema = fetchSchema ?? _defaultFetchSchema,
        _specs = specs ?? defaultConfigSpecs;

  /// The tools this dialog can say anything about at all.
  Iterable<AiWorkspaceTool> get configurableTools => _specs.keys;

  bool canConfigure(AiWorkspaceTool tool) => _specs.containsKey(tool);

  ToolConfigSpec? specFor(AiWorkspaceTool tool) => _specs[tool];

  /// The schema [tool] published this session, or null when it published
  /// none.
  ConfigSchema? publishedSchema(AiWorkspaceTool tool) => _schemas[tool];

  /// Why [tool]'s schema could not be pulled, for the dialog's footer. Not an
  /// error on its own — the form still works off inferred values.
  String? schemaError(AiWorkspaceTool tool) => _schemaErrors[tool];

  /// Pulls every published schema once per app start. Concurrent callers
  /// join the same run; the screen awaits the one startup already began.
  Future<void> ensureSchemas() => _schemaFuture ??= _loadSchemas();

  /// Pulls [tool]'s schema again, ignoring what the startup pull found.
  ///
  /// The case that needs it: a tool installed after the app started had
  /// nothing to answer the first pull, and its dialog would otherwise fall
  /// back to inferred fields for the rest of the session.
  Future<void> refreshSchema(AiWorkspaceTool tool) => _loadSchema(tool);

  Future<void> _loadSchemas() async {
    await Future.wait(_specs.keys.map(_loadSchema));
  }

  Future<void> _loadSchema(AiWorkspaceTool tool) async {
    final spec = _specs[tool]!;
    final url = spec.schemaUrl;
    final command = spec.schemaCommand;
    if (url == null && command == null) return;
    try {
      final String source;
      if (url != null) {
        source = await _fetchSchema(url);
      } else {
        // A tool that is not installed has no schema to print, and that is
        // the ordinary case on a fresh workspace — recorded, not raised.
        final result = await _workspace.runInWorkspace(
          command!,
          timeout: const Duration(seconds: 60),
        );
        if (!result.isSuccess) {
          throw Exception(_detail(result, 'schema command failed'));
        }
        source = result.stdout;
      }
      final decoded = jsonDecode(_trimToJson(source));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Schema is not a JSON object');
      }
      _schemas[tool] = ConfigSchema.fromJsonSchema(decoded);
      _schemaErrors.remove(tool);
    } catch (e) {
      _schemas.remove(tool);
      _schemaErrors[tool] = e.toString();
    }
  }

  /// Both schema sources print banners around their JSON — OpenClaw's CLI
  /// writes its version line first — so the document starts at the first
  /// brace, not at the first byte.
  static String _trimToJson(String source) {
    final start = source.indexOf('{');
    if (start <= 0) return source;
    return source.substring(start);
  }

  static String _detail(ExecutionResult result, String fallback) =>
      executionDetail(result, fallback);

  /// Prints the first config file that exists, with its path on a marker
  /// line first. Single quotes only, and no `"` anywhere: a double quote
  /// reaches bash literally through the Windows command line (see the probe
  /// scripts in service.dart).
  static String _readCommandFor(List<String> paths) {
    final buffer = StringBuffer();
    for (final path in paths) {
      buffer.write('if [ -f $path ]; then '
          'echo $_kPathMarker$path; cat $path; exit 0; fi; ');
    }
    buffer.write('exit 0');
    return buffer.toString();
  }

  /// Reads [tool]'s configuration and pairs it with the best schema
  /// available.
  ///
  /// [pullSchema] false skips asking the tool for its schema when none is
  /// held yet — for a caller that wants the values, not the form, and would
  /// otherwise wait on `openclaw config schema` for nothing.
  Future<ToolConfigDocument> load(
    AiWorkspaceTool tool, {
    bool pullSchema = true,
  }) async {
    final spec = _specs[tool];
    if (spec == null) {
      throw Exception('No configuration is known for this tool');
    }

    final readCommand = spec.readCommand ?? _readCommandFor(spec.configPaths);
    final result = await _workspace.runInWorkspace(
      readCommand,
      timeout: const Duration(seconds: 30),
    );
    if (!result.isSuccess) {
      throw Exception(_detail(result, 'Could not read the configuration'));
    }

    var body = result.stdout;
    var source = spec.configPaths.isNotEmpty ? spec.configPaths.first : '';
    var missing = false;
    if (spec.readCommand == null) {
      final markerAt = body.indexOf(_kPathMarker);
      if (markerAt < 0) {
        missing = true;
        body = '';
      } else {
        final lineEnd = body.indexOf('\n', markerAt);
        source = body
            .substring(markerAt + _kPathMarker.length,
                lineEnd < 0 ? body.length : lineEnd)
            .trim();
        body = lineEnd < 0 ? '' : body.substring(lineEnd + 1);
      }
    } else {
      source = 'open-webui';
    }

    Map<String, dynamic> values;
    if (missing || body.trim().isEmpty) {
      // "No config file yet, saving creates one" is only true of a tool whose
      // settings are a file. A container that reported no environment has a
      // configuration — it is simply empty, and nothing here would create it.
      missing = spec.readCommand == null;
      values = <String, dynamic>{};
    } else if (spec.parseReadOutput != null) {
      values = spec.parseReadOutput!(body);
    } else {
      values = decodeRelaxedJson(body);
    }

    _rawDocuments[tool] = values;
    _resolvedPaths[tool] = source;

    // A tool installed since the startup pull, or one whose pull failed on a
    // flaky network, gets one more chance before the fields drop back to
    // whatever the file happens to hold. Free for a tool that publishes
    // nothing: [_loadSchema] returns at once when there is no source.
    if (pullSchema && _schemas[tool] == null) {
      await _loadSchema(tool);
    }

    final published = _schemas[tool];
    final readOnly = spec.writeMode == ConfigWriteMode.readOnly;
    final schema = published ??
        ConfigSchema.inferred(values, readOnly: readOnly);

    final secretKeys = <String>{};
    final visible = _copyWithoutSecrets(values, schema, const [], secretKeys);

    return ToolConfigDocument(
      tool: tool,
      schema: schema,
      values: visible,
      secretKeys: secretKeys,
      source: source,
      schemaFromTool: published != null,
      missing: missing,
      readOnly: readOnly,
      readOnlyReasonKey: spec.readOnlyReasonKey,
    );
  }

  /// Drops every value the schema (or its key) marks as a credential.
  ///
  /// A gateway token in a dialog is one screen-share away from being a
  /// published one, and nothing in this form needs to show it: an unchanged
  /// secret is simply not part of the patch.
  Map<String, dynamic> _copyWithoutSecrets(
    Map<String, dynamic> values,
    ConfigSchema schema,
    List<String> path,
    Set<String> secretKeys,
  ) {
    final copy = <String, dynamic>{};
    for (final entry in values.entries) {
      final childPath = [...path, entry.key];
      final key = childPath.join('.');
      final field = schema.fieldAt(key);
      final secret = field?.secret ?? isSecretKey(entry.key);
      if (secret && entry.value is! Map) {
        secretKeys.add(key);
        continue;
      }
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        copy[entry.key] =
            _copyWithoutSecrets(value, schema, childPath, secretKeys);
      } else {
        copy[entry.key] = value;
      }
    }
    return copy;
  }

  /// Applies [changes] — dotted key to new value — to [tool]'s configuration.
  ///
  /// Only the keys the user edited are sent, so a setting this app does not
  /// render, a comment in a `.jsonc` file it never parsed into a field, and a
  /// token it deliberately did not read all stay as they are.
  Future<void> save(
    AiWorkspaceTool tool,
    Map<String, Object?> changes,
  ) async {
    final spec = _specs[tool];
    if (spec == null) {
      throw Exception('No configuration is known for this tool');
    }
    if (spec.writeMode == ConfigWriteMode.readOnly) {
      throw Exception('This tool\'s configuration is read-only');
    }
    if (changes.isEmpty) return;

    final patch = nestedPatch(changes);
    final encoded = const JsonEncoder.withIndent('  ').convert(patch);

    switch (spec.writeMode) {
      case ConfigWriteMode.openClawPatch:
        await _run(
          '${_pipeJson(encoded)} openclaw config patch --stdin',
          'Could not write the configuration',
        );
        // The tool rewrote the file; the copy held here is stale.
        _rawDocuments.remove(tool);
        break;
      case ConfigWriteMode.file:
        // A whole-file write rebuilds the document from the copy [load] read.
        // Without one it would write the patch alone, which is not an update
        // of the file but a replacement of it.
        final existing = _rawDocuments[tool];
        if (existing == null) {
          throw Exception('Read the configuration before writing it');
        }
        final document = <String, dynamic>{...existing};
        applyPatch(document, patch);
        final path = _resolvedPaths[tool] ??
            (spec.configPaths.isNotEmpty ? spec.configPaths.first : null);
        if (path == null) {
          throw Exception('No configuration file to write');
        }
        final body = const JsonEncoder.withIndent('  ').convert(document);
        // Temp file then `mv`, so a failed decode never leaves the tool with
        // half a config, and `mkdir -p` because the file may not exist yet.
        //
        // The directory is split here rather than with `$(dirname …)`: a
        // command substitution is one of the two constructs that came back
        // mangled through the Windows command line into `wsl.exe` (see the
        // wait loops in service.dart), and this one is a plain string
        // operation on a path that is already known.
        final slash = path.lastIndexOf('/');
        final directory = slash > 0 ? path.substring(0, slash) : '';
        await _run(
          '${directory.isEmpty ? '' : 'mkdir -p $directory; '}'
          '${_pipeJson(body)} cat > $path.aiws-new && mv $path.aiws-new $path',
          'Could not write the configuration',
        );
        _rawDocuments[tool] = document;
        break;
      case ConfigWriteMode.readOnly:
        break;
    }
  }

  /// Carries [json] into the workspace as base64 and decodes it there.
  ///
  /// The document is arbitrary user text going through `wsl.exe`'s command
  /// line and then bash: quotes, `$`, backticks and newlines in it would all
  /// be interpreted on the way. Base64 is the only alphabet that survives
  /// both intact — the same reason the macOS snippet runner uses it.
  static String _pipeJson(String json) =>
      'printf %s \'${base64.encode(utf8.encode(json))}\' | base64 -d |';

  Future<void> _run(String command, String fallback) async {
    final result = await _workspace.runInWorkspace(
      command,
      timeout: const Duration(seconds: 60),
    );
    if (!result.isSuccess) {
      throw Exception(_detail(result, fallback));
    }
  }
}
