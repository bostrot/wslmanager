import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/mount_service.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/error_view.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';

void showMountDialog({MountService? service}) {
  final context = GlobalVariable.infobox.currentContext!;
  showDialog(
    context: context,
    builder: (context) => MountDialog(service: service),
  );
}

class MountDialog extends StatefulWidget {
  const MountDialog({super.key, this.service});

  /// Injected in tests; the dialog builds its own.
  final MountService? service;

  @override
  State<MountDialog> createState() => _MountDialogState();
}

class _MountDialogState extends State<MountDialog> {
  late final MountService _mountService = widget.service ?? MountService();
  bool _loading = false;
  int _selectedTab = 0; // 0: Physical, 1: VHD, 2: Unmount

  // Physical Disk
  List<PhysicalDisk> _disks = [];
  PhysicalDisk? _selectedDisk;
  final TextEditingController _partitionController = TextEditingController();
  final TextEditingController _typeController = TextEditingController();
  final TextEditingController _optionsController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  bool _bare = false;

  // VHD
  final TextEditingController _vhdPathController = TextEditingController();
  final TextEditingController _vhdPartitionController = TextEditingController();
  final TextEditingController _vhdTypeController = TextEditingController();
  final TextEditingController _vhdOptionsController = TextEditingController();
  final TextEditingController _vhdNameController = TextEditingController();
  bool _vhdBare = false;

  // Unmount
  final TextEditingController _unmountPathController = TextEditingController();
  List<String> _mountedDisks = [];

  /// What the current tab is waiting for before it can run.
  ///
  /// The three required-field guards used to be bare `return`s *inside* the
  /// try that had already set `_loading`, so pressing the primary button on an
  /// empty field flashed a progress bar and changed nothing at all
  /// (audit ST-45).
  String? _fieldError;

  @override
  void initState() {
    super.initState();
    _loadDisks();
    _loadMountedDisks();
  }

