// Making a distro's default user real, so `wsl` in any terminal opens as it.
//
// ## Why this file exists
//
// Upstream #268: a distro created here logs the user in as **root** when they
// type `wsl` in a Windows terminal, unlike one installed from PowerShell. The
// create flow did set the default user — but only as `[user] default` in
// `/etc/wsl.conf`, and that key is read once, when the distro boots. The
// create had just run `useradd` and `passwd` inside the distro, so it was
// still running when the key was written, and every `wsl` until the next idle
// shutdown kept the root session the app had left behind. The Settings
// dialog's `[user] default` box had the same gap for an existing distro.
//
// WSL has a second, immediate mechanism for the same setting:
// `wsl --manage <distro> --set-default-user <user>` writes the distro's
// `DefaultUid` in the registry and applies to the next session without a
// restart (`basic-commands.md`, WSL 2.5+). This service uses both — the
// registry when the installed WSL has `--manage`, and otherwise the config
// key followed by a `--terminate`, which is what makes the key be re-read.
//
// The user-exists check is not politeness. `[user] default` naming an account
// the distro does not have stops it from starting at all, which is strictly
// worse than the root shell it was meant to replace — `create_dialog.dart`
// already refused to write the key on the path where `useradd` had failed,
// for exactly that reason. Reading `/etc/passwd` answers that question and
// the home directory in one pass, without a shell: Alpine's minirootfs has no
// `bash`, which is the shell every in-distro command here would otherwise
// use.

import 'package:wsl2distromanager/api/wsl.dart';

/// How a default-user change ended.
enum DefaultUserStatus {
  /// In place for the next `wsl`, with no further action from the user.
  applied,

  /// Written, but the distro has to stop before WSL reads it. Only reachable
  /// on a WSL without `--manage` whose `--terminate` also failed.
  needsRestart,

  /// The name is not a POSIX user name this app will write anywhere.
  invalidName,

  /// `/etc/passwd` was readable and has no such account.
  noSuchUser,

  /// The distro could not be reached, or refused every write.
  failed,
}

/// What [DefaultUserService.setDefaultUser] did.
class DefaultUserResult {
  const DefaultUserResult(
    this.status, {
    this.home,
    this.viaManage = false,
    this.restarted = false,
  });

  final DefaultUserStatus status;

  /// The account's home directory as `/etc/passwd` spells it, which is not
  /// always `/home/<user>` — `adduser -D` on Alpine and a pre-existing system
  /// account both land elsewhere. Null when it could not be read.
  final String? home;

  /// The registry path (`--manage --set-default-user`) took the change.
  final bool viaManage;

  /// The distro was terminated so that `/etc/wsl.conf` is read again.
  final bool restarted;

  bool get ok =>
      status == DefaultUserStatus.applied ||
      status == DefaultUserStatus.needsRestart;
}

/// One account line of `/etc/passwd`.
class PasswdEntry {
  const PasswdEntry(this.name, this.uid, this.home, this.shell);

  final String name;
  final int uid;
  final String home;
  final String shell;
}

/// Parse `/etc/passwd`, skipping anything that is not a seven-field line.
///
/// Comments are not part of the format, but `#` lines are tolerated in the
/// wild and a distro with a broken line in there still has good ones after it.
List<PasswdEntry> parsePasswd(String text) {
  final entries = <PasswdEntry>[];
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final fields = line.split(':');
    if (fields.length < 7) continue;
    final uid = int.tryParse(fields[2]);
    if (uid == null) continue;
    entries.add(PasswdEntry(fields[0], uid, fields[5], fields[6]));
  }
  return entries;
}

/// Sets the account `wsl -d <distro>` logs in as, by both documented routes.
///
/// Built around one [WSLApi] rather than a builder, because both call sites
/// already hold the instance their tests injected a shell into — and so does
/// the capability probe behind `--manage`, which [WSLApi.capabilities] keeps
/// per-instance exactly when the shell is a fake.
class DefaultUserService {
  const DefaultUserService(this._api);

  final WSLApi _api;

