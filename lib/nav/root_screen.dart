import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localization/localization.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/app_window.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/sandbox_service.dart';
import 'package:wsl2distromanager/components/ai_chat_dock.dart';
import 'package:wsl2distromanager/components/ai_chat_panel.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';
import 'package:wsl2distromanager/dialogs/bug_dialog.dart';
import 'package:wsl2distromanager/main.dart';
import 'package:wsl2distromanager/nav/init.dart';
import 'package:wsl2distromanager/nav/panelist.dart';
import 'package:wsl2distromanager/nav/router.dart';
import 'package:wsl2distromanager/nav/shell_focus.dart';
import 'package:wsl2distromanager/theme.dart';

class RootPage extends StatefulWidget {
  const RootPage({
    Key? key,
    required this.child,
    required this.shellContext,
    required this.state,
  }) : super(key: key);

  final Widget child;
  final BuildContext? shellContext;
  final GoRouterState state;

  @override
  State<RootPage> createState() => RootPageState();
}

class RootPageState extends State<RootPage> with WindowListener {
  bool value = false;

  dynamic runner(dynamic func) {
    return func;
  }

  final viewKey = GlobalKey(debugLabel: 'Navigation View Key');
  final searchKey = GlobalKey(debugLabel: 'Search Bar Key');
  final searchFocusNode = FocusNode();
  final searchController = TextEditingController();

  /// Everything the shell draws — pane, app bar and page — lives in this
  /// scope, so parking focus on it is enough to make Tab work (audit IA-01).
  final shellFocusScope = FocusScopeNode(debugLabel: 'Shell Focus Scope');
  final shellTraversalPolicy = ShellTraversalPolicy();

  /// What the chat dock rebuilds on. App-lifetime globals, merged once: the
  /// shell rebuilds on every status message, and a merge made inside the
  /// builder re-subscribed to all three each time.
  late final Listenable _dockListenable = Listenable.merge([
    GlobalVariable.aiPanel,
    GlobalVariable.sandboxChat,
    AiService.featuresChanged,
  ]);

  String status = '';
  bool loading = false;
  bool statusLeading = true;
  InfoBarSeverity statusSeverity = InfoBarSeverity.info;
  Widget statusWidget = const Text('');
  Timer? _messageTimer;
  DateTime? _statusPostedAt;

  void statusMsg(
    String msg, {
    Duration? duration,
    InfoBarSeverity severity = InfoBarSeverity.info,
    bool loading = false,
    bool useWidget = false,
    bool leadingIcon = true,
    Widget widget = const Text(''),
  }) {
    if (!mounted) return;

    _messageTimer?.cancel();
    _statusPostedAt = DateTime.now();

    setState(() {
      status = useWidget ? 'WIDGET' : msg;
      this.loading = loading;
      statusLeading = leadingIcon;
      statusSeverity = severity;
      if (useWidget) statusWidget = widget;
    });

    // A message with a spinner lives until the operation that owns it replaces
    // it. Everything else expires, so a "Created instance" toast does not
    // follow the user to another screen for the rest of the session.
    final lifetime = duration ?? (loading ? null : notifyDefaultDuration);
    if (lifetime != null) {
      _messageTimer = Timer(lifetime, clearStatus);
    }
  }

  void clearStatus() {
    _messageTimer?.cancel();
    _statusPostedAt = null;
    if (!mounted) return;
    if (status.isEmpty && !loading) return;
    setState(() {
      status = '';
      loading = false;
      statusSeverity = InfoBarSeverity.info;
    });
  }

