import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/error_view.dart';
import 'package:localization/localization.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/ai_workspace/config_service.dart';
import 'package:wsl2distromanager/api/ai_workspace/service.dart';
import 'package:wsl2distromanager/api/ai_workspace/shared_settings.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/api/sandbox_service.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/volume_mounts.dart';
import 'package:wsl2distromanager/api/wsl.dart' show formatElapsed;
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/volume_mounts_dialog.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'package:wsl2distromanager/screens/ai_workspace_config_dialog.dart';
import 'package:wsl2distromanager/screens/ai_workspace_shared_settings_dialog.dart';

/// The five things a card can be asked to do, for per-action busy state
/// (audit PS-15).
enum _CardAction { install, start, stop, dashboard, configure, uninstall }

/// How often a tool still reporting [ToolStatus.starting] is re-probed.
/// Open WebUI's migrations take ~2 minutes, so this runs a good few times;
/// each tick is one cheap `docker inspect`.
const Duration _kStartingPoll = Duration(seconds: 10);

/// How often the card repaints while an install is streaming. The service
/// keeps only the newest line, so this is a repaint rate, not a sampling
/// rate — nothing is lost by missing a line, and one second is fast enough
/// to read as live without rebuilding the page on every `npm` write.
const Duration _kInstallProgressPoll = Duration(seconds: 1);

class AiWorkspacePage extends StatefulWidget {
  const AiWorkspacePage({super.key});

  @override
  State<AiWorkspacePage> createState() => _AiWorkspacePageState();
}

class _AiWorkspacePageState extends State<AiWorkspacePage> {
  late final AiWorkspaceService _service;
  late final AiWorkspaceConfigService _configService;

  /// Writes the assistant's endpoint, key and model into every tool
  /// (bostrot/ai-tasks#81). Built here rather than provided: it is nothing
  /// but the two services above. The install hook is the copy main.dart
  /// attached.
  late final AiWorkspaceSharedSettingsService _sharedSettings;
  final SandboxService _sandbox = SandboxService();
  List<String> _sandboxes = [];
  // Gates only the distro check, not the page — cards render immediately.
  bool _preparingDistro = true;
  String? _error;

  /// The raw runtime key behind [_error] when it was one of the known
  /// VM-provisioning cases — those get the guided setup button.
  String? _errorKey;
  bool _settingUp = false;
  final Set<AiWorkspaceTool> _busyTools = {};

  /// Which action is in flight per tool. One shared busy flag used to put
  /// the spinner on every enabled button on the card at once — Start spun
  /// Uninstall, opening the dashboard spun Stop and Uninstall (audit PS-15).
  /// The other controls still disable while something runs; only the pressed
  /// one spins.
  final Map<AiWorkspaceTool, _CardAction> _busyAction = {};
  // Each tool clears independently as its own check resolves.
  final Set<AiWorkspaceTool> _checkingTools = {...AiWorkspaceTool.values};
  // Re-attaches this page to an install that a previous instance started.
  Timer? _installWatch;
  // Tools this page has seen mid-install. A tool that drops out of the
  // service's installing set while it is in here has just finished, and is
  // the one that needs its real status read back.
  final Set<AiWorkspaceTool> _watchedInstalls = {};
  Timer? _startingWatch;

  bool get _isPro {
    try {
      return GlobalVariable.testProEnabled || LicenseManager().isPro;
    } catch (_) {
      return false;
    }
  }

  /// Off means the page must not touch WSL at all: opening it is the other
  /// path (besides startup) that provisions the workspace distro.
  bool get _aiEnabled => AiService.featuresEnabled;

  @override
  void initState() {
    super.initState();
    // Shared instance from main.dart — startup already began these checks.
    _service = context.read<AiWorkspaceService>();
    _configService = context.read<AiWorkspaceConfigService>();
    _sharedSettings = AiWorkspaceSharedSettingsService(
        workspace: _service, config: _configService);
    _sandboxes = _sandbox.list();
    // Creation is app-global (it survives leaving this page); repaint the
    // section whenever its stage moves, including from "running" to done.
    SandboxService.creationStage.addListener(_onSandboxStage);
    SandboxService.creationProgress.addListener(_onSandboxStage);
    AiService.featuresChanged.addListener(_onAiSwitch);
    _startIfAvailable();
  }

  /// Whether [_initService] has run for this page. Off-then-on without
  /// leaving the page (the switch lives one guarded navigation away, but a
  /// rebuild can outlive it) must probe then, not render every tool as
  /// "not installed" over an empty state.
  bool _started = false;

  void _startIfAvailable() {
    if (_isPro && _aiEnabled) {
      _started = true;
      // Spinner only where nothing is known yet; cached state renders at
      // once and is refreshed below without blocking the UI.
      _checkingTools
        ..clear()
        ..addAll(AiWorkspaceTool.values.where(
            (tool) => _service.getState(tool)?.hasKnownStatus != true));
      _initService();
    } else {
      // Skip touching WSL entirely for non-Pro users and for users who
      // switched AI off — nothing to probe, nothing to set up.
      _preparingDistro = false;
      _checkingTools.clear();
    }
  }

  void _onAiSwitch() {
    if (!mounted) return;
    setState(() {
      if (!_started) _startIfAvailable();
    });
  }

  @override
  void dispose() {
    SandboxService.creationStage.removeListener(_onSandboxStage);
    SandboxService.creationProgress.removeListener(_onSandboxStage);
    AiService.featuresChanged.removeListener(_onAiSwitch);
    _installWatch?.cancel();
    _startingWatch?.cancel();
    super.dispose();
  }

