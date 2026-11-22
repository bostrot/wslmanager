// What the installed `wsl.exe` can actually do, asked once and cached.
//
// ## Why this file exists
//
// Before P05-08 neither `wsl --version` nor `wsl --status` was invoked
// anywhere in `lib/` (doc/audit/wsl-docs/cli-flags.md CC-1), with three
// consequences the audit calls the enabling finding of the whole phase:
//
// * Every version floor the audit records — Windows 11, WSL 0.66.2+, 2.0.9+,
//   2.5+ — was unenforceable. `hostAddressLoopback` and `safeMode` rendered
//   identically on a machine that could honour neither.
// * `systemd.md:30` documents the canonical probe for the Store build:
//   inbox WSL *rejects* `--version`, the Store build answers it. Without that
//   the app could not warn that `--manage`, `--mount --name` or the
//   `[experimental]` keys are unavailable.
// * "Which WSL do I have" was not answerable anywhere in the UI.
//
// The second half of this file is the part a version number cannot replace.
// wsl.exe reports refused keys, an unsupported host CPU and clamped values on
// **stderr, with exit code 0** (runtime R-1, R-4, R-9). A gate built purely on
// a version string invents an answer where WSL is already giving a real one, so
// [WslCapabilities.warnings] carries WSL's own words through to the user.

import 'package:wsl2distromanager/api/wsl.dart';

/// A `wsl.exe` invocation whose stderr matters as much as its exit code.
class WslOutput {
  final int exitCode;
  final String stdout;
  final String stderr;

  const WslOutput(this.exitCode, this.stdout, this.stderr);

  bool get ok => exitCode == 0;

  /// stdout when there is any, else stderr — for the many wsl.exe verbs that
  /// report success on one channel and failure on the other.
  String get text => stdout.trim().isNotEmpty ? stdout.trim() : stderr.trim();
}

/// `df` output for one distro, in bytes.
class WslDiskUsage {
  /// Size of the filesystem inside the distro.
  final int totalBytes;

  /// How much of it is in use. This is the number an `ext4.vhdx` file length
  /// cannot give: a VHD never shrinks on its own, so allocated ≫ used is the
  /// normal state and the gap is exactly what `--set-sparse` reclaims.
  final int usedBytes;

  final int availableBytes;

  const WslDiskUsage({
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
  });

  double get usedFraction => totalBytes <= 0 ? 0 : usedBytes / totalBytes;

  /// Parse `df -k` output from inside the system distro.
  ///
  /// `-k` rather than `-h`: a fixed unit is one less thing to parse, and the
  /// display formatting belongs to the UI. Returns null when no data row is
  /// present, which is what a distro that would not start looks like.
  static WslDiskUsage? parseDf(String output) {
    for (final rawLine in output.split('\n')) {
      final fields = rawLine.trim().split(RegExp(r'\s+'));
      if (fields.length < 4) continue;
      final total = int.tryParse(fields[1]);
      final used = int.tryParse(fields[2]);
      final available = int.tryParse(fields[3]);
      if (total == null || used == null || available == null) continue;
      return WslDiskUsage(
        totalBytes: total * 1024,
        usedBytes: used * 1024,
        availableBytes: available * 1024,
      );
    }
    return null;
  }
}

final RegExp _versionToken = RegExp(r'(\d+(?:\.\d+)+)');

/// The installed WSL, as far as `wsl.exe` will say.
class WslCapabilities {
  /// e.g. `2.6.3.0`. Null when `wsl --version` did not answer — which on its
  /// own is the signal that this is the inbox build, not that WSL is missing.
  final String? version;

  final String? kernelVersion;

  /// `wsl --version` answered at all. Inbox WSL rejects the flag
  /// (`systemd.md:30`), so this is the documented Store-build probe.
  final bool isStoreWsl;

  /// True when `wsl.exe` could not be run at all.
  final bool wslMissing;

  final String? defaultDistro;
  final int? defaultVersion;

  /// Everything wsl.exe said on stderr while being asked the two questions
  /// above. Kept verbatim, because the messages that matter most — a refused
  /// `.wslconfig` key, an unsupported host CPU — arrive here with exit code 0
  /// and no other signal (runtime R-1, R-4).
  final List<String> warnings;

  const WslCapabilities({
    this.version,
    this.kernelVersion,
    this.isStoreWsl = false,
    this.wslMissing = false,
    this.defaultDistro,
    this.defaultVersion,
    this.warnings = const <String>[],
  });

  /// Nothing known yet — what every gate sees before the first probe returns.
  static const WslCapabilities unknown = WslCapabilities();

  List<int> get _parts => (version ?? '')
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();

  /// Whether the installed WSL is at least [major].[minor].[patch].
  ///
  /// False when the version is unknown: a gate that cannot prove the feature
  /// is there must not offer it, because the fallback path is always safe and
  /// the native path is not always present.
  bool atLeast(int major, [int minor = 0, int patch = 0]) {
    if (version == null) return false;
    final parts = _parts;
    final want = <int>[major, minor, patch];
    for (var i = 0; i < want.length; i++) {
      final have = i < parts.length ? parts[i] : 0;
      if (have != want[i]) return have > want[i];
    }
    return true;
  }

