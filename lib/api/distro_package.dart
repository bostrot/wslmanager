// Building and installing `.wsl` distribution packages.
//
// ## Why this file exists
//
// doc/audit/wsl-docs/features.md F-8, the one **L** in the Phase 05 ordered
// implementation list (P05-24), and the largest net-new surface the whole
// audit found. `build-custom-distro.md` describes a complete, modern
// distribution path that this app implemented no part of:
//
//   rootfs → tar (gzip) → rename to `.wsl` → `wsl --install --from-file`
//
// with `/etc/wsl-distribution.conf` inside the archive deciding what happens
// on first launch. The app creates distros from `.tar.gz` URLs, Docker images
// and `.vhdx` files, always through `wsl --import`, and the docs are explicit
// about what `--import` does *not* produce: no launcher executable — which is
// why `<distro> config --default-user` cannot work for an imported distro
// (`basic-commands.md:152`, the root cause behind wslconf-keys CC-6 and issue
// #268) — no Start-menu shortcut, and no Windows Terminal profile.
//
// ## Why packaging is "configure, then export", not tar surgery
//
// The obvious-looking alternative is to export a tar and splice
// `/etc/wsl-distribution.conf` into it afterwards. It is the wrong trade:
// a distro export is routinely several gigabytes, appending to a tar means
// either loading it into memory or hand-editing its trailing zero blocks, and
// duplicate-entry precedence on extraction is unspecified for WSL's own
// extractor.
//
// So the config is edited **inside the distro**, with the same editor pattern
// as `wsl.conf`, and packaging is then just an export of a distro that already
// contains what it needs. Nothing is injected behind the user's back, the file
// is inspectable with `cat` afterwards, and the archive is produced entirely
// by wsl.exe. The only cost is that the source distro carries the
// distribution config too, which is harmless: WSL reads it on *install*, and
// an already-registered distro is never installed again.
//
// ## Version floor
//
// `build-custom-distro.md:16` — "This guide only applies to WSL release 2.4.4
// and higher". Below that floor `--from-file` is an invalid option, `--format`
// does not exist, and `/etc/wsl-distribution.conf` is never read, so a `.wsl`
// built there is a tar with an extension nothing recognises. Everything here
// is gated on [WslCapabilities.supportsWslPackages] rather than allowed to
// fail at the point of use with wsl.exe's untranslated error.

import 'dart:io';

import 'package:wsl2distromanager/api/safe_paths.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_capabilities.dart';
import 'package:wsl2distromanager/api/wsl_distribution_conf.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Where a distro's OOBE script conventionally lives — the path the sample
/// `wsl-distribution.conf` in `build-custom-distro.md` points `oobe.command`
/// at.
const String kDefaultOobeScriptPath = '/etc/oobe.sh';

/// The UID `build-custom-distro.md`'s recommendations pair with an
/// account-creating `oobe.command`: "both `uid` and `oobe.defaultUid` should
/// be set to `1000`".
const String kDefaultOobeUid = '1000';

/// Export formats `wsl --export --format` accepts, of which only the two tar
/// ones make a `.wsl`.
const List<String> kWslPackageFormats = <String>['tar.gz', 'tar'];

/// The sample OOBE script from `build-custom-distro.md`, verbatim apart from
/// [uid] being substituted into `DEFAULT_UID`.
///
/// Offered rather than required. An `oobe.command` pointing at a script that
/// is not there returns non-zero, and the doc is explicit about what that
/// costs: "If that command returns non zero, it is considered unsuccessful,
/// and the user won't be able to open a shell." A distro packaged that way is
/// bricked on first launch, so the packaging screen offers to write a script
/// that is known to work.
String sampleOobeScript({String uid = kDefaultOobeUid}) => '''#!/bin/bash

set -ue

DEFAULT_GROUPS='adm,cdrom,sudo,dip,plugdev'
DEFAULT_UID='$uid'

echo 'Please create a default UNIX user account. The username does not need to match your Windows username.'
echo 'For more information visit: https://aka.ms/wslusers'

if getent passwd "\$DEFAULT_UID" > /dev/null ; then
  echo 'User account already exists, skipping creation'
  exit 0
fi

while true; do

  # Prompt from the username
  read -p 'Enter new UNIX username: ' username

  # Create the user
  if /usr/sbin/adduser --uid "\$DEFAULT_UID" --quiet --gecos ''  "\$username"; then

    if /usr/sbin/usermod "\$username" -aG "\$DEFAULT_GROUPS"; then
      break
    else
      /usr/sbin/deluser "\$username"
    fi
  fi
done
''';