  /// A tool in [ToolStatus.starting] settles on its own once its container
  /// finishes migrating — the health gate only has to be asked again. Nothing
  /// else on this page re-probes a tool that has already been checked, so
  /// without this poll the card sits on "Starting up..." with Start, Stop and
  /// the dashboard all disabled until the user happens to click something.
  /// Observed against a real Open WebUI container: `docker inspect` reported
  /// `healthy` while the card still read "Startet...".
  void _syncStartingWatch() {
    if (_startingTools().isEmpty) {
      _startingWatch?.cancel();
      _startingWatch = null;
      return;
    }
    // Already polling — a second timer would just double the probe rate.
    if (_startingWatch != null) return;
    _startingWatch = Timer.periodic(_kStartingPoll, (timer) async {
      final pending = _startingTools();
      if (!mounted || pending.isEmpty) {
        timer.cancel();
        _startingWatch = null;
        return;
      }
      await Future.wait(pending.map(_service.refreshStatus));
      if (mounted) setState(() {});
    });
  }

  List<AiWorkspaceTool> _startingTools() => AiWorkspaceTool.values
      .where((tool) => _service.getState(tool)?.status == ToolStatus.starting)
      .toList();

  /// Ticks while any install is running. An install started by the button on
  /// this page and one inherited from a previous instance of it are the same
  /// case — the service owns both — so the page only has to watch: each tick
  /// repaints the streamed progress line under the card, and a tool that has
  /// left [AiWorkspaceService.isInstalling] gets its real status read back.
  void _syncInstallWatch() {
    _watchedInstalls
        .addAll(AiWorkspaceTool.values.where(_service.isInstalling));
    if (_watchedInstalls.isEmpty) {
      _installWatch?.cancel();
      _installWatch = null;
      return;
    }
    // Already ticking — a second timer would just double the repaint rate.
    if (_installWatch != null) return;
    _installWatch = Timer.periodic(_kInstallProgressPoll, (timer) async {
      if (!mounted) {
        timer.cancel();
        _installWatch = null;
        return;
      }
      final finished =
          _watchedInstalls.where((t) => !_service.isInstalling(t)).toList();
      _watchedInstalls.removeAll(finished);
      if (_watchedInstalls.isEmpty) {
        timer.cancel();
        _installWatch = null;
      }
      // Every tick, not only the last one: the progress line changes while
      // the installer is still running, which is the whole point of showing
      // it. Nothing here touches WSL, so a repaint is all it costs.
      setState(() {});
      for (final tool in finished) {
        await _service.refreshStatus(tool);
      }
      if (mounted && finished.isNotEmpty) {
        setState(_syncStartingWatch);
      }
    });
  }

