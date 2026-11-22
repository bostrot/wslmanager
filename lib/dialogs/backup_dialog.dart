// The user-facing half of [BackupService]: pick a folder, tick the instances,
// watch it work (bostrot/ai-tasks#89).
//
// A dialog rather than a screen, unlike `.wsl` packaging, and the nav pane is
// the reason. Packaging earned a destination because it is a multi-step
// editor — the distribution config has to be right before the export freezes
// it in. This is one folder and a list of checkboxes; what it would cost is
// an eighth pane entry, and the pane already runs out of height before it
// runs out of entries at 800x600 (see the note on Cloud in nav/panelist.dart).
// So it opens from Settings, from the "Back up & restore" section's two
// buttons (components/backup_settings_section.dart) — not from the instance
// list, where a control acting on every instance reads as one more
// per-instance action.
//
// The long run stays inside the dialog instead of being handed to the
// notification bar: it is minutes of work per instance, and the one question
// the user has throughout is "which one is it on now, and did any of the
// earlier ones fail". Both live here, next to the Cancel that stops the run
// between instances.

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/backup_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// How the dialog reaches the backend and the filesystem. The seam the widget
/// tests replace, matching `package_screen.dart`'s [packagerBuilder].
BackupService Function()? backupServiceBuilder;

/// The folder the picker buttons return, so a test does not have to drive a
/// native directory dialog. Null means "ask the user".
String? Function()? backupFolderPicker;

/// Show the backup dialog. [restore] opens it on the restore side, for a
/// caller that already knows which of the two the user asked for.
Future<void> showBackupDialog(BuildContext context, {bool restore = false}) {
  return showDialog(
    context: context,
    builder: (context) => BackupDialog(restore: restore),
  );
}

class BackupDialog extends StatefulWidget {
  const BackupDialog({super.key, this.restore = false, this.service});

  /// Open on the restore side rather than the backup side.
  final bool restore;

  /// Injected in tests; the dialog builds its own.
  final BackupService? service;