/// How much a packaging problem matters.
enum PackageIssueLevel {
  /// The `.wsl` will not install, or will install unusable.
  error,

  /// The `.wsl` works, but not the way the documentation recommends.
  warning,
}

/// One thing wrong with a distro about to be packaged, as an i18n key.
class PackageIssue {
  final PackageIssueLevel level;

  /// i18n key of the sentence shown to the user.
  final String messageKey;

  /// Positional arguments for [messageKey], if it takes any.
  final List<String> args;

  const PackageIssue(this.level, this.messageKey,
      {this.args = const <String>[]});

  bool get isError => level == PackageIssueLevel.error;

  @override
  String toString() => '${level.name}:$messageKey';

  @override
  bool operator ==(Object other) =>
      other is PackageIssue &&
      other.level == level &&
      other.messageKey == messageKey;

  @override
  int get hashCode => Object.hash(level, messageKey);
}

/// What a live probe of the distro found on disk.
///
/// Separate from the config so [packageIssues] stays a pure function of facts
/// and can be tested without a distro.
class DistroPackageInspection {
  /// `/etc/wsl.conf` exists. `build-custom-distro.md`'s recommendations ask
  /// for both config files in a packaged distro.
  final bool hasWslConf;

  /// `/etc/resolv.conf` exists. The recommendations say not to ship it: WSL
  /// generates it, and a stale one baked into the rootfs breaks DNS on every
  /// machine the package is installed on.
  final bool hasResolvConf;

  /// `oobe.command` resolves to something executable inside the distro. Null
  /// when no command is configured, so there was nothing to check.
  final bool? oobeCommandExecutable;

  const DistroPackageInspection({
    this.hasWslConf = false,
    this.hasResolvConf = false,
    this.oobeCommandExecutable,
  });
}

/// Everything wrong with packaging [conf] as a `.wsl`, worst first.
///
/// Every rule here is a line of `build-custom-distro.md`, not a preference:
/// the "Configuration file recommendations" section plus the `oobe.defaultName`
/// requirement for the double-click install path at `:191`.
List<PackageIssue> packageIssues(
    WslDistributionConfFile conf, DistroPackageInspection inspection) {
  final issues = <PackageIssue>[];

  final defaultName = conf.get('oobe', 'defaultName');
  if (defaultName == null || defaultName.trim().isEmpty) {
    // `:191`: "A `oobe.defaultName` entry is required in the
    // /etc/wsl-distribution.conf file for this double-click experience to
    // function properly." `--install --from-file --name X` still works, so
    // this is an error for the package, not for the command line.
    issues.add(const PackageIssue(
        PackageIssueLevel.error, 'packagenodefaultname-text'));
  }

  final command = conf.get('oobe', 'command')?.trim() ?? '';
  if (command.isEmpty) {
    issues.add(
        const PackageIssue(PackageIssueLevel.warning, 'packagenooobe-text'));
  } else {
    if (inspection.oobeCommandExecutable == false) {
      issues.add(PackageIssue(
          PackageIssueLevel.error, 'packageoobenotexecutable-text',
          args: <String>[command]));
    }
    final uid = conf.get('oobe', 'defaultUid')?.trim() ?? '';
    if (uid.isEmpty) {
      issues.add(
          const PackageIssue(PackageIssueLevel.warning, 'packagenouid-text'));
    }
  }

  final icon = conf.get('shortcut', 'icon')?.trim() ?? '';
  if (icon.isNotEmpty && !icon.toLowerCase().endsWith('.ico')) {
    // "Must be in .ico format with a maximum size of 10MB."
    issues.add(const PackageIssue(
        PackageIssueLevel.warning, 'packageiconformat-text'));
  }

  if (!inspection.hasWslConf) {
    issues.add(
        const PackageIssue(PackageIssueLevel.warning, 'packagenowslconf-text'));
  }
  if (inspection.hasResolvConf) {
    issues.add(const PackageIssue(
        PackageIssueLevel.warning, 'packageresolvconf-text'));
  }

  issues.sort((a, b) => a.level.index.compareTo(b.level.index));
  return issues;
}

/// Result of a packaging run.
class PackageResult {
  final bool ok;

  /// Where the `.wsl` landed, when it did.
  final String? path;

  /// Size of the produced file, for the "done" message.
  final int? bytes;

  /// wsl.exe's own words when it failed.
  final String? error;

