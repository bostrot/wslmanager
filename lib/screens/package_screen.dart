// The custom-distro distribution screen: `/etc/wsl-distribution.conf`,
// `.wsl` packaging, and `wsl --install --from-file`.
//
// ## Why this is a screen and not a dialog
//
// Phase 05 asks for the **L**-sized surfaces to follow `create_screen.dart`'s
// precedent — a dedicated screen for anything with long-running progress. That
// is not a formality here: packaging a distro is `wsl --export` over the whole
// root filesystem, routinely several gigabytes and several minutes, and
// installing a `.wsl` is the same amount of work in the other direction. A
// dialog hides the progress notifications behind itself and invites an
// accidental dismiss halfway through.
//
// It is also more than one step. The distribution config has to be *right*
// before the export happens, because the export is what freezes it into the
// package — so the config editor, the readiness check and the packaging button
// belong on one surface, in that order, where the user can see the checks turn
// green before spending the minutes.
//
// The findings this closes are in doc/audit/wsl-docs/features.md F-8 and the
// ordered list's P05-24.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/distro_package.dart';
import 'package:wsl2distromanager/api/wsl_capabilities.dart';
import 'package:wsl2distromanager/api/wsl_distribution_conf.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/debounced_text_box.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// How this screen reaches WSL and the filesystem. The seam the widget tests
/// replace, matching `settings_dialog.dart`'s `wslApiBuilder` and
/// `disk_dialog.dart`'s `diskApiBuilder`.
DistroPackager Function() packagerBuilder = () => DistroPackager();

/// The `.wsl` file the install section starts with, so a test does not have to
/// drive a native file-picker dialog. Null means "ask the user".
String? Function()? packageFilePicker;

/// One documented `wsl-distribution.conf` key, with everything the editor
/// needs to render it. The same shape as `settings_dialog.dart`'s
/// [WslConfSetting] — deliberately, because it is the same job — but keyed on
/// the file rather than on a `SharedPreferences` mirror: this screen holds the
/// parsed file in state, so there is nothing to keep in step.
class DistributionConfSetting {
  final String section;
  final String key;
  final String labelKey;
  final String infoKey;
  final bool isToggle;

  /// What WSL does when the key is absent, where the reference table states
  /// it. Both documented booleans default to **on**, so a switch rendered from
  /// a missing key shows the opposite of the truth unless this is honoured —
  /// the same trap as `wsl.conf` CC-3.
  final bool? defaultOn;

  final String? placeholder;

  const DistributionConfSetting.toggle(
    this.section,
    this.key,
    this.labelKey,
    this.infoKey, {
    this.defaultOn,
  })  : isToggle = true,
        placeholder = null;

  const DistributionConfSetting.text(
    this.section,
    this.key,
    this.labelKey,
    this.infoKey, {
    this.placeholder,
  })  : isToggle = false,
        defaultOn = null;
}

/// Every documented `wsl-distribution.conf` key, in the order the editor
/// renders them — `[oobe]` first, because it is the section that decides
/// whether the packaged distro is usable at all.
const List<DistributionConfSetting> distributionConfSettings =
    <DistributionConfSetting>[
  DistributionConfSetting.text(
      'oobe', 'defaultName', 'oobedefaultname-text', 'oobedefaultnameinfo-text',
      placeholder: 'my-distro'),
  DistributionConfSetting.text(
      'oobe', 'command', 'oobecommand-text', 'oobecommandinfo-text',
      placeholder: kDefaultOobeScriptPath),
  DistributionConfSetting.text(
      'oobe', 'defaultUid', 'oobedefaultuid-text', 'oobedefaultuidinfo-text',
      placeholder: kDefaultOobeUid),
  DistributionConfSetting.toggle(
      'shortcut', 'enabled', 'shortcutenabled-text', 'shortcutenabledinfo-text',
      defaultOn: true),
  DistributionConfSetting.text(
      'shortcut', 'icon', 'shortcuticon-text', 'shortcuticoninfo-text',
      placeholder: '/usr/lib/wsl/my-icon.ico'),
  DistributionConfSetting.toggle('windowsterminal', 'enabled',
      'terminalprofileenabled-text', 'terminalprofileenabledinfo-text',
      defaultOn: true),
  DistributionConfSetting.text('windowsterminal', 'profileTemplate',
      'terminalprofiletemplate-text', 'terminalprofiletemplateinfo-text',
      placeholder: '/usr/lib/wsl/terminal-profile.json'),
];

