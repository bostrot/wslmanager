// Saved cloud-init configurations, and how they reach a new instance.
//
// cloud-init is what a fresh Linux guest runs on its first boot to set
// itself up — packages, users, files, commands — from a "user-data"
// document handed to it by the platform. Both backends can hand one over:
//
//  * A macOS VM boots from a cloud image with a NoCloud seed ISO that vmctl
//    builds; a saved configuration rides in that seed next to the account and
//    SSH key vmctl seeds on its own (`vmctl create --user-data`).
//  * A WSL distro that ships cloud-init (Ubuntu 24.04 and later) reads
//    `%USERPROFILE%\.cloud-init\<distro>.user-data` on its first start —
//    cloud-init's WSL datasource. Distros without cloud-init ignore the file.
//
// The configurations themselves live in SharedPreferences as one JSON list
// (the same shape as [TodoStore]), which is what the Cloud-init screen edits
// and the two create pages pick from.

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:yaml/yaml.dart';

/// One saved user-data document under a name.
class CloudInitConfig {
  const CloudInitConfig({
    required this.name,
    this.description = '',
    required this.content,
  });

  /// What the pickers show and what a create page remembers its choice by.
  /// Held to a path segment's alphabet (see [isValidCloudInitName]) so it
  /// can be typed, shown in a combo box and put in a message without ever
  /// needing to be escaped — the file cloud-init reads on Windows is named
  /// after the *distro*, not after this.
  final String name;
  final String description;

  /// The user-data document, verbatim: `#cloud-config` YAML or a script.
  final String content;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'content': content,
      };

  factory CloudInitConfig.fromJson(Map<String, dynamic> json) =>
      CloudInitConfig(
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}

/// Name rule shared with the snippet editor: letters, digits, `.`, `_`,
/// `-`, not starting with a dot, so `..` and a hidden-file name are out too.
final RegExp _namePattern = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

bool isValidCloudInitName(String name) =>
    name.isNotEmpty && name.length <= 64 && _namePattern.hasMatch(name);

/// The first lines cloud-init recognises a user-data document by — the
/// same list its own `type_from_starts_with` sniffs, minus the MIME
/// multipart form, which the macOS seed nests inside a multipart of its own
/// where cloud-init would not recognise it again (a nested message is left
/// as `text/plain` and logged as unhandled). A prefix match, so
/// `#cloud-config-archive`, `#cloud-config-jsonp` and `#include-once` are
/// covered by their stems.
///
/// Anything else cloud-init passes through unhandled with a warning in the
/// guest's log, which is the silent failure the editor refuses to let
/// through.
const List<String> kCloudInitHeaders = [
  '#cloud-config',
  '#!',
  '#include',
  '#cloud-boothook',
  '#part-handler',
  '## template: jinja',
];

/// Why a document cannot be a cloud-init user-data, as an i18n key (with
/// its `%s` argument in [CloudInitProblem.detail]), or null when it can.
///
/// Plain `#cloud-config` documents are also parsed as YAML, because that is
/// the mistake people actually make — a stray tab, a missing space after a
/// colon — and cloud-init reports it only in a log inside the guest.
CloudInitProblem? validateCloudInitUserData(String content) {
  final text = content.trimLeft();
  if (text.trim().isEmpty) {
    return const CloudInitProblem('cloudinitcontentrequired-text');
  }
  if (!kCloudInitHeaders.any(text.startsWith)) {
    return const CloudInitProblem('cloudinitheaderinvalid-text');
  }
  if (text.startsWith('#cloud-config') &&
      !text.startsWith('#cloud-config-')) {
    try {
      final parsed = loadYaml(text);
      if (parsed != null && parsed is! YamlMap) {
        return const CloudInitProblem('cloudinityamlnotamap-text');
      }
    } on YamlException catch (error) {
      return CloudInitProblem('cloudinityamlinvalid-text',
          detail: error.message);
    }
  }
  return null;
}

