import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/api/cloud/cloud_provider.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';

import 'mocks.dart' show MockProcess;

/// A scripted `ssh`/`scp`/`ssh-keygen`: answers by substring match on the
/// whole command line and records every invocation, so a test can assert on
/// the exact argv a deploy sends across.
class FakeCloudShell implements Shell {
  /// Every `[executable, ...arguments]` this shell has been handed.
  final List<List<String>> calls = [];

  /// stdout for the first invocation whose command line contains the key.
  final Map<String, String> responses = {};

  /// stderr, same keys.
  final Map<String, String> errors = {};

  /// Exit codes, same keys. Absent means 0.
  final Map<String, int> exitCodes = {};

  /// Keys whose *first* N calls fail with exit 255, the way ssh does against
  /// a server that has not finished booting.
  final Map<String, int> failFirst = {};

  /// The whole command line of every call, for readable assertions.
  List<String> get commandLines => calls.map((c) => c.join(' ')).toList();

  /// Whether any call's command line contains [needle].
  bool sawCommand(String needle) =>
      commandLines.any((line) => line.contains(needle));

  /// The first command line containing [needle], or '' when there is none.
  String commandContaining(String needle) => commandLines.firstWhere(
      (line) => line.contains(needle),
      orElse: () => '');

  String? _match(Map<String, dynamic> table, String line) {
    for (final key in table.keys) {
      if (line.contains(key)) return key;
    }
    return null;
  }

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
    final process = await start(executable, arguments);
    return ProcessResult(0, await process.exitCode, '', '');
  }

  /// [CloudDeployService] runs everything through `ExecutionBroker`, which
  /// spawns rather than runs, so this is the channel the tests exercise.
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    calls.add([executable, ...arguments]);
    final line = [executable, ...arguments].join(' ');

    final failKey = _match(failFirst, line);
    if (failKey != null && failFirst[failKey]! > 0) {
      failFirst[failKey] = failFirst[failKey]! - 1;
      return MockProcess(exitCode: 255, stderr: 'Connection refused');
    }

    final stdoutKey = _match(responses, line);
    final stderrKey = _match(errors, line);
    final exitKey = _match(exitCodes, line);
    return MockProcess(
      exitCode: exitKey == null ? 0 : exitCodes[exitKey]!,
      stdout: stdoutKey == null ? '' : responses[stdoutKey]!,
      stderr: stderrKey == null ? '' : errors[stderrKey]!,
    );
  }
}

/// An in-memory cloud account.
class FakeCloudProvider implements CloudProvider {
  FakeCloudProvider({
    this.servers = const [],
    this.sshKeys = const [],
    this.catalogueValue = const CloudCatalogue(),
  });

  List<CloudServer> servers;
  List<CloudSshKey> sshKeys;
  CloudCatalogue catalogueValue;

  /// Servers handed back by consecutive [getServer] calls, so a test can walk
  /// a create from `initializing` to `running`.
  final List<CloudServer> getServerAnswers = [];
  int getServerCalls = 0;

  final List<String> deleted = [];
  final List<String> poweredOn = [];
  final List<String> poweredOff = [];
  final List<CloudSshKey> createdKeys = [];

  /// The arguments of the last [createServer], for assertions.
  Map<String, Object?> lastCreate = const {};

  /// When set, every call throws it.
  CloudException? failure;

  @override
  CloudProviderId get id => CloudProviderId.hetzner;

  void _check() {
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<List<CloudServer>> listServers() async {
    _check();
    return servers;
  }

  @override
  Future<CloudServer> getServer(String serverId) async {
    _check();
    if (getServerAnswers.isEmpty) {
      return servers.firstWhere((s) => s.id == serverId);
    }
    final index = getServerCalls++;
    return getServerAnswers[
        index < getServerAnswers.length ? index : getServerAnswers.length - 1];
  }

  @override
  Future<CloudCatalogue> catalogue() async {
    _check();
    return catalogueValue;
  }

  @override
  Future<List<CloudSshKey>> listSshKeys() async {
    _check();
    return sshKeys;
  }

  @override
  Future<CloudSshKey> createSshKey(String name, String publicKey) async {
    _check();
    final key = CloudSshKey(id: '${createdKeys.length + 100}', name: name);
    createdKeys.add(key);
    return key;
  }

  @override
  Future<CloudServer> createServer({
    required String name,
    required String serverType,
    required String image,
    required String location,
    List<String> sshKeyIds = const [],
    String userData = '',
    Map<String, String> labels = const {},
  }) async {
    _check();
    lastCreate = {
      'name': name,
      'serverType': serverType,
      'image': image,
      'location': location,
      'sshKeyIds': sshKeyIds,
      'userData': userData,
      'labels': labels,
    };
    return CloudServer(
      id: '1',
      name: name,
      state: CloudServerState.initializing,
      provider: CloudProviderId.hetzner,
      labels: labels,
    );
  }

  @override
  Future<void> powerOn(String serverId) async {
    _check();
    poweredOn.add(serverId);
  }

  @override
  Future<void> powerOff(String serverId) async {
    _check();
    poweredOff.add(serverId);
  }

  @override
  Future<void> deleteServer(String serverId) async {
    _check();
    deleted.add(serverId);
  }

  @override
  Future<void> verifyToken() async => _check();
}

/// A [VmBackend] that only does what a deploy asks of it: list, export and
/// import. Everything else throws, so a change that starts calling something
/// heavier from the deploy path fails loudly instead of hitting a real
/// `wsl.exe`.
class FakeDeployBackend extends VmBackend {
  FakeDeployBackend({
    this.instances = const ['Ubuntu'],
    this.rootfsExport = true,
    this.rootfsImportNeedsBase = false,
    this.exportFails = false,
  });

