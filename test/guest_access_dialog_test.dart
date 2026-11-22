/// Tests for lib/dialogs/guest_access_dialog.dart — the one-time SSH key
/// installation that makes snippets work in Apple VMs installed from an ISO
/// (bostrot/ai-tasks#16).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/guest_access_dialog.dart';

import 'fake_vmctl_shell.dart';

const String _denied =
    'root@192.168.64.2: Permission denied (publickey,password,keyboard-interactive).';

void main() {
  late FakeVmctlShell shell;
  late AppleVmApi api;
  final List<String> notices = [];

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      notices.add(msg);
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    notices.clear();
    shell = FakeVmctlShell();
    api = AppleVmApi(
      shell: shell,
      helperPathOverride: '/fake/vmctl',
      storeDirOverride: '/tmp/fake-store',
      earlyExitProbeDelay: Duration.zero,
    );
  });

  /// A page with one button that runs the guarded flow and records its
  /// answer — the shape of the "Run in instance" call sites.
  Future<void> pump(WidgetTester tester, List<bool?> answers,
      {String? user}) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Builder(
          builder: (context) => Button(
            child: const Text('run'),
            onPressed: () async {
              answers.add(await ensureGuestAccess(context, api, 'alpine_2',
                  user: user));
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  List<List<String>> callsFor(String command) =>
      shell.calls.where((c) => c.contains(command)).toList();

  testWidgets('a guest that already accepts the key runs straight away',
      (tester) async {
    final answers = <bool?>[];
    await pump(tester, answers);
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(answers, [true]);
    expect(find.byType(GuestAccessDialog), findsNothing);
    // One probe, as root — the default runCommands uses without a start user.
    final probes = callsFor('exec');
    expect(probes, hasLength(1));
    expect(probes.single, containsAll(['--user', 'root', 'true']));
    expect(callsFor('authorize'), isEmpty);
  });

  testWidgets('a stopped or unreachable VM is reported, not prompted for',
      (tester) async {
    shell.exitCodes['exec'] = 1;
    shell.errors['exec'] = 'VM alpine_2 is not running.';
    final answers = <bool?>[];
    await pump(tester, answers);
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(answers, [false]);
    expect(find.byType(GuestAccessDialog), findsNothing);
    expect(notices.single, contains('guestaccessunreachable-text'));
  });

  testWidgets(
      'Permission denied opens the dialog; the key is installed with the '
      'password in the environment and the snippet may run', (tester) async {
    // First probe: denied. After authorize the guest accepts the key.
    shell.exitCodeQueue['exec'] = [255, 0];
    shell.errors['exec'] = _denied;
    shell.responses['authorize'] =
        '{"authorized":"alpine_2","root":true,"user":"eric"}';
    prefs.setString('StartUser_alpine_2', 'eric');
    final answers = <bool?>[];
    await pump(tester, answers);
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(find.byType(GuestAccessDialog), findsOneWidget);
    // The start user is offered as the account to sign in with.
    final userBox = tester.widget<TextBox>(
        find.byKey(const ValueKey('test-guest-access-user')));
    expect(userBox.controller!.text, 'eric');

    await tester.enterText(
        find.byKey(const ValueKey('test-guest-access-password')), 'hunter2');
    await tester.tap(find.byKey(const ValueKey('test-guest-access-submit')));
    await tester.pumpAndSettle();

    expect(find.byType(GuestAccessDialog), findsNothing);
    expect(answers, [true]);

    final authorize = callsFor('authorize').single;
    expect(authorize, containsAll(['--name', 'alpine_2', '--user', 'eric']));
    // The password must never be an argument (visible in ps and logs)…
    expect(authorize.join(' '), isNot(contains('hunter2')));
    // …it goes through the environment variable the helper reads.
    final index = shell.calls.indexOf(authorize);
    expect(shell.environments[index],
        {AppleVmApi.guestPasswordEnv: 'hunter2'});
    // Access was re-checked after the install rather than assumed.
    expect(callsFor('exec'), hasLength(2));
    expect(notices.last, contains('guestaccessdone-text'));
  });

  testWidgets('a wrong password stays in the dialog with ssh\'s reason',
      (tester) async {
    shell.exitCodes['exec'] = 255;
    shell.errors['exec'] = _denied;
    shell.exitCodes['authorize'] = 1;
    shell.errors['authorize'] =
        'Could not sign in as eric@192.168.64.2: Permission denied (publickey,password).';
    final answers = <bool?>[];
    await pump(tester, answers);
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('test-guest-access-user')), 'eric');
    await tester.enterText(
        find.byKey(const ValueKey('test-guest-access-password')), 'nope');
    await tester.tap(find.byKey(const ValueKey('test-guest-access-submit')));
    await tester.pumpAndSettle();

    // Still open, error shown, nothing ran.
    expect(find.byType(GuestAccessDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('test-guest-access-error')), findsOneWidget);
    expect(find.textContaining('Could not sign in as eric'), findsOneWidget);
    expect(answers, isEmpty);

    // Cancel answers "do not run".
    await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  testWidgets('empty fields are refused before anything is run',
      (tester) async {
    shell.exitCodes['exec'] = 255;
    shell.errors['exec'] = _denied;
    final answers = <bool?>[];
    await pump(tester, answers);
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('test-guest-access-submit')));
    await tester.pumpAndSettle();

    expect(find.text('guestaccessempty-text'), findsOneWidget);
    expect(callsFor('authorize'), isEmpty);
    expect(find.byType(GuestAccessDialog), findsOneWidget);
  });

  testWidgets(
      'when the snippet user is still refused after the install, say so and '
      'do not run', (tester) async {
    // The key went in for eric, but root login stays off in sshd.
    shell.exitCodes['exec'] = 255;
    shell.errors['exec'] = _denied;
    shell.responses['authorize'] =
        '{"authorized":"alpine_2","root":false,"user":"eric"}';
    final answers = <bool?>[];
    await pump(tester, answers);
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('test-guest-access-user')), 'eric');
    await tester.enterText(
        find.byKey(const ValueKey('test-guest-access-password')), 'hunter2');
    await tester.tap(find.byKey(const ValueKey('test-guest-access-submit')));
    await tester.pumpAndSettle();

    expect(answers, [false]);
    expect(notices.last, contains('guestaccessstilldenied-text'));
  });

  testWidgets('a snippet with its own start user is probed as that user',
      (tester) async {
    final answers = <bool?>[];
    await pump(tester, answers, user: 'dev');
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();

    expect(answers, [true]);
    expect(callsFor('exec').single, containsAll(['--user', 'dev']));
  });

  /// What the snippet itself then signs in as. The guard can change it —
  /// it pins the account that took the key — and the caller read its own
  /// value before the dialog ever opened (bostrot/ai-tasks#101).
  group('the account a run uses after the guard', () {
    test('is the pinned one when the guard wrote one', () async {
      await prefs.setString('StartUser_alpine_2', 'erict');
      expect(guestRunUser('alpine_2', null), 'erict');
      expect(guestRunUser('alpine_2', 'user'), 'erict');
    });

    test('is what the caller had when nothing is pinned', () {
      expect(guestRunUser('alpine_2', 'dev'), 'dev');
    });

    test('stays null rather than becoming an empty account', () {
      // WSL would sign in with `-u ''`; null is what means "your default".
      expect(guestRunUser('alpine_2', null), isNull);
    });
  });

  /// A macOS guest has no root to fall back on — sshd refuses it outright —
  /// and no settings dialog either, so "set the right account" was advice
  /// with nowhere to follow it (bostrot/ai-tasks#101).
  group('a macOS guest', () {
    const macos = '{"vms":[{"name":"alpine_2","state":"running","os":"macos",'
        '"user":"user","ip":"192.168.64.5"}]}';

    testWidgets('is probed as its own account rather than as root',
        (tester) async {
      shell.responses['list'] = macos;
      final answers = <bool?>[];
      await pump(tester, answers);
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();

      expect(answers, [true]);
      expect(callsFor('exec').single, containsAll(['--user', 'user']));
    });

    testWidgets(
        'the account that took the key is pinned when the placeholder is '
        'still refused', (tester) async {
      shell.responses['list'] = macos;
      // Probes: `user` denied, `user` denied again after the install, then
      // `erict` — the account that just signed in — answers.
      shell.exitCodeQueue['exec'] = [255, 255, 0];
      shell.errors['exec'] = _denied;
      shell.responses['authorize'] =
          '{"authorized":"alpine_2","root":false,"user":"erict"}';
      final answers = <bool?>[];
      await pump(tester, answers);
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('test-guest-access-user')), 'erict');
      await tester.enterText(
          find.byKey(const ValueKey('test-guest-access-password')), 'hunter2');
      await tester.tap(find.byKey(const ValueKey('test-guest-access-submit')));
      await tester.pumpAndSettle();

      // The run goes ahead, and every later one signs in as that account.
      expect(answers, [true]);
      expect(prefs.getString('StartUser_alpine_2'), 'erict');
      expect(notices.last, contains('guestaccessadopted-text'));
      expect(callsFor('exec').last, containsAll(['--user', 'erict']));
    });

    testWidgets('an account that does not answer either is not pinned',
        (tester) async {
      shell.responses['list'] = macos;
      shell.exitCodes['exec'] = 255;
      shell.errors['exec'] = _denied;
      shell.responses['authorize'] =
          '{"authorized":"alpine_2","root":false,"user":"erict"}';
      final answers = <bool?>[];
      await pump(tester, answers);
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('test-guest-access-user')), 'erict');
      await tester.enterText(
          find.byKey(const ValueKey('test-guest-access-password')), 'hunter2');
      await tester.tap(find.byKey(const ValueKey('test-guest-access-submit')));
      await tester.pumpAndSettle();

      expect(answers, [false]);
      expect(prefs.getString('StartUser_alpine_2'), isNull);
      expect(notices.last, contains('guestaccessstilldenied-text'));
    });

    testWidgets('a pinned account is what the guest is probed as',
        (tester) async {
      shell.responses['list'] = macos;
      await prefs.setString('StartUser_alpine_2', 'erict');
      final answers = <bool?>[];
      await pump(tester, answers);
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();

      expect(callsFor('exec').single, containsAll(['--user', 'erict']));
    });
  });
}
