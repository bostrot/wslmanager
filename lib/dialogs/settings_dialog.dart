import 'dart:async';

import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/api/default_user_service.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/debounced_text_box.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/sync.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';

String extractPorts(String portRaw) {
  List<String> portsRaw = portRaw.split('\n');
  String ports = '';
  for (String portRaw in portsRaw) {
    if (portRaw.contains(':')) {
      if (ports != '') {
        ports += ', ';
      }
      ports += int.tryParse(portRaw.split(':')[2].split(' ')[0], radix: 16)
          .toString();
    }
  }
  if (ports.isEmpty) {
    ports = "None";
  }
  return ports;
}

// Global vars
String cmds = '';

/// How the `wsl.conf` editor reaches WSL.
///
/// The dialog is built from top-level functions with no injection point, so
/// this is the seam the widget tests replace to keep `wsl.exe` out of them.
WSLApi Function() wslApiBuilder = () => WSLApi();

/// Rename Dialog
/// @param context: context
/// @param item: distro name
settingsDialog(item) {
  // Get root context by Key
  final context = GlobalVariable.infobox.currentContext!;

  // "Settings" alone was also the nav item for the app-wide screen, so one
  // word named two destinations and the dialog never said which distro it
  // edits (audit ST-33).
  var title = '${'settings-text'.i18n()} \'${distroLabel(item)}\'';
  final pathController = TextEditingController();
  pathController.text = prefs.getString('StartPath_$item') ?? '';
  final startCmdController = TextEditingController();
  startCmdController.text = prefs.getString('StartCmd_$item') ?? '';
  final userController = TextEditingController();
  userController.text = prefs.getString('StartUser_$item') ?? '';
  plausible.event(page: 'settings_dialog');

  // Every `wsl.conf` control writes here rather than straight to the distro,
  // so Cancel is a cancel and Save is the only thing that changes anything
  // (audit ST-28).
  final draft = WslConfDraft();

  // False until `/etc/wsl.conf` has actually been read. Save wrote the three
  // pref-backed fields and flushed an empty draft over settings it had not
  // loaded yet, and it was live for the four-plus seconds that read takes
  // (audit ST-36). Cancel stays enabled throughout — backing out of a dialog
  // that has not loaded is exactly what a user should be able to do.
  //
  // Not disposed: `showDialog`'s future resolves as the pop begins, while the
  // builder below is still listening, so disposing from there is a
  // use-after-dispose. Nothing outside this closure holds it, so it goes when
  // the route does.
  final loaded = ValueNotifier<bool>(false);

  showDialog(
    context: context,
    builder: (childcontext) {
      return ContentDialog(
        // Twenty controls lived in a 500x500 box: three fields visible at a
        // time and ten wheel notches to reach Move, on a window with 900px of
        // empty desktop around the dialog (audit ST-32).
        constraints: const BoxConstraints(maxHeight: 720.0, maxWidth: 640.0),
        title: Text(title),
        content: SettingsDialogContent(
          item: item,
          pathController: pathController,
          startCmdController: startCmdController,
          userController: userController,
          draft: draft,
          loaded: loaded,
        ),
        // Primary first, Cancel last — the order every other dialog in the
        // app uses (audit ST-62).
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: loaded,
            builder: (context, isLoaded, _) => FilledButton(
                key: const ValueKey('test-settings-dialog-save'),
                onPressed: !isLoaded
                    ? null
                    : () async {
                        final navigator = Navigator.of(childcontext);
                        prefs.setString('StartPath_$item', pathController.text);
                        prefs.setString(
                            'StartCmd_$item', startCmdController.text);
                        prefs.setString('StartUser_$item', userController.text);
                        for (final setting in await draft.flush(item)) {
                          _reportWrite(false, setting);
                        }
                        navigator.pop();
                      },
                child: Text('save-text'.i18n())),
          ),
          Button(
              child: Text('cancel-text'.i18n()),
              onPressed: () {
                draft.clear();
                Navigator.pop(childcontext);
              }),
        ],
      );
    },
  );
}

