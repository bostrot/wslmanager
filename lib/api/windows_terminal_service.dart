import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';

/// One entry this app contributes to Windows Terminal's profile list.
///
/// Two shapes, because a fragment can do two things: [WindowsTerminalProfile]
/// with a [name] creates a profile, one with [updates] set layers settings
/// onto a profile that already exists — which is how the twin Windows
/// Terminal generates for the same distro is taken back out of the menu.
class WindowsTerminalProfile {
  const WindowsTerminalProfile.create({
    required this.name,
    required this.guid,
    required this.commandline,
    this.icon,
  })  : updates = null,
        hidden = false;

  const WindowsTerminalProfile.hide(this.updates)
      : name = null,
        guid = null,
        commandline = null,
        icon = null,
        hidden = true;

  final String? name;
  final String? guid;
  final String? commandline;
  final String? icon;

  /// GUID of the profile this entry modifies, null when it creates one.
  final String? updates;
  final bool hidden;

  Map<String, Object?> toJson() {
    if (updates != null) {
      return {'updates': updates, 'hidden': hidden};
    }
    return {
      'guid': guid,
      'name': name,
      'commandline': commandline,
      // Windows Terminal's own WSL profiles start in the Windows directory,
      // which drops the shell in /mnt/c. `--cd ~` in the command line is what
      // moves that to the user's home, so this must not fight it.
      'startingDirectory': null,
      if (icon != null) 'icon': icon,
    };
  }
}

/// Puts the instances this app manages into the Windows Terminal dropdown
/// (bostrot/wsl2-distro-manager#239).
///
/// Windows Terminal reads every `.json` in its `Fragments\<app>` folder at
/// startup and merges what it finds into the user's settings, so an app can
/// contribute profiles without ever editing `settings.json` — the user's own
/// file is never touched, and turning the feature off is one file delete.
/// The per-user folder lives under `LOCALAPPDATA`, so nothing here elevates.
///
/// Windows Terminal also generates a profile of its own for every distro in
/// the registry. Left alone that would put two entries in the menu for one
/// distro, so each created profile is paired with an `updates` entry that
/// hides the generated twin by its GUID. Both GUIDs are version 5 UUIDs over
/// the distro name, computed exactly the way Windows Terminal computes them,
/// which is what makes the pairing possible without reading its settings.
class WindowsTerminalService {
  WindowsTerminalService({
    VmBackend? backend,
    String? fragmentDirectory,
    String? iconPath,
    bool? hostIsWindows,
  })  : _backend = backend,
        _fragmentDirectory = fragmentDirectory,
        _iconPath = iconPath,
        _hostIsWindows = hostIsWindows;

  /// The one the app runs with, so the Settings section and the app-start
  /// sync cannot end up with a timer each.
  static final WindowsTerminalService instance = WindowsTerminalService();

  final VmBackend? _backend;
  final String? _fragmentDirectory;
  final String? _iconPath;

  /// Stands in for the host check while testing. Without it the only thing
  /// worth pinning — what lands in the fragment file — would be skipped on
  /// every machine the suite actually runs on.
  final bool? _hostIsWindows;

  VmBackend get backend => _backend ?? vmBackend();

  static const String prefEnabled = 'WindowsTerminalProfiles';
  static const String prefHideGenerated = 'WindowsTerminalHideGenerated';

  /// The folder name under `Fragments\`, and also the application name the
  /// profile GUIDs are derived from. Changing it orphans every profile this
  /// app has already written, so it is a constant rather than a setting.
  static const String appName = 'WSL Manager';

  /// Windows Terminal reads every `.json` in the folder; one file is enough.
  static const String fragmentFileName = 'wsl-manager.json';

  /// Namespace for profiles contributed by plugins and fragments.
  static const String fragmentNamespace =
      'f65ddb7e-706b-4499-8a50-40313caf510a';

  /// Namespace Windows Terminal uses for the profiles it generates itself,
  /// including the one per registered WSL distro.
  static const String generatedNamespace =
      '2bde4a90-d05f-401c-9492-e40884ead1d8';

  /// Where Windows Terminal looks for a single user's fragments. A per-user
  /// install has no business writing the machine-wide `ProgramData` copy,
  /// and this one needs no administrator rights.
  static String defaultFragmentDirectory() {
    final local = Platform.environment['LOCALAPPDATA'] ??
        '${Platform.environment['USERPROFILE'] ?? Directory.current.path}'
            r'\AppData\Local';
    return '$local\\Microsoft\\Windows Terminal\\Fragments\\$appName';
  }