  /// `/etc/passwd` of [distro], or null when the distro could not be reached.
  Future<List<PasswdEntry>?> _accounts(String distro) async {
    final String? text = await _api.readDistroFile(distro, '/etc/passwd');
    if (text == null) return null;
    // An empty read is a distro whose `/etc/passwd` this app cannot see. That
    // is not "the account does not exist" — refusing there would take the
    // setting away from a distro that is merely unusual, so it reads as
    // "cannot verify" and the caller goes ahead.
    if (text.trim().isEmpty) return const <PasswdEntry>[];
    return parsePasswd(text);
  }

  /// The home directory of [user] in [distro], or null when it is not known.
  Future<String?> homeDirectory(String distro, String user) async {
    if (!WSLApi.isPlainUserName(user)) return null;
    final accounts = await _accounts(distro);
    if (accounts == null) return null;
    for (final account in accounts) {
      if (account.name == user) return account.home;
    }
    return null;
  }

  /// The `[user] default` currently written in [distro]'s `/etc/wsl.conf`.
  ///
  /// Null when there is no such line — which is the state that gives the root
  /// shell the upstream report is about — or when the file is unreadable.
  Future<String?> readDefaultUser(String distro) async {
    final conf = await _api.readWSLConf(distro);
    final value = conf?.get('user', 'default')?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Make [user] the account [distro] opens as, everywhere — the app's own
  /// terminals, `wsl -d <distro>`, and a bare `wsl` when it is the default
  /// distro.
  Future<DefaultUserResult> setDefaultUser(String distro, String user) async {
    if (!WSLApi.isPlainUserName(user)) {
      return const DefaultUserResult(DefaultUserStatus.invalidName);
    }

    final accounts = await _accounts(distro);
    if (accounts == null) {
      return const DefaultUserResult(DefaultUserStatus.failed);
    }
    String? home;
    if (accounts.isNotEmpty) {
      final match = accounts.where((a) => a.name == user);
      if (match.isEmpty) {
        return const DefaultUserResult(DefaultUserStatus.noSuchUser);
      }
      home = match.first.home;
    }

    return _apply(distro, user, home: home);
  }

  /// Put [distro] back to opening as root.
  ///
  /// Both halves, for the same reason [setDefaultUser] writes both: the
  /// registry `DefaultUid` outlives the config key, so dropping the
  /// `[user] default` line on its own would leave the distro still opening as
  /// a user no file mentions any more.
  Future<DefaultUserResult> clearDefaultUser(String distro) =>
      _apply(distro, null);

  /// [user] null means "remove the setting".
  Future<DefaultUserResult> _apply(String distro, String? user,
      {String? home}) async {
    // The config key first, because it is the one an `--export` carries with
    // the distro: the registry entry belongs to this machine's registration
    // and does not travel.
    final bool confOk = user == null
        ? await _api.removeSetting(distro, 'user', 'default')
        : await _api.setSetting(distro, 'user', 'default', user);

    bool viaManage = false;
    final capabilities = await _api.capabilities.load();
    if (capabilities.supportsManage) {
      // `--set-default-user` wants a name, and root is the name of uid 0 on
      // every distro this app can create.
      final output = await _api.manageSetDefaultUser(distro, user ?? 'root');
      viaManage = output.ok;
    }

    if (viaManage) {
      // The registry is authoritative for the next session, so the distro may
      // keep running: nothing is waiting on `/etc/wsl.conf` being re-read.
      // This is also the one path where a failed config write is not a failed
      // change — a distro with a read-only `/etc` still opens as [user].
      return DefaultUserResult(DefaultUserStatus.applied,
          home: home, viaManage: true);
    }

    if (!confOk) return const DefaultUserResult(DefaultUserStatus.failed);

    // Without `--manage`, `/etc/wsl.conf` is the only route and it is read at
    // boot. The distro is running — the read above started it if it was not —
    // so it has to stop before the next `wsl` means anything.
    try {
      await _api.stop(distro);
      return DefaultUserResult(DefaultUserStatus.applied,
          home: home, restarted: true);
    } catch (_) {
      // The value is on disk either way; only the moment it starts counting
      // moves out to whenever the distro next stops on its own.
      return DefaultUserResult(DefaultUserStatus.needsRestart, home: home);
    }
  }
}
