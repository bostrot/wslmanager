/// Tests for the rootfs-catalogue create path: the download in
/// [WSLApi.create] and the user setup in [WSLApi.createUser].
///
/// Both were rewritten after the phase-06 install tests. The download used to
/// spin forever on a dead URL and to accept a truncated file as a success; the
/// user setup used to be five hard-coded `apt-get`/`useradd -G sudo` commands
/// that created no user at all on thirteen of the nineteen catalogue entries.

import 'dart:io';

import 'package:chunked_downloader/chunked_downloader.dart' as cd;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

/// Stands in for a real download. Writes [bytes] to the *final* path, which is
/// the state the package leaves behind after its own `.tmp` rename.
class _FakeDownloader extends MockChunkedDownloader {
  _FakeDownloader({this.error, this.bytes = 0, this.reportedTotal});

  /// Thrown from [start], the way the package reports a non-2xx response.
  final Object? error;
  final int bytes;

  /// The `Content-Length` the server claimed. Differs from [bytes] to
  /// simulate a connection cut mid-transfer; -1 for no `Content-Length`.
  final int? reportedTotal;

  /// Whether a leftover `.tmp` was still on disk when the download started.
  bool sawStaleTmp = false;

  @override
  Future<cd.ChunkedDownloader> start() async {
    sawStaleTmp = File('$saveFilePath.tmp').existsSync();
    if (error != null) throw error!;
    onProgress?.call(bytes, reportedTotal ?? bytes, 1.0);
    final file = File(saveFilePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(bytes, 0));
    done = true;
    onDone?.call(file);
    return this;
  }
}

