// Host folders mounted inside an instance — the AI Workspace, a WSL distro
// or an Apple VM alike (bostrot/ai-tasks#79).
//
// Both backends already had a way to see the host: WSL automounts every
// fixed drive under /mnt, and an Apple VM has nothing at all. Neither gave the
// user a say over *which* folder shows up *where*, and a tool running inside
// the workspace that wants "the project" at a short, stable path had to be
// told a `/mnt/c/Users/…` one. This is that say: a list of host folder →
// guest path pairs the user edits, kept by the backend so it survives
// restarts.
//
// On WSL the list is the block this app owns in the distro's `/etc/fstab`
// (drvfs entries, mounted at start by WSL itself and right away by us). On
// the Apple backend it lives in the VM's config: `vmctl` attaches one
// virtio-fs device per folder and the daemon mounts them in the guest after
// each boot — see `macos/vmctl/Sources/VMCtlKit/Mounts.swift`.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_args.dart';
import 'package:wsl2distromanager/api/wsl_conf.dart';

/// One host folder shared into an instance.
class VolumeMount {
  /// Absolute path on the host — `C:\Users\…` for a WSL distro (also over
  /// remote WSL, where the host is the other machine), `/Users/…` for a VM.
  final String hostPath;

  /// Where it appears inside the instance.
  final String guestPath;

  final bool readOnly;

  const VolumeMount({
    required this.hostPath,
    required this.guestPath,
    this.readOnly = false,
  });

  factory VolumeMount.fromJson(Map<String, dynamic> json) => VolumeMount(
        hostPath: json['hostPath'] as String? ?? '',
        guestPath: json['guestPath'] as String? ?? '',
        readOnly: json['readOnly'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is VolumeMount &&
      other.hostPath == hostPath &&
      other.guestPath == guestPath &&
      other.readOnly == readOnly;

  @override
  int get hashCode => Object.hash(hostPath, guestPath, readOnly);

  @override
  String toString() =>
      'VolumeMount($hostPath -> $guestPath${readOnly ? ', ro' : ''})';
}

/// When a saved change reaches the instance.
enum MountApplyTiming {
  /// Mounted already (and kept for the next start).
  now,

  /// The instance picks it up when it next starts; a running one has to be
  /// restarted.
  nextStart,
}

class MountApplyResult {
  final MountApplyTiming timing;

  /// Whether the instance was running when the change was saved — with
  /// [MountApplyTiming.nextStart] that means "restart it".
  final bool instanceRunning;

  /// i18n keys (with their arguments already applied) for things worth
  /// telling the user that did not stop the save.
  final List<String> warnings;

  const MountApplyResult({
    required this.timing,
    required this.instanceRunning,
    this.warnings = const [],
  });
}

/// A mount operation that failed; [message] is an i18n key or the backend's
/// own text.
class VolumeMountException implements Exception {
  final String message;
  const VolumeMountException(this.message);

  @override
  String toString() => message;
}

/// Guest directories a folder must never be mounted over — the instance
/// would lose its own system underneath. Below them is fine.
const Set<String> reservedGuestMountPaths = {
  '/', '/bin', '/boot', '/dev', '/etc', '/lib', '/lib64', '/proc', '/root',
  '/run', '/sbin', '/sys', '/usr', '/var',
};

/// Where a macOS guest shows every share; a share there is named by its
/// last path component, so this is the one guest location with a space in
/// it that the rules below let through.
const String kMacOsSharedFilesRoot = '/Volumes/My Shared Files';

/// The i18n key describing what is wrong with [path] as a guest mount point,
/// or null when it is acceptable: absolute, plain characters (it reaches an
/// fstab line and a root shell — the same [isPlainDistroPath] rule every
/// in-distro path this app interpolates has to pass), no `.`/`..` segments,
/// not a system directory. The same rule `vmctl` enforces for a Linux guest,
/// so a path this accepts is one the helper accepts too; a macOS guest's
/// share is accepted as the path `vmctl mounts` reports it under.
String? validateGuestMountPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return 'mountsguestrequired-text';
  if (trimmed.startsWith('$kMacOsSharedFilesRoot/')) {
    final name = trimmed.substring(kMacOsSharedFilesRoot.length + 1);
    return isPlainDistroPath('/$name') && !name.contains('/') && !name.startsWith('.')
        ? null
        : 'mountsguestinvalid-text';
  }
  if (trimmed.length > 255 ||
      trimmed.endsWith('/') ||
      trimmed.contains('//') ||
      !isPlainDistroPath(trimmed)) {
    return 'mountsguestinvalid-text';
  }
  final segments = trimmed.split('/');
  if (segments.contains('.') || segments.contains('..')) {
    return 'mountsguestinvalid-text';
  }
  if (reservedGuestMountPaths.contains(trimmed)) {
    return 'mountsguestinvalid-text';
  }
  return null;
}

final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

/// The i18n key describing what is wrong with [path] as a host folder, or
/// null. [windowsStyle] says which host the instance's backend lives on —
/// a WSL distro driven from a Mac over SSH still takes `C:\…`.
///
/// Quotes and line breaks are refused outright: the path is single-quoted
/// into a mount command on WSL, and nothing legitimate contains them.
String? validateHostMountPath(String path, {required bool windowsStyle}) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return 'mountshostrequired-text';
  if (trimmed.contains("'") ||
      trimmed.contains('"') ||
      trimmed.contains('\n') ||
      trimmed.contains('\r')) {
    return 'mountshostinvalid-text';
  }
  final absolute =
      windowsStyle ? _windowsAbsolute.hasMatch(trimmed) : trimmed.startsWith('/');
  return absolute ? null : 'mountshostinvalid-text';
}