Future<Map<String, String>> getInstanceData(String item) async {
  String ip = await WSLApi().execCmdAsRoot(item, 'hostname --all-ip-addresses');
  String portsTcp =
      extractPorts(await WSLApi().execCmdAsRoot(item, 'cat /proc/net/tcp'));
  String portsUdp =
      extractPorts(await WSLApi().execCmdAsRoot(item, 'cat /proc/net/udp'));
  String portsTcp6 =
      extractPorts(await WSLApi().execCmdAsRoot(item, 'cat /proc/net/tcp6'));
  String portsUdp6 =
      extractPorts(await WSLApi().execCmdAsRoot(item, 'cat /proc/net/udp6'));
  return {
    'ip': ip,
    'portsTcp': portsTcp,
    'portsUdp': portsUdp,
    'portsTcp6': portsTcp6,
    'portsUdp6': portsUdp6,
  };
}

Column settingsColumn(
    TextEditingController pathController,
    TextEditingController startCmdController,
    TextEditingController userController,
    context,
    item,
    bool isSyncing,
    Function setState,
    WslConfDraft draft) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 8.0),
        child: Text('startcommand-text'.i18n()),
      ),
      Tooltip(
        message: 'startcommand-text'.i18n(),
        child: TextBox(
          controller: startCmdController,
          placeholder: 'e.g. /bin/bash',
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 8.0, top: 8.0),
        child: Text('startdirectorypath-text'.i18n()),
      ),
      Tooltip(
        message: 'startdirectorypath-text'.i18n(),
        child: TextBox(
          controller: pathController,
          placeholder: '/home/user/project',
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 2.0, top: 8.0),
        child: Text('startuser-text'.i18n()),
      ),
      // The narrow one. It only becomes `--user` on terminals this app
      // launches, which is why it used to be mistaken for the wsl.conf key
      // rendered right below it (audit coverage-sweep S-1).
      Padding(
        padding: const EdgeInsets.only(bottom: 4.0),
        child: Text('startuserinfo-text'.i18n(),
            style: FluentTheme.of(context).typography.caption),
      ),
      TextBox(
        controller: userController,
        placeholder: 'root',
      ),
      // A caption tied to the three start fields above, not a bare
      // parenthetical floating between two unrelated groups (audit ST-35).
      Padding(
        padding: const EdgeInsets.only(bottom: 8.0, top: 4.0),
        child: Text('emptyfieldsfordefault-text'.i18n(),
            style: FluentTheme.of(context).typography.caption),
      ),
      // The real one: `[user] default` in /etc/wsl.conf, which the app wrote
      // at creation and then never let anyone see again (audit CC-6). No
      // bare "User" heading — the field renders its own label, and the two
      // together read as one section labelling itself twice (ST-35).
      settingText(item, setState, userDefaultSetting, draft),
      const SizedBox(
        height: 8.0,
      ),
      wslSettings(context, item, setState, draft),
      const SizedBox(height: 16.0),
      const Divider(),
      const SizedBox(height: 12.0),
      // Everything above edits a setting; the four buttons below act on the
      // distro itself. As full-width rows with a 16px glyph on the right they
      // were the same shape, height and border as the `wsl.conf` expanders
      // directly above them, so "Move" — export → unregister → import — read
      // as one more section to open (audit ST-29).
      Text('distroactions-text'.i18n(),
          style: FluentTheme.of(context).typography.bodyStrong),
      const SizedBox(height: 4.0),
      Text('distroactionsinfo-text'.i18n(),
          style: FluentTheme.of(context).typography.caption),
      const SizedBox(height: 10.0),
      Wrap(
        spacing: 8.0,
        runSpacing: 8.0,
        children: [
          distroActionButton(
            context,
            label: 'terminatedistro-text'.i18n(),
            icon: FluentIcons.power_button,
            destructive: true,
            onPressed: () async {
              await wslApiBuilder().stop(item);
              Notify.message('terminatedistro-text'.i18n());
            },
          ),
          if (Sync().hasPath(item))
            // Says which of the two it will do. One label used to name both
            // actions over a state that was invisible, never persisted and
            // never repainted (audit ST-31).
            distroActionButton(
              context,
              label: (Sync.servingDistro == item
                      ? 'stopserving-text'
                      : 'startserving-text')
                  .i18n(),
              icon: Sync.servingDistro == item
                  ? FluentIcons.stop
                  : FluentIcons.upload,
              tooltip: 'startstopservinghint-text'.i18n(),
              onPressed: () async {
                plausible.event(name: "network_uploaded");
                Sync sync = Sync.instance(item);
                if (Sync.servingDistro != item) {
                  await sync.startServer();
                  Notify.message('startedserving-text'.i18n([item]));
                } else {
                  sync.stopServer();
                  Notify.message('stoppedserving-text'.i18n([item]));
                }
                setState(() {});
              },
            ),
          if (Sync().hasPath(item))
            distroActionButton(
              context,
              label: 'downloadoverride-text'.i18n(),
              icon: FluentIcons.download,
              tooltip: 'downloadoverridehint-text'.i18n(),
              destructive: true,
              onPressed: () {
                plausible.event(name: "network_downloaded");
                dialog(
                    item: item,
                    title: 'syncfromserver-text'.i18n([distroLabel(item)]),
                    body: 'syncwarning-text'.i18n([item]),
                    submitText: 'yesoverride-text'.i18n(),
                    submitInput: false,
                    submitStyle: ButtonStyle(
                      backgroundColor: ButtonState.all(Colors.red),
                      foregroundColor: ButtonState.all(Colors.white),
                    ),
                    onSubmit: (inputText) {
                      Sync sync = Sync.instance(item);
                      sync.download();
                    });
              },
            ),
          distroActionButton(
            context,
            label: 'move-text'.i18n(),
            icon: FluentIcons.move,
            destructive: true,
            onPressed: () async {
              // Pick directory
              String? selectedDirectory =
                  await FilePicker.platform.getDirectoryPath(
                dialogTitle: 'move-text'.i18n(),
                lockParentWindow: true,
              );

              if (selectedDirectory == null) {
                return;
              }

              // Say which of the two moves is about to run. On WSL 2.5+ this
              // is one supported `--manage --move`; below that it is export →
              // **unregister** → import, and #280 is a user who lost a distro
              // inside that window without ever being told it existed.
              final native = await wslApiBuilder().supportsNativeMove();

              dialog(
                  item: item,
                  title: '${'move-text'.i18n()} \'${distroLabel(item)}\'',
                  body: '${'movebody-text'.i18n([
                        distroLabel(item)
                      ])}\n\nTarget: $selectedDirectory'
                      '\n\n${native ? 'movenative-text'.i18n() : 'movelegacy-text'.i18n()}',
                  submitText: 'move-text'.i18n(),
                  submitStyle: ButtonStyle(
                    backgroundColor: ButtonState.all(Colors.red),
                    foregroundColor: ButtonState.all(Colors.white),
                  ),
                  submitInput: false,
                  onSubmit: (inputText) async {
                    Notify.message(
                        'moving-text'
                            .i18n([distroLabel(item), selectedDirectory]),
                        loading: true);
                    try {
                      await wslApiBuilder().move(item, selectedDirectory);
                      Notify.message('moved-text'
                          .i18n([distroLabel(item), selectedDirectory]));
                    } catch (e) {
                      Notify.message(
                          'move-error-text'.i18n([
                            distroLabel(item),
                            selectedDirectory,
                            friendlyErrorText(e)
                          ]),
                          severity: InfoBarSeverity.error);
                    }
                  });
            },
          ),
        ],
      ),
    ],
  );
}

