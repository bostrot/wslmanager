import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tar/tar.dart';
import 'package:wsl2distromanager/api/docker_local_image.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Where `WSLApi.create` looks for a docker rootfs.
String rootfsPath(String stem) =>
    (getDataPath()..cd('distros')).file('$stem.tar.gz');

/// Writes a tar archive of [entries] (name -> bytes) to [path], uncompressed,
/// the way `docker save` does.
Future<void> writeTar(String path, Map<String, List<int>> entries) async {
  await Stream<TarEntry>.fromIterable(entries.entries.map((e) => TarEntry.data(
        TarHeader(name: e.key, mode: int.parse('644', radix: 8)),
        e.value,
      ))).transform(tarWriter).pipe(File(path).openWrite());
}

/// A single-file layer tar, uncompressed — the `layer.tar` shape.
Future<List<int>> layerBytes(Map<String, String> files) async {
  final out = <int>[];
  await Stream<TarEntry>.fromIterable(files.entries.map((e) => TarEntry.data(
        TarHeader(name: e.key, mode: int.parse('644', radix: 8)),
        utf8.encode(e.value),
      ))).transform(tarWriter).forEach(out.addAll);
  return out;
}

/// Reads a merged rootfs back into a path -> contents map.
Future<Map<String, String>> readRootfs(String path) async {
  final result = <String, String>{};
  final reader = TarReader(File(path).openRead().transform(gzip.decoder));
  while (await reader.moveNext()) {
    result[reader.current.name] =
        await reader.current.contents.transform(utf8.decoder).join();
  }
  await reader.cancel();
  return result;
}

