// Playbooks: an instance's desired state as code, applied to an existing
// instance as often as needed (bostrot/ai-tasks#78).
//
// cloud-init runs once, on a first boot. A playbook is the same kind of
// document — packages, users, files, services, commands — for an instance
// that already exists: every step looks first and changes only what is not
// there yet, and reports `ok` or `changed` the way Ansible does, so applying
// the same playbook twice is safe and the second run says so.
//
// Two document shapes are accepted:
//
//  * A YAML mapping in cloud-config's vocabulary (`packages`, `users`,
//    `write_files`, `runcmd`, …). The app is the engine: each key becomes
//    one or more small root shell scripts, run one at a time through
//    [VmBackend.runInInstance], each answering with a status marker on its
//    last line. A saved cloud-init configuration works here unchanged.
//  * A YAML list of Ansible plays. Those are handed to `ansible-playbook`
//    inside the instance (`-i localhost, -c local`), installing Ansible
//    from the instance's package manager first when it is missing.
//
// The playbooks live in SharedPreferences as one JSON list (`Playbooks`),
// the same shape as the cloud-init configurations; the latest run of each
// playbook on each instance is kept next to them (`PlaybookRuns`).

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:yaml/yaml.dart';

/// One saved playbook under a name.
class Playbook {
  const Playbook({
    required this.name,
    this.description = '',
    required this.content,
  });

  /// Held to a path segment's alphabet (see [isValidPlaybookName]), so it
  /// can be shown, typed and put in a message without escaping.
  final String name;
  final String description;

  /// The document, verbatim.
  final String content;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'content': content,
      };

  factory Playbook.fromJson(Map<String, dynamic> json) => Playbook(
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}

/// Name rule shared with the snippet and cloud-init editors: letters,
/// digits, `.`, `_`, `-`, not starting with a dot.
final RegExp _namePattern = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

bool isValidPlaybookName(String name) =>
    name.isNotEmpty && name.length <= 64 && _namePattern.hasMatch(name);

/// The top-level keys the built-in engine handles, in the order it runs
/// them — cloud-init's own order: accounts and files first, packages next,
/// commands last, so a command can rely on everything above it.
const List<String> kPlaybookKeys = [
  'users',
  'write_files',
  'package_update',
  'packages',
  'package_upgrade',
  'timezone',
  'services',
  'runcmd',
];

/// Why a document cannot be applied, as an i18n key (with its `%s` argument
/// in [PlaybookProblem.detail]), or null when it can.
PlaybookProblem? validatePlaybook(String content) {
  if (content.trim().isEmpty) {
    return const PlaybookProblem('playbookcontentrequired-text');
  }
  final dynamic parsed;
  try {
    parsed = loadYaml(content);
  } on YamlException catch (error) {
    return PlaybookProblem('playbookyamlinvalid-text', detail: error.message);
  }
  if (parsed is YamlList) {
    for (final play in parsed) {
      if (play is! YamlMap || !play.containsKey('hosts')) {
        return const PlaybookProblem('playbooknotplay-text');
      }
    }
    if (parsed.isEmpty) {
      return const PlaybookProblem('playbookcontentrequired-text');
    }
    return null;
  }
  if (parsed is YamlMap) {
    if (!parsed.keys.any((k) => kPlaybookKeys.contains(k.toString()))) {
      return PlaybookProblem('playbooknothing-text',
          detail: kPlaybookKeys.join(', '));
    }
    return null;
  }
  return const PlaybookProblem('playbookshape-text');
}

class PlaybookProblem {
  const PlaybookProblem(this.key, {this.detail = ''});

  /// An i18n key. Keys with a `%s` take [detail].
  final String key;
  final String detail;
}

/// LF line endings and a final newline, whatever editor the text came from.
String normalizePlaybook(String content) {
  var text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (!text.endsWith('\n')) text += '\n';
  return text;
}

/// What a new playbook starts as: every stanza the built-in engine knows,
/// the optional ones commented out.
const String kPlaybookStarter = '''#cloud-config
# A playbook describes the state an instance should be in. Apply it to any
# instance as often as you like: every step checks first and changes only
# what is not there yet. The vocabulary is cloud-config's, so a saved
# cloud-init configuration works here too. A YAML list of plays is run with
# ansible-playbook inside the instance instead.

package_update: true
packages:
  - git
  - curl

# users:
#   - name: dev
#     groups: [sudo]
#     shell: /bin/bash
#     sudo: ALL=(ALL) NOPASSWD:ALL
#     ssh_authorized_keys:
#       - ssh-ed25519 AAAA... you@example.com

# write_files:
#   - path: /etc/motd
#     content: |
#       Managed by WSL Manager.
#     permissions: "0644"

# services:
#   - name: ssh
#     enabled: true
#     state: started

# runcmd:
#   - cmd: curl -fsSL https://example.com/install.sh | sh
#     creates: /usr/local/bin/example
''';

/// The saved playbooks: one JSON list in SharedPreferences, names unique.
///
/// A singleton [ChangeNotifier], like the cloud-init store, so the list
/// page follows every save; [reload] drops the cache for tests that swap
/// the preferences underneath it.
class PlaybookStore extends ChangeNotifier {
  PlaybookStore._();
  static final PlaybookStore instance = PlaybookStore._();