/// One documented `/etc/wsl.conf` key, with everything the dialog needs to
/// render it.
///
/// The dialog used to derive its labels from the Dart identifier —
/// `"MountFsTab"`, `"AppendWindowsPath"` — with no description and no
/// `.i18n()` call anywhere, which made it the largest i18n gap the WSL
/// documentation audit found (doc/audit/wsl-docs/wslconf-keys.md CC-4).
class WslConfSetting {
  final String section;
  final String key;

  /// i18n key of the label, and of the sentence under it.
  final String labelKey;
  final String infoKey;

  final bool isToggle;

  /// What WSL does when the key is absent, where the documentation states it.
  ///
  /// Null means the default is not a fixed value — `[boot] systemd` is
  /// whatever the distro image ships — so an unset key renders off and says
  /// so rather than claiming a default it does not have.
  final bool? defaultOn;

  final String? placeholder;

  const WslConfSetting.toggle(
    this.section,
    this.key,
    this.labelKey,
    this.infoKey, {
    this.defaultOn,
  })  : isToggle = true,
        placeholder = null;

  const WslConfSetting.text(
    this.section,
    this.key,
    this.labelKey,
    this.infoKey, {
    this.placeholder,
  })  : isToggle = false,
        defaultOn = null;

  /// Suffix of this key's `SharedPreferences` entry, under `<distro>-`.
  ///
  /// The spelling here is the documented one, and [WslConfFile] normalises the
  /// file's spelling to match on read, so a hand-written `mountfstab = true`
  /// reaches the widget that renders it (audit V-7).
  String get prefKey => '$section-$key';
}

