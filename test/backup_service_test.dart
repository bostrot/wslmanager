/// Backing every instance up to a folder and restoring it on another machine
/// (bostrot/ai-tasks#89).
///
/// The cases here are the ones that decide whether a backup is worth having:
/// one instance failing must not cost the other seven, an export that wrote
/// nothing must be reported rather than filed as a backup, and a restore must
/// never import over an instance that already exists on this machine.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/backup_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_provisioning_backend.dart';

/// A backend whose export writes a real file, so the service's own checks on
/// what landed on disk are exercised rather than mocked away.
class _FakeBackend extends ScriptedBackend {
  _FakeBackend() : super(instances: const ['Ubuntu', 'alpine']);

  /// Instances [listRunning] reports.
  List<String> running = [];

  /// Instances whose export throws instead of writing.
  Set<String> failExport = {};

  /// Instances whose export writes an empty file — the truncated export the
  /// service has to catch.
  Set<String> emptyExport = {};

  final List<String> stopped = [];
  final List<List<String>> imports = [];
  final List<bool> importedAsVhd = [];
  final List<String> exported = [];

  /// Names [list] answers with, when it should differ from what was backed
  /// up (the restoring machine's own instances).
  List<String>? listOverride;

  @override
  String get backendId => 'fake';

  @override
  String get templateExtension => 'ext4';

  @override
  Future<Instances> list(bool showDocker) async =>
      Instances(listOverride ?? instances, running);

  @override
  Future<List<String>> listRunning() async => running;

  @override
  Future<String> stop(String distribution) async {
    stopped.add(distribution);
    running = running.where((name) => name != distribution).toList();
    return '';
  }

  @override
  Future<String> export(String distribution, String location,
      {String? format}) async {
    exported.add(distribution);
    if (failExport.contains(distribution)) {
      throw Exception('export refused');
    }
    final file = File(location)..createSync(recursive: true);
    if (!emptyExport.contains(distribution)) {
      file.writeAsStringSync('archive of $distribution');
    }
    return '';
  }

  @override
  Future<String> import(
      String distribution, String installLocation, String filename,
      {bool isVhd = false}) async {
    imports.add([distribution, installLocation, filename]);
    importedAsVhd.add(isVhd);
    return 'Imported';
  }
}

