// A section-aware, comment-preserving model of a distro's `/etc/wsl.conf`.
//
// ## Why this file exists
//
// The old writer (`assets/scripts/settings.bash`, deleted with this file's
// first use) templated a `sed` expression per key and ran it inside the
// distro as root. Three separate defects fell out of that one design, all
// recorded in doc/audit/wsl-docs/wslconf-keys.md:
//
// * **CC-1** — both the `[[ =~ ]]` existence test and the `s///g` searched the
//   whole file, so toggling `[interop] enabled` also rewrote
//   `[automount] enabled`. Two documented sections share the key name.
// * **CC-2** — the value was interpolated into `s/KEY[ ]*=[ ]*.*/KEY = VALUE/g`
//   verbatim, so any `/` closed the substitution early. `[automount] root`'s
//   documented default `/mnt/` is itself a failing value.
// * **CC-7** — the same substitution landed inside `echo -e "…"` in the
//   add-a-section branch, where a `"`, a backtick or a `$(…)` executed as
//   root inside the distro.
//
// Reading the file, mutating a model and writing the whole file back makes
// those one fix rather than three: nothing is templated into a shell, so
// nothing in a value can be interpreted. [WSLApi.writeWSLConf] carries the
// payload base64-encoded for the same reason.
//
// The model itself now lives in `ini_config.dart`, shared with `.wslconfig`
// (P05-02) — this file is the `wsl.conf` dialect of it.

import 'package:wsl2distromanager/api/ini_config.dart';

export 'package:wsl2distromanager/api/ini_config.dart' show IniSchema;

/// The documented keys of each `wsl.conf` section, in their canonical
/// spelling, from `microsoftdocs/wsl@8842def` (`wsl-config.md`).
const Map<String, List<String>> kWslConfKeys = <String, List<String>>{
  'automount': <String>['enabled', 'mountFsTab', 'root', 'options'],
  'boot': <String>['systemd', 'command', 'protectBinfmt'],
  'gpu': <String>['enabled'],
  'interop': <String>['enabled', 'appendWindowsPath'],
  'network': <String>['generateHosts', 'generateResolvConf', 'hostname'],
  'time': <String>['useWindowsTimezone'],
  'user': <String>['default'],
};

/// `wsl.conf`: `#` and `;` both comment, values are verbatim, LF endings.
///
/// Unlike `.wslconfig` there is no escaping here — [WSLApi.writeWSLConf] never
/// puts a value through a shell, and WSL's `wsl.conf` parser takes the rest of
/// the line as written.
const IniSchema kWslConfSchema = IniSchema(
  keys: kWslConfKeys,
  commentPrefixes: <String>['#', ';'],
  defaultNewline: '\n',
);

/// [section] in its documented spelling, or as written when it is not a
/// section this app knows.
String canonicalWslConfSection(String section) =>
    kWslConfSchema.canonicalSection(section);

/// [key] in its documented spelling within [section], or as written when the
/// section or the key is unknown.
String canonicalWslConfKey(String section, String key) =>
    kWslConfSchema.canonicalKey(section, key);

/// A parsed `/etc/wsl.conf`.
class WslConfFile extends IniConfigFile {
  WslConfFile.parse(String text) : super.parse(text, kWslConfSchema);

  /// An empty file, which is what a distro without `/etc/wsl.conf` reads as.
  WslConfFile.empty() : super.parse('', kWslConfSchema);
}
