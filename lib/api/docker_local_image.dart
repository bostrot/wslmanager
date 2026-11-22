// Importing a WSL distribution from an image the local Docker daemon already
// holds, instead of pulling one from a registry.
//
// The registry path in [DockerImage] fetches blobs over HTTP; there is nothing
// to fetch for an image that was built locally or loaded with `docker load`,
// and in an offline or air-gapped setup there is nowhere to fetch it from
// either. `docker save` writes exactly the same thing a registry serves — a
// tarball of layer tars plus a config blob — so the two paths differ only in
// where the layers come from, and both end at [LayerProcessor.mergeLayers].
//
// Two details of `docker save` output are what the earlier attempt at this got
// wrong, and both make the difference between a working import and none:
//
//  * its layers are *uncompressed* tars, where registry blobs are gzipped.
//    [LayerProcessor] now sniffs each layer instead of assuming gzip.
//  * since Docker Engine 25's containerd image store, `manifest.json` may name
//    layers as `blobs/sha256/<digest>` rather than `<hash>/layer.tar`. Entry
//    names are therefore taken from the manifest verbatim, with the legacy
//    `/layer.tar` suffix tried only as a fallback.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tar/tar.dart';
import 'package:wsl2distromanager/api/docker_images.dart'
    show TotalProgressCallback;
import 'package:wsl2distromanager/api/layer_processor.dart';
import 'package:wsl2distromanager/api/safe_paths.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Runs an external command. The seam exists so the tests can drive the whole
/// export without a Docker daemon — faking [Process.run] itself is not
/// possible, and requiring Docker would make the suite unrunnable in CI.
typedef DockerRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

Future<ProcessResult> _runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

/// A reference to an image in the local daemon, split into the parts this app
/// needs: something to hand `docker save`, and something to name a file after.
///
/// Splitting on the first `:` — which is what the first version of this did —
/// is wrong for the two forms the upstream request explicitly asks for. A
/// registry-qualified name carries a port (`localhost:5000/app:v1` would have
/// become image `localhost`, tag `5000/app`), and an image ID has no tag at
/// all (`sha256:ab…` would have become image `sha256`). The tag separator is
/// the last `:` *after* the last `/`, which is the rule Docker itself uses.
class DockerImageRef {
  /// The repository, or the ID itself when [isId].
  final String name;

  /// The tag, when the reference carries one.
  final String? tag;

  /// A `@sha256:…` digest, when the reference is pinned to one.
  final String? digest;

  /// Whether this is a bare image ID rather than a repository name.
  final bool isId;

  const DockerImageRef({
    required this.name,
    this.tag,
    this.digest,
    this.isId = false,
  });

  /// An image ID as `docker image ls` prints it: short (12 hex) or full, with
  /// or without the `sha256:` algorithm prefix.
  static final RegExp _id = RegExp(r'^(sha256:)?[0-9a-f]{12,64}$');

  factory DockerImageRef.parse(String raw) {
    final ref = raw.trim();
    if (ref.isEmpty) {
      throw ArgumentError('Docker image reference is empty');
    }

    if (_id.hasMatch(ref)) {
      return DockerImageRef(name: ref, isId: true);
    }

    // A digest pin replaces the tag: `repo@sha256:…`.
    final at = ref.indexOf('@');
    if (at > 0) {
      return DockerImageRef(
          name: ref.substring(0, at), digest: ref.substring(at + 1));
    }

    final lastColon = ref.lastIndexOf(':');
    final lastSlash = ref.lastIndexOf('/');
    if (lastColon > lastSlash && lastColon != -1) {
      final tag = ref.substring(lastColon + 1);
      if (tag.isNotEmpty) {
        return DockerImageRef(name: ref.substring(0, lastColon), tag: tag);
      }
    }
    return DockerImageRef(name: ref);
  }

  /// What `docker save` is given.
  String get reference {
    if (isId) return name;
    if (digest != null) return '$name@$digest';
    if (tag != null) return '$name:$tag';
    return name;
  }

