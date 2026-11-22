// Backing every instance up to one folder, and putting them back on another
// machine (bostrot/ai-tasks#89, upstream bostrot/wsl2-distro-manager#203).
//
// ## Why this is not "templates, but more of them"
//
// Templates already export an instance to a file, and the cloud deploy
// already moves one to another machine — so the obvious reading of the
// request is that it is covered twice over. It is not, and the difference is
// where the file lands. A template goes into the app's own data directory
// under a name the app made up, and is only ever read back through the
// app on the same machine; the request is about a *new PC*, which means the
// archives have to land somewhere the user chooses — an external disk, a
// share — and have to be readable on the other side without anyone
// reconstructing which file was which instance.
//
// Hence the manifest. `<folder>/wslmanager-backup.json` records the real
// instance name against the file it was written to, plus the backend and the
// archive format that produced it, so a restore can put every instance back
// under the name it had even though the file name had to be sanitised for
// the filesystem. A folder without a manifest still restores — the file
// names are the fallback — because a user who copies half a backup around,
// or exports by hand, should not be told their archives are unreadable.
//
// ## Why it is written against [VmBackend] and not against wsl.exe
//
// The board issue asks whether the same thing should exist for the Mac's
// VMs. It should, and it does not need a second implementation: export and
// import are both on the backend surface — `wsl --export/--import` on
// Windows, `vmctl export/import` on the Apple backend — and the only thing
// that differs is the extension of what comes out (an ext4 tarball vs a raw
// disk image), which [VmBackend.templateExtension] already states. So this
// file talks to the abstract backend, the manifest records which backend
// wrote the folder, and a restore warns when that is not the backend doing
// the reading: a raw VM disk is not something wsl.exe can import, and
// finding that out from a failed import halfway through is worse than being
// told up front.
//
// ## Failure is per instance, never per run
//
// A backup of eight instances that stops dead on the third is the shape this
// feature exists to replace — the user is back to doing it by hand, except
// now they also have to work out which ones made it. Every step is caught,
// recorded against its instance, and the run continues; what comes back is a
// list of what worked, what was skipped and what failed with why. The
// manifest is written even for a partial run, so the archives that *did*
// land stay restorable.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// One archive in a backup folder: the instance it came from and the file it
/// was written to. The two are not the same string — an instance may be
/// called `Ubuntu 22.04 (work)`, which is not a file name anyone wants to
/// hand to `wsl --import` on the other side.
class BackupEntry {
  const BackupEntry({
    required this.name,
    required this.file,
    this.bytes = 0,
    this.missing = false,
  });

  /// The instance's own name, restored verbatim.
  final String name;

  /// File name inside the backup folder, never a path: a folder that is
  /// copied to another machine changes its absolute path on the way.
  final String file;

  /// Size of the archive when it was written, for the UI to show. Zero means
  /// "not recorded", which is what a scanned folder without a manifest has
  /// until the file is stat'ed.
  final int bytes;

  /// The manifest names this archive but the folder no longer holds it —
  /// half a backup copied off a disk, typically. Kept rather than dropped:
  /// a restore that quietly hands back seven of the eight instances the
  /// folder claims is the one outcome nobody would notice in time.
  final bool missing;

  Map<String, dynamic> toJson() => {
        'name': name,
        'file': file,
        'bytes': bytes,
      };

  static BackupEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final file = raw['file'];
    if (name is! String || file is! String) return null;
    if (name.isEmpty || file.isEmpty) return null;
    final bytes = raw['bytes'];
    return BackupEntry(
      name: name,
      file: file,
      bytes: bytes is int ? bytes : 0,
    );
  }
}

/// What a backup folder holds, either read from its manifest or worked out
/// from the files in it.
class BackupManifest {
  const BackupManifest({
    required this.entries,
    this.backend = '',
    this.archiveExtension = '',
    this.appVersion = '',
    this.createdAt,
    this.fromManifest = true,
  });

  /// The version this writer produces. Read back leniently: a folder written
  /// by a newer app is still a folder full of archives, and refusing to
  /// restore it would strand the user's data behind a version number.
  static const int formatVersion = 1;

  final List<BackupEntry> entries;

  /// [VmBackend.backendId] of whatever wrote the folder, or '' when unknown.
  final String backend;

  /// Extension the archives carry, without the dot.
  final String archiveExtension;

  /// App version that wrote the folder, for support questions.
  final String appVersion;

