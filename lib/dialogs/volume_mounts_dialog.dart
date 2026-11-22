import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/volume_mounts.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// Opens the shared-folder editor for [instance] (bostrot/ai-tasks#79).
///
/// [service] is injected by tests; the dialog otherwise builds one over the
/// host's backend.
Future<void> showVolumeMountsDialog(String instance,
    {VolumeMountService? service, BuildContext? context}) async {
  final host = context ?? GlobalVariable.infobox.currentContext!;
  await showDialog<void>(
    context: host,
    builder: (_) => VolumeMountsDialog(
      instance: instance,
      service: service ?? VolumeMountService(vmBackend()),
    ),
  );
}

class VolumeMountsDialog extends StatefulWidget {
  final String instance;
  final VolumeMountService service;

  const VolumeMountsDialog(
      {super.key, required this.instance, required this.service});

  @override
  State<VolumeMountsDialog> createState() => _VolumeMountsDialogState();
}

class _VolumeMountsDialogState extends State<VolumeMountsDialog> {
  List<VolumeMount>? _mounts;
  String? _loadError;
  bool _saving = false;

  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _guestController = TextEditingController();
  bool _readOnly = false;

  /// What the add form is missing, shown under it rather than as a toast:
  /// the field it names is right there.
  String? _fieldError;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'volume_mounts_dialog');
    _load();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _guestController.dispose();
    super.dispose();
  }

  /// What went wrong, for the user: the service's own failures carry an
  /// i18n key, anything else is read the way every other error is.
  static String reasonFor(Object error) {
    if (error is VolumeMountException && error.message.endsWith('-text')) {
      return error.message.i18n();
    }
    return WslFailure.from(error).shortReason;
  }

  Future<void> _load() async {
    try {
      final mounts = await widget.service.list(widget.instance);
      if (mounted) setState(() => _mounts = mounts);
    } catch (error) {
      if (mounted) setState(() => _loadError = reasonFor(error));
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || path.isEmpty || !mounted) return;
    setState(() {
      _hostController.text = path;
      if (_guestController.text.trim().isEmpty) {
        _guestController.text = widget.service.suggestGuestPath(path);
      }
      _fieldError = null;
    });
  }

  /// The i18n key (already applied) for what stops the add form, or null.
  String? _addError() {
    final host = _hostController.text.trim();
    final guest = _guestController.text.trim();
    final hostError = validateHostMountPath(host,
        windowsStyle: widget.service.windowsHostPaths);
    if (hostError != null) return hostError.i18n();
    // Only a folder on this machine can be checked for; over remote WSL the
    // path names a folder on the other one.
    if (!widget.service.isRemote &&
        Platform.isWindows == widget.service.windowsHostPaths &&
        !Directory(host).existsSync()) {
      return 'mountshostmissing-text'.i18n([host]);
    }
    final guestError = validateGuestMountPath(guest);
    if (guestError != null) return guestError.i18n();
    if ((_mounts ?? []).any((m) => m.guestPath == guest)) {
      return 'mountsguestduplicate-text'.i18n([guest]);
    }
    return null;
  }

  void _add() {
    final error = _addError();
    if (error != null) {
      setState(() => _fieldError = error);
      return;
    }
    setState(() {
      _mounts = [
        ...?_mounts,
        VolumeMount(
          hostPath: _hostController.text.trim(),
          guestPath: _guestController.text.trim(),
          readOnly: _readOnly,
        ),
      ];
      _hostController.clear();
      _guestController.clear();
      _readOnly = false;
      _fieldError = null;
    });
  }

  void _remove(VolumeMount mount) {
    setState(() => _mounts = [...?_mounts]..remove(mount));
  }

  Future<void> _save() async {
    final mounts = _mounts;
    if (mounts == null || _saving) return;
    setState(() => _saving = true);
    final label = distroLabel(widget.instance);
    try {
      final result = await widget.service.apply(widget.instance, mounts);
      final String message;
      if (result.timing == MountApplyTiming.now) {
        message = 'mountsapplied-text'.i18n([label]);
      } else if (result.instanceRunning) {
        message = 'mountsrestart-text'.i18n([label]);
      } else {
        message = 'mountsonstart-text'.i18n([label]);
      }
      Notify.message(message, severity: InfoBarSeverity.success);
      for (final warning in result.warnings) {
        // A bare key is one of ours; anything else is what the guest said.
        final text = warning.endsWith('-text')
            ? warning.i18n()
            : 'mountsapplywarning-text'.i18n([warning]);
        Notify.message(text,
            severity: InfoBarSeverity.warning,
            duration: const Duration(seconds: 8));
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (error) {
      Notify.message(
          '${'mountsfailed-text'.i18n([label])} ${reasonFor(error)}'.trim(),
          severity: InfoBarSeverity.error);
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _mountRow(VolumeMount mount) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(FluentIcons.fabric_folder_link, size: 14),
          const SizedBox(width: 8.0),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mount.guestPath,
                    key: ValueKey('test-mounts-guest-${mount.guestPath}'),
                    style: FluentTheme.of(context).typography.bodyStrong,
                    overflow: TextOverflow.ellipsis),
                Text(mount.hostPath,
                    style: TextStyle(
                        fontSize: 12, color: secondaryTextColor(context)),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (mount.readOnly)
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Text('mountsreadonly-text'.i18n(),
                  style: TextStyle(
                      fontSize: 12, color: secondaryTextColor(context))),
            ),
          const SizedBox(width: 4.0),
          NamedIconButton(
            key: ValueKey('test-mounts-remove-${mount.guestPath}'),
            label: '${'mountsremove-text'.i18n()}: ${mount.guestPath}',
            icon: FluentIcons.delete,
            iconSize: 14,
            onPressed: _saving ? null : () => _remove(mount),
          ),
        ],
      ),
    );
  }

  Widget _addForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoLabel(
          label: 'mountshost-text'.i18n(),
          child: TextBox(
            key: const ValueKey('test-mounts-host'),
            controller: _hostController,
            onChanged: (_) {
              if (_fieldError != null) setState(() => _fieldError = null);
            },
            // The picker browses this machine; over remote WSL that is not
            // where the folder is.
            suffix: widget.service.isRemote
                ? null
                : NamedIconButton(
                    key: const ValueKey('test-mounts-browse'),
                    label: 'mountsbrowse-text'.i18n(),
                    icon: FluentIcons.open_folder_horizontal,
                    onPressed: _saving ? null : _pickFolder,
                  ),
          ),
        ),
        const SizedBox(height: 8.0),
        InfoLabel(
          label: 'mountsguest-text'.i18n(),
          child: TextBox(
            key: const ValueKey('test-mounts-guest'),
            controller: _guestController,
            onChanged: (_) {
              if (_fieldError != null) setState(() => _fieldError = null);
            },
          ),
        ),
        const SizedBox(height: 8.0),
        Row(
          children: [
            Expanded(
              child: Checkbox(
                key: const ValueKey('test-mounts-readonly'),
                checked: _readOnly,
                onChanged: (value) =>
                    setState(() => _readOnly = value ?? false),
                content: Text('mountsreadonly-text'.i18n()),
              ),
            ),
            Button(
              key: const ValueKey('test-mounts-add'),
              onPressed: _saving ? null : _add,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(FluentIcons.add, size: 12),
                const SizedBox(width: 6),
                Text('mountsadd-text'.i18n()),
              ]),
            ),
          ],
        ),
        if (_fieldError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6.0),
            child: Text(_fieldError!,
                key: const ValueKey('test-mounts-field-error'),
                style: TextStyle(
                    fontSize: 12, color: destructiveColor(context))),
          ),
      ],
    );
  }

  Widget _body() {
    final loadError = _loadError;
    if (loadError != null) {
      return Text(loadError,
          key: const ValueKey('test-mounts-error'),
          style: TextStyle(color: destructiveColor(context)));
    }
    final mounts = _mounts;
    if (mounts == null) {
      return Row(children: [
        const SizedBox.square(
            dimension: 16.0, child: ProgressRing(strokeWidth: 2.0)),
        const SizedBox(width: 8.0),
        Text('loading-text'.i18n()),
      ]);
    }
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('mountsbody-text'.i18n()),
          const SizedBox(height: 12.0),
          if (widget.service.guestProblem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: InfoBar(
                key: const ValueKey('test-mounts-guest-problem'),
                title: Text('mountsguestproblem-text'.i18n()),
                content: Text(widget.service.guestProblem!),
                severity: InfoBarSeverity.warning,
                isLong: true,
              ),
            ),
          if (mounts.isEmpty)
            Text('mountsnone-text'.i18n(),
                key: const ValueKey('test-mounts-none'),
                style: TextStyle(color: secondaryTextColor(context))),
          for (final mount in mounts) _mountRow(mount),
          const SizedBox(height: 8.0),
          _addForm(),
          if (widget.service.appliesAtNextStart)
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: InfoBar(
                key: const ValueKey('test-mounts-next-start'),
                title: Text('mountsnextstart-text'.i18n()),
                content: Text('mountsownerhint-text'.i18n()),
                severity: InfoBarSeverity.info,
                isLong: true,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 620.0),
      title: Text('mountstitle-text'.i18n([distroLabel(widget.instance)])),
      content: _body(),
      actions: [
        FilledButton(
          key: const ValueKey('test-mounts-save'),
          onPressed: _mounts == null || _saving ? null : _save,
          child: Text('save-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-dialog-cancel'),
          onPressed:
              _saving ? null : () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text('cancel-text'.i18n()),
        ),
      ],
    );
  }
}