/// Every documented `wsl.conf` key, in the order the dialog renders them.
///
/// `[gpu] enabled`, `[time] useWindowsTimezone` and `[boot] protectBinfmt`
/// were missing entirely; `[user] default` was written once at distro creation
/// and never shown again (audit CC-6).
const List<WslConfSetting> wslConfSettings = <WslConfSetting>[
  WslConfSetting.toggle(
      'boot', 'systemd', 'bootsystemd-text', 'bootsystemdinfo-text'),
  WslConfSetting.text(
      'boot', 'command', 'bootcommand-text', 'bootcommandinfo-text',
      placeholder: 'service docker start'),
  WslConfSetting.toggle(
      'boot', 'protectBinfmt', 'protectbinfmt-text', 'protectbinfmtinfo-text',
      defaultOn: true),
  WslConfSetting.toggle('automount', 'enabled', 'automountenabled-text',
      'automountenabledinfo-text',
      defaultOn: true),
  WslConfSetting.toggle('automount', 'mountFsTab', 'automountmountfstab-text',
      'automountmountfstabinfo-text',
      defaultOn: true),
  WslConfSetting.text(
      'automount', 'root', 'automountroot-text', 'automountrootinfo-text',
      placeholder: '/mnt/'),
  WslConfSetting.text('automount', 'options', 'automountoptions-text',
      'automountoptionsinfo-text',
      placeholder: 'metadata,uid=1000,gid=1000,umask=22'),
  WslConfSetting.toggle('network', 'generateHosts', 'networkgeneratehosts-text',
      'networkgeneratehostsinfo-text',
      defaultOn: true),
  WslConfSetting.toggle('network', 'generateResolvConf',
      'networkgenerateresolvconf-text', 'networkgenerateresolvconfinfo-text',
      defaultOn: true),
  WslConfSetting.text('network', 'hostname', 'networkhostname-text',
      'networkhostnameinfo-text'),
  WslConfSetting.toggle(
      'interop', 'enabled', 'interopenabled-text', 'interopenabledinfo-text',
      defaultOn: true),
  WslConfSetting.toggle('interop', 'appendWindowsPath',
      'interopappendwindowspath-text', 'interopappendwindowspathinfo-text',
      defaultOn: true),
  WslConfSetting.toggle(
      'gpu', 'enabled', 'gpuenabled-text', 'gpuenabledinfo-text',
      defaultOn: true),
  WslConfSetting.toggle('time', 'useWindowsTimezone', 'usewindowstimezone-text',
      'usewindowstimezoneinfo-text',
      defaultOn: true),
  // Rendered next to the "Start user" box instead of in an Expander — see
  // [userDefaultSetting].
  WslConfSetting.text(
      'user', 'default', 'wsldefaultuser-text', 'defaultuserinfo-text',
      placeholder: 'root'),
];

