import 'dart:async';

import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/dialogs/snippet_env_dialog.dart';
import 'package:wsl2distromanager/api/templates.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/vm_resize.dart';
import 'package:wsl2distromanager/api/volume_mounts.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/ai_diagnosis.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'analytics.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/dialogs/dialogs.dart';
import 'package:wsl2distromanager/dialogs/file_transfer_dialog.dart';
import 'package:wsl2distromanager/dialogs/guest_access_dialog.dart';
import 'package:wsl2distromanager/dialogs/vm_credentials_dialog.dart';
import 'package:wsl2distromanager/dialogs/vm_resize_dialog.dart';
import 'package:wsl2distromanager/dialogs/vm_resources_dialog.dart';
import 'package:wsl2distromanager/dialogs/volume_mounts_dialog.dart';

/// Builder for the WSL Distro List Items. Each item is an expander with [item]
/// as the title and [trailing] as the trailing text. [running] is a list of
/// running distros.
///
/// The action buttons are wrapped in MergeSemantics: fluent_ui's Tooltip puts
/// its message on a Semantics node above the button, while IconButton opens a
/// semantics container of its own, so without the merge a screen reader reads
/// every action as an unlabelled "button".
class ListItem extends StatefulWidget {
  const ListItem(
      {super.key,
      required this.item,
      required this.running,
      required this.trailing});
  final List<String> running;
  final String item;
  final String trailing;
  @override
  State<ListItem> createState() => _ListItemState();
}

class _ListItemState extends State<ListItem> {
  final VmBackend api = vmBackend();
  Map<String, bool> hover = {};
  bool isSyncing = false;
  bool isCleaning = false;
  bool showBar = false;
  bool hovered = false;

  /// Start and stop are slow enough to be tapped twice. While one is in flight
  /// both controls report it instead of silently queueing a second `wsl.exe`.
  /// Which row action is in flight, or null. Only that action's button
  /// shows a spinner; the others merely disable — one press must not turn
  /// the whole strip into progress rings.
  String? busyAction;
  bool get isBusy => busyAction != null;

  /// The Expander's header is one big HoverButton, and its focus ring is drawn
  /// around the chevron alone — 1,100px from the name it belongs to (IA-05) —
  /// while any focused child of the header lights it a second time (IA-06).
  /// Tracking the three regions separately is what tells "the row is the tab
  /// stop" apart from "a control inside the row is".
  bool rowFocused = false;
  bool leadingFocused = false;
  bool contentFocused = false;

  bool get headerFocused => rowFocused && !leadingFocused && !contentFocused;

  /// Focus for the selectable size/IP label. Selecting text needs focus so
  /// Ctrl/Cmd+C can find it, but the label must not become a Tab stop of its
  /// own — the row and its buttons are the keyboard surface.
  final FocusNode _metaFocus =
      FocusNode(skipTraversal: true, debugLabel: 'row-meta');

  @override
  void dispose() {
    _metaFocus.dispose();
    super.dispose();
  }

  void syncing(var item) {
    setState(() {
      isSyncing = item;
    });
  }

  bool isRunning(String distroName, List<String> runningList) =>
      runningList.contains(distroName);

  /// What the row calls itself. LN-01 cuts this at half the row width, so
  /// the same string is also the header's tooltip (audit LN-23).
  String headerLabel() => isRunning(widget.item, widget.running)
      ? '${distroLabel(widget.item)} (${'running-text'.i18n()})'
      : distroLabel(widget.item);