final RegExp _trailingSeparators = RegExp(r'[\\/]+$');
final RegExp _pathSeparator = RegExp(r'[\\/]');
final RegExp _notMountPointChar = RegExp(r'[^A-Za-z0-9._-]');
final RegExp _leadingDots = RegExp(r'^[.-]+');

/// The last component of [hostPath], reduced to the characters a mount
/// point (or a share name) may carry; `share` when nothing is left.
String mountNameFor(String hostPath) {
  final trimmed = hostPath.trim().replaceAll(_trailingSeparators, '');
  var name = trimmed.split(_pathSeparator).last;
  if (name.endsWith(':')) name = name.substring(0, name.length - 1);
  name = name.replaceAll(_notMountPointChar, '-').replaceAll(_leadingDots, '');
  return name.isEmpty ? 'share' : name;
}

/// A guest path to offer for [hostPath]: `/mnt/<folder name>` on a Linux
/// guest, or the share's place under [guestRoot] when the guest fixes where
/// shares go (a macOS guest).
String suggestGuestMountPath(String hostPath, {String? guestRoot}) =>
    '${guestRoot ?? '/mnt'}/${mountNameFor(hostPath)}';

/// The block this app owns inside a distro's `/etc/fstab`: everything
/// between two marker comments, one mount per line, the rest of the file
/// untouched.
class FstabMountBlock {
  static const String begin = '# >>> wslmanager mounts >>>';
  static const String end = '# <<< wslmanager mounts <<<';