  final DateTime? createdAt;

  /// False when this was reconstructed by listing the folder, which is worth
  /// telling the user: names come from file names then, not from the app.
  final bool fromManifest;

  Map<String, dynamic> toJson() => {
        'version': formatVersion,
        'app': 'wslmanager',
        'appVersion': appVersion,
        'backend': backend,
        'extension': archiveExtension,
        'created': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
        'instances': entries.map((e) => e.toJson()).toList(),
      };

  static BackupManifest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final instances = raw['instances'];
    if (instances is! List) return null;
    final entries = <BackupEntry>[];
    for (final item in instances) {
      final entry = BackupEntry.fromJson(item);
      if (entry != null) entries.add(entry);
    }
    String text(String key) => raw[key] is String ? raw[key] as String : '';
    return BackupManifest(
      entries: entries,
      backend: text('backend'),
      archiveExtension: text('extension'),
      appVersion: text('appVersion'),
      createdAt: DateTime.tryParse(text('created')),
    );
  }
}

/// Which part of one instance's turn is running, so the UI can say more than
/// "working" through a step that takes minutes.
enum BackupStage {
  /// Shutting the instance down before its disk is read.
  stopping,

  /// The export itself — the long one.
  exporting,

  /// The import on the restore side — the other long one.
  importing,

  /// Nothing was done: the name is already taken on this machine.
  skipped,

  /// The instance finished successfully.
  done,

  /// The instance failed; the run carries on with the next one.
  failed,
}

/// One progress report. [index] is 1-based so it reads as "3 of 8".
class BackupStep {
  const BackupStep({
    required this.instance,
    required this.index,
    required this.total,
    required this.stage,
    this.reason = '',
  });

  final String instance;
  final int index;
  final int total;
  final BackupStage stage;

  /// Why it failed or was skipped, already turned into a sentence.
  final String reason;
}

/// What a finished run did, per instance.
class BackupOutcome {
  BackupOutcome({this.cancelled = false});

  final List<String> succeeded = [];
  final List<String> skipped = [];

  /// Instance name to the reason it failed, in the order they failed.
  final Map<String, String> failed = {};

  /// True when the user stopped the run; the instances that had already
  /// finished are still in [succeeded].
  bool cancelled;

  bool get isEmpty => succeeded.isEmpty && skipped.isEmpty && failed.isEmpty;
}

/// Exporting every instance to a folder of the user's choosing, and building
/// them back out of one. See the file header for why this is not templates.
class BackupService {
  BackupService({VmBackend? backend}) : backend = backend ?? vmBackend();

  final VmBackend backend;

  /// The manifest's file name inside a backup folder.
  static const String manifestFileName = 'wslmanager-backup.json';

  /// Extensions a restore is willing to read besides the backend's own, so a
  /// folder of hand-made `wsl --export` tarballs restores too.
  static const List<String> _knownExtensions = [
    'tar',
    'tar.gz',
    'tgz',
    'tar.xz',
    'ext4',
    'vhdx',
    'img',
  ];

  /// Export [instances] into [directory], one archive each, plus a manifest.
  ///
  /// Every instance is shut down first: `wsl --export` of a running distro
  /// reads a disk that is still being written to, and a backup is the last
  /// place to accept that risk. Failures are per instance — see the header.
  Future<BackupOutcome> backup({
    required String directory,
    required List<String> instances,
    CancelSignal? cancel,
    void Function(BackupStep step)? onStep,
  }) async {
    final outcome = BackupOutcome();
    final entries = <BackupEntry>[];
    final folder = Directory(directory);
    if (!folder.existsSync()) {
      folder.createSync(recursive: true);
    }

    List<String> running;
    try {
      running = await backend.listRunning();
    } catch (_) {
      // Not knowing which are running only costs a redundant stop.
      running = List<String>.from(instances);
    }

    final usedNames = <String>{};
    for (var i = 0; i < instances.length; i++) {
      final name = instances[i];
      if (cancel?.isCancelled ?? false) {
        outcome.cancelled = true;
        break;
      }

      BackupStep step(BackupStage stage, {String reason = ''}) => BackupStep(
            instance: name,
            index: i + 1,
            total: instances.length,
            stage: stage,
            reason: reason,
          );

      final file = _archiveFileName(name, usedNames);
      final target = p.join(directory, file);
      try {
        if (running.contains(name)) {
          onStep?.call(step(BackupStage.stopping));
          await backend.stop(name);
        }
        onStep?.call(step(BackupStage.exporting));
        await backend.export(name, target);

        // An export that wrote nothing is the failure mode that hurts most
        // here: it looks like a backup right up until the restore on the
        // other machine, months later.
        final written = File(target);
        final size = written.existsSync() ? written.lengthSync() : 0;
        if (size <= 0) {
          throw const WslFailure(details: 'The export produced no data.');
        }

        entries.add(BackupEntry(name: name, file: file, bytes: size));
        outcome.succeeded.add(name);
        onStep?.call(step(BackupStage.done));
      } catch (e) {
        // Whatever the failed export left behind goes with it. A half-written
        // archive is indistinguishable from a whole one at restore time, and
        // an export into a folder that already held a good copy has already
        // truncated that copy by the time it fails — keeping the remains only
        // buys a restore that succeeds into a broken instance.
        final partial = File(target);
        if (partial.existsSync()) {
          try {
            partial.deleteSync();
          } catch (_) {}
        }
        final reason = friendlyErrorReason(e);
        outcome.failed[name] = reason;
        onStep?.call(step(BackupStage.failed, reason: reason));
      }
    }

    // Written even for a partial or cancelled run: the archives that landed
    // are restorable, and only the manifest knows their real names.
    _writeManifest(directory, entries);
    return outcome;
  }