/// `[user] default`, the one documented way to change the default user of an
/// imported distro (`basic-commands.md:152`).
///
/// It is deliberately not inside the `wsl.conf` Expanders: the dialog already
/// shows a **Start user** box that only sets `--user` on terminals this app
/// launches, and a user hunting for this setting finds that one first and
/// stops looking (audit coverage-sweep S-1). The two sit together, each
/// saying what it does.
final WslConfSetting userDefaultSetting =
    wslConfSettings.firstWhere((s) => s.section == 'user');

/// i18n key of each section's Expander header.
const Map<String, String> wslConfSectionLabels = <String, String>{
  'boot': 'boot-text',
  'automount': 'automount-text',
  'network': 'network-text',
  'interop': 'interop-text',
  'gpu': 'gpu-text',
  'time': 'time-text',
};

/// The `wsl.conf` editor: one Expander per documented section.
Widget wslSettings(
    BuildContext context, String item, Function setState, WslConfDraft draft) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('wslsettings-text'.i18n()),
      const SizedBox(height: 4.0),
      // No wsl.conf key takes effect while the distro is still running — the
      // documented "8 second rule" (wsl-config.md:20-26). A per-distro
      // terminate is enough; the global shutdown the .wslconfig screen needs
      // is not (audit runtime R-12).
      Text('wslconfrestart-text'.i18n(),
          style: FluentTheme.of(context).typography.caption),
      const SizedBox(height: 8.0),
      for (final section in wslConfSectionLabels.entries) ...[
        Expander(
          header: Text(section.value.i18n()),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final setting
                  in wslConfSettings.where((s) => s.section == section.key))
                wslConfField(item, setState, setting, draft),
            ],
          ),
        ),
        const SizedBox(height: 8.0),
      ],
    ],
  );
}

/// A button in the per-distro dialog that *does* something to the distro.
///
/// All four used to be full-width rows with the label on the left and a 16px
/// glyph on the right — the shape of the `wsl.conf` expanders stacked
/// immediately above them (audit ST-29). They are sized to their content now,
/// the icon leads the label, and the three that cannot be undone carry the
/// destructive colour.
Widget distroActionButton(
  BuildContext context, {
  required String label,
  required IconData icon,
  required VoidCallback onPressed,
  String? tooltip,
  bool destructive = false,
  Key? key,
}) {
  final color = destructive ? destructiveColor(context) : null;
  final button = Button(
    key: key,
    style: ButtonStyle(
      padding: ButtonState.all(
          const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0)),
      foregroundColor: color == null ? null : ButtonState.all(color),
    ),
    onPressed: onPressed,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16.0, color: color),
        const SizedBox(width: 8.0),
        Text(label),
      ],
    ),
  );
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: tooltip == null ? button : Tooltip(message: tooltip, child: button),
  );
}

/// Edits to `/etc/wsl.conf` the user has made but not saved.
///
/// Every control in the editor used to write to the distro the moment it
/// changed or lost focus, while the dialog's Save button persisted only the
/// three app-side start preferences. A user who flipped `[boot] systemd`,
/// thought better of it and pressed **Cancel** had already changed their
/// distro (audit ST-28). Edits land here instead, and [flush] is what Save
/// calls.
class WslConfDraft {
  /// Pending value per `prefKey`; `null` means "remove the line".
  final Map<String, String?> _pending = <String, String?>{};

  /// True while there is something Save would write.
  bool get isDirty => _pending.isNotEmpty;

  /// The settings this draft would touch, in the order they were edited.
  Iterable<String> get editedKeys => _pending.keys;

  void setValue(WslConfSetting setting, String value) =>
      _pending[setting.prefKey] = value;

  void unset(WslConfSetting setting) => _pending[setting.prefKey] = null;

  void clear() => _pending.clear();

