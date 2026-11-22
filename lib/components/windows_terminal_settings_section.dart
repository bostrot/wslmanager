import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/windows_terminal_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// The "Windows Terminal" section of Settings: whether this app's instances
/// show up in the Windows Terminal dropdown, whether the entry Windows
/// Terminal generates for the same distro is hidden, and the two buttons
/// that write or remove the fragment by hand
/// (bostrot/ai-tasks#93, bostrot/wsl2-distro-manager#239).
///
/// A section of its own rather than more lines in the Settings screen. What
/// it writes is one file in the user's own AppData — Windows Terminal reads
/// it at startup, which is the one thing a user has to be told here, since
/// a profile that appears two minutes later looks like nothing happened.
class WindowsTerminalSettingsSection extends StatefulWidget {
  const WindowsTerminalSettingsSection({super.key, this.service});

  /// Injected by the tests; the real screen lets the section build its own.
  final WindowsTerminalService? service;

  static const Key toggleKey = ValueKey('test-wt-profiles-toggle');
  static const Key hideGeneratedKey = ValueKey('test-wt-hide-generated');
  static const Key syncKey = ValueKey('test-wt-sync-now');
  static const Key clearKey = ValueKey('test-wt-clear');

  @override
  State<WindowsTerminalSettingsSection> createState() =>
      WindowsTerminalSettingsSectionState();
}

class WindowsTerminalSettingsSectionState
    extends State<WindowsTerminalSettingsSection> {
  late final WindowsTerminalService _service =
      widget.service ?? WindowsTerminalService.instance;
  late bool _enabled = _service.enabled;
  late bool _hideGenerated = _service.hideGenerated;
  bool _busy = false;
  List<String> _profiles = const [];

  /// Runs [action] with the buttons disabled, and says what came of it.
  Future<void> _run(Future<WindowsTerminalResult> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await action();
      if (!mounted) return;
      setState(() => _profiles = result.names);
      Notify.message(_outcome(result), severity: InfoBarSeverity.success);
    } catch (e) {
      if (!mounted) return;
      Notify.message('windowsterminalfailed-text'.i18n([e.toString()]),
          severity: InfoBarSeverity.warning);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Nothing changed" and "the profiles are gone" are both successes, and
  /// neither is "wrote 0 profiles".
  static String _outcome(WindowsTerminalResult result) {
    if (!result.changed) return 'windowsterminalunchanged-text'.i18n();
    if (result.names.isEmpty) return 'windowsterminalcleared-text'.i18n();
    return 'windowsterminalwritten-text'.i18n(['${result.names.length}']);
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

  /// Changing what is hidden changes the file, so it is written straight
  /// away — but only when the feature is on. Off, the switch is just a
  /// preference for the next time it is turned on.
  Future<void> _toggleHideGenerated(bool value) async {
    await _service.setHideGenerated(value);
    if (!mounted) return;
    setState(() => _hideGenerated = value);
    if (_enabled) await _run(() => _service.sync());
  }

  @override
  Widget build(BuildContext context) {
    final hintStyle =
        TextStyle(color: secondaryTextColor(context), fontSize: 12);

    if (!_service.isSupported) {
      return Padding(
        padding: const EdgeInsets.all(10.0),
        child: Text('windowsterminalunsupported-text'.i18n()),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10.0),
          child:
              Text('windowsterminal-info-text'.i18n([_service.fragmentPath])),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'windowsterminalsync-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(children: [
              ToggleSwitch(
                key: WindowsTerminalSettingsSection.toggleKey,
                checked: _enabled,
                onChanged: _busy ? null : _toggle,
              ),
              const SizedBox(width: 10.0),
              Expanded(
                  child: Text('windowsterminalsyncinfo-text'.i18n(),
                      style: hintStyle)),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'windowsterminalhidegenerated-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(children: [
              ToggleSwitch(
                key: WindowsTerminalSettingsSection.hideGeneratedKey,
                checked: _hideGenerated,
                onChanged: _busy ? null : _toggleHideGenerated,
              ),
              const SizedBox(width: 10.0),
              Expanded(
                  child: Text('windowsterminalhidegeneratedinfo-text'.i18n(),
                      style: hintStyle)),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(children: [
            Button(
              key: WindowsTerminalSettingsSection.syncKey,
              onPressed: _busy ? null : () => _run(() => _service.sync()),
              child: Text('windowsterminalsyncnow-text'.i18n()),
            ),
            const SizedBox(width: 10.0),
            Button(
              key: WindowsTerminalSettingsSection.clearKey,
              onPressed: _busy ? null : () => _run(_service.clear),
              child: Text('windowsterminalclear-text'.i18n()),
            ),
          ]),
        ),
        if (_profiles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'windowsterminalprofiles-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final name in _profiles) Text(name, style: hintStyle),
                  const SizedBox(height: 4.0),
                  Text('windowsterminalrestart-text'.i18n(), style: hintStyle),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