void main() {
  late Directory tempDir;
  late MockShell mockShell;
  late List<String> statusMessages;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('catalogue_test');
    SharedPreferences.setMockInitialValues({'DataPath': tempDir.path});
    await initPrefs();
    mockShell = MockShell();
    statusMessages = [];
    distroRootfsLinks = {'Test Distro': 'https://example.invalid/rootfs.tar.gz'};
  });

  tearDown(() async {
    distroRootfsLinks = {};
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String downloadPathFor(String name) =>
      (getDataPath()..cd('distros')).file('$name.tar.gz');

  group('create() download', () {
    test('a dead URL reports an error instead of hanging', () async {
      final downloader =
          _FakeDownloader(error: const HttpException('HTTP 404: Not Found'));
      final api = WSLApi(
        shell: mockShell,
        downloaderFactory: ({
          required String url,
          required String saveFilePath,
          Map<String, String>? headers,
          int? chunkSize,
          Function(int, int, double)? onProgress,
          Function(File)? onDone,
          Function(dynamic)? onError,
        }) {
          downloader.url = url;
          downloader.saveFilePath = saveFilePath;
          downloader.onProgress = onProgress;
          return downloader;
        },
      );

      // The old cascade `..start()` dropped this exception and polled `done`
      // forever, so the real assertion here is that the future completes.
      final result = await api
          .create('TestInstance', 'Test Distro', tempDir.path,
              statusMessages.add)
          .timeout(const Duration(seconds: 10));

      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('404'));
      // Nothing may be imported from a download that failed.
      expect(mockShell.runCalls.any((c) => c.contains('--import')), isFalse);
      expect(File(downloadPathFor('Test Distro')).existsSync(), isFalse);
    });

    test('a truncated download is rejected and not left on disk', () async {
      final api = WSLApi(
        shell: mockShell,
        downloaderFactory: ({
          required String url,
          required String saveFilePath,
          Map<String, String>? headers,
          int? chunkSize,
          Function(int, int, double)? onProgress,
          Function(File)? onDone,
          Function(dynamic)? onError,
        }) {
          final d = _FakeDownloader(bytes: 512, reportedTotal: 4096);
          d.saveFilePath = saveFilePath;
          d.onProgress = onProgress;
          return d;
        },
      );

      final result = await api.create(
          'TestInstance', 'Test Distro', tempDir.path, statusMessages.add);

      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('512 of 4096'));
      // A partial file left behind would be treated as a cache hit forever.
      expect(File(downloadPathFor('Test Distro')).existsSync(), isFalse);
      expect(mockShell.runCalls.any((c) => c.contains('--import')), isFalse);
    });

    test('an empty file is rejected', () async {
      final api = WSLApi(
        shell: mockShell,
        downloaderFactory: ({
          required String url,
          required String saveFilePath,
          Map<String, String>? headers,
          int? chunkSize,
          Function(int, int, double)? onProgress,
          Function(File)? onDone,
          Function(dynamic)? onError,
        }) {
          final d = _FakeDownloader(bytes: 0, reportedTotal: -1);
          d.saveFilePath = saveFilePath;
          d.onProgress = onProgress;
          return d;
        },
      );

      final result = await api.create(
          'TestInstance', 'Test Distro', tempDir.path, statusMessages.add);

      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('empty'));
    });

    test('a complete download imports and leaves no .tmp behind', () async {
      late String seenSavePath;
      final api = WSLApi(
        shell: mockShell,
        downloaderFactory: ({
          required String url,
          required String saveFilePath,
          Map<String, String>? headers,
          int? chunkSize,
          Function(int, int, double)? onProgress,
          Function(File)? onDone,
          Function(dynamic)? onError,
        }) {
          seenSavePath = saveFilePath;
          final d = _FakeDownloader(bytes: 2048, reportedTotal: 2048);
          d.saveFilePath = saveFilePath;
          d.onProgress = onProgress;
          return d;
        },
      );

      final result = await api.create(
          'TestInstance', 'Test Distro', tempDir.path, statusMessages.add);

      expect(result.exitCode, 0);
      // The package appends its own '.tmp'. Handing it a path that already
      // ended in '.tmp' is what produced '<name>.tar.gz.tmp.tmp' on disk.
      expect(seenSavePath, endsWith('Test Distro.tar.gz'));
      expect(File(downloadPathFor('Test Distro')).existsSync(), isTrue);
      expect(File('${downloadPathFor('Test Distro')}.tmp').existsSync(), isFalse);
      expect(File('${downloadPathFor('Test Distro')}.tmp.tmp').existsSync(),
          isFalse);
      expect(mockShell.runCalls.any((c) => c.contains('--import')), isTrue);
    });

    test('a stale .tmp from a killed run is cleared first', () async {
      // The package *appends* to its temp file, so a leftover would be glued
      // in front of the new download.
      final stale = File('${downloadPathFor('Test Distro')}.tmp');
      await stale.parent.create(recursive: true);
      await stale.writeAsBytes(List.filled(99, 7));

      late _FakeDownloader downloader;
      final api = WSLApi(
        shell: mockShell,
        downloaderFactory: ({
          required String url,
          required String saveFilePath,
          Map<String, String>? headers,
          int? chunkSize,
          Function(int, int, double)? onProgress,
          Function(File)? onDone,
          Function(dynamic)? onError,
        }) {
          downloader = _FakeDownloader(bytes: 2048, reportedTotal: 2048);
          downloader.saveFilePath = saveFilePath;
          downloader.onProgress = onProgress;
          return downloader;
        },
      );

      await api.create(
          'TestInstance', 'Test Distro', tempDir.path, statusMessages.add);

      expect(downloader.sawStaleTmp, isFalse);
    });

    test('progress without a Content-Length reports MB, not a negative %',
        () async {
      final api = WSLApi(
        shell: mockShell,
        downloaderFactory: ({
          required String url,
          required String saveFilePath,
          Map<String, String>? headers,
          int? chunkSize,
          Function(int, int, double)? onProgress,
          Function(File)? onDone,
          Function(dynamic)? onError,
        }) {
          final d = _FakeDownloader(bytes: 4 * 1024 * 1024, reportedTotal: -1);
          d.saveFilePath = saveFilePath;
          d.onProgress = onProgress;
          return d;
        },
      );

      await api.create(
          'TestInstance', 'Test Distro', tempDir.path, statusMessages.add);

      // The old code printed `(count / total * 100)` with total == -1, so the
      // dialog counted downwards through negative percentages.
      expect(statusMessages.any((m) => m.contains('%')), isFalse);
      expect(statusMessages.any((m) => m.contains('4 MB')), isTrue);
    });
  });

  group('createUser()', () {
    test('rejects a name that would be shell code', () async {
      final api = WSLApi(shell: mockShell);
      for (final bad in [
        'root; rm -rf /',
        r'a$(id)',
        'has space',
        '',
        'Capital',
        '1leading',
      ]) {
        expect(WSLApi.isPlainUserName(bad), isFalse, reason: bad);
        final result = await api.createUser('Test', bad);
        expect(result.exitCode, isNot(0), reason: bad);
      }
      for (final good in ['tester', '_svc', 'a-b_c9']) {
        expect(WSLApi.isPlainUserName(good), isTrue, reason: good);
      }
    });

    test('runs through sh, not bash — Alpine has no bash', () async {
      final api = WSLApi(shell: mockShell);
      await api.createUser('Test', 'tester');

      final args = mockShell.runCalls.last;
      expect(args, containsAllInOrder(['-d', 'Test', '-u', 'root']));
      expect(args, contains('--exec'));
      expect(args, contains('sh'));
      expect(args.contains('bash'), isFalse);
    });

    test('reading and writing /etc/wsl.conf does not need bash either',
        () async {
      // Same failure as createUser: with `bash -c` these two exited 1 on
      // Alpine with `execvpe(bash) failed`, so a freshly created instance
      // never got the `[user] default=` line and still opened as root.
      final api = WSLApi(shell: mockShell);

      await api.readDistroFile('Test', '/etc/wsl.conf');
      expect(mockShell.runCalls.last, contains('sh'));
      expect(mockShell.runCalls.last.contains('bash'), isFalse);

      await api.writeDistroFile('Test', '/etc/wsl.conf', '[user]\n');
      expect(
          mockShell.runCalls.where((c) => c.contains('bash')).toList(), isEmpty);
    });

    test('covers every package manager in the catalogue', () {
      final script = WSLApi.buildUserSetupScript('tester');
      // The nineteen catalogue entries span five package managers.
      for (final pm in ['apt-get', 'dnf', 'zypper', 'apk', 'pacman', 'yum']) {
        expect(script, contains(pm), reason: pm);
      }
      // Arch's WSL image ships an unpopulated keyring; without this pacman
      // fails with 'required key missing from keyring' and sudo never lands.
      expect(script, contains('pacman-key --init'));
    });

    test('does not assume bash, a sudo group, or /etc/sudoers.d exists', () {
      final script = WSLApi.buildUserSetupScript('tester');
      // The old command was `useradd -m -s /bin/bash -G sudo <user>`, which
      // exits 6 with "group 'sudo' does not exist" on every non-Debian entry.
      expect(script.contains('-G sudo '), isFalse);
      expect(script, contains('for g in sudo wheel'));
      expect(script, contains('[ -x /bin/bash ] && sh=/bin/bash'));
      // busybox userlands have adduser but no useradd.
      expect(script, contains('adduser -D'));
      expect(script, contains('mkdir -p /etc/sudoers.d'));
    });

    test('interpolates the user name exactly once, as a shell variable', () {
      final script = WSLApi.buildUserSetupScript('tester');
      expect(script, contains('\nu=tester\n'));
      // Every later use goes through $u, so the name is never re-expanded.
      expect(RegExp('tester').allMatches(script).length, 1);
    });
  });
}