void main() {
  late Directory tempDir;
  late Directory backupDir;
  late _FakeBackend backend;
  late BackupService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    tempDir = await Directory.systemTemp.createTemp('backup_test');
    prefs.setString('DistroPath', tempDir.path);
    backupDir = Directory('${tempDir.path}/backup');
    backend = _FakeBackend();
    service = BackupService(backend: backend);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Map<String, dynamic> readManifest() => json.decode(
      File('${backupDir.path}/${BackupService.manifestFileName}')
          .readAsStringSync()) as Map<String, dynamic>;

  group('backup', () {
    test('writes one archive per instance and a manifest naming them',
        () async {
      final outcome = await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );

      expect(outcome.succeeded, ['Ubuntu', 'alpine']);
      expect(outcome.failed, isEmpty);
      expect(File('${backupDir.path}/Ubuntu.ext4').existsSync(), true);
      expect(File('${backupDir.path}/alpine.ext4').existsSync(), true);

      final manifest = readManifest();
      expect(manifest['backend'], 'fake');
      expect(manifest['extension'], 'ext4');
      final instances = manifest['instances'] as List;
      expect(instances.map((e) => e['name']), ['Ubuntu', 'alpine']);
      expect(instances.first['bytes'], greaterThan(0));
    });

    test('shuts a running instance down before reading its disk', () async {
      backend.running = ['Ubuntu'];

      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );

      // Only the running one: stopping an instance that is already off is a
      // wsl.exe round trip for nothing.
      expect(backend.stopped, ['Ubuntu']);
    });

    test('keeps the file name legal and the instance name intact', () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu 22.04 (work)'],
      );

      final instances = readManifest()['instances'] as List;
      expect(instances.single['name'], 'Ubuntu 22.04 (work)');
      expect(instances.single['file'], 'Ubuntu_22.04__work_.ext4');
      expect(File('${backupDir.path}/Ubuntu_22.04__work_.ext4').existsSync(),
          true);
    });

    test('one failing instance does not cost the rest of the run', () async {
      backend.failExport = {'Ubuntu'};

      final outcome = await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );

      expect(outcome.failed.keys, ['Ubuntu']);
      expect(outcome.succeeded, ['alpine']);
      // The archives that landed stay restorable, so the manifest is written
      // even though the run was partial.
      expect((readManifest()['instances'] as List).map((e) => e['name']),
          ['alpine']);
    });

    test('an export that wrote nothing is a failure, not a backup', () async {
      backend.emptyExport = {'Ubuntu'};

      final outcome = await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu'],
      );

      expect(outcome.succeeded, isEmpty);
      expect(outcome.failed.keys, ['Ubuntu']);
      // The stub is gone: a zero-byte file next to real archives is exactly
      // what a later restore would try to import.
      expect(File('${backupDir.path}/Ubuntu.ext4').existsSync(), false);
      expect(readManifest()['instances'], isEmpty);
    });

    test('a second run into the same folder keeps the first run listed',
        () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );

      await service.backup(directory: backupDir.path, instances: ['alpine']);

      // Ubuntu.ext4 is still in the folder, so the manifest still names it;
      // a restore reads the manifest and never looks at the files.
      final names = (readManifest()['instances'] as List)
          .map((e) => e['name'])
          .toList();
      expect(names, containsAll(['Ubuntu', 'alpine']));
      expect(names.length, 2);
    });

    test('a failed export leaves nothing behind to restore later', () async {
      // The export that wrote a byte and then died: wsl.exe truncates the
      // target on open, so what is left is a broken archive under a name a
      // restore would happily import.
      backend.failExport = {'Ubuntu'};
      backupDir.createSync(recursive: true);
      File('${backupDir.path}/Ubuntu.ext4').writeAsStringSync('half');

      final outcome = await service.backup(
          directory: backupDir.path, instances: ['Ubuntu']);

      expect(outcome.failed.keys, ['Ubuntu']);
      expect(File('${backupDir.path}/Ubuntu.ext4').existsSync(), false);
      expect(readManifest()['instances'], isEmpty);
    });

    test('cancelling stops before the next instance starts', () async {
      final cancel = CancelSignal();

      final outcome = await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
        cancel: cancel,
        onStep: (step) {
          if (step.instance == 'Ubuntu' && step.stage == BackupStage.done) {
            cancel.cancel();
          }
        },
      );

      expect(outcome.cancelled, true);
      expect(outcome.succeeded, ['Ubuntu']);
      expect(backend.exported, ['Ubuntu']);
    });

    test('reports the stages the UI shows', () async {
      backend.running = ['Ubuntu'];
      final stages = <BackupStage>[];

      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu'],
        onStep: (step) {
          stages.add(step.stage);
          expect(step.total, 1);
          expect(step.index, 1);
        },
      );

      expect(stages,
          [BackupStage.stopping, BackupStage.exporting, BackupStage.done]);
    });
  });

  group('inspect', () {
    test('reads the manifest a backup left behind', () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu 22.04 (work)'],
      );

      final manifest = await service.inspect(backupDir.path);

      expect(manifest.fromManifest, true);
      expect(manifest.backend, 'fake');
      expect(manifest.entries.single.name, 'Ubuntu 22.04 (work)');
      expect(manifest.entries.single.bytes, greaterThan(0));
    });

    test('falls back to the file names when there is no manifest', () async {
      backupDir.createSync(recursive: true);
      File('${backupDir.path}/ubuntu.tar').writeAsStringSync('x');
      File('${backupDir.path}/notes.txt').writeAsStringSync('x');

      final manifest = await service.inspect(backupDir.path);

      expect(manifest.fromManifest, false);
      expect(manifest.entries.map((e) => e.name), ['ubuntu']);
    });

    test('a corrupt manifest still leaves the archives readable', () async {
      backupDir.createSync(recursive: true);
      File('${backupDir.path}/${BackupService.manifestFileName}')
          .writeAsStringSync('{not json');
      File('${backupDir.path}/alpine.ext4').writeAsStringSync('x');

      final manifest = await service.inspect(backupDir.path);

      expect(manifest.fromManifest, false);
      expect(manifest.entries.single.name, 'alpine');
    });

    test('an archive the manifest names but the folder lost is marked',
        () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );
      File('${backupDir.path}/alpine.ext4').deleteSync();

      final manifest = await service.inspect(backupDir.path);

      // Kept, not dropped: half a backup that hands back one of two
      // instances without saying so is the failure nobody notices in time.
      expect(manifest.entries.map((e) => e.name), ['Ubuntu', 'alpine']);
      expect(manifest.entries.last.missing, true);
      expect(manifest.entries.first.missing, false);
    });

    test('an empty folder is an empty list, not an error', () async {
      backupDir.createSync(recursive: true);

      final manifest = await service.inspect(backupDir.path);

      expect(manifest.entries, isEmpty);
    });
  });

  group('restore', () {
    test('imports every archive under the name it had', () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu 22.04 (work)'],
      );
      // The other machine: nothing installed yet.
      backend.listOverride = [];

      final outcome = await service.restore(directory: backupDir.path);

      expect(outcome.succeeded, ['Ubuntu 22.04 (work)']);
      expect(backend.imports.single[0], 'Ubuntu 22.04 (work)');
      expect(backend.importedAsVhd.single, false);
      // p.join, not a literal '/': the service joins with the platform
      // separator, so this is a backslash on Windows.
      expect(backend.imports.single[2],
          path.join(backupDir.path, 'Ubuntu_22.04__work_.ext4'));
    });

    test('leaves an instance that already exists here alone', () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );
      backend.listOverride = ['Ubuntu'];

      final outcome = await service.restore(directory: backupDir.path);

      expect(outcome.skipped, ['Ubuntu']);
      expect(outcome.succeeded, ['alpine']);
      expect(backend.imports.map((call) => call[0]), ['alpine']);
    });

    test('only restores what it was asked for', () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );
      backend.listOverride = [];

      final outcome =
          await service.restore(directory: backupDir.path, only: ['alpine']);

      expect(outcome.succeeded, ['alpine']);
      expect(backend.imports.map((call) => call[0]), ['alpine']);
    });

    test('a missing archive fails only its own instance', () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );
      // Named by the manifest, then taken away behind its back — a folder
      // that was copied while it was still being written.
      File('${backupDir.path}/alpine.ext4').deleteSync();
      backend.listOverride = [];

      final outcome = await service.restore(directory: backupDir.path);

      expect(outcome.succeeded, ['Ubuntu']);
      expect(outcome.failed.keys, ['alpine']);
    });

    test('cancelling stops before the next import starts', () async {
      await service.backup(
        directory: backupDir.path,
        instances: ['Ubuntu', 'alpine'],
      );
      backend.listOverride = [];
      final cancel = CancelSignal();

      final outcome = await service.restore(
        directory: backupDir.path,
        cancel: cancel,
        onStep: (step) {
          if (step.stage == BackupStage.done) cancel.cancel();
        },
      );

      expect(outcome.cancelled, true);
      expect(outcome.succeeded, ['Ubuntu']);
      expect(backend.imports.length, 1);
    });

    test('a vhdx archive is imported as a disk, not as a tarball', () async {
      backupDir.createSync(recursive: true);
      File('${backupDir.path}/win.vhdx').writeAsStringSync('x');
      backend.listOverride = [];

      await service.restore(directory: backupDir.path);

      expect(backend.imports.single[0], 'win');
      expect(backend.importedAsVhd.single, true);
    });
  });

  test('a folder written by another backend is flagged as foreign', () async {
    await service.backup(directory: backupDir.path, instances: ['Ubuntu']);
    final manifest = await service.inspect(backupDir.path);

    expect(service.isForeign(manifest), false);
    expect(
        BackupService(backend: ScriptedBackend()).isForeign(manifest), true);
    // A folder with no manifest claims no backend, so there is nothing to
    // disagree with.
    expect(service.isForeign(const BackupManifest(entries: [])), false);
  });
}
