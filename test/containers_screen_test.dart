/// Widget tests for lib/screens/containers_screen.dart — the Docker/Podman
/// surface added for bostrot/ai-tasks#57.
///
/// There is no localization delegate here, so `.i18n()` returns the key it was
/// given; asserting on `containers-text` is what proves the label goes through
/// i18n rather than being a hardcoded English string.
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/containers/container_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/containers_screen.dart';

import 'container_service_test.dart' show psLine;
import 'fake_container_shell.dart';

void main() {
  late FakeContainerShell shell;
  final messages = <String>[];

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
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    messages.clear();
    shell = FakeContainerShell();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: ContainersPage(
            service: ContainerService(shell: shell, isWindows: false)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Every command the shell has been handed, one string per call — argv
  /// lists compare by identity, which no assertion can use.
  List<String> ran() => shell.calls.map((call) => call.join(' ')).toList();

  /// The row's buttons live inside a collapsed Expander, so nothing under it
  /// is in the tree until the header is tapped.
  Future<void> openRow(WidgetTester tester, String name) async {
    await tester.tap(find.textContaining(name).first);
    await tester.pumpAndSettle();
  }

  testWidgets('a host without an engine gets an explanation, not an error',
      (tester) async {
    shell.missing.addAll(['docker', 'podman']);
    await pump(tester);

    expect(find.byKey(const ValueKey('test-containers-no-engine')),
        findsOneWidget);
    expect(find.text('nocontainerenginehint-text'), findsOneWidget);
  });

  testWidgets('an engine with nothing in it says so', (tester) async {
    await pump(tester);
    expect(
        find.byKey(const ValueKey('test-containers-empty')), findsOneWidget);
  });

  testWidgets("a failing engine shows the engine's own message",
      (tester) async {
    shell.exitCodes['docker ps'] = 1;
    shell.errors['docker ps'] = 'Cannot connect to the Docker daemon';
    shell.exitCodes['podman ps'] = 125;
    shell.errors['podman ps'] = 'podman machine is not running';
    await pump(tester);

    expect(
        find.byKey(const ValueKey('test-containers-error')), findsOneWidget);
    expect(find.textContaining('Cannot connect to the Docker daemon'),
        findsOneWidget);
  });

  testWidgets('containers from both engines are listed with their state',
      (tester) async {
    shell.responses['docker ps'] =
        psLine('a1', 'web', 'nginx:latest', 'running', 'Up 2 hours', '80/tcp');
    shell.responses['podman ps'] = psLine('b2', 'db', 'postgres', 'exited');
    await pump(tester);

    expect(find.textContaining('web (running-text)'), findsOneWidget);
    expect(find.textContaining('db (stopped-text)'), findsOneWidget);
    // The caption tells two same-named containers apart.
    expect(find.textContaining('nginx:latest · Docker · 80/tcp'),
        findsOneWidget);
  });

  testWidgets('the toggle stops a running container and starts a stopped one',
      (tester) async {
    shell.responses['docker ps'] =
        psLine('a1', 'web', 'nginx', 'running');
    shell.responses['podman ps'] = psLine('b2', 'db', 'postgres', 'exited');
    await pump(tester);

    await openRow(tester, 'web');
    await tester.tap(find.byKey(const ValueKey('test-container-toggle-web')));
    await tester.pumpAndSettle();
    expect(ran(), contains('docker stop web'));

    await openRow(tester, 'db');
    await tester.tap(find.byKey(const ValueKey('test-container-toggle-db')));
    await tester.pumpAndSettle();
    expect(ran(), contains('podman start db'));
  });

  testWidgets('a failed action surfaces the engine text in the status bar',
      (tester) async {
    shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
    shell.exitCodes['docker stop'] = 1;
    shell.errors['docker stop'] = 'container web is restarting';
    await pump(tester);

    await openRow(tester, 'web');
    await tester.tap(find.byKey(const ValueKey('test-container-toggle-web')));
    await tester.pumpAndSettle();

    expect(messages.join('\n'), contains('container web is restarting'));
  });

  testWidgets('deleting asks first and only then removes', (tester) async {
    shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
    await pump(tester);

    await openRow(tester, 'web');
    await tester.tap(find.byKey(const ValueKey('test-container-delete-web')));
    await tester.pumpAndSettle();

    // The confirmation is up and nothing has been removed yet.
    expect(find.text('deletecontainerbody-text'), findsOneWidget);
    expect(shell.calls.where((c) => c.contains('rm')), isEmpty);

    await tester.tap(find.text('delete-text').last);
    await tester.pumpAndSettle();
    // Running, so the engine would refuse a plain rm.
    expect(ran(), contains('docker rm --force web'));
  });

  testWidgets('logs open in a dialog', (tester) async {
    shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
    shell.responses['docker logs'] = 'listening on :80';
    await pump(tester);

    await openRow(tester, 'web');
    await tester.tap(find.byKey(const ValueKey('test-container-logs-web')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-container-logs-dialog')),
        findsOneWidget);
    expect(find.text('listening on :80'), findsOneWidget);
  });

  testWidgets('refresh re-probes for an engine installed since startup',
      (tester) async {
    shell.missing.addAll(['docker', 'podman']);
    await pump(tester);
    expect(find.byKey(const ValueKey('test-containers-no-engine')),
        findsOneWidget);

    shell.missing.clear();
    shell.responses['docker ps'] = psLine('a1', 'web', 'nginx', 'running');
    await tester.tap(find.byKey(const ValueKey('test-containers-refresh')));
    await tester.pumpAndSettle();

    expect(find.textContaining('web (running-text)'), findsOneWidget);
  });

  group('creating a container', () {
    /// Open the create form from the header button.
    Future<void> openCreate(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('test-containers-create')));
      await tester.pumpAndSettle();
    }

    testWidgets('the button is offered once an engine has answered',
        (tester) async {
      await pump(tester);
      final button = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-containers-create')));
      expect(button.onPressed, isNotNull);
      expect(find.text('createcontainer-text'), findsOneWidget);
    });

    testWidgets('the button is dead while no engine is installed',
        (tester) async {
      // Nothing to create *with*: the empty state explains, and the button
      // must not open a form whose every submit would fail.
      shell.missing.addAll(['docker', 'podman']);
      await pump(tester);

      final button = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-containers-create')));
      expect(button.onPressed, isNull);
    });

    testWidgets('an image alone is enough, and becomes a detached run',
        (tester) async {
      await pump(tester);
      await openCreate(tester);
      expect(find.byKey(const ValueKey('test-create-container-dialog')),
          findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('test-create-image')), 'alpine');
      await tester.tap(
          find.byKey(const ValueKey('test-create-container-submit')));
      await tester.pumpAndSettle();

      expect(ran(), contains('docker run --detach alpine'));
      // Closed on success, and the list reloaded behind it.
      expect(find.byKey(const ValueKey('test-create-container-dialog')),
          findsNothing);
      expect(messages.any((m) => m.contains('createdcontainer-text')), isTrue);
    });

    testWidgets('every field reaches the engine as its own flag',
        (tester) async {
      await pump(tester);
      await openCreate(tester);

      await tester.enterText(
          find.byKey(const ValueKey('test-create-image')), 'nginx:1.27');
      await tester.enterText(
          find.byKey(const ValueKey('test-create-name')), 'web');
      await tester.enterText(
          find.byKey(const ValueKey('test-create-ports')), '127.0.0.1:8080:80');
      await tester.enterText(
          find.byKey(const ValueKey('test-create-volumes')), 'mydata:/data');
      await tester.enterText(
          find.byKey(const ValueKey('test-create-env')), 'TZ=Europe/Berlin');
      await tester.enterText(
          find.byKey(const ValueKey('test-create-command')), 'sleep 3600');
      await tester.tap(find.byKey(const ValueKey('test-create-rm')));
      await tester.pumpAndSettle();
      await tester.tap(
          find.byKey(const ValueKey('test-create-container-submit')));
      await tester.pumpAndSettle();

      expect(
          ran(),
          contains('docker run --detach --rm --name web '
              '--publish 127.0.0.1:8080:80 --volume mydata:/data '
              '--env TZ=Europe/Berlin nginx:1.27 sleep 3600'));
    });

    testWidgets('a bad port is reported at the box and nothing is run',
        (tester) async {
      await pump(tester);
      await openCreate(tester);
      final before = ran().length;

      await tester.enterText(
          find.byKey(const ValueKey('test-create-image')), 'alpine');
      await tester.enterText(
          find.byKey(const ValueKey('test-create-ports')), '99999:80');
      await tester.tap(
          find.byKey(const ValueKey('test-create-container-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-create-ports-error')),
          findsOneWidget);
      expect(find.text('containerportinvalid-text'), findsOneWidget);
      // The form is still open and the engine was never asked.
      expect(find.byKey(const ValueKey('test-create-container-dialog')),
          findsOneWidget);
      expect(ran().length, before);
    });

    testWidgets('an image that looks like a flag never reaches the engine',
        (tester) async {
      await pump(tester);
      await openCreate(tester);
      final before = ran().length;

      await tester.enterText(find.byKey(const ValueKey('test-create-image')),
          '--privileged');
      await tester.tap(
          find.byKey(const ValueKey('test-create-container-submit')));
      await tester.pumpAndSettle();

      expect(find.text('containerflaglike-text'), findsOneWidget);
      expect(ran().length, before);
    });

    testWidgets("the engine's own refusal is shown and the form stays open",
        (tester) async {
      // "port is already allocated" is worth reading, and retrying after
      // editing one box beats retyping the whole form.
      shell.exitCodes['docker run'] = 125;
      shell.errors['docker run'] =
          'docker: Error response from daemon: port is already allocated.';
      await pump(tester);
      await openCreate(tester);

      await tester.enterText(
          find.byKey(const ValueKey('test-create-image')), 'alpine');
      await tester.tap(
          find.byKey(const ValueKey('test-create-container-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-create-container-dialog')),
          findsOneWidget);
      expect(find.textContaining('port is already allocated'), findsOneWidget);
    });

    testWidgets('with two engines the form asks which one', (tester) async {
      await pump(tester);
      await openCreate(tester);
      expect(find.byKey(const ValueKey('test-create-engine')), findsOneWidget);
    });

    testWidgets('a pin naming an uninstalled engine does not break the picker',
        (tester) async {
      // The pin in settings outlives the engine it names. The picker shows
      // the stale value without complaining, so the symptom is not a crash:
      // the run went to `wslc` on a host that has no wslc, and a whole
      // filled-in form came back as "command not found".
      // wslc is a real engine the pin can name and this host cannot have —
      // so the picker is shown (docker and podman both answered) with a
      // pinned value that is not one of its two items.
      SharedPreferences.setMockInitialValues({'ContainerEngine': 'wslc'});
      prefs = await SharedPreferences.getInstance();
      await pump(tester);
      await openCreate(tester);

      expect(find.byKey(const ValueKey('test-create-engine')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(
          find.byKey(const ValueKey('test-create-image')), 'alpine');
      await tester.tap(
          find.byKey(const ValueKey('test-create-container-submit')));
      await tester.pumpAndSettle();

      // Falls back to the engine that is actually there.
      expect(ran(), contains('docker run --detach alpine'));
    });

    testWidgets('with one engine there is nothing to pick', (tester) async {
      shell.missing.add('podman');
      await pump(tester);
      await openCreate(tester);
      expect(find.byKey(const ValueKey('test-create-engine')), findsNothing);
    });
  });

}