  String get fragmentDirectory =>
      _fragmentDirectory ?? defaultFragmentDirectory();

  String get fragmentPath =>
      '$fragmentDirectory${Platform.pathSeparator}$fragmentFileName';

  /// The app's own logo as it sits next to the executable in a Flutter
  /// Windows build. Null when it is not there — a fragment that names an
  /// icon Windows Terminal cannot open shows a broken one, so a missing
  /// file means no `icon` key at all.
  static String? defaultIconPath() {
    if (!Platform.isWindows) return null;
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir\\data\\flutter_assets\\assets\\logo_wsl_manager.png';
  }

  String? get iconPath {
    final path = _iconPath ?? defaultIconPath();
    if (path == null || path.isEmpty) return null;
    return File(path).existsSync() ? path : null;
  }

  /// Only a Windows host has a Windows Terminal, and only instances that run
  /// on this machine can be launched from it: a remote WSL host's distros
  /// are reachable from *that* machine, and `wsl -d name` here would open a
  /// distro that does not exist.
  bool get isSupported =>
      (_hostIsWindows ?? Platform.isWindows) && !backend.isRemote;

  bool get enabled => (prefs.getBool(prefEnabled) ?? false) && isSupported;

  /// Whether the profile Windows Terminal generates for the same distro is
  /// hidden. On by default: two menu entries per distro is the thing this
  /// feature is supposed to avoid.
  bool get hideGenerated => prefs.getBool(prefHideGenerated) ?? true;

  Future<void> setEnabled(bool value) => prefs.setBool(prefEnabled, value);

  Future<void> setHideGenerated(bool value) =>
      prefs.setBool(prefHideGenerated, value);

  /// The command line one profile runs. `--cd ~` is the difference between
  /// landing in the user's home and landing in `/mnt/c/...`, which is where
  /// a bare `wsl -d name` from a Windows Terminal profile starts.
  static String commandlineFor(String instance) =>
      'wsl.exe -d ${_quote(instance)} --cd ~';

  /// Distro names may carry spaces, and Windows Terminal hands the command
  /// line to the shell as written. Double quotes cannot appear in a distro
  /// name, so quoting the argument is enough.
  static String _quote(String value) =>
      value.contains(' ') ? '"$value"' : value;

  /// GUID of the profile this app contributes for [instance].
  static String profileGuid(String instance) =>
      '{${_uuidV5(_uuidV5(fragmentNamespace, appName), instance)}}';

  /// GUID of the profile Windows Terminal generates for the WSL distro
  /// [instance]. No application name takes part: the generated profiles hang
  /// straight off Windows Terminal's own namespace.
  static String generatedProfileGuid(String instance) =>
      '{${_uuidV5(generatedNamespace, instance)}}';

  /// The profiles [instances] turn into, in the order they are written.
  List<WindowsTerminalProfile> profilesFor(List<String> instances) {
    final icon = iconPath;
    final seen = <String>{};
    final profiles = <WindowsTerminalProfile>[];
    for (final instance in instances) {
      final name = instance.trim();
      // A name that differs only by surrounding space would hash to a
      // different GUID but read as the same entry in the menu.
      if (name.isEmpty || !seen.add(name)) continue;
      profiles.add(WindowsTerminalProfile.create(
        name: name,
        guid: profileGuid(name),
        commandline: commandlineFor(name),
        icon: icon,
      ));
      if (hideGenerated) {
        profiles.add(WindowsTerminalProfile.hide(generatedProfileGuid(name)));
      }
    }
    return profiles;
  }

