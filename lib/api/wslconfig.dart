// A section-aware, comment-preserving model of `%UserProfile%\.wslconfig`.
//
// ## Why this file exists
//
// This replaces `WSLApi.readConfig` / `setConfig` / `writeConfig`
// (`wsl.dart:530-646` before P05-02), which between them carried seven
// defects recorded in doc/audit/wsl-docs/wslconfig-keys.md. Each of them is a
// property of the *design* — a flat `key → value` map plus a `replaceAll` over
// the whole file — rather than a bug that could be patched in place:
//
// * **CC-2** — `value.replaceAll(' ', '')` on read. `kernelCommandLine` and any
//   path under `C:\Program Files\…` came back mangled, and the mangled form was
//   written back on the next Save.
// * **CC-3** — no section tracking at all, on either side. A user's hand-added
//   `[experimental]` key was re-emitted into `[wsl2]`, where WSL 2.6.3.0
//   **rejects** it and boots with the setting off (runtime R-4). Silent.
// * **CC-4** — a case-sensitive regex against a case-insensitive format. A
//   lower-case `swapfile =` line was never matched, so Save appended a second
//   `swapFile =` line; WSL resolves duplicates to the **first** occurrence
//   (R-8), so the user's edit did nothing, on that boot or any later one.
// * **CC-5** — comment lines parsed as keys on read, and the write-side regex
//   was unanchored, so a commented-out `#memory=8GB` absorbed the write and
//   stayed commented out.
// * **CC-10 / R-6** — path values written with single backslashes. WSL answers
//   `Ungültiges Escapezeichen` and **discards the line**, which made every
//   value `kernelModules`' file picker could produce a dead line.
// * **CC-11** — three branches and no fourth: a key could be added and changed
//   but never removed, so "unset — use the documented default" had nowhere to
//   be written. That is what blocked the tri-state toggles (P05-04).
//
// The model itself is [IniConfigFile], shared with `/etc/wsl.conf`; this file
// is the `.wslconfig` dialect of it — `#` comments only, escaped backslashes in
// path values, and the section each documented key belongs in.

import 'package:wsl2distromanager/api/ini_config.dart';

export 'package:wsl2distromanager/api/ini_config.dart' show IniSchema;

/// The `[wsl2]` reference-table keys, in their documented spelling
/// (`microsoftdocs/wsl@8842def`, `wsl-config.md`).
const List<String> kWslConfigWsl2Keys = <String>[
  'kernel',
  'kernelModules',
  'memory',
  'processors',
  'localhostForwarding',
  'kernelCommandLine',
  'safeMode',
  'swap',
  'swapFile',
  'guiApplications',
  'debugConsole',
  'nestedVirtualization',
  'vmIdleTimeout',
  'maxCrashDumpCount',
  'dnsProxy',
  'networkingMode',
  'firewall',
  'dnsTunneling',
  'autoProxy',
  'defaultVhdSize',
];

/// The `[experimental]` reference-table keys.
///
/// The section is not cosmetic: WSL 2.6.3.0 rejects every one of these under
/// `[wsl2]` and boots with the key unset, saying so only on a stderr line the
/// app never used to read (runtime R-4).
const List<String> kWslConfigExperimentalKeys = <String>[
  'autoMemoryReclaim',
  'sparseVhd',
  'bestEffortDnsParsing',
  'dnsTunnelingIpAddress',
  'initialAutoProxyTimeout',
  'ignoredPorts',
  'hostAddressLoopback',
];

const Map<String, List<String>> kWslConfigKeys = <String, List<String>>{
  'wsl2': kWslConfigWsl2Keys,
  'experimental': kWslConfigExperimentalKeys,
};

/// The three keys documented as `path`, which are the three that need escaped
/// backslashes (`wsl-config.md:248`, measured in runtime R-6).
const List<String> kWslConfigPathKeys = <String>[
  'kernel',
  'kernelModules',
  'swapFile',
];

/// What WSL does when a boolean key is absent.
///
/// Seven of these are `true`, and the toggles used to render every one of them
/// off on the ordinary case of a machine with no `.wslconfig` — a user reading
/// the screen concluded the opposite of the truth (audit CC-1). A key with no
/// entry here has no documented boolean default.
const Map<String, bool> kWslConfigBoolDefaults = <String, bool>{
  'localhostForwarding': true,
  'guiApplications': true,
  'nestedVirtualization': true,
  'dnsProxy': true,
  'firewall': true,
  'dnsTunneling': true,
  'autoProxy': true,
  'safeMode': false,
  'debugConsole': false,
  'sparseVhd': false,
  'bestEffortDnsParsing': false,
  'hostAddressLoopback': false,
};

bool _isPathKey(String key) => kWslConfigPathKeys
    .any((path) => path.toLowerCase() == key.trim().toLowerCase());

