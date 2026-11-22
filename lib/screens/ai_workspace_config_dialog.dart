// The dynamic settings form for one AI Workspace tool.
//
// Nothing here knows what any tool's settings are called. The controls come
// from whatever [AiWorkspaceConfigService] read this session — a schema the
// tool published, or the shape of its own config file — so a tool that adds a
// setting in its next release gets a field for it without a change here
// (bostrot/ai-tasks#72).

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';

import '../api/ai_workspace/config_schema.dart';
import '../api/ai_workspace/config_service.dart';
import '../api/ai_workspace/service.dart';
import '../components/busy_button.dart';
import '../components/helpers.dart';
import '../components/notify.dart';

/// Opens the configuration dialog for [tool]. Resolves true when something
/// was written, so the caller can offer a restart.
Future<bool?> showAiWorkspaceConfigDialog({
  required BuildContext context,
  required AiWorkspaceConfigService configService,
  required AiWorkspaceTool tool,
  required String toolName,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => AiWorkspaceConfigDialog(
      configService: configService,
      tool: tool,
      toolName: toolName,
    ),
  );
}

class AiWorkspaceConfigDialog extends StatefulWidget {
  final AiWorkspaceConfigService configService;
  final AiWorkspaceTool tool;
  final String toolName;

  const AiWorkspaceConfigDialog({
    super.key,
    required this.configService,
    required this.tool,
    required this.toolName,
  });

  @override
  State<AiWorkspaceConfigDialog> createState() =>
      _AiWorkspaceConfigDialogState();
}

class _AiWorkspaceConfigDialogState extends State<AiWorkspaceConfigDialog> {
  ToolConfigDocument? _document;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  /// Edited values by dotted key. Only these are ever written.
  final Map<String, Object?> _changes = {};

  /// Text controllers for the fields that have been rendered. Built on
  /// demand: OpenClaw's schema carries about two thousand settings, and
  /// creating a controller for every one of them to show ten would be a
  /// waste the user pays for in dropped frames.
  final Map<String, TextEditingController> _controllers = {};

  /// Sections the user has opened. An [Expander]'s content is only built for
  /// these, for the same reason.
  final Set<String> _expanded = {};

  final TextEditingController _searchController = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Joins the pull app startup began; only waits when the dialog opened
      // first.
      await widget.configService.ensureSchemas();
      final document = await widget.configService.load(widget.tool);
      if (!mounted) return;
      setState(() {
        _document = document;
        _changes.clear();
        for (final controller in _controllers.values) {
          controller.dispose();
        }
        _controllers.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Object? _originalValue(ConfigField field) =>
      valueAtPath(_document!.values, field.path);

  bool get _hasChanges => _changes.isNotEmpty;

  TextEditingController _controllerFor(ConfigField field, String initial) {
    return _controllers.putIfAbsent(
      field.key,
      () => TextEditingController(text: initial),
    );
  }

  /// Records an edit, or forgets it again when the value is back to what the
  /// file already holds — a form that reports "unsaved changes" after an
  /// undo writes settings nobody chose.
  void _record(ConfigField field, Object? value) {
    final original = _originalValue(field);
    setState(() {
      if (_sameValue(original, value)) {
        _changes.remove(field.key);
      } else {
        _changes[field.key] = value;
      }
    });
  }

  static bool _sameValue(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return jsonEncode(a) == jsonEncode(b);
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
      title: Text('ai-workspace-config-title'.i18n([widget.toolName])),
      content: SizedBox(
        width: 600,
        child: _loading
            ? Row(
                key: const ValueKey('test-ai-config-loading'),
                children: [
                  const SizedBox(
                      width: 16, height: 16, child: ProgressRing(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('ai-workspace-config-loading-text'.i18n()),
                ],
              )
            : _error != null
                ? _buildError(_error!)
                : document == null
                    ? const SizedBox.shrink()
                    : _buildForm(document),
      ),
      actions: [
        if (!_loading && _error == null && document != null && !document.readOnly)
          BusyButton(
            key: const ValueKey('test-ai-config-save'),
            filled: true,
            label: 'save-text'.i18n(),
            busy: _saving,
            minWidth: 72.0,
            onPressed: _hasChanges && !_saving ? _save : null,
          ),
        Button(
          key: const ValueKey('test-ai-config-close'),
          onPressed: _saving
              ? null
              : () => Navigator.of(context, rootNavigator: true).pop(false),
          child: Text(
              document?.readOnly == true ? 'close-text'.i18n() : 'cancel-text'.i18n()),
        ),
      ],
    );
  }

  Widget _buildError(String message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'ai-workspace-config-load-failed-text'.i18n([message]),
          key: const ValueKey('test-ai-config-error'),
          style: TextStyle(color: Colors.red),
        ),
        const SizedBox(height: 12),
        Button(
          key: const ValueKey('test-ai-config-retry'),
          onPressed: _load,
          child: Text('retry-text'.i18n()),
        ),
      ],
    );
  }

