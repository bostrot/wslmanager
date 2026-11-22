/// A backend for the playbook tests: answers `runInInstance` from a queue
/// and keeps every command it was given, so a test can read the step
/// scripts back out of them (bostrot/ai-tasks#78).
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/vm/vm_backend.dart';

class ScriptedBackend extends VmBackend {
  ScriptedBackend(
      {this.instances = const ['ubuntu', 'alpine'],
      this.runningInstances = const []});

  final List<String> instances;

  /// Which of [instances] answer as running. Empty by default: a test that
  /// cares says so.
  List<String> runningInstances;

  /// Answers, one per `runInInstance` call, in order. When the queue runs
  /// dry every step answers `ok`.
  final List<VmCommandOutput> answers = [];

  /// Every command handed to `runInInstance`, in order.
  final List<String> commands = [];
  final List<String> targets = [];
  final List<Duration> timeouts = [];

  /// Set to make `runInInstance` throw instead of answering.
  Object? failure;

  @override
  String get backendId => 'scripted';

  @override
  String get instanceNoun => 'box';

  @override
  VmFeatures get features => const VmFeatures(quickActions: true);

  @override
  Future<Instances> list(bool showDocker) async =>
      Instances(instances, runningInstances);

  /// Read back out of [list], so a subclass that overrides only that one
  /// still answers both questions the same way.
  @override
  Future<List<String>> listRunning() async => (await list(false)).running;

  @override
  Future<void> start(String distribution,
      {String startPath = '',
      String startUser = '',
      String startCmd = ''}) async {}

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
  }) async {
    commands.add(command);
    targets.add(instance);
    timeouts.add(timeout);
    if (failure != null) throw failure!;
    if (answers.isEmpty) return const VmCommandOutput(0, '__wslm__:ok\n', '');
    return answers.removeAt(0);
  }

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

/// The step script inside a command `ProvisioningRunner.commandFor` built:
/// the base64 payload between `printf %s ` and ` | base64 -d`.
String scriptOf(String command) {
  final match =
      RegExp(r"printf %s ([A-Za-z0-9+/=]+) \| base64 -d").firstMatch(command);
  if (match == null) throw StateError('no script payload in: $command');
  return utf8.decode(base64.decode(match.group(1)!));
}

VmCommandOutput answer(String status,
        {String stdout = '', String stderr = ''}) =>
    VmCommandOutput(0, '$stdout\n__wslm__:$status\n', stderr);