  /// [fstab] with the block replaced by [lines] (or removed when empty).
  ///
  /// A begin marker whose end marker has gone missing (a hand edit) does
  /// not swallow the rest of the file: only the drvfs lines after it are
  /// taken as the block, everything else is kept — this is written back as
  /// root, and a user's own entries are not ours to lose.
  static String render(String fstab, List<String> lines) {
    final kept = <String>[];
    final pending = <String>[];
    var inBlock = false;
    var closed = true;
    for (final line in fstab.split('\n')) {
      if (line.trim() == begin) {
        inBlock = true;
        closed = false;
        continue;
      }
      if (line.trim() == end) {
        inBlock = false;
        closed = true;
        pending.clear();
        continue;
      }
      if (inBlock) {
        pending.add(line);
      } else {
        kept.add(line);
      }
    }
    if (!closed) {
      kept.addAll(pending.where((line) => !_isDrvfsLine(line)));
    }
    // Drop the trailing empty element a final newline leaves behind, so the
    // block is appended after the last real line rather than after a gap.
    while (kept.isNotEmpty && kept.last.trim().isEmpty) {
      kept.removeLast();
    }
    if (lines.isEmpty) {
      return kept.isEmpty ? '' : '${kept.join('\n')}\n';
    }
    return '${[...kept, begin, ...lines, end].join('\n')}\n';
  }

  static bool _isDrvfsLine(String line) =>
      line.trim().split(_whitespace).length >= 4 &&
      line.trim().split(_whitespace)[2] == 'drvfs';

  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _octalEscape = RegExp(r'\\([0-7]{3})');

  /// The lines inside the block, comments and blanks left out.
  static List<String> lines(String fstab) {
    final found = <String>[];
    var inBlock = false;
    for (final line in fstab.split('\n')) {
      final trimmed = line.trim();
      if (trimmed == begin) {
        inBlock = true;
        continue;
      }
      if (trimmed == end) break;
      if (inBlock && trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        found.add(trimmed);
      }
    }
    return found;
  }

  /// fstab fields are whitespace-separated, so whitespace inside one is
  /// written as an octal escape (`\040`), the way `mount` reads it.
  static String encodeField(String value) => value
      .replaceAll('\\', r'\134')
      .replaceAll(' ', r'\040')
      .replaceAll('\t', r'\011');

  static String decodeField(String value) => value.replaceAllMapped(
      _octalEscape, (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 8)));
}

/// The backend-specific half of [VolumeMountService].
abstract class VolumeMountDriver {
  /// Whether a saved change waits for the instance's next start.
  bool get appliesAtNextStart;

  /// Whether host paths are Windows paths.
  bool get windowsHostPaths;

  /// Where the guest puts every share when that is not the user's choice
  /// (a macOS guest: `/Volumes/My Shared Files`), else null. Known after
  /// [list].
  String? get guestRoot => null;

  /// What the guest itself reported about its shares the last time [list]
  /// asked, when that was a problem — the Apple daemon mounts them after
  /// boot and may fail to — else null.
  String? get guestProblem => null;

  Future<List<VolumeMount>> list(String instance);

  Future<MountApplyResult> apply(String instance, List<VolumeMount> mounts);
}

/// Persistent host-folder mounts of an instance, on whichever backend drives
/// it.
class VolumeMountService {
  final VolumeMountDriver _driver;

  /// Whether the instance lives on another machine, so a folder picker on
  /// this one would pick the wrong disk.
  final bool isRemote;

  VolumeMountService(VmBackend api)
      : _driver = _driverFor(api),
        isRemote = api.isRemote;

  /// A service over a driver of the test's choosing.
  VolumeMountService.withDriver(VolumeMountDriver driver,
      {this.isRemote = false})
      : _driver = driver;

  /// Whether [api] is a backend this service knows how to drive.
  static bool isSupported(VmBackend api) => api is WSLApi || api is AppleVmApi;

  static VolumeMountDriver _driverFor(VmBackend api) {
    if (api is AppleVmApi) return AppleVolumeMountDriver(api);
    if (api is WSLApi) return WslVolumeMountDriver(api);
    throw const VolumeMountException('mountsunsupported-text');
  }

  bool get appliesAtNextStart => _driver.appliesAtNextStart;
  bool get windowsHostPaths => _driver.windowsHostPaths;
  String? get guestProblem => _driver.guestProblem;

  /// A guest path to offer for [hostPath], where this guest puts shares.
  String suggestGuestPath(String hostPath) =>
      suggestGuestMountPath(hostPath, guestRoot: _driver.guestRoot);

