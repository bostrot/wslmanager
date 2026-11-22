// Automated updates for the builds nothing else keeps current.
//
// The Microsoft Store updates its own copy of the app, and a packaged install
// could not write into itself anyway — so a Store build is left alone here.
// Everything else the project ships arrives as a plain download: the Windows
// `-setup.exe` and portable zip from GitHub or wslmanager.com, and every macOS
// build, since there is no Mac App Store listing. Those sit at whatever
// version they were installed at until someone notices a release, which is
// what this replaces (bostrot/ai-tasks#43).
//
// The shape is deliberately small: ask the releases API what the newest
// version is, download the one artefact this host can actually apply, and hand
// it to the platform's own installer. No appcast, no signing keys, no native
// plugin — the same GitHub release the manual "download now" banner already
// pointed at, followed through to the end.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The human-readable releases page. Used as the fallback link when a release
/// carries no artefact this host can install.
const String releasesPageUrl =
    'https://github.com/bostrot/wslmanager/releases';

/// Where this copy of the app came from, which is what decides whether it may
/// update itself.
enum UpdateChannel {
  /// Installed from the Microsoft Store. The Store owns the update.
  store,

  /// Installed from the website or GitHub — the Windows installer, the
  /// portable zip, and every macOS build. Nothing else updates these.
  direct,

  /// A host the project ships no installer for (a Linux dev build).
  unsupported,
}

/// Raised for the failures the update flow can explain to the user. [messageKey]
/// is an i18n key, so the dialog stays a plain renderer.
class UpdateException implements Exception {
  const UpdateException(this.messageKey);

  final String messageKey;

  @override
  String toString() => 'UpdateException($messageKey)';
}

/// One downloadable file attached to a GitHub release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    this.size = 0,
  });

  final String name;
  final String url;

  /// Bytes, as the API reported them; 0 when it did not say.
  final int size;

  /// Null for anything that is not a usable asset object, so a malformed
  /// entry drops out of the list instead of failing the whole check.
  static ReleaseAsset? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final url = json['browser_download_url'];
    if (name is! String || url is! String) return null;
    if (name.isEmpty || url.isEmpty) return null;
    final size = json['size'];
    return ReleaseAsset(name: name, url: url, size: size is int ? size : 0);
  }
}

/// A release that is newer than the running app.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.asset,
  });

  /// The release tag with its `v` removed, e.g. `1.12.0`.
  final String version;

  /// The release page, for the notes and for the hosts that cannot install
  /// anything themselves.
  final String releaseUrl;

  /// The artefact this host can apply, or null when the release carries none
  /// — an in-flight release whose macOS job has not attached its zip yet, for
  /// instance.
  final ReleaseAsset? asset;

  bool get canInstall => asset != null;
}