  const PackageResult.success(this.path, this.bytes)
      : ok = true,
        error = null;

  const PackageResult.failure(this.error)
      : ok = false,
        path = null,
        bytes = null;
}

/// Builds and installs `.wsl` packages.
class DistroPackager {
  final WSLApi api;

  DistroPackager({WSLApi? api}) : api = api ?? WSLApi();

  /// Where packages are written by default: `<data path>\packages`.
  ///
  /// Alongside `templates`, through the same [SafePath] helper, so the two
  /// export-shaped features live next to each other and neither can be talked
  /// into writing outside the data root.
  SafePath packagePath() => getDataPath()..cd('packages');

  /// Default output file for [distro].
  String defaultPackageFile(String distro) =>
      packagePath().file('${replaceSpecialChars(distro)}.wsl');

  /// Read [distro]'s distribution config, or null when it cannot be reached.
  Future<WslDistributionConfFile?> readConf(String distro) =>
      api.readDistributionConf(distro);

  /// Probe [distro] for the facts [packageIssues] needs.
  ///
  /// The fixed paths go through one `bash -c` because there are three of them;
  /// the OOBE command goes through `--exec` with real argv, because it is a
  /// value out of a file the user edits and must not reach a shell at all.
  Future<DistroPackageInspection> inspect(
      String distro, WslDistributionConfFile conf) async {
    final probe = await api.readDistroFileList(distro, const <String>[
      '/etc/wsl.conf',
      '/etc/resolv.conf',
    ]);

    final command = conf.get('oobe', 'command')?.trim() ?? '';
    bool? executable;
    if (command.isNotEmpty) {
      executable = await api.isExecutableInDistro(distro, command);
    }

    return DistroPackageInspection(
      hasWslConf: probe.contains('/etc/wsl.conf'),
      hasResolvConf: probe.contains('/etc/resolv.conf'),
      oobeCommandExecutable: executable,
    );
  }

  /// Write the documented sample OOBE script into [distro] and point
  /// `oobe.command` at it.
  ///
  /// `0755`: WSL executes it directly, and a `0644` script fails with
  /// "permission denied", which the doc says costs the user their shell.
  /// `oobe.defaultUid` is set in the same pass because the script creates the
  /// account at that UID and the two disagreeing is the documented mistake.
  Future<bool> writeSampleOobe(String distro,
      {String path = kDefaultOobeScriptPath,
      String uid = kDefaultOobeUid}) async {
    final written = await api.writeDistroFile(
        distro, path, sampleOobeScript(uid: uid),
        mode: '0755');
    if (!written) return false;
    return api.updateDistributionConf(distro, (conf) {
      conf.set('oobe', 'command', path);
      conf.set('oobe', 'defaultUid', uid);
    });
  }

  /// Export [distro] as a `.wsl` package at [outputPath].
  ///
  /// [format] must be one of [kWslPackageFormats]; `tar.gz` is the documented
  /// recommendation and the default. A `.wsl` **is** a tar — the only thing
  /// that makes it a package is the extension plus the config files inside it
  /// — so this is `wsl --export` with the right format and the right name, and
  /// deliberately nothing more.
  Future<PackageResult> package(String distro, String outputPath,
      {String format = 'tar.gz'}) async {
    if (!(await api.capabilities.load()).supportsWslPackages) {
      return const PackageResult.failure('requires WSL 2.4.4');
    }

    final target = File(outputPath);
    try {
      final parent = target.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
    } on FileSystemException catch (error) {
      return PackageResult.failure(error.message);
    }

    try {
      await api.export(distro, outputPath, format: format);
    } catch (error) {
      return PackageResult.failure(error.toString());
    }

    if (!target.existsSync()) {
      // wsl.exe reports plenty of failures on stderr with exit code 0
      // (runtime R-1, R-4), so "the command returned" is not evidence that a
      // file was produced.
      return const PackageResult.failure('no file was written');
    }
    return PackageResult.success(outputPath, target.lengthSync());
  }

  /// Install a `.wsl` package through the documented path.
  ///
  /// [name] overrides the package's own `oobe.defaultName`; [location] is
  /// where the VHD goes, defaulting to this app's instance path so a
  /// `--from-file` install lands beside everything else it manages.
  Future<WslOutput> install(String path, {String? name, String? location}) {
    final target = (name != null && name.trim().isNotEmpty)
        ? getInstancePath(name.trim()).path
        : null;
    return api.installFromFile(path,
        name: name?.trim(), location: location ?? target);
  }
}