  @override
  void initState() {
    windowManager.addListener(this);
    // The footer pane item reads the licence state, so it has to rebuild when
    // that changes.
    LicenseManager().addListener(_onLicenseChanged);
    // So does the AI Workspace entry when AI is switched off in Settings.
    AiService.featuresChanged.addListener(_onLicenseChanged);
    // And the experimental destinations when one is switched on or off.
    ExperimentalFeatures.generation.addListener(_onLicenseChanged);
    initRoot(statusMsg);
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => adoptKeyboardFocus());
  }

  /// A cold launch — and every return from another window — left the primary
  /// focus on the root scope (audit IA-01). Handing focus to the shell scope
  /// puts traversal back at the top of the cycle.
  void adoptKeyboardFocus() {
    if (!mounted || !shouldAdoptKeyboardFocus()) return;
    shellFocusScope.requestFocus();
  }

  @override
  void didUpdateWidget(covariant RootPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.uri.path == widget.state.uri.path) return;
    // Leaving a screen drops the message that screen put up. The grace window
    // is what keeps a message posted *by* the navigation itself — "Created
    // instance", posted just before the create page returns home — on screen.
    final posted = _statusPostedAt;
    if (posted != null &&
        DateTime.now().difference(posted) < const Duration(seconds: 2)) {
      return;
    }
    if (loading) return;
    clearStatus();
  }

  void _onLicenseChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    windowManager.removeListener(this);
    LicenseManager().removeListener(_onLicenseChanged);
    AiService.featuresChanged.removeListener(_onLicenseChanged);
    ExperimentalFeatures.generation.removeListener(_onLicenseChanged);
    searchController.dispose();
    searchFocusNode.dispose();
    shellFocusScope.dispose();
    super.dispose();
  }

  /// fluent_ui addresses the pane by its "effective" items — separators and
  /// headers are dropped from the numbering — so a raw list index does not
  /// line up with what the pane considers selected.
  int _calculateSelectedIndex(BuildContext context) {
    final path = widget.state.uri.path;
    final effective = [...originalItems, ...footerItems]
        .whereType<PaneItem>()
        .where((item) => item is! PaneItemAction)
        .toList();
    final index = effective.indexWhere((item) => item.key == Key(path));
    return index == -1 ? 0 : index;
  }

  @override
  Widget build(BuildContext context) {
    final localizations = FluentLocalizations.of(context);
    final appTheme = context.watch<AppTheme>();

    final navigationView = NavigationView(
      key: viewKey,
      appBar: NavigationAppBar(
        height: shellAppBarHeight,
        automaticallyImplyLeading: false,
        // Every pane destination is a `go()` on the shell route, so on most
        // screens there is nothing to pop. A permanently disabled arrow was
        // still a tab stop on every screen and still rendered near-white —
        // enabled-looking — in dark (audit IA-03, LN-13), so it is only built
        // when it can actually do something.
        leading: () {
          // With the native macOS title bar hidden (main.dart), the traffic
          // lights float over the app bar's left edge; everything the bar
          // puts there has to start to their right.
          const macTrafficLightInset = 70.0;
          final needsMacInset = !kIsWeb && Platform.isMacOS;
          if (widget.shellContext == null || !router.canPop()) {
            return needsMacInset
                ? const SizedBox(width: macTrafficLightInset)
                : null;
          }

          final Widget back = Builder(
            builder: (context) => PaneItem(
              icon: const Center(child: Icon(FluentIcons.back, size: 12.0)),
              title: Text(localizations.backButtonTooltip),
              body: const SizedBox.shrink(),
            ).build(
              context,
              false,
              () async {
                // Back is an exit route like any other, so it asks the screen
                // it is leaving first (audit ST-01).
                if (!await UnsavedChangesGuard.confirmLeave()) return;
                if (!mounted) return;
                if (router.canPop()) {
                  router.pop();
                  setState(() {});
                }
              },
              displayMode: PaneDisplayMode.compact,
            ),
          );
          if (needsMacInset) {
            return Padding(
              padding:
                  const EdgeInsetsDirectional.only(start: macTrafficLightInset),
              child: back,
            );
          }
          return back;
        }(),
        title: () {
          if (kIsWeb) {
            return Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(appTitle),
            );
          }
          return DragToMoveArea(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(appTitle),
            ),
          );
        }(),
        // Not on macOS: the native title bar already has its own window
        // controls there, and WindowCaption queries the window plugin at
        // build time, which asserts when nothing initialised it (tests).
        actions: ShellAppBarActions(
          windowButtons: !kIsWeb && !Platform.isMacOS,
        ),
      ),
      paneBodyBuilder: (item, child) {
        final name =
            item?.key is ValueKey ? (item!.key as ValueKey).value : null;
        // A column rather than a stack: overlaid at the bottom, the status bar
        // covered the Create / Cancel row outright on a short window, and the
        // user had no way to move it.
        // The page plus its status/notification bar. On a short window the
        // bar used to overlay the page bottom; as a column child it takes its
        // own row instead.
        final statusBar = statusBuilder(
          status,
          statusWidget,
          loading,
          statusLeading,
          statusSeverity,
          clearStatus,
        );
        final pageWithStatus = Column(
          children: [
            Expanded(child: widget.child),
            statusBar,
          ],
        );

        // The AI chat is docked here, at the shell, rather than inside the
        // home page — so the status bar above sits to the *left* of the dock
        // instead of sliding underneath it and colliding with the panel's own
        // input and the chat button (the design the user flagged). On every
        // page, not just home: a sandbox chat is opened from the AI Workspace
        // page and stays put while the user moves around — a dock the user
        // can keep "in the background", unlike the modal it replaces.
        final body = ListenableBuilder(
          listenable: _dockListenable,
          builder: (context, _) {
            if (!GlobalVariable.aiPanel.value || !AiService.featuresEnabled) {
              return pageWithStatus;
            }
            var sandbox = GlobalVariable.sandboxChat.value;
            // A sandbox deleted while docked (any path — the button, the MCP
            // tool) must not leave a dead transcript on screen.
            if (sandbox != null && !SandboxService().isSandbox(sandbox)) {
              sandbox = null;
              WidgetsBinding.instance.addPostFrameCallback(
                  (_) => GlobalVariable.sandboxChat.value = null);
            }
            // The dock owns the split: its width is draggable and
            // remembered, and expanding it gives the chat the whole page
            // area while the navigation pane stays put (ai-tasks#104).
            final docked = sandbox;
            return AiChatDock(
              page: widget.child,
              statusBar: statusBar,
              panelBuilder: (context, expanded, toggleExpanded) =>
                  // Keyed: switching between the assistant and a sandbox
                  // session swaps the panel state instead of mixing them.
                  AiChatPanel(
                key: ValueKey('chat-${docked ?? 'main'}'),
                sandbox: docked == null ? null : SandboxChat.of(docked),
                onClose: () => GlobalVariable.aiPanel.value = false,
                expanded: expanded,
                onToggleExpanded: toggleExpanded,
              ),
            );
          },
        );

        return ShellBodyScope(
          child: FocusTraversalGroup(
            key: ValueKey('body$name'),
            child: body,
          ),
        );
      },
      pane: NavigationPane(
        size: const NavigationPaneSize(openWidth: 220),
        selected: _calculateSelectedIndex(context),
        displayMode: appTheme.displayMode,
        indicator: () {
          switch (appTheme.indicator) {
            case NavigationIndicators.end:
              return const EndNavigationIndicator();
            case NavigationIndicators.sticky:
            default:
              return const StickyNavigationIndicator();
          }
        }(),
        items: originalItems,
        footerItems: footerItems,
      ),
      onOpenSearch: () => searchFocusNode.requestFocus(),
    );

    // The group has to be above the scope: the sort walks up from the scope
    // node to find the policy that owns it.
    return FocusTraversalGroup(
      policy: shellTraversalPolicy,
      child: FocusScope(node: shellFocusScope, child: navigationView),
    );
  }

  @override
  void onWindowFocus() {
    // Alt-tabbing away and back dropped focus to the root scope, and no key
    // could get it out again (audit IA-01).
    WidgetsBinding.instance.addPostFrameCallback((_) => adoptKeyboardFocus());
  }

  @override
  void onWindowResized() => _saveWindowBounds();

  @override
  void onWindowMoved() => _saveWindowBounds();

  @override
  void onWindowMaximize() => prefs.setBool('WindowMaximized', true);

  @override
  void onWindowUnmaximize() => prefs.setBool('WindowMaximized', false);

  /// Persist the current geometry so the next start reopens where the user
  /// left off. Skipped while maximized, otherwise the restored-down size would
  /// be lost.
  Future<void> _saveWindowBounds() async {
    if (await appWindow.isMaximized()) return;
    final size = await appWindow.getSize();
    final position = await appWindow.getPosition();
    await prefs.setDouble('WindowWidth', size.width);
    await prefs.setDouble('WindowHeight', size.height);
    await prefs.setDouble('WindowLeft', position.dx);
    await prefs.setDouble('WindowTop', position.dy);
  }

  @override
  void onWindowClose() async {
    // `setPreventClose(true)` in main() is what gives a dirty screen the
    // chance to answer here rather than losing the edits to the X (ST-01).
    if (!await UnsavedChangesGuard.confirmLeave()) return;
    await _saveWindowBounds();
    SystemNavigator.pop();
    exit(0);
  }
}

