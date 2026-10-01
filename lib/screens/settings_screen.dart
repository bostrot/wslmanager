import 'dart:async' show unawaited;
import 'dart:io' show Platform;
import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/backup_settings_section.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/ai_workspace/shared_settings.dart';
import 'package:wsl2distromanager/api/apple/guest_greeting.dart';
import 'package:wsl2distromanager/api/containers/container_models.dart';
import 'package:wsl2distromanager/api/containers/container_service.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_service.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/mcp/cloudflare_tunnel_service.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_service.dart';
import 'package:wsl2distromanager/api/remote_target.dart';
import 'package:wsl2distromanager/api/web/web_dashboard_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/updater.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/api/wsl_capabilities.dart';
import 'package:wsl2distromanager/api/wslconfig.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/debounced_text_box.dart';
import 'package:wsl2distromanager/components/experimental_features_section.dart';
import 'package:wsl2distromanager/components/hosts_settings_section.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';
import 'package:wsl2distromanager/components/windows_terminal_settings_section.dart';
import 'package:wsl2distromanager/components/wsl_size.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:wsl2distromanager/dialogs/update_dialog.dart';
import 'package:wsl2distromanager/dialogs/wsl_version_dialog.dart';
import 'package:system_info2/system_info2.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'package:wsl2distromanager/theme.dart';

/// How a `.wslconfig` key is rendered. One member per documented value type in
/// `wsl-config.md`: `size` is byte-valued and carries an optional unit suffix,
/// `number` is a plain count, and `enumeration` is a closed set of values that
/// must not be typeable by hand (doc/audit/wsl-docs/ P05-09, P05-11).
enum SettingsType { bool, text, size, number, enumeration }