class CloudInitProblem {
  const CloudInitProblem(this.key, {this.detail = ''});

  /// An i18n key. Keys with a `%s` take [detail].
  final String key;
  final String detail;
}

/// A document the way both guests read it: LF line endings and a final
/// newline. A configuration pasted from a Windows editor carries CRLF, and
/// while cloud-init's header sniff survives a `\r`, a YAML value or a
/// script line does not have to; the seed on macOS and the file on Windows
/// both get the same bytes, from here.
String normalizeCloudInitUserData(String content) {
  var text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (!text.endsWith('\n')) text += '\n';
  return text;
}

/// What a new configuration starts as: every stanza people reach for,
/// commented out, so the editor is never a blank page with a YAML dialect to
/// remember.
const String kCloudInitStarter = '''#cloud-config
# Runs once, on the instance's first boot.
# Reference: https://cloudinit.readthedocs.io/en/latest/reference/examples.html

package_update: true
packages:
  - git
  - curl

# users:
#   - name: dev
#     groups: [sudo]
#     sudo: ALL=(ALL) NOPASSWD:ALL
#     shell: /bin/bash
#     ssh_authorized_keys:
#       - ssh-ed25519 AAAA... you@example.com

# write_files:
#   - path: /etc/motd
#     content: |
#       Provisioned by WSL Manager.

runcmd:
  - echo "cloud-init finished" > /var/tmp/wslmanager-cloud-init
''';

/// The saved configurations: one JSON list in SharedPreferences, names
/// unique.
///
/// A singleton [ChangeNotifier] so the create pages' pickers and the
/// Cloud-init screen see one list; [reload] drops the cache for tests that
/// swap the preferences underneath it.
class CloudInitStore extends ChangeNotifier {
  CloudInitStore._();
  static final CloudInitStore instance = CloudInitStore._();

  static const String prefsKey = 'CloudInitConfigs';

  final List<CloudInitConfig> _items = [];
  bool _loaded = false;

  /// A live, read-only view — not a copy, because the pickers read it on
  /// every rebuild of a form.
  List<CloudInitConfig> get items {
    _load();
    return UnmodifiableListView(_items);
  }

  CloudInitConfig? byName(String name) {
    _load();
    for (final item in _items) {
      if (item.name == name) return item;
    }
    return null;
  }

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final stored = prefs.getString(prefsKey);
    if (stored == null || stored.isEmpty) return;
    try {
      // Parsed in full before anything is replaced, element by element: a
      // bad entry halfway through is dropped on its own, not with every
      // entry after it — which the next save would then have written back
      // as the whole list.
      final list = jsonDecode(stored) as List;
      final parsed = <CloudInitConfig>[];
      for (final e in list) {
        try {
          parsed.add(CloudInitConfig.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // One entry nobody can use; the rest are still worth having.
        }
      }
      _items
        ..clear()
        ..addAll(parsed);
    } catch (_) {
      // A preference that is not a list at all reads as an empty one.
    }
  }

  Future<void> _persist() => prefs.setString(
      prefsKey, jsonEncode(_items.map((e) => e.toJson()).toList()));

  /// Adds [config], or replaces the one of the same name — and, when an
  /// edit renamed it, the one under [previousName]. Whatever the caller
  /// checked, the list never ends up with two entries under one name: the
  /// entry keeps the slot of the one it replaces, and any other entry that
  /// name already had goes.
  ///
  /// The document is stored normalised (see [normalizeCloudInitUserData]),
  /// so every consumer gets the same bytes.
  Future<void> save(CloudInitConfig config, {String? previousName}) async {
    _load();
    final stored = CloudInitConfig(
      name: config.name,
      description: config.description,
      content: normalizeCloudInitUserData(config.content),
    );
    var index = _items.indexWhere((e) => e.name == (previousName ?? config.name));
    if (index < 0) index = _items.indexWhere((e) => e.name == config.name);
    _items.removeWhere(
        (e) => e.name == config.name || e.name == previousName);
    if (index < 0 || index > _items.length) index = _items.length;
    _items.insert(index, stored);
    await _persist();
    notifyListeners();
  }

