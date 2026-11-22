import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/updater.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Answers the releases API with [releases], and any download with [bytes].
class _ReleasesAdapter implements HttpClientAdapter {
  _ReleasesAdapter(this.releases, {this.bytes = const <int>[]});

  final Object releases;
  final List<int> bytes;

  int calls = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    if (options.path.contains('/releases/download/')) {
      return ResponseBody.fromBytes(bytes, 200, headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      });
    }
    return ResponseBody.fromString(jsonEncode(releases), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Every request fails, as if the machine were offline.
class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException.connectionError(
        requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

/// Records what [UpdateService.install] tried to start.
class _RecordingLauncher {
  final List<List<String>> calls = <List<String>>[];

  Future<void> call(String executable, List<String> arguments) async {
    calls.add(<String>[executable, ...arguments]);
  }
}

/// Stands in for `ditto`: reports success and drops a bundle where the real
/// one would have unpacked it.
class _UnpackShell implements Shell {
  _UnpackShell({this.bundleName = 'WSL Manager.app'});

  /// The bundle `ditto` leaves behind; empty stands for an unpack that
  /// produced nothing usable.
  final String bundleName;
  List<String>? lastArguments;

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      Encoding? stdoutEncoding = systemEncoding,
      Encoding? stderrEncoding = systemEncoding}) async {
    lastArguments = arguments;
    if (bundleName.isNotEmpty) {
      Directory('${arguments.last}/$bundleName').createSync(recursive: true);
    }
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<Process> start(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessStartMode mode = ProcessStartMode.normal}) {
    throw UnimplementedError();
  }
}

Dio _dioWith(HttpClientAdapter adapter) => Dio()..httpClientAdapter = adapter;

/// One release entry, carrying the assets every platform's job attaches.
Map<String, Object?> _release(
  String tag, {
  Duration age = const Duration(days: 30),
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object?>>? assets,
}) {
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  return {
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'published_at': DateTime.now().toUtc().subtract(age).toIso8601String(),
    'html_url': 'https://github.com/bostrot/wslmanager/releases/$tag',
    'assets': assets ??
        [
          {
            'name': 'wsl2-distro-manager-v$version.zip',
            'browser_download_url': 'https://github.com/x/releases/download/'
                '$tag/wsl2-distro-manager-v$version.zip',
            'size': 10,
          },
          {
            'name': 'wsl2-distro-manager-v$version-unsigned.msix',
            'browser_download_url': 'https://github.com/x/releases/download/'
                '$tag/wsl2-distro-manager-v$version-unsigned.msix',
            'size': 10,
          },
          {
            'name': 'wsl2-distro-manager-v$version-setup.exe',
            'browser_download_url': 'https://github.com/x/releases/download/'
                '$tag/wsl2-distro-manager-v$version-setup.exe',
            'size': 4,
          },
          {
            'name': 'wsl2-distro-manager-v$version-macos.dmg',
            'browser_download_url': 'https://github.com/x/releases/download/'
                '$tag/wsl2-distro-manager-v$version-macos.dmg',
            'size': 10,
          },
          {
            'name': 'wsl2-distro-manager-v$version-macos.zip',
            'browser_download_url': 'https://github.com/x/releases/download/'
                '$tag/wsl2-distro-manager-v$version-macos.zip',
            'size': 4,
          },
        ],
  };
}