  /// Watches a region of the row for focus without becoming a tab stop itself.
  Widget watchFocus(Widget child, ValueChanged<bool> onChanged) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (mounted) setState(() => onChanged(focused));
        },
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, left: 12.0, right: 12.0),
      child: watchFocus(
        // The ring the header would have drawn round its chevron is switched
        // off and redrawn around the whole row; the buttons inside restore the
        // theme's ring by merging an empty override over the suppression.
        // Hover lights the same whole-row ring — the Expander's own hover
        // effect reached only the chevron, 660px from the cursor (LN-09).
        MouseRegion(
          onEnter: (_) => setState(() => hovered = true),
          onExit: (_) => setState(() => hovered = false),
          child: FocusBorder(
            focused: headerFocused || hovered,
            child: FocusTheme(
              data: const FocusThemeData(
                primaryBorder: BorderSide.none,
                secondaryBorder: BorderSide.none,
              ),
              child: buildRow(context),
            ),
          ),
        ),
        (focused) => rowFocused = focused,
      ),
    );
  }

  Widget buildRow(BuildContext context) {
    return Expander(
          initiallyExpanded: false,
          leading: watchFocus(
              FocusTheme(
                  data: const FocusThemeData(),
                  child: Row(children: [
            // On a running distro the first button opens another terminal —
            // its tooltip saying "Start" over an already-running instance
            // promised the wrong thing (audit LN-26).
            MergeSemantics(
              child: Tooltip(
                message: isRunning(widget.item, widget.running)
                    ? 'openterminal-text'.i18n()
                    : 'start-text'.i18n(),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: IconButton(
                    key: const ValueKey('test-listitem-start'),
                    icon: busyAction == 'start' ||
                            (busyAction == 'console' &&
                                isRunning(widget.item, widget.running))
                        ? const SizedBox.square(
                            dimension: 16.0,
                            child: ProgressRing(strokeWidth: 2.0))
                        : Icon(
                            isRunning(widget.item, widget.running)
                                ? FluentIcons.command_prompt
                                : FluentIcons.play,
                            size: 16.0),
                    onPressed: isBusy
                        ? null
                        : () {
                            // On the Apple backend the promise this button
                            // makes while running — "open terminal" — is the
                            // serial console; start (with the VM's display)
                            // is only for bringing a stopped VM up.
                            if (api.features.serialConsole &&
                                isRunning(widget.item, widget.running)) {
                              openTerminal();
                            } else {
                              startInstance();
                            }
                          },
                  ),
                ),
              ),
            ),
            // Kept in the tree while the distro is stopped — its footprint
            // is maintained invisibly, so the name does not jump ~30px
            // sideways every time a distro starts or stops (audit LN-02).
            // Hidden means disabled, so no invisible tab stop comes back.
            // Third slot, one concept per state: a stopped VM boots straight
            // into a Terminal serial console (no display window at any
            // point); a running VM summons its screen — the first button is
            // already the terminal then.
            if (api.features.serialConsole)
              MergeSemantics(
                child: Tooltip(
                  message: isRunning(widget.item, widget.running)
                      ? 'vmshowdisplay-text'.i18n()
                      : 'vmopenconsole-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      key: ValueKey(isRunning(widget.item, widget.running)
                          ? 'test-listitem-screen'
                          : 'test-listitem-console'),
                      icon: busyAction == 'console' &&
                              !isRunning(widget.item, widget.running)
                          ? const SizedBox.square(
                              dimension: 16.0,
                              child: ProgressRing(strokeWidth: 2.0))
                          : Icon(
                              isRunning(widget.item, widget.running)
                                  ? FluentIcons.t_v_monitor
                                  : FluentIcons.command_prompt,
                              size: 16.0),
                      onPressed: isBusy
                          ? null
                          : () {
                              if (isRunning(widget.item, widget.running)) {
                                showDisplay();
                              } else {
                                openConsole();
                              }
                            },
                    ),
                  ),
                ),
              ),
            Visibility(
              visible: isRunning(widget.item, widget.running),
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: MergeSemantics(
                child: Tooltip(
                  message: 'stop-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      key: const ValueKey('test-listitem-stop'),
                      icon: busyAction == 'stop'
                          ? const SizedBox.square(
                              dimension: 16.0,
                              child: ProgressRing(strokeWidth: 2.0))
                          : const Icon(FluentIcons.stop, size: 16.0),
                      onPressed:
                          (isBusy || !isRunning(widget.item, widget.running))
                              ? null
                              : () {
                                  stopInstance();
                                },
                    ),
                  ),
                ),
              ),
            ),
                  ])),
              (focused) => leadingFocused = focused),
          header: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Tooltip(
                  message: headerLabel(),
                  child: Text(
                    headerLabel(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Sized to its text, not to a flex share: `Expanded` +
              // `Flexible` both at flex 1 split the header 50/50 and cut the
              // name at half width beside ~480px of nothing (audit LN-01).
              // The tooltip says what the bare "1.65 GB" actually is
              // (LN-25), and a failed size read shows a dash instead of
              // silently blanking. On macOS this label also carries the
              // guest's IP, which is only useful if it can be copied — so it
              // is selectable text, not a plain label. A click inside it
              // places the caret instead of toggling the row; the rest of
              // the header still expands it.
              Tooltip(
                message: widget.trailing.isEmpty
                    ? 'diskusageunavailable-text'.i18n()
                    : 'sizeondiskhint-text'.i18n(),
                child: SelectableText(
                  widget.trailing.isEmpty ? '—' : widget.trailing,
                  key: ValueKey('test-listitem-meta-${widget.item}'),
                  focusNode: _metaFocus,
                  maxLines: 1,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          content: watchFocus(
              FocusTheme(
                data: const FocusThemeData(),
                child: Bar(
                  widget: widget,
                  isCleaning: isCleaning,
                  onCleaningChanged: (value) {
                    if (mounted) {
                      setState(() {
                        isCleaning = value;
                      });
                    }
                  },
                ),
              ),
              (focused) => contentFocused = focused));
  }

  void _setBusy(String? action) {
    if (mounted) setState(() => busyAction = action);
  }

  /// Terminal.app on the running VM: signed in as its own account over SSH
  /// where that works, its serial console otherwise.
  ///
  /// A macOS guest has no serial console behind it (bostrot/ai-tasks#101), so
  /// a refused key is the end of the road there rather than a fallback. It is
  /// also the one failure that can be repaired from here: the same dialog a
  /// snippet run uses installs the key, and the terminal opens after all.
  Future<void> openTerminal() async {
    _setBusy('console');
    try {
      final vmApi = api as AppleVmApi;
      try {
        await vmApi.openTerminal(widget.item);
      } on GuestKeyRefusedException catch (refused) {
        if (!mounted) return;
        if (!await ensureGuestAccess(context, api, widget.item,
            user: refused.user)) {
          return;
        }
        await vmApi.openTerminal(widget.item);
      }
    } catch (error) {
      Notify.message(
          '${'startfailed-text'.i18n([distroLabel(widget.item)])} $error',
          severity: InfoBarSeverity.error);
    } finally {
      _setBusy(null);
    }
  }

  /// Attach Terminal.app to the VM's serial console, booting it headless
  /// first when needed — the fully windowless path.
  Future<void> openConsole() async {
    _setBusy('console');
    try {
      await (api as AppleVmApi).openConsole(widget.item);
    } catch (error) {
      Notify.message(
          '${'startfailed-text'.i18n([distroLabel(widget.item)])} $error',
          severity: InfoBarSeverity.error);
    } finally {
      _setBusy(null);
    }
  }

  /// Front (or first-open) the running VM's display window.
  Future<void> showDisplay() async {
    try {
      await (api as AppleVmApi).showDisplay(widget.item);
    } catch (error) {
      Notify.message('${'vmshowdisplay-text'.i18n()}: $error',
          severity: InfoBarSeverity.error);
    }
  }

  Future<void> stopInstance() async {
    plausible.event(name: "wsl_stopped");
    _setBusy('stop');
    try {
      Notify.message('stoppinginstance-text'.i18n([distroLabel(widget.item)]),
          loading: true);
      await api.stop(widget.item);
      Notify.message('${widget.item} ${'stopped-text'.i18n()}.',
          severity: InfoBarSeverity.success,
          loading: false,
          duration: const Duration(seconds: 3));
    } catch (e) {
      final failure = WslFailure.from(e);
      Notify.message(
          '${'stopfailed-text'.i18n([distroLabel(widget.item)])} ${failure.shortReason}'.trim(),
          severity: InfoBarSeverity.error);
      diagnoseWithAi(failure.details);
    } finally {
      _setBusy(null);
    }
  }

  void startInstance() async {
    plausible.event(name: "wsl_started");
    String? startPath = prefs.getString('StartPath_${widget.item}') ?? '';
    String? startName = prefs.getString('StartUser_${widget.item}') ?? '';
    String startCmd = '';
    if (prefs.getBool('TurnkeyFirstStart_${widget.item}') ?? false) {
      startCmd = 'turnkey-init';
      prefs.setBool('TurnkeyFirstStart_${widget.item}', false);
    } else {
      startCmd = prefs.getString('StartCmd_${widget.item}') ?? '';
      // Replace faulty semicolons (e.g. "; ;" or ";;")
      startCmd = startCmd.replaceAll(RegExp(r';[ ]*;'), ';');
    }
    _setBusy('start');
    try {
      Notify.message('startinginstance-text'.i18n([distroLabel(widget.item)]),
          loading: true);
      // Awaited, and the toast posted afterwards. `Future.delayed(d, f(...))`
      // evaluates `f(...)` immediately and hands its result to the timer, so
      // the "started" toast used to appear before the process had spawned —
      // and the catch below could never run against a fire-and-forget call.
      await api.start(widget.item,
          startPath: startPath, startUser: startName, startCmd: startCmd);
      // A VM started from here shows the guest's own login prompt in its
      // display window, so the terminal greeting has to be inside the guest
      // by the time someone signs in. Deliberately not awaited: it waits for
      // the guest to answer SSH, which a start button must not.
      final backend = api;
      if (backend is AppleVmApi) {
        unawaited(backend.primeGuestGreeting(widget.item));
      }
      Notify.message('${widget.item} ${'started-text'.i18n()}.',
          severity: InfoBarSeverity.success,
          duration: const Duration(seconds: 3));
    } catch (e) {
      final failure = WslFailure.from(e);
      Notify.message(
          '${'startfailed-text'.i18n([distroLabel(widget.item)])} ${failure.shortReason}'.trim(),
          severity: InfoBarSeverity.error);
      diagnoseWithAi(failure.details);
    } finally {
      _setBusy(null);
    }
  }
}

class Bar extends StatelessWidget {
  const Bar(
      {super.key,
      required this.widget,
      required this.isCleaning,
      required this.onCleaningChanged});

  final ListItem widget;
  final bool isCleaning;
  final Function(bool) onCleaningChanged;

  @override
  Widget build(BuildContext context) {
    final VmBackend api = vmBackend();
    final VmFeatures features = api.features;
    return Container(
      decoration: const BoxDecoration(
          borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(5.0),
              bottomRight: Radius.circular(5.0))),
      // The hint on the left is flexible; the action strip is not. A `Row`
      // that runs out of room neither scrolls nor wraps — it paints the
      // overflow stripes and hides whatever is past the edge — and at the
      // 700px minimum window `main.dart` allows, the unconstrained
      // "no snippets yet" sentence pushed the last ~43px of the strip out
      // of the row. Laying the strip out first and letting the sentence
      // wrap into what is left keeps every control reachable at any window
      // size (bostrot/ai-tasks#109).
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Builder(builder: (childcontext) {
            // Quick actions are scripted in-distro commands; backends
            // without that capability get no dead dropdown or hint.
            if (!features.quickActions) return const SizedBox.shrink();
            List<MenuFlyoutItem> actions = [];
            List<String>? quickSettingsTitles =
                prefs.getStringList("quickSettingsTitles");
            List<String>? quickSettingsContents =
                prefs.getStringList("quickSettingsContents");
            String? user = prefs.getString('StartUser_${widget.item}');
            if (quickSettingsContents != null && quickSettingsTitles != null) {
              for (int i = 0; i < quickSettingsTitles.length; i++) {
                actions.add(MenuFlyoutItem(
                  leading: const MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Icon(FluentIcons.play),
                    ),
                  ),
                  onPressed: () async {
                    plausible.event(name: "wsl_quickaction_run");
                    // An Apple VM installed from an ISO has no key for the
                    // app yet; this installs it once instead of letting the
                    // Terminal window show "Permission denied".
                    if (!await ensureGuestAccess(childcontext, api, widget.item,
                        user: user)) {
                      return;
                    }
                    if (!childcontext.mounted) return;
                    // Its metadata carries the environment the snippet wants;
                    // a local snippet without any is read from the script
                    // itself (bostrot/ai-tasks#99).
                    final action =
                        QuickAction().byName(quickSettingsTitles[i]) ??
                            QuickActionItem(
                                name: quickSettingsTitles[i],
                                content: quickSettingsContents[i]);
                    final env = await askSnippetEnv(childcontext, action);
                    if (env == null) return;
                    api.runCommands(
                        widget.item, quickSettingsContents[i].split('\n'),
                        user: guestRunUser(widget.item, user), env: env);
                  },
                  text: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text(quickSettingsTitles[i])),
                ));
              }
            }
            return actions.isNotEmpty
                ? MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: DropDownButton(
                      leading: const Icon(FluentIcons.code),
                      title: Text('runquickaction-text'.i18n()),
                      items: actions,
                    ),
                  )
                // Says what would fill the ~85% of the expanded row that sat
                // empty with no explanation (audit LN-07).
                : Text('nosnippetshint-text'.i18n(),
                    style: TextStyle(
                        fontSize: 12.0, color: secondaryTextColor(context)));
          })),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              MergeSemantics(
                child: Tooltip(
                  message: 'saveastemplate-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      // Distinct from copy's two-pages silhouette four
                      // positions along (audit LN-06).
                      icon: const Icon(FluentIcons.archive, size: 16.0),
                      onPressed: () =>
                          // Open remove dialog
                          dialog(
                              item: widget.item,
                              title: 'savesatemplatequestion-text'
                                  .i18n([widget.item]),
                              body: 'saveastemplatebody-text'.i18n(),
                              submitText: 'saveastemplate-text'.i18n(),
                              submitInput: false,
                              submitStyle: ButtonStyle(
                                backgroundColor: ButtonState.all(Colors.red),
                                foregroundColor: ButtonState.all(Colors.white),
                              ),
                              onSubmit: (inputText) async {
                                await Templates().saveTemplate(widget.item);
                              }),
                    ),
                  ),
                ),
              ),
              // Only the app's own paths (snippets, the terminal button,
              // templating) get in by key; the VM's own screen asks for an
              // account and a password, and nothing else in the UI says what
              // they are (bostrot/ai-tasks#60).
              if (features.guestCredentials)
                MergeSemantics(
                  child: Tooltip(
                    message: 'vmlogindetailstooltip-text'.i18n(),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Builder(builder: (credentialsContext) {
                        return IconButton(
                          key: ValueKey('test-listitem-credentials-${widget.item}'),
                          icon: const Icon(FluentIcons.permissions, size: 16.0),
                          onPressed: () => showVmCredentialsDialog(
                              credentialsContext,
                              api as AppleVmApi,
                              widget.item),
                        );
                      }),
                    ),
                  ),
                ),
              // Next to the folder button, and for the reason that button
              // exists: opening the host's file manager is how you reach a
              // distro's files, right up until there is nothing to open —
              // a stopped distro, a backend with no share. This reaches them
              // through the instance itself (bostrot/ai-tasks#92).
              MergeSemantics(
                child: Tooltip(
                  message: 'transferfilestooltip-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Builder(builder: (transferContext) {
                      return IconButton(
                        key: ValueKey('test-listitem-transfer-${widget.item}'),
                        // An arrow out of a box: distinct at 16px from the
                        // folder four positions along, which the rest of the
                        // strip's near-identical glyphs were not (audit
                        // LN-06).
                        icon: const Icon(FluentIcons.export, size: 16.0),
                        onPressed: () {
                          plausible.event(name: "wsl_transfer_files");
                          showFileTransferDialog(
                              transferContext, widget.item);
                        },
                      );
                    }),
                  ),
                ),
              ),
              MergeSemantics(
                child: Tooltip(
                  message: 'openwithexplorer-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon: const Icon(FluentIcons.open_folder_horizontal,
                          size: 16.0),
                      onPressed: () {
                        plausible.event(name: "wsl_explorer");
                        api.startExplorer(widget.item);
                      },
                    ),
                  ),
                ),
              ),
              if (features.hostIntegration)
              MergeSemantics(
                child: Tooltip(
                  message: 'openwithvscode-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      // An outline glyph like its eight neighbours — the
                      // solid VS bowtie was the heaviest mark in the strip
                      // and pulled the eye to the least important action
                      // (audit LN-05).
                      icon: const Icon(FluentIcons.file_code, size: 16.0),
                      onPressed: () {
                        plausible.event(name: "wsl_vscode");
                        // Get path
                        String? path =
                            prefs.getString('StartPath_${widget.item}') ?? '';
                        WSLApi().startVSCode(widget.item, path: path);
                      },
                    ),
                  ),
                ),
              ),
              MergeSemantics(
                child: Tooltip(
                  message: 'copy-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon: const Icon(FluentIcons.copy, size: 16.0),
                      onPressed: () {
                        copyDialog(widget.item);
                      },
                    ),
                  ),
                ),
              ),
              MergeSemantics(
                child: Tooltip(
                  message: 'rename-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      // A pencil, not the abstract =|) mark nothing reads
                      // as renaming (audit LN-06).
                      icon: const Icon(FluentIcons.edit, size: 16.0),
                      onPressed: () {
                        dialog(
                            item: widget.item,
                            title:
                                '${'rename-text'.i18n()} \'${distroLabel(widget.item)}\'',
                            body: 'renameinfo-text'.i18n(),
                            submitText: 'rename-text'.i18n(),
                            submitStyle: const ButtonStyle(),
                            onSubmit: (inputText) {
                              Notify.message(
                                  'renaminginstance-text'.i18n(
                                      [distroLabel(widget.item), inputText]),
                                  loading: true);
                              prefs.setString(
                                  'DistroName_${widget.item}', inputText);
                              Notify.message(
                                  'renamedinstance-text'.i18n(
                                      [distroLabel(widget.item), inputText]),
                                  severity: InfoBarSeverity.success);
                            });
                      },
                    ),
                  ),
                ),
              ),
              // What the instance is using *right now*, beside what it is
              // using on disk: the same question asked of memory and CPU
              // instead of storage (bostrot/ai-tasks#109). Every backend
              // runs a Linux guest it can read `/proc` in, so there is no
              // flag to gate it on — a guest that cannot be read says so in
              // the dialog.
              MergeSemantics(
                child: Tooltip(
                  message: 'vmresources-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Builder(builder: (resourcesContext) {
                      return IconButton(
                        key: ValueKey('test-listitem-resources-${widget.item}'),
                        // A line chart: the only graph glyph in the strip,
                        // and distinct at 16px from the pie next to it
                        // (audit LN-06).
                        icon: const Icon(FluentIcons.stacked_line_chart,
                            size: 16.0),
                        onPressed: () {
                          plausible.event(name: "wsl_resources");
                          showVmResourcesDialog(
                            widget.item,
                            running:
                                widget.running.contains(widget.item),
                            context: resourcesContext,
                          );
                        },
                      );
                    }),
                  ),
                ),
              ),
              // Next to Compact deliberately: "80 GB allocated, 12 GB used"
              // is the question a user asks *before* reaching for the broom,
              // and #303 is someone whose compact filled the drive because
              // nothing showed them the numbers first (audit F-11).
              if (features.cleanup)
              MergeSemantics(
                child: Tooltip(
                  message: 'diskusage-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                      icon:
                          // A usage-share glyph, not a server rack (LN-06).
                          const Icon(FluentIcons.pie_single, size: 16.0),
                      onPressed: () {
                        plausible.event(name: "wsl_disk");
                        diskDialog(widget.item);
                      },
                    ),
                  ),
                ),
              ),
              if (features.cleanup)
              MergeSemantics(
                child: Tooltip(
                  message: 'cleanup-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                        icon: const Icon(FluentIcons.broom, size: 16.0),
                        onPressed: isCleaning
                            ? null
                            : () {
                                dialog(
                                    item: widget.item,
                                    title:
                                        'cleanuptitle-text'.i18n([widget.item]),
                                    body: 'cleanupbody-text'.i18n(),
                                    submitText: 'continue-text'.i18n(),
                                    submitStyle: ButtonStyle(
                                      backgroundColor:
                                          ButtonState.all(Colors.red),
                                      foregroundColor:
                                          ButtonState.all(Colors.white),
                                    ),
                                    submitInput: false,
                                    cancelText: 'cancel-text'.i18n(),
                                    onSubmit: (inputText) async {
                                      onCleaningChanged(true);
                                      // Show initial notification
                                      Notify.message(
                                          'cleaningupinstance-text'
                                              .i18n([distroLabel(widget.item)]),
                                          loading: true);

                                      try {
                                        await WSLApi().cleanup(widget.item,
                                            onProgress: (status) {
                                          Notify.message(
                                              'cleaningupprogress-text'.i18n(
                                                  [distroLabel(widget.item), status]),
                                              loading: true);
                                        });
                                        // Show success notification
                                        Notify.message(
                                            'cleanedupinstance-text'
                                                .i18n([distroLabel(widget.item)]),
                                            severity: InfoBarSeverity.success);
                                      } catch (error) {
                                        final failure = WslFailure.from(error);
                                        Notify.message(
                                            '${'cleanupfailed-text'.i18n([
                                              distroLabel(widget.item)
                                            ])} ${failure.shortReason}'.trim(),
                                            severity: InfoBarSeverity.error);
                                        diagnoseWithAi(failure.details);
                                      } finally {
                                        onCleaningChanged(false);
                                      }
                                    });
                              }),
                  ),
                ),
              ),
              // Host folders mounted inside the instance, at a path the
              // user picks — both backends can, so this is gated on the
              // service knowing the backend rather than on a feature flag
              // (bostrot/ai-tasks#79).
              if (VolumeMountService.isSupported(api))
              MergeSemantics(
                child: Tooltip(
                  message: 'mounts-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                        key: ValueKey('test-listitem-mounts-${widget.item}'),
                        icon: const Icon(FluentIcons.fabric_folder_link,
                            size: 16.0),
                        onPressed: () {
                          plausible.event(name: "wsl_mounts");
                          showVolumeMountsDialog(widget.item);
                        }),
                  ),
                ),
              ),
              // How much machine the instance gets. Next to the shares
              // because both are "what this VM is made of" rather than
              // something you do to it, and gated the same way: the Apple
              // backend can change it, WSL sizes its disk from the disk
              // dialog instead (bostrot/ai-tasks#103).
              if (VmResizeService.isSupported(api))
              MergeSemantics(
                child: Tooltip(
                  message: 'vmresize-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                        key: ValueKey('test-listitem-resize-${widget.item}'),
                        icon: const Icon(FluentIcons.hard_drive_group,
                            size: 16.0),
                        onPressed: () {
                          plausible.event(name: "vm_resize");
                          showVmResizeDialog(widget.item);
                        }),
                  ),
                ),
              ),
              if (features.wslConfig)
              MergeSemantics(
                child: Tooltip(
                  message: 'settings-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                        icon: const Icon(FluentIcons.settings, size: 16.0),
                        onPressed: () {
                          settingsDialog(widget.item);
                        }),
                  ),
                ),
              ),
              // Delete is the only control in this strip that destroys the
              // distro, and it used to sit between the broom and the gear —
              // 32px from two buttons a user reaches for routinely (audit
              // LN-04). It is last now, behind a separator, and carries the
              // same destructive colour its confirmation's submit button has.
              const Divider(
                direction: Axis.vertical,
                size: 20.0,
                style: DividerThemeData(
                  verticalMargin: EdgeInsets.symmetric(horizontal: 6.0),
                ),
              ),
              MergeSemantics(
                child: Tooltip(
                  message: 'delete-text'.i18n(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: IconButton(
                        icon: Icon(FluentIcons.delete,
                            size: 16.0, color: destructiveColor(context)),
                        onPressed: () {
                          dialog(
                              item: widget.item,
                              title: 'deleteinstancequestion-text'
                                  .i18n([distroLabel(widget.item)]),
                              body: 'deleteinstancebody-text'.i18n(),
                              submitText: 'delete-text'.i18n(),
                              submitInput: false,
                              submitStyle: ButtonStyle(
                                backgroundColor: ButtonState.all(Colors.red),
                                foregroundColor: ButtonState.all(Colors.white),
                              ),
                              onSubmit: (inputText) async {
                                try {
                                  Notify.message(
                                      'deletinginstance-text'
                                          .i18n([distroLabel(widget.item)]),
                                      loading: true);
                                  await api.remove(widget.item);
                                  Notify.message(
                                      'deletedinstance-text'
                                          .i18n([widget.item]),
                                      severity: InfoBarSeverity.success);
                                } catch (e) {
                                  final failure = WslFailure.from(e);
                                  Notify.message(
                                      '${'deletefailed-text'.i18n([
                                        distroLabel(widget.item)
                                      ])} ${failure.shortReason}'.trim(),
                                      severity: InfoBarSeverity.error);
                                  diagnoseWithAi(failure.details);
                                }
                              });
                        }),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