/// Orders two version strings the way a human reads them.
///
/// Returns <0 when [a] is older than [b], 0 when they are the same release,
/// >0 when [a] is newer. A leading `v`, a `+build` tail and a `-beta`
/// pre-release tail are all ignored, so `v1.11.0+3` and `1.11.0` compare
/// equal — the app only ever compares against release tags, which do not
/// disagree in that tail.
int compareVersions(String a, String b) {
  final left = _versionParts(a);
  final right = _versionParts(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

List<int> _versionParts(String version) {
  var text = version.trim().toLowerCase();
  if (text.startsWith('v')) text = text.substring(1);
  final core = text.split(RegExp(r'[+\-]')).first;
  return core.split('.').map((part) => int.tryParse(part) ?? 0).toList();
}

/// The channel for a host, split out from [UpdateService.channel] so both
/// answers are testable from either dev machine.
UpdateChannel updateChannelFor({
  required bool windows,
  required bool macos,
  required bool packaged,
}) {
  if (macos) return UpdateChannel.direct;
  if (!windows) return UpdateChannel.unsupported;
  return packaged ? UpdateChannel.store : UpdateChannel.direct;
}

/// The asset this host can actually apply, or null when the release has none.
///
/// Windows takes the Inno installer: it is the only Windows artefact that
/// knows how to replace an existing install — the zip is a loose folder and
/// the release msix is unsigned, so it cannot be installed at all. macOS
/// prefers the zip over the dmg because a zip holds the `.app` itself and can
/// therefore be swapped in without asking anyone to drag anything; the dmg is
/// the fallback, and only ever opens in Finder.
ReleaseAsset? selectUpdateAsset(
  List<ReleaseAsset> assets, {
  required bool macos,
}) {
  ReleaseAsset? firstEndingIn(String suffix) {
    for (final asset in assets) {
      if (asset.name.toLowerCase().endsWith(suffix)) return asset;
    }
    return null;
  }

  if (macos) {
    return firstEndingIn('-macos.zip') ?? firstEndingIn('.dmg');
  }
  return firstEndingIn('-setup.exe');
}

/// `/Applications/WSL Manager.app/Contents/MacOS/wsl2distromanager` → the
/// `.app` around it. Null when the executable is not inside a bundle, which
/// is what `flutter run` and the tests look like.
///
/// Posix explicitly, not the ambient context: the path is always a macOS one,
/// so a Windows host must not rejoin it with backslashes. That only shows up
/// when the tests run on the Windows CI runner.
String? macAppBundleFor(String executablePath) {
  final parts = p.posix.split(executablePath);
  final index =
      parts.lastIndexWhere((part) => part.toLowerCase().endsWith('.app'));
  if (index < 0) return null;
  return p.posix.joinAll(parts.sublist(0, index + 1));
}

/// Single-quotes [value] for `/bin/sh`. Bundle paths contain spaces and the
/// app name is user-visible, so nothing here may be pasted in raw.
String shQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The script that swaps a downloaded bundle over the running one.
///
/// It cannot run inside the app it replaces, so it waits for [pid] to go away
/// first and starts the new copy itself. The old bundle is moved aside rather
/// than deleted, and moved back if the copy fails, so a failed update leaves a
/// working app behind instead of no app at all.
String macSwapScript({
  required String stagedApp,
  required String targetApp,
  required int pid,
}) {
  final staged = shQuote(stagedApp);
  final target = shQuote(targetApp);
  return '''
#!/bin/sh
# Written by WSL Manager's updater. Safe to delete.
i=0
while [ \$i -lt 150 ] && kill -0 $pid 2>/dev/null; do
  sleep 0.2
  i=\$((i + 1))
done
# Still there after 30s: something is holding the app open, and replacing a
# bundle out from under a running copy would leave two of them.
if kill -0 $pid 2>/dev/null; then
  exit 1
fi
backup=$target.old
rm -rf "\$backup"
mv $target "\$backup" || exit 1
# ditto, not cp: it preserves the extended attributes the code signature
# lives in, and an unsigned bundle will not launch.
if ! /usr/bin/ditto $staged $target; then
  rm -rf $target
  mv "\$backup" $target
  exit 1
fi
rm -rf "\$backup"
/usr/bin/xattr -dr com.apple.quarantine $target 2>/dev/null
/usr/bin/open $target
''';
}

/// Launches a process that has to outlive the app.
typedef ProcessLauncher = Future<void> Function(
    String executable, List<String> arguments);

/// Finds, downloads and applies a new release on the builds that have no
/// store behind them.
class UpdateService {
  UpdateService({Dio? dio, Shell? shell})
      : _dio = dio ?? Dio(),
        _shell = shell ?? ProcessShell();

  final Dio _dio;
  final Shell _shell;

  /// Preference names. Auto-checking defaults to on: the whole point is that
  /// a direct install stops going stale on its own.
  static const String autoCheckPref = 'AutoUpdateCheck';
  static const String skippedVersionPref = 'SkippedUpdateVersion';
  static const String lastCheckPref = 'LastUpdateCheck';

  /// How long a release has to have been out before the app offers it. Kept
  /// from the old banner: a release that turns out broken is usually pulled
  /// or fixed within a day, and nobody should be auto-updated into that.
  static const Duration releaseSoak = Duration(days: 2);

  /// Inno's own flags. `/SILENT` shows the progress window but no wizard
  /// pages, `/CLOSEAPPLICATIONS` lets setup shut this app down instead of
  /// failing on a locked exe, and `/RESTARTAPPLICATIONS` brings it back
  /// afterwards. The UAC prompt stays — `installer/setup.iss` asks for admin —
  /// so this is unattended, not invisible.
  static const List<String> windowsInstallerArgs = <String>[
    '/SILENT',
    '/CLOSEAPPLICATIONS',
    '/RESTARTAPPLICATIONS',
    '/NORESTART',
  ];

  /// Test seam: forces [channel] regardless of the host.
  static UpdateChannel? channelOverride;

  /// Test seam for the bundle the macOS swap targets.
  static String? resolvedExecutableOverride;

  /// Detached on purpose. The installer and the swap script both outlive the
  /// app that starts them, so they must not go through [ProcessShell.start] —
  /// that adopts the child into the app's job object, which dies with the app.
  static ProcessLauncher launcher = _detachedLaunch;

  static Future<void> _detachedLaunch(
      String executable, List<String> arguments) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  static bool get autoCheckEnabled => prefs.getBool(autoCheckPref) ?? true;

  static Future<void> setAutoCheckEnabled(bool value) =>
      prefs.setBool(autoCheckPref, value);

  UpdateChannel get channel =>
      channelOverride ??
      updateChannelFor(
        windows: Platform.isWindows,
        macos: Platform.isMacOS,
        packaged: LicenseManager().isStorePackaged,
      );

  /// Whether this build may replace itself. False on the Store, where the
  /// Store does it, and on hosts with no installer to run.
  bool get canSelfUpdate => channel == UpdateChannel.direct;

  /// The newest release worth offering, or null when there is none.
  ///
  /// [minimumAge] is the soak above; a check the user asked for passes
  /// [Duration.zero] and [includeSkipped] so "check for updates" never
  /// answers "up to date" about a version it is deliberately hiding.
  Future<UpdateInfo?> check({
    String? version,
    Duration minimumAge = releaseSoak,
    bool includeSkipped = false,
  }) async {
    if (!canSelfUpdate) return null;

    final Object? data;
    try {
      final response = await _dio.get(updateUrl);
      data = response.data;
    } catch (_) {
      // Offline, rate-limited, GitHub down: not something to interrupt
      // anyone about.
      return null;
    }
    if (data is! List) return null;

    for (final entry in data) {
      if (entry is! Map) continue;
      if (entry['draft'] == true || entry['prerelease'] == true) continue;

      final tag = entry['tag_name'];
      if (tag is! String || tag.isEmpty) continue;

      if (compareVersions(tag, version ?? currentVersion) <= 0) return null;

      final publishedAt = entry['published_at'];
      if (publishedAt is String) {
        final published = DateTime.tryParse(publishedAt);
        if (published != null &&
            DateTime.now().toUtc().difference(published.toUtc()) < minimumAge) {
          return null;
        }
      }

      final normalized =
          tag.toLowerCase().startsWith('v') ? tag.substring(1) : tag;
      if (!includeSkipped &&
          prefs.getString(skippedVersionPref) == normalized) {
        return null;
      }

      final rawAssets = entry['assets'];
      final assets = <ReleaseAsset>[];
      if (rawAssets is List) {
        for (final asset in rawAssets) {
          final parsed = ReleaseAsset.fromJson(asset);
          if (parsed != null) assets.add(parsed);
        }
      }

      final htmlUrl = entry['html_url'];
      return UpdateInfo(
        version: normalized,
        releaseUrl: htmlUrl is String ? htmlUrl : releasesPageUrl,
        asset: selectUpdateAsset(assets, macos: Platform.isMacOS),
      );
    }
    return null;
  }

  /// The once-a-day check the app runs for itself at startup.
  ///
  /// Same shape as the motd check in `initRoot`: the date is written before
  /// the request so a failed check does not retry on every launch.
  Future<UpdateInfo?> checkOnStartup() async {
    if (!autoCheckEnabled || !canSelfUpdate) return null;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (prefs.getString(lastCheckPref) == today) return null;
    await prefs.setString(lastCheckPref, today);
    return check();
  }

  /// Stops [checkOnStartup] offering [info] again. A newer release still
  /// comes through — only this one version is hidden.
  Future<void> skip(UpdateInfo info) =>
      prefs.setString(skippedVersionPref, info.version);

  /// Downloads [info]'s asset into a per-version temp directory and returns
  /// it. Throws [UpdateException] when the file does not arrive whole.
  Future<File> download(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final asset = info.asset;
    if (asset == null) throw const UpdateException('update-failed-text');

    final directory = Directory(
        p.join(Directory.systemTemp.path, 'wsl-manager-update', info.version));
    await directory.create(recursive: true);
    // basename, not the raw name: the destination is built from a remote
    // string, and it may only ever name a file inside the directory above.
    final file = File(p.join(directory.path, p.basename(asset.name)));
    if (await file.exists()) await file.delete();

    try {
      await _dio.download(
        asset.url,
        file.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (onProgress == null) return;
          final expected = total > 0 ? total : asset.size;
          if (expected <= 0) return;
          onProgress((received / expected).clamp(0.0, 1.0));
        },
      );
    } catch (e) {
      if (await file.exists()) await file.delete();
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      throw const UpdateException('update-failed-text');
    }

    // A truncated download is worse than none: an installer only finds out
    // halfway through, with the old app already closed.
    if (asset.size > 0 && await file.length() != asset.size) {
      await file.delete();
      throw const UpdateException('update-failed-text');
    }
    return file;
  }

  /// Hands [file] to the platform's installer. Returns true once that has
  /// been started — the caller quits the app afterwards, because both paths
  /// need the running copy gone before they can finish.
  Future<bool> install(File file) async {
    if (Platform.isWindows) {
      await launcher(file.path, windowsInstallerArgs);
      return true;
    }
    if (Platform.isMacOS) return _installMacos(file);
    return false;
  }

  Future<bool> _installMacos(File file) async {
    // A disk image cannot be swapped in unattended without reimplementing
    // Finder's copy, so hand it over and let the user drag it across.
    if (file.path.toLowerCase().endsWith('.dmg')) {
      await launcher('/usr/bin/open', [file.path]);
      return true;
    }

    final target = macAppBundleFor(
        resolvedExecutableOverride ?? Platform.resolvedExecutable);
    if (target == null) return false;

    final stage = Directory(p.join(file.parent.path, 'staged'));
    if (await stage.exists()) await stage.delete(recursive: true);
    await stage.create(recursive: true);

    // ditto, not unzip: the code signature lives in extended attributes that
    // unzip drops, and an unsigned bundle will not launch.
    final extract =
        await _shell.run('/usr/bin/ditto', ['-x', '-k', file.path, stage.path]);
    if (extract.exitCode != 0) {
      throw const UpdateException('update-failed-extract-text');
    }

    String? staged;
    for (final entry in stage.listSync()) {
      if (entry is Directory && entry.path.toLowerCase().endsWith('.app')) {
        staged = entry.path;
        break;
      }
    }
    if (staged == null)
      throw const UpdateException('update-failed-extract-text');

    final script = File(p.join(file.parent.path, 'apply-update.sh'));
    await script.writeAsString(
        macSwapScript(stagedApp: staged, targetApp: target, pid: pid));
    await launcher('/bin/sh', [script.path]);
    return true;
  }
}
