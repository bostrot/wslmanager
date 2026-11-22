import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/panelist.dart';
import 'package:wsl2distromanager/screens/template_screen.dart';

import 'mocks.dart';
import 'vm_backend_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // The AI consent gate is answered here for the same reason the
    // experimental gate is: these assertions are about the *backend* gate,
    // and the consent gate has its own tests. Undecided hides the AI
    // Workspace entry outright, which is not what is under test.
    SharedPreferences.setMockInitialValues({AiService.enabledPrefKey: true});
    prefs = await SharedPreferences.getInstance();
    // Most of these assertions are about the *backend* gate; the unreleased
    // gate is exercised on its own below, so keep it out of the way here.
    ExperimentalFeatures.overrideAll = true;
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

  group('navigation follows the backend features', () {
    test('WSL backend shows every destination', () {
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      final keys = paneKeys();
      expect(keys, contains("[<'/quickactions'>]"));
      expect(keys, contains("[<'/templates'>]"));
      // The AI Workspace needs a local wsl.exe, so its entry follows the
      // host platform even on the WSL backend.
      expect(keys.contains("[<'/ai-workspace'>]"), Platform.isWindows);
      expect(keys, contains("[<'/package'>]"));
      expect(keys, contains("[<'/addinstance'>]"));
    });

    test('Kubernetes is offered on every backend', () {
      // kubectl runs on the host, not inside a distro or a VM, so the
      // destination is the same on Windows and macOS (bostrot/ai-tasks#61).
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      expect(paneKeys(), contains("[<'/kubernetes'>]"));
      vmBackendBuilder = FakeBackend.new;
      expect(paneKeys(), contains("[<'/kubernetes'>]"));
    });

    test('Cloud follows the backend that can export a root filesystem', () {
      // Unlike Kubernetes, this destination is gated: the deploy needs an
      // instance the backend can hand over as a rootfs tarball, and a Cloud
      // screen that cannot deploy is a server list with a delete button — a
      // second control panel for somebody else's product
      // (bostrot/ai-tasks#62).
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      expect(vmBackend().features.rootfsExport, isTrue);
      expect(paneKeys(), contains("[<'/cloud'>]"));
      vmBackendBuilder = FakeBackend.new;
      expect(vmBackend().features.rootfsExport, isFalse);
      expect(paneKeys(), isNot(contains("[<'/cloud'>]")));
    });

    test('Cloud is offered on the Apple backend too', () {
      // `vmctl export` hands out a raw disk, but the backend can still read a
      // root filesystem out of the running guest, so the destination is not
      // Windows-only — and the pull-back there needs a local base to restore
      // onto, which the dialog wording depends on.
      vmBackendBuilder = () => AppleVmApi(
            helperPathOverride: '/fake/vmctl',
            storeDirOverride:
                Directory.systemTemp.createTempSync('cloud-gating').path,
          );
      expect(vmBackend().features.rootfsExport, isTrue);
      expect(vmBackend().features.rootfsImportNeedsBase, isTrue);
      expect(paneKeys(), contains("[<'/cloud'>]"));
    });

    test('Containers, Kubernetes and Cloud are hidden until switched on', () {
      // Each drives something this app does not own and none is finished
      // enough to release, so all three sit behind their experimental
      // switches — including on the backend that satisfies every other
      // condition for them. The override stands in for all the switches.
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      ExperimentalFeatures.overrideAll = false;
      final hidden = paneKeys();
      expect(hidden, isNot(contains("[<'/containers'>]")));
      expect(hidden, isNot(contains("[<'/kubernetes'>]")));
      expect(hidden, isNot(contains("[<'/cloud'>]")));
      // The shipping destinations are untouched by it.
      expect(hidden, contains("[<'/templates'>]"));
      expect(hidden, contains("[<'/addinstance'>]"));

      ExperimentalFeatures.overrideAll = true;
      final shown = paneKeys();
      expect(shown, contains("[<'/containers'>]"));
      expect(shown, contains("[<'/kubernetes'>]"));
      expect(shown, contains("[<'/cloud'>]"));
    });

    test('the switches default to the same answer the Pro debug gate gives',
        () {
      // Not hard-coded to false: under `flutter test` the Pro debug gate is
      // deliberately off, and with no choice stored the experimental
      // features follow it rather than carrying a second rule of their own
      // (bostrot/ai-tasks#87; the switches themselves are covered in
      // experimental_features_test.dart).
      ExperimentalFeatures.overrideAll = null;
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      expect(ExperimentalFeatures.isEnabled(ExperimentalFeature.containers),
          LicenseManager().isPro);
      expect(paneKeys(), isNot(contains("[<'/containers'>]")));
    });

    test('a backend without WSL features hides the WSL-only entries', () {
      vmBackendBuilder = FakeBackend.new;
      final keys = paneKeys();
      expect(keys, isNot(contains("[<'/quickactions'>]")));
      expect(keys, isNot(contains("[<'/ai-workspace'>]")));
      expect(keys, isNot(contains("[<'/package'>]")));
      // Templates and create stay: they are first-class on every backend.
      expect(keys, contains("[<'/templates'>]"));
      expect(keys, contains("[<'/addinstance'>]"));
    });
  });

  group('beta markers in the pane', () {
    Widget? badgeFor(String path) {
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      final item = originalItems
          .whereType<PaneItem>()
          .firstWhere((item) => item.key == Key(path));
      return item.infoBadge;
    }

    test('distro packaging is marked beta like the AI Workspace', () {
      // `.wsl` packaging ships before it is fully polished, so the pane says
      // so where the user picks the destination (bostrot/ai-tasks#36).
      expect(badgeFor('/package'), isA<BetaPaneBadge>());
    });

    test('the settled destinations carry no badge', () {
      // The marker only means something while it is rare.
      expect(badgeFor('/templates'), isNull);
      expect(badgeFor('/addinstance'), isNull);
      expect(badgeFor('/'), isNull);
    });

    test('the AI Workspace keeps its badge', () {
      // Its entry is Windows-only (it needs a local wsl.exe), so there is
      // nothing to assert about it elsewhere.
      if (!Platform.isWindows) return;
      expect(badgeFor('/ai-workspace'), isA<BetaPaneBadge>());
    });
  });

  group('templates deprecation banner', () {
    late Directory dataDir;

    setUp(() async {
      dataDir = Directory.systemTemp.createTempSync('tpl-ui-test');
      await prefs.setString('DataPath', dataDir.path);
      Directory('${dataDir.path}/templates').createSync();
    });

    tearDown(() {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const FluentApp(home: TemplatePage()));
      await tester.pump();
    }

    testWidgets('shown on the WSL backend, which has distro packages',
        (tester) async {
      File('${dataDir.path}/templates/base.ext4').writeAsStringSync('x');
      await prefs.setStringList('templates', ['base']);
      vmBackendBuilder = () => WSLApi(shell: MockShell());

      await pump(tester);
      expect(
          find.byKey(const ValueKey('test-templates-deprecated')), findsOneWidget);
    });

    testWidgets('hidden on the Apple backend, where templates stay first-class',
        (tester) async {
      File('${dataDir.path}/templates/base.img').writeAsStringSync('x');
      await prefs.setStringList('templates', ['base']);
      vmBackendBuilder = () => AppleVmApi(
            helperPathOverride: '/fake/vmctl',
            storeDirOverride: '${dataDir.path}/vms',
          );

      await pump(tester);
      // The list itself renders (the template was adopted from disk) ...
      expect(find.textContaining('base'), findsWidgets);
      // ... but no deprecation banner.
      expect(
          find.byKey(const ValueKey('test-templates-deprecated')), findsNothing);
    });
  });
}