/// A Windows path as `.wslconfig` requires it: every `\` doubled.
///
/// `swapFile=C:\Temp\wslswap.vhdx` is `wsl: Ungültiges Escapezeichen: „T“` and
/// the line is thrown away; `C:\\Temp\\wslswap.vhdx` parses (runtime R-6).
String escapeWslConfigPath(String value) => value.replaceAll('\\', '\\\\');

/// Inverse of [escapeWslConfigPath], leniently.
///
/// A lone backslash — the form the old writer produced and WSL rejects — is
/// passed through rather than eaten, so the value the user sees is the value
/// they typed. Writing it back then escapes it properly, which repairs the
/// line as a side effect of the next Save.
String unescapeWslConfigPath(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    if (value[i] == '\\' && i + 1 < value.length && value[i + 1] == '\\') {
      buffer.write('\\');
      i++;
      continue;
    }
    buffer.write(value[i]);
  }
  return buffer.toString();
}

String _encode(String section, String key, String value) =>
    _isPathKey(key) ? escapeWslConfigPath(value) : value;

String _decode(String section, String key, String value) =>
    _isPathKey(key) ? unescapeWslConfigPath(value) : value;

/// `.wslconfig`: `#` comments only, escaped backslashes in path values, and the
/// file's own line endings preserved.
///
/// `;` is deliberately **not** a comment prefix. WSL 2.6.3.0 answers a `;` line
/// with `wsl: Ungültiger Schlüsselname` (runtime R-7), so `.wslconfig` is
/// INI-*like*, not INI, and "helpfully" supporting `;` would hide a real error
/// from the user. A `;`-prefixed line still survives untouched — it fails the
/// key pattern in [IniConfigFile] and stays an opaque raw line.
const IniSchema kWslConfigSchema = IniSchema(
  keys: kWslConfigKeys,
  commentPrefixes: <String>['#'],
  defaultNewline: '\r\n',
  preserveNewline: true,
  encodeValue: _encode,
  decodeValue: _decode,
);

/// Apply the settings screen's edits to [config], writing **only** what
/// changed, and report how many keys moved.
///
/// Three properties come out of diffing against [loaded] rather than
/// re-emitting every non-empty key, which is what `saveSettings` used to do:
///
/// * A key the screen never touched keeps its line, its spelling, its section
///   and its position — including the `[experimental]` keys the old loop
///   relocated into `[wsl2]`, where WSL rejects them silently (R-4).
/// * An **emptied** value removes the key, so the documented default applies
///   again. `setConfig` had no delete branch at all, which is why clearing a
///   field used to do nothing (CC-11) and why the tri-state toggles could not
///   ship before the engine did.
/// * A path key is escaped exactly once, on the way out, by [WslConfigFile]'s
///   own codec — so the file picker stops producing lines WSL throws away
///   (CC-10 / R-6).
///
/// [loaded] is updated in place to match, so a second Save in the same session
/// is a no-op rather than a rewrite.
int applyWslConfigEdits(
  WslConfigFile config,
  Map<String, String> loaded,
  Map<String, String> edited,
) {
  var changed = 0;
  edited.forEach((key, raw) {
    final value = raw.trim();
    if (value == (loaded[key] ?? '')) return;

    changed++;
    if (value.isEmpty) {
      config.remove(config.sectionFor(key), key);
      loaded.remove(key);
    } else {
      config.set(config.sectionFor(key), key, value);
      loaded[key] = value;
    }
  });
  return changed;
}

/// A parsed `%UserProfile%\.wslconfig`.
class WslConfigFile extends IniConfigFile {
  WslConfigFile.parse(String text) : super.parse(text, kWslConfigSchema);

  /// An empty file, which is what a machine with no `.wslconfig` reads as.
  WslConfigFile.empty() : super.parse('', kWslConfigSchema);

  /// Where a write of [key] should land: the section it is already in, else the
  /// section the documentation puts it in, else `[wsl2]`.
  ///
  /// Checking the file first is what stops a key a user filed by hand from
  /// being duplicated into a second section; falling back to the documented
  /// table is what stops the seven `[experimental]` keys from being re-emitted
  /// into `[wsl2]`, where WSL ignores them (R-4).
  String sectionFor(String key) =>
      sectionOf(key) ?? schema.documentedSection(key) ?? 'wsl2';

  /// Every documented key in the file, flattened by canonical key name.
  ///
  /// The settings screen keys its controllers by key name alone — no key name
  /// is shared between `[wsl2]` and `[experimental]`, so this is lossless for
  /// the keys the screen renders. Keys in sections the app does not know are
  /// left out entirely rather than shown under a control that would write them
  /// back somewhere else.
  Map<String, String> flatten() {
    final flat = <String, String>{};
    toMap().forEach((section, entries) {
      if (!kWslConfigKeys.keys
          .any((known) => known.toLowerCase() == section.toLowerCase())) {
        return;
      }
      entries.forEach((key, value) => flat[key] = value);
    });
    return flat;
  }
}