  Widget _buildForm(ToolConfigDocument document) {
    final schemaError = widget.configService.schemaError(widget.tool);
    final matches = _search.isEmpty ? null : _matchingFields(document);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'ai-workspace-config-source-text'.i18n([document.source]),
          key: const ValueKey('test-ai-config-source'),
          style: TextStyle(fontSize: 12, color: secondaryTextColor(context)),
        ),
        const SizedBox(height: 4),
        Text(
          document.schemaFromTool
              ? 'ai-workspace-config-schema-live-text'.i18n()
              : 'ai-workspace-config-schema-inferred-text'.i18n(),
          key: const ValueKey('test-ai-config-schema-origin'),
          style: TextStyle(fontSize: 12, color: secondaryTextColor(context)),
        ),
        if (document.schemaFromTool && document.schema.truncated) ...[
          const SizedBox(height: 4),
          Text(
            'ai-workspace-config-truncated-text'.i18n(),
            style: TextStyle(fontSize: 12, color: secondaryTextColor(context)),
          ),
        ],
        if (!document.schemaFromTool && schemaError != null) ...[
          const SizedBox(height: 4),
          Text(
            'ai-workspace-config-schema-error-text'.i18n([schemaError]),
            key: const ValueKey('test-ai-config-schema-error'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: secondaryTextColor(context)),
          ),
        ],
        if (document.missing) ...[
          const SizedBox(height: 8),
          InfoBar(
            key: const ValueKey('test-ai-config-missing'),
            title: Text('ai-workspace-config-missing-text'.i18n([widget.toolName])),
            severity: InfoBarSeverity.info,
            isLong: true,
          ),
        ],
        if (document.readOnly && document.readOnlyReasonKey != null) ...[
          const SizedBox(height: 8),
          InfoBar(
            key: const ValueKey('test-ai-config-readonly'),
            title: Text(document.readOnlyReasonKey!.i18n()),
            severity: InfoBarSeverity.warning,
            isLong: true,
          ),
        ],
        const SizedBox(height: 12),
        TextBox(
          key: const ValueKey('test-ai-config-search'),
          controller: _searchController,
          placeholder: 'ai-workspace-config-search-placeholder'.i18n(),
          onChanged: (value) => setState(() => _search = value.trim()),
        ),
        const SizedBox(height: 12),
        Flexible(
          child: document.schema.isEmpty
              ? Text(
                  'ai-workspace-config-empty-text'.i18n(),
                  key: const ValueKey('test-ai-config-empty'),
                )
              : matches != null
                  ? (matches.isEmpty
                      ? Text(
                          'ai-workspace-config-no-results-text'.i18n([_search]),
                          key: const ValueKey('test-ai-config-no-results'),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final field in matches)
                              _buildField(document, field, showPath: true),
                          ],
                        ))
                  : ListView(
                      shrinkWrap: true,
                      children: _buildSectionBody(document, document.schema.root),
                    ),
        ),
      ],
    );
  }

  /// Every field whose key, label or description mentions the search text.
  /// The search is what makes a two-thousand-setting schema usable at all.
  List<ConfigField> _matchingFields(ToolConfigDocument document) {
    final needle = _search.toLowerCase();
    return document.schema.fields
        .where((field) =>
            field.key.toLowerCase().contains(needle) ||
            field.label.toLowerCase().contains(needle) ||
            (field.description ?? '').toLowerCase().contains(needle))
        .take(100)
        .toList();
  }

  List<Widget> _buildSectionBody(
      ToolConfigDocument document, ConfigSection section) {
    return [
      for (final field in section.fields) _buildField(document, field),
      for (final child in section.sections)
        if (!child.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Expander(
              key: ValueKey('test-ai-config-section-${child.key}'),
              header: Text(child.label),
              onStateChanged: (open) => setState(() {
                if (open) {
                  _expanded.add(child.key);
                } else {
                  _expanded.remove(child.key);
                }
              }),
              content: _expanded.contains(child.key)
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _buildSectionBody(document, child),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
    ];
  }

  Widget _buildField(ToolConfigDocument document, ConfigField field,
      {bool showPath = false}) {
    final readOnly = document.readOnly || field.readOnly;
    final label = showPath ? field.key : field.label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InfoLabel(
        label: label,
        labelStyle: const TextStyle(fontWeight: FontWeight.w500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildControl(document, field, readOnly),
            if (field.description != null && field.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  field.description!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 12, color: secondaryTextColor(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControl(
      ToolConfigDocument document, ConfigField field, bool readOnly) {
    final key = ValueKey('test-ai-config-field-${field.key}');
    final current = _changes.containsKey(field.key)
        ? _changes[field.key]
        : _originalValue(field);

    switch (field.kind) {
      case ConfigFieldKind.boolean:
        final checked = current is bool
            ? current
            : (field.defaultValue is bool
                ? field.defaultValue as bool
                : false);
        return Align(
          alignment: Alignment.centerLeft,
          child: ToggleSwitch(
            key: key,
            checked: checked,
            onChanged: readOnly ? null : (value) => _record(field, value),
          ),
        );
      case ConfigFieldKind.choice:
        final value = current == null ? null : '$current';
        final items = <String>[
          ...field.choices,
          // A value the tool wrote that its own schema no longer lists still
          // has to be visible rather than silently reset.
          if (value != null && !field.choices.contains(value)) value,
        ];
        return ComboBox<String>(
          key: key,
          value: value,
          placeholder: Text(field.defaultValue == null
              ? 'ai-workspace-config-unset-text'.i18n()
              : '${field.defaultValue}'),
          items: [
            for (final item in items)
              ComboBoxItem<String>(value: item, child: Text(item)),
          ],
          onChanged: readOnly ? null : (value) => _record(field, value),
        );
      case ConfigFieldKind.integer:
      case ConfigFieldKind.number:
      case ConfigFieldKind.text:
      case ConfigFieldKind.json:
        final isJson = field.kind == ConfigFieldKind.json;
        final initial = field.secret
            ? ''
            : current == null
                ? ''
                : isJson
                    ? const JsonEncoder.withIndent('  ').convert(current)
                    : '$current';
        return TextBox(
          key: key,
          controller: _controllerFor(field, initial),
          readOnly: readOnly,
          obscureText: field.secret,
          maxLines: isJson ? 4 : 1,
          placeholder: field.secret
              ? 'ai-workspace-config-secret-placeholder'.i18n()
              : field.defaultValue == null
                  ? null
                  : 'ai-workspace-config-default-placeholder'
                      .i18n(['${field.defaultValue}']),
          onChanged: readOnly
              ? null
              : (text) => _record(field, _parse(field, text)),
        );
    }
  }

  /// Turns typed text into the value the config file should hold. Invalid
  /// input is kept as the raw string and rejected by [_validate] on save, so
  /// a half-typed number never silently becomes a string in the file.
  Object? _parse(ConfigField field, String text) {
    final trimmed = text.trim();
    // An emptied field means "remove this setting", which both writers spell
    // as null — OpenClaw's patch deletes a null path, and a whole-file write
    // drops it on the merge.
    if (trimmed.isEmpty) return null;
    switch (field.kind) {
      case ConfigFieldKind.integer:
        return int.tryParse(trimmed) ?? trimmed;
      case ConfigFieldKind.number:
        return num.tryParse(trimmed) ?? trimmed;
      case ConfigFieldKind.json:
        try {
          return jsonDecode(trimmed);
        } catch (_) {
          return _InvalidJson(trimmed);
        }
      default:
        return trimmed;
    }
  }

  /// The first field whose typed value cannot be written, or null.
  String? _validate() {
    for (final entry in _changes.entries) {
      final field = _document!.schema.fieldAt(entry.key);
      if (field == null) continue;
      final value = entry.value;
      if (value is _InvalidJson) {
        return 'ai-workspace-config-invalid-json-text'.i18n([field.label]);
      }
      if ((field.kind == ConfigFieldKind.integer ||
              field.kind == ConfigFieldKind.number) &&
          value is! num &&
          value != null) {
        return 'ai-workspace-config-invalid-number-text'.i18n([field.label]);
      }
    }
    return null;
  }

  Future<void> _save() async {
    final problem = _validate();
    if (problem != null) {
      Notify.message(problem);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.configService.save(widget.tool, _changes);
      if (!mounted) return;
      Notify.message(
        'ai-workspace-config-saved-text'.i18n([widget.toolName]),
        severity: InfoBarSeverity.success,
      );
      Navigator.of(context, rootNavigator: true).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      Notify.message('ai-workspace-config-save-failed-text'.i18n([e.toString()]));
    }
  }
}

/// Marker for text that was meant to be JSON and is not. Kept out of the
/// changes as a value of its own so [_AiWorkspaceConfigDialogState._validate]
/// can name the field rather than the app writing `"{ broken"` as a string.
class _InvalidJson {
  final String raw;
  const _InvalidJson(this.raw);
}