  Future<void> _loadMountedDisks() async {
    try {
      var disks = await _mountService.getMountedDisks();
      if (mounted) {
        setState(() {
          _mountedDisks = disks;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadDisks() async {
    setState(() => _loading = true);
    try {
      _disks = await _mountService.getPhysicalDisks();
      if (_disks.isNotEmpty) {
        _selectedDisk = _disks.first;
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The message for the field the active tab needs, or null when it can run.
  String? _missingField() {
    if (_selectedTab == 0) {
      return _selectedDisk == null ? 'selectdiskrequired-text'.i18n() : null;
    }
    if (_selectedTab == 1) {
      return _vhdPathController.text.trim().isEmpty
          ? 'vhdpathrequired-text'.i18n()
          : null;
    }
    return _unmountPathController.text.trim().isEmpty
        ? 'unmountpathrequired-text'.i18n()
        : null;
  }

  void _selectTab(int tab) {
    setState(() {
      _selectedTab = tab;
      // The message names a field on the tab that is going away.
      _fieldError = null;
    });
  }

  void _clearFieldError() {
    if (_fieldError != null) setState(() => _fieldError = null);
  }

  /// One segment of the mode switch; the active mode renders filled.
  Widget _modeButton(int index, String labelKey) {
    final label = Text(labelKey.i18n(),
        maxLines: 1, overflow: TextOverflow.ellipsis);
    return Expanded(
      child: _selectedTab == index
          ? FilledButton(
              onPressed: () => _selectTab(index),
              child: label,
            )
          : Button(
              onPressed: () => _selectTab(index),
              child: label,
            ),
    );
  }

  /// The validation message under the field it is about, or nothing.
  Widget _fieldErrorText() {
    if (_fieldError == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4.0),
      child: Text(
        _fieldError!,
        key: const ValueKey('test-mount-field-error'),
        style: TextStyle(color: destructiveColor(context), fontSize: 12.0),
      ),
    );
  }

  Future<void> _execute() async {
    final missing = _missingField();
    if (missing != null) {
      setState(() => _fieldError = missing);
      return;
    }

    setState(() {
      _fieldError = null;
      _loading = true;
    });
    try {
      if (_selectedTab == 0) {
        await _mountService.mountDisk(
          _selectedDisk!.deviceId,
          partition: _partitionController.text,
          type: _typeController.text,
          options: _optionsController.text,
          name: _nameController.text,
          bare: _bare,
        );
        if (mounted) Notify.message('diskmounted-text'.i18n());
      } else if (_selectedTab == 1) {
        await _mountService.mountVhd(
          _vhdPathController.text,
          partition: _vhdPartitionController.text,
          type: _vhdTypeController.text,
          options: _vhdOptionsController.text,
          name: _vhdNameController.text,
          bare: _vhdBare,
        );
        if (mounted) Notify.message('vhdmounted-text'.i18n());
      } else {
        await _mountService.unmount(_unmountPathController.text);
        if (mounted) Notify.message('diskunmounted-text'.i18n());
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        final failure = WslFailure.from(e);
        bool handled = false;

        // Handle unmount by name failure for auto-generated mounts
        if (_selectedTab == 2 &&
            _mountedDisks.contains(_unmountPathController.text)) {
          // Check if it's likely the specific error (or just assume it is if it failed by name)
          // The error from WSL is usually "The system cannot find the file specified" or "invalid name"
          handled = true;
          await showDialog(
            context: context,
            builder: (dialogContext) => ContentDialog(
              title: Text('unmountfailed-text'.i18n()),
              content: Text('unmountfailed-msg'.i18n()),
              actions: [
                FilledButton(
                  child: Text('selectfile-text'.i18n()),
                  onPressed: () async {
                    Navigator.pop(dialogContext); // Close error dialog
                    FilePickerResult? result =
                        await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['vhdx', 'vhd'],
                    );
                    if (result != null) {
                      setState(() => _loading = true);
                      try {
                        await _mountService.unmount(result.files.single.path!);
                        if (mounted) {
                          Notify.message('diskunmounted-text'.i18n());
                          Navigator.pop(context); // Close mount dialog
                        }
                      } catch (e2) {
                        if (mounted) {
                          showDialog(
                            context: context,
                            builder: (context) => ContentDialog(
                              title: Text('error-text'.i18n()),
                              content: ErrorBody(failure: WslFailure.from(e2)),
                              actions: [
                                Button(
                                  child: Text('ok-text'.i18n()),
                                  onPressed: () => Navigator.pop(context),
                                )
                              ],
                            ),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => _loading = false);
                      }
                    }
                  },
                ),
                Button(
                  child: Text('cancel-text'.i18n()),
                  onPressed: () => Navigator.pop(dialogContext),
                ),
              ],
            ),
          );
        }

        if (!handled) {
          // Check for "attached but not mounted" error
          // Look for: wsl.exe --unmount <path>
          RegExp unmountRegex = RegExp(r'wsl\.exe --unmount (.*?)["\n]');
          Match? match = unmountRegex.firstMatch(failure.details);
          if (match != null) {
            String path = match.group(1)?.trim() ?? '';
            if (path.isNotEmpty) {
              handled = true;
              await showDialog(
                context: context,
                builder: (dialogContext) => ContentDialog(
                  title: Text('mountfailed-text'.i18n()),
                  content: Text('mountfailed-msg'.i18n()),
                  actions: [
                    FilledButton(
                      child: Text('detach-text'.i18n()),
                      onPressed: () async {
                        Navigator.pop(dialogContext);
                        setState(() => _loading = true);
                        try {
                          await _mountService.unmount(path);
                          if (mounted) {
                            Notify.message('diskunmounted-text'.i18n());
                          }
                        } catch (e2) {
                          if (mounted) {
                            showDialog(
                              context: context,
                              builder: (context) => ContentDialog(
                                title: Text('error-text'.i18n()),
                                content: ErrorBody(failure: WslFailure.from(e2)),
                                actions: [
                                  Button(
                                    child: Text('ok-text'.i18n()),
                                    onPressed: () => Navigator.pop(context),
                                  )
                                ],
                              ),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _loading = false);
                        }
                      },
                    ),
                    Button(
                      child: Text('cancel-text'.i18n()),
                      onPressed: () => Navigator.pop(dialogContext),
                    ),
                  ],
                ),
              );
            }
          }
        }

        if (!handled) {
          // The remedy is attached by error code, not by matching English
          // Windows prose: on a localized host the old substring test could
          // never fire, so the user got the raw output and no hint (IA-19).
          showDialog(
            context: context,
            builder: (context) => ContentDialog(
              title: Text('mountfailedtitle-text'.i18n()),
              content: ErrorBody(
                failure: failure,
                hint: failure.isResourceInUse
                    ? 'diskofflinehint-text'.i18n()
                    : null,
              ),
              actions: [
                Button(
                  child: Text('ok-text'.i18n()),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      // Says which of the two operations it is doing — the title stayed
      // "Mount Disk" while the primary button said Unmount (audit ST-47).
      title: Text(_selectedTab == 2
          ? 'unmountdisk-text'.i18n()
          : 'mountdisk-text'.i18n()),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A segmented mode switch, not three radio buttons posing as a
            // tab strip whose third member is the inverse operation (ST-47).
            Row(
              children: [
                _modeButton(0, 'physicaldisk-text'),
                const SizedBox(width: 4),
                _modeButton(1, 'vhdimage-text'),
                const SizedBox(width: 4),
                _modeButton(2, 'unmount-text'),
              ],
            ),
            const SizedBox(height: 20),

            if (_loading)
              const ProgressBar()
            else if (_selectedTab == 0)
              _buildPhysicalDiskForm()
            else if (_selectedTab == 1)
              _buildVhdForm()
            else
              _buildUnmountForm(),
          ],
        ),
      ),
      // Primary first, Cancel last — the order every other dialog in the app
      // uses (audit ST-62).
      actions: [
        FilledButton(
          key: const ValueKey('test-mount-submit'),
          onPressed: _loading ? null : _execute,
          child: Text(
              _selectedTab == 2 ? 'unmount-text'.i18n() : 'mount-text'.i18n()),
        ),
        Button(
          onPressed: () => Navigator.pop(context),
          child: Text('cancel-text'.i18n()),
        ),
      ],
    );
  }

  /// `wsl --mount \\.\PHYSICALDRIVE0` needs an elevated process and takes the
  /// disk away from Windows for as long as it stays mounted. The form used to
  /// say neither: the only text covering any of it was appended to the *error*
  /// message, after the attempt had already failed (audit ST-46).
  Widget _physicalMountWarning() => InfoBar(
        key: const ValueKey('test-mount-physical-warning'),
        title: Text('physicalmountwarning-title'.i18n()),
        content: Text('physicalmountwarning-text'.i18n()),
        severity: InfoBarSeverity.warning,
      );

  Widget _buildPhysicalDiskForm() {
    if (_disks.isEmpty) {
      return Column(
        children: [
          _physicalMountWarning(),
          const SizedBox(height: 10),
          Text('nodisksfound-text'.i18n()),
          _fieldErrorText(),
          const SizedBox(height: 10),
          Button(
            onPressed: _loadDisks,
            child: Text('refresh-text'.i18n()),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _physicalMountWarning(),
        const SizedBox(height: 10),
        InfoLabel(
          label: 'selectdisk-text'.i18n(),
          child: ComboBox<PhysicalDisk>(
            isExpanded: true,
            items: _disks
                .map((e) => ComboBoxItem(
                      value: e,
                      child: Tooltip(
                        message: e.toString(),
                        child: Text(
                          e.toString(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ))
                .toList(),
            value: _selectedDisk,
            onChanged: (v) => setState(() {
              _selectedDisk = v;
              _fieldError = null;
            }),
          ),
        ),
        _fieldErrorText(),
        // The device id is the only thing that separates two disks of the
        // same model, and it is the first thing the combo ellipsises away
        // (audit ST-44).
        if (_selectedDisk != null)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              '${'deviceid-text'.i18n()}: ${_selectedDisk!.deviceId}',
              style: TextStyle(
                fontSize: 12.0,
                color: secondaryTextColor(context),
              ),
            ),
          ),
        if (_selectedDisk != null && _selectedDisk!.isUsb)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: InfoBar(
              title: Text('usbdetected-text'.i18n()),
              content: Text('usbdetected-msg'.i18n()),
              severity: InfoBarSeverity.warning,
            ),
          ),
        const SizedBox(height: 10),
        Checkbox(
          checked: _bare,
          onChanged: (v) => setState(() => _bare = v ?? false),
          content: Text('bare-text'.i18n()),
        ),
        if (!_bare) ...[
          const SizedBox(height: 10),
          InfoLabel(
            label: 'customname-text'.i18n(),
            child: TextBox(
              controller: _nameController,
              placeholder: 'customnamehint-text'.i18n(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            // Bottom-aligned so the two boxes line up even when one label
            // wraps to a second line.
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: InfoLabel(
                  label: 'partition-text'.i18n(),
                  child: TextBox(
                    controller: _partitionController,
                    placeholder: 'examplepartition-text'.i18n(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InfoLabel(
                  label: 'filesystemtype-text'.i18n(),
                  child: TextBox(
                    controller: _typeController,
                    placeholder: 'examplefilesystem-text'.i18n(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InfoLabel(
            label: 'mountoptions-text'.i18n(),
            // Short example in the box; the ro/rw constraint lives in the
            // tooltip — as a placeholder the sentence clipped mid-word.
            child: Tooltip(
              message: 'mountoptionshint-text'.i18n(),
              child: TextBox(
                controller: _optionsController,
                placeholder: 'mountoptionsplaceholder-text'.i18n(),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        // Where the disk actually lands (audit ST-52).
        Text('mountlanding-text'.i18n(),
            style:
                TextStyle(fontSize: 12.0, color: secondaryTextColor(context))),
      ],
    );
  }

  Widget _buildVhdForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoLabel(
          label: 'vhdpath-text'.i18n(),
          child: Row(
            children: [
              Expanded(
                child: TextBox(
                  controller: _vhdPathController,
                  placeholder: 'examplepath-text'.i18n(),
                  onChanged: (_) => _clearFieldError(),
                  suffix: NamedIconButton(
                    label: 'choosefile-text'.i18n(),
                    icon: FluentIcons.open_folder_horizontal,
                    onPressed: () async {
                      FilePickerResult? result =
                          await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['vhdx', 'vhd'],
                      );
                      if (result != null) {
                        setState(() {
                          _vhdPathController.text = result.files.single.path!;
                          _fieldError = null;
                        });
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        _fieldErrorText(),
        const SizedBox(height: 10),
        Checkbox(
          checked: _vhdBare,
          onChanged: (v) => setState(() => _vhdBare = v ?? false),
          content: Text('bare-text'.i18n()),
        ),
        if (!_vhdBare) ...[
          const SizedBox(height: 10),
          InfoLabel(
            label: 'customname-text'.i18n(),
            child: TextBox(
              controller: _vhdNameController,
              placeholder: 'customnamehint-text'.i18n(),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            // Bottom-aligned so the two boxes line up even when one label
            // wraps to a second line.
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: InfoLabel(
                  label: 'partition-text'.i18n(),
                  child: TextBox(
                    controller: _vhdPartitionController,
                    placeholder: 'examplepartition-text'.i18n(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InfoLabel(
                  label: 'filesystemtype-text'.i18n(),
                  child: TextBox(
                    controller: _vhdTypeController,
                    placeholder: 'examplefilesystem-text'.i18n(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InfoLabel(
            label: 'mountoptions-text'.i18n(),
            child: Tooltip(
              message: 'mountoptionshint-text'.i18n(),
              child: TextBox(
                controller: _vhdOptionsController,
                placeholder: 'mountoptionsplaceholder-text'.i18n(),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        // Where the disk actually lands (audit ST-52).
        Text('mountlanding-text'.i18n(),
            style:
                TextStyle(fontSize: 12.0, color: secondaryTextColor(context))),
      ],
    );
  }

  String _formatMountName(String name) {
    if (name.startsWith('PHYSICALDRIVE')) {
      return 'physicaldrive-text'.i18n() + ' ${name.substring(13)}';
    }
    return name;
  }

  Widget _buildUnmountForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The app knows the list is empty and says so — the picker used to
        // simply vanish, leaving a free text box and a request to recall the
        // mount path from memory (audit ST-48).
        if (_mountedDisks.isEmpty) ...[
          Text('nothingmounted-text'.i18n(),
              style: TextStyle(color: secondaryTextColor(context))),
          const SizedBox(height: 10),
        ],
        if (_mountedDisks.isNotEmpty) ...[
          InfoLabel(
            label: 'selectmounteddisk-text'.i18n(),
            child: ComboBox<String>(
              isExpanded: true,
              placeholder: Text('selectdiskplaceholder-text'.i18n()),
              items: _mountedDisks
                  .map((e) => ComboBoxItem(
                        value: e,
                        child: Text(_formatMountName(e)),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _fieldError = null;
                    if (v.startsWith('PHYSICALDRIVE')) {
                      _unmountPathController.text = '\\\\.\\$v';
                    } else {
                      _unmountPathController.text = v;
                    }
                  });
                }
              },
            ),
          ),
          const SizedBox(height: 10),
        ],
        InfoLabel(
          label: 'diskpathtounmount-text'.i18n(),
          child: TextBox(
            controller: _unmountPathController,
            placeholder: 'exampleunmountpath-text'.i18n(),
            onChanged: (_) => _clearFieldError(),
          ),
        ),
        _fieldErrorText(),
        const SizedBox(height: 10),
        Text('unmountpathhint-text'.i18n()),
      ],
    );
  }
}