  /// What the editor shows for [setting]: the pending edit when there is one,
  /// otherwise the value `loadDistroSettings` read out of the file.
  String? read(String item, WslConfSetting setting) {
    if (_pending.containsKey(setting.prefKey)) return _pending[setting.prefKey];
    return prefs.get('$item-${setting.prefKey}')?.toString();
  }

  /// Whether [setting] would have a line in `wsl.conf` once this draft is
  /// written.
  bool isSet(String item, WslConfSetting setting) =>
      read(item, setting) != null;

  /// Write every pending edit to [item]'s `/etc/wsl.conf` and mirror it into
  /// the preference cache the editor renders from. Returns the settings whose
  /// write failed, for the caller to report.
  Future<List<WslConfSetting>> flush(String item) async {
    final failed = <WslConfSetting>[];
    for (final entry in _pending.entries) {
      final setting = wslConfSettings.firstWhere((s) => s.prefKey == entry.key);
      final value = entry.value;
      final bool ok;
      // `[user] default` is the one key with a second, immediate route — and
      // the one whose wrong value stops the distro from starting — so it goes
      // through the service that knows both, rather than straight to the file
      // like every other key here. See lib/api/default_user_service.dart.
      final bool isDefaultUser =
          setting.section == 'user' && setting.key == 'default';
      if (value == null) {
        // An emptied box means "unset", which has to delete the line: writing
        // `hostname =` back would pin the distro to an empty value instead of
        // letting WSL fall back to the Windows computer name.
        await prefs.remove('$item-${setting.prefKey}');
        if (isDefaultUser) {
          final cleared =
              await DefaultUserService(wslApiBuilder()).clearDefaultUser(item);
          ok = cleared.ok;
        } else {
          ok = await wslApiBuilder()
              .removeSetting(item, setting.section, setting.key);
        }
      } else {
        if (setting.isToggle) {
          await prefs.setBool('$item-${setting.prefKey}', value == 'true');
        } else {
          await prefs.setString('$item-${setting.prefKey}', value);
        }
        if (isDefaultUser) {
          final applied = await DefaultUserService(wslApiBuilder())
              .setDefaultUser(item, value);
          ok = applied.ok;
          // A name the distro has no account for was written verbatim before
          // and left it unable to start; the pref mirror must not keep
          // claiming a value the file does not have.
          if (!ok) await prefs.remove('$item-${setting.prefKey}');
        } else {
          ok = await wslApiBuilder()
              .setSetting(item, setting.section, setting.key, value);
        }
      }
      if (!ok) failed.add(setting);
    }
    _pending.clear();
    return failed;
  }
}

/// The widget [setting] is rendered by.
Widget wslConfField(String item, Function setState, WslConfSetting setting,
    WslConfDraft draft) {
  return setting.isToggle
      ? settingSwitch(item, setState, setting, draft)
      : settingText(item, setState, setting, draft);
}

/// Report a failed write. The old writer returned `true` unconditionally and
/// ran with `showOutput: false`, so a `sed` that never fired still showed as
/// applied (audit CC-2).
void _reportWrite(bool ok, WslConfSetting setting) {
  if (!ok) {
    Notify.message('wslconfwritefailed-text'.i18n([setting.labelKey.i18n()]));
  }
}

/// Label, description and — when the key is actually in the file — the
/// control that takes it back out again.
Widget _settingHeader(BuildContext context, String item, Function setState,
    WslConfSetting setting, WslConfDraft draft,
    {Widget? leading}) {
  final theme = FluentTheme.of(context);
  final isSet = draft.isSet(item, setting);
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (leading != null) ...[leading, const SizedBox(width: 8.0)],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(setting.labelKey.i18n()),
            const SizedBox(height: 2.0),
            Text(setting.infoKey.i18n(), style: theme.typography.caption),
            // Grey like the .wslconfig screen's unset marker, not accent —
            // in accent it read as a hyperlink that did nothing when
            // clicked, and the two screens spoke two visual languages for
            // one concept (audit ST-34).
            if (!isSet)
              Text('settingunset-text'.i18n(),
                  style: theme.typography.caption
                      ?.copyWith(color: secondaryTextColor(context))),
          ],
        ),
      ),
      if (isSet)
        NamedIconButton(
          label: 'resettodefault-text'.i18n(),
          icon: FluentIcons.undo,
          onPressed: () {
            draft.unset(setting);
            setState(() {});
          },
        ),
    ],
  );
}

