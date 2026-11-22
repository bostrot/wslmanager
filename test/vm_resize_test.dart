/// Tests for lib/api/vm_resize.dart and lib/dialogs/vm_resize_dialog.dart —
/// changing a VM's CPU count, memory and disk after it was created
/// (bostrot/ai-tasks#103).
///
/// No localization delegate here, so `.i18n()` returns the key it was given
/// and an expectation can name the key rather than an English sentence.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/vm_resize.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/list_item.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/vm_resize_dialog.dart';

import 'fake_vmctl_shell.dart';
import 'mocks.dart';

const int _gb = 1024 * 1024 * 1024;

String _listJson({
  String name = 'dev',
  String os = 'linux',
  String state = 'stopped',
  int cpus = 2,
  int memoryGb = 4,
  int diskGb = 32,
}) =>
    json.encode({
      'vms': [
        {
          'name': name,
          'os': os,
          'state': state,
          'cpus': cpus,
          'memoryBytes': memoryGb * _gb,
          'diskPath': '/store/$name/disk.img',
          'diskSizeBytes': diskGb * _gb,
          'user': 'dev',
        }
      ]
    });

VmResources _resources({
  String os = 'linux',
  bool running = false,
  int cpus = 2,
  int memoryGb = 4,
  int diskGb = 32,
}) =>
    VmResources(
      name: 'dev',
      os: os,
      running: running,
      cpus: cpus,
      memoryBytes: memoryGb * _gb,
      diskSizeBytes: diskGb * _gb,
    );

/// A service whose helper is scripted, so nothing runs vmctl for real.
class _ScriptedService {
  final FakeVmctlShell shell;
  final VmResizeService service;

  factory _ScriptedService() {
    final shell = FakeVmctlShell();
    final api = AppleVmApi(
        shell: shell,
        helperPathOverride: '/helper/vmctl',
        storeDirOverride: '/store');
    return _ScriptedService._(shell, VmResizeService(api));
  }