  Future<List<VolumeMount>> list(String instance) => _driver.list(instance);

  /// Makes [mounts] the instance's whole list: anything missing from it is
  /// unmounted, anything new is added.
  Future<MountApplyResult> apply(
      String instance, List<VolumeMount> mounts) async {
    for (final mount in mounts) {
      final guestError = validateGuestMountPath(mount.guestPath);
      if (guestError != null) throw VolumeMountException(guestError);
      final hostError = validateHostMountPath(mount.hostPath,
          windowsStyle: windowsHostPaths);
      if (hostError != null) throw VolumeMountException(hostError);
    }
    final targets = mounts.map((m) => m.guestPath).toSet();
    if (targets.length != mounts.length) {
      throw const VolumeMountException('mountsguestduplicate-text');
    }
    return await _driver.apply(instance, mounts);
  }
}

/// WSL: drvfs entries in the distro's `/etc/fstab`, which WSL mounts at
/// every start (`[automount] mountFsTab`, on by default), plus an immediate
/// `mount` so the folder is there without a restart.
class WslVolumeMountDriver implements VolumeMountDriver {
  final WSLApi api;

  WslVolumeMountDriver(this.api);

  @override
  bool get appliesAtNextStart => false;

  @override
  bool get windowsHostPaths => true;

  /// The user picks where a folder goes, and WSL mounts it itself at start.
  @override
  String? get guestRoot => null;

  @override
  String? get guestProblem => null;

  static const String fstabPath = '/etc/fstab';

  /// fstab keeps the drive path with forward slashes, which drvfs accepts
  /// and which keeps backslashes — an escape character to `mount` — out of
  /// the file.
  static String fstabSource(String hostPath) =>
      FstabMountBlock.encodeField(hostPath.trim().replaceAll('\\', '/'));

  static String displayHostPath(String source) =>
      FstabMountBlock.decodeField(source).replaceAll('/', '\\');

  /// drvfs options for [mount]: `metadata` so Linux permissions work on the
  /// folder, [owner] (`uid=`/`gid=` of the distro's default user, so the
  /// files belong to them the way the automounted drives do; without them
  /// drvfs hands everything to root), `ro` when asked. The same list goes
  /// into fstab and into the immediate `mount`, so the folder mounted now
  /// is the one WSL mounts at the next start.
  static String mountOptions(VolumeMount mount, {List<String> owner = const []}) =>
      ['metadata', ...owner, if (mount.readOnly) 'ro'].join(',');

  static String fstabLine(VolumeMount mount, {List<String> owner = const []}) =>
      '${fstabSource(mount.hostPath)} '
      '${FstabMountBlock.encodeField(mount.guestPath)} drvfs '
      'defaults,${mountOptions(mount, owner: owner)} 0 0';

  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _accountName = RegExp(r'^[A-Za-z_][A-Za-z0-9._-]*$');

  static VolumeMount? parseLine(String line) {
    final fields = line.split(_whitespace);
    if (fields.length < 4 || fields[2] != 'drvfs') return null;
    final options = fields[3].split(',');
    return VolumeMount(
      hostPath: displayHostPath(fields[0]),
      guestPath: FstabMountBlock.decodeField(fields[1]),
      readOnly: options.contains('ro'),
    );
  }

  Future<String> _readFstab(String instance) async {
    final text = await api.readInstanceFile(instance, fstabPath);
    if (text == null) throw const VolumeMountException('mountsunreachable-text');
    return text;
  }

  @override
  Future<List<VolumeMount>> list(String instance) async {
    final fstab = await _readFstab(instance);
    return FstabMountBlock.lines(fstab)
        .map(parseLine)
        .whereType<VolumeMount>()
        .toList();
  }