  /// What is in [directory]: its manifest, or the archives themselves when
  /// there is no manifest to read.
  ///
  /// Returns a manifest with no entries when the folder holds nothing this
  /// can restore, rather than throwing: "there is nothing here" is an answer
  /// the dialog shows, not an error it reports.
  Future<BackupManifest> inspect(String directory) async {
    final manifest = File(p.join(directory, manifestFileName));
    if (manifest.existsSync()) {
      try {
        final parsed =
            BackupManifest.fromJson(json.decode(manifest.readAsStringSync()));
        if (parsed != null) {
          // Sizes are re-read from disk, and an archive the folder no
          // longer holds is marked rather than promised.
          final present = <BackupEntry>[];
          for (final entry in parsed.entries) {
            final file = File(p.join(directory, entry.file));
            final there = file.existsSync();
            present.add(BackupEntry(
              name: entry.name,
              file: entry.file,
              bytes: there ? file.lengthSync() : 0,
              missing: !there,
            ));
          }
          return BackupManifest(
            entries: present,
            backend: parsed.backend,
            archiveExtension: parsed.archiveExtension,
            appVersion: parsed.appVersion,
            createdAt: parsed.createdAt,
          );
        }
      } catch (_) {
        // A corrupt manifest is not a corrupt backup: fall through to the
        // file names, which is the same road a hand-made folder takes.
      }
    }
    return BackupManifest(
      entries: _scan(directory),
      fromManifest: false,
    );
  }

  /// Import the archives in [directory] back into this machine.
  ///
  /// [only] restricts the run to those instance names; null means all of
  /// them. A name that already exists here is skipped rather than
  /// overwritten — `wsl --import` onto a live distro is not a merge, and the
  /// user's current machine is not the copy to lose.
  Future<BackupOutcome> restore({
    required String directory,
    List<String>? only,
    CancelSignal? cancel,
    void Function(BackupStep step)? onStep,
  }) async {
    final outcome = BackupOutcome();
    final manifest = await inspect(directory);
    final wanted = only == null
        ? manifest.entries
        : manifest.entries.where((e) => only.contains(e.name)).toList();

    List<String> existing;
    try {
      existing = (await backend.list(true)).all;
    } catch (_) {
      existing = const [];
    }

    for (var i = 0; i < wanted.length; i++) {
      final entry = wanted[i];
      if (cancel?.isCancelled ?? false) {
        outcome.cancelled = true;
        break;
      }

      BackupStep step(BackupStage stage, {String reason = ''}) => BackupStep(
            instance: entry.name,
            index: i + 1,
            total: wanted.length,
            stage: stage,
            reason: reason,
          );

      if (existing.contains(entry.name)) {
        outcome.skipped.add(entry.name);
        onStep?.call(step(BackupStage.skipped));
        continue;
      }

      final archive = p.join(directory, entry.file);
      try {
        if (!File(archive).existsSync()) {
          throw const WslFailure(details: 'The archive is missing.');
        }
        onStep?.call(step(BackupStage.importing));
        await backend.import(
          entry.name,
          getInstancePath(entry.name).path,
          archive,
          isVhd: entry.file.toLowerCase().endsWith('.vhdx'),
        );
        // Restored instances count as existing for the rest of the run, so a
        // folder that names one twice cannot import it over itself.
        existing = [...existing, entry.name];
        outcome.succeeded.add(entry.name);
        onStep?.call(step(BackupStage.done));
      } catch (e) {
        final reason = friendlyErrorReason(e);
        outcome.failed[entry.name] = reason;
        onStep?.call(step(BackupStage.failed, reason: reason));
      }
    }

    return outcome;
  }