void main() {
  group('DockerImageRef.parse', () {
    test('splits a plain name and tag', () {
      final ref = DockerImageRef.parse('ubuntu:22.04');
      expect(ref.name, 'ubuntu');
      expect(ref.tag, '22.04');
      expect(ref.reference, 'ubuntu:22.04');
      expect(ref.isId, isFalse);
    });

    test('leaves an untagged name untagged', () {
      final ref = DockerImageRef.parse('myapp');
      expect(ref.name, 'myapp');
      expect(ref.tag, isNull);
      expect(ref.reference, 'myapp');
    });

    test('keeps a registry port out of the tag', () {
      // The regression: splitting on the first `:` read the tag as
      // "5000/team/app" and the repository as "localhost".
      final ref = DockerImageRef.parse('localhost:5000/team/app:v1');
      expect(ref.name, 'localhost:5000/team/app');
      expect(ref.tag, 'v1');
      expect(ref.reference, 'localhost:5000/team/app:v1');
    });

    test('a registry port without a tag is not a tag', () {
      final ref = DockerImageRef.parse('registry.example.com:5000/app');
      expect(ref.name, 'registry.example.com:5000/app');
      expect(ref.tag, isNull);
    });

    test('accepts a short image id', () {
      final ref = DockerImageRef.parse('a1b2c3d4e5f6');
      expect(ref.isId, isTrue);
      expect(ref.tag, isNull);
      expect(ref.reference, 'a1b2c3d4e5f6');
    });

    test('accepts a sha256-prefixed image id', () {
      final id = 'sha256:${'a' * 64}';
      final ref = DockerImageRef.parse(id);
      expect(ref.isId, isTrue);
      expect(ref.reference, id);
    });

    test('keeps a digest pin', () {
      final ref = DockerImageRef.parse('app@sha256:${'b' * 64}');
      expect(ref.name, 'app');
      expect(ref.digest, 'sha256:${'b' * 64}');
      expect(ref.tag, isNull);
      expect(ref.reference, 'app@sha256:${'b' * 64}');
    });

    test('rejects an empty reference', () {
      expect(() => DockerImageRef.parse('   '), throwsArgumentError);
    });

    test('a local image never shares a file with the registry copy', () {
      final stem = DockerImageRef.parse('ubuntu:latest').fileStem;
      expect(stem, 'local_ubuntu_latest');
      expect(stem, isNot('library_ubuntu_latest'));
      expect(DockerImageRef.parse('localhost:5000/team/app:v1').fileStem,
          'local_localhost_5000_team_app_v1');
    });
  });

  group('DockerLocalImages.list', () {
    test('lists tagged images and names untagged ones by id', () async {
      final docker = DockerLocalImages(run: (exe, args) async {
        expect(exe, 'docker');
        expect(args.first, 'image');
        return ProcessResult(
            0,
            0,
            'ubuntu:22.04\t3f2a1b0c9d8e\n'
                '<none>:<none>\tdeadbeef1234\n'
                'localhost:5000/app:v1\t9988776655aa\n',
            '');
      });
      expect(await docker.list(), [
        'ubuntu:22.04',
        'deadbeef1234',
        'localhost:5000/app:v1',
      ]);
    });

    test('drops duplicates and blank lines', () async {
      final docker = DockerLocalImages(
          run: (_, __) async =>
              ProcessResult(0, 0, 'a:1\tid1\n\na:1\tid1\n', ''));
      expect(await docker.list(), ['a:1']);
    });

    test('is empty when docker reports an error', () async {
      final docker = DockerLocalImages(
          run: (_, __) async =>
              ProcessResult(0, 1, '', 'Cannot connect to the Docker daemon'));
      expect(await docker.list(), isEmpty);
    });

    test('is empty when docker is not installed', () async {
      final docker = DockerLocalImages(
          run: (_, __) async => throw ProcessException('docker', const []));
      expect(await docker.list(), isEmpty);
    });
  });

  group('DockerImageConfig', () {
    test('turns env, entrypoint and cmd into one start command', () {
      final config = DockerImageConfig.fromJson({
        'config': {
          'Env': ['PATH=/usr/bin', 'LANG=C'],
          'Entrypoint': ['/entry.sh'],
          'Cmd': ['bash', '-l'],
          'User': 'dev',
        }
      });
      expect(config.user, 'dev');
      expect(config.startCmd,
          'export PATH=/usr/bin; export LANG=C; /entry.sh; bash -l');
    });

    test('ignores a numeric user, which names a uid and not an account', () {
      final config = DockerImageConfig.fromJson({
        'config': {'User': '1000:1000'}
      });
      expect(config.user, isNull);
    });

    test('keeps the account out of a user:group pair', () {
      final config = DockerImageConfig.fromJson({
        'config': {'User': 'app:app'}
      });
      expect(config.user, 'app');
    });

    test('collects the user and group build steps', () {
      final config = DockerImageConfig.fromJson({
        'config': {},
        'history': [
          {'created_by': '/bin/sh -c groupadd -r app'},
          {'created_by': '/bin/sh -c useradd -r -g app app'},
          {'created_by': '/bin/sh -c apt-get update'},
          {'empty_layer': true},
        ]
      });
      expect(config.groupCmds, ['/bin/sh -c groupadd -r app']);
      expect(config.userCmds, ['/bin/sh -c useradd -r -g app app']);
    });

    test('survives a config with nothing in it', () {
      final config = DockerImageConfig.fromJson({});
      expect(config.user, isNull);
      expect(config.startCmd, isNull);
      expect(config.userCmds, isEmpty);
      expect(config.groupCmds, isEmpty);
    });
  });

  group('DockerLocalImages.import', () {
    late Directory root;

    setUp(() async {
      WidgetsFlutterBinding.ensureInitialized();
      root = await Directory.systemTemp.createTemp('docker_local_image');
      SharedPreferences.setMockInitialValues({'DistroPath': root.path});
      await initPrefs();
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    /// A fake `docker` whose `save` writes [entries] to the requested path.
    DockerRunner saving(Map<String, List<int>> entries,
            {int exitCode = 0, String stderr = ''}) =>
        (exe, args) async {
          if (args.first != 'save') return ProcessResult(0, 0, '', '');
          expect(args[1], '-o');
          if (exitCode != 0) return ProcessResult(0, exitCode, '', stderr);
          await writeTar(args[2], entries);
          return ProcessResult(0, 0, '', '');
        };

    test('imports a legacy docker save archive, layers merged in order',
        () async {
      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {
            'Config': 'abc123.json',
            'Layers': ['l0/layer.tar', 'l1/layer.tar'],
          }
        ])),
        'abc123.json': utf8.encode(json.encode({
          'config': {
            'Env': ['PATH=/bin'],
            'Cmd': ['sh'],
            'User': 'app',
          },
          'history': [
            {'created_by': '/bin/sh -c useradd app'}
          ],
        })),
        'l0/layer.tar':
            await layerBytes({'etc/os-release': 'base', 'etc/keep': 'kept'}),
        'l1/layer.tar': await layerBytes({'etc/os-release': 'top'}),
      };

      final stem = await DockerLocalImages(run: saving(entries))
          .import('mydistro', 'myapp:v1', onStatus: (_) {}, progress: _noop);

      expect(stem, 'local_myapp_v1');
      final rootfs = rootfsPath(stem);
      expect(File(rootfs).existsSync(), isTrue);

      final contents = await readRootfs(rootfs);
      // The upper layer wins, and what it does not replace survives.
      expect(contents['etc/os-release'], 'top');
      expect(contents['etc/keep'], 'kept');

      // The image's defaults reach the instance, as they do for a registry
      // pull.
      expect(prefs.getString('StartUser_mydistro'), 'app');
      expect(prefs.getString('StartCmd_mydistro'), 'export PATH=/bin; ; sh');
      expect(prefs.getStringList('UserCmds_$stem'), ['/bin/sh -c useradd app']);
      expect(prefs.getStringList('GroupCmds_$stem'), isEmpty);
    });

    test('imports an OCI-layout archive, whose layers are plain blob paths',
        () async {
      // Docker Engine 25's containerd image store writes this shape; appending
      // "/layer.tar" to these names finds nothing.
      final digest = 'blobs/sha256/${'c' * 64}';
      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {
            'Config': 'blobs/sha256/${'d' * 64}',
            'Layers': [digest],
          }
        ])),
        'blobs/sha256/${'d' * 64}': utf8.encode(json.encode({'config': {}})),
        digest: await layerBytes({'etc/hostname': 'oci'}),
      };

      final stem = await DockerLocalImages(run: saving(entries))
          .import('oci', 'app', onStatus: (_) {}, progress: _noop);

      final contents = await readRootfs(rootfsPath(stem));
      expect(contents['etc/hostname'], 'oci');
    });

    test('writes a layer the manifest lists twice into both slots', () async {
      // Identical layers appear once in the archive but twice in the layer
      // list; only filling the first slot left the second one empty.
      final shared = 'blobs/sha256/${'e' * 64}';
      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {
            'Layers': [shared, 'l1/layer.tar', shared],
          }
        ])),
        shared: await layerBytes({'etc/shared': 'same'}),
        'l1/layer.tar': await layerBytes({'etc/mid': 'mid'}),
      };

      final stem = await DockerLocalImages(run: saving(entries))
          .import('dup', 'app:1', onStatus: (_) {}, progress: _noop);

      final contents = await readRootfs(rootfsPath(stem));
      expect(contents['etc/shared'], 'same');
      expect(contents['etc/mid'], 'mid');
    });

    test('applies whiteouts from the upper layer', () async {
      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {
            'Layers': ['l0/layer.tar', 'l1/layer.tar'],
          }
        ])),
        'l0/layer.tar': await layerBytes({'etc/gone': 'x', 'etc/stays': 'y'}),
        'l1/layer.tar': await layerBytes({'etc/.wh.gone': ''}),
      };

      final stem = await DockerLocalImages(run: saving(entries))
          .import('wh', 'app:1', onStatus: (_) {}, progress: _noop);

      final contents = await readRootfs(rootfsPath(stem));
      expect(contents.containsKey('etc/gone'), isFalse);
      expect(contents['etc/stays'], 'y');
    });

    test('does not leave the export behind', () async {
      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {
            'Layers': ['l0/layer.tar'],
          }
        ])),
        'l0/layer.tar': await layerBytes({'a': 'b'}),
      };
      await DockerLocalImages(run: saving(entries))
          .import('tidy', 'app:1', onStatus: (_) {}, progress: _noop);
      expect(
          Directory((getTmpPath()..cd('local_app_1')).path).listSync().isEmpty,
          isTrue);
    });

    test('writes the rootfs where create looks when a data path is set',
        () async {
      // A configured data path moves the distros folder; a rootfs left under
      // the distro path would then never be found by the import.
      final data = await Directory.systemTemp.createTemp('docker_data_path');
      addTearDown(() async {
        if (await data.exists()) await data.delete(recursive: true);
      });
      SharedPreferences.setMockInitialValues(
          {'DistroPath': root.path, 'DataPath': data.path});
      await initPrefs();

      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {
            'Layers': ['l0/layer.tar'],
          }
        ])),
        'l0/layer.tar': await layerBytes({'a': 'b'}),
      };
      final stem = await DockerLocalImages(run: saving(entries))
          .import('split', 'app:1', onStatus: (_) {}, progress: _noop);

      expect(File(rootfsPath(stem)).existsSync(), isTrue);
      expect(rootfsPath(stem), startsWith(data.path));
    });

    test('reports what docker save said when it fails', () async {
      final docker = DockerLocalImages(
          run: saving(const {}, exitCode: 1, stderr: 'No such image: app:1'));
      await expectLater(
        docker.import('bad', 'app:1', onStatus: (_) {}, progress: _noop),
        throwsA(predicate((e) => '$e'.contains('No such image: app:1'))),
      );
    });

    test('fails when docker is not installed', () async {
      final docker = DockerLocalImages(
          run: (_, __) async => throw ProcessException('docker', const []));
      await expectLater(
        docker.import('bad', 'app:1', onStatus: (_) {}, progress: _noop),
        throwsA(predicate((e) => '$e'.contains('Docker is not available'))),
      );
    });

    test('fails when a layer the manifest names is missing', () async {
      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {
            'Layers': ['l0/layer.tar', 'missing/layer.tar'],
          }
        ])),
        'l0/layer.tar': await layerBytes({'a': 'b'}),
      };
      await expectLater(
        DockerLocalImages(run: saving(entries))
            .import('bad', 'app:1', onStatus: (_) {}, progress: _noop),
        throwsA(predicate((e) => '$e'.contains('missing/layer.tar'))),
      );
    });

    test('fails when the export has no manifest', () async {
      final entries = <String, List<int>>{'oci-layout': utf8.encode('{}')};
      await expectLater(
        DockerLocalImages(run: saving(entries))
            .import('bad', 'app:1', onStatus: (_) {}, progress: _noop),
        throwsA(predicate((e) => '$e'.contains('No manifest.json'))),
      );
    });

    test('fails when the manifest lists no layers', () async {
      final entries = <String, List<int>>{
        'manifest.json': utf8.encode(json.encode([
          {'Layers': <String>[]}
        ])),
      };
      await expectLater(
        DockerLocalImages(run: saving(entries))
            .import('bad', 'app:1', onStatus: (_) {}, progress: _noop),
        throwsA(predicate((e) => '$e'.contains('no layers'))),
      );
    });
  });
}

void _noop(int count, int total, int countStep, int totalStep) {}