/// fluent_ui's default app bar height, spelled out so the actions row can be
/// sized to it (see [ShellAppBarActions]).
const double shellAppBarHeight = 50.0;

/// The bug report button and the dark mode switch at the app bar's end,
/// followed by the caption buttons where the app draws its own.
///
/// fluent_ui aligns the actions widget to the *top* end corner of the bar,
/// not the centre. On Windows the 50px [WindowButtons] stretched the row to
/// the bar's full height and the row centred the switch in it; on macOS and
/// the web nothing did, so the row was as tall as the switch and sat hard
/// against the top edge, 8px from the window corner (ai-tasks#15). The row
/// is sized to the bar explicitly, and the switch keeps a real margin to the
/// window edge when no caption buttons follow it.
class ShellAppBarActions extends StatelessWidget {
  const ShellAppBarActions({super.key, required this.windowButtons});

  /// Whether the app draws its own minimise/maximise/close buttons after the
  /// switch. False on macOS (the native traffic lights sit at the *start* of
  /// the bar) and on the web.
  final bool windowButtons;

  /// The margin between the switch and whatever ends the bar: the caption
  /// buttons, or the window edge itself.
  static const double innerEndInset = 8.0;
  static const double windowEdgeInset = 16.0;

  @override
  Widget build(BuildContext context) {
    final appTheme = context.watch<AppTheme>();
    return SizedBox(
      height: shellAppBarHeight,
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Padding(
            padding: const EdgeInsetsDirectional.only(end: innerEndInset),
            child: MergeSemantics(
              child: Tooltip(
                message: 'reportbug-text'.i18n(),
                child: IconButton(
                  icon: const Icon(FluentIcons.bug),
                  onPressed: () => bugDialog(),
                ),
              ),
            )),
        Padding(
          padding: EdgeInsetsDirectional.only(
              end: windowButtons ? innerEndInset : windowEdgeInset),
          child: ToggleSwitch(
            // Was the one hardcoded-English label in the nav (audit LN-14).
            content: Text('darkmode-text'.i18n()),
            checked: FluentTheme.of(context).brightness.isDark,
            onChanged: (v) {
              appTheme.mode = v ? ThemeMode.dark : ThemeMode.light;
            },
          ),
        ),
        if (windowButtons) const WindowButtons(),
      ]),
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final FluentThemeData theme = FluentTheme.of(context);

    return SizedBox(
      width: 138,
      height: 50,
      child: WindowCaption(
        brightness: theme.brightness,
        backgroundColor: Colors.transparent,
      ),
    );
  }
}
