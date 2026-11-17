// The disk-space surface: how big a distro's disk is, how much of it is
// actually in use, and the two supported ways to do something about it.
//
// ## Why this file exists
//
// `disk-space.md` is a whole documented workflow and the app implemented one
// third of one step of it: `[wsl2] defaultVhdSize`, a plain text box on the
// global settings screen (doc/audit/wsl-docs/features.md F-11). There was no
// usage display, no `--system` invocation, no resize and no reclaim — and
// `grep -rni "resize" lib/` found only a window-resize handler.
//
// The two numbers are the point, and they are different numbers:
//
// * **Allocated** is the length of `ext4.vhdx` on the Windows filesystem. The
//   app already reads it for `move()`'s safety floor and for the size shown in
//   the distro list.
// * **Used** is what the distro's own filesystem reports, read the documented
//   way — `wsl --system df /mnt/wslg/distro` (`disk-space.md:30`).
//
// A VHD never shrinks on its own, so allocated ≫ used is the normal state and
// the gap between the two is exactly what `--manage --set-sparse` reclaims.
// Showing one number without the other is what made #133 ("disk shrinking") and
// #303 ("Compact fills the drive") separate mysteries rather than one feature.
//
// `--manage` is WSL 2.5+, so every control that needs it is gated on
// [WslCapabilities.supportsManage] and says so when it is missing, rather than
// failing at the point of use with wsl.exe's own "Invalid command line option".

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_capabilities.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// How the disk dialog reaches WSL. The seam widget tests replace to keep
/// `wsl.exe` out of them, matching `settings_dialog.dart`'s `wslApiBuilder`.
WSLApi Function() diskApiBuilder = () => WSLApi();

/// A `--manage --resize` argument, or null when [text] is not one.
///
/// `disk-space.md:52-58` is explicit that **decimals are unsupported** —
/// `2.5TB` is rejected by wsl.exe — so this refuses them here, where the reason
/// can be shown, rather than letting the user find out from a failed command.
String? normalizeResizeSize(String text) {
  final match =
      RegExp(r'^\s*(\d+)\s*(B|M|MB|G|GB|T|TB)?\s*$', caseSensitive: false)
          .firstMatch(text);
  if (match == null) return null;
  final amount = int.tryParse(match.group(1)!);
  if (amount == null || amount <= 0) return null;
  final unit = (match.group(2) ?? 'GB').toUpperCase();
  return '$amount$unit';
}

void diskDialog(String item) {
  final context = GlobalVariable.infobox.currentContext!;
  plausible.event(page: 'disk_dialog');

  showDialog(
    context: context,
    builder: (childContext) => ContentDialog(
      constraints: const BoxConstraints(maxHeight: 560.0, maxWidth: 520.0),
      title: Text('${'diskusage-text'.i18n()} — ${distroLabel(item)}'),
      content: DiskDialogContent(item: item),
      actions: [
        Button(
          child: Text('close-text'.i18n()),
          onPressed: () => Navigator.pop(childContext),
        ),
      ],
    ),
  );
}

class DiskDialogContent extends StatefulWidget {
  final String item;

  const DiskDialogContent({super.key, required this.item});

  @override
  State<DiskDialogContent> createState() => DiskDialogContentState();
}

class DiskDialogContentState extends State<DiskDialogContent> {
  final TextEditingController _resizeController = TextEditingController();

  WslDiskUsage? _usage;
  int? _allocatedBytes;
  WslCapabilities? _capabilities;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _resizeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    // Allocated comes from the file, resolved through findVhdxPath rather than
    // the stale `Path_` preference — the registry is what WSL itself reads.
    final vhdxPath = findVhdxPath(widget.item);
    int? allocated;
    if (vhdxPath != null) {
      try {
        allocated = File(vhdxPath).lengthSync();
      } on FileSystemException {
        allocated = null;
      }
    }

    // Through the API instance rather than the app-wide singleton, so a test's
    // fake wsl.exe is the one that decides whether `--manage` is offered.
    final api = diskApiBuilder();
    final capabilities = await api.capabilities.load();
    final usage = await api.diskUsage(widget.item);

