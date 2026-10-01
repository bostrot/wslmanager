import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/badge_pill.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/dialogs/info_dialog.dart';
import 'package:wsl2distromanager/dialogs/mount_dialog.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/nav/linkaction.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Rebuilt on every access so the entries follow the active backend's
/// feature set (WSL-only destinations disappear on the Apple backend).
List<NavigationPaneItem> get originalItems {
  final backend = vmBackend();
  final features = backend.features;
  return [
  PaneItem(
    key: const Key('/'),
    icon: const Icon(FluentIcons.home),
    title: Text('homepage-text'.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('home', path: '/');
    },
  ),
  if (features.quickActions)
  PaneItem(
    key: const Key('/quickactions'),
    // Distinct from the Templates item's file_template at 16px (LN-11).
    icon: const Icon(FluentIcons.code),
    title: Text('managequickactions-text'.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('quickactions', path: '/quickactions');
    },
  ),
  // Containers sit next to the instances rather than inside their list: the
  // engine, not this app, owns their lifecycle (bostrot/ai-tasks#57).
  // Experimental, so only once switched on in Settings — see
  // [ExperimentalFeatures].
  if (ExperimentalFeatures.isVisible(ExperimentalFeature.containers, backend: backend))
  PaneItem(
    key: const Key('/containers'),
    icon: const Icon(FluentIcons.product_list),
    title: Text(ExperimentalFeature.containers.labelKey.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('containers', path: '/containers');
    },
  ),
  // Kubernetes sits next to Containers for the same reason Containers sits
  // next to the instances: the cluster owns these, this app only drives them
  // (bostrot/ai-tasks#61). Experimental, so only once switched on.
  if (ExperimentalFeatures.isVisible(ExperimentalFeature.kubernetes, backend: backend))
  PaneItem(
    key: const Key('/kubernetes'),
    icon: const Icon(FluentIcons.cloud),
    title: Text(ExperimentalFeature.kubernetes.labelKey.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('kubernetes', path: '/kubernetes');
    },
  ),
  PaneItem(
    key: const Key('/templates'),
    icon: const Icon(FluentIcons.file_template),
    title: Text('templates-text'.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('templates', path: '/templates');
    },
  ),
  // Hidden, not paywalled, once AI is switched off in Settings: the entry
  // is the one place the workspace distro gets provisioned from.
  if (features.aiWorkspace && AiService.featuresEnabled)
  PaneItem(
    key: const Key('/ai-workspace'),
    icon: const Icon(FluentIcons.robot),
    title: Text('ai-workspace-title'.i18n()),
    infoBadge: const BetaPaneBadge(),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('ai-workspace', path: '/ai-workspace');
    },
  ),
  PaneItem(
    key: const Key('/addinstance'),
    icon: const Icon(FluentIcons.add),
    title: Text('addinstance-text'.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('addinstance', path: '/addinstance');
    },
  ),
  if (features.packaging)
  PaneItem(
    key: const Key('/package'),
    icon: const Icon(FluentIcons.package),
    title: Text('custompackage-text'.i18n()),
    // `.wsl` packaging is as new as the AI Workspace and rests on a WSL
    // feature that is itself young, so the pane marks it the same way
    // (bostrot/ai-tasks#36).
    infoBadge: const BetaPaneBadge(),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('package', path: '/package');
    },
  ),
  // A PaneItemAction, not a PaneItem: this opens a modal, and as a PaneItem
  // it was pixel-identical to the seven real destinations while the pane's
  // selection stayed wherever it was (audit LN-16).
  if (features.mountDisk)
  PaneItemAction(
    icon: const Icon(FluentIcons.hard_drive),
    title: Text('mountdisk-text'.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      showMountDialog();
    },
  ),
  // Playbooks: an instance's state as code — packages, users, files,
  // services, commands — applied to an instance that already exists, as
  // often as needed, or an Ansible playbook run inside it. Gated on
  // quickActions because that is the capability it rests on: scripted
  // commands run inside an instance, which both backends offer — but not
  // over remote WSL, whose SSH wrapper caps an inline command at a couple
  // of KB while every step here ships a base64 script several KB long
  // (bostrot/ai-tasks#78). Experimental on top of that gate, so only once
  // switched on.
  if (ExperimentalFeatures.isVisible(ExperimentalFeature.playbooks, backend: backend))
  PaneItem(
    key: const Key('/playbooks'),
    icon: const Icon(FluentIcons.build_definition),
    title: Text(ExperimentalFeature.playbooks.labelKey.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('playbooks', path: '/playbooks');
    },
  ),
  // Cloud goes last, and that placement is the whole argument for where it
  // belongs. It shares its subject with Containers and Kubernetes — machines
  // this app does not own — but it is also the newest and the most
  // specialised of the destinations, and the pane runs out of height before
  // it runs out of entries: at 800x600 on the Apple backend it holds seven.
  // Whatever sits last is the entry a user at that size has to scroll for,
  // and Add instance and the AI Workspace are not entries to hide
  // (bostrot/ai-tasks#62).
  //
  // Gated on rootfsExport, unlike Containers and Kubernetes, because that is
  // what deploying needs — a Cloud screen that cannot deploy is a server list
  // with a delete button, which is the "second control panel for somebody
  // else's product" this app deliberately does not build. Both shipped
  // backends pass that gate: the Apple one reads the root filesystem out of
  // the running guest rather than out of its disk image (#62, reopened). The
  // gate stays because it is the capability the screen depends on, not a
  // platform check in disguise.
  // Experimental on top of that gate, so only once switched on.
  if (ExperimentalFeatures.isVisible(ExperimentalFeature.cloud, backend: backend))
  PaneItem(
    key: const Key('/cloud'),
    icon: const Icon(FluentIcons.cloud_upload),
    title: Text(ExperimentalFeature.cloud.labelKey.i18n()),
    infoBadge: const BetaPaneBadge(),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('cloud', path: '/cloud');
    },
  ),
  // Last for the same reason Cloud is: the pane runs out of height before
  // it runs out of entries, and this is the newest and the most specialised
  // of them — a configuration most people write once. Both backends pass
  // the gate; a Mac driving a remote Windows host does not, because the
  // file cloud-init reads lives under a profile on the other machine
  // (bostrot/ai-tasks#76). Experimental on top of that gate, so only once
  // switched on.
  if (ExperimentalFeatures.isVisible(ExperimentalFeature.cloudInit, backend: backend))
  PaneItem(
    key: const Key('/cloudinit'),
    icon: const Icon(FluentIcons.cloud_add),
    title: Text(ExperimentalFeature.cloudInit.labelKey.i18n()),
    body: const SizedBox.shrink(),
    onTap: () {
      navigateGuarded('cloudinit', path: '/cloudinit');
    },
  ),
  ];
}

