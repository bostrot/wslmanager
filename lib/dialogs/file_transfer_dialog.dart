// The user-facing half of [FileTransferService]: browse one instance, tick
// what you want, say where it goes (bostrot/ai-tasks#92, upstream
// bostrot/wsl2-distro-manager#236).
//
// Opened from the instance row, not from Settings, because the question it
// answers is always about one instance the user is already looking at — the
// old one they are about to delete. The row it opens from is the source; the
// only thing left to choose is the destination.
//
// The list is one flat folder with a path above it rather than a tree. A tree
// would need a listing per expanded node, and every listing is a command
// round trip into a guest that may have to be started first; a folder at a
// time is one round trip per click, which is what the browser can promise on
// a remote host as well.
//
// Directories are navigated by their name and picked by their checkbox, which
// are deliberately two different targets: the whole point of the request is
// taking a folder across, so "open it" must not be the only thing a folder
// can do.

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/file_transfer_service.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// How the dialog reaches the backend. The seam the widget tests replace,
/// matching `backup_dialog.dart`'s [FileTransferService] builder.
FileTransferService Function()? fileTransferServiceBuilder;

/// Browse [instance] and copy what is picked into another instance.
Future<void> showFileTransferDialog(BuildContext context, String instance) {
  return showDialog(
    context: context,
    builder: (context) => FileTransferDialog(instance: instance),
  );
}

class FileTransferDialog extends StatefulWidget {
  const FileTransferDialog({super.key, required this.instance, this.service});

  /// The instance the files come out of.
  final String instance;

  /// Injected in tests; the dialog builds its own.
  final FileTransferService? service;

  @override
  State<FileTransferDialog> createState() => _FileTransferDialogState();
}

class _FileTransferDialogState extends State<FileTransferDialog> {
  late final FileTransferService _service = widget.service ??
      fileTransferServiceBuilder?.call() ??
      FileTransferService();

  final TextEditingController _path = TextEditingController();
  final TextEditingController _destination = TextEditingController();

  List<InstanceFileEntry> _entries = [];

  /// The folder [_entries] came from. Distinct from [_path], which is a field
  /// the user may be halfway through editing: a transfer has to name the
  /// folder whose list they ticked, not the one they have started typing.
  String _current = '/';

  /// Names ticked in the folder currently shown. Cleared on navigation: a
  /// selection the user can no longer see is one they cannot untick, and
  /// names are only unique within their own folder anyway.
  final Set<String> _selected = <String>{};

  /// The other instances on this machine, and which one was chosen.
  List<String> _targets = [];
  String? _target;

  /// Which of [_targets] the backend reported as running when the list was
  /// read. A stopped one is still offered — the transfer starts it — but it
  /// says so in the dropdown, because "it will take a few minutes longer" is
  /// worth knowing before pressing the button rather than after.
  Set<String> _runningTargets = <String>{};

  bool _loading = true;
  bool _running = false;

  /// The instance being started while the dialog opens, or empty. Separate
  /// from [_step], which only exists once a transfer is under way: this is
  /// the wait *before* anything can be shown at all.
  String _startingInstance = '';
  CancelSignal? _cancel;
  TransferStep? _step;

  /// The listing's own failure — shown in place of the list, because an empty
  /// list and an unreadable folder must not look the same (see the service
  /// header for what that looked like upstream).
  String _listError = '';

