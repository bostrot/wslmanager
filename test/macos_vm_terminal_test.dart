/// The terminal button on a macOS guest (bostrot/ai-tasks#101).
///
/// Apple's Virtualization framework gives a macOS guest no serial device, so
/// the console the Linux path falls back on does not exist for it: pressing
/// the button opened a Terminal window that said "Serial console is only
/// available for Linux guests." and stopped there. SSH is the only terminal
/// such a guest has, so the row makes sure the app's key is in it first —
/// with the dialog a snippet run already uses — instead of handing over a
/// refused session.
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed.
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list_item.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_vmctl_shell.dart';

class _MockPlausible implements Plausible {
  @override
  Future<int> event(
          {String? name,
          String? page,
          Map<String, String>? props,
          String? referrer,
          PlausibleRevenue? revenue,
          bool interactive = true}) async =>
      200;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        dynamic widget,
        leadingIcon = true}) {};
  });

  late FakeVmctlShell shell;
  late AppleVmApi backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    plausible = _MockPlausible();
    shell = FakeVmctlShell();
    backend = AppleVmApi(
      shell: shell,
      helperPathOverride: '/fake/vmctl',
      storeDirOverride: Directory.systemTemp.createTempSync('vmterm').path,
      earlyExitProbeDelay: Duration.zero,
      guestReadyPollInterval: Duration.zero,
      macosTerminalTimeout: Duration.zero,
    );
    // One instance, so the row and the assertions share a shell.
    vmBackendBuilder = () => backend;
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
  });

  Widget row(String name) => FluentApp(
        home: ScaffoldPage(
          content: ListItem(item: name, running: [name], trailing: '10.0 GB'),
        ),
      );

  /// The terminal button: the first slot carries it while the VM runs.
  Future<void> pressTerminal(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-listitem-start')));
    // Long enough for the row's own probe *and* for fluent_ui's 100ms press
    // animation, which the framework counts as a pending timer.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a macOS guest that refuses the key is offered the key dialog',
      (tester) async {
    shell.responses['list'] =
        '{"vms":[{"name":"sequoia","state":"running","os":"macos",'
        '"user":"user","ip":"192.168.64.5"}]}';
    shell.exitCodes['exec'] = 255;
    shell.errors['exec'] = 'eric@192.168.64.5: Permission denied (publickey).';
    await prefs.setString('StartUser_sequoia', 'eric');

    await tester.pumpWidget(row('sequoia'));
    await pressTerminal(tester);

    expect(find.byKey(const ValueKey('test-guest-access-user')), findsOneWidget);
    // Prefilled with the account the terminal would sign in as, which on a
    // macOS guest is the instance's own user setting.
    final field = tester.widget<TextBox>(
        find.byKey(const ValueKey('test-guest-access-user')));
    expect(field.controller?.text, 'eric');
    // Nothing was opened behind the dialog.
    expect(shell.calls.where((c) => c.first == 'start:open'), isEmpty);
  });

  testWidgets('cancelling the dialog opens no terminal at all', (tester) async {
    shell.responses['list'] =
        '{"vms":[{"name":"sequoia","state":"running","os":"macos",'
        '"user":"user","ip":"192.168.64.5"}]}';
    shell.exitCodes['exec'] = 255;
    shell.errors['exec'] = 'user@192.168.64.5: Permission denied (publickey).';

    await tester.pumpWidget(row('sequoia'));
    await pressTerminal(tester);
    await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('test-guest-access-user')), findsNothing);
    expect(shell.calls.where((c) => c.first == 'start:open'), isEmpty);
  });

  testWidgets('installing the key from the dialog then opens the shell',
      (tester) async {
    shell.responses['list'] =
        '{"vms":[{"name":"sequoia","state":"running","os":"macos",'
        '"user":"user","ip":"192.168.64.5"}]}';
    shell.exitCodes['exec'] = 255;
    shell.errors['exec'] = 'user@192.168.64.5: Permission denied (publickey).';
    shell.responses['authorize'] = '{"authorized":"sequoia","root":false}';
    // The guest takes the key: every probe after that one succeeds.
    shell.onCommand = (command) {
      if (command == 'authorize') shell.exitCodes['exec'] = 0;
    };

    await tester.pumpWidget(row('sequoia'));
    await pressTerminal(tester);
    await tester.enterText(
        find.byKey(const ValueKey('test-guest-access-user')), 'eric');
    await tester.enterText(
        find.byKey(const ValueKey('test-guest-access-password')), 'hunter2');
    await tester.tap(find.byKey(const ValueKey('test-guest-access-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(shell.calls.any((c) => c.contains('authorize')), isTrue);
    expect(shell.calls.lastWhere((c) => c.first == 'start:open').last,
        endsWith('shell.command'));
  });

  testWidgets('a reachable macOS guest goes straight to its shell',
      (tester) async {
    shell.responses['list'] =
        '{"vms":[{"name":"sequoia","state":"running","os":"macos",'
        '"user":"user","ip":"192.168.64.5"}]}';

    await tester.pumpWidget(row('sequoia'));
    await pressTerminal(tester);

    expect(find.byKey(const ValueKey('test-guest-access-user')), findsNothing);
    expect(shell.calls.lastWhere((c) => c.first == 'start:open').last,
        endsWith('shell.command'));
  });

  testWidgets('a Linux guest is never asked for a key by this button',
      (tester) async {
    // It has a console to fall back on, so a refused key is not a dead end
    // there and the row leaves the decision to the backend.
    shell.responses['list'] =
        '{"vms":[{"name":"ubuntu","state":"running","os":"linux",'
        '"user":"eric","ip":"192.168.64.4"}]}';
    shell.exitCodes['exec'] = 255;
    shell.errors['exec'] = 'eric@192.168.64.4: Permission denied (publickey).';

    await tester.pumpWidget(row('ubuntu'));
    await pressTerminal(tester);

    expect(find.byKey(const ValueKey('test-guest-access-user')), findsNothing);
    expect(shell.calls.lastWhere((c) => c.first == 'start:open').last,
        endsWith('console.command'));
  });
}