/// A boolean `wsl.conf` key.
///
/// Unset renders as the *documented* default, not as off. Six keys are
/// documented `true` and the old switch showed every one of them off on a
/// distro whose `wsl.conf` is absent or near-empty, which is most of them
/// (audit CC-3). Turning a key back to unset removes its line, so there is a
/// real third state rather than a relabelled `false`.
Widget settingSwitch(String item, Function setState, WslConfSetting setting,
    WslConfDraft draft) {
  final stored = draft.read(item, setting);
  final checked =
      stored != null ? stored == 'true' : (setting.defaultOn ?? false);
  return Padding(
    padding: const EdgeInsets.all(8.0),
    child: Builder(
      builder: (context) => _settingHeader(
        context,
        item,
        setState,
        setting,
        draft,
        leading: Padding(
          padding: const EdgeInsets.only(top: 2.0),
          child: ToggleSwitch(
            checked: checked,
            onChanged: (value) {
              draft.setValue(setting, value.toString());
              setState(() {});
            },
          ),
        ),
      ),
    ),
  );
}

/// A free-text `wsl.conf` key.
Widget settingText(String item, Function setState, WslConfSetting setting,
    WslConfDraft draft) {
  return _WslConfTextField(
    key: ValueKey('$item-${setting.prefKey}'),
    item: item,
    setting: setting,
    setState: setState,
    draft: draft,
  );
}

/// A text key that records the value once it settles instead of once per
/// keystroke.
///
/// `onChanged` used to run a full in-distro script execution per character
/// typed (audit CC-5). The debounce plus the commit on blur means a
/// twelve-character hostname is one entry in the draft — and, since ST-28, one
/// write when the dialog is saved rather than one the moment the box is left.
class _WslConfTextField extends StatefulWidget {
  final String item;
  final WslConfSetting setting;
  final Function setState;
  final WslConfDraft draft;

  const _WslConfTextField({
    super.key,
    required this.item,
    required this.setting,
    required this.setState,
    required this.draft,
  });

  @override
  State<_WslConfTextField> createState() => _WslConfTextFieldState();
}

class _WslConfTextFieldState extends State<_WslConfTextField> {
  Future<void> _commit(String value) async {
    if (value.isEmpty) {
      widget.draft.unset(widget.setting);
    } else {
      widget.draft.setValue(widget.setting, value);
    }
    if (mounted) widget.setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _settingHeader(context, widget.item, widget.setState, widget.setting,
              widget.draft),
          const SizedBox(height: 4.0),
          DebouncedTextBox(
            initialValue: widget.draft.read(widget.item, widget.setting) ?? '',
            placeholder: widget.setting.placeholder,
            onCommit: _commit,
          ),
        ],
      ),
    );
  }
}

Future<void> loadDistroSettings(String item) async {
  // Clear known wsl.conf settings to avoid stale data. Derived from the
  // rendered list so a key added to `wslConfSettings` cannot be forgotten
  // here and leak its value from the previously opened distro.
  final List<String> knownKeys =
      wslConfSettings.map((setting) => setting.prefKey).toList();

  for (var key in knownKeys) {
    await prefs.remove('$item-$key');
  }

  var config = await wslApiBuilder().getWSLConf(item);
  config.forEach((section, settings) {
    settings.forEach((key, value) {
      // Handle booleans
      if (value == 'true') {
        prefs.setBool('$item-$section-$key', true);
      } else if (value == 'false') {
        prefs.setBool('$item-$section-$key', false);
      } else {
        prefs.setString('$item-$section-$key', value);
      }
    });
  });
}

