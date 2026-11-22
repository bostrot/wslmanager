import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/containers/container_service.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/cloud_init_picker.dart';
import 'package:wsl2distromanager/components/experimental_features_section.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/panelist.dart';
import 'package:wsl2distromanager/nav/router.dart';

import 'fake_container_shell.dart';
import 'vm_backend_test.dart' show FakeBackend;

/// A backend that can carry every experimental feature, whatever the host:
/// the *backend* gates are covered in vm_ui_gating_test.dart; here only the
/// switches are under test.
class _EverythingBackend extends FakeBackend {
  @override
  VmFeatures get features => const VmFeatures(
        quickActions: true,
        rootfsExport: true,
        cloudInit: true,
      );
}

/// The experimental features (bostrot/ai-tasks#87): Containers, Kubernetes,
/// Cloud, cloud-init and Playbooks used to be visible in a debug run only;
/// now each has its own opt-in switch in Settings, and everything that
/// surfaces one of them — the pane, the router, the MCP tool families, the
/// create pages' cloud-init picker — follows that switch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    vmBackendBuilder = _EverythingBackend.new;
    ExperimentalFeatures.overrideAll = null;
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
    ExperimentalFeatures.overrideAll = null;
  });

  Set<String> paneKeys() => originalItems
      .map((item) => item.key)
      .whereType<Key>()
      .map((key) => key.toString())
      .toSet();

  group('the switches', () {
    test('every feature is off until the user switches it on', () {
      // Under `flutter test` the debug rule is deliberately off, so with no
      // decision stored the answer is the shipped one.
      expect(LicenseManager.isDebugRun, isFalse);
      for (final feature in ExperimentalFeature.values) {
        expect(ExperimentalFeatures.isEnabled(feature), isFalse,
            reason: '$feature should be off by default');
        expect(prefs.getBool(feature.prefKey), isNull,
            reason: 'nothing is written until the user decides');
      }
    });

    test('each switch is its own pref and moves only its own feature', () {
      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, true);
      expect(prefs.getBool('ExperimentalKubernetes'), isTrue);
      expect(ExperimentalFeatures.isEnabled(ExperimentalFeature.kubernetes),
          isTrue);
      for (final other in ExperimentalFeature.values) {
        if (other == ExperimentalFeature.kubernetes) continue;
        expect(ExperimentalFeatures.isEnabled(other), isFalse,
            reason: '$other must not follow the Kubernetes switch');
      }

      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, false);
      expect(ExperimentalFeatures.isEnabled(ExperimentalFeature.kubernetes),
          isFalse);
    });

    test('a flip moves the generation and is announced, a no-op flip is not',
        () {
      var fired = 0;
      void listener() => fired++;
      ExperimentalFeatures.generation.addListener(listener);
      addTearDown(
          () => ExperimentalFeatures.generation.removeListener(listener));
      final start = ExperimentalFeatures.generation.value;

      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, true);
      expect(fired, 1);
      expect(ExperimentalFeatures.generation.value, start + 1);
      // Already on: nothing moved, so the shell has nothing to rebuild for.
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, true);
      expect(fired, 1);
      expect(ExperimentalFeatures.generation.value, start + 1);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, false);
      expect(fired, 2);
      expect(ExperimentalFeatures.generation.value, start + 2);
    });

    test('a flip is stored even while the test override reads the other way',
        () {
      // setEnabled compares against the stored choice, not the effective
      // value: with the override forcing "on", switching on must still be
      // written, or the pref would be left behind the switch.
      ExperimentalFeatures.overrideAll = true;
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, false);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, true);
      expect(prefs.getBool(ExperimentalFeature.cloud.prefKey), isTrue);
    });

    test('the test override wins over the stored choice, both ways', () {
      prefs.setBool(ExperimentalFeature.containers.prefKey, true);
      ExperimentalFeatures.overrideAll = false;
      expect(ExperimentalFeatures.isEnabled(ExperimentalFeature.containers),
          isFalse);
      ExperimentalFeatures.overrideAll = true;
      expect(ExperimentalFeatures.isEnabled(ExperimentalFeature.playbooks),
          isTrue);
    });

    test('a feature the backend cannot carry is never visible', () {
      vmBackendBuilder = FakeBackend.new;
      final bare = FakeBackend();
      for (final feature in [
        ExperimentalFeature.cloud,
        ExperimentalFeature.cloudInit,
        ExperimentalFeature.playbooks,
      ]) {
        ExperimentalFeatures.setEnabled(feature, true);
        expect(feature.offeredBy(bare), isFalse);
        expect(ExperimentalFeatures.isVisible(feature), isFalse,
            reason: 'the switch alone cannot show $feature');
        // The backend in hand counts, not the active one.
        expect(
            ExperimentalFeatures.isVisible(feature,
                backend: _EverythingBackend()),
            isTrue);
      }
      // The host-side ones are carried by every backend.
      expect(ExperimentalFeature.containers.offeredBy(bare), isTrue);
      expect(ExperimentalFeature.kubernetes.offeredBy(bare), isTrue);
    });
  });

  group('the nav pane', () {
    test('shows exactly the destinations that are switched on', () {
      final off = paneKeys();
      expect(off, isNot(contains("[<'/containers'>]")));
      expect(off, isNot(contains("[<'/kubernetes'>]")));
      expect(off, isNot(contains("[<'/cloud'>]")));
      expect(off, isNot(contains("[<'/cloudinit'>]")));
      expect(off, isNot(contains("[<'/playbooks'>]")));
      // The shipping destinations are untouched by the switches.
      expect(off, contains("[<'/templates'>]"));
      expect(off, contains("[<'/addinstance'>]"));

      ExperimentalFeatures.setEnabled(ExperimentalFeature.playbooks, true);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloudInit, true);
      final some = paneKeys();
      expect(some, contains("[<'/playbooks'>]"));
      expect(some, contains("[<'/cloudinit'>]"));
      expect(some, isNot(contains("[<'/containers'>]")));
      expect(some, isNot(contains("[<'/kubernetes'>]")));
      expect(some, isNot(contains("[<'/cloud'>]")));
    });
  });

  group('the router', () {
    test(
        'sends a switched-off destination home and lets one that is on through',
        () {
      expect(experimentalRedirect(ExperimentalFeature.containers), '/');
      ExperimentalFeatures.setEnabled(ExperimentalFeature.containers, true);
      expect(experimentalRedirect(ExperimentalFeature.containers), isNull);
      // On, but not carried by this backend: home as well, like the pane.
      vmBackendBuilder = FakeBackend.new;
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, true);
      expect(experimentalRedirect(ExperimentalFeature.cloud), '/');
    });
  });

  group('the MCP tool families', () {
    List<String> toolNames() {
      final backend = _EverythingBackend();
      return buildWslMcpTools(
        backend,
        WslTerminalManager(wslApi: backend),
        containerService:
            ContainerService(shell: FakeContainerShell(), isWindows: false),
      ).map((t) => t.name).toList();
    }

    test('each family follows its own switch', () {
      final none = toolNames();
      expect(none.where((n) => n.startsWith('container_')), isEmpty);
      expect(none.where((n) => n.startsWith('kube_')), isEmpty);
      expect(none.where((n) => n.startsWith('cloud_')), isEmpty);
      expect(none, contains('wsl_list_distros'));

      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, true);
      final kube = toolNames();
      expect(kube, contains('kube_contexts'));
      expect(kube.where((n) => n.startsWith('container_')), isEmpty);
      expect(kube.where((n) => n.startsWith('cloud_')), isEmpty);

      ExperimentalFeatures.setEnabled(ExperimentalFeature.containers, true);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, true);
      final all = toolNames();
      expect(all, contains('container_list'));
      expect(all, contains('kube_contexts'));
      expect(all, contains('cloud_servers'));
    });
  });

  group('the assistant', () {
    test('rebuilds its tool list after a flip', () {
      // The list is cached for the process, so without this a switch made
      // after the first message would leave the prompt and the tools
      // disagreeing about which families exist.
      final ai = AiService();
      expect(ai.tools.map((t) => t.name), isNot(contains('kube_contexts')));
      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, true);
      expect(ai.tools.map((t) => t.name), contains('kube_contexts'));
      ExperimentalFeatures.setEnabled(ExperimentalFeature.kubernetes, false);
      expect(ai.tools.map((t) => t.name), isNot(contains('kube_contexts')));
      expect(ai.tools.map((t) => t.name), contains('wsl_list_distros'));
    });

    test('keeps its terminal manager across a rebuild', () {
      // The wsl_terminal_* session ids the model holds live in the manager,
      // so a rebuilt list must be wired to the same one.
      final ai = AiService();
      McpTool terminalList() =>
          ai.tools.firstWhere((t) => t.name == 'wsl_terminal_list');
      final before = terminalList();
      final manager = ai.terminalManagerForTesting;
      expect(manager, isNotNull);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, true);
      final after = terminalList();
      expect(identical(before, after), isFalse, reason: 'the list was rebuilt');
      expect(identical(ai.terminalManagerForTesting, manager), isTrue);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, false);
    });

    test('keeps a list handed to it whatever the switches do', () {
      // A scoped conversation and a test pass their own list; a flip must
      // not swap it for the registry.
      final ai = AiService();
      ai.toolsForTesting = const [];
      ExperimentalFeatures.setEnabled(ExperimentalFeature.containers, true);
      expect(ai.tools, isEmpty);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.containers, false);
    });
  });

  group('the Settings section', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const FluentApp(
        home: ScaffoldPage(content: ExperimentalFeaturesSection()),
      ));
    }

    testWidgets('offers one switch per feature the backend can carry',
        (tester) async {
      await pump(tester);
      for (final feature in ExperimentalFeature.values) {
        expect(find.byKey(ExperimentalFeaturesSection.switchKey(feature)),
            findsOneWidget,
            reason: '$feature should have a switch');
      }
    });

    testWidgets('leaves out the switches for what the backend cannot carry',
        (tester) async {
      vmBackendBuilder = FakeBackend.new;
      await pump(tester);
      expect(
          find.byKey(ExperimentalFeaturesSection.switchKey(
              ExperimentalFeature.containers)),
          findsOneWidget);
      expect(
          find.byKey(
              ExperimentalFeaturesSection.switchKey(ExperimentalFeature.cloud)),
          findsNothing);
      expect(
          find.byKey(ExperimentalFeaturesSection.switchKey(
              ExperimentalFeature.playbooks)),
          findsNothing);
    });

    testWidgets('keeps the switch for a feature that is on but not offered',
        (tester) async {
      // Cloud switched on on a backend that could deploy, then a backend
      // that cannot: the pane entry is gone, but the way back is not.
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloud, true);
      vmBackendBuilder = FakeBackend.new;
      await pump(tester);
      final key =
          ExperimentalFeaturesSection.switchKey(ExperimentalFeature.cloud);
      expect(find.byKey(key), findsOneWidget);
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(prefs.getBool(ExperimentalFeature.cloud.prefKey), isFalse);
      // Off and not offered: now it goes.
      expect(find.byKey(key), findsNothing);
    });

    testWidgets('a tap stores the choice, shows it and announces it',
        (tester) async {
      var announced = 0;
      void listener() => announced++;
      ExperimentalFeatures.generation.addListener(listener);
      addTearDown(
          () => ExperimentalFeatures.generation.removeListener(listener));
      await pump(tester);
      final key =
          ExperimentalFeaturesSection.switchKey(ExperimentalFeature.cloudInit);
      expect(tester.widget<ToggleSwitch>(find.byKey(key)).checked, isFalse);

      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(tester.widget<ToggleSwitch>(find.byKey(key)).checked, isTrue);
      expect(prefs.getBool(ExperimentalFeature.cloudInit.prefKey), isTrue);
      expect(announced, 1);
      expect(paneKeys(), contains("[<'/cloudinit'>]"));

      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
      expect(tester.widget<ToggleSwitch>(find.byKey(key)).checked, isFalse);
      expect(prefs.getBool(ExperimentalFeature.cloudInit.prefKey), isFalse);
      expect(announced, 2);
    });

    testWidgets('a flip made elsewhere shows up without a tap', (tester) async {
      // The section rebuilds on the generation like the shell does, so a
      // switch moved by anything else is not shown stale.
      await pump(tester);
      final key =
          ExperimentalFeaturesSection.switchKey(ExperimentalFeature.playbooks);
      ExperimentalFeatures.setEnabled(ExperimentalFeature.playbooks, true);
      await tester.pumpAndSettle();
      expect(tester.widget<ToggleSwitch>(find.byKey(key)).checked, isTrue);
    });
  });

  group('the cloud-init picker on the create pages', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: CloudInitPicker(
            value: '',
            hint: 'hint',
            onChanged: (_) {},
          ),
        ),
      ));
    }

    testWidgets('is not offered while cloud-init is switched off',
        (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('test-create-cloudinit')), findsNothing);
      expect(find.byKey(const ValueKey('test-create-cloudinit-new')),
          findsNothing);
    });

    testWidgets('is offered once it is switched on', (tester) async {
      ExperimentalFeatures.setEnabled(ExperimentalFeature.cloudInit, true);
      await pump(tester);
      expect(
          find.byKey(const ValueKey('test-create-cloudinit')), findsOneWidget);
    });
  });
}
