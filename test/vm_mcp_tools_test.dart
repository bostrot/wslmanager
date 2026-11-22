import 'package:fluent_ui/fluent_ui.dart' show InfoBarSeverity;
import 'dart:io';
import 'package:wsl2distromanager/api/apple/vm_image_catalog.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_vmctl_shell.dart';
import 'mocks.dart';
import 'vm_backend_test.dart' show FakeBackend;

/// A catalog whose download is a fixed local file — no network.
class _FixedDownloadCatalog implements VmImageCatalog {
  _FixedDownloadCatalog(this.path);
  final String path;

  @override
  Future<String> download(VmIsoCatalogEntry entry,
      {void Function(int, int)? onProgress,
      CancelSignal? cancelSignal}) async => path;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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
        leadingIcon = true,
        dynamic widget}) {};
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Set<String> namesOf(List tools) =>
      tools.map((t) => t.name as String).toSet();

  group('tool registry composition', () {
    test('a plain backend gets the generic surface only', () {
      final backend = FakeBackend();
      final names = namesOf(
          buildWslMcpTools(backend, WslTerminalManager(wslApi: backend)));

      // The lifecycle every backend shares.
      expect(
          names,
          containsAll([
            'wsl_list_distros',
            'wsl_distro_info',
            'wsl_export_distro',
            'wsl_unregister_distro',
            'wsl_run_command',
            'wsl_stop_distro',
            'wsl_shutdown',
            'wsl_terminal_start',
            'wsl_terminal_close',
            'wsl_list_snippets',
            'wsl_list_recipes',
            'wsl_install_service',
          ]));
      // Nothing WSL- or Apple-specific.
      expect(names, isNot(contains('wsl_set_wslconfig')));
      expect(names, isNot(contains('wsl_mount_disk')));
      expect(names, isNot(contains('wsl_package_distro')));
      expect(names, isNot(contains('vm_create_linux')));
    });

    test('the WSL backend also gets the WSL-only families', () {
      final wslApi = WSLApi(shell: MockShell());
      final names = namesOf(
          buildWslMcpTools(wslApi, WslTerminalManager(wslApi: wslApi)));
      expect(
          names,
          containsAll([
            'wsl_status',
            'wsl_import_distro',
            'wsl_get_wsl_conf',
            'wsl_set_wslconfig',
            'wsl_move_distro',
            'wsl_mount_disk',
            'wsl_package_distro',
            'wsl_set_version',
          ]));
      expect(names, isNot(contains('vm_create_linux')));
    });

    test('the Apple backend brings the vm_* tools instead', () {
      final api = AppleVmApi(
          shell: FakeVmctlShell(),
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test');
      final names =
          namesOf(buildWslMcpTools(api, WslTerminalManager(wslApi: api)));
      expect(
          names,
          containsAll([
            'vm_list_images',
            'vm_create_linux',
            'vm_create_macos',
            'vm_start',
            'vm_stop',
            'vm_restart',
            'vm_ip',
            'vm_import_image',
            'wsl_list_distros',
            'wsl_run_command',
          ]));
      expect(names, isNot(contains('wsl_set_wslconfig')));
      expect(names, isNot(contains('wsl_mount_disk')));
    });
  });

  group('generic handlers on a non-WSL backend', () {
    late FakeBackend backend;
    late Map<String, dynamic Function(Map<String, dynamic>)> handlers;

    setUp(() {
      backend = FakeBackend();
      final tools =
          buildWslMcpTools(backend, WslTerminalManager(wslApi: backend));
      handlers = {for (final t in tools) t.name: t.handler};
    });

    test('wsl_list_distros lists through the backend', () async {
      final out = await handlers['wsl_list_distros']!({});
      expect(out, contains('one'));
      expect(out, contains('stopped'));
    });

    test('wsl_unregister_distro still demands the confirm flag', () async {
      expect(
        () => handlers['wsl_unregister_distro']!({'distro': 'one'}),
        throwsArgumentError,
      );
      final out = await handlers['wsl_unregister_distro']!(
          {'distro': 'one', 'confirm': true});
      expect(out, contains('Unregistered'));
    });

    test('wsl_run_command falls back to execCmdAsRoot', () async {
      final out = await handlers['wsl_run_command']!(
          {'distro': 'one', 'command': 'echo hi'});
      // FakeBackend returns nothing, which reports as such rather than
      // failing.
      expect(out, '(no output)');
    });
  });

  group('apple handlers', () {
    test('vm_create_linux forwards to vmctl create', () async {
      final shell = FakeVmctlShell();
      shell.responses['create'] = '{"created":"dev"}';
      final api = AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test');
      final tools =
          buildWslMcpTools(api, WslTerminalManager(wslApi: api));
      final create =
          tools.firstWhere((t) => t.name == 'vm_create_linux').handler;
      final out = await create({'name': 'dev', 'cpus': 6, 'image_path': '/tmp/cloud.img'});
      expect(out, contains('dev'));
      expect(shell.calls.last, containsAll(['create', '--cpus', '6']));
    });

    test('vm_create_linux refuses a blank disk', () async {
      final shell = FakeVmctlShell();
      final api = AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test');
      final tools =
          buildWslMcpTools(api, WslTerminalManager(wslApi: api));
      final create =
          tools.firstWhere((t) => t.name == 'vm_create_linux').handler;
      await expectLater(create({'name': 'blank'}), throwsArgumentError);
      expect(shell.calls.any((c) => c.contains('create')), isFalse);
    });

    test('a cloud catalog id seeds the disk, not the ISO slot', () async {
      final shell = FakeVmctlShell();
      final api = AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test');
      final dir = Directory.systemTemp.createTempSync('mcp-cloud-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final image = File('${dir.path}/debian.raw')..writeAsBytesSync([1]);
      vmImageCatalogBuilder = () => _FixedDownloadCatalog(image.path);
      addTearDown(() => vmImageCatalogBuilder = () => VmImageCatalog());

      final tools =
          buildWslMcpTools(api, WslTerminalManager(wslApi: api));
      final out = await tools
          .firstWhere((t) => t.name == 'vm_create_linux')
          .handler({'name': 'cloudy', 'catalog': 'debian-13-cloud'});

      final createCall = shell.calls.lastWhere((c) => c.contains('create'));
      expect(createCall, contains('--image'));
      expect(createCall[createCall.indexOf('--image') + 1], image.path);
      expect(createCall.contains('--iso'), isFalse);
      expect(out, contains('ready to use'));
    });

    test('vm_list_images lists catalog ids', () async {
      final api = AppleVmApi(
          shell: FakeVmctlShell(),
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test');
      final tools =
          buildWslMcpTools(api, WslTerminalManager(wslApi: api));
      final out = await tools
          .firstWhere((t) => t.name == 'vm_list_images')
          .handler({});
      expect(out, contains('alpine-linux-virt'));
    });

    test('vm_restart stops, starts and reports the address', () async {
      final shell = FakeVmctlShell();
      shell.responses['stop'] = '{"stopped":"dev"}';
      shell.responses['start'] = '{"started":"dev"}';
      shell.responses['ip'] = '{"ip":"192.168.64.10"}';
      // Running, down after the stop, up again after the start.
      shell.responseQueue['list'] = [
        '{"vms":[{"name":"dev","state":"running"}]}',
        '{"vms":[{"name":"dev","state":"stopped"}]}',
        '{"vms":[{"name":"dev","state":"running"}]}',
      ];
      final api = AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test',
          earlyExitProbeDelay: Duration.zero);
      final tools = buildWslMcpTools(api, WslTerminalManager(wslApi: api));

      final out = await tools
          .firstWhere((t) => t.name == 'vm_restart')
          .handler({'name': 'dev'});

      final vmctl = shell.calls.where((c) => c.first == '/fake/vmctl');
      expect(vmctl.any((c) => c.contains('stop')), isTrue);
      expect(vmctl.any((c) => c.contains('start')), isTrue);
      expect(out, contains('Restarted dev'));
      expect(out, contains('192.168.64.10'));
    });

    test('vm_stop leaves an already stopped VM alone', () async {
      final shell = FakeVmctlShell();
      shell.responses['list'] = '{"vms":[{"name":"dev","state":"stopped"}]}';
      final api = AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test',
          earlyExitProbeDelay: Duration.zero);
      final tools = buildWslMcpTools(api, WslTerminalManager(wslApi: api));

      final out = await tools
          .firstWhere((t) => t.name == 'vm_stop')
          .handler({'name': 'dev'});

      expect(out, contains('already stopped'));
      expect(shell.calls.any((c) => c.contains('stop')), isFalse);
    });

    test('vm_start is headless unless gui is asked for', () async {
      final shell = FakeVmctlShell();
      shell.responses['start'] = '{}';
      shell.responses['list'] = '{"vms":[{"name":"dev","state":"running"}]}';
      final api = AppleVmApi(
          shell: shell,
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '/tmp/vm-mcp-test',
          earlyExitProbeDelay: Duration.zero);
      final tools =
          buildWslMcpTools(api, WslTerminalManager(wslApi: api));
      final start = tools.firstWhere((t) => t.name == 'vm_start').handler;

      List<String> startCall() =>
          shell.calls.lastWhere((c) => c.contains('start'));
      await start({'name': 'dev'});
      expect(startCall(), isNot(contains('--gui')));
      await start({'name': 'dev', 'gui': true});
      expect(startCall(), contains('--gui'));
    });
  });

  group('recipe tools on any backend', () {
    test('wsl_list_recipes enumerates the catalog', () async {
      final backend = FakeBackend();
      final tools =
          buildWslMcpTools(backend, WslTerminalManager(wslApi: backend));
      final list = tools.firstWhere((t) => t.name == 'wsl_list_recipes');
      final out = await list.handler({});
      expect(out, contains('minio'));
      expect(out, contains('postgres'));
    });

    test('wsl_install_service refuses an unknown recipe id', () async {
      final backend = FakeBackend();
      final tools =
          buildWslMcpTools(backend, WslTerminalManager(wslApi: backend));
      final install =
          tools.firstWhere((t) => t.name == 'wsl_install_service');
      expect(
          () => install.handler({'distro': 'box', 'recipe': 'ghost'}),
          throwsArgumentError);
    });
  });
}