  @override
  State<BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<BackupDialog> {
  late final BackupService _service =
      widget.service ?? backupServiceBuilder?.call() ?? BackupService();

  late bool _restoreMode = widget.restore;

  /// Instances on this machine, and the ones ticked for a backup.
  List<String> _instances = [];
  final Set<String> _selected = <String>{};

  /// The folder each side works with. Two controllers, not one: the folder a
  /// backup is written to and the folder a restore is read from are rarely
  /// the same, and sharing the field made the second pick overwrite the
  /// first.
  final TextEditingController _backupFolder = TextEditingController();
  final TextEditingController _restoreFolder = TextEditingController();

  /// What the restore folder turned out to hold, once one is picked.
  BackupManifest? _found;
  final Set<String> _restoreSelected = <String>{};

  /// Names that already exist here, so the restore list can say so before
  /// the run rather than reporting them as skipped afterwards.
  List<String> _existing = [];

  bool _loading = false;
  bool _running = false;
  CancelSignal? _cancel;
  String _status = '';
  BackupOutcome? _outcome;

  /// The message for the field the active side needs, or null when it can
  /// run. Shown under the field — a primary button may never silently do
  /// nothing (see test/required_fields_test.dart).
  String? _fieldError;

  /// Nothing here works against a remote host: `wsl --export` runs on that
  /// machine and writes to its disk, while the folder the user picks is on
  /// this one. Said in the dialog rather than only hidden in the list, so
  /// the answer is the same wherever it is opened from.
  bool get _remote => _service.backend.isRemote;

  @override
  void initState() {
    super.initState();
    _loadInstances();
  }

  @override
  void dispose() {
    _backupFolder.dispose();
    _restoreFolder.dispose();
    super.dispose();
  }

  Future<void> _loadInstances() async {
    setState(() => _loading = true);
    try {
      final instances =
          await _service.backend.list(prefs.getBool('showDocker') ?? false);
      final names = instances.all
          .where((name) => name.isNotEmpty && name != 'wslNotInstalled')
          .toList();
      if (!mounted) return;
      setState(() {
        _instances = names;
        _existing = names;
        // Everything ticked: the request this answers is "export all of
        // them", and un-ticking two is less work than ticking six.
        _selected
          ..clear()
          ..addAll(names);
      });
    } catch (_) {
      // An unreachable backend leaves the backup side empty, which its own
      // empty-state line explains; the restore side still works.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<String?> _pickFolder() async {
    final injected = backupFolderPicker?.call();
    if (injected != null) return injected;
    return FilePicker.platform
        .getDirectoryPath(dialogTitle: 'choosefolder-text'.i18n());
  }

  Future<void> _pickBackupFolder() async {
    final path = await _pickFolder();
    if (path == null || !mounted) return;
    setState(() {
      _backupFolder.text = path;
      _fieldError = null;
    });
  }

  Future<void> _pickRestoreFolder() async {
    final path = await _pickFolder();
    if (path == null || !mounted) return;
    setState(() {
      _restoreFolder.text = path;
      _fieldError = null;
      _found = null;
    });
    await _inspectRestoreFolder();
  }

  Future<void> _inspectRestoreFolder() async {
    final folder = _restoreFolder.text.trim();
    if (folder.isEmpty) return;
    setState(() => _loading = true);
    try {
      final manifest = await _service.inspect(folder);
      if (!mounted) return;
      setState(() {
        _found = manifest;
        _restoreSelected
          ..clear()
          // Everything that can actually be restored, ticked; the ones
          // already on this machine start un-ticked because restoring them
          // is the one thing this will not do.
          ..addAll(manifest.entries
              .where((e) => !e.missing && !_existing.contains(e.name))
              .map((e) => e.name));
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _missingField() {
    if (_restoreMode) {
      if (_restoreFolder.text.trim().isEmpty) {
        return 'backupnofolder-text'.i18n();
      }
      if (_restoreSelected.isEmpty) return 'backupnoinstances-text'.i18n();
      return null;
    }
    if (_backupFolder.text.trim().isEmpty) return 'backupnofolder-text'.i18n();
    if (_selected.isEmpty) return 'backupnoinstances-text'.i18n();
    return null;
  }

  void _selectMode(bool restore) {
    setState(() {
      _restoreMode = restore;
      // The message names a field on the side that is going away.
      _fieldError = null;
      _outcome = null;
    });
  }

  /// Turn one progress report into the line under the progress bar.
  String _statusLine(BackupStep step) {
    final counter =
        'backupcounter-text'.i18n(['${step.index}', '${step.total}']);
    switch (step.stage) {
      case BackupStage.stopping:
        return '${'backupstopping-text'.i18n([step.instance])} ($counter)';
      case BackupStage.exporting:
        return '${'backupexporting-text'.i18n([step.instance])} ($counter)';
      case BackupStage.importing:
        return '${'backupimporting-text'.i18n([step.instance])} ($counter)';
      case BackupStage.skipped:
      case BackupStage.done:
      case BackupStage.failed:
        return counter;
    }
  }

  Future<void> _run() async {
    // A folder typed rather than browsed to has never been read. Doing it
    // here keeps "Restore" from answering a real path with "select at least
    // one instance".
    final restoreFolder = _restoreFolder.text.trim();
    if (_restoreMode && _found == null && restoreFolder.isNotEmpty) {
      await _inspectRestoreFolder();
      if (!mounted) return;
    }

    final missing = _missingField();
    if (missing != null) {
      setState(() => _fieldError = missing);
      return;
    }

    final cancel = CancelSignal();
    setState(() {
      _fieldError = null;
      _outcome = null;
      _running = true;
      _cancel = cancel;
      _status = '';
    });

    void onStep(BackupStep step) {
      if (!mounted) return;
      setState(() => _status = _statusLine(step));
    }

    BackupOutcome outcome;
    try {
      if (_restoreMode) {
        outcome = await _service.restore(
          directory: _restoreFolder.text.trim(),
          only: _restoreSelected.toList(),
          cancel: cancel,
          onStep: onStep,
        );
      } else {
        outcome = await _service.backup(
          directory: _backupFolder.text.trim(),
          instances:
              _instances.where((name) => _selected.contains(name)).toList(),
          cancel: cancel,
          onStep: onStep,
        );
      }
    } catch (e) {
      // A run that throws as a whole — an unwritable folder, a backend that
      // is gone — still has to land somewhere the user can read.
      outcome = BackupOutcome()..failed[''] = friendlyErrorReason(e);
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _cancel = null;
      _status = '';
      _outcome = outcome;
    });

    // The bar carries the headline out of the dialog, so it survives the
    // user closing it; the breakdown stays here.
    Notify.message(_headline(outcome),
        severity: outcome.failed.isEmpty
            ? InfoBarSeverity.success
            : InfoBarSeverity.warning);
    if (_restoreMode && outcome.succeeded.isNotEmpty) {
      // A restored instance is not in the list this dialog is still showing.
      await _loadInstances();
    }
  }

  String _headline(BackupOutcome outcome) {
    final key = _restoreMode ? 'backuprestored-text' : 'backupsucceeded-text';
    return key.i18n(['${outcome.succeeded.length}']);
  }

  Widget _modeButton(bool restore, String labelKey) {
    final label =
        Text(labelKey.i18n(), maxLines: 1, overflow: TextOverflow.ellipsis);
    // Dead while a run is going: the side is what decides which operation
    // the finishing line reports, and switching it mid-export made the
    // summary name the one that did not run.
    final onPressed = _running ? null : () => _selectMode(restore);
    return Expanded(
      child: _restoreMode == restore
          ? FilledButton(onPressed: onPressed, child: label)
          : Button(onPressed: onPressed, child: label),
    );
  }

  Widget _info(String key) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Text(key.i18n(),
            style:
                const TextStyle(fontSize: 12.0, fontStyle: FontStyle.italic)),
      );

  Widget _folderRow({
    required TextEditingController controller,
    required String labelKey,
    required VoidCallback onBrowse,
    required String browseKey,
    VoidCallback? onEdited,
  }) {
    return InfoLabel(
      label: labelKey.i18n(),
      labelStyle: const TextStyle(fontWeight: FontWeight.w500),
      child: Row(
        children: [
          Expanded(
            child: TextBox(
              key: ValueKey(browseKey),
              controller: controller,
              readOnly: _running,
              onChanged: (_) {
                onEdited?.call();
                if (_fieldError != null) setState(() => _fieldError = null);
              },
            ),
          ),
          const SizedBox(width: 8.0),
          Button(
            onPressed: _running ? null : onBrowse,
            child: Text('choosefolder-text'.i18n()),
          ),
        ],
      ),
    );
  }

  Widget _fieldErrorText() {
    if (_fieldError == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4.0),
      child: Text(
        _fieldError!,
        key: const ValueKey('test-backup-field-error'),
        style: TextStyle(color: destructiveColor(context), fontSize: 12.0),
      ),
    );
  }

  /// The tick list both sides use: same rows, different subtitles.
  Widget _checkList(List<_BackupRow> rows, Set<String> selection) {
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Text(
          (_restoreMode ? 'backupnoarchives-text' : 'noinstancesfound-text')
              .i18n(),
          key: const ValueKey('test-backup-empty'),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220.0),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: Checkbox(
              checked: selection.contains(row.name),
              onChanged: _running || !row.enabled
                  ? null
                  : (checked) => setState(() {
                        if (checked ?? false) {
                          selection.add(row.name);
                        } else {
                          selection.remove(row.name);
                        }
                        _fieldError = null;
                      }),
              content: Text(
                row.subtitle.isEmpty
                    ? row.name
                    : '${row.name} — ${row.subtitle}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBackupSide() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _info('backupinfo-text'),
        _folderRow(
          controller: _backupFolder,
          labelKey: 'backupfolder-text',
          onBrowse: _pickBackupFolder,
          browseKey: 'test-backup-folder',
        ),
        const SizedBox(height: 12.0),
        Text('backupinstances-text'.i18n(),
            style: const TextStyle(fontWeight: FontWeight.w500)),
        _checkList(
          [for (final name in _instances) _BackupRow(name: name)],
          _selected,
        ),
        // Said before the run, not in the error afterwards: an instance the
        // user is working in disappears for the length of its export.
        InfoBar(
          key: const ValueKey('test-backup-shutdown-warning'),
          title: Text('backupshutdown-title'.i18n()),
          content: Text('backupshutdown-text'.i18n()),
          severity: InfoBarSeverity.info,
        ),
      ],
    );
  }

  Widget _buildRestoreSide() {
    final manifest = _found;
    final rows = <_BackupRow>[
      if (manifest != null)
        for (final entry in manifest.entries)
          _BackupRow(
            name: entry.name,
            subtitle: entry.missing
                ? 'backupmissingarchive-text'.i18n()
                : _existing.contains(entry.name)
                    ? 'backupalreadyhere-text'.i18n()
                    : formatBytes(entry.bytes),
            enabled: !entry.missing && !_existing.contains(entry.name),
          ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _info('restoreinfo-text'),
        _folderRow(
          controller: _restoreFolder,
          labelKey: 'restorefolder-text',
          onBrowse: _pickRestoreFolder,
          browseKey: 'test-restore-folder',
          // A typed path is a different folder; what the last one held is
          // not a listing of this one. Re-read on the way into the run
          // rather than on every keystroke.
          onEdited: () {
            if (_found != null) setState(() => _found = null);
          },
        ),
        const SizedBox(height: 12.0),
        if (manifest != null && !manifest.fromManifest && rows.isNotEmpty)
          InfoBar(
            key: const ValueKey('test-restore-no-manifest'),
            title: Text('restorenomanifest-title'.i18n()),
            content: Text('restorenomanifest-text'.i18n()),
            severity: InfoBarSeverity.info,
          ),
        // A raw VM disk is not something wsl.exe can import, and the other
        // way round; better said here than found out four gigabytes in.
        if (manifest != null && _service.isForeign(manifest))
          InfoBar(
            key: const ValueKey('test-restore-foreign-backend'),
            title: Text('restoreforeign-title'.i18n()),
            content: Text('restoreforeign-text'.i18n([manifest.backend])),
            severity: InfoBarSeverity.warning,
          ),
        if (manifest != null) _checkList(rows, _restoreSelected),
      ],
    );
  }

  /// What the finished run did, per instance, under the buttons that did it.
  Widget _buildOutcome(BackupOutcome outcome) {
    final lines = <String>[
      if (outcome.cancelled) 'backupstopped-text'.i18n(),
      _headline(outcome),
      if (outcome.skipped.isNotEmpty)
        'backupskipped-text'.i18n(['${outcome.skipped.length}']),
      for (final entry in outcome.failed.entries)
        entry.key.isEmpty
            ? entry.value
            : 'backupfailedone-text'.i18n([entry.key, entry.value]),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12.0),
      child: Column(
        key: const ValueKey('test-backup-outcome'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2.0),
              child: Text(line, style: const TextStyle(fontSize: 12.0)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560.0),
      // Says which of the two it is about: the title used to be the feature's
      // name while the primary button said the opposite operation elsewhere
      // in this app (audit ST-47).
      title: Text(
          (_restoreMode ? 'restore-text' : 'backup-text').i18n()),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _modeButton(false, 'backup-text'),
                const SizedBox(width: 4.0),
                _modeButton(true, 'restore-text'),
              ],
            ),
            const SizedBox(height: 16.0),
            if (_remote)
              InfoBar(
                key: const ValueKey('test-backup-remote'),
                title: Text('backupremote-title'.i18n()),
                content: Text('backupremote-text'.i18n()),
                severity: InfoBarSeverity.warning,
              )
            else if (_running) ...[
              const ProgressBar(),
              const SizedBox(height: 8.0),
              Text(_status, key: const ValueKey('test-backup-status')),
            ] else if (_loading)
              const ProgressBar()
            else if (_restoreMode)
              _buildRestoreSide()
            else
              _buildBackupSide(),
            _fieldErrorText(),
            if (outcome != null && !_running) _buildOutcome(outcome),
          ],
        ),
      ),
      // Primary first, Cancel last — the order every other dialog uses
      // (audit ST-62).
      actions: [
        FilledButton(
          key: const ValueKey('test-backup-submit'),
          onPressed: _running || _loading || _remote ? null : _run,
          child: Text((_restoreMode ? 'restore-text' : 'backup-text').i18n()),
        ),
        Button(
          key: const ValueKey('test-backup-cancel'),
          // While a run is going, Cancel stops the run rather than the
          // dialog: closing the window would leave the export running with
          // nothing to report to.
          onPressed: _running
              ? () => _cancel?.cancel()
              : () => Navigator.pop(context),
          child: Text(_running ? 'stop-text'.i18n() : 'cancel-text'.i18n()),
        ),
      ],
    );
  }
}

/// One row of either tick list.
class _BackupRow {
  const _BackupRow({
    required this.name,
    this.subtitle = '',
    this.enabled = true,
  });

  final String name;
  final String subtitle;

  /// False for an archive whose name is already taken here: it cannot be
  /// restored, so it cannot be ticked.
  final bool enabled;
}
