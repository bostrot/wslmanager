import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:re_editor/re_editor.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/share_snippet_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'package:wsl2distromanager/screens/actions_screen.dart' show Editor;

/// The distros the community repo's scripts declare.
const List<String> kKnownDistros = [
  'Debian',
  'Ubuntu',
  'Alpine',
  'Fedora',
  'Arch',
];

/// Writes one snippet, in the shape the community repo expects.
///
/// The old form asked for a name and a body. A script in the repo is a
/// folder holding `info.yml` and `script.noshell`, so anything shared from
/// here had to have its metadata invented by hand afterwards; the fields
/// below are exactly that file's keys.
class SnippetEditorPage extends StatefulWidget {
  const SnippetEditorPage({super.key, this.existing});

  /// The snippet being edited, or null when writing a new one.
  final QuickActionItem? existing;

  @override
  State<SnippetEditorPage> createState() => _SnippetEditorPageState();
}

class _SnippetEditorPageState extends State<SnippetEditorPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _version = TextEditingController(text: '1.0.0');
  final _author = TextEditingController();
  final _license = TextEditingController(text: 'MIT');
  final _git = TextEditingController();
  final _content = CodeLineEditingController();
  final _scroll = ScrollController();

  final Set<String> _distros = {};
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'snippet_editor');
    final existing = widget.existing;
    if (existing != null) {
      _name.text = existing.name;
      _description.text = existing.description;
      if (existing.version.isNotEmpty) _version.text = existing.version;
      _author.text = existing.author;
      if (existing.license.isNotEmpty) _license.text = existing.license;
      _git.text = existing.git;
      _content.text = existing.content;
      final raw = existing.distro;
      if (raw is List) {
        _distros.addAll(raw.map((e) => e.toString().trim()));
      } else if (raw is String && raw.trim().isNotEmpty) {
        _distros.add(raw.trim());
      }
    }
    _author.text = _author.text.isEmpty
        ? (prefs.getString('SnippetAuthor') ?? '')
        : _author.text;
  }

  @override
  void dispose() {
    for (final c in [_name, _description, _version, _author, _license, _git]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  QuickActionItem _buildItem() => QuickActionItem(
        name: _name.text.trim(),
        description: _description.text.trim(),
        version: _version.text.trim(),
        author: _author.text.trim(),
        license: _license.text.trim(),
        git: _git.text.trim(),
        distro: _distros.length == 1 ? _distros.first : _distros.toList(),
        // Carried over rather than rebuilt: the editor has no field for the
        // `env:` block, and dropping it would cost an edited community
        // snippet the descriptions its run dialog is built from.
        env: widget.existing?.env ?? const [],
        content: _content.text,
      );

  /// The name doubles as the folder name in the community repo, so it has to
  /// survive as a path segment.
  String? _validate() {
    if (_name.text.trim().isEmpty) return 'snippetnamerequired-text'.i18n();
    if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(_name.text.trim())) {
      return 'snippetnameinvalid-text'.i18n();
    }
    if (_content.text.trim().isEmpty) {
      return 'snippetcontentrequired-text'.i18n();
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
    final item = _buildItem();
    QuickAction.addToPrefs(item);
    // Remembered so the next snippet does not ask again.
    if (item.author.isNotEmpty) {
      await prefs.setString('SnippetAuthor', item.author);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    Notify.message('snippetsaved-text'.i18n(), severity: InfoBarSeverity.success);
    router.pop();
  }

  Future<void> _share() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final item = _buildItem();
    QuickAction.addToPrefs(item);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => ShareSnippetDialog(item: item),
    );
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
                        ? 'newsnippet-text'
                        : 'editsnippet-text')
                    .i18n(),
                style: FluentTheme.of(context).typography.titleLarge),
            const SizedBox(height: 4),
            Text('snippeteditorsubtitle-text'.i18n(),
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
            Editor(
              contentController: _content,
              scrollController: _scroll,
              lineNumbers: '',
              lineNum: 1,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(_error!,
                    key: const ValueKey('test-snippet-error'),
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
            // Sharing saves first: the PR is built from what is stored, so
            // the two can never disagree.
            Button(
              key: const ValueKey('test-snippet-share'),
              onPressed: _saving ? null : _share,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(FluentIcons.share, size: 14),
                const SizedBox(width: 8),
                Text('sharesnippet-text'.i18n()),
              ]),
            ),
            const Spacer(),
            Button(
              onPressed: _saving ? null : () => router.pop(),
              child: Text('close-text'.i18n()),
            ),
            const SizedBox(width: 8),
            BusyButton(
              key: const ValueKey('test-snippet-save'),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(builder: (context, constraints) {
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
                    label: 'settingname-text'.i18n(),
                    child: TextBox(
                      key: const ValueKey('test-snippet-name'),
                      controller: _name,
                      placeholder: 'my-script',
                      onChanged: (_) {
                        if (_error != null) setState(() => _error = null);
                      },
                    ),
                  ),
                ),
                SizedBox(
                  width: fieldWidth,
                  child: InfoLabel(
                    label: 'snippetmetaauthor-text'.i18n(),
                    child: TextBox(
                      key: const ValueKey('test-snippet-author'),
                      controller: _author,
                    ),
                  ),
                ),
                SizedBox(
                  width: constraints.maxWidth,
                  child: InfoLabel(
                    label: 'snippetdescription-text'.i18n(),
                    child: TextBox(
                      key: const ValueKey('test-snippet-description'),
                      controller: _description,
                      maxLines: 2,
                    ),
                  ),
                ),
                SizedBox(
                  width: twoUp
                      ? (constraints.maxWidth - 32) / 3
                      : constraints.maxWidth,
                  child: InfoLabel(
                    label: 'snippetversion-text'.i18n(),
                    child: TextBox(controller: _version),
                  ),
                ),
                SizedBox(
                  width: twoUp
                      ? (constraints.maxWidth - 32) / 3
                      : constraints.maxWidth,
                  child: InfoLabel(
                    label: 'snippetlicense-text'.i18n(),
                    child: TextBox(controller: _license),
                  ),
                ),
                SizedBox(
                  width: twoUp
                      ? (constraints.maxWidth - 32) / 3
                      : constraints.maxWidth,
                  child: InfoLabel(
                    label: 'snippetgit-text'.i18n(),
                    child: TextBox(
                      controller: _git,
                      placeholder: 'https://github.com/...',
                    ),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: 14),
          Text('snippetdistros-text'.i18n(),
              style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final distro in kKnownDistros)
                Checkbox(
                  checked: _distros.contains(distro),
                  onChanged: (value) => setState(() {
                    if (value ?? false) {
                      _distros.add(distro);
                    } else {
                      _distros.remove(distro);
                    }
                  }),
                  content: Text(distro),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