    if (!mounted) return;
    setState(() {
      _allocatedBytes = allocated;
      _capabilities = capabilities;
      _usage = usage;
      _loading = false;
    });
  }

  bool get _canManage => _capabilities?.supportsManage ?? false;

  Future<void> _resize() async {
    final size = normalizeResizeSize(_resizeController.text);
    if (size == null) {
      Notify.message('resizediskinvalid-text'.i18n());
      return;
    }

    setState(() => _busy = true);
    Notify.message('resizingdisk-text'.i18n([distroLabel(widget.item)]),
        loading: true);

    // `disk-space.md:52` requires the VM to be shut down first, and the failure
    // when it is not is a locked-file error that says nothing about why.
    final api = diskApiBuilder();
    await api.shutdown();
    final result = await api.manageResize(widget.item, size);

    if (!mounted) return;
    setState(() => _busy = false);
    Notify.message(
        result.ok
            ? 'resizeddisk-text'.i18n([distroLabel(widget.item), size])
            : 'resizediskfailed-text'.i18n([result.text]),
        severity: result.ok ? InfoBarSeverity.success : InfoBarSeverity.error);
    if (result.ok) await _load();
  }

  Future<void> _setSparse(bool sparse) async {
    setState(() => _busy = true);
    Notify.message('settingsparse-text'.i18n(), loading: true);

    final api = diskApiBuilder();
    await api.stop(widget.item);
    final result = await api.manageSetSparse(widget.item, sparse);

    if (!mounted) return;
    setState(() => _busy = false);
    Notify.message(
        result.ok
            ? 'sparseset-text'.i18n([sparse ? 'true' : 'false'])
            : 'sparsefailed-text'.i18n([result.text]),
        severity: result.ok ? InfoBarSeverity.success : InfoBarSeverity.error);
    if (result.ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(height: 200, child: Center(child: ProgressRing()));
    }

    final theme = FluentTheme.of(context);
    final usage = _usage;
    final allocated = _allocatedBytes;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (allocated != null)
            _row('diskallocated-text'.i18n(), formatBytes(allocated),
                'diskallocatedinfo-text'.i18n(), theme),
          if (usage != null) ...[
            _row('diskused-text'.i18n(), formatBytes(usage.usedBytes),
                'diskusedinfo-text'.i18n(), theme),
            _row('diskfree-text'.i18n(), formatBytes(usage.availableBytes), '',
                theme),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: ProgressBar(
                  value: (usage.usedFraction * 100).clamp(0, 100).toDouble()),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text('diskusageunavailable-text'.i18n(),
                  style: theme.typography.caption),
            ),

          // Everything below needs `--manage`, which arrived in WSL 2.5. Saying
          // so is the point of P05-08: the alternative is a button that fails
          // with wsl.exe's untranslated "Invalid command line option".
          if (!_canManage)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: Text('requireswsl-text'.i18n(['2.5']),
                  style: TextStyle(color: Colors.warningPrimaryColor)),
            ),

          const SizedBox(height: 12.0),
          Text('resizedisk-text'.i18n(),
              style: const TextStyle(fontWeight: FontWeight.w500)),
          Text('resizediskinfo-text'.i18n(), style: theme.typography.caption),
          const SizedBox(height: 4.0),
          Row(
            children: [
              Expanded(
                child: TextBox(
                  controller: _resizeController,
                  enabled: _canManage && !_busy,
                  placeholder: '256GB',
                ),
              ),
              const SizedBox(width: 8.0),
              Button(
                onPressed: (_canManage && !_busy) ? _resize : null,
                child: Text('resizedisk-text'.i18n()),
              ),
            ],
          ),

          const SizedBox(height: 16.0),
          Text('setsparse-text'.i18n(),
              style: const TextStyle(fontWeight: FontWeight.w500)),
          Text('setsparseinfo-text'.i18n(), style: theme.typography.caption),
          const SizedBox(height: 4.0),
          Row(
            children: [
              Button(
                onPressed:
                    (_canManage && !_busy) ? () => _setSparse(true) : null,
                child: Text('setsparseon-text'.i18n()),
              ),
              const SizedBox(width: 8.0),
              Button(
                onPressed:
                    (_canManage && !_busy) ? () => _setSparse(false) : null,
                child: Text('setsparseoff-text'.i18n()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, String info, FluentThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          if (info.isNotEmpty) Text(info, style: theme.typography.caption),
        ],
      ),
    );
  }
}