  /// The stem of the rootfs tarball this image is exported to.
  ///
  /// Prefixed with `local_` so a locally built `ubuntu:latest` never overwrites
  /// the `library_ubuntu_latest` the registry path downloads — they are
  /// different images that happen to share a name.
  String get fileStem {
    final parts = [name, if (tag != null) tag!, if (digest != null) digest!]
        .map((part) => part.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_'));
    return 'local_${parts.join('_')}';
  }

  @override
  String toString() => reference;
}

/// The parts of a Docker image config blob a WSL instance can act on.
///
/// Mirrors what the registry path reads out of `config.json`, so an image
/// imported from the local daemon starts the same way as the same image pulled
/// from a registry — before this, a local import silently dropped the image's
/// environment, entrypoint and default user.
class DockerImageConfig {
  /// The default user, when the image names one that is not a bare uid.
  final String? user;

  /// The image's environment, entrypoint and command, as one shell line.
  final String? startCmd;

  /// Build steps that created users, replayed after the import.
  final List<String> userCmds;

  /// Build steps that created groups, replayed before [userCmds].
  final List<String> groupCmds;

  const DockerImageConfig({
    this.user,
    this.startCmd,
    this.userCmds = const [],
    this.groupCmds = const [],
  });

  factory DockerImageConfig.fromJson(Map<String, dynamic> json) {
    String? user;
    String? startCmd;

    final config = json['config'] ?? json['Config'];
    if (config is Map) {
      final rawUser = config['User'] ?? config['user'];
      if (rawUser is String && rawUser.isNotEmpty) {
        final candidate = rawUser.split(':').first;
        // A numeric `User` names a uid, not an account WSL can switch to.
        if (int.tryParse(candidate) == null) user = candidate;
      }

      final env = config['Env'] ?? config['env'];
      final exportEnv =
          env is List ? env.map((e) => 'export $e;').join(' ') : '';

      final entrypoint = config['Entrypoint'] ?? config['entrypoint'];
      final entrypointCmd = entrypoint is List
          ? entrypoint.map((e) => e.toString()).join(' ')
          : '';

      final cmd = config['Cmd'] ?? config['cmd'];
      if (cmd is List) {
        startCmd =
            '$exportEnv $entrypointCmd; ${cmd.map((e) => e.toString()).join(' ')}';
      } else if (entrypointCmd.isNotEmpty) {
        startCmd = '$exportEnv $entrypointCmd';
      }
    }

    final userCmds = <String>[];
    final groupCmds = <String>[];
    final history = json['history'] ?? json['History'];
    if (history is List) {
      for (final item in history) {
        if (item is! Map) continue;
        final createdBy = item['created_by'];
        if (createdBy is! String) continue;
        if (createdBy.contains('adduser') || createdBy.contains('useradd')) {
          userCmds.add(createdBy);
        }
        if (createdBy.contains('groupadd') || createdBy.contains('addgroup')) {
          groupCmds.add(createdBy);
        }
      }
    }

    return DockerImageConfig(
        user: user,
        startCmd: startCmd,
        userCmds: userCmds,
        groupCmds: groupCmds);
  }
}

/// Importing WSL root filesystems from images the local Docker daemon holds.
class DockerLocalImages {
  final DockerRunner run;

  DockerLocalImages({DockerRunner? run}) : run = run ?? _runProcess;

