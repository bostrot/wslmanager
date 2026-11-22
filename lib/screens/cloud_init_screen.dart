import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/empty_state.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'package:wsl2distromanager/screens/actions_screen.dart' show Editor;

/// The saved cloud-init configurations: what runs on an instance's first
/// boot when it is picked on the Add instance page (bostrot/ai-tasks#76).
///
/// A list of [Expander]s the way the Snippets screen is, because the two
/// are the same kind of thing — a named text the user keeps and applies to
/// an instance — and should not look like two different apps.
class CloudInitPage extends StatefulWidget {
  const CloudInitPage({super.key});

  @override
  State<CloudInitPage> createState() => _CloudInitPageState();
}

class _CloudInitPageState extends State<CloudInitPage> {
  final CloudInitStore _store = CloudInitStore.instance;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'cloud_init');
  }

  // The list follows the store on its own; nothing here needs a setState.
  Future<void> _open({CloudInitConfig? existing}) =>
      router.pushNamed('cloudinit-editor', extra: existing);

  /// A copy under a free name, so a working configuration can be varied
  /// without retyping it.
  Future<void> _duplicate(CloudInitConfig item) async {
    var name = '${item.name}-copy';
    var n = 2;
    while (_store.byName(name) != null) {
      name = '${item.name}-copy$n';
      n++;
    }
    await _store.save(CloudInitConfig(
      name: name,
      description: item.description,
      content: item.content,
    ));
  }

  void _confirmDelete(BuildContext context, CloudInitConfig item) {
    dialog(
      item: item,
      // This page is not the home screen, so the dialog needs a context
      // of its own (audit ST-04).
      hostContext: context,
      title: 'deletecloudinitquestion-text'.i18n([item.name]),
      body: 'deletecloudinitbody-text'.i18n(),
      submitText: 'delete-text'.i18n(),
      submitInput: false,
      submitStyle: ButtonStyle(
        backgroundColor: WidgetStateProperty.all(Colors.red),
        foregroundColor: WidgetStateProperty.all(Colors.white),
      ),
      onSubmit: (_) => _store.remove(item.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('cloudinit-text'.i18n(),
                      style: FluentTheme.of(context).typography.titleLarge),
                  const SizedBox(height: 4),
                  Text('cloudinitsubtitle-text'.i18n(),
                      style: TextStyle(color: secondaryTextColor(context))),
                ],
              ),
            ),
            const SizedBox(width: 16),
            FilledButton(
              key: const ValueKey('test-cloudinit-new'),
              onPressed: () => _open(),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(FluentIcons.add, size: 14),
                const SizedBox(width: 8),
                Text('newcloudinit-text'.i18n()),
              ]),
            ),
          ],
        ),
      ),
      content: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final items = _store.items;
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: EmptyState(
                key: const ValueKey('test-cloudinit-empty'),
                icon: FluentIcons.cloud_add,
                title: 'cloudinitempty-text'.i18n(),
                body: 'cloudinitemptybody-text'.i18n(),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: items.length,
            itemBuilder: (context, index) => _row(context, items[index]),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, CloudInitConfig item) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Expander(
        key: ValueKey('test-cloudinit-row-${item.name}'),
        header: RichText(
          text: TextSpan(children: [
            TextSpan(
              text: item.name,
              style: TextStyle(
                color: FluentTheme.of(context).resources.textFillColorPrimary,
              ),
            ),
            if (item.description.isNotEmpty)
              TextSpan(
                text: '  ${item.description}',
                style: TextStyle(
                  fontSize: 13.0,
                  color: secondaryTextColor(context),
                ),
              ),
          ]),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MergeSemantics(
              child: Tooltip(
                message: 'edit-text'.i18n(),
                child: IconButton(
                  key: ValueKey('test-cloudinit-edit-${item.name}'),
                  icon: const Icon(FluentIcons.edit),
                  onPressed: () => _open(existing: item),
                ),
              ),
            ),
            MergeSemantics(
              child: Tooltip(
                message: 'cloudinitduplicate-text'.i18n(),
                child: IconButton(
                  key: ValueKey('test-cloudinit-duplicate-${item.name}'),
                  icon: const Icon(FluentIcons.copy),
                  onPressed: () => _duplicate(item),
                ),
              ),
            ),
            MergeSemantics(
              child: Tooltip(
                message: 'delete-text'.i18n(),
                child: IconButton(
                  key: ValueKey('test-cloudinit-delete-${item.name}'),
                  icon: Icon(FluentIcons.delete,
                      color: destructiveColor(context)),
                  onPressed: () => _confirmDelete(context, item),
                ),
              ),
            ),
          ],
        ),
        content: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cardFillColor(context),
            border: Border.all(color: surfaceBorderColor(context)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            item.content,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5),
          ),
        ),
      ),
    );
  }
}

/// Writes one configuration: a name, a line about it, and the user-data
/// itself in a YAML-highlighted editor.
class CloudInitEditorPage extends StatefulWidget {
  const CloudInitEditorPage({super.key, this.existing});

  /// The configuration being edited, or null when writing a new one.
  final CloudInitConfig? existing;

