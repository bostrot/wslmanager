import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:wsl2distromanager/api/provisioning.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/empty_state.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:wsl2distromanager/dialogs/guest_access_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'package:wsl2distromanager/screens/actions_screen.dart' show Editor;

/// The saved playbooks: an instance's state as code, applied to any
/// existing instance as often as needed (bostrot/ai-tasks#78).
///
/// Laid out like the Snippets and Cloud-init pages — a list of expanders
/// with the document inside — because all three keep a named text the user
/// applies to an instance. What sets this one apart is the record under
/// each document: which instances it was applied to, when, and how it went.
class PlaybooksPage extends StatefulWidget {
  const PlaybooksPage({super.key});

  @override
  State<PlaybooksPage> createState() => _PlaybooksPageState();
}

class _PlaybooksPageState extends State<PlaybooksPage> {
  final PlaybookStore _store = PlaybookStore.instance;
  final PlaybookRunStore _runs = PlaybookRunStore.instance;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'playbooks');
  }

  Future<void> _open({Playbook? existing}) =>
      router.pushNamed('playbook-editor', extra: existing);

  Future<void> _apply(Playbook item) =>
      router.pushNamed('playbook-apply', extra: item);

  Future<void> _duplicate(Playbook item) async {
    var name = '${item.name}-copy';
    var n = 2;
    while (_store.byName(name) != null) {
      name = '${item.name}-copy$n';
      n++;
    }
    await _store.save(Playbook(
      name: name,
      description: item.description,
      content: item.content,
    ));
  }

  void _confirmDelete(BuildContext context, Playbook item) {
    dialog(
      item: item,
      hostContext: context,
      title: 'deleteplaybookquestion-text'.i18n([item.name]),
      body: 'deleteplaybookbody-text'.i18n(),
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
                  Text('playbooks-text'.i18n(),
                      style: FluentTheme.of(context).typography.titleLarge),
                  const SizedBox(height: 4),
                  Text('playbookssubtitle-text'.i18n(),
                      style: TextStyle(color: secondaryTextColor(context))),
                ],
              ),
            ),
            const SizedBox(width: 16),
            FilledButton(
              key: const ValueKey('test-playbook-new'),
              onPressed: () => _open(),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(FluentIcons.add, size: 14),
                const SizedBox(width: 8),
                Text('newplaybook-text'.i18n()),
              ]),
            ),
          ],
        ),
      ),
      content: ListenableBuilder(
        listenable: Listenable.merge([_store, _runs]),
        builder: (context, _) {
          final items = _store.items;
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: EmptyState(
                key: const ValueKey('test-playbook-empty'),
                icon: FluentIcons.build_definition,
                title: 'playbooksempty-text'.i18n(),
                body: 'playbooksemptybody-text'.i18n(),
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

  Widget _row(BuildContext context, Playbook item) {
    final runs = _runs.forPlaybook(item.name);
    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Expander(
        key: ValueKey('test-playbook-row-${item.name}'),
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
                message: 'applyplaybook-text'.i18n(),
                child: IconButton(
                  key: ValueKey('test-playbook-apply-${item.name}'),
                  icon: const Icon(FluentIcons.play),
                  onPressed: () => _apply(item),
                ),
              ),
            ),
            MergeSemantics(
              child: Tooltip(
                message: 'edit-text'.i18n(),
                child: IconButton(
                  key: ValueKey('test-playbook-edit-${item.name}'),
                  icon: const Icon(FluentIcons.edit),
                  onPressed: () => _open(existing: item),
                ),
              ),
            ),
            MergeSemantics(
              child: Tooltip(
                message: 'playbookduplicate-text'.i18n(),
                child: IconButton(
                  key: ValueKey('test-playbook-duplicate-${item.name}'),
                  icon: const Icon(FluentIcons.copy),
                  onPressed: () => _duplicate(item),
                ),
              ),
            ),
            MergeSemantics(
              child: Tooltip(
                message: 'delete-text'.i18n(),
                child: IconButton(
                  key: ValueKey('test-playbook-delete-${item.name}'),
                  icon: Icon(FluentIcons.delete,
                      color: destructiveColor(context)),
                  onPressed: () => _confirmDelete(context, item),
                ),
              ),
            ),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
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
            const SizedBox(height: 10),
            Text('playbooklastruns-text'.i18n(),
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            if (runs.isEmpty)
              Text('playbooknorun-text'.i18n(),
                  key: ValueKey('test-playbook-norun-${item.name}'),
                  style: TextStyle(
                      fontSize: 12.5, color: secondaryTextColor(context)))
            else
              for (final run in runs) _runLine(context, run),
          ],
        ),
      ),
    );
  }

  Widget _runLine(BuildContext context, PlaybookRun run) {
    final summary = 'playbooksummary-text'.i18n([
      '${run.ok}',
      '${run.changed}',
      '${run.failed}',
      '${run.skipped}',
    ]);
    final mode =
        run.check ? 'playbookrunchecked-text' : 'playbookrunapplied-text';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2.0),
      child: Row(
        key: ValueKey('test-playbook-run-${run.playbook}-${run.instance}'),
        children: [
          Icon(statusIcon(run.status),
              size: 13, color: statusColor(context, run.status)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${distroLabel(run.instance)}  ·  ${mode.i18n()} ${formatRunTime(run.at)}  ·  $summary',
              style: const TextStyle(fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Ansible's icons for its four words: a tick, a pencil, a cross, a dash.
IconData statusIcon(TaskStatus status) {
  switch (status) {
    case TaskStatus.ok:
      return FluentIcons.check_mark;
    case TaskStatus.changed:
      return FluentIcons.edit;
    case TaskStatus.failed:
      return FluentIcons.error_badge;
    case TaskStatus.skipped:
      return FluentIcons.remove;
  }
}

Color statusColor(BuildContext context, TaskStatus status) {
  switch (status) {
    case TaskStatus.ok:
      return Colors.green;
    case TaskStatus.changed:
      return Colors.orange;
    case TaskStatus.failed:
      return destructiveColor(context);
    case TaskStatus.skipped:
      return secondaryTextColor(context);
  }
}

/// `2026-09-14 11:05`, local time — the run list is a log, and a log
/// carries the clock time, not "3 hours ago".
String formatRunTime(DateTime at) {
  final t = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Writes one playbook: a name, a line about it, and the document in a
/// YAML-highlighted editor.
class PlaybookEditorPage extends StatefulWidget {
  const PlaybookEditorPage({super.key, this.existing});

  /// The playbook being edited, or null when writing a new one.
  final Playbook? existing;

  @override
  State<PlaybookEditorPage> createState() => _PlaybookEditorPageState();
}

class _PlaybookEditorPageState extends State<PlaybookEditorPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _content = CodeLineEditingController();
  // Required by the shared Editor's signature; it does not read it.
  final _scroll = ScrollController();

  String? _error;
  bool _saving = false;

  /// What the form last held on disk, so leaving can tell an edit from a
  /// look. The guard asks before a pane click throws the document away
  /// (audit ST-01).
  String _savedName = '';
  String _savedDescription = '';
  String _savedContent = '';
  late final Future<bool> Function() _leaveGuard = _confirmLeave;

  final PlaybookStore _store = PlaybookStore.instance;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'playbook_editor');
    final existing = widget.existing;
    if (existing != null) {
      _name.text = existing.name;
      _description.text = existing.description;
      _content.text = existing.content;
    } else {
      _content.text = kPlaybookStarter;
    }
    _markSaved();
    UnsavedChangesGuard.register(_leaveGuard);
  }

  void _markSaved() {
    _savedName = _name.text;
    _savedDescription = _description.text;
    _savedContent = _content.text;
  }

  bool get _dirty =>
      _name.text != _savedName ||
      _description.text != _savedDescription ||
      _content.text != _savedContent;

  /// Asked by [UnsavedChangesGuard] on every route out of this page, and by
  /// the Close button.
  Future<bool> _confirmLeave() async {
    if (!_dirty || !mounted) return true;
    final choice = await showUnsavedChangesDialog(context);
    switch (choice) {
      case UnsavedChangesChoice.cancel:
        return false;
      case UnsavedChangesChoice.discard:
        return true;
      case UnsavedChangesChoice.save:
        return _saveOnly();
    }
  }

  @override
  void dispose() {
    UnsavedChangesGuard.release(_leaveGuard);
    _name.dispose();
    _description.dispose();
    _content.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String? _validate() {
    final name = _name.text.trim();
    if (name.isEmpty) return 'playbooknamerequired-text'.i18n();
    if (!isValidPlaybookName(name)) return 'playbooknameinvalid-text'.i18n();
    if (name != widget.existing?.name && _store.byName(name) != null) {
      return 'playbooknametaken-text'.i18n();
    }
    final problem = validatePlaybook(_content.text);
    if (problem != null) {
      return problem.detail.isEmpty
          ? problem.key.i18n()
          : problem.key.i18n([problem.detail]);
    }
    return null;
  }

  /// Saves when the form is valid; false (with the error shown) when not.
  Future<bool> _saveOnly() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return false;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    await _store.save(
      Playbook(
        name: _name.text.trim(),
        description: _description.text.trim(),
        content: _content.text,
      ),
      previousName: widget.existing?.name,
    );
    _markSaved();
    if (!mounted) return true;
    setState(() => _saving = false);
    Notify.message('playbooksaved-text'.i18n(),
        severity: InfoBarSeverity.success);
    return true;
  }

  Future<void> _save() async {
    if (await _saveOnly()) _leave();
  }

  Future<void> _close() async {
    if (await _confirmLeave()) _leave();
  }

  void _leave() {
    if (router.canPop()) {
      router.pop();
    } else {
      router.goNamed('playbooks');
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
                        ? 'newplaybook-text'
                        : 'editplaybook-text')
                    .i18n(),
                style: FluentTheme.of(context).typography.titleLarge),
            const SizedBox(height: 4),
            Text('playbookssubtitle-text'.i18n(),
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
              label: 'playbookdocument-text'.i18n(),
              hint: '#cloud-config',
              heightFactor: 0.55,
              editorKey: const ValueKey('test-playbook-editor'),
              languages: {'yaml': CodeHighlightThemeMode(mode: langYaml)},
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(_error!,
                    key: const ValueKey('test-playbook-error'),
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
              key: const ValueKey('test-playbook-close'),
              onPressed: _saving ? null : _close,
              child: Text('close-text'.i18n()),
            ),
            const SizedBox(width: 8),
            BusyButton(
              key: const ValueKey('test-playbook-save'),
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
                  key: const ValueKey('test-playbook-name'),
                  controller: _name,
                  placeholder: 'dev-box',
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
                  key: const ValueKey('test-playbook-description'),
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

/// Applies one playbook to an instance and shows every step as it runs —
/// the play-by-play a terminal would give, kept on a page so the result
/// can be read afterwards.
class PlaybookApplyPage extends StatefulWidget {
  const PlaybookApplyPage({super.key, required this.playbook, this.api});

  final Playbook playbook;

  /// The backend to run in; the host's when null. Tests inject a fake.
  final VmBackend? api;

  @override
  State<PlaybookApplyPage> createState() => _PlaybookApplyPageState();
}

class _PlaybookApplyPageState extends State<PlaybookApplyPage> {
  List<String> _instances = [];
  String? _instance;
  bool _check = false;
  bool _running = false;
  bool _stopRequested = false;
  ProvisioningReport? _report;

  /// The steps the document compiles to, shown before the run so the user
  /// sees what Apply will do.
  late final List<ProvisioningTask> _plan;

  VmBackend get _api => widget.api ?? vmBackend();

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'playbook_apply');
    try {
      _plan = compilePlaybook(widget.playbook.content);
    } on FormatException {
      _plan = const [];
    }
    // Only when injected or in a real app run: a widget test that pumps
    // this page must not spawn wsl.exe from initState.
    if (widget.api != null ||
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      _api.list(false).then((instances) {
        if (!mounted) return;
        setState(() {
          _instances = instances.all;
          _instance ??= _instances.isEmpty ? null : _instances.first;
        });
      }).catchError((_) {});
    }
  }

  Future<void> _run() async {
    final instance = _instance;
    if (instance == null || _running) return;
    plausible.event(name: _check ? 'playbook_check' : 'playbook_apply');
    // An Apple VM installed from an ISO has no key for the app yet; this
    // installs it once instead of letting every step fail at "Permission
    // denied".
    if (!await ensureGuestAccess(context, _api, instance)) return;
    if (!mounted) return;
    setState(() {
      _running = true;
      _stopRequested = false;
      _report = null;
    });
    final report = await ProvisioningRunner(_api).apply(
      instance,
      widget.playbook,
      check: _check,
      tasks: _plan,
      onProgress: (r) {
        if (mounted) setState(() => _report = r);
      },
      shouldStop: () => _stopRequested,
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      _report = report;
    });
    if (report.failed) {
      Notify.message('playbookfailed-text'.i18n([distroLabel(instance)]),
          severity: InfoBarSeverity.error);
    } else if (report.stopped) {
      Notify.message('playbookstopped-text'.i18n(),
          severity: InfoBarSeverity.warning);
    } else {
      Notify.message('playbookdone-text'.i18n([distroLabel(instance)]),
          severity: InfoBarSeverity.success);
    }
  }

  void _leave() {
    if (router.canPop()) {
      router.pop();
    } else {
      router.goNamed('playbooks');
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    // Steps before this one have a result; this one is the running one.
    final done = report?.results.length ?? 0;
    return ScaffoldPage(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('applyplaybooktitle-text'.i18n([widget.playbook.name]),
                style: FluentTheme.of(context).typography.titleLarge),
            const SizedBox(height: 4),
            Text(
                widget.playbook.description.isNotEmpty
                    ? widget.playbook.description
                    : 'playbookssubtitle-text'.i18n(),
                style: TextStyle(color: secondaryTextColor(context))),
          ],
        ),
      ),
      content: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _targetCard(context),
            const SizedBox(height: 14),
            Text('playbooksteps-text'.i18n(),
                style: const TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 6),
            if (_plan.isEmpty)
              Text('applyplaybooknosteps-text'.i18n(),
                  key: const ValueKey('test-playbook-nosteps'),
                  style: TextStyle(color: secondaryTextColor(context))),
            for (var i = 0; i < _plan.length; i++)
              _stepRow(
                  context, i, _plan[i], i < done ? report!.results[i] : null,
                  running: _running && i == done),
            if (report != null && report.finished) ...[
              const SizedBox(height: 10),
              Text(
                _summary(report),
                key: const ValueKey('test-playbook-summary'),
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ],
        ),
      ),
      bottomBar: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
        child: Row(
          children: [
            if (_running)
              Button(
                key: const ValueKey('test-playbook-stop'),
                onPressed: _stopRequested
                    ? null
                    : () => setState(() => _stopRequested = true),
                child: Text('applyplaybookstop-text'.i18n()),
              ),
            const Spacer(),
            Button(
              onPressed: _running ? null : _leave,
              child: Text('close-text'.i18n()),
            ),
            const SizedBox(width: 8),
            BusyButton(
              key: const ValueKey('test-playbook-run'),
              filled: true,
              label:
                  (_check ? 'applyplaybookcheckrun-text' : 'applyplaybook-text')
                      .i18n(),
              busyLabel: 'applyplaybookrunning-text'.i18n(),
              busy: _running,
              onPressed:
                  _running || _instance == null || _plan.isEmpty ? null : _run,
            ),
          ],
        ),
      ),
    );
  }

  String _summary(ProvisioningReport report) {
    final counts = 'playbooksummary-text'.i18n([
      '${report.count(TaskStatus.ok)}',
      '${report.count(TaskStatus.changed)}',
      '${report.count(TaskStatus.failed)}',
      '${report.count(TaskStatus.skipped)}',
    ]);
    if (report.failed) {
      final failed =
          report.results.lastWhere((r) => r.status == TaskStatus.failed);
      return '${'playbookfailedat-text'.i18n([
            failed.task.titleKey.i18n(failed.task.titleArgs)
          ])} $counts';
    }
    if (report.stopped) return '${'playbookstopped-text'.i18n()} $counts';
    return counts;
  }

  Widget _targetCard(BuildContext context) {
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
          InfoLabel(
            label: 'applyplaybookinstance-text'.i18n(),
            child: _instances.isEmpty
                ? Text('applyplaybooknoinstances-text'.i18n(),
                    key: const ValueKey('test-playbook-noinstances'),
                    style: TextStyle(color: secondaryTextColor(context)))
                : ComboBox<String>(
                    key: const ValueKey('test-playbook-instance'),
                    value: _instance,
                    isExpanded: true,
                    items: [
                      for (final name in _instances)
                        ComboBoxItem(
                            value: name, child: Text(distroLabel(name))),
                    ],
                    onChanged: _running
                        ? null
                        : (value) => setState(() => _instance = value),
                  ),
          ),
          const SizedBox(height: 12),
          Checkbox(
            key: const ValueKey('test-playbook-check'),
            checked: _check,
            onChanged: _running
                ? null
                : (value) => setState(() => _check = value ?? false),
            content: Text('applyplaybookcheck-text'.i18n()),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(BuildContext context, int index, ProvisioningTask task,
      TaskResult? result,
      {required bool running}) {
    final title = task.titleKey.i18n(task.titleArgs);
    final Widget leading;
    if (running) {
      leading = const SizedBox(
          width: 14, height: 14, child: ProgressRing(strokeWidth: 2));
    } else if (result != null) {
      leading = Icon(statusIcon(result.status),
          size: 14, color: statusColor(context, result.status));
    } else {
      leading = Icon(FluentIcons.circle_ring,
          size: 14, color: secondaryTextColor(context));
    }
    final statusText =
        result == null ? '' : 'playbookstatus${result.status.name}-text'.i18n();
    final header = Row(children: [
      leading,
      const SizedBox(width: 8),
      Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
      if (statusText.isNotEmpty)
        Text(statusText,
            key: ValueKey('test-playbook-step-$index-status'),
            style: TextStyle(
                fontSize: 12.5,
                color: result == null
                    ? null
                    : statusColor(context, result.status))),
    ]);
    if (result == null || result.output.isEmpty) {
      return Padding(
        key: ValueKey('test-playbook-step-$index'),
        padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 8.0),
        child: header,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4.0),
      child: Expander(
        key: ValueKey('test-playbook-step-$index'),
        // A failed step is the one the user has to read.
        initiallyExpanded: result.status == TaskStatus.failed,
        header: header,
        content: SelectableText(
          result.output,
          style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
        ),
      ),
    );
  }
}