  /// What the primary button is waiting for, shown under the fields rather
  /// than left as a button that does nothing.
  String? _fieldError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _path.dispose();
    _destination.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    // The source has to be up before its filesystem can be listed. Without
    // this the first listing on a stopped VM sits on the backend's own
    // timeout and then shows an empty folder, which is exactly the "it's
    // blank" the upstream report was about.
    try {
      await _service.ensureRunning(widget.instance, onStarting: () {
        if (!mounted) return;
        setState(() => _startingInstance = widget.instance);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _startingInstance = '';
        _loading = false;
        _listError = friendlyErrorReason(e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _startingInstance = '');
    final home = await _service.homeDirectory(widget.instance);
    if (!mounted) return;
    _path.text = home;
    _destination.text = home;
    await _loadTargets();
    if (!mounted) return;
    await _open(home);
  }

  Future<void> _loadTargets() async {
    try {
      final all =
          await _service.backend.list(prefs.getBool('showDocker') ?? false);
      if (!mounted) return;
      final names = all.all
          .where((name) =>
              name.isNotEmpty &&
              name != 'wslNotInstalled' &&
              name != widget.instance)
          .toList();
      setState(() {
        _targets = names;
        _runningTargets = all.running.toSet();
        // A running instance first: it is the one that transfers without a
        // boot in front of it, and on a machine with several VMs the default
        // choice should not be the slow one by accident.
        _target = names.isEmpty
            ? null
            : names.firstWhere((name) => _runningTargets.contains(name),
                orElse: () => names.first);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _targets = [];
        _runningTargets = <String>{};
      });
    }
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _listError = '';
      _fieldError = null;
    });
    try {
      final entries = await _service.list(widget.instance, path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _selected.clear();
        _current = path;
        _path.text = path;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = [];
        _selected.clear();
        _listError = friendlyErrorReason(e);
        _loading = false;
      });
    }
  }

  /// The parent of the folder shown, or null at the root.
  String? get _parent {
    if (_current == '/') return null;
    final cut = _current.lastIndexOf('/');
    return cut <= 0 ? '/' : _current.substring(0, cut);
  }

  String _normalized(String path) {
    var value = path.trim();
    if (value.isEmpty) return '/';
    while (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value.startsWith('/') ? value : '/$value';
  }

  String _child(String name) => _current == '/' ? '/$name' : '$_current/$name';

  String? _missingField() {
    if (_selected.isEmpty) return 'transfernothingpicked-text'.i18n();
    if (_target == null) return 'transfernotarget-text'.i18n();
    if (_destination.text.trim().isEmpty) {
      return 'transfernodestination-text'.i18n();
    }
    return null;
  }

  Future<void> _run() async {
    final missing = _missingField();
    if (missing != null) {
      setState(() => _fieldError = missing);
      return;
    }

    final cancel = CancelSignal();
    setState(() {
      _fieldError = null;
      _running = true;
      _cancel = cancel;
      _step = const TransferStep(stage: TransferStage.packing);
    });

    try {
      final bytes = await _service.transfer(
        sourceInstance: widget.instance,
        sourceDirectory: _current,
        names: _selected.toList(),
        targetInstance: _target!,
        targetDirectory: _destination.text.trim(),
        cancel: cancel,
        onStep: (step) {
          if (!mounted) return;
          setState(() => _step = step);
        },
      );
      if (!mounted) return;
      setState(() {
        _running = false;
        _cancel = null;
        _step = null;
      });
      Notify.message(
          'transferdone-text'
              .i18n(['${_selected.length}', _target!, formatBytes(bytes)]),
          severity: InfoBarSeverity.success);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _cancel = null;
        _step = null;
        _fieldError = friendlyErrorReason(e);
      });
    }
  }

  /// A stopped instance is labelled as one: the transfer will start it, and
  /// that is minutes of waiting the user should be able to see coming.
  String _targetLabel(String name) {
    final label = distroLabel(name);
    return _runningTargets.contains(name)
        ? label
        : 'transferstoppedtarget-text'.i18n([label]);
  }

  String _statusLine(TransferStep step) {
    switch (step.stage) {
      case TransferStage.starting:
        return 'startinginstance-text'.i18n([distroLabel(step.instance)]);
      case TransferStage.packing:
        return 'transferpacking-text'.i18n();
      case TransferStage.reading:
        return 'transferreading-text'.i18n();
      case TransferStage.writing:
        return 'transferwriting-text'.i18n([_target ?? '']);
      case TransferStage.unpacking:
      case TransferStage.done:
        return 'transferunpacking-text'.i18n([_target ?? '']);
    }
  }

  Widget _pathRow() {
    final parent = _parent;
    return Row(
      children: [
        NamedIconButton(
          key: const ValueKey('test-transfer-up'),
          label: 'transferup-text'.i18n(),
          icon: FluentIcons.up,
          iconSize: 14.0,
          onPressed: _running || parent == null ? null : () => _open(parent),
        ),
        const SizedBox(width: 4.0),
        Expanded(
          child: TextBox(
            key: const ValueKey('test-transfer-path'),
            controller: _path,
            enabled: !_running,
            onSubmitted: (value) => _open(_normalized(value)),
          ),
        ),
      ],
    );
  }

  Widget _listBody() {
    if (_listError.isNotEmpty) {
      return InfoBar(
        key: const ValueKey('test-transfer-list-error'),
        title: Text('transfercannotread-title'.i18n()),
        content: Text(_listError),
        severity: InfoBarSeverity.warning,
      );
    }
    if (_entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Text('transferemptyfolder-text'.i18n(),
            key: const ValueKey('test-transfer-empty')),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 260.0),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          final subtitle =
              entry.isDirectory ? '' : '  ${formatBytes(entry.sizeBytes)}';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: Row(
              children: [
                Checkbox(
                  key: ValueKey('test-transfer-pick-${entry.name}'),
                  checked: _selected.contains(entry.name),
                  onChanged: _running
                      ? null
                      : (checked) => setState(() {
                            if (checked ?? false) {
                              _selected.add(entry.name);
                            } else {
                              _selected.remove(entry.name);
                            }
                            _fieldError = null;
                          }),
                ),
                const SizedBox(width: 8.0),
                Icon(
                    entry.isDirectory
                        ? FluentIcons.folder_horizontal
                        : FluentIcons.page,
                    size: 14.0),
                const SizedBox(width: 6.0),
                Expanded(
                  child: entry.isDirectory
                      ? HyperlinkButton(
                          key: ValueKey('test-transfer-open-${entry.name}'),
                          onPressed:
                              _running ? null : () => _open(_child(entry.name)),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(entry.name,
                                overflow: TextOverflow.ellipsis),
                          ),
                        )
                      : Text('${entry.name}$subtitle',
                          overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _destinationRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('transfertarget-text'.i18n(),
            style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 4.0),
        // "There is no other instance" is only true once the list has been
        // read. While the source is still being started that can be minutes
        // away, and an empty list in the meantime means nothing.
        if (_targets.isEmpty && _loading)
          const SizedBox.shrink()
        else if (_targets.isEmpty)
          InfoBar(
            key: const ValueKey('test-transfer-no-targets'),
            title: Text('transfernoothers-title'.i18n()),
            content: Text('transfernoothers-text'.i18n()),
            severity: InfoBarSeverity.info,
          )
        else
          Row(
            children: [
              SizedBox(
                width: 180.0,
                child: ComboBox<String>(
                  key: const ValueKey('test-transfer-target'),
                  value: _target,
                  isExpanded: true,
                  items: [
                    for (final name in _targets)
                      ComboBoxItem<String>(
                        value: name,
                        child: Text(_targetLabel(name),
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _running
                      ? null
                      : (value) => setState(() {
                            _target = value;
                            _fieldError = null;
                          }),
                ),
              ),
              const SizedBox(width: 8.0),
              Expanded(
                child: TextBox(
                  key: const ValueKey('test-transfer-destination'),
                  controller: _destination,
                  enabled: !_running,
                  placeholder: 'transferdestination-text'.i18n(),
                ),
              ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final error = _fieldError;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 620.0),
      title: Text('transferfiles-text'.i18n([distroLabel(widget.instance)])),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text('transferinfo-text'.i18n(),
                  style: const TextStyle(
                      fontSize: 12.0, fontStyle: FontStyle.italic)),
            ),
            if (_running && step != null) ...[
              // ProgressBar only sets a *minimum* width, so in a
              // start-aligned Column it collapses to a ~130px stub sitting in
              // the corner of a 620px dialog. It has to be told to fill.
              SizedBox(
                width: double.infinity,
                child: ProgressBar(
                    value:
                        step.fraction == null ? null : step.fraction! * 100.0),
              ),
              const SizedBox(height: 8.0),
              Text(_statusLine(step),
                  key: const ValueKey('test-transfer-status')),
            ] else ...[
              _pathRow(),
              const SizedBox(height: 8.0),
              if (_loading) ...[
                const SizedBox(width: double.infinity, child: ProgressBar()),
                if (_startingInstance.isNotEmpty) ...[
                  const SizedBox(height: 8.0),
                  Text(
                      'startinginstance-text'
                          .i18n([distroLabel(_startingInstance)]),
                      key: const ValueKey('test-transfer-opening-status')),
                ],
              ] else
                _listBody(),
              const SizedBox(height: 12.0),
              _destinationRow(),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(error,
                    key: const ValueKey('test-transfer-error'),
                    style: TextStyle(
                        fontSize: 12.0,
                        color: Colors.red.defaultBrushFor(
                            FluentTheme.of(context).brightness))),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('test-transfer-submit'),
          onPressed: _running || _loading || _targets.isEmpty ? null : _run,
          child: Text('transfer-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-transfer-cancel'),
          // While a transfer is going, Cancel stops the transfer rather than
          // the dialog: closing the window would leave an archive half
          // written into the target with nothing to clean it up.
          onPressed:
              _running ? () => _cancel?.cancel() : () => Navigator.pop(context),
          child: Text(_running ? 'stop-text'.i18n() : 'cancel-text'.i18n()),
        ),
      ],
    );
  }
}