  Future<void> _initService() async {
    if (_service.toolStates.isEmpty) {
      _service.seedToolStates();
    }
    _syncInstallWatch();

    try {
      await _service.ensureDistro();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _friendlyInitError(e);
          _preparingDistro = false;
          _checkingTools.clear();
        });
      }
      return;
    }

    if (mounted) {
      setState(() => _preparingDistro = false);
    }

    // Refresh anything not yet verified this session, cached or not.
    // Results land in place without flashing a spinner.
    for (final tool in AiWorkspaceTool.values) {
      if (_service.getState(tool)?.checked == true) continue;
      unawaited(_service.refreshStatus(tool).then((_) {
        if (mounted) {
          setState(() {
            _checkingTools.remove(tool);
            // A tool seeded or probed as `starting` has to keep being asked.
            _syncStartingWatch();
          });
        }
      }));
    }

    // Re-entering the page finds every tool already `checked`, so the loop
    // above probes nothing — but one of them may still be mid-migration from a
    // start issued before the user navigated away.
    _syncStartingWatch();
  }

  /// The runtime raises a bare i18n key for the two VM-provisioning cases;
  /// turn those into the localized sentence, and leave anything else as its
  /// own text.
  String _friendlyInitError(Object error) {
    final raw = error.toString().replaceFirst('Exception: ', '');
    const known = {
      'ai-workspace-vm-missing-text',
      'ai-workspace-vm-stopped-text',
      'ai-workspace-vm-unreachable-text',
    };
    _errorKey = known.contains(raw) ? raw : null;
    return known.contains(raw) ? raw.i18n() : raw;
  }

  /// Whether the current error is one the guided setup can fix by itself:
  /// a missing VM (download + create + boot) or a stopped one (boot).
  bool get _setupCanFix =>
      _errorKey == 'ai-workspace-vm-missing-text' ||
      _errorKey == 'ai-workspace-vm-stopped-text' ||
      _errorKey == 'ai-workspace-vm-unreachable-text';

  Future<void> _runGuidedSetup() async {
    setState(() => _settingUp = true);
    try {
      await _service.setUpEnvironment();
      Notify.message('ai-workspace-setup-done-text'.i18n(),
          severity: InfoBarSeverity.success);
      await _retryInit();
    } catch (e) {
      if (mounted) {
        setState(() => _error = _friendlyInitError(e));
      }
    } finally {
      if (mounted) setState(() => _settingUp = false);
    }
  }

  Future<void> _retryInit() async {
    // Clear `checked` so the retry actually re-probes everything.
    for (final tool in AiWorkspaceTool.values) {
      _service.getState(tool)?.checked = false;
    }
    setState(() {
      _error = null;
      _preparingDistro = true;
      _checkingTools
        ..clear()
        ..addAll(AiWorkspaceTool.values);
    });
    await _initService();
  }

  Future<void> _handleInstall(AiWorkspaceTool tool) async {
    if (!context.mounted) return;
    setState(() {
      // Drop the previous failure so a retry does not render under a stale
      // error message. install() does this too — doing it here as well is
      // what makes the card update on the same frame as the button press.
      _service.clearError(tool);
      _busyTools.add(tool);
      _busyAction[tool] = _CardAction.install;
    });
    // install() marks the tool as installing before its first await, so by
    // the time this returns the future the service already knows about it and
    // the progress ticker can start on the same frame as the button press.
    final install = _service.install(tool);
    if (mounted) setState(_syncInstallWatch);
    try {
      await install;
    } finally {
      if (context.mounted) {
        setState(() {
          _busyTools.remove(tool);
          _busyAction.remove(tool);
        });
      }
    }
  }

  Future<void> _handleStart(AiWorkspaceTool tool) async {
    if (!context.mounted) return;
    setState(() {
      _service.clearError(tool);
      _busyTools.add(tool);
      _busyAction[tool] = _CardAction.start;
    });
    try {
      await _service.start(tool);
    } finally {
      if (context.mounted) {
        setState(() {
          _busyTools.remove(tool);
          // start() leaves a health-gated tool on `starting`; poll it out.
          _syncStartingWatch();
        });
      }
    }
  }

  /// A failed install or start holds the card until the user acknowledges it.
  /// Dismissing releases it and asks WSL what the truth actually is.
  Future<void> _handleDismissError(AiWorkspaceTool tool) async {
    if (!context.mounted) return;
    setState(() {
      _service.clearError(tool);
      _checkingTools.add(tool);
    });
    await _service.refreshStatus(tool);
    if (mounted) {
      setState(() {
        _checkingTools.remove(tool);
        _syncStartingWatch();
      });
    }
  }

  Future<void> _handleStop(AiWorkspaceTool tool) async {
    if (!context.mounted) return;
    setState(() {
      _busyTools.add(tool);
      _busyAction[tool] = _CardAction.stop;
    });
    try {
      await _service.stop(tool);
    } finally {
      if (context.mounted) {
        setState(() {
          _busyTools.remove(tool);
          _busyAction.remove(tool);
        });
      }
    }
  }

  Future<void> _handleOpenDashboard(AiWorkspaceTool tool) async {
    if (!context.mounted) return;
    setState(() {
      _busyTools.add(tool);
      _busyAction[tool] = _CardAction.dashboard;
    });
    try {
      final url = await _service.getDashboardUrl(tool);
      if (url == null) {
        Notify.message('ai-workspace-dashboard-failed-text'.i18n());
        return;
      }
      // No canLaunchUrl gate: on Windows it reports false for perfectly
      // launchable http URLs, which is what made a healthy dashboard look
      // unreachable. Every other launch site in this app calls launchUrl
      // directly for the same reason.
      final uri = Uri.parse(url);
      try {
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          Notify.message('ai-workspace-dashboard-failed-text'.i18n());
        }
      } catch (_) {
        Notify.message('ai-workspace-dashboard-failed-text'.i18n());
      }
    } finally {
      if (context.mounted) {
        setState(() {
          _busyTools.remove(tool);
          _busyAction.remove(tool);
        });
      }
    }
  }

  /// Opens the dynamic settings form for [tool] (bostrot/ai-tasks#72).
  ///
  /// The fields come from whatever the tool itself described this session, so
  /// this page needs to know nothing about them — only which tool was asked
  /// for and what it is called.
  Future<void> _handleConfigure(AiWorkspaceTool tool) async {
    setState(() {
      _busyTools.add(tool);
      _busyAction[tool] = _CardAction.configure;
    });
    bool? saved;
    try {
      saved = await showAiWorkspaceConfigDialog(
        context: context,
        configService: _configService,
        tool: tool,
        toolName: _toolName(tool),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyTools.remove(tool);
          _busyAction.remove(tool);
        });
      }
    }

    // Every tool here reads its configuration when it starts, so a change
    // saved against a running one changes nothing until it is restarted.
    if (saved == true &&
        mounted &&
        _service.getState(tool)?.status == ToolStatus.running) {
      Notify.message(
          'ai-workspace-config-restart-hint-text'.i18n([_toolName(tool)]));
    }
  }

  Future<void> _handleUninstall(AiWorkspaceTool tool) async {
    final confirmed = await showDialog<bool>(
      context: context,
      // The tool's name used to float on a bare line above a sentence that
      // called it "this tool" (PS-28), and the button that removes it was the
      // accent-blue primary every harmless dialog uses, while every other
      // destructive confirmation in the app submits in red (PS-27).
      builder: (dialogContext) => ContentDialog(
        title: Text('ai-workspace-uninstall-title'.i18n([_toolName(tool)])),
        content: Text('ai-workspace-uninstall-confirm'.i18n([_toolName(tool)])),
        actions: [
          FilledButton(
            key: const ValueKey('test-ai-uninstall-confirm'),
            style: ButtonStyle(
              backgroundColor: ButtonState.all(Colors.red),
              foregroundColor: ButtonState.all(Colors.white),
            ),
            onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(true),
            child: Text('ai-workspace-uninstall-btn'.i18n()),
          ),
          Button(
            key: const ValueKey('test-ai-uninstall-cancel'),
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext, rootNavigator: true).pop(false),
            child: Text('cancel-text'.i18n()),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    if (!context.mounted) return;
    setState(() {
      _busyTools.add(tool);
      _busyAction[tool] = _CardAction.uninstall;
    });
    try {
      final success = await _service.uninstall(tool);
      if (mounted) {
        setState(() {}); // Rebuild UI after uninstall completes
        if (success) {
          // One key with a placeholder — word order was baked into Dart
          // concatenation, so no locale could move the subject (audit PS-29).
          Notify.message('ai-workspace-uninstall-success'.i18n([_toolName(tool)]),
              severity: InfoBarSeverity.success);
        } else {
          final state = _service.getState(tool);
          Notify.message(state?.errorMessage ?? 'ai-workspace-uninstall-failed'.i18n());
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyTools.remove(tool);
          _busyAction.remove(tool);
        });
      }
    }
  }

  Widget _buildPaywall(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    accent.withValues(alpha: 0.25),
                    accent.withValues(alpha: 0.08),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(FluentIcons.robot, size: 36, color: accent),
            ),
            const SizedBox(height: 20),
            // The badge stays on the paywall: the one moment the app asks
            // for money must not be the one moment it stops saying the
            // feature is beta (audit PS-13).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Flexible: a long title (or a raw key under test) must wrap
                // inside the 420px column rather than overflow it.
                Flexible(
                  child: Text(
                    'ai-workspace-title'.i18n(),
                    textAlign: TextAlign.center,
                    style: FluentTheme.of(context).typography.titleLarge,
                  ),
                ),
                const SizedBox(width: 8),
                const BetaBadge(),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'ai-workspace-pro-required-text'.i18n(),
              textAlign: TextAlign.center,
              style: TextStyle(color: secondaryTextColor(context)),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const ValueKey('test-ai-workspace-upgrade'),
              onPressed: () {
                trackUpgradeClick('ai_workspace');
                router.pushNamed('license');
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.crown, size: 14),
                  const SizedBox(width: 8),
                  Text('upgrade-pro-text'.i18n()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Reached by URL or from a stale pane: the entry itself is hidden while
  /// AI is off. Says where the switch is instead of quietly provisioning.
  Widget _buildSwitchedOff(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(FluentIcons.robot,
                size: 36, color: secondaryTextColor(context)),
            const SizedBox(height: 20),
            Text(
              'ai-workspace-title'.i18n(),
              textAlign: TextAlign.center,
              style: FluentTheme.of(context).typography.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'ai-disabled-text'.i18n(),
              textAlign: TextAlign.center,
              style: TextStyle(color: secondaryTextColor(context)),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const ValueKey('test-ai-workspace-open-settings'),
              onPressed: () => navigateGuarded('settings'),
              child: Text('opensettings-text'.i18n()),
            ),
          ],
        ),
      ),
    );
  }

  String _toolName(AiWorkspaceTool tool) {
    switch (tool) {
      case AiWorkspaceTool.hermesAgent: return 'Hermes Agent';
      case AiWorkspaceTool.openClaw: return 'OpenClaw';
      case AiWorkspaceTool.openWebUi: return 'Open WebUI';
      case AiWorkspaceTool.openCode: return 'OpenCode';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Paywall before the switch: the switch is only offered to Pro, so a
    // lapsed licence must not be told to flip a control it cannot see.
    if (!_isPro) {
      return _buildPaywall(context);
    }
    if (!_aiEnabled) {
      return _buildSwitchedOff(context);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'ai-workspace-title'.i18n(),
                style: FluentTheme.of(context).typography.titleLarge,
              ),
              const SizedBox(width: 10),
              const BetaBadge(key: ValueKey('test-ai-workspace-beta-badge')),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'ai-workspace-subtitle'.i18n(),
            style: FluentTheme.of(context).typography.bodyStrong,
          ),
          const SizedBox(height: 12),
          const BetaBanner(),
          const SizedBox(height: 16),
          // Only the tool cards live in the workspace environment (the
          // 'ai-workspace' VM, or that distro on Windows). A sandbox is its
          // own distro and needs none of it, so a missing, stopped,
          // unreachable or broken environment swaps out the tool section
          // alone — the page used to vanish behind a full-screen setup or
          // error view and take the sandboxes with it.
          if (_error != null && _setupCanFix)
            _buildGuidedSetupCard(context)
          else if (_error != null)
            _buildInitErrorCard(context)
          else ...[
            if (_preparingDistro) ...[
              _buildInlineStatus('ai-workspace-checking-env-text'.i18n()),
              const SizedBox(height: 16),
            ],
            ...AiWorkspaceTool.values.map((tool) => _buildToolCard(tool)),
            if (!_preparingDistro) ...[
              const SizedBox(height: 8),
              _buildSharedSettingsCard(context),
            ],
            if (!_preparingDistro && _mountsSupported) ...[
              const SizedBox(height: 8),
              _buildMountsCard(context),
            ],
          ],
          const SizedBox(height: 8),
          _buildSandboxSection(context),
        ],
      ),
    );
  }

  /// A missing or stopped workspace VM is not an error the user must fix
  /// by hand: the guided setup downloads the cloud image, creates the VM
  /// and boots it. Rendered in place of the tool cards, not the whole page.
  Widget _buildGuidedSetupCard(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor;
    // The same button drives all three cases, but a VM that is merely
    // stopped, or up and silent over SSH, is not "not installed": the
    // Home screen showed 'ai-workspace' running with an address while
    // this page offered to download Debian and create it. Say which
    // state it is in and what the button will do about it.
    final String body;
    final String label;
    if (_errorKey == 'ai-workspace-vm-stopped-text') {
      body = 'ai-workspace-start-vm-text'.i18n();
      label = 'ai-workspace-start-vm-btn'.i18n();
    } else if (_errorKey == 'ai-workspace-vm-unreachable-text') {
      body = 'ai-workspace-repair-text'.i18n();
      label = 'ai-workspace-repair-btn'.i18n();
    } else {
      body = 'ai-workspace-setup-text'.i18n();
      label = 'ai-workspace-setup-btn'.i18n();
    }
    return _buildEnvironmentCard(
      key: const ValueKey('test-workspace-setup-card'),
      icon: Icon(FluentIcons.robot, size: 28, color: accent),
      children: [
        Text(body, style: TextStyle(color: secondaryTextColor(context))),
        const SizedBox(height: 12),
        BusyButton(
          key: const ValueKey('test-workspace-setup'),
          filled: true,
          label: label,
          busyLabel: 'ai-workspace-setup-busy-text'.i18n(),
          busy: _settingUp,
          onPressed: _settingUp ? null : _runGuidedSetup,
        ),
      ],
    );
  }

  /// Only genuinely unexpected failures render as errors — and only the
  /// tool section does, so the sandboxes underneath stay reachable.
  Widget _buildInitErrorCard(BuildContext context) {
    return _buildEnvironmentCard(
      key: const ValueKey('test-workspace-error-card'),
      icon: Icon(FluentIcons.error, size: 28, color: destructiveColor(context)),
      children: [
        // Was 'Error loading AI Workspace: <Exception.toString()>' —
        // hardcoded English wrapped around a class name (audit PS-31).
        ErrorBody(
          failure: WslFailure.from(_error),
          leading: 'ai-workspace-load-failed-text'.i18n(),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _retryInit,
          child: Text('retry-text'.i18n()),
        ),
      ],
    );
  }

  /// The shell both environment cards share: a leading icon beside a
  /// left-aligned body, sitting where the tool cards otherwise would.
  Widget _buildEnvironmentCard({
    required Key key,
    required Widget icon,
    required List<Widget> children,
  }) {
    return Card(
      key: key,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  /// Whether the workspace's backend can mount host folders at all. Fixed
  /// for the page's life, and the page rebuilds every second while a tool
  /// installs.
  late final bool _mountsSupported =
      VolumeMountService.isSupported(vmBackend());

  /// Host folders mounted inside the workspace (bostrot/ai-tasks#79): the
  /// tools run in there, and a project they are meant to work on lives out
  /// here. The editor is the same one every instance row opens; the
  /// workspace is just the instance called [kAiWorkspaceDistro].
  Widget _buildMountsCard(BuildContext context) {
    return Card(
      key: const ValueKey('test-workspace-mounts-card'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(FluentIcons.fabric_folder_link, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ai-workspace-mounts-title'.i18n(),
                    style: FluentTheme.of(context).typography.subtitle),
                const SizedBox(height: 4),
                Text('ai-workspace-mounts-subtitle'.i18n(),
                    style: TextStyle(
                        fontSize: 12, color: secondaryTextColor(context))),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Button(
            key: const ValueKey('test-workspace-mounts'),
            onPressed: () => showVolumeMountsDialog(kAiWorkspaceDistro,
                context: context),
            child: Text('ai-workspace-mounts-btn'.i18n()),
          ),
        ],
      ),
    );
  }

  /// The assistant's endpoint, key and model, which every tool uses
  /// (bostrot/ai-tasks#81). The row says what is set, so the page answers
  /// "which model are these tools on?" without opening the dialog, and
  /// points at Settings while nothing is.
  Widget _buildSharedSettingsCard(BuildContext context) {
    final settings = _sharedSettings.current();
    final subtitle = settings.isConfigured
        ? 'ai-workspace-shared-current-text'
            .i18n([settings.model, settings.endpoint])
        : 'ai-workspace-shared-unset-text'.i18n();
    return Card(
      key: const ValueKey('test-workspace-shared-card'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(FluentIcons.plug_connected, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ai-workspace-shared-title'.i18n(),
                    style: FluentTheme.of(context).typography.subtitle),
                const SizedBox(height: 4),
                Text(subtitle,
                    key: const ValueKey('test-workspace-shared-subtitle'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: secondaryTextColor(context))),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Button(
            key: const ValueKey('test-workspace-shared'),
            onPressed: () async {
              await showAiWorkspaceSharedSettingsDialog(
                context: context,
                service: _sharedSettings,
                toolName: _toolName,
                openSettings: () => navigateGuarded('settings'),
              );
              // The subtitle reads the assistant's values; repaint it.
              if (mounted) setState(() {});
            },
            child: Text('ai-workspace-shared-btn'.i18n()),
          ),
        ],
      ),
    );
  }

  /// Sandboxes: app-created Ubuntu distros an AI chat is confined to. The chat
  /// gets only the sandbox_* tools, so the model can do anything inside the
  /// distro and nothing outside it.
  Widget _buildSandboxSection(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.processing, size: 18),
              const SizedBox(width: 8),
              Text('sandbox-title-text'.i18n(),
                  style: FluentTheme.of(context).typography.subtitle),
            ],
          ),
          const SizedBox(height: 6),
          Text('sandbox-subtitle-text'.i18n(),
              style: TextStyle(
                  fontSize: 12, color: secondaryTextColor(context))),
          const SizedBox(height: 12),
          if (_sandboxes.isEmpty && !SandboxService.isCreating)
            Text('sandbox-none-text'.i18n(),
                style: TextStyle(color: secondaryTextColor(context))),
          for (final distro in _sandboxes)
            Padding(
              padding: const EdgeInsets.only(bottom: 6.0),
              child: Row(
                children: [
                  const Icon(FluentIcons.cube_shape, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(distro,
                          overflow: TextOverflow.ellipsis)),
                  Button(
                    key: ValueKey('test-sandbox-chat-$distro'),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(FluentIcons.chat, size: 12),
                      const SizedBox(width: 6),
                      Text('sandbox-open-chat-text'.i18n()),
                    ]),
                    // The docked panel, not a modal: it stays open while the
                    // user works elsewhere in the app, and its transcript
                    // persists across close/reopen.
                    onPressed: () {
                      GlobalVariable.sandboxChat.value = distro;
                      GlobalVariable.aiPanel.value = true;
                    },
                  ),
                  const SizedBox(width: 6),
                  MergeSemantics(
                    child: Tooltip(
                      message: 'delete-text'.i18n(),
                      child: IconButton(
                        icon: Icon(FluentIcons.delete,
                            size: 14, color: destructiveColor(context)),
                        onPressed: () => _deleteSandbox(distro),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          if (SandboxService.isCreating)
            Row(
              children: [
                Expanded(child: _buildInlineStatus(_sandboxStatusLabel(), fill: true)),
                Button(
                  key: const ValueKey('test-sandbox-cancel'),
                  onPressed: SandboxService.cancelCreation,
                  child: Text('cancel-text'.i18n()),
                ),
              ],
            )
          else
            Button(
              key: const ValueKey('test-sandbox-add'),
              onPressed: _addSandbox,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(FluentIcons.add, size: 12),
                const SizedBox(width: 6),
                Text('sandbox-add-text'.i18n()),
              ]),
            ),
        ],
      ),
    );
  }

  Future<void> _refreshSandboxes() async {
    if (mounted) setState(() => _sandboxes = _sandbox.list());
  }

  /// "Creating the sandbox distro… (downloading 42%)".
  String _sandboxStatusLabel() {
    final stage = SandboxService.creationStage.value;
    var stageLabel = 'sandbox-stage-$stage-text'.i18n();
    final progress = SandboxService.creationProgress.value;
    if (stage == 'downloading' && progress != null) {
      stageLabel = '$stageLabel ${(progress * 100).round()}%';
    }
    return '${'sandbox-creating-text'.i18n()} ($stageLabel)';
  }

  Future<void> _addSandbox() async {
    final controller = TextEditingController();
    String? image; // null = newest Ubuntu, the labelled default.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => ContentDialog(
          title: Text('sandbox-add-text'.i18n()),
          // mainAxisSize.min: a bare TextBox handed the dialog's tall
          // constraints stretched to the full dialog height (user-reported).
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextBox(
                key: const ValueKey('test-sandbox-name'),
                controller: controller,
                placeholder: 'sandbox-name-hint-text'.i18n(),
                autofocus: true,
                onSubmitted: (v) => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 12),
              // Any catalog image, not just Ubuntu — the plumbing has always
              // taken an arbitrary image. Which catalog that is comes from
              // the backend: rootfs tarballs on WSL, cloud images on macOS.
              FutureBuilder<List<String>>(
                future: _sandbox.imageChoices(),
                builder: (context, snapshot) {
                  final keys = snapshot.data ?? const <String>[];
                  return DropDownButton(
                    key: const ValueKey('test-sandbox-image'),
                    // Cloud-image names run long ("Ubuntu 26.04 LTS (cloud
                    // image)"); the dialog is narrower than they are.
                    title: Text(image ?? 'sandbox-image-default-text'.i18n(),
                        overflow: TextOverflow.ellipsis),
                    items: [
                      MenuFlyoutItem(
                        selected: image == null,
                        leading: image == null
                            ? const Icon(FluentIcons.check_mark, size: 12.0)
                            : const SizedBox.square(dimension: 12.0),
                        text: Text('sandbox-image-default-text'.i18n()),
                        onPressed: () => setDialogState(() => image = null),
                      ),
                      if (keys.isNotEmpty) const MenuFlyoutSeparator(),
                      for (final key in keys)
                        MenuFlyoutItem(
                          selected: image == key,
                          leading: image == key
                              ? const Icon(FluentIcons.check_mark, size: 12.0)
                              : const SizedBox.square(dimension: 12.0),
                          text: Text(key, overflow: TextOverflow.ellipsis),
                          onPressed: () => setDialogState(() => image = key),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
          actions: [
            Button(
              child: Text('cancel-text'.i18n()),
              onPressed: () => Navigator.of(context).pop(),
            ),
            FilledButton(
              child: Text('create-text'.i18n()),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );
    final name = controller.text;
    if (confirmed != true || name.trim().isEmpty) return;
    // Fire and forget: the download takes minutes and must not be tied to
    // this page's lifetime — the global stage notifier carries progress and
    // the toasts land wherever the user is when it finishes.
    _sandbox.createUbuntuSandbox(name, image: image).then((_) {
      Notify.message('sandbox-created-text'.i18n(),
          severity: InfoBarSeverity.success);
      _refreshSandboxes();
    }).catchError((e) {
      if (e is CancelledException) {
        Notify.message('createcancelled-text'.i18n(),
            severity: InfoBarSeverity.warning);
      } else if (e.toString().contains('sandbox-disk-space')) {
        Notify.message('sandbox-disk-space-text'.i18n(),
            severity: InfoBarSeverity.error);
      } else {
        Notify.message(
            '${'sandbox-create-failed-text'.i18n()} ${WslFailure.from(e).shortReason}'
                .trim(),
            severity: InfoBarSeverity.error);
      }
      _refreshSandboxes();
    });
  }

  void _onSandboxStage() {
    if (mounted) setState(() => _sandboxes = _sandbox.list());
  }

  Future<void> _deleteSandbox(String distro) async {
    // A dock pointed at a distro that no longer exists would be a dead
    // transcript; hand it back to the assistant first.
    if (GlobalVariable.sandboxChat.value == distro) {
      GlobalVariable.sandboxChat.value = null;
    }
    try {
      await _sandbox.deleteSandbox(distro);
    } catch (_) {}
    await _refreshSandboxes();
  }

  /// Spinner plus a grey label saying what is being waited on.
  ///
  /// [fill] takes the full width and ellipsises the label instead of sizing
  /// to it — installer output is arbitrarily long and would otherwise
  /// overflow the card. The default stays min-sized for the header, where
  /// this sits next to a [Spacer].
  Widget _buildInlineStatus(String label, {bool fill = false}) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: secondaryTextColor(context)),
    );
    return Row(
      mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
      children: [
        const SizedBox.square(
          dimension: 12,
          child: ProgressRing(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        if (fill) Expanded(child: text) else text,
      ],
    );
  }

  Widget _buildToolCard(AiWorkspaceTool tool) {
    final state = _service.getState(tool);
    // Through [_toolName], not a second table of its own: the card and the
    // uninstall dialog have to agree on what the tool is called, and two
    // hand-maintained lists of the same four names only agree by luck.
    final name = _toolName(tool);

    final isChecking = _checkingTools.contains(tool);
    // The service, not this page, owns install progress: the page is rebuilt
    // from scratch when the user navigates away and back, but the install
    // keeps running.
    final isInstalling = _service.isInstalling(tool);
    // For the whole of a six-minute install the pill read "Not Installed" and
    // the dot stayed grey, directly above a live spinner (audit PS-19): the
    // one element whose job is to say what state the tool is in said the
    // wrong thing for the entire operation.
    final statusColors =
        _statusColors(state?.status, installing: isInstalling);
    final isBusy = _busyTools.contains(tool) || isInstalling;
    // `error` means the last attempt failed, not that the tool is present —
    // a retry has to stay reachable.
    final canInstall = state?.status == ToolStatus.notInstalled ||
        state?.status == ToolStatus.error;
    // The service keeps the last streamed line after the install ends. A
    // failure is the case that needs it — the error text is whatever the
    // killed shell managed to write, which for a timeout is nothing at all.
    final lastOutput = state?.status == ToolStatus.error
        ? _service.installProgress(tool)
        : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: statusColors.dot,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(name, style: FluentTheme.of(context).typography.subtitle),
                const Spacer(),
                isChecking
                    ? _buildInlineStatus(
                        'ai-workspace-checking-status-text'.i18n())
                    : isInstalling
                        ? _badge(
                            'installing-text'.i18n(),
                            statusColors,
                            key: ValueKey('test-ai-installing-badge-'
                                '${tool.name}'),
                          )
                        : _statusBadge(state?.status),
              ],
            ),
            if (state?.installPath != null) ...[
              const SizedBox(height: 4),
              // Keyed, and the internal existence-check sentinels stay
              // internal — "Installed: cmd://openclaw" leaked an
              // implementation detail as a path, and `docker://` was the
              // same leak for container-backed tools (audit PS-26).
              Text(
                'ai-workspace-installed-at-text'.i18n([
                  state!.installPath!.contains('://')
                      ? state.installPath!
                          .substring(state.installPath!.indexOf('://') + 3)
                      : state.installPath!
                ]),
                style: FluentTheme.of(context).typography.bodyStrong,
              ),
            ],
            if (state?.errorMessage != null) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      WslFailure.from(state!.errorMessage).shortReason,
                      style: TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                  // Without this a sticky failure has no way out: the status
                  // probe deliberately leaves it alone until the user acts.
                  NamedIconButton(
                    key: ValueKey('test-ai-dismiss-error-${tool.name}'),
                    label: 'close-text'.i18n(),
                    icon: FluentIcons.cancel,
                    iconSize: 10,
                    onPressed: () => _handleDismissError(tool),
                  ),
                ],
              ),
            ],
            // Streamed installer output. A Hermes install runs for minutes at
            // a time, and without this the card is a bare spinner: a stall
            // and steady progress look exactly alike.
            if (_service.isInstalling(tool)) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: ValueKey('test-ai-install-progress-${tool.name}'),
                      child: _buildInlineStatus(
                        _service.installProgress(tool) ??
                            'ai-workspace-install-progress-text'.i18n(),
                        fill: true,
                      ),
                    ),
                  ),
                  // The clock is the point: the streamed line above it sat
                  // unchanged for two minutes of a six-minute install, and a
                  // still line next to a moving one is a stall, while a still
                  // line on its own is unreadable (audit PS-18).
                  const SizedBox(width: 8),
                  Text(
                    formatElapsed(_service.installElapsed(tool) ?? Duration.zero),
                    key: ValueKey('test-ai-install-elapsed-${tool.name}'),
                    style: TextStyle(
                        fontSize: 12, color: secondaryTextColor(context)),
                  ),
                  const SizedBox(width: 8),
                  NamedIconButton(
                    key: ValueKey('test-ai-install-cancel-${tool.name}'),
                    label: 'stopinstall-text'.i18n(),
                    icon: FluentIcons.stop,
                    iconSize: 12,
                    onPressed: _service.canCancelInstall(tool)
                        ? () => _service.cancelInstall(tool)
                        : null,
                  ),
                ],
              ),
            ] else if (lastOutput != null) ...[
              const SizedBox(height: 4),
              Text(
                'ai-workspace-install-last-output-text'.i18n([lastOutput]),
                key: ValueKey('test-ai-install-last-output-${tool.name}'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 12, color: secondaryTextColor(context)),
              ),
            ],
            const SizedBox(height: 12),
            // One primary action per state, and only the actions that state
            // can ever run. The old row kept Install, Start and Stop all
            // visible with every non-applicable one disabled, so an installed
            // tool wore a permanently dead "Installed" button repeating the
            // badge beside it (audit PS-22), a running tool's only filled
            // button was Stop (PS-23), and each disabled `FilledButton`
            // painted white on grey at 1.71:1 (PS-21) — plain `Button`s keep
            // their disabled foreground legible.
            //
            // The state actions sit in a `Wrap`, not straight in the row: a
            // running OpenCode card carries Open Dashboard, Stop, Configure
            // and Uninstall, and with the assistant panel open the card is
            // narrow enough that a plain row pushed Uninstall 68 px past the
            // edge (issue #82 screenshot, German labels). Uninstall stays
            // pinned to the right; the others wrap onto a second line.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (canInstall)
                        _buildAction(
                          key: ValueKey('test-ai-install-${tool.name}'),
                          // A failed install leaves the tool in `error`,
                          // which is not "installed" — a retry has to stay
                          // reachable.
                          label: state?.status == ToolStatus.error
                              ? 'retry-text'.i18n()
                              : 'install-text'.i18n(),
                          enabled: !isBusy && !isChecking,
                          busy: _busyAction[tool] == _CardAction.install,
                          onPressed: () => _handleInstall(tool),
                        ),
                      if (state?.status == ToolStatus.stopped)
                        _buildAction(
                          key: ValueKey('test-ai-start-${tool.name}'),
                          label: 'start-text'.i18n(),
                          enabled: !isBusy && !isChecking,
                          busy: _busyAction[tool] == _CardAction.start,
                          onPressed: () => _handleStart(tool),
                        ),
                      if (state?.status == ToolStatus.running ||
                          state?.status == ToolStatus.starting) ...[
                        // The thing to do with a running AI tool is to open
                        // it — Open Dashboard is the primary, not Stop
                        // (PS-23). Shown but disabled while starting: hiding
                        // it entirely reads as "this tool has no dashboard"
                        // rather than "not yet".
                        _maybeTooltip(
                          state?.status == ToolStatus.starting
                              ? 'ai-workspace-startingup-hint-text'.i18n()
                              : null,
                          BusyButton(
                            key: ValueKey(
                                'test-ai-open-dashboard-${tool.name}'),
                            filled: true,
                            label: 'ai-workspace-open-dashboard-text'.i18n(),
                            busy: _busyAction[tool] == _CardAction.dashboard,
                            minWidth: 72.0,
                            onPressed:
                                (!isBusy && state?.status == ToolStatus.running)
                                    ? () => _handleOpenDashboard(tool)
                                    : null,
                          ),
                        ),
                        // Live while starting too: a tool stuck mid-migration
                        // used to leave Uninstall as the only enabled way out
                        // (PS-16).
                        BusyButton(
                          key: ValueKey('test-ai-stop-${tool.name}'),
                          label: 'stop-text'.i18n(),
                          busy: _busyAction[tool] == _CardAction.stop,
                          minWidth: 72.0,
                          onPressed: (!isBusy &&
                                  (state?.status == ToolStatus.running ||
                                      state?.status == ToolStatus.starting))
                              ? () => _handleStop(tool)
                              : null,
                        ),
                      ],
                      // Only once something is installed: a tool that is not
                      // there has no configuration to read, and its schema is
                      // the one thing this dialog cannot infer from nothing.
                      if (state?.status != ToolStatus.notInstalled &&
                          state?.status != ToolStatus.error &&
                          _configService.canConfigure(tool))
                        BusyButton(
                          key: ValueKey('test-ai-configure-${tool.name}'),
                          label: 'ai-workspace-configure-text'.i18n(),
                          busy: _busyAction[tool] == _CardAction.configure,
                          minWidth: 72.0,
                          onPressed: (!isBusy && !isChecking)
                              ? () => _handleConfigure(tool)
                              : null,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                BusyButton(
                  key: ValueKey('test-ai-uninstall-${tool.name}'),
                  label: 'uninstall-text'.i18n(),
                  busy: _busyAction[tool] == _CardAction.uninstall,
                  minWidth: 72.0,
                  onPressed: (state?.status != ToolStatus.notInstalled &&
                          !isBusy &&
                          !isChecking)
                      ? () => _handleUninstall(tool)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAction({
    required Key key,
    required String label,
    required bool enabled,
    required bool busy,
    required VoidCallback onPressed,
  }) {
    // Same reason as the create screen's Create button: a button that becomes
    // a bare spinner loses both its width and its name (audit CI-15).
    return BusyButton(
      key: key,
      filled: true,
      label: label,
      busy: busy,
      minWidth: 72.0,
      onPressed: enabled ? onPressed : null,
    );
  }

  Widget _statusBadge(ToolStatus? status) =>
      _badge(_statusLabel(status), _statusColors(status));

  /// The pill itself. Taken out of [_statusBadge] because an install is not a
  /// [ToolStatus] — it is a transition between two of them — and it still has
  /// to be able to say so (audit PS-19).
  Widget _badge(String label, _StatusColors colors, {Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.tint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: colors.foreground,
        ),
      ),
    );
  }

  /// The palette a status renders with, per theme brightness.
  ///
  /// The old single-colour version painted `Colors.orange` on 10% of itself —
  /// 2.70:1 in light, and the `Colors.grey` fallback was **1.03:1** against a
  /// dark card, an invisible pill (audit TL-01, TL-04, PS-20). Each
  /// brightness now gets a text shade measured against its own tint; every
  /// pair below clears AA's 4.5:1 on both page colours. `notInstalled` uses
  /// the theme's own secondary text instead of a status colour, so the state
  /// that means "nothing here" stops being the most assertive of the four
  /// (PS-24).
  _StatusColors _statusColors(ToolStatus? status, {bool installing = false}) {
    final dark = FluentTheme.of(context).brightness.isDark;
    _StatusColors of(AccentColor base, Color darkFg) => _StatusColors(
          foreground: dark ? darkFg : base.darkest,
          tint: base.normal.withValues(alpha: 0.15),
          dot: base.defaultBrushFor(
              dark ? Brightness.dark : Brightness.light),
        );
    if (installing || status == ToolStatus.starting) {
      return of(Colors.blue, Colors.blue.lightest);
    }
    switch (status) {
      case ToolStatus.running:
        return of(Colors.green, const Color(0xFF8FC48F));
      case ToolStatus.stopped:
        return of(Colors.orange, Colors.orange.lightest);
      case ToolStatus.error:
        return of(Colors.red, const Color(0xFFF4949C));
      default:
        return _StatusColors(
          foreground: secondaryTextColor(context),
          tint: subtleFillColor(context),
          dot: disabledTextColor(context),
        );
    }
  }

  /// A tooltip only where it says something the label does not (audit
  /// PS-30). A null [message] leaves [child] bare.
  Widget _maybeTooltip(String? message, Widget child) =>
      message == null ? child : Tooltip(message: message, child: child);

  String _statusLabel(ToolStatus? status) {
    if (status == ToolStatus.running) return 'running-text'.i18n();
    if (status == ToolStatus.starting) return 'startingup-text'.i18n();
    if (status == ToolStatus.stopped) return 'stopped-text'.i18n();
    if (status == ToolStatus.error) return 'error-text'.i18n();
    return 'notinstalled-text'.i18n();
  }
}

/// The colours one status pill needs: an AA-checked text colour for the
/// current brightness, the tint behind it, and the dot beside the tool name.
class _StatusColors {
  const _StatusColors(
      {required this.foreground, required this.tint, required this.dot});
  final Color foreground;
  final Color tint;
  final Color dot;
}