/// Rebuilt on every access: the label and badge depend on the licence state,
/// and a PaneItem title has to be a real Text — fluent_ui reads the string out
/// of it, so a builder widget renders an empty entry.
List<NavigationPaneItem> get footerItems => [
      PaneItem(
        key: const Key('/license'),
        icon: const Icon(FluentIcons.crown),
        title: Text(LicenseManager().isPro
            ? 'license-text'.i18n()
            : 'upgrade-pro-text'.i18n()),
        infoBadge: LicenseManager().isPro
            ? null
            // IA-10: the pill is decoration next to the pane label, so it
            // needs a name of its own to be announced as anything. Accent,
            // not amber: the same amber pill used to mean "immature feature"
            // in five places and "buy this" here, and measured 1.35:1 on the
            // light wash besides (audit PS-09, TL-05).
            : Builder(builder: (context) {
                final dark = FluentTheme.of(context).brightness.isDark;
                return Semantics(
                  label: 'new-badge-label-text'.i18n(),
                  excludeSemantics: true,
                  // The same pill as BetaBadge, so the two line up at one
                  // height in the pane; only the palette differs.
                  child: BadgePill(
                    label: 'NEW',
                    foreground:
                        dark ? Colors.blue.lightest : Colors.blue.darkest,
                    background: Colors.blue.normal.withValues(alpha: 0.15),
                  ),
                );
              }),
        body: const SizedBox.shrink(),
        onTap: () {
          // Pro users open their licence; everyone else is being upsold —
          // unless they are already looking at it, which navigateGuarded
          // ignores and so should the count.
          if (!LicenseManager().isPro &&
              router.state.uri.toString() != '/license') {
            trackUpgradeClick('pane');
          }
          navigateGuarded('license', path: '/license');
        },
      ),
      LinkPaneItemAction(
        icon: const Icon(FluentIcons.heart),
        title: Text('sponsor-text'.i18n()),
        link: 'https://github.com/sponsors/bostrot',
        body: const SizedBox.shrink(),
      ),
      PaneItemSeparator(),
      PaneItem(
        key: const Key('/settings'),
        icon: const Icon(FluentIcons.settings),
        title: Text('settings-text'.i18n()),
        body: const SizedBox.shrink(),
        onTap: () {
          navigateGuarded('settings', path: '/settings');
        },
      ),
      LinkPaneItemAction(
        icon: const Icon(FluentIcons.help),
        title: Text('documentation-text'.i18n()),
        link: 'https://github.com/bostrot/wslmanager/wiki',
        body: const SizedBox.shrink(),
      ),
      // Same LN-16 rule as Mount Disk: a modal opener is an action.
      PaneItemAction(
        icon: const Icon(FluentIcons.info),
        title: Text('about-text'.i18n()),
        body: const SizedBox.shrink(),
        onTap: () {
          infoDialog(prefs, currentVersion);
        },
      ),
    ];