/// What [selectUpdateAsset] is expected to pick on the host running the test.
String get _expectedAssetSuffix =>
    Platform.isMacOS ? '-macos.zip' : '-setup.exe';

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  /// The real, detached launcher, so a test that swaps it in can put it back.
  final defaultLauncher = UpdateService.launcher;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    UpdateService.channelOverride = UpdateChannel.direct;
    UpdateService.resolvedExecutableOverride = null;
  });

  tearDown(() {
    UpdateService.channelOverride = null;
    UpdateService.resolvedExecutableOverride = null;
    UpdateService.launcher = defaultLauncher;
  });

  group('compareVersions', () {
    test('orders by component, not by digit soup', () {
      // The old versionToDouble collapse read this pair the wrong way round
      // once the minor went past 9.
      expect(compareVersions('1.11.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.11.0'), greaterThan(0));
      expect(compareVersions('1.9.0', '1.11.0'), lessThan(0));
    });

    test('ignores the v prefix, build and pre-release tails', () {
      expect(compareVersions('v1.2.3', '1.2.3'), 0);
      expect(compareVersions('1.2.3+4', '1.2.3'), 0);
      expect(compareVersions('1.2.3-beta.1', '1.2.3'), 0);
    });

    test('pads a shorter version with zeroes', () {
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
    });

    test('treats an unparsable component as zero rather than throwing', () {
      expect(compareVersions('1.x.0', '1.0.0'), 0);
      expect(compareVersions('', '0.0.0'), 0);
    });
  });

  group('updateChannelFor', () {
    test('a packaged Windows build is the Store\'s to update', () {
      expect(updateChannelFor(windows: true, macos: false, packaged: true),
          UpdateChannel.store);
    });

    test('an unpackaged Windows build updates itself', () {
      expect(updateChannelFor(windows: true, macos: false, packaged: false),
          UpdateChannel.direct);
    });

    test('macOS is always direct — there is no Mac App Store listing', () {
      expect(updateChannelFor(windows: false, macos: true, packaged: true),
          UpdateChannel.direct);
    });

    test('anything else ships no installer', () {
      expect(updateChannelFor(windows: false, macos: false, packaged: false),
          UpdateChannel.unsupported);
    });
  });

  group('selectUpdateAsset', () {
    final assets = (_release('v2.0.0')['assets'] as List)
        .map((a) => ReleaseAsset.fromJson(a)!)
        .toList();

    test('Windows takes the installer, never the zip or the unsigned msix', () {
      final asset = selectUpdateAsset(assets, macos: false);
      expect(asset?.name, endsWith('-setup.exe'));
    });

    test('macOS prefers the zip, because a zip holds the app itself', () {
      final asset = selectUpdateAsset(assets, macos: true);
      expect(asset?.name, endsWith('-macos.zip'));
    });

    test('macOS falls back to the dmg when the zip is missing', () {
      final withoutZip =
          assets.where((a) => !a.name.endsWith('-macos.zip')).toList();
      expect(selectUpdateAsset(withoutZip, macos: true)?.name,
          endsWith('-macos.dmg'));
    });

    test('a release with nothing installable answers null', () {
      final onlyMsix = assets.where((a) => a.name.endsWith('.msix')).toList();
      expect(selectUpdateAsset(onlyMsix, macos: false), isNull);
      expect(selectUpdateAsset(onlyMsix, macos: true), isNull);
      expect(selectUpdateAsset(const <ReleaseAsset>[], macos: true), isNull);
    });
  });

  group('ReleaseAsset.fromJson', () {
    test('drops an entry with no name or no url', () {
      expect(ReleaseAsset.fromJson({'name': 'a.exe'}), isNull);
      expect(
          ReleaseAsset.fromJson({'browser_download_url': 'https://x'}), isNull);
      expect(ReleaseAsset.fromJson('not an object'), isNull);
    });

    test('defaults an absent size to zero rather than failing', () {
      final asset = ReleaseAsset.fromJson(
          {'name': 'a.exe', 'browser_download_url': 'https://x'});
      expect(asset?.size, 0);
    });
  });

  group('check', () {
    test('offers a newer release with the asset this host can apply', () async {
      final service =
          UpdateService(dio: _dioWith(_ReleasesAdapter([_release('v2.0.0')])));
      final info = await service.check(version: '1.11.0');
      expect(info, isNotNull);
      expect(info!.version, '2.0.0');
      expect(info.canInstall, isTrue);
      expect(info.asset!.name, endsWith(_expectedAssetSuffix));
      expect(info.releaseUrl, contains('releases/v2.0.0'));
    });

    test('says nothing when the running version is already current', () async {
      final service =
          UpdateService(dio: _dioWith(_ReleasesAdapter([_release('v2.0.0')])));
      expect(await service.check(version: '2.0.0'), isNull);
      expect(await service.check(version: '2.1.0'), isNull);
    });

    test('a Store install is never offered an update', () async {
      UpdateService.channelOverride = UpdateChannel.store;
      final adapter = _ReleasesAdapter([_release('v2.0.0')]);
      final service = UpdateService(dio: _dioWith(adapter));
      expect(await service.check(version: '1.0.0'), isNull);
      // And it does not even ask.
      expect(adapter.calls, 0);
    });

    test('holds a release back until it has been out for the soak', () async {
      final service = UpdateService(
          dio: _dioWith(_ReleasesAdapter(
              [_release('v2.0.0', age: const Duration(hours: 6))])));
      expect(await service.check(version: '1.0.0'), isNull);
      // A check the user asked for skips the wait.
      expect(await service.check(version: '1.0.0', minimumAge: Duration.zero),
          isNotNull);
    });

    test('skips a version the user skipped, until asked directly', () async {
      final service =
          UpdateService(dio: _dioWith(_ReleasesAdapter([_release('v2.0.0')])));
      final info = await service.check(version: '1.0.0');
      await service.skip(info!);

      expect(prefs.getString(UpdateService.skippedVersionPref), '2.0.0');
      expect(await service.check(version: '1.0.0'), isNull);
      expect(await service.check(version: '1.0.0', includeSkipped: true),
          isNotNull);
    });

    test('a skipped version does not hide the release after it', () async {
      await prefs.setString(UpdateService.skippedVersionPref, '2.0.0');
      final service =
          UpdateService(dio: _dioWith(_ReleasesAdapter([_release('v2.1.0')])));
      expect(await service.check(version: '1.0.0'), isNotNull);
    });

    test('ignores drafts and pre-releases', () async {
      final service = UpdateService(
          dio: _dioWith(_ReleasesAdapter([
        _release('v3.0.0', draft: true),
        _release('v2.9.0', prerelease: true),
        _release('v2.0.0'),
      ])));
      final info = await service.check(version: '1.0.0');
      expect(info?.version, '2.0.0');
    });

    test('answers null when the network is gone', () async {
      final service = UpdateService(dio: _dioWith(_OfflineAdapter()));
      expect(await service.check(version: '1.0.0'), isNull);
    });

    test('answers null on a payload that is not a release list', () async {
      final service = UpdateService(
          dio: _dioWith(_ReleasesAdapter({'message': 'rate limited'})));
      expect(await service.check(version: '1.0.0'), isNull);
    });

    test('a release with no usable asset is still reported, without one',
        () async {
      final service = UpdateService(
          dio: _dioWith(_ReleasesAdapter([
        _release('v2.0.0', assets: [
          {
            'name': 'wsl2-distro-manager-v2.0.0-unsigned.msix',
            'browser_download_url': 'https://github.com/x/a.msix',
            'size': 1,
          }
        ]),
      ])));
      final info = await service.check(version: '1.0.0');
      expect(info, isNotNull);
      expect(info!.canInstall, isFalse);
    });
  });

  group('checkOnStartup', () {
    test('runs once a day and records the date before asking', () async {
      final adapter = _ReleasesAdapter([_release('v2.0.0')]);
      final service = UpdateService(dio: _dioWith(adapter));

      await service.checkOnStartup();
      expect(adapter.calls, 1);
      expect(prefs.getString(UpdateService.lastCheckPref),
          DateTime.now().toIso8601String().substring(0, 10));

      await service.checkOnStartup();
      expect(adapter.calls, 1);
    });

    test('does nothing when the user turned auto-checks off', () async {
      await UpdateService.setAutoCheckEnabled(false);
      final adapter = _ReleasesAdapter([_release('v2.0.0')]);
      await UpdateService(dio: _dioWith(adapter)).checkOnStartup();
      expect(adapter.calls, 0);
      expect(UpdateService.autoCheckEnabled, isFalse);
    });

    test('defaults to on, so a direct install does not go stale silently', () {
      expect(UpdateService.autoCheckEnabled, isTrue);
    });
  });

  group('download', () {
    test('writes the asset and reports progress', () async {
      final adapter =
          _ReleasesAdapter([_release('v2.0.0')], bytes: [1, 2, 3, 4]);
      final service = UpdateService(dio: _dioWith(adapter));
      final info = (await service.check(version: '1.0.0'))!;

      final seen = <double>[];
      final file = await service.download(info, onProgress: seen.add);

      expect(await file.exists(), isTrue);
      expect(await file.length(), 4);
      expect(file.path, endsWith(info.asset!.name));
      expect(seen.last, 1.0);

      await file.parent.delete(recursive: true);
    });

    test('refuses a truncated download and leaves nothing behind', () async {
      // The release says four bytes; only two arrive.
      final adapter = _ReleasesAdapter([_release('v2.0.0')], bytes: [1, 2]);
      final service = UpdateService(dio: _dioWith(adapter));
      final info = (await service.check(version: '1.0.0'))!;

      await expectLater(
          service.download(info), throwsA(isA<UpdateException>()));
      final expected = File('${Directory.systemTemp.path}/wsl-manager-update/'
          '${info.version}/${info.asset!.name}');
      expect(await expected.exists(), isFalse);
    });
  });

  group('macOS swap', () {
    test('finds the bundle around the running executable', () {
      expect(
          macAppBundleFor('/Applications/WSL Manager.app/Contents/MacOS/wsl'),
          '/Applications/WSL Manager.app');
      expect(macAppBundleFor('/usr/local/bin/wsl2distromanager'), isNull);
    });

    test('quotes paths so a space or a quote cannot escape the script', () {
      expect(shQuote('/Applications/WSL Manager.app'),
          "'/Applications/WSL Manager.app'");
      expect(shQuote("it's"), r"'it'\''s'");
    });

    test('the script waits for the app, and puts it back if the copy fails',
        () {
      final script = macSwapScript(
        stagedApp: '/tmp/staged/WSL Manager.app',
        targetApp: '/Applications/WSL Manager.app',
        pid: 4321,
      );
      expect(script, contains('kill -0 4321'));
      // And gives up rather than replacing a bundle that is still running.
      expect(script, contains('exit 1'));
      expect(script, contains("'/Applications/WSL Manager.app'"));
      expect(script, contains('/usr/bin/ditto'));
      // The rollback: the backup goes back where the bundle was.
      expect(script, contains(r'mv "$backup"'));
      expect(script, contains('/usr/bin/open'));
    });
  });

  group('install', () {
    test('hands the Windows installer its unattended flags', () async {
      final launcher = _RecordingLauncher();
      UpdateService.launcher = launcher.call;

      final file = File('${Directory.systemTemp.path}/setup.exe');
      await file.writeAsBytes([0]);
      addTearDown(() => file.deleteSync());

      expect(await UpdateService().install(file), isTrue);
      expect(launcher.calls.single.first, file.path);
      expect(launcher.calls.single,
          containsAll(UpdateService.windowsInstallerArgs));
    }, skip: !Platform.isWindows);

    test('a dmg is handed to Finder — it cannot be swapped in unattended',
        () async {
      final launcher = _RecordingLauncher();
      UpdateService.launcher = launcher.call;

      final file = File('${Directory.systemTemp.path}/wslm-test.dmg');
      await file.writeAsBytes([0]);
      addTearDown(() => file.deleteSync());

      expect(await UpdateService().install(file), isTrue);
      expect(launcher.calls.single, ['/usr/bin/open', file.path]);
    }, skip: !Platform.isMacOS);

    test('a zip is unpacked and applied by a detached swap script', () async {
      final launcher = _RecordingLauncher();
      UpdateService.launcher = launcher.call;

      final root = await Directory.systemTemp.createTemp('wslm-update');
      addTearDown(() => root.deleteSync(recursive: true));
      UpdateService.resolvedExecutableOverride =
          '${root.path}/WSL Manager.app/Contents/MacOS/wsl2distromanager';

      final file = File('${root.path}/wsl2-distro-manager-v2.0.0-macos.zip');
      await file.writeAsBytes([0]);

      final shell = _UnpackShell();
      expect(await UpdateService(shell: shell).install(file), isTrue);

      expect(shell.lastArguments!.first, '-x');
      expect(launcher.calls.single.first, '/bin/sh');

      // Valid sh, checked by sh itself: a quoting slip in a path with a
      // space would only surface on a user's machine, after the app had
      // already closed.
      final syntax =
          await Process.run('/bin/sh', ['-n', launcher.calls.single.last]);
      expect(syntax.exitCode, 0, reason: '${syntax.stderr}');

      final script = await File(launcher.calls.single.last).readAsString();
      expect(script, contains("'${root.path}/WSL Manager.app'"));
      expect(script, contains("'${root.path}/staged/WSL Manager.app'"));
    }, skip: !Platform.isMacOS);

    test('an unpack that produces no bundle is a reported failure', () async {
      final root = await Directory.systemTemp.createTemp('wslm-update');
      addTearDown(() => root.deleteSync(recursive: true));
      UpdateService.resolvedExecutableOverride =
          '${root.path}/WSL Manager.app/Contents/MacOS/wsl2distromanager';

      final file = File('${root.path}/wsl2-distro-manager-v2.0.0-macos.zip');
      await file.writeAsBytes([0]);

      await expectLater(
          UpdateService(shell: _UnpackShell(bundleName: '')).install(file),
          throwsA(isA<UpdateException>()));
    }, skip: !Platform.isMacOS);
  });
}
