/// Tests for lib/dialogs/create_dialog.dart — the create form's validation and
/// failure reporting.
///
/// Covers CI-12 ("Create default user" with an empty username used to import
/// the distro, skip the account and still report success) and CI-17 (every
/// failure path has to take the "Creating instance..." spinner down with it).
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/create_dialog.dart';

import 'mocks.dart';

void main() {
  late List<String> messages;
  late List<bool> spinners;

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
      spinners.add(loading);
    };
  });

  setUp(() async {
    messages = [];
    spinners = [];
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('supportsDefaultUser', () {
    test('is false for the source types that hide the toggle', () {
      expect(supportsDefaultUser(CreateSourceType.turnkey), isFalse);
      expect(supportsDefaultUser(CreateSourceType.docker), isFalse);
      expect(supportsDefaultUser(CreateSourceType.vhdx), isFalse);
    });

    test('is true for the source types that show it', () {
      expect(supportsDefaultUser(CreateSourceType.repo), isTrue);
      expect(supportsDefaultUser(CreateSourceType.local), isTrue);
      expect(supportsDefaultUser(CreateSourceType.dockerLocalImage), isTrue);
    });
  });

  group('createInstance', () {
    test('refuses to start when a default user was asked for but not named',
        () async {
      final error = ValueNotifier<CreateFailure?>(null);
      final ok = await createInstance(
        TextEditingController(text: 'Ubuntu-Test'),
        TextEditingController(),
        WSLApi(),
        TextEditingController(text: 'Ubuntu'),
        TextEditingController(text: '   '),
        requireUser: true,
        onError: error,
      );

      expect(ok, isFalse);
      expect(error.value, isNotNull);
      expect(error.value!.message, 'errorenterusername-text');
      // A form the user can simply correct is not worth an AI diagnosis.
      expect(error.value!.diagnosable, isFalse);
      error.dispose();
    });

    test('leaves no spinner running behind a failure', () async {
      final error = ValueNotifier<CreateFailure?>(null);
      await createInstance(
        TextEditingController(text: 'Ubuntu-Test'),
        TextEditingController(),
        WSLApi(),
        TextEditingController(text: 'Ubuntu'),
        TextEditingController(),
        requireUser: true,
        onError: error,
      );

      // CI-17: the banner carries the text, so the status bar is cleared
      // rather than left spinning for the rest of the session.
      expect(messages.last, '');
      expect(spinners, everyElement(isFalse));
      error.dispose();
    });

    test('reports an empty name before it touches WSL', () async {
      final error = ValueNotifier<CreateFailure?>(null);
      final ok = await createInstance(
        TextEditingController(),
        TextEditingController(),
        WSLApi(),
        TextEditingController(text: 'Ubuntu'),
        TextEditingController(),
        onError: error,
      );

      expect(ok, isFalse);
      expect(error.value!.message, 'errorentername-text');
      error.dispose();
    });
  });

  group('createInstance with a cloud-init configuration', () {
    late Directory dir;
    late MockShell shell;
    late WSLApi api;
    late String rootfs;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('create-cloud-init-');
      CloudInitFiles.userDataDirOverride = '${dir.path}/.cloud-init';
      SharedPreferences.setMockInitialValues({'DataPath': dir.path});
      prefs = await SharedPreferences.getInstance();
      CloudInitStore.instance.reload();
      await CloudInitStore.instance.save(const CloudInitConfig(
          name: 'dev', content: '#cloud-config\npackages:\n  - git\n'));
      shell = MockShell();
      // The first boot's answer: cloud-init ran to the end.
      shell.commandOutputs[cloudInitWaitScript] = 'done';
      api = WSLApi(shell: shell);
      WSLApi.localCloudInitOverride = true;
      // A local rootfs: no download, straight to `wsl --import`.
      rootfs = '${dir.path}/rootfs.tar.gz';
      File(rootfs).writeAsBytesSync([1]);
    });

    tearDown(() {
      WSLApi.localCloudInitOverride = null;
      CloudInitFiles.userDataDirOverride = null;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<bool> create(String name, {ValueNotifier<CreateFailure?>? error}) =>
        createInstance(
          TextEditingController(text: name),
          TextEditingController(text: '${dir.path}/instances'),
          api,
          TextEditingController(text: rootfs),
          TextEditingController(),
          cloudInitName: 'dev',
          onError: error,
        );

    test('writes the file for the first boot, waits, then removes it',
        () async {
      final path = CloudInitFiles.userDataPath('Ubuntu-Dev');
      // The import reports progress while it runs, which is when the file
      // has to be in place: what cloud-init would read on the first boot.
      String? seenDuringImport;
      final progress = ValueNotifier<CreateProgress?>(null);
      progress.addListener(() {
        if (progress.value?.phase == CreatePhase.importing &&
            seenDuringImport == null &&
            File(path).existsSync()) {
          seenDuringImport = File(path).readAsStringSync();
        }
      });
      final ok = await createInstance(
        TextEditingController(text: 'Ubuntu-Dev'),
        TextEditingController(text: '${dir.path}/instances'),
        api,
        TextEditingController(text: rootfs),
        TextEditingController(),
        cloudInitName: 'dev',
        onProgress: progress,
      );
      expect(ok, isTrue, reason: messages.join('\n'));
      expect(seenDuringImport, '#cloud-config\npackages:\n  - git\n');
      // The import ran, then the first boot waited for cloud-init …
      final importIndex =
          shell.runCalls.indexWhere((c) => c.contains('--import'));
      final waitIndex =
          shell.runCalls.indexWhere((c) => c.contains(cloudInitWaitScript));
      expect(importIndex, greaterThanOrEqualTo(0));
      expect(waitIndex, greaterThan(importIndex));
      expect(messages, contains('cloudinitwaiting-text'));
      // … and the file, having been consumed, is gone — it must not apply
      // itself to a later distro of the same name.
      expect(File(path).existsSync(), isFalse);
      progress.dispose();
    });

    test('refuses to overwrite a file the user put there', () async {
      final error = ValueNotifier<CreateFailure?>(null);
      final path = CloudInitFiles.userDataPath('Ubuntu-Dev');
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('#cloud-config\ntheirs: true\n');
      final ok = await create('Ubuntu-Dev', error: error);
      expect(ok, isFalse);
      expect(error.value?.message, startsWith('cloudinitfileexists-text'));
      expect(error.value?.diagnosable, isFalse);
      // Nothing was imported and their file is untouched.
      expect(shell.runCalls.any((c) => c.contains('--import')), isFalse);
      expect(File(path).readAsStringSync(), '#cloud-config\ntheirs: true\n');
      error.dispose();
    });

    test('removes the file again when the import fails', () async {
      shell.simulatePermissionDenied = true;
      final error = ValueNotifier<CreateFailure?>(null);
      final ok = await create('Ubuntu-Dev', error: error);
      expect(ok, isFalse);
      expect(error.value?.message, startsWith('createinstancefailed-text'));
      expect(CloudInitFiles.exists('Ubuntu-Dev'), isFalse);
      expect(shell.runCommands, isNot(contains(cloudInitWaitScript)));
      error.dispose();
    });

    test('a first boot that did not run cloud-init removes the file and says so',
        () async {
      shell.commandOutputs[cloudInitWaitScript] = 'skipped';
      final ok = await create('Ubuntu-Dev');
      expect(ok, isTrue, reason: messages.join('\n'));
      expect(CloudInitFiles.exists('Ubuntu-Dev'), isFalse);
      expect(messages, contains('cloudinitnotrun-text'));
    });

    test('a first boot that could not be confirmed keeps the file for it',
        () async {
      // An empty answer is the mock's "command not there" — here it stands
      // for a distro that never got to the end of the script.
      shell.commandOutputs[cloudInitWaitScript] = '';
      final ok = await create('Ubuntu-Dev');
      expect(ok, isTrue, reason: messages.join('\n'));
      expect(CloudInitFiles.exists('Ubuntu-Dev'), isTrue);
      expect(messages, contains('cloudinitwaitfailed-text'));
    });

    test('a backend without the feature refuses instead of writing a file',
        () async {
      WSLApi.localCloudInitOverride = false;
      final error = ValueNotifier<CreateFailure?>(null);
      final ok = await create('Ubuntu-Dev', error: error);
      expect(ok, isFalse);
      expect(error.value?.message, 'cloudinitunsupported-text');
      expect(CloudInitFiles.exists('Ubuntu-Dev'), isFalse);
      error.dispose();
    });

    test('removing a distro takes its user-data file with it', () async {
      await CloudInitFiles.write('Ubuntu-Dev', '#cloud-config\n');
      await api.remove('Ubuntu-Dev');
      expect(CloudInitFiles.exists('Ubuntu-Dev'), isFalse);
    });

    test('a configuration deleted since it was picked stops the create',
        () async {
      await CloudInitStore.instance.remove('dev');
      final error = ValueNotifier<CreateFailure?>(null);
      final ok = await create('Ubuntu-Dev', error: error);
      expect(ok, isFalse);
      expect(error.value?.message, 'cloudinitmissing-text');
      expect(shell.runCalls.any((c) => c.contains('--import')), isFalse);
      error.dispose();
    });
  });
}