  Future<bool> remove(String name) async {
    _load();
    final before = _items.length;
    _items.removeWhere((e) => e.name == name);
    if (_items.length == before) return false;
    await _persist();
    notifyListeners();
    return true;
  }

  /// Forget the cached list, so the next read comes from the preferences.
  void reload() {
    _loaded = false;
    _items.clear();
    notifyListeners();
  }
}

/// The user-data files cloud-init's WSL datasource reads, under
/// `%USERPROFILE%\.cloud-init\`.
///
/// Only the per-instance file (`<distro>.user-data`) is ever written: the
/// `default.user-data` and `<id>-all.user-data` fallbacks belong to the
/// user, and a file this app leaves behind would apply itself to every
/// later distro of the same name. So the file is written right before
/// `wsl --import`, removed again once the first boot has consumed it, and
/// removed with the distro either way (`WSLApi.remove`).
class CloudInitFiles {
  /// Test seam: where the `.cloud-init` directory lives instead of the
  /// user profile.
  static String? userDataDirOverride;

  static String get userDataDir =>
      userDataDirOverride ??
      '${userProfileDir()}${Platform.pathSeparator}.cloud-init';

  static String userDataPath(String distroName) =>
      '$userDataDir${Platform.pathSeparator}$distroName.user-data';

  static bool exists(String distroName) =>
      File(userDataPath(distroName)).existsSync();

  /// Writes [content] for [distroName]: UTF-8 without a BOM (which would be
  /// the first byte of the `#cloud-config` header, seen from the guest) and
  /// normalised line endings.
  static Future<String> write(String distroName, String content) async {
    final file = File(userDataPath(distroName));
    await file.parent.create(recursive: true);
    await file.writeAsString(normalizeCloudInitUserData(content),
        flush: true);
    return file.path;
  }

  static Future<void> remove(String distroName) async {
    try {
      await File(userDataPath(distroName)).delete();
    } on FileSystemException {
      // Nothing to remove.
    }
  }
}

/// The guest-side wait for cloud-init to finish its first boot, run as root
/// after `wsl --import`. It answers with one word on its last line:
///
///  * `done` — cloud-init is present, systemd is running it, and every
///    module has run: the user-data file has been consumed.
///  * `skipped` — the distro has no cloud-init, or no systemd to run it
///    (`/run/systemd/system` exists only under a running systemd): the file
///    will never be read, by this boot or a later one.
///
/// `status --wait` blocks while the status is still "not run", which is
/// what the systemd check is for; the broker's [cloudInitWaitTimeout] is the
/// bound on everything else. Exit status is swallowed on purpose: a module
/// that failed is cloud-init's to report, and the distro is there to be
/// used.
const String cloudInitWaitScript =
    'if command -v cloud-init >/dev/null 2>&1 && [ -d /run/systemd/system ]; '
    'then cloud-init status --wait >/dev/null 2>&1 || true; echo done; '
    'else echo skipped; fi';

/// The most a first boot may take before the create gives up waiting and
/// says so: long enough for `package_update` and a few `packages` against a
/// slow mirror, short enough that a wedged boot does not hold the create
/// page for the afternoon.
const Duration cloudInitWaitTimeout = Duration(minutes: 20);

/// How the first-boot wait ended.
enum CloudInitWaitOutcome { done, skipped, failed, cancelled }

/// Reads [cloudInitWaitScript]'s answer.
CloudInitWaitOutcome parseCloudInitWait(int exitCode, String stdout) {
  final lines = stdout.trim().split('\n');
  final last = lines.isEmpty ? '' : lines.last.trim();
  if (exitCode != 0) return CloudInitWaitOutcome.failed;
  if (last == 'done') return CloudInitWaitOutcome.done;
  if (last == 'skipped') return CloudInitWaitOutcome.skipped;
  return CloudInitWaitOutcome.failed;
}