  /// The warnings that actually concern `.wslconfig`.
  ///
  /// The two probes behind [warnings] are `wsl --version` and `wsl --status`,
  /// and neither is about the config file — but WSL prefixes its `.wslconfig`
  /// complaints to the output of *every* invocation, so a line that names the
  /// file is the only kind the Settings panel may present as being about it
  /// (audit ST-07). The file name is not localized; the sentence around it is.
  List<String> get configWarnings => warnings
      .where((w) => w.toLowerCase().contains('wslconfig'))
      .toList(growable: false);

  /// Everything else the two probes printed.
  List<String> get otherWarnings => warnings
      .where((w) => !w.toLowerCase().contains('wslconfig'))
      .toList(growable: false);

  /// `wsl --manage` and all four of its options arrived in WSL 2.5
  /// (`disk-space.md:48-58`).
  bool get supportsManage => atLeast(2, 5);

  /// `.wsl` packages: `--install --from-file`, `/etc/wsl-distribution.conf`
  /// and `--export --format`.
  ///
  /// `build-custom-distro.md:16` states the floor in so many words — "This
  /// guide only applies to WSL release 2.4.4 and higher". Below it, a `.wsl`
  /// file is just a tar with an extension nothing recognises, the distribution
  /// config is never read, and `--from-file` is an invalid option.
  bool get supportsWslPackages => atLeast(2, 4, 4);

  /// Build from the two probes' raw output.
  factory WslCapabilities.parse(WslOutput version, WslOutput status) {
    final warnings = <String>[];
    for (final output in <WslOutput>[version, status]) {
      for (final line in output.stderr.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) warnings.add(trimmed);
      }
    }

    // A negative exit code is [WSLApi.runVerb]'s "the process did not run" —
    // wsl.exe absent, or a timeout. Distinct from a non-zero exit code, which
    // is wsl.exe rejecting the flag.
    final missing = version.exitCode < 0 && status.exitCode < 0;

    return WslCapabilities(
      version: version.ok ? _labelledVersion(version.stdout) : null,
      kernelVersion: version.ok ? _kernelVersion(version.stdout) : null,
      isStoreWsl: version.ok,
      wslMissing: missing,
      defaultDistro: _field(status.stdout, const <String>['default distri']),
      defaultVersion: int.tryParse(
          _field(status.stdout, const <String>['default version']) ?? ''),
      warnings: warnings,
    );
  }

  /// The WSL version line of `wsl --version`.
  ///
  /// Matched by shape rather than by the English label, because the output is
  /// localised — this machine answers in German (runtime, *The machine under
  /// test*). `wslg` and `kernel` are excluded explicitly: both lines contain
  /// "wsl" and both carry a version number of their own.
  static String? _labelledVersion(String output) {
    for (final line in output.split('\n')) {
      final lower = line.toLowerCase();
      if (!lower.contains('wsl')) continue;
      if (lower.contains('wslg') || lower.contains('kernel')) continue;
      final match = _versionToken.firstMatch(line);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// The kernel version, whole. Unlike [version] it is never compared against
  /// anything, so the trailing `-1` of `6.6.87.2-1` is kept rather than parsed
  /// away — this field exists to be shown, and a truncated kernel version is a
  /// wrong one.
  static String? _kernelVersion(String output) =>
      _field(output, const <String>['kernel']);

  /// Value of the first `Label: value` line whose label starts with one of
  /// [prefixes], case-insensitively.
  static String? _field(String output, List<String> prefixes) {
    for (final line in output.split('\n')) {
      final separator = line.indexOf(':');
      if (separator < 0) continue;
      final label = line.substring(0, separator).trim().toLowerCase();
      if (!prefixes.any(label.startsWith)) continue;
      final value = line.substring(separator + 1).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }
}

/// Runs the two probes once and remembers the answer.
///
/// One instance for the app, replaceable in tests. The probes are cheap but not
/// free — `--version` on a cold WSL takes a second or two — and every gate in
/// the UI asks the same question, so caching is what keeps a settings screen
/// from launching a process per rebuild.
class WslCapabilityService {
  static WslCapabilityService instance = WslCapabilityService();

  final WSLApi Function() _apiBuilder;

  WslCapabilityService({WSLApi Function()? apiBuilder})
      : _apiBuilder = apiBuilder ?? (() => WSLApi());

  WslCapabilities? _cached;
  Future<WslCapabilities>? _inFlight;

  /// The last answer, or null if nothing has asked yet. Synchronous, for
  /// `build()` methods that must not await.
  WslCapabilities? get cached => _cached;

  /// Ask, or hand back the cached answer. Concurrent callers share one probe.
  Future<WslCapabilities> load({bool force = false}) {
    if (!force && _cached != null) return Future.value(_cached);
    if (!force && _inFlight != null) return _inFlight!;

    final api = _apiBuilder();
    final future = () async {
      final version = await api.versionInfo();
      final status = await api.statusInfo();
      final capabilities = WslCapabilities.parse(version, status);
      _cached = capabilities;
      _inFlight = null;
      return capabilities;
    }();
    _inFlight = future;
    return future;
  }

  /// Drop the cache — used by tests and by the "check again" affordance next
  /// to the version display.
  void reset() {
    _cached = null;
    _inFlight = null;
  }
}