  _ScriptedService._(this.shell, this.service);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> notices = [];
  final List<InfoBarSeverity> severities = [];

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
      severities.add(severity);
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    notices.clear();
    severities.clear();
  });

  group('the rules', () {
    test('a stopped VM may grow its disk and change either way otherwise', () {
      expect(
          validateVmResize(
              current: _resources(), cpus: 4, memoryGb: 8, diskGb: 64),
          isNull);
      // Memory and CPUs are config only, so down is as safe as up.
      expect(
          validateVmResize(
              current: _resources(), cpus: 1, memoryGb: 2, diskGb: 32),
          isNull);
    });

    test('a disk may not shrink', () {
      expect(
          validateVmResize(
              current: _resources(diskGb: 64), cpus: 2, memoryGb: 4, diskGb: 32),
          'vmresizeshrink-text');
      // Its own size is not a shrink.
      expect(
          validateVmResize(
              current: _resources(diskGb: 64), cpus: 4, memoryGb: 4, diskGb: 64),
          isNull);
    });

    test('a running VM is refused before anything is typed', () {
      expect(
          validateVmResize(
              current: _resources(running: true),
              cpus: 4,
              memoryGb: 8,
              diskGb: 64),
          'vmresizerunning-text');
    });

    test('zero and negative numbers are refused', () {
      for (final bad in [
        [0, 4, 32],
        [2, 0, 32],
        [2, 4, 0],
        [-1, 4, 32],
      ]) {
        expect(
            validateVmResize(
                current: _resources(),
                cpus: bad[0],
                memoryGb: bad[1],
                diskGb: bad[2]),
            'vmresizepositive-text',
            reason: '$bad');
      }
    });

    test('a request that changes nothing is refused', () {
      expect(
          validateVmResize(
              current: _resources(), cpus: 2, memoryGb: 4, diskGb: 32),
          'vmresizenochange-text');
    });

    test('bytes read back as the whole gigabytes they were typed in', () {
      expect(gigabytesOf(32 * _gb), 32);
      // A sparse image a few bytes short of the round number is still 32 GB
      // in the box the user edits, not 31.
      expect(gigabytesOf(32 * _gb - 512), 32);
      expect(gigabytesOf(0), 0);
    });
  });

  group('the service', () {
    test('only the Apple backend is driven', () {
      expect(
          VmResizeService.isSupported(AppleVmApi(shell: FakeVmctlShell())),
          isTrue);
      expect(VmResizeService.isSupported(WSLApi(shell: MockShell())), isFalse);
    });

    test('reads the VM the backend reports', () async {
      final s = _ScriptedService();
      s.shell.responses['list'] = _listJson(memoryGb: 8, diskGb: 64);
      final current = await s.service.read('dev');
      expect(current.cpus, 2);
      expect(current.memoryGb, 8);
      expect(current.diskGb, 64);
      expect(current.running, isFalse);
      expect(current.guestMayGrowItself, isTrue);
    });

    test('a VM the backend has never heard of is named, not invented',
        () async {
      final s = _ScriptedService();
      s.shell.responses['list'] = json.encode({'vms': []});
      await expectLater(
          s.service.read('dev'),
          throwsA(isA<VmResizeException>()
              .having((e) => e.message, 'message', 'vmresizeunknown-text')));
    });

    test('sends only what actually changed', () async {
      final s = _ScriptedService();
      s.shell.responses['list'] = _listJson();
      s.shell.responses['resize'] = json.encode({
        'name': 'dev',
        'cpus': 2,
        'memoryBytes': 8 * _gb,
        'diskSizeBytes': 32 * _gb,
        'guestGrowsFilesystem': true,
      });

      final result =
          await s.service.apply('dev', cpus: 2, memoryGb: 8, diskGb: 32);

      final resize = s.shell.calls.last;
      expect(resize, contains('resize'));
      expect(resize, containsAllInOrder(['--memory', '8']));
      // Untouched knobs are not mentioned at all, so a memory change can
      // never be the thing that trips the helper's grow-only disk rule.
      expect(resize, isNot(contains('--disk-size')));
      expect(resize, isNot(contains('--cpus')));
      expect(result.memoryBytes, 8 * _gb);
      expect(result.diskGrew, isFalse);
      expect(result.needsGuestAction, isFalse);
    });

    test('a grown disk the guest cannot follow is reported as such', () async {
      final s = _ScriptedService();
      s.shell.responses['list'] = _listJson(os: 'macos');
      s.shell.responses['resize'] = json.encode({
        'name': 'dev',
        'cpus': 2,
        'memoryBytes': 4 * _gb,
        'diskSizeBytes': 64 * _gb,
        'guestGrowsFilesystem': false,
      });

      final result =
          await s.service.apply('dev', cpus: 2, memoryGb: 4, diskGb: 64);
      expect(s.shell.calls.last, containsAllInOrder(['--disk-size', '64']));
      expect(result.diskGrew, isTrue);
      expect(result.needsGuestAction, isTrue);
    });

    test('an older helper that says nothing about the guest is not trusted',
        () async {
      final s = _ScriptedService();
      s.shell.responses['list'] = _listJson();
      s.shell.responses['resize'] = json.encode({'name': 'dev'});
      final result =
          await s.service.apply('dev', cpus: 2, memoryGb: 4, diskGb: 64);
      expect(result.guestGrowsFilesystem, isFalse);
      expect(result.needsGuestAction, isTrue);
      // Falls back to what was asked for rather than reporting zeroes.
      expect(result.diskSizeBytes, 64 * _gb);
      expect(result.cpus, 2);
    });

    test('the helper never runs when the request is already wrong', () async {
      final s = _ScriptedService();
      s.shell.responses['list'] = _listJson(diskGb: 64);
      await expectLater(
          s.service.apply('dev', cpus: 2, memoryGb: 4, diskGb: 32),
          throwsA(isA<VmResizeException>()
              .having((e) => e.message, 'message', 'vmresizeshrink-text')));
      expect(s.shell.calls.map((c) => c).where((c) => c.contains('resize')),
          isEmpty);
    });

    test("the helper's own refusal reaches the caller", () async {
      final s = _ScriptedService();
      s.shell.responses['list'] = _listJson();
      s.shell.exitCodes['resize'] = 1;
      s.shell.errors['resize'] =
          '--memory must be between 1 GB and 16 GB on this Mac, got 128 GB.';
      await expectLater(
          s.service.apply('dev', cpus: 2, memoryGb: 128, diskGb: 32),
          throwsA(isA<VmResizeException>().having((e) => e.message, 'message',
              contains('must be between 1 GB and 16 GB'))));
    });
  });

  group('the dialog', () {
    Future<void> pumpAndOpen(WidgetTester tester, FakeVmctlShell shell) async {
      await tester.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = AppleVmApi(
          shell: shell,
          helperPathOverride: '/helper/vmctl',
          storeDirOverride: '/store');
      final service = VmResizeService(api);
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Builder(
            builder: (context) => Button(
              child: const Text('open'),
              onPressed: () =>
                  showVmResizeDialog('dev', service: service, context: context),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('opens on the numbers the VM already has', (tester) async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson(cpus: 6, memoryGb: 8, diskGb: 64);
      await pumpAndOpen(tester, shell);

      expect(
          tester
              .widget<TextBox>(find.byKey(const ValueKey('test-vmresize-cpus')))
              .controller!
              .text,
          '6');
      expect(
          tester
              .widget<TextBox>(
                  find.byKey(const ValueKey('test-vmresize-memory')))
              .controller!
              .text,
          '8');
      expect(
          tester
              .widget<TextBox>(find.byKey(const ValueKey('test-vmresize-disk')))
              .controller!
              .text,
          '64');
    });

    testWidgets('a running VM says why and cannot be saved', (tester) async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson(state: 'running');
      await pumpAndOpen(tester, shell);

      expect(find.byKey(const ValueKey('test-vmresize-running')), findsOneWidget);
      final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('test-vmresize-save')));
      expect(save.onPressed, isNull);
    });

    testWidgets('a shrink is refused under the boxes and never sent',
        (tester) async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson(diskGb: 64);
      await pumpAndOpen(tester, shell);

      await tester.enterText(
          find.byKey(const ValueKey('test-vmresize-disk')), '32');
      await tester.tap(find.byKey(const ValueKey('test-vmresize-save')));
      await tester.pumpAndSettle();

      expect(find.text('vmresizeshrink-text'), findsOneWidget);
      expect(shell.calls.any((c) => c.contains('resize')), isFalse);
      // The dialog stays open on its own error.
      expect(find.byType(ContentDialog), findsOneWidget);

      // Typing again clears the message.
      await tester.enterText(
          find.byKey(const ValueKey('test-vmresize-disk')), '128');
      await tester.pumpAndSettle();
      expect(find.text('vmresizeshrink-text'), findsNothing);
    });

    testWidgets('a word in a box is refused before anything is sent',
        (tester) async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson();
      await pumpAndOpen(tester, shell);

      await tester.enterText(
          find.byKey(const ValueKey('test-vmresize-memory')), 'lots');
      await tester.tap(find.byKey(const ValueKey('test-vmresize-save')));
      await tester.pumpAndSettle();

      expect(find.text('vmresizepositive-text'), findsOneWidget);
      expect(shell.calls.any((c) => c.contains('resize')), isFalse);
    });

    testWidgets('a saved resize reports it and closes', (tester) async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson();
      shell.responses['resize'] = json.encode({
        'name': 'dev',
        'cpus': 4,
        'memoryBytes': 4 * _gb,
        'diskSizeBytes': 64 * _gb,
        'guestGrowsFilesystem': true,
      });
      await pumpAndOpen(tester, shell);

      await tester.enterText(
          find.byKey(const ValueKey('test-vmresize-cpus')), '4');
      await tester.enterText(
          find.byKey(const ValueKey('test-vmresize-disk')), '64');
      await tester.tap(find.byKey(const ValueKey('test-vmresize-save')));
      await tester.pumpAndSettle();

      expect(shell.calls.last, containsAllInOrder(['--cpus', '4']));
      expect(shell.calls.last, containsAllInOrder(['--disk-size', '64']));
      expect(notices, contains('vmresized-text'));
      // The guest grows its own root here, so nothing asks the user to.
      expect(notices, isNot(contains('vmresizeguestmanual-text')));
      expect(find.byType(ContentDialog), findsNothing);
    });

    testWidgets('a guest that cannot grow itself is told to the user',
        (tester) async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson(os: 'macos');
      shell.responses['resize'] = json.encode({
        'name': 'dev',
        'cpus': 2,
        'memoryBytes': 4 * _gb,
        'diskSizeBytes': 64 * _gb,
        'guestGrowsFilesystem': false,
      });
      await pumpAndOpen(tester, shell);

      await tester.enterText(
          find.byKey(const ValueKey('test-vmresize-disk')), '64');
      await tester.tap(find.byKey(const ValueKey('test-vmresize-save')));
      await tester.pumpAndSettle();

      expect(notices, contains('vmresizeguestmanual-text'));
      expect(severities, contains(InfoBarSeverity.warning));
    });

    testWidgets("the helper's refusal is shown in the dialog, which stays open",
        (tester) async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson();
      shell.exitCodes['resize'] = 1;
      shell.errors['resize'] = 'VM dev is running; stop it before resizing.';
      await pumpAndOpen(tester, shell);

      await tester.enterText(
          find.byKey(const ValueKey('test-vmresize-cpus')), '4');
      await tester.tap(find.byKey(const ValueKey('test-vmresize-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('test-vmresize-field-error')),
          findsOneWidget);
      expect(find.byType(ContentDialog), findsOneWidget);
    });

    testWidgets('a backend that cannot be read says so instead of an empty form',
        (tester) async {
      final shell = FakeVmctlShell();
      shell.exitCodes['list'] = 1;
      shell.errors['list'] = 'vmctl: no such store';
      await pumpAndOpen(tester, shell);

      expect(find.byKey(const ValueKey('test-vmresize-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-vmresize-cpus')), findsNothing);
    });
  });

  group('the row', () {
    tearDown(() {
      vmBackendBuilder = defaultVmBackendBuilder;
    });

    Future<void> pumpRow(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(FluentApp(
        home: ScaffoldPage(
          content: Bar(
            widget: const ListItem(
                item: 'dev', running: [], trailing: '2.1 GB'),
            isCleaning: false,
            onCleaningChanged: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a VM row offers the resize button', (tester) async {
      vmBackendBuilder = () => AppleVmApi(
          shell: FakeVmctlShell(),
          helperPathOverride: '/helper/vmctl',
          storeDirOverride: '/store');
      await pumpRow(tester);
      expect(find.byKey(const ValueKey('test-listitem-resize-dev')),
          findsOneWidget);
    });

    testWidgets('a WSL distro row does not — it sizes its disk elsewhere',
        (tester) async {
      vmBackendBuilder = () => WSLApi(shell: MockShell());
      await pumpRow(tester);
      expect(
          find.byKey(const ValueKey('test-listitem-resize-dev')), findsNothing);
    });
  });

  group('the MCP tool', () {
    AppleVmApi apiOver(FakeVmctlShell shell) => AppleVmApi(
        shell: shell,
        helperPathOverride: '/helper/vmctl',
        storeDirOverride: '/store');

    test('vm_resize changes only the values it was given', () async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson(cpus: 2, memoryGb: 4, diskGb: 32);
      shell.responses['resize'] = json.encode({
        'name': 'dev',
        'cpus': 2,
        'memoryBytes': 4 * _gb,
        'diskSizeBytes': 64 * _gb,
        'guestGrowsFilesystem': true,
      });
      final api = apiOver(shell);
      final tools = buildWslMcpTools(api, WslTerminalManager(wslApi: api));
      final resize = tools.firstWhere((t) => t.name == 'vm_resize').handler;

      final out = await resize({'name': 'dev', 'disk_gb': 64});
      expect(shell.calls.last, containsAllInOrder(['--disk-size', '64']));
      // The knobs left out keep what the VM already had, and are not sent.
      expect(shell.calls.last, isNot(contains('--cpus')));
      expect(out, contains('64 GB disk'));
    });

    test('vm_resize is offered only on the Apple backend', () {
      final wsl = WSLApi(shell: MockShell());
      final names = buildWslMcpTools(wsl, WslTerminalManager(wslApi: wsl))
          .map((t) => t.name);
      expect(names, isNot(contains('vm_resize')));
    });

    test('vm_resize refuses in English, not in i18n keys', () async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = _listJson(diskGb: 64);
      final api = apiOver(shell);
      final tools = buildWslMcpTools(api, WslTerminalManager(wslApi: api));
      final resize = tools.firstWhere((t) => t.name == 'vm_resize').handler;

      // A model on the other end of this cannot do anything with
      // "vmresizeshrink-text".
      await expectLater(
          resize({'name': 'dev', 'disk_gb': 32}),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              contains('A disk can only grow'))));
      expect(shell.calls.any((c) => c.contains('resize')), isFalse);

      await expectLater(
          resize({'name': 'dev'}),
          throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
              contains('values the VM already has'))));

      shell.responses['list'] = json.encode({'vms': []});
      await expectLater(
          resize({'name': 'gone', 'disk_gb': 64}),
          throwsA(isA<ArgumentError>().having(
              (e) => '${e.message}', 'message', contains('No VM by that name'))));

      // Every key the validator can return has a sentence to go with it.
      for (final key in [
        'vmresizerunning-text',
        'vmresizepositive-text',
        'vmresizeshrink-text',
        'vmresizenochange-text',
        'vmresizeunknown-text',
      ]) {
        expect(vmResizeProblemSummaries, contains(key));
      }
    });
  });
}
