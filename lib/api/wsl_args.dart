// Canonical argument builders for every `wsl.exe` invocation that runs
// something *inside* a distro.
//
// ## Why this file exists
//
// `wsl.exe <options> <command…>` does **not** exec the command it is given.
// It re-joins its argv into a single string and hands that string to the
// distro's *default shell*, which parses it a second time — destroying one
// level of quoting. So `bash -c '<script>'` arrives inside the distro as:
//
// ```sh
// bash -c <first word of the script>   # a throwaway child process
// <the rest of the script>             # runs in the OUTER shell
// ```
//
// Measured live against a real distro on 2026-08-28:
// `bash -c 'X=hello; echo [$X]'` printed `[]`, because the assignment
// happened in the throwaway child, and `$BASH_EXECUTION_STRING` came back as
// `bash -c echo …` rather than the script. That is what made
// `AiWorkspaceService`'s status probe `_s=$(…)` permanently empty (so the
// `running` branch could never be taken for any tool), what silently defeated
// `set -o pipefail` on installs, and — when the command string contains a
// newline, so the outer shell's re-parse fails on its second line — what
// produced the user-reported `bash: -c: line 2: syntax error near unexpected
// token '2'`.
//
// The full write-up, with two runnable reproductions, is in
// `.maestro/playbooks/2026-08-28-WSL-Manager-Backlog-Audit/Working/`.
//
// ## The rule
//
// **Never rely on wsl.exe's default-shell re-parse.** Every in-distro
// invocation goes through one of the two builders below:
//
// * [wslExecArgs] when you have real argv — it reaches the distro intact.
// * [wslShellArgs] when you have a shell *script* (pipes, `;`, `&&`, `>>`,
//   `$(…)`, quoting) — it is handed to `bash -c` as one argument.
//
// Splitting a command string yourself and appending the pieces (the old
// `splitShellArgs()` + `wsl -d X <pieces…>` pattern) is the worst of both:
// the split strips the quotes, and the re-join then feeds the unquoted result
// to a shell. `echo 'u ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/x` came out
// the other side as a bash syntax error on the bare `(`.
//
// The only invocations that legitimately skip these builders are the ones
// with **no** in-distro command at all — `wsl -d X -u root` for an
// interactive stdin-driven shell ([WSLApi.startShell], [WSLApi.execCmds]),
// terminal launches that deliberately want the default shell (`start()`
// appends `;/bin/sh` to keep the window open), and host-level management
// verbs (`--list`, `--import`, `--terminate`, `--mount`, …), where `--exec`
// is not even valid.

/// The `wsl.exe` option that skips the distro's default shell and execs the
/// remaining argv directly. `-e` is the short spelling; `--shell-type none`
/// behaves identically but is newer and less widely supported.
const String kWslExecFlag = '--exec';

List<String> _distroPrefix(String distro, String? user) => [
      '-d',
      distro,
      if (user != null && user.isNotEmpty) ...['-u', user],
    ];

/// Arguments for running [argv] inside [distro], with argv preserved exactly.
///
/// Use this when there is nothing to interpret — a program and its
/// parameters. No shell runs inside the distro at all, so metacharacters in
/// [argv] are literal, which is what you want for values that came from user
/// input or a path.
///
/// Pass [user] to run as somebody other than the distro's default user.
List<String> wslExecArgs(String distro, List<String> argv, {String? user}) {
  return [
    ..._distroPrefix(distro, user),
    kWslExecFlag,
    ...argv,
  ];
}

/// Arguments for running the shell [script] inside [distro] through
/// `bash -c` (or [shell]).
///
/// [script] is passed as a *single* argument, so it may contain anything a
/// shell understands. Do not pre-split it.
///
/// Shell-quoting note that keeps biting: because this ends up in
/// `Process.run(..., runInShell: false)`, a double quote inside [script]
/// reaches bash literally. Prefer single quotes in the scripts you build.
///
/// Pass `shell: 'sh'` for anything the app runs against a distro it did not
/// choose. `bash` is not in the base image of every catalogue entry — Alpine's
/// minirootfs has none, and `--exec bash -c …` there fails outright with
/// `execvpe(bash) failed: No such file or directory`. Only scripts aimed at a
/// distro this app installed itself (the AI workspace) may assume bash.
List<String> wslShellArgs(
  String distro,
  String script, {
  String? user,
  String shell = 'bash',
}) {
  return wslExecArgs(distro, [shell, '-c', script], user: user);
}

/// In-distro paths this app is willing to interpolate into a shell script.
///
/// Absolute, and built only from characters no shell interprets — no space,
/// no quote, no `$`, no `;`. [wslShellArgs] hands its script to `bash -c`, so
/// a path that reaches it unquoted is code; `/etc/wsl.conf; rm -rf /` would
/// be two commands. Every path this app writes to (`/etc/wsl.conf`,
/// `/etc/wsl-distribution.conf`, `/etc/oobe.sh`) matches, so the guard costs
/// nothing and closes the one hole the base64 payload encoding does not:
/// the payload is safe, the *destination* was not.
///
/// A path that fails this is not quoted-and-passed — it is refused. There is
/// no legitimate caller with a space in an `/etc` path, and a guard that
/// silently rewrites its input is harder to reason about than one that says no.
bool isPlainDistroPath(String path) =>
    RegExp(r'^/[A-Za-z0-9._/-]+$').hasMatch(path);