  /// `uid=`/`gid=` of the distro's default user, or nothing when they
  /// cannot be found (or are root's, which is what no option means anyway)
  /// — the mount still works then, only owned by root.
  Future<List<String>> _ownerOptions(String instance) async {
    try {
      final user = (await api.getDefaultUser(instance)).trim();
      if (!_accountName.hasMatch(user)) return const [];
      final out = await api.runInInstance(
          instance, "id -u '$user' && id -g '$user'",
          timeout: const Duration(seconds: 30));
      if (!out.ok) return const [];
      final parts = out.stdout.trim().split(_whitespace);
      if (parts.length < 2) return const [];
      final uid = int.tryParse(parts[0]);
      final gid = int.tryParse(parts[1]);
      if (uid == null || gid == null || (uid == 0 && gid == 0)) return const [];
      return ['uid=$uid', 'gid=$gid'];
    } catch (_) {
      return const [];
    }
  }

  /// The shell that mounts [mounts] right now: unmounts what was dropped or
  /// changed, mounts what is new. Every path is single-quoted; the
  /// validation upstream keeps quotes out of them.
  ///
  /// Exits non-zero when any step failed — a busy folder that would not
  /// unmount, a mount that did not take — so the caller can say so instead
  /// of reporting a change the distro does not show.
  static String applyScript(
    List<VolumeMount> previous,
    List<VolumeMount> mounts, {
    List<String> owner = const [],
  }) {
    final desired = {for (final m in mounts) m.guestPath: m};
    final lines = <String>['fail=0'];
    for (final old in previous) {
      final now = desired[old.guestPath];
      if (now == null || now != old) {
        lines.add("if mountpoint -q '${old.guestPath}'; then "
            "umount '${old.guestPath}' || fail=1; fi");
      }
    }
    for (final mount in mounts) {
      final source = mount.hostPath.trim().replaceAll('\\', '/');
      lines.add("mkdir -p '${mount.guestPath}'");
      lines.add("mountpoint -q '${mount.guestPath}' || "
          "mount -t drvfs '$source' '${mount.guestPath}' "
          "-o '${mountOptions(mount, owner: owner)}' || fail=1");
    }
    lines.add(r'exit $fail');
    return lines.join('\n');
  }

  /// Whether the distro's wsl.conf turns fstab processing off, read
  /// section-aware through the same parser the settings dialog uses.
  static bool fstabDisabled(String? wslConf) {
    if (wslConf == null) return false;
    final value = WslConfFile.parse(wslConf).get('automount', 'mountFsTab');
    return value?.trim().toLowerCase() == 'false';
  }

  @override
  Future<MountApplyResult> apply(
      String instance, List<VolumeMount> mounts) async {
    // Three wsl.exe launches that need nothing from each other.
    final results = await Future.wait<Object?>([
      _readFstab(instance),
      mounts.isEmpty ? Future.value(const <String>[]) : _ownerOptions(instance),
      api.readInstanceFile(instance, '/etc/wsl.conf'),
    ]);
    final fstab = results[0] as String;
    final owner = results[1] as List<String>;
    final wslConf = results[2] as String?;
    final previous = FstabMountBlock.lines(fstab)
        .map(parseLine)
        .whereType<VolumeMount>()
        .toList();
    final rendered = FstabMountBlock.render(
        fstab, [for (final m in mounts) fstabLine(m, owner: owner)]);
    if (!await api.writeInstanceFile(instance, fstabPath, rendered)) {
      throw const VolumeMountException('mountswritefailed-text');
    }

    final warnings = <String>[];
    if (previous.isNotEmpty || mounts.isNotEmpty) {
      final out = await api.runInInstance(
          instance, applyScript(previous, mounts, owner: owner),
          timeout: const Duration(minutes: 2));
      if (!out.ok) {
        warnings.add(out.text.isEmpty ? 'mountsapplyfailed-text' : out.text);
      }
    }
    if (fstabDisabled(wslConf)) {
      warnings.add('mountsfstabdisabled-text');
    }
    return MountApplyResult(
        timing: MountApplyTiming.now,
        instanceRunning: true,
        warnings: warnings);
  }
}

