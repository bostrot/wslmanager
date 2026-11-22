import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/apple/vm_image_catalog.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/api/recipes/recipe_service.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/create_vm_screen.dart';

import 'fake_vmctl_shell.dart';

/// A catalog whose network is a canned resolution and an instant "download".
class _FakeCatalog implements VmImageCatalog {
  _FakeCatalog(this.dataDir, {this.failWith});
  final Directory dataDir;
  final Object? failWith;
  final List<String> downloaded = [];

  @override
  Future<String> download(VmIsoCatalogEntry entry,
      {void Function(int, int)? onProgress,
      CancelSignal? cancelSignal}) async {
    if (failWith != null) throw failWith!;
    onProgress?.call(50, 100);
    downloaded.add(entry.name);
    final path = '${dataDir.path}/isos/${entry.name}.iso';
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1]);
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;
  late FakeVmctlShell shell;
  late _FakeCatalog catalog;
  late List<String> messages;

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      messages.add(msg.toString());
    };
  });

  setUp(() async {
    messages = [];
    dataDir = Directory.systemTemp.createTempSync('create-vm-screen-test');
    // The cloud-init picker follows its switch in Settings
    // (bostrot/ai-tasks#87); the page's cloud-init tests need it on.
    SharedPreferences.setMockInitialValues({
      'DataPath': dataDir.path,
      ExperimentalFeature.cloudInit.prefKey: true,
    });
    prefs = await SharedPreferences.getInstance();
    shell = FakeVmctlShell();
    shell.responses['list'] = '{"vms":[]}';
    CloudInitStore.instance.reload();
    catalog = _FakeCatalog(dataDir);
    appleVmApiBuilder = () => AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '${dataDir.path}/vms',
          earlyExitProbeDelay: Duration.zero,
        );
    vmImageCatalogBuilder = () => catalog;
    // The picker asks the active backend whether it carries cloud-init. On a
    // Windows test host the default would be a WSLApi, whose constructor
    // fetches the distro catalogue and leaves a timer pending.
    vmBackendBuilder = appleVmApiBuilder;
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
    appleVmApiBuilder = () {
      final backend = AppleVmApi();
      return backend;
    };
    vmImageCatalogBuilder = VmImageCatalog.new;
    CloudInitStore.instance.reload();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        const FluentApp(home: ScaffoldPage(content: CreateVmPage())));
    await tester.pump();
  }

  /// The page opens on the cloud-image choice; this flips it to the ISO one.
  Future<void> chooseInstallerIso(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-vm-boot-installer-iso')));
    await tester.pumpAndSettle();
  }

  List<String> suggestionsOf(WidgetTester tester, String key) {
    final box = tester.widget<AutoSuggestBox<String>>(find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(AutoSuggestBox<String>)));
    return box.items.map((item) => item.label).toList();
  }

  final cloudImageNames = VmImageCatalog.entries
      .where((e) => e.isCloudImage)
      .map((e) => e.name)
      .toList();
  final isoNames = VmImageCatalog.entries
      .where((e) => !e.isCloudImage)
      .map((e) => e.name)
      .toList();

  testWidgets('the page opens on the cloud-image choice, listing only those',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('test-vm-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-vm-iso')), findsNothing);

    // bostrot/ai-tasks#5: cloud images and ISOs used to share one list.
    final labels = suggestionsOf(tester, 'test-vm-image');
    expect(labels, unorderedEquals(cloudImageNames));
    expect(cloudImageNames, isNotEmpty);
  });

  testWidgets('the installer-ISO choice swaps in a field listing only ISOs',
      (tester) async {
    await pump(tester);
    await chooseInstallerIso(tester);
    expect(find.byKey(const ValueKey('test-vm-iso')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-vm-image')), findsNothing);

    final labels = suggestionsOf(tester, 'test-vm-iso');
    expect(labels, unorderedEquals(isoNames));
    for (final name in cloudImageNames) {
      expect(labels, isNot(contains(name)),
          reason: 'a cloud image is not an installer');
    }
  });

  testWidgets('switching the choice keeps what was typed under each',
      (tester) async {
    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-image')), '/tmp/local.raw');
    await chooseInstallerIso(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-iso')), '/tmp/local.iso');

    await tester.tap(find.byKey(const ValueKey('test-vm-boot-cloud-image')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<AutoSuggestBox<String>>(find.descendant(
                of: find.byKey(const ValueKey('test-vm-image')),
                matching: find.byType(AutoSuggestBox<String>)))
            .controller
            ?.text,
        '/tmp/local.raw');

    await chooseInstallerIso(tester);
    expect(
        tester
            .widget<AutoSuggestBox<String>>(find.descendant(
                of: find.byKey(const ValueKey('test-vm-iso')),
                matching: find.byType(AutoSuggestBox<String>)))
            .controller
            ?.text,
        '/tmp/local.iso');
  });

  testWidgets('clicking the boot-source box lists the catalog before typing',
      (tester) async {
    await pump(tester);
    // Settle past fluent_ui's first-frame overlay reset.
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('test-vm-image'));
    final box = find.descendant(
        of: field, matching: find.byType(AutoSuggestBox<String>));
    expect(tester.state<AutoSuggestBoxState<String>>(box).isOverlayVisible,
        isFalse);

    await tester.tap(field);
    await tester.pumpAndSettle();

    // bostrot/ai-tasks#4: the list used to stay hidden until a keystroke.
    expect(tester.state<AutoSuggestBoxState<String>>(box).isOverlayVisible,
        isTrue);
    for (final name in cloudImageNames) {
      // The popup lives in the root overlay behind a transform follower,
      // which the default on-stage walk skips.
      expect(find.text(name, skipOffstage: false), findsOneWidget,
          reason: '$name should be listed');
    }
    for (final name in isoNames) {
      expect(find.text(name, skipOffstage: false), findsNothing,
          reason: '$name is an installer, not a cloud image');
    }
  });

  testWidgets('a Linux VM with no ISO and no image is refused', (tester) async {
    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    // No cloud image chosen.
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-vm-boot-error')), findsOneWidget);
    expect(shell.calls.any((c) => c.contains('create')), isFalse,
        reason: 'a VM that could only fail must never reach vmctl');
    expect(catalog.downloaded, isEmpty);
  });

  testWidgets('a guest account name useradd would refuse never reaches vmctl',
      (tester) async {
    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-user')), 'Eric Trenkel');
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-vm-user-error')), findsOneWidget);
    // Refused here rather than by the helper: the name reaches an ssh
    // target and the .command script Terminal opens.
    expect(shell.calls.any((c) => c.contains('create')), isFalse);
  });

  testWidgets('a valid account name is passed through untouched',
      (tester) async {
    shell.exitCodes['create'] = 1;
    shell.errors['create'] = 'refused by test';
    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-user')), 'eric_2');
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-image')), '/tmp/local.img');
    // Let the open suggestion list shrink to "no results" first.
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-vm-user-error')), findsNothing);
    final create = shell.calls.lastWhere((c) => c.contains('create'));
    expect(create[create.indexOf('--user') + 1], 'eric_2');
  });

  testWidgets('switching the choice clears a stale boot-source error',
      (tester) async {
    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-vm-boot-error')), findsOneWidget);

    await chooseInstallerIso(tester);
    expect(find.byKey(const ValueKey('test-vm-boot-error')), findsNothing,
        reason: 'the complaint was about the cloud-image field');
  });

  testWidgets('only the chosen boot source counts', (tester) async {
    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    // An ISO typed under the installer choice, then back to the (empty)
    // cloud-image choice: the ISO must not be silently used.
    await chooseInstallerIso(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-iso')), '/tmp/local.iso');
    await tester.tap(find.byKey(const ValueKey('test-vm-boot-cloud-image')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-vm-boot-error')), findsOneWidget);
    expect(shell.calls.any((c) => c.contains('create')), isFalse);
  });

  testWidgets('a catalog pick is downloaded and its local path used',
      (tester) async {
    // Creation itself fails, keeping the test off the router; the wiring
    // under test is catalog → download → create arguments.
    shell.exitCodes['create'] = 1;
    shell.errors['create'] = 'refused by test';

    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await chooseInstallerIso(tester);
    await tester.enterText(find.byKey(const ValueKey('test-vm-iso')),
        'Alpine Linux (virt)');
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    expect(catalog.downloaded, ['Alpine Linux (virt)']);
    final createCall = shell.calls.lastWhere((c) => c.contains('create'));
    final isoArg = createCall[createCall.indexOf('--iso') + 1];
    expect(isoArg, endsWith('Alpine Linux (virt).iso'),
        reason: 'the backend must get the cached file, not the catalog name');
  });

  testWidgets('a cloud-image pick seeds the disk instead of attaching an ISO',
      (tester) async {
    shell.exitCodes['create'] = 1;
    shell.errors['create'] = 'refused by test';

    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await tester.enterText(find.byKey(const ValueKey('test-vm-image')),
        'Debian 13 (cloud image)');
    // Focusing the box opened the full suggestion list, which is tall enough
    // to reach the create button; a frame lets it filter down to the match.
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    final createCall = shell.calls.lastWhere((c) => c.contains('create'));
    expect(createCall, contains('--image'));
    expect(createCall[createCall.indexOf('--image') + 1],
        endsWith('Debian 13 (cloud image).iso'),
        reason: 'the downloaded file must seed the disk');
    expect(createCall.contains('--iso'), isFalse,
        reason: 'a cloud image is not an installer to attach');
  });

  testWidgets('a plain ISO path skips the catalog entirely', (tester) async {
    shell.exitCodes['create'] = 1;
    shell.errors['create'] = 'refused by test';

    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await chooseInstallerIso(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-iso')), '/tmp/local.iso');
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    expect(catalog.downloaded, isEmpty);
    final createCall = shell.calls.lastWhere((c) => c.contains('create'));
    expect(createCall[createCall.indexOf('--iso') + 1], '/tmp/local.iso');
    expect(createCall.contains('--image'), isFalse);
  });

  testWidgets('a local disk image path seeds the disk', (tester) async {
    shell.exitCodes['create'] = 1;
    shell.errors['create'] = 'refused by test';

    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-image')), '/tmp/template.raw');
    // As above: let the open suggestion list shrink to "no results" first.
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    expect(catalog.downloaded, isEmpty);
    final createCall = shell.calls.lastWhere((c) => c.contains('create'));
    expect(createCall[createCall.indexOf('--image') + 1], '/tmp/template.raw');
    expect(createCall.contains('--iso'), isFalse);
  });

  testWidgets('a chosen service is queued as pending for first run',
      (tester) async {
    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'dbvm');
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-image')), '/tmp/local.raw');
    // Focusing the box opens its catalog popup over the fields below; a
    // frame lets it shrink to the typed path (no match) before the click.
    await tester.pumpAndSettle();

    // Pick Postgres from the service dropdown.
    await tester.tap(find.byKey(const ValueKey('test-vm-recipe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PostgreSQL — PostgreSQL 16 database server.').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    // The VM was created and the recipe queued to install on first run.
    expect(shell.calls.any((c) => c.contains('create')), isTrue);
    expect(prefs.getString(RecipeService.pendingKey('dbvm')), 'postgres');
  });

  testWidgets('a failed download stops the create and re-enables the form',
      (tester) async {
    catalog = _FakeCatalog(dataDir, failWith: Exception('mirror down'));
    vmImageCatalogBuilder = () => catalog;

    await pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-vm-name')), 'demo');
    await chooseInstallerIso(tester);
    await tester.enterText(find.byKey(const ValueKey('test-vm-iso')),
        'Alpine Linux (virt)');
    await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    await tester.pumpAndSettle();

    // No create reached the helper, and the button is usable again.
    expect(shell.calls.where((c) => c.contains('create')), isEmpty);
    final button =
        find.byKey(const ValueKey('test-vm-create-button'));
    expect(tester.widget<Button>(find.descendant(
                of: button, matching: find.byWidgetPredicate((w) => w is Button))
            .first)
        .onPressed, isNotNull);
  });

  group('macOS create progress', () {
    /// Selects the macOS guest and names the VM; a macOS guest needs no
    /// boot source, the helper downloads a restore image when none is given.
    Future<void> fillMacosForm(WidgetTester tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('test-vm-guest-os')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('macOS').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('test-vm-name')), 'sequoia');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('test-vm-create-button')));
      await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
    }

    String progressText(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('test-vm-create-progress')))
        .data!;

    testWidgets('each step the helper reports reaches the page and the bar',
        (tester) async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] =
          'progress {"fraction":0.5,"phase":"download","received":1048576,'
          '"total":2097152}\n';
      // The helper stays alive: a create that has already returned has
      // nothing left to report, which is exactly the old behaviour
      // (bostrot/ai-tasks#100).
      shell.startDelay = const Duration(seconds: 2);

      await fillMacosForm(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(progressText(tester), contains('50%'));
      expect(progressText(tester), contains('1.0 MB / 2.0 MB'));
      expect(progressText(tester), contains('vmcreatedownload-text'));
      expect(
          tester
              .widget<ProgressBar>(
                  find.byKey(const ValueKey('test-vm-create-progress-bar')))
              .value,
          50.0);
      // The status bar says the same thing: the user does not have to stay
      // on this page to see where the install is.
      expect(messages.last, contains('50%'));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-vm-create-progress')), findsNothing);
    });

    testWidgets('a step that cannot say how far it is still says what it is',
        (tester) async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] = 'progress {"phase":"lookup"}\n';
      shell.startDelay = const Duration(seconds: 2);

      await fillMacosForm(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(progressText(tester), 'vmcreatelookup-text');
      expect(
          tester
              .widget<ProgressBar>(
                  find.byKey(const ValueKey('test-vm-create-progress-bar')))
              .value,
          isNull,
          reason: 'an indeterminate step gets an indeterminate bar');

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    /// The helper the app runs is whatever is installed, and a rebuilt app
    /// does not rebuild it (bostrot/ai-tasks#100): the page has to move on
    /// a helper that reports no steps at all, or the whole hour looks the
    /// way it did before this feature existed.
    testWidgets('a helper that reports no steps still shows what it printed',
        (tester) async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] =
          'downloading restore image from https://example.invalid/r.ipsw\n';
      shell.startDelay = const Duration(seconds: 2);

      await fillMacosForm(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(progressText(tester),
          'downloading restore image from https://example.invalid/r.ipsw');
      expect(messages.last, contains('example.invalid'));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('a step and a printed line are shown one under the other',
        (tester) async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] =
          'downloading restore image from https://example.invalid/r.ipsw\n'
          'progress {"fraction":0.5,"phase":"download"}\n';
      shell.startDelay = const Duration(seconds: 2);

      await fillMacosForm(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(progressText(tester), contains('vmcreatedownload-text'));
      expect(
          tester
              .widget<Text>(
                  find.byKey(const ValueKey('test-vm-create-detail')))
              .data,
          contains('example.invalid'));
      // Once a step is known the status bar says that, not the line.
      expect(messages.last, contains('vmcreatedownload-text'));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('a line from an earlier step does not follow the next one',
        (tester) async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] =
          'downloading restore image from https://example.invalid/r.ipsw\n'
          'progress {"fraction":1,"phase":"download"}\n'
          'progress {"phase":"install","fraction":0.1}\n';
      shell.startDelay = const Duration(seconds: 2);

      await fillMacosForm(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(progressText(tester), contains('vmcreateinstall-text'));
      expect(find.byKey(const ValueKey('test-vm-create-detail')), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('a download of unknown length shows the bytes so far',
        (tester) async {
      shell.responses['create'] = '{"created":"sequoia"}';
      shell.errors['create'] =
          'progress {"phase":"download","received":1048576}\n';
      shell.startDelay = const Duration(seconds: 2);

      await fillMacosForm(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(progressText(tester), 'vmcreatedownload-text 1.0 MB');
      expect(
          tester
              .widget<ProgressBar>(
                  find.byKey(const ValueKey('test-vm-create-progress-bar')))
              .value,
          isNull);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('a failed create keeps the helper\'s words on the page',
        (tester) async {
      shell.exitCodes['create'] = 1;
      shell.errors['create'] = 'progress {"phase":"prepare"}\n'
          'macOS installation failed: no space left on device\n';

      await fillMacosForm(tester);
      await tester.pumpAndSettle();

      // The status bar clears itself after a few seconds; an install that
      // failed at minute fifty must leave something to read.
      await tester.pump(const Duration(seconds: 30));
      final banner = find.byKey(const ValueKey('test-vm-create-error'));
      expect(banner, findsOneWidget);

      // The helper's own words are a fold away, the way every other error
      // surface in the app carries them.
      await tester.tap(find.descendant(
          of: banner,
          matching: find.byKey(const ValueKey('test-error-details-toggle'))));
      await tester.pumpAndSettle();
      expect(
          find.descendant(
              of: banner,
              matching: find.text(
                  'macOS installation failed: no space left on device')),
          findsOneWidget);
      // The progress line it failed on is not part of the complaint.
      expect(find.textContaining('progress {'), findsNothing);
      expect(find.byKey(const ValueKey('test-vm-create-progress')), findsNothing);
    });
  });

  group('cloud-init', () {
    testWidgets('the picker is offered for a Linux guest and not for macOS',
        (tester) async {
      await pump(tester);
      expect(find.byKey(const ValueKey('test-create-cloudinit')), findsOneWidget);
      expect(find.text('cloudinitvmhint-text'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('test-vm-guest-os')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('macOS').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-create-cloudinit')), findsNothing);
    });

    testWidgets('the picker goes with the installer-ISO choice, which reads no seed',
        (tester) async {
      await pump(tester);
      await chooseInstallerIso(tester);
      expect(find.byKey(const ValueKey('test-create-cloudinit')), findsNothing);
    });

    testWidgets('a configuration deleted since it was picked stops the create',
        (tester) async {
      await CloudInitStore.instance.save(
          const CloudInitConfig(name: 'dev', content: '#cloud-config\n'));
      shell.responses['create'] = '{"created":"box"}';
      await pump(tester);
      await tester.enterText(
          find.byKey(const ValueKey('test-vm-image')), '/tmp/local.raw');
      await tester.enterText(find.byKey(const ValueKey('test-vm-name')), 'box');
      await tester.pumpAndSettle();
      tester
          .widget<ComboBox<String>>(
              find.byKey(const ValueKey('test-create-cloudinit')))
          .onChanged!('dev');
      await tester.pump();
      await CloudInitStore.instance.remove('dev');
      await tester.pump();
      await tester.ensureVisible(
          find.byKey(const ValueKey('test-vm-create-button')));
      await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
      await tester.pumpAndSettle();

      // Refused and named, the way the Windows page does it — not a VM
      // silently seeded with nothing.
      expect(shell.calls.any((c) => c.contains('create')), isFalse);
      expect(messages, contains('cloudinitmissing-text'));
    });

    testWidgets('a picked configuration reaches vmctl as --user-data',
        (tester) async {
      await CloudInitStore.instance.save(const CloudInitConfig(
          name: 'dev', content: '#cloud-config\npackages:\n  - git\n'));
      shell.responses['create'] = '{"created":"box"}';
      String? handedOver;
      shell.onCommand = (command) {
        if (command != 'create') return;
        final call = shell.calls.last;
        final index = call.indexOf('--user-data');
        if (index >= 0) handedOver = File(call[index + 1]).readAsStringSync();
      };
      await pump(tester);
      // The image first: typing there opens its suggestion list, which is
      // tall enough to sit over the create button. Moving on to the name
      // closes it.
      await tester.enterText(
          find.byKey(const ValueKey('test-vm-image')), '/tmp/local.raw');
      await tester.enterText(find.byKey(const ValueKey('test-vm-name')), 'box');
      await tester.pumpAndSettle();
      tester
          .widget<ComboBox<String>>(
              find.byKey(const ValueKey('test-create-cloudinit')))
          .onChanged!('dev');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(
          find.byKey(const ValueKey('test-vm-create-button')));
      await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
      await tester.pumpAndSettle();

      expect(handedOver, '#cloud-config\npackages:\n  - git\n');
    });

    testWidgets('None passes nothing', (tester) async {
      shell.responses['create'] = '{"created":"box"}';
      await pump(tester);
      await tester.enterText(
          find.byKey(const ValueKey('test-vm-image')), '/tmp/local.raw');
      await tester.enterText(find.byKey(const ValueKey('test-vm-name')), 'box');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
          find.byKey(const ValueKey('test-vm-create-button')));
      await tester.tap(find.byKey(const ValueKey('test-vm-create-button')));
      await tester.pumpAndSettle();
      final create = shell.calls.lastWhere((c) => c.contains('create'));
      expect(create, isNot(contains('--user-data')));
    });
  });
}
