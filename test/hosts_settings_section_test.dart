/// Tests for lib/components/hosts_settings_section.dart — the Settings
/// section behind the hosts-file entries (bostrot/ai-tasks#90).
///
/// No localization delegate here, so `.i18n()` returns the key it was given.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/hosts_file_service.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/hosts_settings_section.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_provisioning_backend.dart';

/// A backend with guests actually running, so `listRunning` has something to
/// say — the plain [ScriptedBackend] reports none.
class RunningBackend extends ScriptedBackend {
  RunningBackend(this.running) : remote = false;

  final List<String> running;
  final bool remote;

  RunningBackend.remote()
      : running = const ['Ubuntu'],
        remote = true;

  @override
  bool get isRemote => remote;

  @override
  Future<List<String>> listRunning() async => running;
}

/// Answers every elevation with success, does the copy the real elevated
/// command would do, and remembers it happened.
class RecordingShell implements Shell {
  RecordingShell(this.hostsPath);

  final String hostsPath;
  final List<String> executables = [];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async {
    executables.add(executable);
    final staged = File('${Directory.systemTemp.path}'
        '${Platform.pathSeparator}wslm_hosts.txt');
    if (staged.existsSync()) {
      File(hostsPath).writeAsStringSync(staged.readAsStringSync());
    }
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Writing the hosts file is a Windows/macOS affair; a Linux checkout runs
  // only the part that needs no elevation.
  final elevates = Platform.isWindows || Platform.isMacOS;

  final List<String> notices = [];
  late Directory dir;

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
    SharedPreferences.setMockInitialValues({'HostsFileSuffix': 'wsl'});
    prefs = await SharedPreferences.getInstance();
    notices.clear();
    dir = Directory.systemTemp.createTempSync('wslm_hosts_widget');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File hostsFile(String content) =>
      File('${dir.path}${Platform.pathSeparator}hosts')
        ..writeAsStringSync(content);

  Future<void> pump(WidgetTester tester, HostsFileService service) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: SingleChildScrollView(
          child: HostsSettingsSection(service: service),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Taps [key] and lets the service's file work actually run — it touches
  /// dart:io, which the fake clock in a widget test would otherwise hold.
  ///
  /// [done] turns the wait into a poll. One flat 50 ms was enough only while
  /// the machine was idle: with the rest of the suite running beside it, the
  /// file work regularly landed after the assertions and failed the run at
  /// random.
  Future<void> tapAndSettle(WidgetTester tester, Key key,
      {bool Function()? done}) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(key));
      await tester.pump();
      for (var round = 0; round < 60; round++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (done == null || done()) break;
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('writes the running instances and lists what it wrote',
      (tester) async {
    final backend = RunningBackend(['Ubuntu']);
    backend.answers
        .add(VmCommandOutput(0, 'ubuntu\n__WSLM__\n172.24.128.2\n', ''));
    final path = hostsFile('').path;
    final shell = RecordingShell(path);
    final service =
        HostsFileService(backend: backend, shell: shell, hostsPath: path);

    await pump(tester, service);
    await tapAndSettle(tester, HostsSettingsSection.syncKey,
        done: () => shell.executables.isNotEmpty);

    expect(shell.executables, hasLength(1));
    expect(find.textContaining('ubuntu.wsl'), findsOneWidget);
    expect(find.textContaining('172.24.128.2'), findsOneWidget);
    expect(notices, contains('hostsfilewritten-text'));
  }, skip: !elevates);

  testWidgets('says so instead of writing when nothing moved', (tester) async {
    final backend = RunningBackend(['Ubuntu']);
    backend.answers
        .add(VmCommandOutput(0, 'ubuntu\n__WSLM__\n172.24.128.2\n', ''));
    final wanted = HostsFileService.applyBlock('127.0.0.1\tlocalhost\n', const [
      HostsEntry(
          instance: 'Ubuntu', ip: '172.24.128.2', hostname: 'ubuntu.wsl'),
    ]);
    final path = hostsFile(wanted).path;
    final shell = RecordingShell(path);
    final service =
        HostsFileService(backend: backend, shell: shell, hostsPath: path);

    await pump(tester, service);
    await tapAndSettle(tester, HostsSettingsSection.syncKey);

    expect(shell.executables, isEmpty);
    expect(notices, contains('hostsfileunchanged-text'));
  }, skip: !elevates);

  testWidgets('removing the entries takes the block out again', (tester) async {
    final written =
        HostsFileService.applyBlock('127.0.0.1\tlocalhost\n', const [
      HostsEntry(
          instance: 'Ubuntu', ip: '172.24.128.2', hostname: 'ubuntu.wsl'),
    ]);
    final file = hostsFile(written);
    final shell = RecordingShell(file.path);
    final service = HostsFileService(
        backend: RunningBackend(['Ubuntu']),
        shell: shell,
        hostsPath: file.path);

    await pump(tester, service);
    await tapAndSettle(tester, HostsSettingsSection.clearKey);

    expect(shell.executables, hasLength(1));
    expect(notices, contains('hostsfilecleared-text'));
  }, skip: !elevates);

  testWidgets('the switch remembers the choice', (tester) async {
    final backend = RunningBackend(['Ubuntu']);
    backend.answers
        .add(VmCommandOutput(0, 'ubuntu\n__WSLM__\n172.24.128.2\n', ''));
    final path = hostsFile('').path;
    final service = HostsFileService(
        backend: backend, shell: RecordingShell(path), hostsPath: path);

    await pump(tester, service);
    await tapAndSettle(tester, HostsSettingsSection.toggleKey);

    expect(prefs.getBool(HostsFileService.prefEnabled), isTrue);
    service.stopAutoSync();
  }, skip: !elevates);

  testWidgets('a remote host gets the explanation, not the controls',
      (tester) async {
    final path = hostsFile('').path;
    final service = HostsFileService(
        backend: RunningBackend.remote(),
        shell: RecordingShell(path),
        hostsPath: path);

    await pump(tester, service);

    expect(find.text('hostsfileunsupported-text'), findsOneWidget);
    expect(find.byKey(HostsSettingsSection.syncKey), findsNothing);
  });
}
