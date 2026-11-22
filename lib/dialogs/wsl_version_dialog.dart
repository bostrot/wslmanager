// The WSL-version surface: what each installed distro runs on, and what a
// newly created one will run on (upstream bostrot/wsl2-distro-manager#103).
//
// Both halves existed underneath and neither was reachable. `--set-version`
// was an [WSLApi] method only the MCP server called, and `--set-default-version`
// was not implemented at all — so the app could create a distro without being
// able to say, or choose, which WSL it would be created as.
//
// One dialog rather than a control per distro row: the two questions are the
// same question at two scopes, the per-distro answer is a table that wants to
// be read down, and the distro list's action strip is already nine buttons
// wide (audit LN-04).
//
// Conversion is confirmed before it runs. `wsl --set-version` rewrites the
// whole disk — minutes on a large distro, during which the distro is
// unusable — which is the same class of operation as Move, and Move asks
// (audit ST-29).

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/wsl_version.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';

/// How this dialog reaches WSL. The seam widget tests replace to keep
/// `wsl.exe` out of them, matching `diskApiBuilder` and `wslApiBuilder`.
WslVersionService Function() wslVersionServiceBuilder =
    () => WslVersionService();

/// Open the dialog.
///
/// [hostContext] is required rather than taken from `GlobalVariable.infobox`:
/// the only caller is the Settings screen, and that key belongs to Home — on
/// another route it resolves to an unmounted element (audit ST-04).
/// Resolves when the dialog closes, so a caller showing the default version
/// of its own can re-read it.
Future<void> wslVersionDialog(BuildContext hostContext,
    {bool showDocker = false}) {
  plausible.event(page: 'wsl_version_dialog');

  return showDialog<void>(
    context: hostContext,
    builder: (childContext) => ContentDialog(
      constraints: const BoxConstraints(maxHeight: 620.0, maxWidth: 560.0),
      title: Text('wslversions-text'.i18n()),
      content: WslVersionDialogContent(showDocker: showDocker),
      actions: [
        Button(
          child: Text('close-text'.i18n()),
          onPressed: () => Navigator.pop(childContext),
        ),
      ],
    ),
  );
}

class WslVersionDialogContent extends StatefulWidget {
  final bool showDocker;

  const WslVersionDialogContent({super.key, this.showDocker = false});

  @override
  State<WslVersionDialogContent> createState() =>
      WslVersionDialogContentState();
}

class WslVersionDialogContentState extends State<WslVersionDialogContent> {
  WslVersionSnapshot? _snapshot;
  bool _loading = true;

  /// Set while a conversion or a default-version write is in flight. Every
  /// control reads it: two `--set-version` calls at once on the same host is
  /// not a state wsl.exe recovers from cleanly.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final snapshot =
        await wslVersionServiceBuilder().load(showDocker: widget.showDocker);
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

  Future<void> _setDefaultVersion(int version) async {
    setState(() => _busy = true);
    final result = await wslVersionServiceBuilder().setDefaultVersion(version);
    if (!mounted) return;
    setState(() => _busy = false);
    Notify.message(
      result.ok
          ? 'defaultwslversionset-text'.i18n(['$version'])
          : 'defaultwslversionfailed-text'.i18n([result.text]),
      severity: result.ok ? InfoBarSeverity.success : InfoBarSeverity.error,
    );
    if (result.ok) await _load();
  }

  /// Ask first, then convert. The confirmation says what it costs, because a
  /// disk rewrite that starts silently looks like the app has hung.
  void _confirmConvert(String distro, int version) {
    dialog(
      hostContext: context,
      item: distro,
      title: 'convertwslversion-text'.i18n([distroLabel(distro), '$version']),
      body: 'convertwslversionbody-text'.i18n(),
      submitText: 'converttowsl-text'.i18n(['$version']),
      submitInput: false,
      cancelText: 'cancel-text'.i18n(),
      onSubmit: (_) => _convert(distro, version),
    );
  }

  Future<void> _convert(String distro, int version) async {
    setState(() => _busy = true);
    Notify.message(
        'convertingwslversion-text'.i18n([distroLabel(distro), '$version']),
        loading: true);

    final result = await wslVersionServiceBuilder().convert(distro, version);

    if (!mounted) return;
    setState(() => _busy = false);
    Notify.message(
      result.ok
          ? 'convertedwslversion-text'.i18n([distroLabel(distro), '$version'])
          : 'convertwslversionfailed-text'
              .i18n([distroLabel(distro), result.text]),
      severity: result.ok ? InfoBarSeverity.success : InfoBarSeverity.error,
    );
    if (result.ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(height: 200, child: Center(child: ProgressRing()));
    }

    final theme = FluentTheme.of(context);
    final snapshot = _snapshot ?? const WslVersionSnapshot();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('wslversionsinfo-text'.i18n(), style: theme.typography.caption),
          const SizedBox(height: 16.0),
          Text('defaultwslversion-text'.i18n(),
              style: const TextStyle(fontWeight: FontWeight.w500)),
          Text('defaultwslversioninfo-text'.i18n(),
              style: theme.typography.caption),
          const SizedBox(height: 6.0),
          ComboBox<int>(
            key: const ValueKey('test-wsl-default-version-combo'),
            value: wslVersions.contains(snapshot.defaultVersion)
                ? snapshot.defaultVersion
                : null,
            // Nothing pre-selected when `wsl --status` did not say, rather
            // than a guess of 2: the placeholder is honest and picking a
            // value from it still writes.
            placeholder: Text('wslversionunknown-text'.i18n()),
            items: [
              for (final version in wslVersions)
                ComboBoxItem<int>(
                  value: version,
                  child: Text('wslversionvalue-text'.i18n(['$version'])),
                ),
            ],
            onChanged: _busy
                ? null
                : (version) {
                    if (version == null) return;
                    if (version == snapshot.defaultVersion) return;
                    _setDefaultVersion(version);
                  },
          ),
          const SizedBox(height: 20.0),
          const Divider(),
          const SizedBox(height: 12.0),
          Text('installeddistroversions-text'.i18n(),
              style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 6.0),
          if (!snapshot.ok)
            Text('wslversionsunavailable-text'.i18n([snapshot.error ?? '']),
                style: TextStyle(color: Colors.warningPrimaryColor))
          else if (snapshot.distros.isEmpty)
            Text('noinstancesfound-text'.i18n(),
                style: theme.typography.caption)
          else
            for (final distro in snapshot.distros) _distroRow(distro, theme),
        ],
      ),
    );
  }

  Widget _distroRow(WslDistroVersion distro, FluentThemeData theme) {
    // Two versions exist, so the button names the other one — a combo box
    // over a binary choice reads as a setting that might not apply, and this
    // one starts a disk rewrite.
    final target = distro.version == 1 ? 2 : 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(distroLabel(distro.name)),
                Text(
                  distro.isDefault
                      ? '${'wslversionvalue-text'.i18n([
                              '${distro.version}'
                            ])} · ${'wsldefaultdistro-text'.i18n()}'
                      : 'wslversionvalue-text'.i18n(['${distro.version}']),
                  style: theme.typography.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12.0),
          Button(
            key: ValueKey('test-wsl-convert-${distro.name}'),
            onPressed:
                _busy ? null : () => _confirmConvert(distro.name, target),
            child: Text('converttowsl-text'.i18n(['$target'])),
          ),
        ],
      ),
    );
  }
}
