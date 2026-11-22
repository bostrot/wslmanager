import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/hosts_file_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// The "Hostnames" section of Settings: whether the running instances are
/// written into the host's hosts file, under which suffix, and the two
/// buttons that do it once by hand
/// (bostrot/ai-tasks#90, bostrot/wsl2-distro-manager#214).
///
/// A section of its own rather than more lines in the Settings screen,
/// because everything it needs is its own — and because writing the hosts
/// file asks for administrator rights, which is a thing to say next to the
/// switch, not three screens away.
class HostsSettingsSection extends StatefulWidget {
  const HostsSettingsSection({super.key, this.service});

  /// Injected by the tests; the real screen lets the section build its own.
  final HostsFileService? service;

  static const Key toggleKey = ValueKey('test-hosts-sync-toggle');
  static const Key suffixKey = ValueKey('test-hosts-sync-suffix');
  static const Key syncKey = ValueKey('test-hosts-sync-now');
  static const Key clearKey = ValueKey('test-hosts-sync-clear');

  @override
  State<HostsSettingsSection> createState() => HostsSettingsSectionState();
}

class HostsSettingsSectionState extends State<HostsSettingsSection> {
  late final HostsFileService _service =
      widget.service ?? HostsFileService.instance;
  late final TextEditingController _suffixController =
      TextEditingController(text: _service.suffix);
  late bool _enabled = _service.enabled;
  bool _busy = false;
  List<HostsEntry> _entries = const [];

  @override
  void dispose() {
    _suffixController.dispose();
    super.dispose();
  }

  /// Runs [action] with the buttons disabled, and says what came of it.
  /// Every failure here is the same failure — the elevation prompt was
  /// declined — so it is reported rather than logged and swallowed.
  Future<void> _run(Future<HostsSyncResult> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await action();
      if (!mounted) return;
      setState(() => _entries = result.entries);
      Notify.message(
        _outcome(result),
        severity: InfoBarSeverity.success,
      );
    } catch (e) {
      if (!mounted) return;
      Notify.message('hostsfilefailed-text'.i18n([e.toString()]),
          severity: InfoBarSeverity.warning);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Nothing changed" and "the block is gone" are both successes, and
  /// neither is "wrote 0 hostnames".
  static String _outcome(HostsSyncResult result) {
    if (!result.changed) return 'hostsfileunchanged-text'.i18n();
    if (result.entries.isEmpty) return 'hostsfilecleared-text'.i18n();
    return 'hostsfilewritten-text'.i18n(['${result.entries.length}']);
  }

  Future<void> _toggle(bool value) async {
    await _service.setEnabled(value);
    if (!mounted) return;
    setState(() => _enabled = value);
    if (value) {
      await _run(() => _service.sync());
      _service.startAutoSync();
    } else {
      _service.stopAutoSync();
      await _run(_service.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hintStyle =
        TextStyle(color: secondaryTextColor(context), fontSize: 12);

    if (!_service.isSupported) {
      return Padding(
        padding: const EdgeInsets.all(10.0),
        child: Text('hostsfileunsupported-text'.i18n()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text('hostsfile-info-text'.i18n([_service.hostsPath])),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'hostsfilesync-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(children: [
              ToggleSwitch(
                key: HostsSettingsSection.toggleKey,
                checked: _enabled,
                onChanged: _busy ? null : _toggle,
              ),
              const SizedBox(width: 10.0),
              Expanded(
                  child:
                      Text('hostsfilesyncinfo-text'.i18n(), style: hintStyle)),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'hostsfilesuffix-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextBox(
                  key: HostsSettingsSection.suffixKey,
                  controller: _suffixController,
                  placeholder: HostsFileService.defaultSuffix,
                  onChanged: (value) => _service.setSuffix(value),
                ),
                const SizedBox(height: 4.0),
                Text('hostsfilesuffixinfo-text'.i18n(), style: hintStyle),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(children: [
            Button(
              key: HostsSettingsSection.syncKey,
              onPressed: _busy ? null : () => _run(() => _service.sync()),
              child: Text('hostsfilesyncnow-text'.i18n()),
            ),
            const SizedBox(width: 10.0),
            Button(
              key: HostsSettingsSection.clearKey,
              onPressed: _busy ? null : () => _run(_service.clear),
              child: Text('hostsfileclear-text'.i18n()),
            ),
          ]),
        ),
        if (_entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'hostsfileentries-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in _entries)
                    Text('${entry.hostname} → ${entry.ip} (${entry.instance})',
                        style: hintStyle),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