/// Apple VMs: the list in the VM's config, edited through `vmctl mount` /
/// `vmctl unmount`. Virtualization.framework cannot attach a device to a
/// running VM, so a change waits for the next start.
class AppleVolumeMountDriver implements VolumeMountDriver {
  final AppleVmApi api;

  AppleVolumeMountDriver(this.api);

  @override
  bool get appliesAtNextStart => true;

  @override
  bool get windowsHostPaths => false;

  String? _guestRoot;
  String? _guestProblem;

  @override
  String? get guestRoot => _guestRoot;

  @override
  String? get guestProblem => _guestProblem;

  Future<Map<String, dynamic>> _run(List<String> args) async {
    final ProcessResult result;
    try {
      result = await api.shell.run(
        api.helperPath(),
        ['--store', api.storeDir, ...args],
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (e) {
      throw VolumeMountException(
          'Could not run the vmctl helper (${api.helperPath()}): ${e.message}');
    }
    final stdout = result.stdout.toString();
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw VolumeMountException(stderr.isNotEmpty
          ? stderr
          : 'vmctl ${args.join(' ')} failed with exit code ${result.exitCode}');
    }
    try {
      final decoded = json.decode(stdout.trim().isEmpty ? '{}' : stdout);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // Fall through.
    }
    throw VolumeMountException('vmctl returned unreadable output: $stdout');
  }

  static List<VolumeMount> _mountsOf(Map<String, dynamic> json) =>
      (json['mounts'] as List? ?? [])
          .whereType<Map>()
          .map((m) => VolumeMount.fromJson(Map<String, dynamic>.from(m)))
          .toList();

  /// What the helper reported about the guest's own state, for the user:
  /// a daemon that could not reach the guest, or shares it could not mount.
  static String? _problemOf(Map<String, dynamic> json) {
    final guest = json['guest'];
    if (guest is! Map) return null;
    final state = guest['state'];
    if (state != 'failed' && state != 'partial' && state != 'outdated') {
      return null;
    }
    final error = guest['error']?.toString() ?? '';
    return error.isNotEmpty ? error : state.toString();
  }

  @override
  Future<List<VolumeMount>> list(String instance) async {
    final json = await _run(['mounts', '--name', instance]);
    _guestRoot = json['os'] == 'macos' ? kMacOsSharedFilesRoot : null;
    _guestProblem = _problemOf(json);
    return _mountsOf(json);
  }

  @override
  Future<MountApplyResult> apply(
      String instance, List<VolumeMount> mounts) async {
    final current = await _run(['mounts', '--name', instance]);
    final before = _mountsOf(current);
    var running = current['running'] == true;
    final desired = {for (final m in mounts) m.guestPath: m};
    for (final old in before) {
      if (!desired.containsKey(old.guestPath)) {
        final out = await _run(
            ['unmount', '--name', instance, '--guest', old.guestPath]);
        running = out['running'] == true;
      }
    }
    final existing = {for (final m in before) m.guestPath: m};
    for (final mount in mounts) {
      // Host paths here are the Mac's, so POSIX rules whatever the host the
      // code runs on — the default context would turn `/a/` into `\a` under
      // a Windows test run and report every row as changed.
      final hostPath = p.posix.normalize(mount.hostPath.trim());
      if (existing[mount.guestPath] == VolumeMount(
          hostPath: hostPath,
          guestPath: mount.guestPath,
          readOnly: mount.readOnly)) {
        continue;
      }
      final out = await _run([
        'mount',
        '--name',
        instance,
        '--host',
        hostPath,
        '--guest',
        mount.guestPath,
        if (mount.readOnly) '--read-only',
      ]);
      running = out['running'] == true;
    }
    return MountApplyResult(
        timing: MountApplyTiming.nextStart, instanceRunning: running);
  }
}