class SettingsDialogContent extends StatefulWidget {
  final String item;
  final TextEditingController pathController;
  final TextEditingController startCmdController;
  final TextEditingController userController;
  final WslConfDraft draft;

  /// Flipped true once `/etc/wsl.conf` has been read, so the dialog's Save
  /// button knows there is something to save (audit ST-36).
  final ValueNotifier<bool>? loaded;

  const SettingsDialogContent({
    Key? key,
    required this.item,
    required this.pathController,
    required this.startCmdController,
    required this.userController,
    required this.draft,
    this.loaded,
  }) : super(key: key);

  @override
  State<SettingsDialogContent> createState() => _SettingsDialogContentState();
}

class _SettingsDialogContentState extends State<SettingsDialogContent> {
  /// Null until the settings have actually been asked for — which, on a
  /// stopped distro, is only after the user has agreed to start it.
  Future<void>? _loadFuture;
  bool isSyncing = false;
  bool _checkingRunning = true;

  @override
  void initState() {
    super.initState();
    _checkRunning();
  }

  /// Reading `/etc/wsl.conf` goes through `wsl.exe`, which boots the distro.
  /// Opening this dialog on a stopped `Ubuntu` therefore started a virtual
  /// machine, with nothing anywhere saying it would (audit ST-27). A running
  /// distro costs nothing and loads straight away; a stopped one is asked
  /// about first.
  Future<void> _checkRunning() async {
    List<String> running;
    try {
      running = await wslApiBuilder().listRunning();
    } catch (_) {
      running = const <String>[];
    }
    if (!mounted) return;
    setState(() {
      _checkingRunning = false;
      if (running.contains(widget.item)) {
        _loadFuture = _load();
      }
    });
  }

  /// The read, plus the one signal the dialog's Save button waits on.
  ///
  /// `whenComplete` rather than `then`: a read that failed still puts the form
  /// on screen, so Save has to be usable over it — what must not happen is
  /// Save flushing a draft while the read is still in flight (audit ST-36).
  Future<void> _load() {
    final future = loadDistroSettings(widget.item);
    future.whenComplete(() {
      if (mounted) widget.loaded?.value = true;
    });
    return future;
  }

  /// A spinner that says what it is waiting for.
  ///
  /// Four-plus seconds of a bare [ProgressRing] in an otherwise empty dialog
  /// left the user with nothing to read and no idea that a distro was being
  /// booted to answer the question (audit ST-36, ST-27).
  Widget _spinner(String label) => SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ProgressRing(),
              const SizedBox(height: 12.0),
              Text(label, key: const ValueKey('test-settings-loading-label')),
            ],
          ),
        ),
      );

  /// Say what opening the editor costs, and let the user decide.
  Widget _startNotice(BuildContext context) {
    return SizedBox(
      height: 200,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoBar(
            title: Text('distrostopped-text'.i18n()),
            content: Text('distrostoppedinfo-text'.i18n([widget.item])),
            severity: InfoBarSeverity.warning,
            isLong: true,
          ),
          const SizedBox(height: 12.0),
          Button(
            key: const ValueKey('test-settings-start-distro'),
            onPressed: () => setState(() => _loadFuture = _load()),
            child: Text('startandread-text'.i18n()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingRunning) {
      return _spinner('checkingdistrostate-text'.i18n([widget.item]));
    }
    final loadFuture = _loadFuture;
    if (loadFuture == null) return _startNotice(context);
    return FutureBuilder(
      future: loadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _spinner('readingwslconf-text'.i18n([widget.item]));
        }
        return SingleChildScrollView(
          // Keeps the scrollbar off the input fields it would otherwise
          // overlap.
          child: Padding(
            padding: const EdgeInsets.only(right: 14.0),
            child: settingsColumn(
                widget.pathController,
                widget.startCmdController,
                widget.userController,
                context,
                widget.item,
                isSyncing,
                setState,
                widget.draft),
          ),
        );
      },
    );
  }
}