  /// Every image the daemon holds, as references [import] accepts.
  ///
  /// An untagged image is listed by its ID: `docker image ls` prints those as
  /// `<none>:<none>`, which is not a reference `docker save` can resolve, so
  /// offering it in the picker only ever produced a failed export.
  ///
  /// Returns an empty list when Docker is not installed or not running: the
  /// source picker asks for this list on every keystroke, and having nothing
  /// to suggest is not an error worth surfacing there.
  Future<List<String>> list() async {
    final ProcessResult result;
    try {
      result = await run('docker',
          ['image', 'ls', '--format', '{{.Repository}}:{{.Tag}}\t{{.ID}}']);
    } on ProcessException {
      return [];
    }
    if (result.exitCode != 0) return [];

    final images = <String>[];
    for (final line in const LineSplitter().convert('${result.stdout}')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final columns = trimmed.split('\t');
      final repoTag = columns.first.trim();
      final id = columns.length > 1 ? columns[1].trim() : '';

      final untagged =
          repoTag.startsWith('<none>') || repoTag.endsWith(':<none>');
      final reference = untagged ? id : repoTag;
      if (reference.isEmpty) continue;
      if (!images.contains(reference)) images.add(reference);
    }
    return images;
  }

  /// Exports [reference] with `docker save` and merges its layers into a
  /// rootfs tarball under the distro path.
  ///
  /// Returns the stem of that tarball, which is what `WSLApi.create` is given
  /// to find it again.
  Future<String> import(
    String instanceName,
    String reference, {
    required void Function(String) onStatus,
    required TotalProgressCallback progress,
  }) async {
    final ref = DockerImageRef.parse(reference);
    final tmpPath = (getTmpPath()..cd(ref.fileStem)).path;
    final tmp = SafePath(tmpPath);
    await Directory(tmpPath).create(recursive: true);

    try {
      final archivePath = tmp.file('image.tar');
      final ProcessResult saved;
      try {
        saved = await run('docker', ['save', '-o', archivePath, ref.reference]);
      } on ProcessException catch (e) {
        throw Exception('Docker is not available: ${e.message}');
      }
      if (saved.exitCode != 0) {
        final stderr = '${saved.stderr}'.trim();
        throw Exception(stderr.isEmpty
            ? 'docker save exited with ${saved.exitCode}'
            : stderr);
      }

      final manifest = await _readManifest(archivePath);
      final layerStems =
          await _extractEntries(archivePath, manifest, tmpPath, progress);

      await _applyConfig(instanceName, ref, tmp);

      // `WSLApi.create` resolves a docker rootfs under the *data* path, not
      // the distro path, and the two differ whenever a separate data path is
      // configured. Writing where the importer will look is what makes the
      // handoff work; the registry path in [DockerImage] still writes to
      // `getDistroPath()` and loses the rootfs in that configuration.
      final outTarGz =
          (getDataPath()..cd('distros')).file('${ref.fileStem}.tar.gz');
      await LayerProcessor().mergeLayers(layerStems, outTarGz, onStatus);
      if (!await File(outTarGz).exists()) {
        throw Exception('Merging the image layers produced no rootfs');
      }
      return ref.fileStem;
    } finally {
      // The export is a full copy of the image; leaving it behind would cost
      // the user that much disk on every import, successful or not.
      final dir = Directory(tmpPath);
      if (await dir.exists()) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // A cleanup that fails must not mask the import's own outcome.
        }
      }
    }
  }

  /// The first entry of `manifest.json`, which names the config blob and the
  /// layers in bottom-to-top order.
  Future<_SaveManifest> _readManifest(String archivePath) async {
    final reader = TarReader(File(archivePath).openRead());
    try {
      while (await reader.moveNext()) {
        if (_entryName(reader.current.name) != 'manifest.json') continue;
        final content =
            await reader.current.contents.transform(utf8.decoder).join();
        final decoded = json.decode(content);
        if (decoded is! List || decoded.isEmpty) {
          throw Exception('The Docker export has an empty manifest.json');
        }
        final first = decoded.first as Map<String, dynamic>;
        final layers =
            (first['Layers'] as List?)?.map((e) => e.toString()).toList() ??
                const <String>[];
        if (layers.isEmpty) {
          throw Exception('The Docker export contains no layers');
        }
        return _SaveManifest(
            config: first['Config']?.toString(), layers: layers);
      }
    } finally {
      await reader.cancel();
    }
    throw Exception('No manifest.json in the Docker export');
  }

  /// Writes each layer and the config blob out of the export, in one pass.
  ///
  /// One pass matters: the export is the size of the whole image, and the
  /// first version read all of it into memory and re-decoded it once per
  /// layer, so a 2 GB image asked for tens of gigabytes of allocations.
  ///
  /// Returns the layer paths in manifest order, which is the order
  /// [LayerProcessor] needs to resolve whiteouts correctly.
  Future<List<String>> _extractEntries(
    String archivePath,
    _SaveManifest manifest,
    String outputPath,
    TotalProgressCallback progress,
  ) async {
    final out = SafePath(outputPath);
    // An entry name maps to *every* slot that wants it: a manifest may list
    // the same digest at two positions — identical layers are deduplicated in
    // the archive but not in the layer list — and writing only the first
    // occurrence would leave the later slot empty.
    final wanted = <String, List<String>>{};
    final layerPaths = <String>[];
    void want(String name, String target) =>
        wanted.putIfAbsent(_entryName(name), () => []).add(target);

    for (var i = 0; i < manifest.layers.length; i++) {
      final target = out.file('layer_$i.tar');
      layerPaths.add(target);
      final ref = _entryName(manifest.layers[i]);
      want(ref, target);
      // Some manifests name only the layer's directory.
      want('$ref/layer.tar', target);
    }
    if (manifest.config != null) {
      want(manifest.config!, out.file('config.json'));
    }

    final found = <String>{};
    var layersWritten = 0;
    final reader = TarReader(File(archivePath).openRead());
    try {
      while (await reader.moveNext()) {
        final entry = reader.current;
        final targets = wanted[_entryName(entry.name)];
        if (targets == null) continue;
        final pending = targets.where((t) => !found.contains(t)).toList();
        if (pending.isEmpty) continue;

        // The archive is read once, so a layer needed twice is written to both
        // slots from this single pass.
        final sink = File(pending.first).openWrite();
        await entry.contents.pipe(sink);
        found.add(pending.first);
        for (final extra in pending.skip(1)) {
          await File(pending.first).copy(extra);
          found.add(extra);
        }

        final layers = pending.where(layerPaths.contains).length;
        if (layers > 0) {
          layersWritten += layers;
          progress(layersWritten - 1, manifest.layers.length, 100, 100);
        }
      }
    } finally {
      await reader.cancel();
    }

    for (var i = 0; i < layerPaths.length; i++) {
      if (!found.contains(layerPaths[i])) {
        throw Exception(
            'The Docker export is missing layer ${manifest.layers[i]}');
      }
    }
    return layerPaths;
  }

  /// Carries the image's environment, entrypoint, user and user/group build
  /// steps over to the instance, under the same preference keys the registry
  /// path writes so the create flow picks them up unchanged.
  Future<void> _applyConfig(
      String instanceName, DockerImageRef ref, SafePath tmp) async {
    final file = File(tmp.file('config.json'));
    if (!await file.exists()) return;
    final DockerImageConfig config;
    try {
      config = DockerImageConfig.fromJson(
          json.decode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // A config this app cannot read is not a reason to fail the import; the
      // rootfs is still perfectly usable without the image's defaults.
      return;
    }

    if (config.user != null) {
      await prefs.setString('StartUser_$instanceName', config.user!);
    }
    if (config.startCmd != null) {
      await prefs.setString('StartCmd_$instanceName', config.startCmd!);
    }
    await prefs.setStringList('UserCmds_${ref.fileStem}', config.userCmds);
    await prefs.setStringList('GroupCmds_${ref.fileStem}', config.groupCmds);
  }

  /// Tar entries are written with and without a `./` prefix depending on who
  /// produced the archive.
  static String _entryName(String name) =>
      name.startsWith('./') ? name.substring(2) : name;
}

class _SaveManifest {
  final String? config;
  final List<String> layers;

  const _SaveManifest({required this.config, required this.layers});
}
