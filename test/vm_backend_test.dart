import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/templates.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The smallest possible backend: proves the app only needs the base type.
class FakeBackend extends VmBackend {
  @override
  String get backendId => 'fake';

  @override
  String get instanceNoun => 'box';

  @override
  VmFeatures get features => const VmFeatures();

  @override
  Future<Instances> list(bool showDocker) async => Instances(['one'], []);

  @override
  Future<List<String>> listRunning() async => [];

  @override
  Future<void> start(String distribution,
      {String startPath = '', String startUser = '', String startCmd = ''}) async {}

  @override
  Future<String> stop(String distribution) async => '';

  @override
  Future<String> shutdown() async => '';

  @override
  Future<String> remove(String distribution) async => '';

  @override
  Future<String> export(String distribution, String location,
          {String? format}) async =>
      '';

  @override
  Future<String> import(
          String distribution, String installLocation, String filename,
          {bool isVhd = false}) async =>
      '';

  @override
  Future<String> execCmdAsRoot(String distribution, String cmd) async => '';

  @override
  Future<VmCommandOutput> runInInstance(
    String instance,
    String command, {
    String user = 'root',
    String cwd = '',
    Duration timeout = const Duration(minutes: 5),
  }) async =>
      const VmCommandOutput(0, '', '');

  @override
  Future<String?> readInstanceFile(String instance, String path) async => null;

  @override
  Future<bool> writeInstanceFile(
          String instance, String path, String content) async =>
      false;

  @override
  Future<Process> startShell(String distribution, {String? user}) =>
      throw UnsupportedError('no shell in the fake');

  @override
  Future<String?> getSize(String distribution) async => null;

  @override
  String currentDistroPath(String distribution) => '/nowhere';

  @override
  Future<String> getDefaultUser(String distribution) async => 'root';

  @override
  Future<void> runCommands(String instance, List<String> commands,
      {String? user, Map<String, String> env = const {}}) async {}

  @override
  Future<String> copy(String distribution, String newName) async => '';

  @override
  void startExplorer(String distribution) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    vmBackendBuilder = defaultVmBackendBuilder;
  });

  group('vmBackend factory', () {
    test('default backend matches the host platform', () {
      final backend = vmBackend();
      if (Platform.isMacOS) {
        expect(backend, isA<AppleVmApi>());
      } else {
        expect(backend, isA<WSLApi>());
      }
    });

    test('a configured remote WSL target switches a Mac to the WSL backend',
        () async {
      SharedPreferences.setMockInitialValues({
        'UseRemoteWSL': true,
        'RemoteWSLTarget': 'eric@192.168.1.20',
      });
      prefs = await SharedPreferences.getInstance();
      final backend = defaultVmBackendBuilder();
      if (Platform.isMacOS) {
        expect(backend, isA<WSLApi>(),
            reason: 'remote WSL outranks native VMs when configured');
        expect(backend.isRemote, isTrue);
      } else {
        expect(backend, isA<WSLApi>());
      }
      // An invalid target must not strand the Mac on a dead backend.
      SharedPreferences.setMockInitialValues({
        'UseRemoteWSL': true,
        'RemoteWSLTarget': 'not a target',
      });
      prefs = await SharedPreferences.getInstance();
      if (Platform.isMacOS) {
        expect(defaultVmBackendBuilder(), isA<AppleVmApi>());
      }
    });

    test('the builder seam swaps the backend for the whole app', () {
      final fake = FakeBackend();
      vmBackendBuilder = () => fake;
      expect(vmBackend(), same(fake));
    });
  });

  group('backend contracts', () {
    test('WSL backend declares the full WSL feature set', () {
      final features = WSLApi().features;
      expect(features.wslConfig, isTrue);
      expect(features.packaging, isTrue);
      expect(features.mountDisk, isTrue);
      // The AI Workspace needs a local wsl.exe, so it follows the host.
      expect(features.aiWorkspace, Platform.isWindows);
      expect(features.quickActions, isTrue);
      expect(features.cleanup, isTrue);
      expect(features.hostIntegration, isTrue);
      // Templates are superseded by distro packages on WSL only.
      expect(features.templatesDeprecated, isTrue);
      expect(WSLApi().templateExtension, 'ext4');
      expect(WSLApi().backendId, 'wsl');
    });

    test('base defaults: not remote, no size label', () {
      final fake = FakeBackend();
      expect(fake.isRemote, isFalse);
      expect(fake.remoteLabel, '');
      expect(fake.instanceSizeLabel('anything'), '');
      expect(fake.templateExtension, 'ext4');
    });

    test('utf8Convert survives malformed bytes and strips control chars', () {
      final fake = FakeBackend();
      expect(fake.utf8Convert([]), '');
      // 0x08 (backspace) is stripped; \n and printable text survive.
      expect(fake.utf8Convert([0x61, 0x08, 0x62, 0x0A, 0x63]), 'ab\nc');
    });
  });

  group('Templates follow the backend', () {
    test('template files use the backend extension', () {
      final templates = Templates(wslApi: FakeBackend());
      expect(templates.extension, 'ext4');
      expect(templates.getTemplateFilePath('base'), endsWith('base.ext4'));
    });

    test('Apple templates are raw disk images', () {
      final apple = AppleVmApi(
          helperPathOverride: '/fake/vmctl', storeDirOverride: '/tmp/x');
      final templates = Templates(wslApi: apple);
      expect(templates.extension, 'img');
      expect(templates.getTemplateFilePath('base'), endsWith('base.img'));
    });

    test('scanTemplateFiles only picks up the backend extension', () async {
      final dataDir = Directory.systemTemp.createTempSync('tpl-test');
      addTearDown(() => dataDir.deleteSync(recursive: true));
      await prefs.setString('DataPath', dataDir.path);
      Directory('${dataDir.path}/templates').createSync();
      File('${dataDir.path}/templates/a.ext4').writeAsStringSync('x');
      File('${dataDir.path}/templates/b.img').writeAsStringSync('x');

      expect(Templates(wslApi: FakeBackend()).scanTemplateFiles(), ['a']);
      final apple = AppleVmApi(
          helperPathOverride: '/fake/vmctl',
          storeDirOverride: '${dataDir.path}/vms');
      expect(Templates(wslApi: apple).scanTemplateFiles(), ['b']);
    });
  });
}
