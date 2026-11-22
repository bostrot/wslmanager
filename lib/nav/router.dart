import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:go_router/go_router.dart';
import 'package:plausible_analytics/navigator_observer.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/unsaved_changes.dart';
import 'package:wsl2distromanager/nav/root_screen.dart';
import 'package:wsl2distromanager/screens/ai_workspace_screen.dart';
import 'package:wsl2distromanager/screens/actions_screen.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/screens/community_screen.dart';
import 'package:wsl2distromanager/screens/snippet_editor_screen.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/screens/cloud_screen.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/screens/cloud_init_screen.dart';
import 'package:wsl2distromanager/screens/containers_screen.dart';
import 'package:wsl2distromanager/screens/create_screen.dart';
import 'package:wsl2distromanager/screens/create_vm_screen.dart';
import 'package:wsl2distromanager/screens/home_screen.dart';
import 'package:wsl2distromanager/screens/kubernetes_screen.dart';
import 'package:wsl2distromanager/screens/license_screen.dart';
import 'package:wsl2distromanager/screens/package_screen.dart';
import 'package:wsl2distromanager/screens/settings_screen.dart';
import 'package:wsl2distromanager/screens/template_screen.dart';
import 'package:wsl2distromanager/api/provisioning.dart';
import 'package:wsl2distromanager/screens/provisioning_screen.dart';

/// Go to the route called [name], asking the current screen first when it is
/// holding unsaved edits (audit ST-01).
///
/// Every in-app navigation that replaces the body goes through here; a bare
/// `router.pushNamed` bypasses the prompt and is what made Settings lose work.
Future<void> navigateGuarded(String name, {String? path}) =>
    navigateGuardedOn(router, name, path: path);

/// [navigateGuarded] against an explicit [target]; the app has one router,
/// tests build their own.
///
/// A pane destination *replaces* the page (`go`), it never pushes. Pushing
/// kept every page the user had ever switched away from alive underneath the
/// current one — a covered page is still `mounted` — so each visit to Home
/// left another 5 s instance poll spawning `wsl.exe` for the rest of the
/// session, and after an hour of clicking around a tab switch took seconds
/// (ai-tasks#26). Screens that are genuinely a step *into* something (the
/// snippet editor, the community browser, "add instance" from the list) still
/// push, and pop back to where they came from.
Future<void> navigateGuardedOn(GoRouter target, String name,
    {String? path}) async {
  if (path != null && target.state.uri.toString() == path) return;
  if (!await UnsavedChangesGuard.confirmLeave()) return;
  target.goNamed(name);
}

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Where a route belonging to [feature] sends the user while the feature is
/// off: home. The routes stay registered — a `redirect` rather than dropping
/// them, because it is re-evaluated on every navigation, while this router
/// is a top-level `final` whose route list would be built exactly once — so
/// a restored, hand-typed or deep-linked path to a switched-off destination
/// lands on the home screen instead of on the feature.
String? experimentalRedirect(ExperimentalFeature feature) =>
    ExperimentalFeatures.isVisible(feature) ? null : '/';

final _shellNavigatorKey = GlobalKey<NavigatorState>();
final router = GoRouter(
  navigatorKey: rootNavigatorKey,
  routes: [
    ShellRoute(
      observers: [PlausibleNavigatorObserver(plausible)],
      navigatorKey: _shellNavigatorKey,
      builder: (context, state, child) {
        return RootPage(
          key: GlobalVariable.root,
          shellContext: _shellNavigatorKey.currentContext,
          state: state,
          child: child,
        );
      },
      routes: [
        /// Home
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const HomePage(
            title: "WSL Manager",
          ),
        ),

        /// Settings
        GoRoute(
          path: '/settings',
          name: 'settings',
          builder: (context, state) => const SettingsPage(),
        ),

        /// Quick Actions
        GoRoute(
          path: '/quickactions',
          name: 'quickactions',
          builder: (context, state) => const QuickPage(),
        ),

        /// Snippet editor
        GoRoute(
          path: '/snippet',
          name: 'snippet',
          builder: (context, state) =>
              SnippetEditorPage(existing: state.extra as QuickActionItem?),
        ),

        /// Community scripts browser
        GoRoute(
          path: '/community',
          name: 'community',
          builder: (context, state) => const CommunityPage(),
        ),

        /// Playbooks: an instance's state as code, applied to existing
        /// instances (bostrot/ai-tasks#78)
        GoRoute(
          path: '/playbooks',
          name: 'playbooks',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.playbooks),
          builder: (context, state) => const PlaybooksPage(),
        ),

        /// Playbook editor — a step into one playbook, so a push.
        GoRoute(
          path: '/playbooks/edit',
          name: 'playbook-editor',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.playbooks),
          builder: (context, state) =>
              PlaybookEditorPage(existing: state.extra as Playbook?),
        ),

        /// Applying a playbook to an instance — pushed from the list. The
        /// playbook rides in `extra`, which a restored or hand-typed route
        /// does not carry: back to the list then, not a red screen.
        GoRoute(
          path: '/playbooks/apply',
          name: 'playbook-apply',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.playbooks) ??
              (state.extra is Playbook ? null : '/playbooks'),
          builder: (context, state) =>
              PlaybookApplyPage(playbook: state.extra as Playbook),
        ),

        /// Containers (Docker / Podman on the host)
        GoRoute(
          path: '/containers',
          name: 'containers',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.containers),
          builder: (context, state) => const ContainersPage(),
        ),

        /// Kubernetes (clusters from the host's kubeconfig)
        GoRoute(
          path: '/kubernetes',
          name: 'kubernetes',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.kubernetes),
          builder: (context, state) => const KubernetesPage(),
        ),

        /// Cloud servers at a provider (deploy an instance, pull it back)
        GoRoute(
          path: '/cloud',
          name: 'cloud',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.cloud),
          builder: (context, state) => const CloudPage(),
        ),

        /// Cloud-init configurations (bostrot/ai-tasks#76)
        GoRoute(
          path: '/cloudinit',
          name: 'cloudinit',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.cloudInit),
          builder: (context, state) => const CloudInitPage(),
        ),

        /// Cloud-init editor — a step into one configuration, so a push.
        GoRoute(
          path: '/cloudinit/edit',
          name: 'cloudinit-editor',
          redirect: (context, state) =>
              experimentalRedirect(ExperimentalFeature.cloudInit),
          builder: (context, state) =>
              CloudInitEditorPage(existing: state.extra as CloudInitConfig?),
        ),

        /// Templates
        GoRoute(
          path: '/templates',
          name: 'templates',
          builder: (context, state) => const TemplatePage(),
        ),

        /// License / Pro
        GoRoute(
          path: '/license',
          name: 'license',
          builder: (context, state) => const LicenseScreen(),
        ),

        /// AI Workspace
        GoRoute(
          path: '/ai-workspace',
          name: 'ai-workspace',
          builder: (context, state) => const AiWorkspacePage(),
        ),

        /// Create a new instance — a WSL distro when the active backend is
        /// WSL (Windows, Linux, or a Mac pointed at a remote target), a
        /// native VM otherwise.
        GoRoute(
          path: '/addinstance',
          name: 'addinstance',
          builder: (context, state) => vmBackend() is AppleVmApi
              ? const CreateVmPage()
              : const CreatePage(),
        ),

        /// Custom distro packaging (`.wsl`, wsl-distribution.conf)
        GoRoute(
          path: '/package',
          name: 'package',
          builder: (context, state) => const PackagePage(),
        ),
      ],
    ),
  ],
);