  /// Whether [manifest] was written by a backend whose archives this one can
  /// read. Unknown ('' — a scanned folder) is not a mismatch: there is
  /// nothing to disagree with.
  bool isForeign(BackupManifest manifest) =>
      manifest.backend.isNotEmpty && manifest.backend != backend.backendId;

  void _writeManifest(String directory, List<BackupEntry> entries) {
    // Archives an earlier run put in this folder stay listed. Backing one
    // instance up into a folder that already holds seven must not leave the
    // other seven invisible to a restore, which reads the manifest and stops
    // looking once it finds one.
    final merged = <String, BackupEntry>{};
    final existing = File(p.join(directory, manifestFileName));
    if (existing.existsSync()) {
      try {
        final parsed =
            BackupManifest.fromJson(json.decode(existing.readAsStringSync()));
        for (final entry in parsed?.entries ?? const <BackupEntry>[]) {
          if (File(p.join(directory, entry.file)).existsSync()) {
            merged[entry.file.toLowerCase()] = entry;
          }
        }
      } catch (_) {
        // An unreadable manifest is replaced by this run's, which is the
        // best that can be said about the folder either way.
      }
    }
    for (final entry in entries) {
      merged[entry.file.toLowerCase()] = entry;
    }

    final manifest = BackupManifest(
      entries: merged.values.toList(),
      backend: backend.backendId,
      archiveExtension: backend.templateExtension,
      appVersion: currentVersion,
      createdAt: DateTime.now(),
    );
    try {
      File(p.join(directory, manifestFileName)).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
    } catch (_) {
      // The archives are the backup; the manifest is what makes it tidy. A
      // read-only folder must not turn a finished export into a failure.
    }
  }

  /// The archives in [directory], named after their files, for a folder with
  /// no manifest to speak for it.
  List<BackupEntry> _scan(String directory) {
    final folder = Directory(directory);
    if (!folder.existsSync()) return const [];
    final entries = <BackupEntry>[];
    final seen = <String>{};
    final files = folder.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    for (final file in files) {
      final fileName = p.basename(file.path);
      final name = _instanceNameFor(fileName);
      if (name == null) continue;
      // Two files that would restore to one name (ubuntu.tar next to
      // ubuntu.ext4) would import over each other; the first wins.
      if (!seen.add(name.toLowerCase())) continue;
      entries.add(
          BackupEntry(name: name, file: fileName, bytes: file.lengthSync()));
    }
    return entries;
  }

  /// The instance name a bare archive file stands for, or null when the file
  /// is not an archive this can read (the manifest itself, a README, the
  /// `.DS_Store` a Mac leaves in every folder it touches).
  String? _instanceNameFor(String fileName) {
    if (fileName == manifestFileName) return null;
    final lower = fileName.toLowerCase();
    final extensions = <String>{
      backend.templateExtension.toLowerCase(),
      ..._knownExtensions,
    };
    // Longest first, so `.tar.gz` is not read as a file called `x.tar`.
    final sorted = extensions.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final extension in sorted) {
      final suffix = '.$extension';
      if (lower.endsWith(suffix) && lower.length > suffix.length) {
        return fileName.substring(0, fileName.length - suffix.length);
      }
    }
    return null;
  }

  /// A file name for [instance] that every filesystem in play accepts, kept
  /// unique within one run. The real name lives in the manifest, so nothing
  /// is lost by being strict here.
  String _archiveFileName(String instance, Set<String> used) {
    final cleaned = instance.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    var base = cleaned.replaceAll(RegExp(r'^[._]+'), '');
    if (base.isEmpty) base = 'instance';
    var candidate = '$base.${backend.templateExtension}';
    var suffix = 2;
    while (!used.add(candidate.toLowerCase())) {
      candidate = '$base-$suffix.${backend.templateExtension}';
      suffix++;
    }
    return candidate;
  }
}