  /// The fragment file's contents for [instances]. Pretty-printed on
  /// purpose: it lands in a folder people do open when they wonder where a
  /// profile came from.
  String buildFragment(List<String> instances) {
    final profiles = profilesFor(instances);
    return '${const JsonEncoder.withIndent('  ').convert({
          'profiles': [for (final p in profiles) p.toJson()],
        })}\n';
  }

  /// Read the fragment back, or '' when this app has not written one yet.
  Future<String> readFragment() async {
    final file = File(fragmentPath);
    if (!await file.exists()) return '';
    return const Utf8Decoder(allowMalformed: true)
        .convert(await file.readAsBytes());
  }

  /// Write the profiles for [instances], or remove the file when there are
  /// none. Returns what actually happened, so the UI can say "nothing
  /// changed" rather than claim a write it did not do.
  Future<WindowsTerminalResult> apply(List<String> instances) async {
    if (!isSupported) {
      return WindowsTerminalResult(
        profiles: const [],
        skipped: backend.isRemote
            ? WindowsTerminalSkip.remote
            : WindowsTerminalSkip.unsupported,
      );
    }
    final profiles = profilesFor(instances);
    final current = await readFragment();

    if (profiles.isEmpty) {
      if (current.isEmpty) {
        return const WindowsTerminalResult(
            profiles: [], skipped: WindowsTerminalSkip.unchanged);
      }
      await _delete();
      return const WindowsTerminalResult.written([]);
    }

    final desired = buildFragment(instances);
    if (desired == current) {
      return WindowsTerminalResult(
          profiles: profiles, skipped: WindowsTerminalSkip.unchanged);
    }
    // Windows Terminal parses the file as UTF-8; a BOM-less UTF-8 write is
    // what `writeAsString` does, which is what it wants.
    await Directory(fragmentDirectory).create(recursive: true);
    await File(fragmentPath).writeAsString(desired);
    return WindowsTerminalResult.written(profiles);
  }

  Future<void> _delete() async {
    final file = File(fragmentPath);
    if (await file.exists()) await file.delete();
    // Leave the folder behind only when something else put a file in it.
    try {
      final dir = Directory(fragmentDirectory);
      if (await dir.exists() && await dir.list().isEmpty) await dir.delete();
    } catch (e, stack) {
      logDebug(e, stack, 'windows_terminal_service');
    }
  }

  /// Ask the backend what it manages and write that out.
  Future<WindowsTerminalResult> sync({List<String>? instances}) async {
    if (!isSupported) {
      return WindowsTerminalResult(
        profiles: const [],
        skipped: backend.isRemote
            ? WindowsTerminalSkip.remote
            : WindowsTerminalSkip.unsupported,
      );
    }
    final names = instances ?? await _listInstances();
    return apply(names);
  }

  /// Take this app's profiles back out of Windows Terminal.
  Future<WindowsTerminalResult> clear() => apply(const []);

  Future<List<String>> _listInstances() async {
    final showDocker = prefs.getBool('showDocker') ?? false;
    final list = await backend.list(showDocker);
    // `wsl --list` answers with a placeholder rather than an empty list when
    // WSL itself is missing. A profile for it would run `wsl -d
    // wslNotInstalled` and fail, so it is dropped here the way every other
    // reader of this list drops it.
    return [
      for (final name in list.all)
        if (name != 'wslNotInstalled') name
    ];
  }

  Timer? _timer;
  String _lastFragment = '';
  bool _ticking = false;

  /// How often the instance list is re-read. Nothing here prompts or
  /// elevates and the file is only rewritten when the rendered JSON changes,
  /// so the cost of a tick that finds nothing new is one `wsl -l -v`.
  static const Duration autoSyncInterval = Duration(minutes: 2);

  /// Follow the instance list for as long as the app is open, so a distro
  /// created now is in the menu the next time Windows Terminal starts.
  void startAutoSync() {
    if (_timer != null || !enabled) return;
    unawaited(_tick());
    _timer = Timer.periodic(autoSyncInterval, (_) => unawaited(_tick()));
  }

  void stopAutoSync() {
    _timer?.cancel();
    _timer = null;
    _lastFragment = '';
  }

  Future<void> _tick() async {
    if (!enabled) {
      stopAutoSync();
      return;
    }
    // A slow `wsl -l -v` can still be running when the next tick fires;
    // two of them would write the same file at the same time, and Windows
    // Terminal could read it half-written.
    if (_ticking) return;
    _ticking = true;
    try {
      final instances = await _listInstances();
      final fragment = buildFragment(instances);
      // Nothing was created or removed since the last tick: the fragment
      // file is not even read.
      if (fragment == _lastFragment) return;
      await apply(instances);
      _lastFragment = fragment;
    } catch (e, stack) {
      // _lastFragment is deliberately left alone: a write that failed —
      // the folder was locked, the disk was full — must be tried again on
      // the next tick, or the menu stays stale until the app restarts.
      logError(e, stack, 'windows_terminal_service');
    } finally {
      _ticking = false;
    }
  }

  /// Version 5 UUID over [namespace] and [name], in the encoding Windows
  /// Terminal hashes with: the name as BOM-less UTF-16LE, which is how a
  /// profile GUID computed here lands on the same value Windows Terminal
  /// computed for the profile it generated.
  static String _uuidV5(String namespace, String name) {
    final bytes = <int>[
      ..._guidBytes(namespace),
      ..._utf16le(name),
    ];
    final hash = _sha1(bytes);
    final out = hash.sublist(0, 16);
    out[6] = (out[6] & 0x0f) | 0x50; // version 5
    out[8] = (out[8] & 0x3f) | 0x80; // RFC 4122 variant
    String hex(int from, int to) => out
        .sublist(from, to)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-'
        '${hex(10, 16)}';
  }

  /// The 16 bytes of a GUID string, big-endian throughout — the layout
  /// RFC 4122 hashes, not the mixed-endian one Windows stores in memory.
  static List<int> _guidBytes(String guid) {
    final hex = guid.replaceAll(RegExp(r'[{}\-]'), '');
    if (hex.length != 32) {
      throw ArgumentError.value(guid, 'guid', 'not a GUID');
    }
    return [
      for (var i = 0; i < 32; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
  }

  /// UTF-16LE without a byte order mark. Characters outside the basic plane
  /// are written as the surrogate pair Dart already stores them as.
  static List<int> _utf16le(String value) {
    final bytes = <int>[];
    for (final unit in value.codeUnits) {
      bytes.add(unit & 0xff);
      bytes.add((unit >> 8) & 0xff);
    }
    return bytes;
  }

  /// SHA-1 of [message]. Vendored rather than pulled in as a dependency:
  /// this is the only hash the app needs, and it is needed for exactly one
  /// thing — matching Windows Terminal's profile GUIDs.
  static List<int> _sha1(List<int> message) {
    var h0 = 0x67452301;
    var h1 = 0xEFCDAB89;
    var h2 = 0x98BADCFE;
    var h3 = 0x10325476;
    var h4 = 0xC3D2E1F0;

    final padded = <int>[...message, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    final bitLength = message.length * 8;
    for (var i = 7; i >= 0; i--) {
      padded.add((bitLength >> (8 * i)) & 0xff);
    }

    final w = List<int>.filled(80, 0);
    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        final j = chunk + i * 4;
        w[i] = (padded[j] << 24) |
            (padded[j + 1] << 16) |
            (padded[j + 2] << 8) |
            padded[j + 3];
      }
      for (var i = 16; i < 80; i++) {
        w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }

      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var i = 0; i < 80; i++) {
        int f, k;
        if (i < 20) {
          f = (b & c) | (~b & 0xffffffff & d);
          k = 0x5A827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ED9EBA1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8F1BBCDC;
        } else {
          f = b ^ c ^ d;
          k = 0xCA62C1D6;
        }
        final temp = (_rotl(a, 5) + f + e + k + w[i]) & 0xffffffff;
        e = d;
        d = c;
        c = _rotl(b, 30);
        b = a;
        a = temp;
      }

      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
    }

    return [
      for (final h in [h0, h1, h2, h3, h4])
        for (var i = 3; i >= 0; i--) (h >> (8 * i)) & 0xff,
    ];
  }

  static int _rotl(int value, int bits) =>
      ((value << bits) | ((value & 0xffffffff) >> (32 - bits))) & 0xffffffff;
}

/// Why a sync wrote nothing. `unchanged` is not a failure: the file already
/// says what it should.
enum WindowsTerminalSkip { unsupported, remote, unchanged }

/// What one sync did.
class WindowsTerminalResult {
  const WindowsTerminalResult({required this.profiles, required this.skipped});

  const WindowsTerminalResult.written(this.profiles) : skipped = null;

  final List<WindowsTerminalProfile> profiles;

  /// Null when the fragment file was rewritten or removed.
  final WindowsTerminalSkip? skipped;

  bool get changed => skipped == null;

  /// The profiles that show up in the menu — the `updates` entries only take
  /// one back out.
  List<String> get names => [
        for (final p in profiles)
          if (p.name != null) p.name!
      ];
}
