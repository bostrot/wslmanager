// Picking root filesystems for the CPU architecture a distribution will
// actually run on.
//
// WSL 2 does not emulate. On a Windows-on-ARM machine every distribution is
// arm64, so the x86-64 root filesystems the catalogue used to consist of
// installed fine and then produced an instance in which nothing at all could
// start (bostrot/wsl2-distro-manager#229). Two places choose an image and both
// used to choose the Intel one unconditionally: the curated catalogue in
// `images.json`, and the architecture list of a Docker manifest.
//
// `images.json` therefore carries a URL per architecture:
//
//     "Ubuntu 24.04": {
//       "x64":   "https://.../noble-server-cloudimg-amd64-root.tar.xz",
//       "arm64": "https://.../noble-server-cloudimg-arm64-root.tar.xz"
//     }
//
// A distro that publishes only one architecture lists only that one and is
// left out of the list on the other — an entry that cannot run is worse than
// an entry that is missing, because the user only finds out after a download
// of several hundred megabytes and a shell that answers "exec format error".
//
// The old flat `"name": "url"` form still parses, because the copy the CDN
// serves is uploaded by hand and is a release behind the repo's own: its
// entries are matched by the architecture named in the URL, which every
// mirror in the catalogue spells out.

import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

// The two families and the machine's own are already described, with the
// Windows-on-ARM emulation case, for the cloud deploy that has to compare a
// server's architecture with this one. One definition of "what is this
// machine" is enough.
import 'package:wsl2distromanager/api/cloud/cloud_deploy_service.dart'
    show cloudLocalArchitecture;
import 'package:wsl2distromanager/components/helpers.dart' show prefs;

/// 64-bit ARM, as [rootfsTokenFamily] reports it.
const String rootfsArmFamily = 'arm';

/// Intel/AMD 64-bit, as [rootfsTokenFamily] reports it.
const String rootfsX86Family = 'x86';

const Set<String> _armTokens = {
  'arm',
  'arm64',
  'arm64v8',
  'aarch64',
  'armv8',
};

const Set<String> _x86Tokens = {
  'x86',
  'x64',
  'amd64',
};

/// The architecture family named somewhere in [value] — a catalogue key such
/// as `arm64`, or a whole image URL: [rootfsArmFamily], [rootfsX86Family], or
/// '' when it names neither.
///
/// Read word by word, so `.../dist-arm64v8/trixie/...` and
/// `AlmaLinux-10.2_x64_20260526.0.wsl` are both recognised while a host or
/// release name that merely contains the letters is not.
String rootfsTokenFamily(String value) {
  for (final token in value.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
    if (_armTokens.contains(token)) return rootfsArmFamily;
    if (_x86Tokens.contains(token)) return rootfsX86Family;
  }
  return '';
}

/// The architecture the next distribution has to be built for, or '' when
/// this cannot be known and the Intel entries are the better guess.
///
/// Off Windows there is no WSL to install into, and with a remote host the
/// machine that will run the distribution is somebody else's — an arm64 one
/// there is possible but nothing local says so, and the overwhelming majority
/// of Windows machines are x86-64. [isWindows], [remote], [abi] and
/// [environment] are parameters so a test can describe a machine other than
/// the one running it.
String rootfsHostArchitecture({
  bool? isWindows,
  bool? remote,
  Abi? abi,
  Map<String, String>? environment,
}) {
  if (remote ?? _remoteWslConfigured()) return '';
  if (!(isWindows ?? Platform.isWindows)) return '';
  return cloudLocalArchitecture(abi: abi, environment: environment);
}

/// Whether the app drives WSL on another machine, the same way `WSLApi`
/// decides it. Read defensively: the catalogue is also parsed by tooling that
/// never initialised the preferences.
bool _remoteWslConfigured() {
  try {
    return (prefs.getBool('UseRemoteWSL') ?? false) &&
        (prefs.getString('RemoteWSLTarget')?.trim() ?? '').isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// One download URL per distribution out of a parsed `images.json`, keeping
/// only what can run on [family] and preserving the catalogue's order.
///
/// An entry is either a map of architecture to URL, or a bare URL whose
/// architecture is read off the URL itself. A bare URL that names no
/// architecture is kept for every family: a custom catalogue is free to say
/// nothing about architecture, and dropping such an entry would empty the
/// list of somebody who has no arm64 machine in sight.
Map<String, String> rootfsLinksFor(Map<dynamic, dynamic> raw, String family) {
  final links = <String, String>{};
  raw.forEach((key, value) {
    final name = key.toString();
    if (value is Map) {
      final url = _perArchitectureUrl(value, family);
      if (url != null) links[name] = url;
      return;
    }
    if (value is String && value.isNotEmpty) {
      final named = rootfsTokenFamily(value);
      if (named.isEmpty || family.isEmpty || named == family) {
        links[name] = value;
      }
    }
  });
  return links;
}

/// The URL for [family] in one entry's architecture map, or null when the
/// distribution publishes nothing for it.
String? _perArchitectureUrl(Map<dynamic, dynamic> entry, String family) {
  String? forFamily(String wanted) {
    for (final candidate in entry.entries) {
      if (rootfsTokenFamily(candidate.key.toString()) != wanted) continue;
      final url = candidate.value;
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }

  // An unknown machine gets the Intel image, which is what all but a handful
  // of Windows installations want.
  if (family.isEmpty) return forFamily(rootfsX86Family);
  return forFamily(family);
}