  static const String prefsKey = 'Playbooks';

  final List<Playbook> _items = [];
  bool _loaded = false;

  List<Playbook> get items {
    _load();
    return UnmodifiableListView(_items);
  }

  Playbook? byName(String name) {
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
      // Element by element: one bad entry is dropped on its own, not with
      // every entry after it.
      final list = jsonDecode(stored) as List;
      final parsed = <Playbook>[];
      for (final e in list) {
        try {
          parsed.add(Playbook.fromJson(e as Map<String, dynamic>));
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

  /// Adds [playbook], or replaces the one of the same name — and, when an
  /// edit renamed it, the one under [previousName]. The list never ends up
  /// with two entries under one name.
  Future<void> save(Playbook playbook, {String? previousName}) async {
    _load();
    final stored = Playbook(
      name: playbook.name,
      description: playbook.description,
      content: normalizePlaybook(playbook.content),
    );
    var index =
        _items.indexWhere((e) => e.name == (previousName ?? playbook.name));
    if (index < 0) index = _items.indexWhere((e) => e.name == playbook.name);
    _items
        .removeWhere((e) => e.name == playbook.name || e.name == previousName);
    if (index < 0 || index > _items.length) index = _items.length;
    _items.insert(index, stored);
    await _persist();
    // The run history follows a rename; the store owns both halves of the
    // name-to-runs relationship (remove drops it, save carries it).
    if (previousName != null && previousName != playbook.name) {
      await PlaybookRunStore.instance
          .renamePlaybook(previousName, playbook.name);
    }
    notifyListeners();
  }

  Future<bool> remove(String name) async {
    _load();
    final before = _items.length;
    _items.removeWhere((e) => e.name == name);
    if (_items.length == before) return false;
    await _persist();
    await PlaybookRunStore.instance.forgetPlaybook(name);
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

/// How one step of a playbook ended — Ansible's four words.
enum TaskStatus { ok, changed, failed, skipped }

/// One step of a playbook: a title (an i18n key and its arguments, so the
/// page shows it in the user's language) and the root shell script that
/// carries it out, or [skipReason] when the engine will not run it.
class ProvisioningTask {
  const ProvisioningTask({
    required this.titleKey,
    this.titleArgs = const [],
    this.script,
    this.timeout = const Duration(minutes: 5),
  });

  final String titleKey;
  final List<String> titleArgs;

  /// The script, or null when the step is reported as skipped without
  /// touching the instance (a key the engine does not handle).
  final String? script;

  /// The most the step may take. Package installs get longer.
  final Duration timeout;

  bool get skipped => script == null;
}

class TaskResult {
  const TaskResult(this.task, this.status, this.output);

  final ProvisioningTask task;
  final TaskStatus status;

  /// What the step printed, marker line removed.
  final String output;
}

/// The outcome of applying a playbook to one instance.
class ProvisioningReport {
  ProvisioningReport({
    required this.playbook,
    required this.instance,
    required this.check,
    required this.tasks,
  });

  final String playbook;
  final String instance;

  /// Whether this was a check run: nothing was changed, `changed` means
  /// "would change".
  final bool check;
  final List<ProvisioningTask> tasks;
  final List<TaskResult> results = [];

  /// Set when the run stopped before the last task: the step that failed,
  /// or the step after which the user stopped it.
  bool stopped = false;

  int count(TaskStatus status) =>
      results.where((r) => r.status == status).length;

  bool get failed => results.any((r) => r.status == TaskStatus.failed);
  bool get changed => results.any((r) => r.status == TaskStatus.changed);
  bool get finished => stopped || results.length == tasks.length;

  /// The overall status, the way a run record keeps it.
  TaskStatus get status => failed
      ? TaskStatus.failed
      : changed
          ? TaskStatus.changed
          : TaskStatus.ok;
}

/// The marker every step's script prints as its last line — on a line of
/// its own (`report` starts with a newline), so a command that printed
/// without a trailing newline cannot glue itself to it.
const String kResultMarker = '__wslm__:';

/// Reads a step's answer. The scripts always exit 0 after their marker, so
/// a non-zero exit or a missing marker means the instance could not run the
/// step at all (not running, no bash, unreachable) — a failure either way.
TaskResult parseTaskOutput(ProvisioningTask task, VmCommandOutput out) {
  final lines =
      out.stdout.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  TaskStatus? status;
  final kept = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith(kResultMarker)) {
      status = _statusFromWord(trimmed.substring(kResultMarker.length).trim());
      continue;
    }
    kept.add(line);
  }
  var text = kept.join('\n').trim();
  final err = out.stderr.trim();
  if (err.isNotEmpty) text = text.isEmpty ? err : '$text\n$err';
  if (out.exitCode != 0 || status == null) {
    return TaskResult(task, TaskStatus.failed, text);
  }
  return TaskResult(task, status, text);
}

TaskStatus? _statusFromWord(String word) {
  for (final s in TaskStatus.values) {
    if (s.name == word) return s;
  }
  return null;
}

/// Single-quote [value] for a POSIX shell: nothing inside is interpreted.
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// Every step's script starts with this: the package-manager shims, the
/// `report`/`fail` answers and the check-mode switch (`WSLM_CHECK=1`: look,
/// print what would change, change nothing).
///
/// POSIX sh, run as `sh`, with only commands busybox has too, so the script
/// itself is the same on Alpine as on Ubuntu. What still needs bash is the
/// way in: [VmBackend.runInInstance] runs through `bash -c` on both
/// backends, so a distro without bash fails at the first step before any of
/// this runs.
const String kScriptPrelude = r'''set -u
export DEBIAN_FRONTEND=noninteractive
# `wsl --exec` hands root a PATH without the sbin directories on some
# distros (`useradd`, `apk` and friends live there).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
CHECK="${WSLM_CHECK:-0}"
report() { printf '\n__wslm__:%s\n' "$1"; exit 0; }
fail() { echo "$1" >&2; printf '\n__wslm__:failed\n'; exit 0; }
PM=none
for m in apt-get apk dnf yum zypper pacman; do
  if command -v "$m" >/dev/null 2>&1; then PM="$m"; break; fi
done
pkg_installed() {
  case "$PM" in
    apt-get) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;;
    dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
pkg_update() {
  case "$PM" in
    apt-get) apt-get update -q ;;
    apk) apk update ;;
    dnf) dnf -q makecache ;;
    yum) yum -q makecache ;;
    zypper) zypper --non-interactive refresh ;;
    pacman) pacman -Sy --noconfirm ;;
    *) return 1 ;;
  esac
}
pkg_install() {
  case "$PM" in
    apt-get) apt-get install -y -q "$@" ;;
    apk) apk add "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
    *) return 1 ;;
  esac
}
pkg_upgrade() {
  case "$PM" in
    apt-get) apt-get upgrade -y -q ;;
    apk) apk upgrade ;;
    dnf) dnf upgrade -y ;;
    yum) yum update -y ;;
    zypper) zypper --non-interactive update ;;
    pacman) pacman -Su --noconfirm ;;
    *) return 1 ;;
  esac
}
''';

/// Turns a document into the steps that apply it, in run order.
///
/// Throws [FormatException] on a document [validatePlaybook] would refuse;
/// callers validate first, this is the last line of defence.
List<ProvisioningTask> compilePlaybook(String content) {
  final problem = validatePlaybook(content);
  if (problem != null) throw FormatException(problem.key);
  final parsed = loadYaml(content);
  if (parsed is YamlList) return _compileAnsible(content);
  return _compileBuiltin(parsed as YamlMap);
}

List<ProvisioningTask> _compileBuiltin(YamlMap doc) {
  final tasks = <ProvisioningTask>[];
  for (final key in kPlaybookKeys) {
    if (!doc.containsKey(key)) continue;
    final value = doc[key];
    if (key == 'users') {
      for (final user in _list(value)) {
        // cloud-config's `default` entry stands for the distro's default
        // user; there is nothing to ensure about it.
        if (user is! Map) continue;
        tasks.add(_userTask(user));
      }
    } else if (key == 'write_files') {
      for (final file in _list(value)) {
        if (file is! Map) continue;
        tasks.add(_fileTask(file));
      }
    } else if (key == 'package_update') {
      if (_truthy(value)) tasks.add(_packageUpdateTask());
    } else if (key == 'packages') {
      final names = <String>[];
      for (final entry in _list(value)) {
        // cloud-config allows `[name, version]` pairs; the built-in engine
        // installs the name and leaves the version to the package manager.
        if (entry is List && entry.isNotEmpty) {
          names.add(entry.first.toString());
        } else if (entry != null) {
          names.add(entry.toString());
        }
      }
      if (names.isNotEmpty) tasks.add(_packagesTask(names));
    } else if (key == 'package_upgrade') {
      if (_truthy(value)) tasks.add(_packageUpgradeTask());
    } else if (key == 'timezone') {
      if (value != null && value.toString().trim().isNotEmpty) {
        tasks.add(_timezoneTask(value.toString().trim()));
      }
    } else if (key == 'services') {
      for (final service in _list(value)) {
        if (service is Map) {
          tasks.add(_serviceTask(service));
        } else if (service != null) {
          tasks.add(_serviceTask({'name': service.toString()}));
        }
      }
    } else if (key == 'runcmd') {
      for (final entry in _list(value)) {
        final task = _commandTask(entry);
        if (task != null) tasks.add(task);
      }
    }
  }
  for (final key in doc.keys) {
    if (kPlaybookKeys.contains(key.toString())) continue;
    tasks.add(ProvisioningTask(
        titleKey: 'playbooktaskunsupported-text', titleArgs: [key.toString()]));
  }
  return tasks;
}

List<dynamic> _list(dynamic value) {
  if (value is List) return value;
  if (value == null) return const [];
  return [value];
}

/// YAML 1.1's booleans as well as YAML 1.2's: cloud-init reads `yes` and
/// `on` as true, the Dart parser reads them as strings.
bool _truthy(dynamic value) =>
    value == true ||
    const ['true', 'yes', 'on', '1'].contains(value.toString().toLowerCase());

String _script(String body) => '$kScriptPrelude$body';

ProvisioningTask _packageUpdateTask() => ProvisioningTask(
      titleKey: 'playbooktaskupdate-text',
      timeout: const Duration(minutes: 20),
      script: _script(r'''
[ "$PM" = none ] && fail "no known package manager (apt-get, apk, dnf, yum, zypper, pacman)"
[ "$CHECK" = 1 ] && report skipped
pkg_update || fail "refreshing the package index failed"
report ok
'''),
    );

ProvisioningTask _packageUpgradeTask() => ProvisioningTask(
      titleKey: 'playbooktaskupgrade-text',
      timeout: const Duration(minutes: 60),
      script: _script(r'''
[ "$PM" = none ] && fail "no known package manager (apt-get, apk, dnf, yum, zypper, pacman)"
[ "$CHECK" = 1 ] && report skipped
pkg_upgrade || fail "upgrading packages failed"
report changed
'''),
    );

ProvisioningTask _packagesTask(List<String> names) {
  final quoted = names.map(shellQuote).join(' ');
  return ProvisioningTask(
    titleKey: 'playbooktaskpackages-text',
    titleArgs: [names.join(', ')],
    timeout: const Duration(minutes: 60),
    script: _script('''
[ "\$PM" = none ] && fail "no known package manager (apt-get, apk, dnf, yum, zypper, pacman)"
missing=""
for p in $quoted; do
  if pkg_installed "\$p"; then echo "\$p: present"; else echo "\$p: missing"; missing="\$missing \$p"; fi
done
[ -z "\$missing" ] && report ok
[ "\$CHECK" = 1 ] && { echo "would install:\$missing"; report changed; }
pkg_install \$missing || fail "installing\$missing failed"
report changed
'''),
  );
}

ProvisioningTask _timezoneTask(String zone) => ProvisioningTask(
      titleKey: 'playbooktasktimezone-text',
      titleArgs: [zone],
      script: _script('''
tz=${shellQuote(zone)}
[ -f "/usr/share/zoneinfo/\$tz" ] || fail "unknown time zone \$tz"
if [ "\$(readlink -f /etc/localtime 2>/dev/null)" = "\$(readlink -f "/usr/share/zoneinfo/\$tz")" ]; then report ok; fi
echo "time zone: \$tz"
[ "\$CHECK" = 1 ] && report changed
ln -sf "/usr/share/zoneinfo/\$tz" /etc/localtime || fail "could not link /etc/localtime"
echo "\$tz" > /etc/timezone
report changed
'''),
    );

ProvisioningTask _userTask(Map user) {
  final name = user['name']?.toString().trim() ?? '';
  final shell = user['shell']?.toString().trim() ?? '';
  final groups = <String>[];
  final rawGroups = user['groups'];
  if (rawGroups is List) {
    groups.addAll(rawGroups.map((g) => g.toString().trim()));
  } else if (rawGroups != null) {
    groups.addAll(rawGroups.toString().split(',').map((g) => g.trim()));
  }
  groups.removeWhere((g) => g.isEmpty);
  final sudo = <String>[];
  final rawSudo = user['sudo'];
  if (rawSudo is List) {
    sudo.addAll(rawSudo.map((s) => s.toString().trim()));
  } else if (rawSudo != null && rawSudo != false) {
    sudo.add(rawSudo.toString().trim());
  }
  sudo.removeWhere((s) => s.isEmpty || s.toLowerCase() == 'false');
  final keys = <String>[];
  final rawKeys = user['ssh_authorized_keys'] ?? user['ssh-authorized-keys'];
  if (rawKeys is List) {
    keys.addAll(rawKeys.map((k) => k.toString().trim()));
  } else if (rawKeys != null) {
    keys.add(rawKeys.toString().trim());
  }
  keys.removeWhere((k) => k.isEmpty);

  if (name.isEmpty) {
    return const ProvisioningTask(
        titleKey: 'playbooktaskunsupported-text', titleArgs: ['users']);
  }
  final sudoLines = sudo.map((rule) => '$name $rule').join('\n');
  return ProvisioningTask(
    titleKey: 'playbooktaskuser-text',
    titleArgs: [name],
    script: _script('''
name=${shellQuote(name)}
shell=${shellQuote(shell)}
want_groups=${shellQuote(groups.join(' '))}
sudo_lines=${shellQuote(sudoLines)}
keys=${shellQuote(keys.join('\n'))}
changed=0
exists=1
if ! id "\$name" >/dev/null 2>&1; then
  exists=0
  echo "user \$name: create"
  if [ "\$CHECK" != 1 ]; then
    if command -v useradd >/dev/null 2>&1; then
      useradd -m \${shell:+-s "\$shell"} "\$name" || fail "useradd \$name failed"
    else
      adduser -D \${shell:+-s "\$shell"} "\$name" || fail "adduser \$name failed"
    fi
    exists=1
  fi
  changed=1
fi
if [ "\$exists" = 1 ] && [ -n "\$shell" ]; then
  cur=\$(getent passwd "\$name" | cut -d: -f7)
  if [ "\$cur" != "\$shell" ]; then
    echo "shell: \$cur -> \$shell"
    if [ "\$CHECK" != 1 ]; then
      if command -v usermod >/dev/null 2>&1; then usermod -s "\$shell" "\$name"; else chsh -s "\$shell" "\$name"; fi || fail "could not change the shell"
    fi
    changed=1
  fi
fi
for g in \$want_groups; do
  if [ "\$exists" = 1 ] && id -nG "\$name" 2>/dev/null | tr ' ' '\\n' | grep -qx "\$g"; then continue; fi
  echo "group \$g: add"
  if [ "\$CHECK" != 1 ]; then
    if ! getent group "\$g" >/dev/null 2>&1; then
      if command -v groupadd >/dev/null 2>&1; then groupadd "\$g"; else addgroup "\$g"; fi || fail "could not create group \$g"
    fi
    if command -v usermod >/dev/null 2>&1; then usermod -aG "\$g" "\$name"; else addgroup "\$name" "\$g"; fi || fail "could not add \$name to \$g"
  fi
  changed=1
done
if [ -n "\$sudo_lines" ]; then
  f="/etc/sudoers.d/90-wslmanager-\$name"
  if [ "\$(cat "\$f" 2>/dev/null)" != "\$sudo_lines" ]; then
    echo "sudoers: write \$f"
    if [ "\$CHECK" != 1 ]; then
      mkdir -p /etc/sudoers.d && printf '%s\\n' "\$sudo_lines" > "\$f" && chmod 0440 "\$f" || fail "could not write \$f"
    fi
    changed=1
  fi
fi
if [ -n "\$keys" ]; then
  home=\$(getent passwd "\$name" 2>/dev/null | cut -d: -f6)
  [ -z "\$home" ] && home="/home/\$name"
  ak="\$home/.ssh/authorized_keys"
  kf=\$(mktemp) || fail "mktemp failed"
  printf '%s\\n' "\$keys" > "\$kf"
  while IFS= read -r k; do
    [ -z "\$k" ] && continue
    if grep -qxF "\$k" "\$ak" 2>/dev/null; then continue; fi
    echo "authorized key: add"
    if [ "\$CHECK" != 1 ]; then
      mkdir -p "\$home/.ssh" && chmod 700 "\$home/.ssh" && printf '%s\\n' "\$k" >> "\$ak" && chmod 600 "\$ak" && chown -R "\$name" "\$home/.ssh" || { rm -f "\$kf"; fail "could not write \$ak"; }
    fi
    changed=1
  done < "\$kf"
  rm -f "\$kf"
fi
[ "\$changed" = 1 ] && report changed
report ok
'''),
  );
}

ProvisioningTask _fileTask(Map file) {
  final path = file['path']?.toString().trim() ?? '';
  var content = file['content']?.toString() ?? '';
  final encoding = file['encoding']?.toString().toLowerCase() ?? '';
  final append = _truthy(file['append']);
  var mode = file['permissions']?.toString().trim() ?? '';
  final owner = file['owner']?.toString().trim() ?? '';
  if (path.isEmpty) {
    return const ProvisioningTask(
        titleKey: 'playbooktaskunsupported-text', titleArgs: ['write_files']);
  }
  // cloud-config takes base64 content under `encoding: b64`; anything else
  // is the text itself. Either way the bytes travel base64-encoded.
  final String payload;
  if (encoding == 'b64' || encoding == 'base64') {
    payload = content.replaceAll(RegExp(r'\s'), '');
  } else {
    payload = base64.encode(utf8.encode(content));
  }
  // `stat -c %a` prints `644` for what the document calls `0644`.
  mode = mode.replaceFirst(RegExp(r'^0+(?=.)'), '');
  // `owner` may be names or numeric ids; either form matches.
  final ownerFormat = owner.contains(':') ? '%U:%G' : '%U';
  final ownerIdFormat = owner.contains(':') ? '%u:%g' : '%u';
  return ProvisioningTask(
    titleKey: 'playbooktaskfile-text',
    titleArgs: [path],
    script: _script('''
path=${shellQuote(path)}
mode=${shellQuote(mode)}
owner=${shellQuote(owner)}
append=${append ? 1 : 0}
tmp=\$(mktemp) || fail "mktemp failed"
printf %s ${shellQuote(payload)} | base64 -d > "\$tmp" || fail "could not decode the content"
changed=0
if [ "\$append" = 1 ]; then
  size=\$(wc -c < "\$tmp")
  if [ -f "\$path" ] && [ "\$size" -le "\$(wc -c < "\$path")" ] && tail -c "\$size" "\$path" | cmp -s - "\$tmp"; then
    echo "content: present"
  else
    echo "content: append"
    if [ "\$CHECK" != 1 ]; then mkdir -p "\$(dirname "\$path")" && cat "\$tmp" >> "\$path" || { rm -f "\$tmp"; fail "could not append to \$path"; }; fi
    changed=1
  fi
else
  if cmp -s "\$tmp" "\$path" 2>/dev/null; then
    echo "content: unchanged"
  else
    if [ -e "\$path" ]; then echo "content: replace"; else echo "content: create"; fi
    if [ "\$CHECK" != 1 ]; then
      # A new file gets cloud-config's default mode rather than mktemp's
      # 0600; an existing one keeps its own unless `permissions` says.
      if [ -e "\$path" ]; then mode_new=0; else mode_new=1; fi
      mkdir -p "\$(dirname "\$path")" && cp "\$tmp" "\$path" || { rm -f "\$tmp"; fail "could not write \$path"; }
      if [ "\$mode_new" = 1 ] && [ -z "\$mode" ]; then chmod 644 "\$path"; fi
    fi
    changed=1
  fi
fi
rm -f "\$tmp"
if [ -n "\$mode" ] && { [ -e "\$path" ] || [ "\$CHECK" = 1 ]; }; then
  if [ "\$(stat -c %a "\$path" 2>/dev/null)" != "\$mode" ]; then
    echo "mode: \$mode"
    if [ "\$CHECK" != 1 ]; then chmod "\$mode" "\$path" || fail "chmod \$mode \$path failed"; fi
    changed=1
  fi
fi
if [ -n "\$owner" ] && { [ -e "\$path" ] || [ "\$CHECK" = 1 ]; }; then
  if [ "\$(stat -c $ownerFormat "\$path" 2>/dev/null)" != "\$owner" ] && [ "\$(stat -c $ownerIdFormat "\$path" 2>/dev/null)" != "\$owner" ]; then
    echo "owner: \$owner"
    if [ "\$CHECK" != 1 ]; then chown "\$owner" "\$path" || fail "chown \$owner \$path failed"; fi
    changed=1
  fi
fi
[ "\$changed" = 1 ] && report changed
report ok
'''),
  );
}

ProvisioningTask _serviceTask(Map service) {
  final name = service['name']?.toString().trim() ?? '';
  if (name.isEmpty) {
    return const ProvisioningTask(
        titleKey: 'playbooktaskunsupported-text', titleArgs: ['services']);
  }
  // A bare name means "enabled and started"; the keys narrow that down.
  final enabled = service.containsKey('enabled')
      ? (_truthy(service['enabled']) ? '1' : '0')
      : '1';
  final state = service.containsKey('state')
      ? service['state'].toString().trim().toLowerCase()
      : 'started';
  return ProvisioningTask(
    titleKey: 'playbooktaskservice-text',
    titleArgs: [name],
    script: _script('''
name=${shellQuote(name)}
enabled=$enabled
state=${shellQuote(state)}
[ -d /run/systemd/system ] || fail "systemd is not running in this instance (on WSL, set [boot] systemd=true in /etc/wsl.conf)"
changed=0
if [ "\$enabled" = 1 ] && ! systemctl is-enabled -q "\$name" 2>/dev/null; then
  echo "enable"
  if [ "\$CHECK" != 1 ]; then systemctl enable -q "\$name" || fail "systemctl enable \$name failed"; fi
  changed=1
fi
if [ "\$enabled" = 0 ] && systemctl is-enabled -q "\$name" 2>/dev/null; then
  echo "disable"
  if [ "\$CHECK" != 1 ]; then systemctl disable -q "\$name" || fail "systemctl disable \$name failed"; fi
  changed=1
fi
case "\$state" in
  started)
    if ! systemctl is-active -q "\$name" 2>/dev/null; then
      echo "start"
      if [ "\$CHECK" != 1 ]; then systemctl start "\$name" || fail "systemctl start \$name failed"; fi
      changed=1
    fi ;;
  stopped)
    if systemctl is-active -q "\$name" 2>/dev/null; then
      echo "stop"
      if [ "\$CHECK" != 1 ]; then systemctl stop "\$name" || fail "systemctl stop \$name failed"; fi
      changed=1
    fi ;;
  restarted)
    echo "restart"
    if [ "\$CHECK" != 1 ]; then systemctl restart "\$name" || fail "systemctl restart \$name failed"; fi
    changed=1 ;;
  *) fail "unknown state \$state (started, stopped, restarted)" ;;
esac
[ "\$changed" = 1 ] && report changed
report ok
'''),
  );
}

/// A `runcmd` entry: a string (run through `sh -c`, as cloud-init does), a
/// list of arguments (run as they are, no shell), or a mapping with `cmd`
/// and an optional `creates` path or `unless` test that makes the step
/// idempotent — a command whose `creates` exists is `ok` and not run again.
ProvisioningTask? _commandTask(dynamic entry) {
  dynamic cmd = entry;
  var creates = '';
  var unless = '';
  if (entry is Map) {
    cmd = entry['cmd'];
    creates = entry['creates']?.toString().trim() ?? '';
    unless = entry['unless']?.toString().trim() ?? '';
  }
  if (cmd == null) return null;
  final String invocation;
  final String title;
  if (cmd is List) {
    if (cmd.isEmpty) return null;
    final args = cmd.map((a) => a.toString()).toList();
    invocation = args.map(shellQuote).join(' ');
    title = args.join(' ');
  } else {
    final text = cmd.toString().trim();
    if (text.isEmpty) return null;
    invocation = 'sh -c ${shellQuote(text)}';
    title = text;
  }
  final shortTitle = title.length > 60 ? '${title.substring(0, 57)}...' : title;
  return ProvisioningTask(
    titleKey: 'playbooktaskcommand-text',
    titleArgs: [shortTitle],
    timeout: const Duration(minutes: 30),
    script: _script('''
creates=${shellQuote(creates)}
unless=${shellQuote(unless)}
if [ -n "\$creates" ] && [ -e "\$creates" ]; then echo "\$creates exists"; report ok; fi
if [ -n "\$unless" ] && sh -c "\$unless" >/dev/null 2>&1; then echo "unless: true"; report ok; fi
[ "\$CHECK" = 1 ] && report skipped
$invocation
rc=\$?
[ "\$rc" = 0 ] || fail "command exited \$rc"
report changed
'''),
  );
}

/// An Ansible playbook: two steps — Ansible present, playbook run.
List<ProvisioningTask> _compileAnsible(String content) {
  final payload = base64.encode(utf8.encode(normalizePlaybook(content)));
  return [
    ProvisioningTask(
      titleKey: 'playbooktaskansible-text',
      timeout: const Duration(minutes: 30),
      script: _script(r'''
if command -v ansible-playbook >/dev/null 2>&1; then ansible-playbook --version 2>/dev/null | head -1; report ok; fi
echo "ansible-playbook: missing"
[ "$CHECK" = 1 ] && fail "Ansible is not installed in this instance; apply once without Check to install it"
[ "$PM" = none ] && fail "no known package manager to install Ansible with"
pkg_update >/dev/null 2>&1 || true
case "$PM" in
  dnf|yum) pkg_install ansible-core ;;
  *) pkg_install ansible ;;
esac || fail "installing Ansible failed"
command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook is still missing after the install"
report changed
'''),
    ),
    ProvisioningTask(
      titleKey: 'playbooktaskansiblerun-text',
      timeout: const Duration(minutes: 60),
      script: _script('''
f=\$(mktemp) || fail "mktemp failed"
printf %s ${shellQuote(payload)} | base64 -d > "\$f" || fail "could not write the playbook"
opts=""
[ "\$CHECK" = 1 ] && opts="--check --diff"
out=\$(ANSIBLE_NOCOLOR=1 ANSIBLE_FORCE_COLOR=0 ansible-playbook -i 'localhost,' -c local \$opts "\$f" 2>&1)
rc=\$?
rm -f "\$f"
printf '%s\\n' "\$out"
[ "\$rc" = 0 ] || fail "ansible-playbook exited \$rc"
if printf '%s\\n' "\$out" | grep -Eq '^localhost[[:space:]]*:.*changed=[1-9]'; then report changed; fi
report ok
'''),
    ),
  ];
}

/// Applies a playbook to one instance, one step at a time.
class ProvisioningRunner {
  ProvisioningRunner(this.backend);

  final VmBackend backend;

  /// Where a step's script lands in the instance before it runs — `mktemp`
  /// there, removed afterwards. The script travels base64-encoded, so no
  /// byte of it is shell syntax on the way in, and the command line itself
  /// carries no quote of either kind: on Windows it is one `wsl.exe`
  /// argument, and PowerShell and `CreateProcess` both have opinions about
  /// quotes inside one (base64's alphabet and `$(…)` need none).
  static String commandFor(ProvisioningTask task, {required bool check}) {
    final payload = base64.encode(utf8.encode(task.script!));
    return 't=\$(mktemp) && printf %s $payload | base64 -d > \$t && '
        'WSLM_CHECK=${check ? 1 : 0} sh \$t; rc=\$?; rm -f \$t; exit \$rc';
  }

  /// Runs [playbook] in [instance]. [onProgress] fires after every step;
  /// [shouldStop] is asked before each step, so a Stop button takes effect
  /// between steps (a running step cannot be interrupted). The run stops at
  /// the first failed step — the steps after it may depend on it.
  ///
  /// The report is also recorded (see [PlaybookRunStore]) once it ends.
  ///
  /// [tasks] are the steps when the caller compiled them already (the apply
  /// page shows the plan before the run); otherwise they are compiled here.
  Future<ProvisioningReport> apply(
    String instance,
    Playbook playbook, {
    bool check = false,
    List<ProvisioningTask>? tasks,
    void Function(ProvisioningReport report)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final report = ProvisioningReport(
      playbook: playbook.name,
      instance: instance,
      check: check,
      tasks: tasks ?? compilePlaybook(playbook.content),
    );
    for (final task in report.tasks) {
      if (shouldStop?.call() ?? false) {
        report.stopped = true;
        break;
      }
      if (task.skipped) {
        report.results.add(TaskResult(task, TaskStatus.skipped, ''));
        onProgress?.call(report);
        continue;
      }
      TaskResult result;
      try {
        final out = await backend.runInInstance(
          instance,
          commandFor(task, check: check),
          timeout: task.timeout,
        );
        result = parseTaskOutput(task, out);
      } catch (error) {
        result = TaskResult(task, TaskStatus.failed, error.toString());
      }
      report.results.add(result);
      onProgress?.call(report);
      // A failed step stops an apply: the steps after it may build on it.
      // A check run changed nothing, so there is nothing to protect and the
      // rest of the plan is still worth previewing.
      if (result.status == TaskStatus.failed && !check) {
        report.stopped = true;
        break;
      }
    }
    // A run the user stopped is not a record of the instance's state.
    if (!report.stopped || report.failed) {
      await PlaybookRunStore.instance.record(report);
    }
    return report;
  }
}

/// The latest run of a playbook on an instance.
class PlaybookRun {
  const PlaybookRun({
    required this.playbook,
    required this.instance,
    required this.at,
    required this.check,
    required this.status,
    required this.ok,
    required this.changed,
    required this.failed,
    required this.skipped,
  });

  final String playbook;
  final String instance;
  final DateTime at;
  final bool check;
  final TaskStatus status;
  final int ok;
  final int changed;
  final int failed;
  final int skipped;

  Map<String, dynamic> toJson() => {
        'playbook': playbook,
        'instance': instance,
        'at': at.toIso8601String(),
        'check': check,
        'status': status.name,
        'ok': ok,
        'changed': changed,
        'failed': failed,
        'skipped': skipped,
      };

  factory PlaybookRun.fromJson(Map<String, dynamic> json) => PlaybookRun(
        playbook: json['playbook'] as String,
        instance: json['instance'] as String,
        at: DateTime.parse(json['at'] as String),
        check: json['check'] == true,
        status: _statusFromWord(json['status'] as String? ?? '') ??
            TaskStatus.failed,
        ok: (json['ok'] as num?)?.toInt() ?? 0,
        changed: (json['changed'] as num?)?.toInt() ?? 0,
        failed: (json['failed'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
      );
}

/// What each playbook was last applied to and how it went: one entry per
/// (playbook, instance) for applies and one for checks, newest run wins —
/// a later check never erases the record of the last real apply. This is what makes a playbook a
/// record of an instance's state rather than a script that was run once.
class PlaybookRunStore extends ChangeNotifier {
  PlaybookRunStore._();
  static final PlaybookRunStore instance = PlaybookRunStore._();

  static const String prefsKey = 'PlaybookRuns';

  final List<PlaybookRun> _runs = [];
  bool _loaded = false;

  /// Test seam for the clock.
  DateTime Function() now = DateTime.now;

  List<PlaybookRun> get runs {
    _load();
    return UnmodifiableListView(_runs);
  }

  /// The runs of [playbook], newest first. Runs are kept by instance name:
  /// an instance deleted and created again under the same name inherits the
  /// line until the playbook is applied to it (the delete paths live in
  /// files another change holds; see doc/playbooks.md).
  List<PlaybookRun> forPlaybook(String playbook) {
    _load();
    // Newest first. Two runs recorded within one clock tick — an apply and
    // a check back to back, or a coarse clock — keep the order they were
    // recorded in, the later one first; the sort alone would leave them as
    // it found them.
    final indexed = _runs
        .where((r) => r.playbook == playbook)
        .toList()
        .asMap()
        .entries
        .toList()
      ..sort((a, b) {
        final byTime = b.value.at.compareTo(a.value.at);
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return [for (final e in indexed) e.value];
  }

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final stored = prefs.getString(prefsKey);
    if (stored == null || stored.isEmpty) return;
    try {
      final list = jsonDecode(stored) as List;
      final parsed = <PlaybookRun>[];
      for (final e in list) {
        try {
          parsed.add(PlaybookRun.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // One unreadable record; the rest still count.
        }
      }
      _runs
        ..clear()
        ..addAll(parsed);
    } catch (_) {
      // Not a list: nothing recorded.
    }
  }

  Future<void> _persist() => prefs.setString(
      prefsKey, jsonEncode(_runs.map((e) => e.toJson()).toList()));

  Future<void> record(ProvisioningReport report) async {
    _load();
    _runs.removeWhere((r) =>
        r.playbook == report.playbook &&
        r.instance == report.instance &&
        r.check == report.check);
    _runs.add(PlaybookRun(
      playbook: report.playbook,
      instance: report.instance,
      at: now(),
      check: report.check,
      status: report.status,
      ok: report.count(TaskStatus.ok),
      changed: report.count(TaskStatus.changed),
      failed: report.count(TaskStatus.failed),
      skipped: report.count(TaskStatus.skipped),
    ));
    await _persist();
    notifyListeners();
  }

  /// Drops every run of [playbook] — it was deleted.
  Future<void> forgetPlaybook(String playbook) async {
    _load();
    final before = _runs.length;
    _runs.removeWhere((r) => r.playbook == playbook);
    if (_runs.length == before) return;
    await _persist();
    notifyListeners();
  }

  /// A rename keeps the history under the new name.
  Future<void> renamePlaybook(String from, String to) async {
    _load();
    var touched = false;
    for (var i = 0; i < _runs.length; i++) {
      if (_runs[i].playbook != from) continue;
      final r = _runs[i];
      _runs[i] = PlaybookRun(
        playbook: to,
        instance: r.instance,
        at: r.at,
        check: r.check,
        status: r.status,
        ok: r.ok,
        changed: r.changed,
        failed: r.failed,
        skipped: r.skipped,
      );
      touched = true;
    }
    if (!touched) return;
    await _persist();
    notifyListeners();
  }

  void reload() {
    _loaded = false;
    _runs.clear();
    notifyListeners();
  }
}