/// Asks before `wsl --shutdown`, then runs [onConfirmed].
///
/// Both buttons that call `WSLApi().restart()` stop *every* running instance
/// and kill every process inside them, including an editor open over `\\wsl$`.
/// Neither said so and neither asked (audit ST-04).
void confirmStopWsl(BuildContext context, VoidCallback onConfirmed) {
  dialog(
    hostContext: context,
    item: '',
    title: 'stopwslquestion-text'.i18n(),
    body: 'stopwslbody-text'.i18n(),
    submitText: 'stopwsl-text'.i18n(),
    submitInput: false,
    submitStyle: ButtonStyle(
      backgroundColor: ButtonState.all(Colors.red),
      foregroundColor: ButtonState.all(Colors.white),
    ),
    onSubmit: (_) => onConfirmed(),
  );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  SettingsPageState createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  Map<String, TextEditingController> _settings =
      <String, TextEditingController>{};

  /// The `.wslconfig` file as it was read, mutated in place by Save.
  WslConfigFile? _config;

  /// Every documented key's value at load time.
  ///
  /// Save compares against this and writes **only** what changed. That is what
  /// makes "load → Save leaves the file byte-identical apart from the key the
  /// user edited" true: the old loop re-emitted every non-empty key into
  /// `[wsl2]` on every Save, which is how a hand-added `[experimental]` key was
  /// silently relocated into a section WSL ignores it in (audit CC-3, R-4).
  Map<String, String> _loadedConfig = <String, String>{};

  /// What the installed wsl.exe can do, once the probe answers.
  WslCapabilities? _capabilities;

  final TextEditingController _syncIpTextController = TextEditingController();
  final TextEditingController _syncPasswordController = TextEditingController();
  final TextEditingController _repoTextController = TextEditingController();
  final TextEditingController _dockerrepoController = TextEditingController();
  final TextEditingController _editorController = TextEditingController();
  final TextEditingController _terminalController = TextEditingController();
  final TextEditingController _vscodeController = TextEditingController();
  final TextEditingController _dockerMirrorController = TextEditingController();
  final TextEditingController _remoteWslTargetController =
      TextEditingController();
  final TextEditingController _byokBaseUrlController = TextEditingController();
  final TextEditingController _byokApiKeyController = TextEditingController();
  final TextEditingController _byokModelController = TextEditingController();
  List<String> _modelSuggestions = [];
  bool _modelsLoading = false;
  bool _aiTestBusy = false;
  bool _useRemoteWsl = false;
  bool _vmGreeting = true;
  bool _aiEnabled = true;
  bool _mcpEnabled = false;
  bool _mcpTokenVisible = false;
  bool _tunnelStarting = false;
  String? _tunnelError;
  bool _webEnabled = false;
  bool _webTokenVisible = false;
  bool _webStarting = false;
  String? _webError;
  bool _webTunnelStarting = false;
  String? _webTunnelError;

  /// The host's LAN addresses, refreshed when the server starts. Links are
  /// built from these at build time so they always carry the current token;
  /// the QR code shows [_webSelectedUrl] out of them.
  List<String> _webAddresses = <String>[];
  String? _webSelectedUrl;
  bool showDocker = false;
  BuildContext? currentContext;

  /// The language the picker currently shows. Held in the draft rather than
  /// written on pick: it used to be the one control on the screen that ignored
  /// Save, so a mis-click could not be undone by leaving (audit ST-02).
  String _draftLanguage = 'en';

  /// The draft as it stood after the last load or Save, so [_isDirty] is a
  /// comparison rather than a flag every control has to remember to set.
  Map<String, String> _savedDraft = <String, String>{};

  /// Whether the dirty guard is currently registered, so [_onDraftChanged]
  /// only rebuilds when the answer actually changes.
  bool _guardRegistered = false;
  final AiService _aiService = AiService();
  final LicenseManager _licenseManager = LicenseManager();
  final WslMcpService _mcpService = WslMcpService();
  final CloudflareTunnelService _tunnelService = CloudflareTunnelService();
  final WebDashboardService _webService = WebDashboardService();
  final UpdateService _updater = UpdateService();

  /// Mirrors the preference so the toggle answers immediately; the service
  /// reads the stored value, not this.
  bool _autoUpdateCheck = UpdateService.autoCheckEnabled;
  bool _checkingUpdate = false;

  bool _isRemoteWslTargetValid(String target) => isValidRemoteTarget(target);

  /// Every controller whose text Save persists, so dirty tracking and the
  /// revert path both work off one list instead of a dozen field names.
  List<TextEditingController> get _draftControllers => <TextEditingController>[
        _syncIpTextController,
        _syncPasswordController,
        _repoTextController,
        _dockerrepoController,
        _editorController,
        _terminalController,
        _vscodeController,
        _dockerMirrorController,
        _remoteWslTargetController,
        _byokBaseUrlController,
        _byokApiKeyController,
        _byokModelController,
        ..._settings.values,
      ];

  /// The whole draft as one comparable map.
  Map<String, String> _draftValues() => <String, String>{
        for (final entry in _settings.entries)
          'wslconfig:${entry.key}': entry.value.text,
        'SyncIP': _syncIpTextController.text,
        'SyncPassword': _syncPasswordController.text,
        'RepoLink': _repoTextController.text,
        'DockerRepoLink': _dockerrepoController.text,
        'Editor': _editorController.text,
        'Terminal': _terminalController.text,
        'VSCodeCmd': _vscodeController.text,
        'DockerMirror': _dockerMirrorController.text,
        'RemoteWSLTarget': _remoteWslTargetController.text,
        'ByokBaseUrl': _byokBaseUrlController.text,
        'ByokApiKey': _byokApiKeyController.text,
        'ByokModel': _byokModelController.text,
        'UseRemoteWSL': _useRemoteWsl.toString(),
        'language': _draftLanguage,
      };

  /// True while the screen holds edits the user has not saved.
  bool get _isDirty => !mapEquals(_savedDraft, _draftValues());

  /// Called by every control in the draft. Registers or releases the exit
  /// guard and repaints the unsaved marker, but only when dirtiness flips.
  void _onDraftChanged() {
    final dirty = _isDirty;
    if (dirty == _guardRegistered) return;
    _guardRegistered = dirty;
    if (dirty) {
      UnsavedChangesGuard.register(_confirmLeave);
    } else {
      UnsavedChangesGuard.release(_confirmLeave);
    }
    if (mounted) setState(() {});
  }

  /// Answer for [UnsavedChangesGuard]: true when the caller may leave.
  Future<bool> _confirmLeave() async {
    if (!_isDirty) return true;
    final context = currentContext;
    if (context == null || !mounted) return true;
    switch (await showUnsavedChangesDialog(context)) {
      case UnsavedChangesChoice.cancel:
        return false;
      case UnsavedChangesChoice.discard:
        _revertDraft();
        return true;
      case UnsavedChangesChoice.save:
        if (!mounted) return true;
        return saveSettings(currentContext!);
    }
  }

  /// Put every control back to the last saved value.
  void _revertDraft() {
    final saved = _savedDraft;
    void restore(TextEditingController controller, String key) {
      final value = saved[key] ?? '';
      if (controller.text != value) controller.text = value;
    }

    for (final entry in _settings.entries) {
      restore(entry.value, 'wslconfig:${entry.key}');
    }
    restore(_syncIpTextController, 'SyncIP');
    restore(_syncPasswordController, 'SyncPassword');
    restore(_repoTextController, 'RepoLink');
    restore(_dockerrepoController, 'DockerRepoLink');
    restore(_editorController, 'Editor');
    restore(_terminalController, 'Terminal');
    restore(_vscodeController, 'VSCodeCmd');
    restore(_dockerMirrorController, 'DockerMirror');
    restore(_remoteWslTargetController, 'RemoteWSLTarget');
    restore(_byokBaseUrlController, 'ByokBaseUrl');
    restore(_byokApiKeyController, 'ByokApiKey');
    restore(_byokModelController, 'ByokModel');
    _useRemoteWsl = saved['UseRemoteWSL'] == 'true';
    _applyLanguage(saved['language'] ?? _draftLanguage, persist: false);
    _onDraftChanged();
    if (mounted) setState(() {});
  }

  /// Take the current draft as the new baseline and drop the exit guard.
  void _markSaved() {
    _savedDraft = _draftValues();
    _guardRegistered = false;
    UnsavedChangesGuard.release(_confirmLeave);
  }

  @override
  void initState() {
    super.initState();
    // The Kubernetes section and the container engine pick follow their
    // experimental switches, so a flip in the section below rebuilds them.
    ExperimentalFeatures.generation.addListener(_onExperimentalChanged);
    readData();
  }

  void _onExperimentalChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ExperimentalFeatures.generation.removeListener(_onExperimentalChanged);
    // No save-on-dispose. It was meant to make leaving the screen commit and
    // observably never fired, which is exactly what made ST-01 a blocker: the
    // code believed in auto-save while the screen discarded everything. The
    // contract is now the Save button plus the exit prompt.
    UnsavedChangesGuard.release(_confirmLeave);
    for (final controller in _draftControllers) {
      controller.removeListener(_onDraftChanged);
    }
    _byokBaseUrlController.dispose();
    _byokApiKeyController.dispose();
    _byokModelController.dispose();
    super.dispose();
  }

  void readData() async {
    // The whole file, not a flat key→value map: Save writes back into this
    // model so comments, blank lines, key order, unknown keys and the sections
    // they sit in all survive a round trip (doc/audit/wsl-docs/ P05-02).
    _config = await WSLApi().readWslConfig();
    if (_config == null) {
      // Unreadable, not empty. Every control still renders, but Save is a
      // no-op — replacing a file we could not read with the one key the user
      // touched is worse than not saving.
      Notify.message('wslconfigwritefailed-text'.i18n());
    }
    final Map<String, String> settings =
        _config?.flatten() ?? <String, String>{};
    _loadedConfig = Map<String, String>.from(settings);
    settings.forEach((key, value) {
      _settings[key] = TextEditingController(text: value);
    });
    // The version the `--manage` affordances gate on, and the answer to
    // "which WSL do I have" the app never used to give (P05-08).
    WSLApi().capabilities.load().then((capabilities) {
      if (mounted) setState(() => _capabilities = capabilities);
    });
    String? syncIP = prefs.getString('SyncIP');
    if (syncIP != null && syncIP != '') {
      _syncIpTextController.text = syncIP;
    }
    String? syncPassword = prefs.getString('SyncPassword');
    if (syncPassword != null && syncPassword != '') {
      _syncPasswordController.text = syncPassword;
    }
    String? repoLink = prefs.getString('RepoLink');
    if (repoLink != null && repoLink != '') {
      _repoTextController.text = repoLink;
    }
    if (prefs.containsKey('DockerRepoLink')) {
      String? dockerRepoLink = prefs.getString('DockerRepoLink');
      if (dockerRepoLink != null && dockerRepoLink != '') {
        _dockerrepoController.text = dockerRepoLink;
      }
    }
    String? editor = prefs.getString('Editor');
    if (editor != null && editor != '') {
      _editorController.text = editor;
    }
    String? terminal = prefs.getString('Terminal');
    if (terminal != null && terminal != '') {
      _terminalController.text = terminal;
    }
    String? vscodeCmd = prefs.getString('VSCodeCmd');
    if (vscodeCmd != null && vscodeCmd != '') {
      _vscodeController.text = vscodeCmd;
    }
    String? dockerMirror = prefs.getString('DockerMirror');
    if (dockerMirror != null && dockerMirror != '') {
      _dockerMirrorController.text = dockerMirror;
    }
    // A *chosen* path renders as real text; only the fallback default stays
    // a placeholder. Both used to render as placeholder grey, so "set" and
    // "unset" were indistinguishable (audit ST-25).
    String? distroPath = prefs.getString('DistroPath');
    if (distroPath != null && distroPath.trim().isNotEmpty) {
      _settings['Default Distro Location'] =
          TextEditingController(text: distroPath);
    }
    String? dataPath = prefs.getString('DataPath');
    if (dataPath != null && dataPath.trim().isNotEmpty) {
      _settings['General Data Location'] =
          TextEditingController(text: dataPath);
    }
    _useRemoteWsl = prefs.getBool('UseRemoteWSL') ?? false;
    _vmGreeting = prefs.getBool(GuestGreeting.enabledPrefKey) ?? true;
    _aiEnabled = AiService.featuresEnabled;
    String? remoteTarget = prefs.getString('RemoteWSLTarget');
    if (remoteTarget != null && remoteTarget.trim().isNotEmpty) {
      _remoteWslTargetController.text = remoteTarget;
    }
    showDocker = prefs.getBool('showDocker') ?? false;
    _byokBaseUrlController.text = prefs.getString('ByokBaseUrl') ?? '';
    _byokApiKeyController.text = _aiService.byokApiKey;
    _byokModelController.text = prefs.getString('ByokModel') ?? '';
    _mcpEnabled = _mcpService.enabled;
    _webEnabled = _webService.enabled;
    if (_webService.isRunning) _refreshWebUrls();
    for (final controller in _draftControllers) {
      controller.removeListener(_onDraftChanged);
      controller.addListener(_onDraftChanged);
    }
    _savedDraft = _draftValues();
    _guardRegistered = false;
    UnsavedChangesGuard.release(_confirmLeave);
    if (!mounted) return;
    setState(() {
      _settings = _settings;
    });
  }

  bool _languageResolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The stored language may be absent, in which case the picker has to show
    // the locale the app actually resolved to — which needs a context.
    if (_languageResolved) return;
    _languageResolved = true;
    var stored = prefs.getString('language') ??
        Localizations.localeOf(context).toString();
    if (!languageOptions.containsKey(stored)) {
      stored = Localizations.localeOf(context).languageCode;
    }
    if (!languageOptions.containsKey(stored)) stored = 'en';
    _draftLanguage = stored;
    _savedDraft = _draftValues();
  }

  /// Show [lang] immediately, and write it only when Save does.
  ///
  /// The picker used to call `prefs.setString` from `onChanged` — the one
  /// control on the screen that ignored Save, with no way to undo a mis-click
  /// — and then told the user to restart the app to see it (ST-02).
  void _applyLanguage(String lang, {required bool persist}) {
    _draftLanguage = lang;
    if (persist) prefs.setString('language', lang);
    final parts = lang.split('_');
    final locale =
        parts.length == 2 ? Locale(parts[0], parts[1]) : Locale(parts[0]);
    if (!mounted) return;
    context.read<AppTheme>().locale = locale;
  }

  @override
  Widget build(BuildContext context) {
    currentContext = context;
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 20.0, left: 20.0, right: 20.0),
            child: SizedBox(
              child: settingsList(context),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(
              left: 20.0, right: 20.0, bottom: 8.0, top: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  // Both footer actions drive wsl.exe — locally or over the
                  // configured remote target.
                  if (!isAppleHost || _useRemoteWsl) ...[
                  Tooltip(
                    message: 'editwslconfighint-text'.i18n(),
                    child: Button(
                        style: ButtonStyle(
                            padding: ButtonState.all(const EdgeInsets.only(
                                left: 15.0,
                                right: 15.0,
                                top: 10.0,
                                bottom: 10.0))),
                        onPressed: () {
                          WSLApi().editConfig();
                        },
                        child: Text('editwslconfig-text'.i18n())),
                  ),
                  const SizedBox(width: 10.0),
                  // Stop WSL used to sit 10px from Save, styled identically,
                  // and shut every running instance down on one click with no
                  // confirmation (audit ST-04). It is now on the opposite side
                  // of the footer and asks first.
                  Tooltip(
                    message: 'stopwslhint-text'.i18n(),
                    child: Button(
                        key: const ValueKey('test-settings-stopwsl'),
                        style: ButtonStyle(
                            padding: ButtonState.all(const EdgeInsets.only(
                                left: 15.0,
                                right: 15.0,
                                top: 10.0,
                                bottom: 10.0))),
                        onPressed: () => confirmStopWsl(context, () {
                              WSLApi().restart();
                              Notify.message('shuttingdownwsl-text'.i18n(),
                                  severity: InfoBarSeverity.success);
                              hasPushed = false;
                              // Leaving the screen is an exit route like any
                              // other, so it asks about unsaved edits (ST-01).
                              navigateGuarded('home');
                            }),
                        child: Text('stopwsl-text'.i18n())),
                  ),
                  ],
                ],
              ),
              const SizedBox(
                width: 10.0,
              ),
              Row(
                children: [
                  if (_isDirty) ...[
                    Text('unsavedchanges-marker-text'.i18n(),
                        key: const ValueKey('test-settings-dirty'),
                        style: FluentTheme.of(context)
                            .typography
                            .caption
                            ?.copyWith(color: secondaryTextColor(context))),
                    const SizedBox(width: 10.0),
                    Button(
                        key: const ValueKey('test-settings-discard'),
                        style: ButtonStyle(
                            padding: ButtonState.all(const EdgeInsets.only(
                                left: 15.0,
                                right: 15.0,
                                top: 10.0,
                                bottom: 10.0))),
                        onPressed: _revertDraft,
                        child: Text('discardchanges-text'.i18n())),
                    const SizedBox(width: 10.0),
                  ],
                  Button(
                      key: const ValueKey('test-settings-save'),
                      style: ButtonStyle(
                          padding: ButtonState.all(const EdgeInsets.only(
                              left: 15.0,
                              right: 20.0,
                              top: 10.0,
                              bottom: 10.0))),
                      onPressed: () {
                        saveSettings(context);
                      },
                      child: Text('save-text'.i18n())),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Persist the draft. Answers false when a validation error stopped it, so
  /// the exit prompt can keep the user on the screen instead of leaving with
  /// the edits unwritten.
  /// The `.wslconfig` keys whose values have a shape WSL will reject.
  /// Save refuses to write an unparseable one: WSL reports a bad value on
  /// stderr with exit code 0 at every distro start, so writing it means the
  /// app can never learn it was wrong (audit ST-05).
  static const Map<String, SettingsType> _numericWslKeys = {
    'memory': SettingsType.size,
    'swap': SettingsType.size,
    'defaultVhdSize': SettingsType.size,
    'processors': SettingsType.number,
    'vmIdleTimeout': SettingsType.number,
    'maxCrashDumpCount': SettingsType.number,
    'initialAutoProxyTimeout': SettingsType.number,
  };

  /// The first key holding a value WSL would reject, or null when clean.
  String? _firstInvalidWslValue() {
    for (final entry in _numericWslKeys.entries) {
      final raw = _settings[entry.key]?.text.trim() ?? '';
      if (raw.isEmpty) continue;
      final ok = entry.value == SettingsType.size
          ? parseWslSize(raw, unit: 'GB') != null
          : parseWslCount(raw) != null;
      if (!ok) return entry.key;
    }
    return null;
  }

  /// The AI Workspace's shared-settings writer, or null where the workspace
  /// services are not in the tree (a test harness without them).
  AiWorkspaceSharedSettingsService? _workspaceSharedSettings(
      BuildContext context) {
    try {
      return AiWorkspaceSharedSettingsService(
        workspace: context.read<AiWorkspaceService>(),
        config: context.read<AiWorkspaceConfigService>(),
      );
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<bool> saveSettings(BuildContext context) async {
    // Resolved before the first await, while the context is still good.
    final workspaceSettings = _workspaceSharedSettings(context);
    final remoteTarget = _remoteWslTargetController.text.trim();
    if (_useRemoteWsl && !_isRemoteWslTargetValid(remoteTarget)) {
      Notify.message('remote-wsl-target-required-text'.i18n(),
          severity: InfoBarSeverity.warning);
      return false;
    }

    // Typed `eight gigabytes` into Memory used to land in the file verbatim
    // and break every distro start with nothing on screen (audit ST-05).
    final invalid = _firstInvalidWslValue();
    if (invalid != null) {
      final labelKey = '${invalid.toLowerCase()}-text';
      final prose = labelKey.i18n();
      Notify.message(
          'settinginvalidvalue-text'
              .i18n([prose == labelKey ? invalid : prose]),
          severity: InfoBarSeverity.warning);
      return false;
    }

    plausible.event(name: "global_settings_saved");
    // Sync target ip setting _syncIpTextController
    if (_syncIpTextController.text.isNotEmpty) {
      prefs.setString("SyncIP", _syncIpTextController.text);
    }

    // Sync password
    if (_syncPasswordController.text.isNotEmpty) {
      prefs.setString("SyncPassword", _syncPasswordController.text);
    } else {
      prefs.remove("SyncPassword");
    }

    // Save repo link. Empty removes the key: Save used to materialise the
    // default as a stored value the user never chose (audit ST-26).
    if (_repoTextController.text.isNotEmpty) {
      prefs.setString("RepoLink", _repoTextController.text);
    } else {
      prefs.remove("RepoLink");
    }

    // Save docker repo link. Same ST-26 rule.
    if (_dockerrepoController.text.isNotEmpty) {
      prefs.setString("DockerRepoLink", _dockerrepoController.text);
    } else {
      prefs.remove("DockerRepoLink");
    }

    // Save editor
    if (_editorController.text.isNotEmpty) {
      prefs.setString("Editor", _editorController.text);
    } else {
      prefs.remove("Editor");
    }

    // Save terminal
    if (_terminalController.text.isNotEmpty) {
      prefs.setString("Terminal", _terminalController.text);
    } else {
      prefs.remove("Terminal");
    }

    // Save vscode command
    if (_vscodeController.text.isNotEmpty) {
      prefs.setString("VSCodeCmd", _vscodeController.text);
    } else {
      prefs.remove("VSCodeCmd");
    }

    // Save docker mirror
    if (_dockerMirrorController.text.isNotEmpty) {
      prefs.setString("DockerMirror", _dockerMirrorController.text);
    } else {
      prefs.remove("DockerMirror");
    }

    prefs.setBool("UseRemoteWSL", _useRemoteWsl);
    if (_isRemoteWslTargetValid(remoteTarget)) {
      prefs.setString("RemoteWSLTarget", remoteTarget);
    } else {
      prefs.remove("RemoteWSLTarget");
    }

    // AI settings. The AI Workspace tools run on the same endpoint, key and
    // model (bostrot/ai-tasks#81): a change here is pushed into every
    // installed tool, in the background so Save does not wait on the
    // workspace distro, and reported through the notification bar.
    final aiBefore = AiWorkspaceSharedSettings.fromAssistant();
    _aiService.setByokBaseUrl(_byokBaseUrlController.text);
    _aiService.setByokApiKey(_byokApiKeyController.text);
    _aiService.setByokModel(_byokModelController.text);
    if (workspaceSettings != null &&
        AiWorkspaceSharedSettings.fromAssistant() != aiBefore) {
      unawaited(workspaceSettings.applyCurrentAndNotify());
    }

    // Location settings. Null-safe: a field hidden on this backend (the
    // distro location does not exist on macOS) never registered a
    // controller, and Save must not crash over it.
    final distroLocation = _settings['Default Distro Location'];
    if (distroLocation != null && distroLocation.text.isNotEmpty) {
      prefs.setString("DistroPath", distroLocation.text);
    }
    final dataLocation = _settings['General Data Location'];
    if (dataLocation != null && dataLocation.text.isNotEmpty) {
      prefs.setString("DataPath", dataLocation.text);
    }

    await _saveWslConfig();
    hasPushed = false;
    _applyLanguage(_draftLanguage, persist: true);
    _markSaved();
    if (mounted) setState(() {});

    // Save used to end with `router.pushNamed('home')`, so pressing it closed
    // the screen: nothing said what had been written, and a second edit meant
    // navigating back (ST-03). It confirms in place instead.
    Notify.message('settingssaved-text'.i18n(),
        severity: InfoBarSeverity.success);
    return true;
  }

  /// The two `settingsWidget` names that are app preferences rather than
  /// `.wslconfig` keys, and must never reach the file.
  static const Set<String> _appPreferenceSettings = <String>{
    'Default Distro Location',
    'General Data Location',
  };

  /// Write back only what the user actually changed — see
  /// [applyWslConfigEdits], which is where the diff and its reasoning live.
  Future<void> _saveWslConfig() async {
    final config = _config;
    if (config == null) return;

    final edits = <String, String>{};
    _settings.forEach((key, controller) {
      if (_appPreferenceSettings.contains(key)) return;
      edits[key] = controller.text;
    });

    if (applyWslConfigEdits(config, _loadedConfig, edits) == 0) return;
    if (!await WSLApi().writeWslConfig(config)) {
      Notify.message('wslconfigwritefailed-text'.i18n());
    }
  }

  Widget settingsList(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expander(
          header: Text('generalsettings-text'.i18n()),
          content: _buildGeneralSettings(context),
        ),
        const SizedBox(height: 10),
        Expander(
          header: Text('update-settings-text'.i18n()),
          content: _buildUpdateSettings(context),
        ),
        // Above the per-backend sections and outside the WSL-only block:
        // writing every instance to a folder is the same job on a Mac's VMs
        // as on WSL, and it is maintenance of the whole install rather than
        // configuration of one part of it (bostrot/ai-tasks#89).
        const SizedBox(height: 10),
        Expander(
          key: const ValueKey('test-backup-expander'),
          header: Text('backupandrestore-text'.i18n()),
          // The flag is read here rather than inside the section so that
          // turning remote WSL on or off in General settings reaches it: a
          // `const` child is the same widget instance on every rebuild, and
          // an element handed an identical widget never builds again.
          //
          // [remoteWslActive], not `vmBackend().isRemote`: they are the same
          // answer on every host, and this one does not build a backend in a
          // build method — the first `WSLApi()` fires off a distro-link
          // fetch from its constructor.
          content: BackupSettingsSection(isRemote: remoteWslActive),
        ),
        if (!isAppleHost || _useRemoteWsl) ...[
        const SizedBox(height: 10),
        Expander(
          header: Text('dockersettings-text'.i18n()),
          content: _buildDockerSettings(context),
        ),
        ],
        // Settings for a destination nobody can open are just clutter.
        if (ExperimentalFeatures.isVisible(ExperimentalFeature.kubernetes)) ...[
        const SizedBox(height: 10),
        Expander(
          header: Text('kubernetessettings-text'.i18n()),
          content: _buildKubernetesSettings(context),
        ),
        ],
        const SizedBox(height: 10),
        Expander(
          header: _betaHeader('byok-settings-text'.i18n()),
          content: _buildAiSettings(context),
        ),
        const SizedBox(height: 10),
        Expander(
          header: _betaHeader(
              (isAppleHost ? 'mcp-settings-vm-text' : 'mcp-settings-text')
                  .i18n()),
          content: _buildMcpSettings(context),
        ),
        const SizedBox(height: 10),
        Expander(
          header: _betaHeader('web-dashboard-settings-text'.i18n()),
          content: _buildWebDashboardSettings(context),
        ),
        // Outside the WSL-only block below: a Mac's VMs get their names in
        // /etc/hosts the same way a distro gets them into
        // drivers\etc\hosts (bostrot/wsl2-distro-manager#214).
        const SizedBox(height: 10),
        Expander(
          key: const ValueKey('test-hosts-file-expander'),
          header: Text('hostsfile-text'.i18n()),
          content: const HostsSettingsSection(),
        ),
        // Windows only, and not for a remote host either: the menu this
        // fills is the one on *this* machine, and `wsl -d name` there would
        // open a distro that lives on the other one
        // (bostrot/wsl2-distro-manager#239).
        if (Platform.isWindows) ...[
        const SizedBox(height: 10),
        Expander(
          key: const ValueKey('test-windows-terminal-expander'),
          header: Text('windowsterminal-text'.i18n()),
          content: const WindowsTerminalSettingsSection(),
        ),
        ],
        if (!isAppleHost || _useRemoteWsl) ...[
        const SizedBox(height: 10),
        Expander(
          header: Text('syncsettings-text'.i18n()),
          content: _buildSyncSettings(context),
        ),
        const SizedBox(height: 10),
        Expander(
          header: Text('globalconfiguration-text'.i18n()),
          content: _buildGlobalConfigSettings(context),
        ),
        const SizedBox(height: 10),
        Expander(
          header: Text('experimental-text'.i18n()),
          content: _buildExperimentalSettings(context),
        ),
        ],
        // The opt-in switches for the destinations that are not finished:
        // last, on every host, because they are the one section a user
        // visits once (bostrot/ai-tasks#87).
        const SizedBox(height: 10),
        Expander(
          key: const ValueKey('test-experimental-features-expander'),
          header: Text('experimentalfeatures-text'.i18n()),
          content: const ExperimentalFeaturesSection(),
        ),
      ],
    );
  }

  /// Updates. Only the direct builds get controls: a Store install is kept
  /// current by the Store, and saying so is more useful than a toggle that
  /// would do nothing (see lib/api/updater.dart).
  Widget _buildUpdateSettings(BuildContext context) {
    final selfUpdates = _updater.canSelfUpdate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text('update-current-version-text'.i18n([currentVersion])),
        ),
        if (!selfUpdates)
          Padding(
            padding: const EdgeInsets.all(10.0),
            child: Text('update-store-managed-text'.i18n()),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                ToggleSwitch(
                  key: const ValueKey('test-auto-update-toggle'),
                  checked: _autoUpdateCheck,
                  onChanged: (value) {
                    setState(() => _autoUpdateCheck = value);
                    UpdateService.setAutoCheckEnabled(value);
                  },
                ),
                const SizedBox(width: 10.0),
                Expanded(child: Text('update-auto-check-text'.i18n())),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Button(
                  key: const ValueKey('test-check-update-button'),
                  onPressed: _checkingUpdate ? null : _checkForUpdate,
                  child: Text('update-check-now-text'.i18n()),
                ),
                if (_checkingUpdate) ...[
                  const SizedBox(width: 10.0),
                  const SizedBox.square(
                      dimension: 16.0, child: ProgressRing(strokeWidth: 2.0)),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// A check the user asked for: no soak, and a version they skipped earlier
  /// comes back — otherwise the button could answer "up to date" about a
  /// release it is deliberately hiding.
  Future<void> _checkForUpdate() async {
    setState(() => _checkingUpdate = true);
    Notify.message('update-checking-text'.i18n());
    final info = await _updater.check(
      minimumAge: Duration.zero,
      includeSkipped: true,
    );
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (info == null) {
      Notify.message('update-uptodate-text'.i18n());
      return;
    }
    await showUpdateDialog(info, service: _updater, hostContext: context);
  }

  Widget _buildGeneralSettings(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The Apple backend keeps everything under the data location; the
        // per-distro path, host editor/terminal and VS Code hooks are WSL
        // flows.
        if (!isAppleHost)
        settingsWidget(context,
            title: 'defaultdistrolocation-text'.i18n(),
            name: 'Default Distro Location',
            tooltip: 'distropath-text'.i18n(),
            suffix: NamedIconButton(
              label: 'choosefolder-text'.i18n(),
              icon: FluentIcons.open_folder_horizontal,
              onPressed: () async {
                String? path = await FilePicker.platform.getDirectoryPath(
                  initialDirectory: prefs.getString("DistroPath") ??
                      getDefaultStorageRootPath(),
                );
                if (path != null &&
                    _settings['Default Distro Location'] != null) {
                  _settings['Default Distro Location']!.text = path;
                } else {
                  // User canceled the picker
                }
              },
            ),
            // The default alone: a chosen value lives in the box itself now
            // (ST-25).
            placeholder: getDefaultStorageRootPath()),
        settingsWidget(context,
            title: 'defaultdatalocation-text'.i18n(),
            name: 'General Data Location',
            tooltip: 'datapath-text'.i18n(),
            suffix: NamedIconButton(
              label: 'choosefolder-text'.i18n(),
              icon: FluentIcons.open_folder_horizontal,
              onPressed: () async {
                String? path = await FilePicker.platform.getDirectoryPath(
                  initialDirectory: prefs.getString("DataPath") ??
                      prefs.getString("DistroPath") ??
                      getDefaultStorageRootPath(),
                );
                if (path != null &&
                    _settings['General Data Location'] != null) {
                  _settings['General Data Location']!.text = path;
                } else {
                  // User canceled the picker
                }
              },
            ),
            placeholder:
                prefs.getString("DistroPath") ?? getDefaultStorageRootPath()),
        if (!isAppleHost)
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'defaulteditor-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: TextBox(
              controller: _editorController,
              placeholder: 'notepad.exe',
              suffix: NamedIconButton(
                label: 'choosefile-text'.i18n(),
                icon: FluentIcons.open_folder_horizontal,
                onPressed: () async {
                  FilePickerResult? result =
                      await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['exe'],
                  );
                  if (result != null) {
                    _editorController.text = result.files.single.path!;
                  }
                },
              ),
            ),
          ),
        ),
        if (!isAppleHost)
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'defaultterminal-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: TextBox(
              controller: _terminalController,
              placeholder: 'wt.exe',
              suffix: NamedIconButton(
                label: 'choosefile-text'.i18n(),
                icon: FluentIcons.open_folder_horizontal,
                onPressed: () async {
                  FilePickerResult? result =
                      await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['exe'],
                  );
                  if (result != null) {
                    _terminalController.text = result.files.single.path!;
                  }
                },
              ),
            ),
          ),
        ),
        if (!isAppleHost)
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'defaultvscode-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: TextBox(
              controller: _vscodeController,
              placeholder: 'code',
            ),
          ),
        ),
        // A VM terminal's banner is the guest's own profile, so this only
        // means anything where the app drives VMs.
        if (isAppleHost)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'vmgreeting-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Row(
                children: [
                  ToggleSwitch(
                    key: const ValueKey('test-vm-greeting-toggle'),
                    checked: _vmGreeting,
                    onChanged: (value) {
                      setState(() => _vmGreeting = value);
                      prefs.setBool(GuestGreeting.enabledPrefKey, value);
                    },
                  ),
                  const SizedBox(width: 10.0),
                  Expanded(child: Text('vmgreeting-info-text'.i18n())),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'remote-wsl-over-ssh-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(
              children: [
                ToggleSwitch(
                  checked: _useRemoteWsl,
                  onChanged: (value) {
                    setState(() {
                      _useRemoteWsl = value;
                    });
                    _onDraftChanged();
                  },
                ),
                const SizedBox(width: 10.0),
                Expanded(
                  child: Text(
                    'remote-wsl-over-ssh-info-text'.i18n(),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'remote-ssh-target-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Tooltip(
              message: 'remote-ssh-target-format-text'.i18n(),
              // Live only while the toggle that reads it is on (audit ST-24).
              child: TextBox(
                controller: _remoteWslTargetController,
                enabled: _useRemoteWsl,
                placeholder: _useRemoteWsl
                    ? 'remote-ssh-target-placeholder-text'.i18n()
                    : null,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'language-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            // Menu
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'languagechange-text'.i18n(),
                ),
                const SizedBox(
                  height: 20.0,
                ),
                // Every zh variant collapsed to the same languageCode
                // before, which left the ComboBox with duplicate values
                // and showed raw locale codes as labels.
                ComboBox<String>(
                    key: const ValueKey('test-language-combo'),
                    value: languageOptions.containsKey(_draftLanguage)
                        ? _draftLanguage
                        : 'en',
                    items: languageOptions.entries
                        .map((e) => ComboBoxItem(
                            value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (language) {
                      if (language == null) return;
                      _applyLanguage(language, persist: false);
                      _onDraftChanged();
                      setState(() {});
                    }),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _betaHeader(String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: 8),
        const BetaBadge(),
      ],
    );
  }

  Widget _buildAiSettings(BuildContext context) {
    final isPro = _licenseManager.isPro;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text(
            'byok-info-text'.i18n(),
            style: const TextStyle(fontSize: 12.0, fontStyle: FontStyle.italic),
          ),
        ),
        if (!isPro)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoBar(
              title: Text('byok-pro-required-text'.i18n()),
              severity: InfoBarSeverity.info,
              action: Button(
                key: const ValueKey('test-byok-upgrade'),
                onPressed: () {
                  trackUpgradeClick('settings_byok');
                  navigateGuarded('license');
                },
                child: Text('upgrade-text'.i18n()),
              ),
            ),
          ),
        // The one switch for everything AI: not a chat on/off — the key is
        // the only chat path — but the opt-in for an assistant, a diagnosis
        // button and a workspace distro set up for you (bostrot/ai-tasks#85,
        // #98). Shown whatever the licence: the first-start question is put
        // to every install, so every install has to be able to answer it
        // again here, and a lapsed licence can still find its way back.
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'ai-enabled-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(children: [
              ToggleSwitch(
                key: const ValueKey('test-ai-enabled-toggle'),
                checked: _aiEnabled,
                onChanged: (value) {
                  setState(() => _aiEnabled = value);
                  AiService.setFeaturesEnabled(value);
                },
              ),
              const SizedBox(width: 10.0),
              Expanded(child: Text('ai-enabled-info-text'.i18n())),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            // The lock and its reason sit on the field itself, not in a
            // notice 90px above it (audit PS-12).
            label: isPro
                ? 'byok-baseurl-text'.i18n()
                : '${'byok-baseurl-text'.i18n()} — ${'byok-locked-text'.i18n()}',
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Tooltip(
              message: 'byok-baseurl-hint-text'.i18n(),
              child: TextBox(
                key: const ValueKey('test-byok-baseurl-input'),
                controller: _byokBaseUrlController,
                enabled: isPro,
                // No placeholder while locked: near-normal-weight example
                // text made the disabled fields read as filled in (PS-12).
                placeholder: isPro ? AiService.defaultByokBaseUrl : null,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: isPro
                ? 'byok-apikey-text'.i18n()
                : '${'byok-apikey-text'.i18n()} — ${'byok-locked-text'.i18n()}',
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Tooltip(
              message: 'byok-apikey-hint-text'.i18n(),
              child: TextBox(
                key: const ValueKey('test-byok-apikey-input'),
                controller: _byokApiKeyController,
                enabled: isPro,
                obscureText: true,
                placeholder: isPro ? 'sk-...' : null,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: isPro
                ? 'byok-model-text'.i18n()
                : '${'byok-model-text'.i18n()} — ${'byok-locked-text'.i18n()}',
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: _modelField(
              key: const ValueKey('test-byok-model-input'),
              controller: _byokModelController,
              enabled: isPro,
              hintKey: 'byok-model-hint-text',
              placeholder: isPro ? AiService.defaultByokModel : null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Button(
            key: const ValueKey('test-ai-test-button'),
            onPressed: isPro && !_aiTestBusy ? _testAiConnection : null,
            child: Text(
                (_aiTestBusy ? 'ai-testing-text' : 'ai-test-text').i18n()),
          ),
        ),
      ],
    );
  }

  /// The model box with autocomplete, plus the button that fills its
  /// suggestion list from the provider's own /models endpoint.
  Widget _modelField({
    required Key key,
    required TextEditingController controller,
    required bool enabled,
    required String hintKey,
    String? placeholder,
  }) {
    return Row(
      children: [
        Expanded(
          child: Tooltip(
            message: hintKey.i18n(),
            child: AutoSuggestBox<String>(
              key: key,
              controller: controller,
              enabled: enabled,
              placeholder: placeholder,
              items: [
                for (final m in _modelSuggestions)
                  AutoSuggestBoxItem<String>(value: m, label: m),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8.0),
        // MergeSemantics+Tooltip so the icon-only button carries its name for
        // a screen reader (audit IA-09).
        MergeSemantics(
          child: Tooltip(
          message: 'ai-loadmodels-text'.i18n(),
          child: IconButton(
            key: const ValueKey('test-ai-loadmodels'),
            icon: _modelsLoading
                ? const SizedBox.square(
                    dimension: 14.0, child: ProgressRing(strokeWidth: 2.0))
                : const Icon(FluentIcons.refresh, size: 14.0),
            onPressed:
                enabled && !_modelsLoading ? _loadModelSuggestions : null,
          ),
          ),
        ),
      ],
    );
  }

  /// Fills the autocomplete from the provider, using the values as typed —
  /// waiting for Save would mean probing yesterday's key.
  Future<void> _loadModelSuggestions() async {
    setState(() => _modelsLoading = true);
    try {
      final models = await _aiService.listModels(
        baseUrl: _byokBaseUrlController.text,
        apiKey: _byokApiKeyController.text,
      );
      if (!mounted) return;
      setState(() => _modelSuggestions = models);
      Notify.message('ai-models-loaded-text'.i18n(['${models.length}']),
          severity: InfoBarSeverity.success);
    } catch (_) {
      if (mounted) {
        Notify.message('ai-models-failed-text'.i18n(),
            severity: InfoBarSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _modelsLoading = false);
    }
  }

  /// One tiny chat round trip with the values as typed, so "it does not
  /// work" surfaces here and not mid-question in the chat panel.
  Future<void> _testAiConnection() async {
    setState(() => _aiTestBusy = true);
    try {
      await _aiService.testConnection(
        baseUrl: _byokBaseUrlController.text,
        apiKey: _byokApiKeyController.text,
        model: _byokModelController.text,
      );
      Notify.message('ai-test-ok-text'.i18n(),
          severity: InfoBarSeverity.success);
    } catch (_) {
      Notify.message('ai-test-failed-text'.i18n(),
          severity: InfoBarSeverity.error);
    } finally {
      if (mounted) setState(() => _aiTestBusy = false);
    }
  }

  Future<void> _connectClaudeDesktop() async {
    try {
      await _mcpService.connectClaudeDesktop();
      Notify.message('mcp-quickconnect-done-text'.i18n(),
          severity: InfoBarSeverity.success);
    } catch (e) {
      Notify.message(
          (e.toString().contains('claude-desktop-not-found')
                  ? 'mcp-quickconnect-notfound-text'
                  : 'mcp-quickconnect-failed-text')
              .i18n(),
          severity: InfoBarSeverity.error);
    }
  }

  Widget _buildMcpSettings(BuildContext context) {
    final isPro = _licenseManager.isPro;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text(
            'mcp-info-text'.i18n(),
            style: const TextStyle(fontSize: 12.0, fontStyle: FontStyle.italic),
          ),
        ),
        if (!isPro)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoBar(
              title: Text('mcp-pro-required-text'.i18n()),
              severity: InfoBarSeverity.info,
              action: Button(
                key: const ValueKey('test-mcp-upgrade'),
                onPressed: () {
                  trackUpgradeClick('settings_mcp');
                  navigateGuarded('license');
                },
                child: Text('upgrade-text'.i18n()),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'mcp-toggle-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(
              children: [
                // A free user's toggle is disabled rather than live: it used to
                // render exactly like the working switches around it and then
                // replace the whole screen with the licence page, dropping any
                // unsaved settings on the way (audit PS-11).
                ToggleSwitch(
                  key: const ValueKey('test-mcp-toggle'),
                  checked: _mcpEnabled && isPro,
                  onChanged: isPro
                      ? (value) {
                          setState(() => _mcpEnabled = value);
                          _mcpService.setEnabled(value);
                        }
                      : null,
                ),
                const SizedBox(width: 10.0),
                Expanded(
                  child: Text('mcp-toggle-hint-text'.i18n(),
                      style: isPro
                          ? null
                          : TextStyle(color: disabledTextColor(context))),
                ),
              ],
            ),
          ),
        ),
        if (_mcpEnabled && isPro) ...[
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'mcp-endpoint-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Row(
                children: [
                  Expanded(
                    child: TextBox(
                      key: const ValueKey('test-mcp-endpoint'),
                      readOnly: true,
                      controller:
                          TextEditingController(text: _mcpService.endpointUrl),
                    ),
                  ),
                  const SizedBox(width: 8),
                  NamedIconButton(
                    label: 'copyendpoint-text'.i18n(),
                    icon: FluentIcons.copy,
                    // A copy with no acknowledgement is indistinguishable
                    // from a missed click (audit ST-21).
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: _mcpService.endpointUrl));
                      Notify.message('copied-text'.i18n(),
                          severity: InfoBarSeverity.success,
                          duration: const Duration(seconds: 2));
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'mcp-token-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Row(
                children: [
                  Expanded(
                    child: TextBox(
                      key: const ValueKey('test-mcp-token'),
                      readOnly: true,
                      obscureText: !_mcpTokenVisible,
                      controller:
                          TextEditingController(text: _mcpService.token),
                    ),
                  ),
                  const SizedBox(width: 8),
                  NamedIconButton(
                    label: _mcpTokenVisible
                        ? 'hidetoken-text'.i18n()
                        : 'showtoken-text'.i18n(),
                    icon:
                        _mcpTokenVisible ? FluentIcons.hide3 : FluentIcons.view,
                    onPressed: () =>
                        setState(() => _mcpTokenVisible = !_mcpTokenVisible),
                  ),
                  const SizedBox(width: 4),
                  // Two identical copy glyphs 60 px apart: only the name
                  // tells them apart (audit ST-18).
                  NamedIconButton(
                    label: 'copytoken-text'.i18n(),
                    icon: FluentIcons.copy,
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: _mcpService.token));
                      Notify.message('copied-text'.i18n(),
                          severity: InfoBarSeverity.success,
                          duration: const Duration(seconds: 2));
                    },
                  ),
                  const SizedBox(width: 4),
                  // Rotating the token silently broke every client already
                  // configured with the old one — no confirmation, no notice,
                  // no undo, one click from a copy button (audit ST-19).
                  NamedIconButton(
                    key: const ValueKey('test-mcp-regenerate-token'),
                    label: 'regeneratetoken-text'.i18n(),
                    icon: FluentIcons.refresh,
                    onPressed: () => dialog(
                      hostContext: context,
                      item: '',
                      title: 'regeneratetokenquestion-text'.i18n(),
                      body: 'regeneratetokenbody-text'.i18n(),
                      submitText: 'regeneratetoken-text'.i18n(),
                      submitInput: false,
                      submitStyle: ButtonStyle(
                        backgroundColor: ButtonState.all(Colors.red),
                        foregroundColor: ButtonState.all(Colors.white),
                      ),
                      onSubmit: (_) {
                        setState(() => _mcpService.regenerateToken());
                        Notify.message('tokenregenerated-text'.i18n(),
                            severity: InfoBarSeverity.success);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'mcp-quickconnect-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Row(
                children: [
                  Button(
                    key: const ValueKey('test-mcp-quickconnect'),
                    onPressed: _connectClaudeDesktop,
                    child: Text('mcp-quickconnect-text'.i18n()),
                  ),
                  const SizedBox(width: 10.0),
                  Expanded(
                    child: Text(
                      'mcp-quickconnect-hint-text'.i18n(),
                      style: TextStyle(
                          color: secondaryTextColor(context), fontSize: 12.0),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Only while the tunnel is actually up: shown whenever MCP was
          // enabled, this warning contradicted the "only reachable from this
          // machine" hint two lines above it (audit ST-20).
          if (_tunnelService.isRunning)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: InfoBar(
                title: Text('mcp-tunnel-warning-text'.i18n()),
                severity: InfoBarSeverity.warning,
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'mcp-tunnel-toggle-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Row(
                children: [
                  ToggleSwitch(
                    key: const ValueKey('test-mcp-tunnel-toggle'),
                    checked: _tunnelService.isRunning,
                    onChanged: _tunnelStarting
                        ? null
                        : (value) async {
                            setState(() {
                              _tunnelStarting = true;
                              _tunnelError = null;
                            });
                            try {
                              if (value) {
                                await _tunnelService.start();
                              } else {
                                await _tunnelService.stop();
                              }
                            } catch (e) {
                              _tunnelError = '${'mcp-tunnel-failed-text'.i18n()} '
                                      '${WslFailure.from(e).shortReason}'
                                  .trim();
                            } finally {
                              if (mounted) {
                                setState(() => _tunnelStarting = false);
                              }
                            }
                          },
                  ),
                  const SizedBox(width: 10.0),
                  Expanded(
                    child: Text('mcp-tunnel-toggle-hint-text'.i18n()),
                  ),
                ],
              ),
            ),
          ),
          if (_tunnelStarting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: _buildInlineTunnelStatus(),
            ),
          if (_tunnelError != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                _tunnelError!,
                style: TextStyle(
                    color: Colors.errorPrimaryColor, fontSize: 12),
              ),
            ),
          if (_tunnelService.isRunning && _tunnelService.publicUrl != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: InfoLabel(
                label: 'mcp-tunnel-url-text'.i18n(),
                labelStyle: const TextStyle(fontWeight: FontWeight.w500),
                child: Row(
                  children: [
                    Expanded(
                      child: TextBox(
                        key: const ValueKey('test-mcp-tunnel-url'),
                        readOnly: true,
                        controller: TextEditingController(
                            text: _tunnelService.publicUrl),
                      ),
                    ),
                    const SizedBox(width: 8),
                    NamedIconButton(
                      label: 'copytunnelurl-text'.i18n(),
                      icon: FluentIcons.copy,
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: _tunnelService.publicUrl!));
                        Notify.message('copied-text'.i18n(),
                            severity: InfoBarSeverity.success,
                            duration: const Duration(seconds: 2));
                      },
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildInlineTunnelStatus() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 12,
          child: ProgressRing(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(
          'mcp-tunnel-connecting-text'.i18n(),
          style: TextStyle(fontSize: 12, color: secondaryTextColor(context)),
        ),
      ],
    );
  }

  /// Every link the QR code can show: the public one first while the tunnel
  /// is up, then each LAN address, then loopback as the always-there fallback.
  List<String> get _webUrlOptions => <String>[
        if (_webService.tunnelUrl != null) _webService.tunnelUrl!,
        for (final address in _webAddresses) _webService.urlFor(address),
        _webService.localUrl,
      ];

  String _webUrlLabel(String url) {
    if (url == _webService.tunnelUrl) return 'web-dashboard-public-text'.i18n();
    if (url == _webService.localUrl) return 'web-dashboard-local-text'.i18n();
    return Uri.tryParse(url)?.host ?? url;
  }

  /// Re-reads the LAN addresses so the picker offers every reachable link.
  Future<void> _refreshWebUrls() async {
    final addresses = await _webService.lanAddresses();
    if (!mounted) return;
    setState(() {
      _webAddresses = addresses;
      final options = _webUrlOptions;
      if (!options.contains(_webSelectedUrl)) {
        _webSelectedUrl = options.first;
      }
    });
  }

  Future<void> _setWebEnabled(bool value) async {
    setState(() {
      _webEnabled = value;
      _webStarting = value;
      _webError = null;
      _webTunnelError = null;
    });
    try {
      await _webService.setEnabled(value);
      if (value) await _refreshWebUrls();
    } catch (e) {
      _webEnabled = false;
      _webError = '${'web-dashboard-start-failed-text'.i18n()} '
              '${WslFailure.from(e).shortReason}'
          .trim();
    } finally {
      if (mounted) setState(() => _webStarting = false);
    }
  }

  Future<void> _setWebTunnel(bool value) async {
    setState(() {
      _webTunnelStarting = true;
      _webTunnelError = null;
    });
    try {
      if (value) {
        await _webService.startTunnel();
      } else {
        await _webService.stopTunnel();
      }
    } catch (e) {
      _webTunnelError = '${'mcp-tunnel-failed-text'.i18n()} '
              '${WslFailure.from(e).shortReason}'
          .trim();
    } finally {
      if (mounted) {
        setState(() {
          _webTunnelStarting = false;
          // Prefer the public link while it exists; fall back when it is gone.
          final options = _webUrlOptions;
          _webSelectedUrl = value && _webService.tunnelUrl != null
              ? _webService.tunnelUrl
              : (options.contains(_webSelectedUrl)
                  ? _webSelectedUrl
                  : options.first);
        });
      }
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    Notify.message('copied-text'.i18n(),
        severity: InfoBarSeverity.success,
        duration: const Duration(seconds: 2));
  }

  Widget _buildWebDashboardSettings(BuildContext context) {
    final isPro = _licenseManager.isPro;
    final options = _webUrlOptions;
    final selectedUrl =
        options.contains(_webSelectedUrl) ? _webSelectedUrl! : options.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text(
            'web-dashboard-info-text'.i18n(),
            style: const TextStyle(fontSize: 12.0, fontStyle: FontStyle.italic),
          ),
        ),
        if (!isPro)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoBar(
              title: Text('web-dashboard-pro-required-text'.i18n()),
              severity: InfoBarSeverity.info,
              action: Button(
                key: const ValueKey('test-web-upgrade'),
                onPressed: () {
                  trackUpgradeClick('settings_web_dashboard');
                  navigateGuarded('license');
                },
                child: Text('upgrade-text'.i18n()),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'web-dashboard-toggle-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(
              children: [
                ToggleSwitch(
                  key: const ValueKey('test-web-toggle'),
                  checked: _webEnabled && isPro,
                  onChanged:
                      isPro && !_webStarting ? _setWebEnabled : null,
                ),
                const SizedBox(width: 10.0),
                Expanded(
                  child: Text('web-dashboard-toggle-hint-text'.i18n(),
                      style: isPro
                          ? null
                          : TextStyle(color: disabledTextColor(context))),
                ),
              ],
            ),
          ),
        ),
        if (_webError != null)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              _webError!,
              key: const ValueKey('test-web-error'),
              style: TextStyle(color: Colors.errorPrimaryColor, fontSize: 12),
            ),
          ),
        if (_webEnabled && isPro && _webService.isRunning) ...[
          if (_webAddresses.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: InfoBar(
                key: const ValueKey('test-web-no-network'),
                title: Text('web-dashboard-no-network-text'.i18n()),
                severity: InfoBarSeverity.warning,
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'web-dashboard-url-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ComboBox<String>(
                          key: const ValueKey('test-web-url-combo'),
                          isExpanded: true,
                          value: selectedUrl,
                          items: [
                            for (final url in options)
                              ComboBoxItem(
                                  value: url, child: Text(_webUrlLabel(url))),
                          ],
                          onChanged: (url) {
                            if (url == null) return;
                            setState(() => _webSelectedUrl = url);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      NamedIconButton(
                        key: const ValueKey('test-web-copy-url'),
                        label: 'copydashboardurl-text'.i18n(),
                        icon: FluentIcons.copy,
                        onPressed: () => _copyToClipboard(selectedUrl),
                      ),
                      const SizedBox(width: 4),
                      NamedIconButton(
                        key: const ValueKey('test-web-open'),
                        label: 'web-dashboard-open-text'.i18n(),
                        icon: FluentIcons.open_in_new_window,
                        onPressed: () => launchUrl(Uri.parse(selectedUrl),
                            mode: LaunchMode.externalApplication),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextBox(
                    key: const ValueKey('test-web-url'),
                    readOnly: true,
                    controller: TextEditingController(text: selectedUrl),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Always black-on-white regardless of theme: phone cameras
                // decode that reliably, an inverted code much less so.
                Container(
                  key: const ValueKey('test-web-qr'),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: QrImageView(
                    data: selectedUrl,
                    version: QrVersions.auto,
                    size: 176,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square, color: Colors.black),
                    dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'web-dashboard-url-hint-text'.i18n(),
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 12.0),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'web-dashboard-token-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextBox(
                          key: const ValueKey('test-web-token'),
                          readOnly: true,
                          obscureText: !_webTokenVisible,
                          controller:
                              TextEditingController(text: _webService.token),
                        ),
                      ),
                      const SizedBox(width: 8),
                      NamedIconButton(
                        label: _webTokenVisible
                            ? 'hidetoken-text'.i18n()
                            : 'showtoken-text'.i18n(),
                        icon: _webTokenVisible
                            ? FluentIcons.hide3
                            : FluentIcons.view,
                        onPressed: () => setState(
                            () => _webTokenVisible = !_webTokenVisible),
                      ),
                      const SizedBox(width: 4),
                      NamedIconButton(
                        label: 'copytoken-text'.i18n(),
                        icon: FluentIcons.copy,
                        onPressed: () => _copyToClipboard(_webService.token),
                      ),
                      const SizedBox(width: 4),
                      NamedIconButton(
                        key: const ValueKey('test-web-regenerate-token'),
                        label: 'regeneratetoken-text'.i18n(),
                        icon: FluentIcons.refresh,
                        onPressed: () => dialog(
                          hostContext: context,
                          item: '',
                          title: 'regeneratetokenquestion-text'.i18n(),
                          body: 'regeneratetokenbody-text'.i18n(),
                          submitText: 'regeneratetoken-text'.i18n(),
                          submitInput: false,
                          submitStyle: ButtonStyle(
                            backgroundColor:
                                WidgetStateProperty.all(Colors.red),
                            foregroundColor:
                                WidgetStateProperty.all(Colors.white),
                          ),
                          onSubmit: (_) {
                            // Links are rebuilt from the addresses with the
                            // new token on the next build; only the picker's
                            // (now stale) choice needs resetting.
                            setState(() {
                              _webService.regenerateToken();
                              _webSelectedUrl = null;
                            });
                            Notify.message('tokenregenerated-text'.i18n(),
                                severity: InfoBarSeverity.success);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'web-dashboard-token-hint-text'.i18n(),
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 12.0),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_webService.tunnel.isRunning)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: InfoBar(
                title: Text('web-dashboard-tunnel-warning-text'.i18n()),
                severity: InfoBarSeverity.warning,
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: InfoLabel(
              label: 'web-dashboard-tunnel-toggle-text'.i18n(),
              labelStyle: const TextStyle(fontWeight: FontWeight.w500),
              child: Row(
                children: [
                  ToggleSwitch(
                    key: const ValueKey('test-web-tunnel-toggle'),
                    checked: _webService.tunnel.isRunning,
                    onChanged: _webTunnelStarting ? null : _setWebTunnel,
                  ),
                  const SizedBox(width: 10.0),
                  Expanded(
                    child:
                        Text('web-dashboard-tunnel-toggle-hint-text'.i18n()),
                  ),
                ],
              ),
            ),
          ),
          if (_webTunnelStarting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: _buildInlineTunnelStatus(),
            ),
          if (_webTunnelError != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                _webTunnelError!,
                style:
                    TextStyle(color: Colors.errorPrimaryColor, fontSize: 12),
              ),
            ),
          if (_webService.tunnelUrl != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: InfoLabel(
                label: 'web-dashboard-tunnel-url-text'.i18n(),
                labelStyle: const TextStyle(fontWeight: FontWeight.w500),
                child: Row(
                  children: [
                    Expanded(
                      child: TextBox(
                        key: const ValueKey('test-web-tunnel-url'),
                        readOnly: true,
                        controller: TextEditingController(
                            text: _webService.tunnelUrl),
                      ),
                    ),
                    const SizedBox(width: 8),
                    NamedIconButton(
                      label: 'copytunnelurl-text'.i18n(),
                      icon: FluentIcons.copy,
                      onPressed: () =>
                          _copyToClipboard(_webService.tunnelUrl!),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// ComboBox value standing for "no engine pinned"; a ComboBox cannot carry
  /// null as one of its items.
  static const String _autoEngine = 'auto';

  /// Where the Kubernetes screen reads its clusters from.
  ///
  /// Empty is the normal case and means kubectl's own lookup — `KUBECONFIG`,
  /// then `~/.kube/config`. The field exists for the developer whose clusters
  /// live in a file their terminal points at per project
  /// (bostrot/ai-tasks#61).
  Widget _buildKubernetesSettings(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: InfoLabel(
        label: 'kubeconfig-text'.i18n(),
        labelStyle: const TextStyle(fontWeight: FontWeight.w500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DebouncedTextBox(
              key: const ValueKey('test-kubeconfig-path'),
              initialValue: prefs.getString(kubeConfigPathPrefKey) ?? '',
              placeholder: 'kubeconfigplaceholder-text'.i18n(),
              onCommit: (value) => KubeService().setKubeConfigPath(value),
            ),
            const SizedBox(height: 6.0),
            Text('kubeconfighint-text'.i18n(),
                style:
                    TextStyle(color: secondaryTextColor(context), fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildDockerSettings(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Which engine the Containers screen and the container_* tools drive.
        // "Automatic" is the pref simply being absent, so an install of Docker
        // after the fact is picked up without anyone revisiting this
        // (bostrot/ai-tasks#57). The rest of this section is the older Docker
        // Hub rootfs support, which ships; only the engine pick follows
        // Containers behind its switch.
        if (ExperimentalFeatures.isVisible(ExperimentalFeature.containers))
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'containerengine-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(
              children: [
                ComboBox<String>(
                  key: const ValueKey('test-container-engine'),
                  // Through byExecutable, so a pinned engine a later build
                  // no longer ships reads as "automatic" instead of asserting
                  // its way out of the settings page.
                  value:
                      ContainerEngine.byExecutable(
                                  prefs.getString(containerEnginePrefKey))
                              ?.executable ??
                          _autoEngine,
                  items: [
                    ComboBoxItem(
                      value: _autoEngine,
                      child: Text('automatic-text'.i18n()),
                    ),
                    for (final engine in ContainerEngine.values)
                      ComboBoxItem(
                        value: engine.executable,
                        child: Text(engine.label),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      if (value == null || value == _autoEngine) {
                        prefs.remove(containerEnginePrefKey);
                      } else {
                        prefs.setString(containerEnginePrefKey, value);
                      }
                    });
                  },
                ),
                const SizedBox(width: 10.0),
                Flexible(child: Text('containerenginehint-text'.i18n())),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'showdockershort-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Row(
              children: [
                ToggleSwitch(
                  checked: showDocker,
                  onChanged: (value) {
                    setState(() {
                      showDocker = value;
                      prefs.setBool('showDocker', value);
                    });
                  },
                ),
                const SizedBox(
                  width: 10.0,
                ),
                Text('showdockerlong-text'.i18n()),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'dockermirror-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Tooltip(
              message: 'dockermirrorhint-text'.i18n(),
              child: TextBox(
                controller: _dockerMirrorController,
                placeholder: 'https://mirror.gcr.io',
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'dockerrepo-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: TextBox(
              controller: _dockerrepoController,
              placeholder: 'https://registry-1.docker.io',
            ),
          ),
        ),
        // Moved out of the Sync group: this is the download source for new
        // distro images and has nothing to do with sync (audit ST-23).
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'repofordistro-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: TextBox(
              controller: _repoTextController,
              placeholder: defaultRepoLink,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSyncSettings(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // What "sync" actually syncs, like every other group added by Phase
        // 05 explains itself (audit ST-23).
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Text(
            'sync-info-text'.i18n(),
            style:
                const TextStyle(fontSize: 12.0, fontStyle: FontStyle.italic),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'syncipaddress-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: TextBox(
              controller: _syncIpTextController,
              placeholder: '192.168.1.20',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: InfoLabel(
            label: 'syncpassword-text'.i18n(),
            labelStyle: const TextStyle(fontWeight: FontWeight.w500),
            child: Tooltip(
              message: 'syncpasswordhint-text'.i18n(),
              child: TextBox(
                // No example password in a masked field: readable
                // placeholder text there reads as a stored value, and the
                // example itself was a weak password (ST-23).
                controller: _syncPasswordController,
                obscureText: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGlobalConfigSettings(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'globalconfigurationinfo-text'.i18n(),
                  style: const TextStyle(
                      fontSize: 12.0, fontStyle: FontStyle.italic),
                ),
              ),
              const SizedBox(width: 12.0),
              // The note used to end "run wsl --shutdown" — a terminal
              // instruction printed above a button that does exactly that
              // (audit ST-13, IA-20). The button now sits with the sentence.
              Tooltip(
                message: 'restartwslinfo-text'.i18n(),
                child: Button(
                  key: const ValueKey('test-globalconfig-restart-wsl'),
                  onPressed: () => confirmStopWsl(context, () {
                    WSLApi().restart();
                    Notify.message('shuttingdownwsl-text'.i18n(),
                        severity: InfoBarSeverity.success);
                  }),
                  child: Text('restartwsl-text'.i18n()),
                ),
              ),
            ],
          ),
        ),
        _wslVersionPanel(context),
        settingsWidget(context,
            title: 'kernel',
            tooltip: 'absolutewindowspath-text'.i18n(),
            placeholder: '',
            suffix: _filePickerSuffix('kernel')),
        settingsWidget(context,
            title: 'kernelModules',
            tooltip: 'kernelmodulesinfo-text'.i18n(),
            placeholder: '',
            suffix: _filePickerSuffix('kernelModules', extensions: ['vhdx'])),
        settingsWidget(context,
            title: 'memory',
            tooltip: 'memoryinfo-text'.i18n(),
            type: SettingsType.size,
            sizePostfix: 'GB',
            sizeMin: 1,
            sizeMax: _hostMemoryGb + 1,
            placeholder: ''),
        settingsWidget(context,
            title: 'processors',
            tooltip: 'processorinfo-text'.i18n(),
            type: SettingsType.number,
            sizeMin: 1,
            // Platform.numberOfProcessors, not SysInfo.cores: the latter
            // reported 1 core on the audit host (ST-08).
            sizeMax: Platform.numberOfProcessors,
            placeholder: ''),
        settingsWidget(context,
            title: 'localhostForwarding',
            tooltip: 'wildcardinfo-text'.i18n(),
            type: SettingsType.bool,
            enabled: _networkingMode() != 'mirrored',
            disabledReason: 'ignoredinmirrored-text'.i18n()),
        settingsWidget(context,
            title: 'kernelCommandLine',
            tooltip: 'kernelcmdinfo-text'.i18n(),
            placeholder: ''),
        settingsWidget(context,
            title: 'safeMode',
            tooltip: 'safemodeinfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'swap',
            tooltip: 'swapinfo-text'.i18n(),
            type: SettingsType.size,
            sizePostfix: 'GB',
            sizeMin: 0,
            sizeMax: _hostMemoryGb * 2,
            placeholder: ''),
        settingsWidget(context,
            title: 'swapFile',
            tooltip: 'vhdinfo-text'.i18n(),
            placeholder: '%Temp%\\swap.vhdx',
            suffix: _filePickerSuffix('swapFile', extensions: ['vhdx'])),
        settingsWidget(context,
            title: 'guiApplications',
            tooltip: 'guiinfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'debugConsole',
            tooltip: 'consoleinfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'nestedVirtualization',
            tooltip: 'nestedvirtinfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'vmIdleTimeout',
            tooltip: 'vmidleinfo-text'.i18n(),
            type: SettingsType.number,
            unitLabel: 'milliseconds-text'.i18n(),
            placeholder: '60000'),
        settingsWidget(context,
            title: 'maxCrashDumpCount',
            tooltip: 'maxcrashdumpcountinfo-text'.i18n(),
            type: SettingsType.number,
            placeholder: '10'),
        settingsWidget(context,
            title: 'dnsProxy',
            tooltip: 'dnsproxyinfo-text'.i18n(),
            type: SettingsType.bool,
            enabled: _networkingMode() == 'nat',
            disabledReason:
                'onlyapplieswhen-text'.i18n(['${'networkingmode-text'.i18n()} = nat'])),
        settingsWidget(context,
            title: 'networkingMode',
            tooltip: 'networkingmodeinfo-text'.i18n(),
            type: SettingsType.enumeration,
            options: const [
              'none',
              'nat',
              'bridged',
              'mirrored',
              'virtioproxy'
            ],
            optionNotes: {'bridged': 'deprecatedvalue-text'.i18n()},
            placeholder: 'nat'),
        settingsWidget(context,
            title: 'firewall',
            tooltip: 'firewallinfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'dnsTunneling',
            tooltip: 'dnstunnelinginfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'autoProxy',
            tooltip: 'autoproxyinfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'defaultVhdSize',
            tooltip: 'defaultvhdsizeinfo-text'.i18n(),
            type: SettingsType.size,
            sizePostfix: 'GB',
            placeholder: 'unitexample-text'.i18n()),
      ],
    );
  }

  /// Which WSL is installed, what it said while being asked, and the one-click
  /// update (P05-08, P05-23).
  ///
  /// The version is not decoration: everything from `--manage` on is gated on
  /// it, and until now the app could not answer "which WSL do I have" anywhere.
  /// The warnings underneath are the half a version number cannot supply —
  /// wsl.exe refuses a `.wslconfig` key, or an unsupported host CPU, on stderr
  /// **with exit code 0** (runtime R-1, R-4), and the app used to discard every
  /// one of those lines.
  Widget _wslVersionPanel(BuildContext context) {
    final capabilities = _capabilities;
    final label = capabilities == null
        ? '…'
        : (capabilities.version ??
            (capabilities.wslMissing
                ? 'wslnotfound-text'.i18n()
                : 'wslinbox-text'.i18n()));
    // `wsl --status` does not always name one, and a panel that prints "2"
    // over an answer wsl.exe never gave is claiming a default it cannot see.
    final defaultVersion = capabilities?.defaultVersion == null
        ? 'wslversionunknown-text'.i18n()
        : 'wslversionvalue-text'.i18n(['${capabilities!.defaultVersion}']);

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: InfoLabel(
        label: 'wslversion-text'.i18n(),
        labelStyle: const TextStyle(fontWeight: FontWeight.w500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(label),
                const SizedBox(width: 12.0),
                Button(
                  onPressed: _updatingWsl
                      ? null
                      : () => _runWslUpdate(webDownload: false),
                  child: Text('updatewsl-text'.i18n()),
                ),
                const SizedBox(width: 8.0),
                Tooltip(
                  message: 'updatewslwebdownloadinfo-text'.i18n(),
                  child: Button(
                    onPressed: _updatingWsl
                        ? null
                        : () => _runWslUpdate(webDownload: true),
                    child: Text('updatewslwebdownload-text'.i18n()),
                  ),
                ),
              ],
            ),
            // Which WSL every distro runs on, and which one a new distro is
            // created as. `--set-version` existed on the API and was
            // reachable only from MCP; `--set-default-version` was not wired
            // up at all (upstream #103).
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Row(
                children: [
                  Text('${'defaultwslversion-text'.i18n()}: $defaultVersion'),
                  const SizedBox(width: 12.0),
                  Button(
                    key: const ValueKey('test-wsl-versions-open'),
                    // The dialog can change the default version, and this
                    // line is the only other place it is shown — so the
                    // probe is re-read once the dialog is gone rather than
                    // left reading what was true when the screen opened.
                    onPressed: () => wslVersionDialog(context,
                            showDocker: prefs.getBool('showDocker') ?? false)
                        .then((_) => _reloadCapabilities()),
                    child: Text('wslversions-text'.i18n()),
                  ),
                ],
              ),
            ),
            // Split by what the line is about. The panel used to head every
            // line of both probes' stderr with "WSL reported:" inside the
            // .wslconfig section, so a virtualisation warning read as a
            // complaint about the config file (audit ST-07).
            if (capabilities != null && capabilities.configWarnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  '${'wslreported-text'.i18n()}\n'
                  '${capabilities.configWarnings.join('\n')}',
                  style: TextStyle(
                      color: Colors.warningPrimaryColor, fontSize: 12),
                ),
              ),
            if (capabilities != null && capabilities.otherWarnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  '${'wslstartupwarnings-text'.i18n()}\n'
                  '${capabilities.otherWarnings.join('\n')}',
                  style: TextStyle(
                      color: Colors.warningPrimaryColor, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _updatingWsl = false;

  /// Re-probe `wsl --version` / `wsl --status` and repaint this panel.
  ///
  /// The service caches for the whole process, so the cache has to be dropped
  /// for a re-read to see anything the WSL-versions dialog changed.
  Future<void> _reloadCapabilities() async {
    WSLApi().capabilities.reset();
    final capabilities = await WSLApi().capabilities.load();
    if (!mounted) return;
    setState(() => _capabilities = capabilities);
  }

  Future<void> _runWslUpdate({required bool webDownload}) async {
    setState(() => _updatingWsl = true);
    Notify.message('updatingwsl-text'.i18n(), loading: true);
    final result = await WSLApi().updateWsl(webDownload: webDownload);
    // `--update` prints its progress and its "already up to date" answer on
    // stdout, so the text is worth showing either way rather than a bare
    // success/failure.
    Notify.message(result.ok
        ? '${'wslupdated-text'.i18n()} ${result.text}'.trim()
        : 'wslupdatefailed-text'.i18n([result.text]));
    WSLApi().capabilities.reset();
    final capabilities = await WSLApi().capabilities.load();
    if (!mounted) return;
    setState(() {
      _updatingWsl = false;
      _capabilities = capabilities;
    });
  }

  /// Host memory in whole GB, the ceiling the `memory` and `swap` sliders are
  /// scaled against.
  ///
  /// `SysInfo.getTotalPhysicalMemory()` returns 0 on some hosts (measured in
  /// the audit: 0 bytes and 1 core, so the Memory / Processors / Swap sliders
  /// never rendered at all — ST-08). win32's `GlobalMemoryStatusEx` is the
  /// authoritative answer on Windows; SysInfo stays as the fallback.
  int get _hostMemoryGb {
    final win32Bytes = hostPhysicalMemoryBytes();
    final bytes =
        win32Bytes > 0 ? win32Bytes : SysInfo.getTotalPhysicalMemory();
    return bytes ~/ 1024 ~/ 1024 ~/ 1024;
  }

  /// A `.wslconfig` boolean read the way WSL reads it: an absent key means the
  /// key's documented default, not `false`. Used for the conditional
  /// dependencies below, so an untouched `dnsTunneling` does not grey out the
  /// two keys it gates (doc/audit/wsl-docs/ CC-6).
  ///
  /// The default comes from [kWslConfigBoolDefaults], the same table
  /// [_tristateToggle] renders from — one place for the twelve documented
  /// defaults rather than a literal at each call site.
  bool _configBool(String name) {
    final value = _settings[name]?.text.trim().toLowerCase() ?? '';
    if (value.isEmpty) return kWslConfigBoolDefaults[name] ?? false;
    return value == 'true';
  }

  /// `networkingMode` as WSL resolves it: unset or unrecognised means NAT.
  String _networkingMode() {
    final value = _settings['networkingMode']?.text.trim().toLowerCase() ?? '';
    const known = ['none', 'nat', 'bridged', 'mirrored', 'virtioproxy'];
    return known.contains(value) ? value : 'nat';
  }

  /// The folder-picker button shared by every `.wslconfig` path key. Restricted
  /// to [extensions] where the documentation names a file type.
  Widget _filePickerSuffix(String name, {List<String>? extensions}) {
    return NamedIconButton(
      label: 'choosefile-text'.i18n(),
      icon: FluentIcons.open_folder_horizontal,
      onPressed: () async {
        FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: extensions == null ? FileType.any : FileType.custom,
          allowedExtensions: extensions,
        );
        if (result != null) {
          _settings[name]!.text = result.files.single.path!;
        }
      },
    );
  }

  Widget _buildExperimentalSettings(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsWidget(context,
            title: 'autoMemoryReclaim',
            tooltip: 'automemoryreclaiminfo-text'.i18n(),
            type: SettingsType.enumeration,
            options: const ['disabled', 'gradual', 'dropCache'],
            placeholder: 'dropCache'),
        settingsWidget(context,
            title: 'sparseVhd',
            tooltip: 'sparsevhdinfo-text'.i18n(),
            type: SettingsType.bool),
        settingsWidget(context,
            title: 'bestEffortDnsParsing',
            tooltip: 'besteffortdnsparsinginfo-text'.i18n(),
            type: SettingsType.bool,
            enabled: _configBool('dnsTunneling'),
            disabledReason:
                'onlyapplieswhen-text'.i18n(['${'dnstunneling-text'.i18n()} = true'])),
        settingsWidget(context,
            title: 'dnsTunnelingIpAddress',
            tooltip: 'dnstunnelingipaddressinfo-text'.i18n(),
            placeholder: '10.255.255.254',
            enabled: _configBool('dnsTunneling'),
            disabledReason:
                'onlyapplieswhen-text'.i18n(['${'dnstunneling-text'.i18n()} = true'])),
        settingsWidget(context,
            title: 'initialAutoProxyTimeout',
            tooltip: 'initialautoproxytimeoutinfo-text'.i18n(),
            type: SettingsType.number,
            unitLabel: 'milliseconds-text'.i18n(),
            placeholder: '1000',
            enabled: _configBool('autoProxy'),
            disabledReason: 'onlyapplieswhen-text'.i18n(['${'autoproxy-text'.i18n()} = true'])),
        settingsWidget(context,
            title: 'ignoredPorts',
            tooltip: 'ignoredportsinfo-text'.i18n(),
            placeholder: '3000,9000,9090',
            enabled: _networkingMode() == 'mirrored',
            disabledReason:
                'onlyapplieswhen-text'.i18n(['${'networkingmode-text'.i18n()} = mirrored'])),
        settingsWidget(context,
            title: 'hostAddressLoopback',
            tooltip: 'hostaddressloopbackinfo-text'.i18n(),
            type: SettingsType.bool,
            enabled: _networkingMode() == 'mirrored',
            disabledReason:
                'onlyapplieswhen-text'.i18n(['${'networkingmode-text'.i18n()} = mirrored'])),
      ],
    );
  }

  Widget settingsWidget(
    BuildContext context, {
    String title = '',
    String name = '',
    String tooltip = '',
    dynamic suffix = 0,
    String placeholder = '',
    SettingsType type = SettingsType.text,
    String sizePostfix = '',
    int sizeMax = 0,
    int sizeMin = 0,
    String unitLabel = '',
    List<String> options = const <String>[],
    Map<String, String> optionNotes = const <String, String>{},
    bool enabled = true,
    String disabledReason = '',
  }) {
    if (name.isEmpty) {
      name = title;
    }
    if (_settings[name] == null) {
      _settings[name] = TextEditingController(text: '');
    }
    // A prose label where one exists, with the raw `.wslconfig` key kept as a
    // small annotation. The control used to be titled with the bare camelCase
    // key — "MaxCrashDumpCount" — while the prose labels sat unrendered in
    // en.json (audit ST-09).
    final rawKey = title;
    final labelKey = '${title.toLowerCase()}-text';
    final prose = labelKey.i18n();
    // One parenthetical: "VM idle timeout (vmIdleTimeout, milliseconds)",
    // not "(vmIdleTimeout) (milliseconds)" stacked.
    final annotation =
        unitLabel.isEmpty ? rawKey : '$rawKey, $unitLabel';
    title = prose == labelKey
        ? '${title.replaceFirst(title[0], title[0].toUpperCase())}'
            '${unitLabel.isEmpty ? '' : ' ($unitLabel)'}'
        : '$prose ($annotation)';
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: InfoLabel(
        label: title,
        labelStyle: const TextStyle(fontWeight: FontWeight.w500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tooltip.isNotEmpty && tooltip != title)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(tooltip,
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 12)),
              ),
            // The documented "Only applicable when…" conditions. The control is
            // disabled rather than hidden, so the key stays discoverable and
            // the reason says why WSL would ignore it right now.
            // Secondary, not disabled, text: this line is the one sentence
            // that explains why the control below will not move, and in the
            // disabled colour it measured 2.51:1 — the least legible text on
            // the screen doing the most necessary job (audit ST-10).
            if (!enabled && disabledReason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(disabledReason,
                    style: TextStyle(
                        color: secondaryTextColor(context),
                        fontSize: 12,
                        fontStyle: FontStyle.italic)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 0.0),
              child: Builder(
                builder: (context) {
                  switch (type) {
                    case SettingsType.bool:
                      return _tristateToggle(context, name, enabled: enabled);
                    case SettingsType.enumeration:
                      return _enumerationBox(name,
                          options: options,
                          notes: optionNotes,
                          placeholder: placeholder,
                          enabled: enabled);
                    case SettingsType.size:
                    case SettingsType.number:
                      return _numericSetting(context, name,
                          type: type,
                          sizePostfix: sizePostfix,
                          sizeMin: sizeMin,
                          sizeMax: sizeMax,
                          placeholder: placeholder,
                          enabled: enabled);
                    case SettingsType.text:
                      return TextBox(
                        controller: _settings[name],
                        placeholder: placeholder,
                        enabled: enabled,
                        suffix: suffix != 0 ? suffix : Container(),
                      );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A boolean `.wslconfig` key with the third state the format actually has.
  ///
  /// An absent key means the key's **documented default**, and seven of the
  /// twelve booleans on this screen default to `true` — every one of which used
  /// to render off, with an empty label, on the ordinary case of a machine with
  /// no `.wslconfig` at all. A user reading the screen concluded the opposite
  /// of the truth for all seven (audit CC-1).
  ///
  /// The undo button empties the controller, which [_saveWslConfig] turns into
  /// a line *removed* from the file. That third state had nowhere to be written
  /// until P05-02 gave the engine a delete branch (CC-11), which is why this
  /// ships with the engine rather than before it.
  Widget _tristateToggle(BuildContext context, String name,
      {required bool enabled}) {
    final raw = _settings[name]!.text.trim();
    final isSet = raw.isNotEmpty;
    final documented = kWslConfigBoolDefaults[name];
    final checked = isSet ? raw.toLowerCase() == 'true' : (documented ?? false);

    return Row(
      children: [
        ToggleSwitch(
          checked: checked,
          onChanged: enabled
              ? (value) {
                  _settings[name]!.text = value ? 'true' : 'false';
                  setState(() {
                    _settings = _settings;
                  });
                }
              : null,
          content: Text(isSet
              ? raw
              : '${checked ? 'true' : 'false'} '
                  '(${'settingdefault-text'.i18n()})'),
        ),
        if (isSet && enabled)
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: NamedIconButton(
              label: 'resettodefault-text'.i18n(),
              icon: FluentIcons.undo,
              iconSize: 14.0,
              onPressed: () {
                _settings[name]!.text = '';
                setState(() {
                  _settings = _settings;
                });
              },
            ),
          ),
        // No trailing "Not set — using the default" caption: the switch
        // label already says "(Default)", and stating the one fact twice in
        // two type styles, twelve times down the page, was ST-15.
      ],
    );
  }

  /// A closed set of documented values. Anything already in the file that is not
  /// one of them is kept as an extra item rather than dropped, so opening the
  /// screen never rewrites a value the user put there by hand — and never trips
  /// `ComboBox`'s "value must be among the items" assert.
  Widget _enumerationBox(
    String name, {
    required List<String> options,
    required Map<String, String> notes,
    required String placeholder,
    required bool enabled,
  }) {
    final current = _settings[name]!.text.trim();
    final match = options.cast<String?>().firstWhere(
        (option) => option!.toLowerCase() == current.toLowerCase(),
        orElse: () => null);
    final selected = current.isEmpty ? null : (match ?? current);
    final items = <String>[
      ...options,
      if (selected != null && match == null) selected,
    ];

    // A DropDownButton, not a ComboBox: the ComboBox popup anchors on the
    // selected item, so with a late value chosen it opened over its own
    // field (audit ST-17); this flyout opens below and marks the current
    // value. The leading "Not set" entry is the un-choose the booleans have
    // always had — an enumeration used to be un-clearable once touched
    // (ST-16): it empties the value, which Save writes as a removed line, so
    // the documented default applies again.
    return DropDownButton(
      title: Expanded(
        child: Text(
          selected == null
              ? (placeholder.isEmpty ? 'settingunset-text'.i18n() : placeholder)
              : selected,
          textAlign: TextAlign.start,
          style: selected == null
              ? TextStyle(color: secondaryTextColor(context))
              : null,
        ),
      ),
      items: [
        MenuFlyoutItem(
          selected: selected == null,
          leading: selected == null
              ? const Icon(FluentIcons.check_mark, size: 12.0)
              : const SizedBox.square(dimension: 12.0),
          text: Text('settingunset-text'.i18n()),
          onPressed: enabled
              ? () => setState(() => _settings[name]!.text = '')
              : null,
        ),
        const MenuFlyoutSeparator(),
        for (final option in items)
          MenuFlyoutItem(
            selected: option == selected,
            leading: option == selected
                ? const Icon(FluentIcons.check_mark, size: 12.0)
                : const SizedBox.square(dimension: 12.0),
            text: Text(notes.containsKey(option)
                ? '$option — ${notes[option]}'
                : option),
            onPressed: enabled
                ? () => setState(() => _settings[name]!.text = option)
                : null,
          ),
      ],
    );
  }

  /// The `size` and `number` keys.
  ///
  /// A slider only when the value the file holds actually fits on it: a
  /// documented-legal `memory=8589934592` or a `processors=64` copied from a
  /// bigger machine is out of range, and `Slider` asserts on that in its
  /// constructor (doc/audit/wsl-docs/ CC-9). Those fall back to a text box that
  /// says so, so the value is left exactly as written instead of being silently
  /// clamped or snapped to the minimum.
  Widget _numericSetting(
    BuildContext context,
    String name, {
    required SettingsType type,
    required String sizePostfix,
    required int sizeMin,
    required int sizeMax,
    required String placeholder,
    required bool enabled,
  }) {
    final raw = _settings[name]!.text.trim();
    final double? value = type == SettingsType.size
        ? parseWslSize(raw,
            unit: sizePostfix.isEmpty ? 'B' : sizePostfix,
            bareUnitMax: sizeMax.toDouble())
        : parseWslCount(raw)?.toDouble();
    final hasSlider = sizeMax > sizeMin;
    final fits = wslSliderFits(value, min: sizeMin, max: sizeMax);

    if (!hasSlider || (raw.isNotEmpty && !fits)) {
      String warning = '';
      if (raw.isNotEmpty && value == null) {
        warning = type == SettingsType.size
            ? 'settinginvalidsize-text'.i18n()
            : 'settinginvalidnumber-text'.i18n();
      } else if (hasSlider && raw.isNotEmpty) {
        warning =
            'settingoutofrange-text'.i18n(['$sizeMin – $sizeMax$sizePostfix']);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextBox(
            controller: _settings[name],
            placeholder: placeholder,
            enabled: enabled,
            // Validation runs on the keystroke, not on whatever unrelated
            // rebuild happened next (audit ST-06).
            onChanged: (_) => setState(() {}),
          ),
          if (warning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(
                warning,
                style:
                    TextStyle(color: Colors.warningPrimaryColor, fontSize: 12),
              ),
            ),
        ],
      );
    }

    return SizedBox(
        width: MediaQuery.of(context).size.width,
        child: Slider(
            min: sizeMin.toDouble(),
            max: sizeMax.toDouble(),
            value: value ?? sizeMin.toDouble(),
            style: SliderThemeData(
              labelBackgroundColor: AppTheme().color,
            ),
            onChanged: enabled
                ? (value) {
                    setState(() {
                      _settings[name]!.text = type == SettingsType.size
                          ? formatWslSize(value, sizePostfix)
                          : value.round().toString();
                    });
                  }
                : null,
            label: _settings[name]!.text.isEmpty
                ? '$sizeMin$sizePostfix'
                : _settings[name]!.text));
  }
}
