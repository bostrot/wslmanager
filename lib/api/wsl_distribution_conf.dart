// A section-aware, comment-preserving model of a distro's
// `/etc/wsl-distribution.conf` — the third config file WSL reads, and the one
// the app had no idea existed.
//
// ## Why this file exists
//
// doc/audit/wsl-docs/features.md F-8 is the largest *net-new* surface the WSL
// documentation audit found, and the whole of it hangs off this file.
// `build-custom-distro.md` describes a complete packaging path — a `.wsl`
// file installed with `wsl --install --from-file` — whose behaviour on first
// launch is governed entirely by `/etc/wsl-distribution.conf`:
//
// * **`[oobe]`** runs a script the first time an interactive shell opens, and
//   declares which UID the distro starts as. This is the documented way an
//   imported distro gets a non-root default user at all, and therefore the
//   root cause behind wslconf-keys CC-6 / issue #268: `--import` produces a
//   distro with **no launcher executable**, so `<distro> config
//   --default-user` cannot work for it (`basic-commands.md:152`).
// * **`[shortcut]`** is why an `--import`ed distro has no Start-menu entry.
// * **`[windowsterminal]`** is why it has no Windows Terminal profile.
//
// `oobe.defaultName` is also load-bearing for the double-click install
// experience: `build-custom-distro.md:191` states a `.wsl` file without one
// does not install correctly when opened in File Explorer.
//
// ## Why it is a schema rather than a parser
//
// The model itself is `ini_config.dart`, already shared by `wsl.conf`
// (P05-03) and `.wslconfig` (P05-02). This file is the third dialect of it, so
// comment preservation, case-insensitive key matching, in-place edits and the
// remove-a-key path all come for free and are already covered by those two
// files' tests. A distribution maintainer hand-writes this file; a packaging
// screen that reformats it on every save is its own bug report.

import 'package:wsl2distromanager/api/ini_config.dart';

export 'package:wsl2distromanager/api/ini_config.dart' show IniSchema;

/// Where WSL reads this file from inside the distro.
const String kWslDistributionConfPath = '/etc/wsl-distribution.conf';

/// The documented keys of each section, in their canonical spelling, from
/// `microsoftdocs/wsl@8842def` (`build-custom-distro.md`).
///
/// `profileTemplate` is spelled with a leading lower-case `p` here because
/// that is what the reference table uses; the sample file three paragraphs
/// above it writes `ProfileTemplate`. The doc contradicts itself, WSL's parser
/// is case-insensitive, and so is [IniSchema] — a file using either spelling
/// reaches the widget that renders it.
const Map<String, List<String>> kWslDistributionConfKeys =
    <String, List<String>>{
  'oobe': <String>['command', 'defaultUid', 'defaultName'],
  'shortcut': <String>['enabled', 'icon'],
  'windowsterminal': <String>['enabled', 'profileTemplate'],
};

/// `wsl-distribution.conf`: a Linux file, parsed by the same INI reader as
/// `wsl.conf`, with values taken verbatim and no escaping of any kind.
///
/// Note that [IniSchema.documentedSection] is **not** usable on this dialect:
/// `enabled` is a documented key of two different sections. Nothing here calls
/// it — that method exists for `.wslconfig`, whose key names happen to be
/// unique — and every read and write below names its section explicitly.
const IniSchema kWslDistributionConfSchema = IniSchema(
  keys: kWslDistributionConfKeys,
  commentPrefixes: <String>['#', ';'],
  defaultNewline: '\n',
);

/// What WSL does when a boolean key is absent, from the reference table.
///
/// Both documented booleans default to **on**, which is the opposite of what a
/// switch rendered from a missing key would show — the same trap that made
/// `wsl.conf` CC-3 a finding. The editor renders these rather than `false`.
const Map<String, bool> kWslDistributionConfBoolDefaults = <String, bool>{
  'shortcut-enabled': true,
  'windowsterminal-enabled': true,
};

/// A parsed `/etc/wsl-distribution.conf`.
class WslDistributionConfFile extends IniConfigFile {
  WslDistributionConfFile.parse(String text)
      : super.parse(text, kWslDistributionConfSchema);

  /// An empty file, which is what every distro this app has ever created
  /// reads as: `wsl --import` writes no distribution config at all.
  WslDistributionConfFile.empty() : super.parse('', kWslDistributionConfSchema);
}

/// [section] in its documented spelling, or as written when unknown.
String canonicalDistributionConfSection(String section) =>
    kWslDistributionConfSchema.canonicalSection(section);

/// [key] in its documented spelling within [section], or as written.
String canonicalDistributionConfKey(String section, String key) =>
    kWslDistributionConfSchema.canonicalKey(section, key);