/// i18n key of each section's header.
const Map<String, String> distributionConfSectionLabels = <String, String>{
  'oobe': 'oobe-text',
  'shortcut': 'shortcut-text',
  'windowsterminal': 'windowsterminal-text',
};

/// Custom-distro distribution screen.
class PackagePage extends StatefulWidget {
  const PackagePage({super.key});

  @override
  State<PackagePage> createState() => PackagePageState();
}

class PackagePageState extends State<PackagePage> {
  final TextEditingController _outputController = TextEditingController();
  final TextEditingController _installNameController = TextEditingController();

  List<String> _distros = <String>[];
  String? _selected;

  WslCapabilities? _capabilities;
  WslDistributionConfFile? _conf;
  DistroPackageInspection _inspection = const DistroPackageInspection();

  /// Null when the distro was reachable. Set when it was not — which is a
  /// different state from "the file is empty", and the editor must not offer
  /// to write into a distro it could not read.
  bool _unreachable = false;

  String _format = kWslPackageFormats.first;
  String? _installFile;

  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'package');
    _load();
  }

  @override
  void dispose() {
    _outputController.dispose();
    _installNameController.dispose();
    super.dispose();
  }

  bool get _supported => _capabilities?.supportsWslPackages ?? false;

  Future<void> _load() async {
    setState(() => _loading = true);

    final packager = packagerBuilder();
    final capabilities = await packager.api.capabilities.load();
    final instances = await packager.api.list(false);

    if (!mounted) return;
    setState(() {
      _capabilities = capabilities;
      _distros = instances.all;
      _selected = _distros.contains(_selected)
          ? _selected
          : (_distros.isNotEmpty ? _distros.first : null);
      _loading = false;
    });

    await _loadDistro();
  }

  /// Read the selected distro's distribution config and probe it.
  Future<void> _loadDistro() async {
    final distro = _selected;
    if (distro == null) {
      setState(() {
        _conf = null;
        _unreachable = false;
      });
      return;
    }

    setState(() => _busy = true);
    final packager = packagerBuilder();
    final conf = await packager.readConf(distro);
    final inspection = conf == null
        ? const DistroPackageInspection()
        : await packager.inspect(distro, conf);

    if (!mounted) return;
    setState(() {
      _conf = conf;
      _unreachable = conf == null;
      _inspection = inspection;
      _busy = false;
      if (_outputController.text.isEmpty) {
        _outputController.text = packager.defaultPackageFile(distro);
      }
    });
  }

  Future<void> _selectDistro(String? distro) async {
    if (distro == null || distro == _selected) return;
    // The default output file is named after the distro, so a distro change
    // has to move it — otherwise the second package silently overwrites the
    // first one's file.
    setState(() {
      _selected = distro;
      _outputController.text = packagerBuilder().defaultPackageFile(distro);
    });
    await _loadDistro();
  }

  /// Write one key, or remove it when [value] is null.
  Future<void> _write(DistributionConfSetting setting, String? value) async {
    final distro = _selected;
    final conf = _conf;
    if (distro == null || conf == null) return;

    setState(() => _busy = true);
    final api = packagerBuilder().api;
    final ok = value == null
        ? await api.removeDistributionSetting(
            distro, setting.section, setting.key)
        : await api.setDistributionSetting(
            distro, setting.section, setting.key, value);

    if (!mounted) return;
    if (!ok) {
      setState(() => _busy = false);
      Notify.message('wslconfwritefailed-text'.i18n([setting.labelKey.i18n()]));
      return;
    }
    // Re-read rather than mutating the local copy: the write is what decides
    // what is in the file, and a screen that shows its own optimistic guess is
    // how a failed write reads as a successful one.
    await _loadDistro();
  }

  Future<void> _writeSampleOobe() async {
    final distro = _selected;
    if (distro == null) return;

    setState(() => _busy = true);
    Notify.message('writingoobescript-text'.i18n(), loading: true);
    final ok = await packagerBuilder().writeSampleOobe(distro);
    if (!mounted) return;
    Notify.message(ok
        ? 'wroteoobescript-text'.i18n([kDefaultOobeScriptPath])
        : 'wslconfwritefailed-text'.i18n([kDefaultOobeScriptPath]));
    await _loadDistro();
  }

  Future<void> _package() async {
    final distro = _selected;
    if (distro == null) return;
    final output = _outputController.text.trim();
    if (output.isEmpty) {
      Notify.message('packagenopath-text'.i18n());
      return;
    }

    setState(() => _busy = true);
    Notify.message('packaging-text'.i18n([distroLabel(distro)]), loading: true);

    // The 8-second rule (`wsl-config.md:20-26`): an export of a running distro
    // captures a filesystem mid-write. Stop this one first — per distro, not a
    // global shutdown (runtime R-12).
    final packager = packagerBuilder();
    await packager.api.stop(distro);
    final result = await packager.package(distro, output, format: _format);

    if (!mounted) return;
    setState(() => _busy = false);
    Notify.message(result.ok
        ? 'packaged-text'.i18n([result.path ?? output])
        : 'packagefailed-text'.i18n([result.error ?? '']));
  }

  Future<void> _pickOutput() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'packageoutput-text'.i18n(),
      fileName: _outputController.text.isEmpty
          ? 'distro.wsl'
          : _outputController.text.split(Platform.pathSeparator).last,
      type: FileType.any,
    );
    if (path == null || !mounted) return;
    setState(() => _outputController.text = path);
  }

  Future<void> _pickInstallFile() async {
    final injected = packageFilePicker?.call();
    if (injected != null) {
      setState(() => _installFile = injected);
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'installfromfile-text'.i18n(),
      type: FileType.any,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _installFile = path);
  }

  Future<void> _install() async {
    final path = _installFile;
    if (path == null) {
      Notify.message('packagenofile-text'.i18n());
      return;
    }

    setState(() => _busy = true);
    Notify.message('installingpackage-text'.i18n(), loading: true);
    final name = _installNameController.text.trim();
    final result =
        await packagerBuilder().install(path, name: name.isEmpty ? null : name);

    if (!mounted) return;
    setState(() => _busy = false);
    // wsl.exe reports refusals on stderr with exit code 0, so the text is
    // carried through either way rather than replaced with a verdict of ours
    // (audit runtime R-1, R-4).
    Notify.message(result.ok
        ? 'installedpackage-text'.i18n([result.text])
        : 'installpackagefailed-text'.i18n([result.text]));
    if (result.ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: ProgressRing());
    }

    final theme = FluentTheme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('custompackage-text'.i18n(),
                style: theme.typography.titleLarge),
            const SizedBox(height: 4),
            Text('custompackageinfo-text'.i18n(),
                style: theme.typography.caption),
            const SizedBox(height: 16),

            // Everything on this screen needs WSL 2.4.4
            // (`build-custom-distro.md:16`). Saying so beats letting
            // `--from-file` come back as "Invalid command line option".
            if (!_supported)
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: InfoBar(
                  title: Text('requireswsl-text'.i18n(['2.4.4'])),
                  content: Text('custompackageunsupported-text'.i18n()),
                  severity: InfoBarSeverity.warning,
                  isLong: true,
                ),
              ),

            _distributionConfSection(theme),
            const SizedBox(height: 24),
            _readinessSection(theme),
            const SizedBox(height: 24),
            _packageSection(theme),
            const SizedBox(height: 24),
            _installSection(theme),
          ],
        ),
      ),
    );
  }

  Widget _heading(String key, String infoKey, FluentThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(key.i18n(), style: theme.typography.subtitle),
          const SizedBox(height: 2),
          Text(infoKey.i18n(), style: theme.typography.caption),
          const SizedBox(height: 8),
        ],
      );

  Widget _distributionConfSection(FluentThemeData theme) {
    final conf = _conf;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('distributionconf-text', 'distributionconfinfo-text', theme),
        Row(
          children: [
            Expanded(
              child: ComboBox<String>(
                key: const ValueKey('test-package-distro'),
                isExpanded: true,
                value: _selected,
                placeholder: Text('selectdistro-text'.i18n()),
                items: <ComboBoxItem<String>>[
                  for (final distro in _distros)
                    ComboBoxItem<String>(
                        value: distro, child: Text(distroLabel(distro))),
                ],
                onChanged: _busy ? null : _selectDistro,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_unreachable)
          InfoBar(
            title: Text('distrounreachable-text'.i18n()),
            severity: InfoBarSeverity.error,
          )
        else if (conf != null) ...[
          for (final section in distributionConfSectionLabels.entries) ...[
            Expander(
              header: Text(section.value.i18n()),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final setting in distributionConfSettings
                      .where((s) => s.section == section.key))
                    _field(conf, setting, theme),
                  if (section.key == 'oobe')
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('writeoobescriptinfo-text'.i18n(),
                              style: theme.typography.caption),
                          const SizedBox(height: 4),
                          Button(
                            key: const ValueKey('test-package-oobe'),
                            onPressed: _busy ? null : _writeSampleOobe,
                            child: Text('writeoobescript-text'.i18n()),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  /// One key, rendered as its documented value type.
  Widget _field(WslDistributionConfFile conf, DistributionConfSetting setting,
      FluentThemeData theme) {
    final value = conf.get(setting.section, setting.key);
    final isSet = value != null;

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (setting.isToggle) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2.0),
            child: ToggleSwitch(
              checked: isSet
                  ? value.trim().toLowerCase() == 'true'
                  : (setting.defaultOn ?? false),
              onChanged:
                  _busy ? null : (v) => _write(setting, v ? 'true' : 'false'),
            ),
          ),
          const SizedBox(width: 8.0),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(setting.labelKey.i18n()),
              const SizedBox(height: 2.0),
              Text(setting.infoKey.i18n(), style: theme.typography.caption),
              if (!isSet)
                Text('settingunset-text'.i18n(),
                    style: theme.typography.caption
                        ?.copyWith(color: theme.accentColor)),
            ],
          ),
        ),
        // The third state: removing the line is what lets WSL's own default
        // apply again. Writing the default back is not the same thing.
        if (isSet)
          NamedIconButton(
            label: 'resettodefault-text'.i18n(),
            icon: FluentIcons.undo,
            onPressed: _busy ? null : () => _write(setting, null),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (!setting.isToggle) ...[
            const SizedBox(height: 4.0),
            DebouncedTextBox(
              key: ValueKey('${setting.section}-${setting.key}-$_selected'),
              initialValue: value ?? '',
              placeholder: setting.placeholder,
              enabled: !_busy,
              // An emptied box means unset, which removes the line rather than
              // pinning the key to an empty value.
              onCommit: (text) =>
                  _write(setting, text.isEmpty ? null : text.trim()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _readinessSection(FluentThemeData theme) {
    final conf = _conf;
    if (conf == null) return const SizedBox.shrink();

    final issues = packageIssues(conf, _inspection);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('packagereadiness-text', 'packagereadinessinfo-text', theme),
        if (issues.isEmpty)
          InfoBar(
            key: const ValueKey('test-package-ready'),
            title: Text('packageready-text'.i18n()),
            severity: InfoBarSeverity.success,
          )
        else
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(bottom: 6.0),
              child: InfoBar(
                title: Text(issue.messageKey.i18n(issue.args)),
                severity: issue.isError
                    ? InfoBarSeverity.error
                    : InfoBarSeverity.warning,
                isLong: true,
              ),
            ),
      ],
    );
  }

  Widget _packageSection(FluentThemeData theme) {
    final canPackage =
        _supported && !_busy && _selected != null && !_unreachable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('packagedistro-text', 'packagedistroinfo-text', theme),
        Row(
          children: [
            Expanded(
              child: TextBox(
                controller: _outputController,
                enabled: !_busy,
                placeholder: 'C:\\WSL2-Distros\\packages\\my-distro.wsl',
              ),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: _busy ? null : _pickOutput,
              child: Text('selectfile-text'.i18n()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            ComboBox<String>(
              value: _format,
              items: <ComboBoxItem<String>>[
                for (final format in kWslPackageFormats)
                  ComboBoxItem<String>(value: format, child: Text(format)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _format = value ?? _format),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('packageformatinfo-text'.i18n(),
                  style: theme.typography.caption),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('test-package-button'),
          onPressed: canPackage ? _package : null,
          child: _busy
              ? const SizedBox.square(
                  dimension: 16, child: ProgressRing(strokeWidth: 2.0))
              : Text('createpackage-text'.i18n()),
        ),
      ],
    );
  }

  Widget _installSection(FluentThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('installfromfile-text', 'installfromfileinfo-text', theme),
        Row(
          children: [
            Expanded(
              child: Text(_installFile ?? 'packagenofile-text'.i18n(),
                  style: theme.typography.caption),
            ),
            const SizedBox(width: 8),
            Button(
              key: const ValueKey('test-package-pick'),
              onPressed: _busy ? null : _pickInstallFile,
              child: Text('selectfile-text'.i18n()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        InfoLabel(
          label: 'name-text'.i18n(),
          child: TextBox(
            controller: _installNameController,
            enabled: !_busy,
            placeholder: 'my-distro',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('test-install-button'),
          onPressed:
              (_supported && !_busy && _installFile != null) ? _install : null,
          child: Text('installpackage-text'.i18n()),
        ),
      ],
    );
  }
}