  @override
  State<CloudInitEditorPage> createState() => _CloudInitEditorPageState();
}

class _CloudInitEditorPageState extends State<CloudInitEditorPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _content = CodeLineEditingController();
  // Required by the shared Editor's signature; it does not read it.
  final _scroll = ScrollController();

  String? _error;
  bool _saving = false;

  /// Whether the document is a `#!` script rather than YAML — the
  /// highlighter follows it. Kept as state and updated off the controller
  /// after the frame, because the editor notifies its controller while it
  /// is building, where a plain listener-driven rebuild is not allowed.
  bool _isScript = false;

  final CloudInitStore _store = CloudInitStore.instance;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'cloud_init_editor');
    final existing = widget.existing;
    if (existing != null) {
      _name.text = existing.name;
      _description.text = existing.description;
      _content.text = existing.content;
    } else {
      _content.text = kCloudInitStarter;
    }
    _isScript = _documentIsScript();
    _content.addListener(_syncLanguage);
  }

  @override
  void dispose() {
    _content.removeListener(_syncLanguage);
    _name.dispose();
    _description.dispose();
    _content.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _documentIsScript() =>
      _content.codeLines.length > 0 &&
      _content.codeLines.first.text.trimLeft().startsWith('#!');

  void _syncLanguage() {
    if (_documentIsScript() == _isScript) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final isScript = _documentIsScript();
      if (isScript != _isScript) setState(() => _isScript = isScript);
    });
  }

  String? _validate() {
    final name = _name.text.trim();
    if (name.isEmpty) return 'cloudinitnamerequired-text'.i18n();
    if (!isValidCloudInitName(name)) return 'cloudinitnameinvalid-text'.i18n();
    if (name != widget.existing?.name && _store.byName(name) != null) {
      return 'cloudinitnametaken-text'.i18n();
    }
    final problem = validateCloudInitUserData(_content.text);
    if (problem != null) {
      return problem.detail.isEmpty
          ? problem.key.i18n()
          : problem.key.i18n([problem.detail]);
    }
    return null;
  }

  Future<void> _save() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    await _store.save(
      CloudInitConfig(
        name: _name.text.trim(),
        description: _description.text.trim(),
        content: _content.text,
      ),
      previousName: widget.existing?.name,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    Notify.message('cloudinitsaved-text'.i18n(),
        severity: InfoBarSeverity.success);
    _leave();
  }

  /// Back to the list: a pop when the editor was pushed from it, the list
  /// itself when it was reached any other way.
  void _leave() {
    if (router.canPop()) {
      router.pop();
    } else {
      router.goNamed('cloudinit');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                (widget.existing == null
                        ? 'newcloudinit-text'
                        : 'editcloudinit-text')
                    .i18n(),
                style: FluentTheme.of(context).typography.titleLarge),
            const SizedBox(height: 4),
            Text('cloudinitsubtitle-text'.i18n(),
                style: TextStyle(color: secondaryTextColor(context))),
          ],
        ),
      ),
      content: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _metadataCard(context),
            const SizedBox(height: 14),
            // The Snippets editor's frame with a YAML palette, since
            // `#cloud-config` is YAML — and bash for the `#!` scripts
            // cloud-init also takes, chosen off the first line and
            // following it as the user types.
            Editor(
              contentController: _content,
              scrollController: _scroll,
              lineNumbers: '',
              lineNum: 1,
              label: 'cloudinituserdata-text'.i18n(),
              hint: '#cloud-config',
              heightFactor: 0.55,
              editorKey: const ValueKey('test-cloudinit-editor'),
              languages: {
                _isScript ? 'bash' : 'yaml': CodeHighlightThemeMode(
                    mode: _isScript ? langBash : langYaml),
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(_error!,
                    key: const ValueKey('test-cloudinit-error'),
                    style: TextStyle(
                        color: destructiveColor(context), fontSize: 12)),
              ),
          ],
        ),
      ),
      bottomBar: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
        child: Row(
          children: [
            const Spacer(),
            Button(
              onPressed: _saving ? null : _leave,
              child: Text('close-text'.i18n()),
            ),
            const SizedBox(width: 8),
            BusyButton(
              key: const ValueKey('test-cloudinit-save'),
              filled: true,
              label: 'save-text'.i18n(),
              busyLabel: 'save-text'.i18n(),
              busy: _saving,
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }

  Widget _metadataCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardFillColor(context),
        border: Border.all(color: surfaceBorderColor(context)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final twoUp = constraints.maxWidth > 720;
        final fieldWidth =
            twoUp ? (constraints.maxWidth - 16) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            SizedBox(
              width: fieldWidth,
              child: InfoLabel(
                label: 'name-text'.i18n(),
                child: TextBox(
                  key: const ValueKey('test-cloudinit-name'),
                  controller: _name,
                  placeholder: 'dev-tools',
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                ),
              ),
            ),
            SizedBox(
              width: fieldWidth,
              child: InfoLabel(
                label: 'description-text'.i18n(),
                child: TextBox(
                  key: const ValueKey('test-cloudinit-description'),
                  controller: _description,
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}
