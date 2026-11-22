/// Tests for lib/dialogs/vm_credentials_dialog.dart — the "how do I actually
/// log in to this thing" surface for Apple VMs (bostrot/ai-tasks#60).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/vm_credentials_dialog.dart';

import 'fake_vmctl_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: VmCredentialsDialog(api: api, instance: 'ubuntu'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  void answerWith(Map<String, dynamic> payload) =>
      shell.responses['credentials'] = json.encode(payload);

  testWidgets('names the account and hides the password until asked',
      (tester) async {
    answerWith({
      'user': 'eric',
      'password': 'Abc23xyz',
      'sshKey': '/store/id_ed25519',
      'appliedOnNextBoot': false,
    });
    await pump(tester);

    expect(find.text('eric'), findsOneWidget);
    expect(find.text('/store/id_ed25519'), findsOneWidget);
    // Masked, not absent — the field has to be visibly there to be found.
    expect(find.text('Abc23xyz'), findsNothing);
    expect(find.text('•' * 'Abc23xyz'.length), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('test-vm-credentials-reveal')));
    await tester.pumpAndSettle();
    expect(find.text('Abc23xyz'), findsOneWidget);
  });

  testWidgets('copies a value to the clipboard and says so', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    answerWith({
      'user': 'eric',
      'password': 'Abc23xyz',
      'sshKey': '/store/id_ed25519',
      'appliedOnNextBoot': false,
    });
    await pump(tester);

    // The password copies in full even while it is masked on screen.
    await tester.tap(
        find.byKey(const ValueKey('test-vm-credentials-password-copy')));
    await tester.pumpAndSettle();
    expect(copied, ['Abc23xyz']);
    expect(notices, contains('copied-text'));
  });

  testWidgets('warns when the password only lands on the next boot',
      (tester) async {
    answerWith({
      'user': 'eric',
      'password': 'Abc23xyz',
      'sshKey': '/store/id_ed25519',
      'appliedOnNextBoot': true,
    });
    await pump(tester);
    expect(find.byKey(const ValueKey('test-vm-credentials-pending')),
        findsOneWidget);
  });

  testWidgets('a root-only guest is told why there is no password',
      (tester) async {
    answerWith({
      'user': 'root',
      'sshKey': '/store/id_ed25519',
      'appliedOnNextBoot': false,
    });
    await pump(tester);
    expect(find.byKey(const ValueKey('test-vm-credentials-nopassword')),
        findsOneWidget);
    // Nothing to reveal, so no reveal button either.
    expect(find.byKey(const ValueKey('test-vm-credentials-reveal')),
        findsNothing);
  });

  testWidgets('a helper failure shows its words instead of an empty dialog',
      (tester) async {
    shell.exitCodes['credentials'] = 1;
    shell.errors['credentials'] = 'No VM named "ubuntu".';
    await pump(tester);
    expect(find.byKey(const ValueKey('test-vm-credentials-error')),
        findsOneWidget);
    expect(find.textContaining('No VM named'), findsOneWidget);
    // Nothing loaded, so there is no account to save either — saving the
    // empty box would clear a pin the user came here to read
    // (bostrot/ai-tasks#101).
    final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('test-vm-credentials-save')));
    expect(save.onPressed, isNull);
  });

  /// On a macOS guest `vmctl create` never learns the account typed into
  /// Setup Assistant and keeps its placeholder, so every SSH path signs in
  /// as a user that does not exist. This box is where that is corrected
  /// (bostrot/ai-tasks#101).
  group('the account', () {
    testWidgets('is prefilled with the pinned one, not the helper\'s guess',
        (tester) async {
      await prefs.setString('StartUser_ubuntu', 'erict');
      answerWith({
        'user': 'user',
        'sshKey': '/store/id_ed25519',
        'appliedOnNextBoot': false,
      });
      await pump(tester);

      final box = tester.widget<TextBox>(
          find.byKey(const ValueKey('test-vm-credentials-user')));
      expect(box.controller!.text, 'erict');
    });

    testWidgets('is pinned for the instance when it is corrected',
        (tester) async {
      answerWith({
        'user': 'user',
        'sshKey': '/store/id_ed25519',
        'appliedOnNextBoot': false,
      });
      await pump(tester);

      await tester.enterText(
          find.byKey(const ValueKey('test-vm-credentials-user')), 'erict');
      await tester.tap(find.byKey(const ValueKey('test-vm-credentials-save')));
      await tester.pumpAndSettle();

      expect(prefs.getString('StartUser_ubuntu'), 'erict');
      expect(notices.last, contains('vmloginusersaved-text'));
      // Saved and gone: the dialog is a setting, not a session.
      expect(find.byType(VmCredentialsDialog), findsNothing);
    });

    testWidgets('typed back to the helper\'s own answer, the pin is dropped',
        (tester) async {
      await prefs.setString('StartUser_ubuntu', 'erict');
      answerWith({
        'user': 'user',
        'sshKey': '/store/id_ed25519',
        'appliedOnNextBoot': false,
      });
      await pump(tester);

      await tester.enterText(
          find.byKey(const ValueKey('test-vm-credentials-user')), 'user');
      await tester.tap(find.byKey(const ValueKey('test-vm-credentials-save')));
      await tester.pumpAndSettle();

      // Not frozen into a setting of its own: a VM whose config is right
      // keeps tracking it.
      expect(prefs.getString('StartUser_ubuntu'), isNull);
    });

    testWidgets('is left alone when the dialog is closed', (tester) async {
      await prefs.setString('StartUser_ubuntu', 'erict');
      answerWith({
        'user': 'user',
        'sshKey': '/store/id_ed25519',
        'appliedOnNextBoot': false,
      });
      await pump(tester);

      await tester.enterText(
          find.byKey(const ValueKey('test-vm-credentials-user')), 'typo');
      await tester.tap(find.byKey(const ValueKey('test-dialog-cancel')));
      await tester.pumpAndSettle();

      expect(prefs.getString('StartUser_ubuntu'), 'erict');
    });
  });
}