  List<String> instances;
  final bool rootfsExport;
  final bool rootfsImportNeedsBase;
  final bool exportFails;

  /// Sub-steps the backend reports while exporting, in order.
  List<String> exportStatus = const [];

  @override
  Future<void> exportRootfs(String instance, String tarPath,
      {void Function(String detail)? onStatus}) async {
    for (final status in exportStatus) {
      onStatus?.call(status);
    }
    await super.exportRootfs(instance, tarPath, onStatus: onStatus);
  }

  /// `[distribution, location, format]` of every export.
  final List<List<String?>> exports = [];

  /// `[distribution, installLocation, filename]` of every import.
  final List<List<String>> imports = [];

  /// `[name, tarPath, sourceInstance]` of every rootfs import. Separate from
  /// [imports] because the source is what a backend that cannot boot a bare
  /// filesystem restores onto, and losing it on the way through the deploy
  /// service would only show up on macOS.
  final List<List<String>> rootfsImports = [];

  @override
  Future<void> importRootfs(String name, String tarPath,
      {String installLocation = '',
      String sourceInstance = '',
      void Function(String detail)? onStatus}) async {
    rootfsImports.add([name, tarPath, sourceInstance]);
    await super.importRootfs(name, tarPath,
        installLocation: installLocation,
        sourceInstance: sourceInstance,
        onStatus: onStatus);
  }

  @override
  String get backendId => 'fake';

  @override
  String get instanceNoun => 'distro';

  @override
  VmFeatures get features => VmFeatures(
      rootfsExport: rootfsExport,
      rootfsImportNeedsBase: rootfsImportNeedsBase);

  @override
  Future<Instances> list(bool showDocker) async =>
      Instances(instances, instances);

  @override
  Future<List<String>> listRunning() async => instances;

  @override
  Future<String> export(String distribution, String location,
      {String? format}) async {
    exports.add([distribution, location, format]);
    if (exportFails) throw Exception('export blew up');
    // The service checks the file really exists before uploading it.
    await File(location).writeAsString('rootfs');
    return '';
  }

  @override
  Future<String> import(
      String distribution, String installLocation, String filename,
      {bool isVhd = false}) async {
    imports.add([distribution, installLocation, filename]);
    return '';
  }

  Never _unsupported() => throw UnimplementedError('not used by deploys');

  @override
  Future<String> copy(String distribution, String newName) => _unsupported();

  @override
  String currentDistroPath(String distribution) => _unsupported();

  @override
  Future<String> execCmdAsRoot(String distribution, String cmd) =>
      _unsupported();

  @override
  Future<String> getDefaultUser(String distribution) => _unsupported();

  @override
  Future<String?> getSize(String distribution) => _unsupported();

  @override
  Future<String?> readInstanceFile(String instance, String path) =>
      _unsupported();

  @override
  Future<String> remove(String distribution) => _unsupported();

  @override
  Future<VmCommandOutput> runInInstance(String instance, String command,
          {String user = 'root',
          String cwd = '',
          Duration timeout = const Duration(minutes: 5)}) =>
      _unsupported();

  @override
  Future<void> runCommands(String instance, List<String> commands,
          {String? user, Map<String, String> env = const {}}) =>
      _unsupported();

  @override
  Future<String> shutdown() => _unsupported();

  @override
  Future<void> start(String distribution,
          {String startPath = '',
          String startUser = '',
          String startCmd = ''}) =>
      _unsupported();

  @override
  void startExplorer(String distribution) => _unsupported();

  @override
  Future<Process> startShell(String distribution, {String? user}) =>
      _unsupported();

  @override
  Future<String> stop(String distribution) => _unsupported();

  @override
  Future<bool> writeInstanceFile(String instance, String path, String content) =>
      _unsupported();
}
