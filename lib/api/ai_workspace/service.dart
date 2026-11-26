// Install/start/status lifecycle for the AI Workspace tools. Every command
// runs inside the dedicated [kAiWorkspaceDistro] Ubuntu distro.

import 'dart:async';
import 'dart:io'
    show InternetAddress, Process, ServerSocket, SocketException;

import 'package:dio/dio.dart';
import 'package:localization/localization.dart';

import '../../components/helpers.dart';
import '../../components/notify.dart';
import '../cancellation.dart';
import '../execution/broker.dart';
import '../execution/models.dart';
import 'runtime.dart';

/// The dedicated WSL distro name used for AI workspace tools.
const String kAiWorkspaceDistro = 'ai-workspace';

/// Printed by the status probe when dockerd never became reachable. Distinct
/// from "missing" so an unavailable daemon is never mistaken for an
/// uninstalled tool.
const String _kDockerDownMarker = 'dockerdown';

/// Blocks until dockerd answers, up to ~20s. `service docker start` returns as
/// soon as the init script forks, well before the socket exists, so anything
/// that talks to Docker has to wait for this first.
/// No `$(seq ...)` and no subshell parentheses: both got mangled on the way
/// through the Windows command line into `wsl.exe`, surfacing as
/// `bash: -c: line 2: syntax error near unexpected token '2'`. Root cause
/// found 2026-08-28 — `wsl.exe` re-ran the flattened command through the
/// distro's default shell; see the `--exec` note in wsl_args.dart. The explicit
/// list is kept because it costs nothing and works under either form.
const String _kDockerWaitLoop = 'for _i in $_kWaitIterations; do '
    'docker info >/dev/null 2>&1 && break; sleep 1; done; ';

/// Twenty iterations, shared by every wait loop here. Spelled out for the
/// reason given on [_kDockerWaitLoop].
const String _kWaitIterations =
    '1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20';

/// Ports the long-running servers bind. Referenced by their status probe,
/// their start gate and [ToolConfig.port], so they get a name rather than
/// three literals.
const int _kHermesPort = 9119;
const int _kOpenClawPort = 18789;

/// OpenCode picks a *random* free port when `--port` is omitted (its flag
/// default is 0), so the card could never know where to look. This is the
/// port the project's own docs use in every example, and it is passed
/// explicitly on every start.
const int _kOpenCodePort = 4096;

/// Shell condition, true when something is accepting TCP connections on
/// [port] inside the distro.
///
/// This replaced `pgrep` for both gateways, which proved only that a process
/// exists: OpenClaw's gateway stays alive after a failed bind and Hermes'
/// launcher exits 0 while its gateway is already dead, so a card read
/// "running" against a port that refused every connection.
///
/// `ss` (iproute2) is the primary probe; the `/dev/tcp` fallback stops an
/// image without iproute2 from reporting every tool as stopped forever. The
/// port is anchored — a bare `grep -q 18789` also matches `:187890` and any
/// other column that happens to contain those digits.
///
/// Single quotes only: `runInShell: false` means a `"` reaches bash literally.
String _listeningTest(int port) =>
    '{ ss -ltn 2>/dev/null | grep -qE \':$port([^0-9]|\$)\' '
    '|| (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; }';

/// [ToolConfig.statusCheck] for a tool whose health is "is the port serving".
String _listeningStatusCheck(int port) =>
    '${_listeningTest(port)} && echo running || echo stopped';

/// Gives a just-started gateway ~20s to bind. Both gateways exist for seconds
/// before they listen, so the command that starts them has to wait or its exit
/// code says nothing about whether the service came up.
String _waitForPort(int port) =>
    'for _i in $_kWaitIterations; do ${_listeningTest(port)} && break; '
    'sleep 1; done; ';

/// The mirror of [_waitForPort]: gives a stopped service ~20s to let go of
/// [port], then answers whether it actually did.
///
/// A kill that matched nothing exits 0 exactly like one that killed the
/// service, and `docker stop` is followed by `|| true`, so the exit code of a
/// stop command says nothing at all. Measured 2026-08-28: the Hermes card
/// flipped to "stopped" while the process was still running and still
/// listening on 9119. The port is the same authority [_listeningStatusCheck]
/// already uses to decide the card's status, so a stop that does not free it
/// has not stopped anything.
String _waitForPortClosed(int port) =>
    'for _i in $_kWaitIterations; do ${_listeningTest(port)} || break; '
    'sleep 1; done; ! ${_listeningTest(port)}';

/// `pgrep -f` patterns for the two long-running services. The leading bracket
/// is the classic self-match guard — `[h]ermes` is eight literal characters
/// that do not contain the substring `hermes`, so the pattern cannot match the
/// process carrying it. See [_killByPattern] for why that is not enough.
///
/// `serve`, not `gateway`: `hermes gateway` is the *messaging* gateway
/// (Telegram/Discord/WhatsApp) and binds no TCP port at all. The process that
/// listens on [_kHermesPort] is `hermes serve`, so a pattern aimed at
/// `gateway` matched nothing the card cares about — Stop reported success over
/// a service that kept serving (measured 2026-08-28).
const String _kHermesPattern = '[h]ermes.*serve';
const String _kOpenClawPattern = '[o]penclaw';

/// Same idiom for OpenCode. Left broad rather than anchored on the `web`
/// subcommand, like [_kOpenClawPattern]: the workspace distro is dedicated to
/// these tools, so anything running `opencode` in it is this card's, and a
/// narrower pattern would miss a helper the server left behind while the
/// port-closed check kept waiting for it.
const String _kOpenCodePattern = '[o]pencode';

/// Kills every process whose command line matches [pattern], without killing
/// the shell that is running the kill.
///
/// This replaced `pkill -f`, which matches the *full command line* — and the
/// `bash -c '<script>'` doing the killing carries the entire script as its own
/// argv. The bracket idiom shields the pattern itself but nothing else in the
/// string, and three commands here mention their tool a second time,
/// unbracketed: `setsid hermes gateway` in Hermes' start, `openclaw gateway
/// stop` in OpenClaw's stop, and the `rm`/`npm uninstall` lines in OpenClaw's
/// uninstall. Measured against the real distro on 2026-08-28, `pkill`
/// signalled its own shell in all three: Hermes never reached its `setsid`
/// line at all, OpenClaw's Stop always returned non-zero — with empty stderr,
/// because a signalled shell writes nothing — and its uninstall died before
/// removing anything.
///
/// `pkill` has no "skip my own process tree" flag, so the filtering happens in
/// the shell: `pgrep` lists the candidates and `$$`/`$PPID` are dropped. Keep
/// it a single `pgrep` with no pipeline — a pipeline forks a subshell that
/// inherits the matching command line and becomes a target itself. The
/// trailing `true` preserves the `|| true` exit status the callers relied on.
///
/// Single quotes only: `runInShell: false` means a `"` reaches bash literally.
String _killByPattern(String pattern) =>
    'for _p in \$(pgrep -f \'$pattern\'); do '
    '[ \$_p = \$\$ ] || [ \$_p = \$PPID ] || kill \$_p; '
    'done 2>/dev/null; true';

/// Supported AI workspace tools.
enum AiWorkspaceTool { hermesAgent, openClaw, openWebUi, openCode }

/// How long an install may print nothing at all before it is abandoned.
///
/// Measured live on 2026-08-28 against the real `ai-workspace` distro: a cold
/// Hermes install takes 482s end to end and spends 306s of that inside a
/// single `npm install --silent` whose output the installer redirects into a
/// temp file, so nothing reaches us at all unless it fails. That step carries
/// its own 600s cap, and Ubuntu 26.04 additionally trips the installer's
/// `playwright_host_unrecognized()` path, which retries a second long
/// download step. Any silence budget under 600s therefore kills a healthy
/// install — which is exactly what the old 5-minute *wall-clock* cap did,
/// always mid-npm, leaving a half-built tree and no `hermes` binary behind.
const Duration _kInstallSilenceTimeout = Duration(minutes: 12);

/// Absolute ceiling, so an installer that wedges while still dribbling output
/// cannot run forever. Room for two cold Hermes installs and then some.
const Duration _kInstallMaxDuration = Duration(minutes: 45);

/// How much of each stream is kept for the failure message. npm and
/// Playwright logs run to megabytes and only the tail is ever shown.
const int _kOutputTailLimit = 8192;

/// Keeps the last [_kOutputTailLimit] characters of a stream.
String _appendTail(String tail, String text) {
  final merged = tail + text;
  if (merged.length <= _kOutputTailLimit) return merged;
  return merged.substring(merged.length - _kOutputTailLimit);
}

/// Duration as it reads in an error message. Minutes in production, smaller
/// units so a test with a sub-minute budget does not report `0 min`.
String _describeDuration(Duration duration) {
  if (duration.inMinutes >= 1) return '${duration.inMinutes} min';
  if (duration.inSeconds >= 1) return '${duration.inSeconds} s';
  return '${duration.inMilliseconds} ms';
}

/// One piece of streamed output, and how it ended.
class _OutputSegment {
  final String text;

  /// Ended in a bare `\r`, so it is a progress-bar frame the terminal was
  /// about to overwrite rather than a line the tool meant to leave behind.
  final bool transient;

  const _OutputSegment(this.text, {required this.transient});
}

/// Splits streamed process output into segments, carrying an unterminated
/// tail over to the next chunk.
///
/// `\r` ends a segment just as `\n` does: installers draw their download
/// progress with carriage returns, and each redraw is the freshest thing there
/// is to show. It does *not* end a line, though — the frame that happens to be
/// on screen when an installer goes quiet is a fragment of a redraw, not a
/// sentence, and quoting it back as "last output" produced the unreadable
/// `Last output: (O) 2. No` on a failed install (measured 2026-08-28). Hence
/// [_OutputSegment.transient]: worth showing live, never worth keeping.
class _LineAssembler {
  String _partial = '';

  List<_OutputSegment> add(String text) {
    final segments = <_OutputSegment>[];
    final buffer = _partial + text;
    var start = 0;
    var i = 0;
    while (i < buffer.length) {
      final char = buffer[i];
      if (char != '\n' && char != '\r') {
        i++;
        continue;
      }
      var transient = char == '\r';
      var next = i + 1;
      // `\r\n` is one line end, not a redraw followed by an empty line. A `\r`
      // at the very end of the chunk is read as a redraw without waiting for
      // the next chunk to confirm it: holding the segment back would defeat
      // the whole point of streaming, since a progress bar writes exactly one
      // `\r`-terminated chunk per frame. Misreading a CRLF line split at the
      // CR costs one line its committed status, and this stream is a WSL pipe
      // that does no CRLF translation in the first place.
      if (transient && next < buffer.length && buffer[next] == '\n') {
        transient = false;
        next++;
      }
      final piece = buffer.substring(start, i).trim();
      if (piece.isNotEmpty) {
        segments.add(_OutputSegment(piece, transient: transient));
      }
      start = next;
      i = next;
    }
    _partial = buffer.substring(start);
    return segments;
  }

  /// Whatever is left unterminated when the stream closes. The stream ending
  /// is what commits it — nothing is coming to overwrite it.
  _OutputSegment? flush() {
    final rest = _partial.trim();
    _partial = '';
    return rest.isEmpty ? null : _OutputSegment(rest, transient: false);
  }
}

/// Receives one segment of streamed installer output. [transient] marks a
/// progress-bar frame — fine to render live, never kept as the retained "last
/// output". See [_LineAssembler].
typedef InstallOutputSink = void Function(
  String line, {
  required bool transient,
});

/// Status of a workspace tool instance.
///
/// [starting] is deliberately distinct from [running]: Open WebUI's container
/// reports `Up` about two minutes before it can answer, while alembic
/// migrations run — and probing or restarting it inside that window kills it
/// (measured 2026-08-27). Reporting it as [running] invites exactly that.
enum ToolStatus { notInstalled, stopped, starting, running, error }

/// Configuration for an AI workspace tool.
class ToolConfig {
  final String name;
  final String installCommand;
  final String startCommand;
  final String stopCommand;
  final String statusCheck;
  final int port;
  final String defaultInstallPath;

  /// Command that starts the tool's dashboard and prints its URL. Null when
  /// [port] alone is enough.
  final String? dashboardCommand;

  /// Second-stage probe, run only once [statusCheck] has said the tool is up.
  /// Must echo exactly one of `running`, `starting` or `stopped`. Null means
  /// "[statusCheck] is the whole answer" and up counts as running.
  ///
  /// This exists because a container being up is not the same as it serving:
  /// see [ToolStatus.starting].
  final String? healthCheck;

  const ToolConfig({
    required this.name,
    required this.installCommand,
    required this.startCommand,
    required this.stopCommand,
    required this.statusCheck,
    required this.port,
    required this.defaultInstallPath,
    this.dashboardCommand,
    this.healthCheck,
  });
}

/// Commands assume an Ubuntu environment (curl, bash, docker available).
final Map<AiWorkspaceTool, ToolConfig> _toolConfigs = {
  AiWorkspaceTool.hermesAgent: ToolConfig(
    name: 'Hermes Agent',
    // `--skip-setup` is the installer's own flag for this, and it is the only
    // one that works: `--non-interactive` gates `prompt_yes_no` but not the
    // setup wizard, which `main()` runs unconditionally and which reads from
    // `/dev/tty` directly. The wizard's own escape hatch is a failed
    // `(: </dev/tty)` probe — and under `wsl.exe` that probe *succeeds*, so
    // the wizard opened a terminal nobody was typing into and sat there.
    // Measured 2026-08-28: `hermes_cli.main setup` with `fd 0 -> /dev/tty`,
    // no I/O at all for 20 min, until the silence budget reaped it.
    installCommand:
        'curl -fsSL https://hermes-agent.nousresearch.com/install.sh '
        '| bash -s -- --non-interactive --skip-setup',
    // `serve`, not `gateway`: only `hermes serve` binds [_kHermesPort] — see
    // [_kHermesPattern]. `--skip-build` keeps the first start from running an
    // npm web build inside the two-minute start timeout.
    // setsid, not `nohup &`: the server survives this one-shot wsl call.
    // The trailing port wait is the real success check — the launcher exits 0
    // even if the server dies immediately, and a `pgrep` gate here reported
    // success for a process that never bound 9119.
    startCommand: '${_killByPattern(_kHermesPattern)}; '
        'mkdir -p \$HOME/.hermes; '
        'setsid hermes serve --skip-build </dev/null '
        '>>\$HOME/.hermes/serve.log 2>&1 & '
        'disown; ${_waitForPort(_kHermesPort)}${_listeningTest(_kHermesPort)}',
    // Ask first, then insist, then check — the same shape as OpenClaw's stop.
    // `hermes serve --stop` is the CLI's own shutdown; the kill is the
    // backstop for a server it has lost track of, and the port test is the
    // only thing that actually decides the exit code.
    stopCommand: 'hermes serve --stop >/dev/null 2>&1; '
        '${_killByPattern(_kHermesPattern)}; '
        '${_waitForPortClosed(_kHermesPort)}',
    // A live process proves nothing — see [_listeningTest].
    statusCheck: _listeningStatusCheck(_kHermesPort),
    port: _kHermesPort,
    defaultInstallPath: 'cmd://hermes',
    // No dashboardCommand on purpose. `hermes dashboard` *starts* a server on
    // the same fixed port and then blocks; it never prints a URL, so parsing
    // its output found nothing and the card said "No dashboard URL from:
    // hermes dashboard" after a 40s wait. The port is fixed and already
    // proven reachable from Windows, so [getUrl] is the whole answer.
  ),
  AiWorkspaceTool.openClaw: ToolConfig(
    name: 'OpenClaw',
    installCommand:
        'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard --no-prompt',
    // The gateway runs in a session of its own, like Hermes and OpenCode, not
    // as the systemd user unit `openclaw gateway restart` restarts. The
    // install is `--no-onboard`, so that unit never exists. On a fresh macOS
    // guest restart had nothing to restart and every Start failed
    // (bostrot/ai-tasks#70; 2026.9.4 says "Service unit not found"). A user
    // unit would also die with the SSH session, because root has no linger.
    // `gateway stop` goes first so a unit that *does* exist (an onboarded WSL
    // distro) lets go of the port instead of racing this one for it.
    // `gateway.mode local` is the one setting the gateway refuses to start
    // without, and `config set` writes the file when onboarding never did.
    // An auth block nobody configured gets a token persisted in it. Without
    // one, 2026.9.4 generates a runtime-only token that changes with every
    // restart and is written nowhere, so [dashboardCommand] finds no token
    // and the Control UI says "gateway token missing". The token is a letter
    // plus hex so `config set` can never parse it as a JSON5 number. Auth that
    // already exists, from onboarding or the user, is left as it is.
    // No `--bind` and no `--auth`: the config stays in charge, and with none
    // the gateway binds loopback, which is where every backend reaches it.
    // The wait is on the port, not the process: the gateway exists for
    // seconds before it ever listens, and stays alive after a bind that
    // failed outright.
    startCommand: 'openclaw gateway stop >/dev/null 2>&1; '
        '${_killByPattern(_kOpenClawPattern)}; '
        '${_waitForPortClosed(_kOpenClawPort)}; '
        'mkdir -p \$HOME/.openclaw; '
        'openclaw config set gateway.mode local >/dev/null 2>&1; '
        'openclaw config get gateway.auth >/dev/null 2>&1 || { '
        'openclaw config set gateway.auth.mode token >/dev/null 2>&1; '
        'openclaw config set gateway.auth.token '
        't\$(od -An -N24 -tx1 /dev/urandom | tr -d \' \\n\') '
        '>/dev/null 2>&1; }; '
        'setsid openclaw gateway run --port $_kOpenClawPort </dev/null '
        '>>\$HOME/.openclaw/gateway.log 2>&1 & '
        'disown; ${_waitForPort(_kOpenClawPort)}${_listeningTest(_kOpenClawPort)}',
    // The port-closed check, not the exit code, is what says it stopped.
    stopCommand: 'openclaw gateway stop >/dev/null 2>&1; '
        '${_killByPattern(_kOpenClawPattern)}; '
        '${_waitForPortClosed(_kOpenClawPort)}',
    // A live process proves nothing — it routinely runs without ever binding.
    statusCheck: _listeningStatusCheck(_kOpenClawPort),
    port: _kOpenClawPort,
    defaultInstallPath: 'cmd://openclaw',
    // `--no-open`: without it the CLI tries to launch a browser *inside* WSL
    // (there is none) and prints a plain URL, so the page we opened on Windows
    // loaded but its WebSocket to the gateway had no token and failed with
    // "connection not possible". `--no-open` prints the tokenised URL with the
    // auth details baked in, which is the one that actually connects.
    // `--no-open` alone is not enough: with no browser inside WSL the CLI
    // prints a *bare* URL and says (measured 2026-08-31) "Token auto-auth not
    // delivered. Append your gateway token … as a URL fragment with key
    // `token`" — so the page loaded but its WebSocket had no token and the
    // dashboard showed "unauthorized: gateway token missing". The second line
    // digs the token out of the config (the CLI's own `config get` redacts
    // it) and prints it on a marker line for [_runDashboardCommand] to append
    // as `#token=`.
    dashboardCommand: 'openclaw dashboard --no-open 2>&1; '
        'printf "GATEWAY_TOKEN:%s\\n" "\${OPENCLAW_GATEWAY_TOKEN:-\$(sed -n '
        "'s/.*\"token\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' "
        '~/.openclaw/openclaw.json 2>/dev/null | head -n1)}"',
  ),
  AiWorkspaceTool.openWebUi: ToolConfig(
    name: 'Open WebUI',
    // `docker rm -f` keeps this idempotent — a re-install must not fail with
    // "name already in use".
    installCommand:
        'docker pull ghcr.io/open-webui/open-webui:latest && docker rm -f open-webui >/dev/null 2>&1; docker run -d -p 8083:8080 --name open-webui ghcr.io/open-webui/open-webui:latest',
    startCommand:
        'docker start open-webui || (docker pull ghcr.io/open-webui/open-webui:latest && docker run -d -p 8083:8080 --name open-webui ghcr.io/open-webui/open-webui:latest)',
    // `|| true` keeps a missing container from being an error; the port check
    // that follows is what actually decides whether the stop worked.
    stopCommand: 'docker stop open-webui || true; ${_waitForPortClosed(8083)}',
    statusCheck:
        'docker ps --filter name=open-webui | grep -q Up && echo running || echo stopped',
    // `Up` is not `serving`: the container runs its alembic migrations for
    // ~2 minutes before the web server answers, and touching it in that
    // window kills it. Docker's own healthcheck is the only thing that knows
    // the difference.
    // Single quotes around the Go template, never double: `runInShell: false`
    // means a `"` reaches bash literally and breaks the filter. `x$_h` rather
    // than a quoted comparison for the same reason — an image with no
    // HEALTHCHECK makes `docker inspect` fail and leaves `_h` empty, and an
    // empty answer is no evidence of a problem, so it falls through to
    // running.
    healthCheck:
        '_h=\$(docker inspect --format \'{{.State.Health.Status}}\' open-webui 2>/dev/null); '
        'if [ x\$_h = xstarting ]; then echo starting; '
        'elif [ x\$_h = xunhealthy ]; then echo stopped; '
        'else echo running; fi',
    port: 8083,
    defaultInstallPath: 'docker://open-webui',
  ),
  AiWorkspaceTool.openCode: ToolConfig(
    name: 'OpenCode',
    // `--no-modify-path` keeps the installer out of the distro's shell rc
    // files; the symlink is what actually puts the binary on PATH. It has to
    // be there rather than in `$HOME/.opencode/bin`, because every command
    // here runs through a *non-interactive* `bash -c` that sources nothing —
    // the `export PATH=...` line the installer would otherwise append to
    // `.bashrc` is never read, so `command -v opencode` (the `cmd://` check
    // behind this card's Installed state) would answer "missing" over a
    // perfectly good install. The installer hardcodes its own install dir and
    // offers no prefix flag, hence the symlink rather than an env var.
    // `hash -r` so a re-install inside the same shell does not keep a stale
    // path cached.
    // `SHELL` is defaulted because the installer reads `basename $SHELL`
    // *unconditionally*, above and outside the block `--no-modify-path`
    // turns off, and it runs under `set -u` — so on any environment that
    // reaches the distro without that variable the installer would abort on
    // an unbound variable before it downloaded anything.
    installCommand: 'curl -fsSL https://opencode.ai/install '
        '| SHELL=\${SHELL:-/bin/bash} bash -s -- --no-modify-path && '
        'ln -sf \$HOME/.opencode/bin/opencode /usr/local/bin/opencode && '
        'hash -r',
    // `web`, not `serve`: both start the same HTTP server, but only `web`
    // serves the browser interface this card's "Open Dashboard" opens.
    // `--port` is mandatory — see [_kOpenCodePort]. `--hostname 127.0.0.1` is
    // OpenCode's own default and is deliberately kept on every backend: the
    // server is unauthenticated unless `OPENCODE_SERVER_PASSWORD` is set.
    // WSL's localhost relay reaches a loopback bind from Windows, and on
    // macOS [AiWorkspaceService.getDashboardUrl] forwards the port instead
    // (bostrot/ai-tasks#70 tried binding 0.0.0.0 there first).
    // The browser `web` tries to open is harmless here — OpenCode swallows
    // that failure — but it has nothing to open inside the distro.
    // setsid + the trailing port wait for the same reasons as Hermes: the
    // server has to survive this one-shot call, and the launcher's exit code
    // says nothing about whether anything ever bound the port.
    startCommand: '${_killByPattern(_kOpenCodePattern)}; '
        'mkdir -p \$HOME/.opencode; cd \$HOME; '
        'setsid opencode web --port $_kOpenCodePort --hostname 127.0.0.1 '
        '</dev/null >>\$HOME/.opencode/web.log 2>&1 & '
        'disown; ${_waitForPort(_kOpenCodePort)}'
        '${_listeningTest(_kOpenCodePort)}',
    // No CLI shutdown verb of its own — `opencode web` runs until it is
    // signalled — so the kill is the whole stop, and the port-closed check is
    // what decides the exit code.
    stopCommand: '${_killByPattern(_kOpenCodePattern)}; '
        '${_waitForPortClosed(_kOpenCodePort)}',
    // A live process proves nothing — see [_listeningTest].
    statusCheck: _listeningStatusCheck(_kOpenCodePort),
    port: _kOpenCodePort,
    defaultInstallPath: 'cmd://opencode',
    // No dashboardCommand: `opencode web` *is* the dashboard, and it is
    // already running on a port this card fixed itself, so [getUrl] is the
    // whole answer.
  ),
};

/// State tracker for a single tool instance.
class ToolState {
  final AiWorkspaceTool tool;

  ToolStatus _status;

  ToolStatus get status => _status;

  /// The single reset point for [installPath]: a tool that is not installed
  /// cannot have one. Routing every assignment through this setter is what
  /// stops a card from reading "Not installed" while still showing
  /// `Installed: cmd://openclaw` underneath — the probe that downgrades a
  /// tool to [ToolStatus.notInstalled] used to leave the path from the last
  /// successful install behind. Callers set [installPath] *after* the status.
  set status(ToolStatus value) {
    _status = value;
    if (value == ToolStatus.notInstalled) {
      installPath = null;
    }
  }

  String? installPath;
  int port;
  DateTime? lastStarted;
  DateTime? lastStopped;
  String? errorMessage;

  /// A live WSL check completed this session — decides whether a background
  /// refresh is still owed.
  bool checked;

  /// [status] holds real information (live or cached) rather than the blank
  /// default — decides spinner vs. badge in the UI.
  bool hasKnownStatus;

  /// [status] and [errorMessage] describe a failed *user action* and belong to
  /// the user until they act again. [AiWorkspaceService.refreshStatus] leaves
  /// a sticky failure alone; without this the probe that follows a failed
  /// install replaces the reason with a bare "Not installed" before anyone
  /// can read it. Cleared by [AiWorkspaceService.clearError].
  bool errorSticky;

  ToolState({
    required this.tool,
    ToolStatus status = ToolStatus.notInstalled,
    this.installPath,
    required this.port,
    this.lastStarted,
    this.lastStopped,
    this.errorMessage,
    this.checked = false,
    this.hasKnownStatus = false,
    this.errorSticky = false,
  }) : _status = status {
    // The setter's invariant has to hold for a freshly built state too: a
    // persisted install path must not outlive a cached notInstalled.
    if (_status == ToolStatus.notInstalled) {
      installPath = null;
    }
  }
}

/// Checks whether [url] is actually serving requests yet. Injectable so
/// tests don't need a real HTTP stack.
typedef DashboardReachabilityChecker = Future<bool> Function(String url);

Future<bool> _defaultReachabilityCheck(String url) async {
  final dio = Dio();
  try {
    final response = await dio.get<void>(
      url,
      options: Options(
        sendTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        // Any response counts, 4xx/5xx included — we only care that
        // something is listening.
        validateStatus: (_) => true,
      ),
    );
    return response.statusCode != null;
  } catch (_) {
    return false;
  } finally {
    dio.close();
  }
}

/// Picks the port on this machine a port forward listens on, given the port
/// inside the workspace. Injectable so tests never bind a real socket.
typedef LocalPortPicker = Future<int> Function(int preferred);

/// [preferred] when it is free, so a dashboard keeps the port its docs name,
/// otherwise whatever the OS hands out. Another process can still take the
/// port between this probe closing and ssh binding it; vmctl's
/// `ExitOnForwardFailure` turns that into a forward that ends, loudly, rather
/// than one that silently serves nothing.
Future<int> _defaultPickLocalPort(int preferred) async {
  for (final port in [preferred, 0]) {
    try {
      final probe =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      final picked = probe.port;
      await probe.close();
      return picked;
    } on SocketException {
      // Taken; the OS-assigned port is next.
    }
  }
  throw const SocketException('No free local port for the forward');
}

/// One running port forward out of the workspace. See
/// [WorkspaceRuntime.portForward].
class _PortForward {
  _PortForward(this.process, this.remotePort, this.localPort);

  final Process process;
  final int remotePort;
  final int localPort;
  bool exited = false;

  /// The last of what the forward wrote to stderr, which is where ssh says
  /// why a forward failed.
  String stderrTail = '';

  /// [url] re-pointed at this forward's local end. Path and fragment are
  /// kept, OpenClaw's `#token=` among them. The host becomes `127.0.0.1`
  /// rather than `localhost`, because the forward listens on IPv4 only and
  /// `localhost` may resolve to `::1` first.
  String localUrl(String url) =>
      Uri.parse(url).replace(host: '127.0.0.1', port: localPort).toString();
}

/// Service for managing AI workspace tools.
class AiWorkspaceService {
  /// Whether a missing environment is created without asking. On by default;
  /// off means deleting the 'ai-workspace' distro sticks, and the page offers
  /// to set it up again instead (bostrot/wsl2-distro-manager#321).
  static const autoProvisionPrefKey = 'AiWorkspaceAutoProvision';

  /// The i18n key [ensureDistro] throws when the environment is missing and
  /// [autoProvision] is off.
  static const notProvisionedKey = 'ai-workspace-not-provisioned-text';

  static bool get autoProvision => prefs.getBool(autoProvisionPrefKey) ?? true;

  static Future<void> setAutoProvision(bool value) =>
      prefs.setBool(autoProvisionPrefKey, value);

  final ExecutionBroker _broker;
  final WorkspaceRuntime _runtime;
  final Map<AiWorkspaceTool, ToolState> _toolStates = {};
  final DashboardReachabilityChecker _isReachable;
  bool _distroReady = false;
  bool _dockerReady = false;

  // Installs outlive the screen that started them. Tracking them here — not
  // in the page's State — is what lets the UI show progress again after the
  // user navigates away and back, and stops a status refresh from
  // overwriting an install that is still running.
  final Set<AiWorkspaceTool> _installing = {};

  // Last line the running installer printed, per tool. Lives here for the
  // same reason [_installing] does: the progress an install has made must
  // still be there when the user comes back to the page.
  final Map<AiWorkspaceTool, String> _installProgress = {};

  // The same, minus the progress-bar frames. A redraw is the right thing to
  // show while it is redrawing and the wrong thing to leave frozen on a failed
  // card, so once the install is over this replaces [_installProgress].
  final Map<AiWorkspaceTool, String> _installLastLine = {};

  // How long each running install has been going. A Hermes install measured
  // six minutes with its one progress line frozen for two of them — 0 pixels
  // changed over 120 seconds — and a frozen line beside a ticking clock is at
  // least unambiguous (audit PS-18).
  final Map<AiWorkspaceTool, Stopwatch> _installElapsed = {};

  // Cancels a running install by killing its `wsl` child. There was no way
  // out of one at all: Install was a spinner and Start, Stop and Uninstall
  // were all disabled, so a wedged `curl | bash` could only be escaped by
  // killing the app (audit PS-18).
  final Map<AiWorkspaceTool, CancelSignal> _installCancels = {};

  // WSL shuts a distro down once its last session exits, which takes systemd
  // user services with it — measured: a started gateway is listening while a
  // session is held open and gone ~20s after the last one closes. Every action
  // here is its own one-shot `wsl` call, so without this the gateway is
  // already dead by the time "open dashboard" runs.
  Process? _keepAlive;

  // Port forwards out of a workspace that shares no loopback with this
  // machine, keyed by the port inside it. Held here for the same reason as
  // [_keepAlive]: the dashboard tab keeps using one long after the call that
  // opened it has returned.
  final Map<int, _PortForward> _forwards = {};
  final Map<int, Future<_PortForward>> _openingForwards = {};
  final LocalPortPicker _pickLocalPort;

  /// How long an install may go silent before it is abandoned, and its
  /// absolute ceiling. Injectable so tests can exercise both without waiting
  /// out the real budgets.
  final Duration _installSilenceTimeout;
  final Duration _installMaxDuration;

  AiWorkspaceService({
    required ExecutionBroker broker,
    WorkspaceRuntime? runtime,
    DashboardReachabilityChecker? reachabilityChecker,
    Duration? installSilenceTimeout,
    Duration? installMaxDuration,
    LocalPortPicker? localPortPicker,
  })  : _broker = broker,
        _runtime = runtime ?? workspaceRuntimeBuilder(),
        _isReachable = reachabilityChecker ?? _defaultReachabilityCheck,
        _pickLocalPort = localPortPicker ?? _defaultPickLocalPort,
        _installSilenceTimeout =
            installSilenceTimeout ?? _kInstallSilenceTimeout,
        _installMaxDuration = installMaxDuration ?? _kInstallMaxDuration;

  Map<AiWorkspaceTool, ToolState> get toolStates =>
      Map.unmodifiable(_toolStates);

  ToolState? getState(AiWorkspaceTool tool) => _toolStates[tool];

  /// True while [install] is still running for [tool], including across a
  /// navigation away from the AI Workspace page.
  bool isInstalling(AiWorkspaceTool tool) => _installing.contains(tool);

  /// The most recent line the installer printed for [tool], or null when it
  /// has not printed anything yet. Kept after the install ends so a failure
  /// card can still show where it got to.
  String? installProgress(AiWorkspaceTool tool) => _installProgress[tool];

  /// How long [tool]'s install has been running, or null when none is.
  ///
  /// Read once a second by the card. The clock, not the streamed line, is what
  /// tells a slow install from a wedged one.
  Duration? installElapsed(AiWorkspaceTool tool) =>
      _installElapsed[tool]?.elapsed;

  /// Stops a running install for [tool] by killing its `wsl` child.
  ///
  /// Safe to call when nothing is running. The install itself reports the
  /// cancel, so this returns nothing.
  void cancelInstall(AiWorkspaceTool tool) => _installCancels[tool]?.cancel();

  /// True while [tool]'s install can still be stopped.
  bool canCancelInstall(AiWorkspaceTool tool) =>
      _installCancels.containsKey(tool);

  /// Holds one WSL session open so long-running tools survive between the
  /// one-shot calls that start, probe and use them. Safe to call repeatedly.
  Future<void> ensureKeepAlive() async {
    if (_keepAlive != null) return;
    final request = _runtime.keepAlive();
    // Some runtimes (a VM) keep services alive on their own.
    if (request == null) return;
    try {
      _keepAlive = await _broker.startPersistent(request);
      // If the session drops, forget the handle so the next call retries.
      unawaited(_keepAlive!.exitCode.then((_) => _keepAlive = null));
    } catch (_) {
      // A keep-alive is an optimisation, never a reason to fail the action.
      _keepAlive = null;
    }
  }

  /// Releases the held session and every port forward. The distro is then
  /// free to shut down.
  void dispose() {
    _keepAlive?.kill();
    _keepAlive = null;
    for (final forward in _forwards.values) {
      forward.process.kill();
    }
    _forwards.clear();
  }

  // -----------------------------------------------------------------------
  // Distro management
  // -----------------------------------------------------------------------

  /// Creates the distro if missing. With [forUninstall] it must already
  /// exist and the call fails instead, and with [autoProvision] off it
  /// throws [notProvisionedKey] so the user decides via [setUpEnvironment].
  Future<void> ensureDistro({bool forUninstall = false}) async {
    if (_distroReady) return;

    if (await _runtime.exists(_broker)) {
      _distroReady = true;
      return;
    }

    if (forUninstall) {
      throw Exception(
          'AI workspace environment is not installed. Cannot uninstall.');
    }

    if (!autoProvision && _runtime.provisionCreates) {
      throw Exception(notProvisionedKey);
    }

    await _runtime.provision(_broker,
        notify: (key) => Notify.message(key.i18n(), loading: true));
    _distroReady = true;
  }

  /// The user-confirmed workspace setup: unlike [ensureDistro] it may do
  /// heavy work (download an image, create and boot a VM). The page offers
  /// it when [ensureDistro] reports the environment missing.
  Future<void> setUpEnvironment() async {
    await _runtime.setUp(_broker,
        notify: (key) => Notify.message(key.i18n(), loading: true));
    _distroReady = true;
  }

  /// One-shot root command in the workspace environment, built by the active
  /// [WorkspaceRuntime].
  ExecutionRequest _req(String shellCommand, {Duration? timeout}) =>
      _runtime.script(shellCommand, timeout: timeout);

  /// Runs [shellCommand] in the workspace environment and hands back its
  /// result, provisioning the environment first if it is not ready.
  ///
  /// The entry point for everything that needs the workspace but is not a
  /// tool lifecycle action — [AiWorkspaceConfigService] reads and writes the
  /// tools' config files through it, so the runtime, the root user and the
  /// distro check stay in one place.
  Future<ExecutionResult> runInWorkspace(
    String shellCommand, {
    Duration? timeout,
  }) async {
    await ensureDistro();
    return _broker.run(_req(shellCommand, timeout: timeout));
  }

  /// Installs docker.io on first use — the base Ubuntu image has no Docker.
  Future<void> _ensureDockerReady() async {
    if (_dockerReady) return;

    Notify.message('ai-workspace-docker-setup-text'.i18n(), loading: true);
    // The daemon wait matters as much as the install: `service docker start`
    // returns before dockerd has a socket, and the `docker pull` that follows
    // this call would hit a daemon that is not up yet.
    const setupCommand = 'command -v docker >/dev/null 2>&1 || '
        '(apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io); '
        'service docker status >/dev/null 2>&1 || service docker start; '
        '$_kDockerWaitLoop'
        'docker info >/dev/null 2>&1';

    final result = await _broker.run(
        _req(setupCommand, timeout: const Duration(minutes: 5)));

    if (!result.isSuccess) {
      throw Exception(
          'Failed to prepare Docker in the AI workspace distro: ${result.stderr}');
    }
    _dockerReady = true;
  }

  /// Whether a failed probe says the environment itself is gone, which is
  /// a confirmed "not installed" for every tool in it.
  ///
  /// Only the two explicit answers count: WSL's untranslated error code
  /// (wsl.exe localizes the sentence around it, and writes it to stdout or
  /// stderr depending on the verb) and vmctl's own message for a VM that is
  /// not in the store. Anything else, such as a `command not found` from
  /// inside the distro or a start failure that names it, says nothing about
  /// the tool and must not be persisted as if it did.
  bool _indicatesMissingDistro(ExecutionResult result) {
    final text = '${result.stderr}\n${result.stdout}';
    return text.contains('WSL_E_DISTRO_NOT_FOUND') ||
        text.contains('No VM named "${_runtime.target}"');
  }

  // Last *confirmed* status per tool, persisted so the UI can show a real
  // answer at startup instead of a spinner. Written only from confirmed
  // results, never from a transient failure. Still just a cache —
  // [ensureInitialized] always re-verifies in the background.

  static String _statusPrefsKey(AiWorkspaceTool tool) =>
      'AiWorkspaceStatus_${tool.name}';
  static String _installPathPrefsKey(AiWorkspaceTool tool) =>
      'AiWorkspaceInstallPath_${tool.name}';

  void _persistConfirmedState(AiWorkspaceTool tool) {
    final state = _toolStates[tool];
    if (state == null) return;
    prefs.setString(_statusPrefsKey(tool), state.status.name);
    final installPath = state.installPath;
    if (installPath != null) {
      prefs.setString(_installPathPrefsKey(tool), installPath);
    } else {
      prefs.remove(_installPathPrefsKey(tool));
    }
  }

  ToolStatus? _loadCachedStatus(AiWorkspaceTool tool) {
    final raw = prefs.getString(_statusPrefsKey(tool));
    if (raw == null) return null;
    for (final status in ToolStatus.values) {
      if (status.name == raw) return status;
    }
    return null;
  }

  /// Creates tool state entries, seeded from the persisted cache.
  /// Synchronous — no WSL calls.
  void seedToolStates() {
    for (final tool in AiWorkspaceTool.values) {
      final config = _toolConfigs[tool]!;
      final cachedStatus = _loadCachedStatus(tool);
      _toolStates[tool] = ToolState(
        tool: tool,
        port: config.port,
        status: cachedStatus ?? ToolStatus.notInstalled,
        // A cached notInstalled drops the path in the constructor, so the
        // no-cache case needs no branch of its own.
        installPath: prefs.getString(_installPathPrefsKey(tool)),
        hasKnownStatus: cachedStatus != null,
      );
    }
  }

  /// Blocks until every tool has been probed. UI layers that want to render
  /// progressively should call [seedToolStates], [ensureDistro] and
  /// [refreshStatus] themselves instead.
  Future<void> init() async {
    seedToolStates();
    await ensureDistro();

    await Future.wait(AiWorkspaceTool.values.map(refreshStatus));
  }

  // -----------------------------------------------------------------------
  // Lifecycle operations
  // -----------------------------------------------------------------------

  /// Records a failed user action and makes it stick: [refreshStatus] will not
  /// touch this tool again until [clearError] runs. A failed install used to
  /// be erased by the very next background probe, which reported the tool as
  /// plain `notInstalled` with no message.
  /// What a failed action puts on the card. A command killed by a signal
  /// writes nothing to stderr of its own, which rendered a bare `Error:` with
  /// nothing after it — seen on Stop (fixed in Phase 02) and then on Start.
  static String _failureDetail(String? stderr, String fallback) {
    final detail = (stderr ?? '').trim();
    return detail.isEmpty ? fallback : detail;
  }

  void _recordActionFailure(AiWorkspaceTool tool, String? message) {
    final state = _toolStates[tool];
    if (state == null) return;
    state.status = ToolStatus.error;
    state.errorMessage = message;
    state.errorSticky = true;
  }

  /// Hands the tool back to the status probe after a sticky failure. Every
  /// explicit user action calls this — install, start, stop, and the UI's
  /// dismiss affordance. [status] falls back to the last *confirmed* answer
  /// rather than a guess, since an error is never cached.
  void clearError(AiWorkspaceTool tool) {
    // Every explicit user action routes through here, which makes it the one
    // place the previous action's residue belongs. Without it the install's
    // last line outlived the install: a *start* that failed rendered the card
    // with the *installer's* final output underneath it.
    _installProgress.remove(tool);
    _installLastLine.remove(tool);
    final state = _toolStates[tool];
    if (state == null) return;
    state.errorMessage = null;
    state.errorSticky = false;
    if (state.status != ToolStatus.error) return;
    final cached = _loadCachedStatus(tool);
    state.status = (cached == null || cached == ToolStatus.error)
        ? ToolStatus.notInstalled
        : cached;
  }

  /// Runs once a tool is installed, before [install] reports success, so
  /// whatever it does is done by the time the card offers Start. Set by
  /// `AiWorkspaceSharedSettingsService.attach` (bostrot/ai-tasks#81); a
  /// failure inside it is the hook's to report and never fails the install.
  Future<void> Function(AiWorkspaceTool tool)? onInstalled;

  /// The name a tool goes by on its card.
  String toolName(AiWorkspaceTool tool) => _toolConfigs[tool]!.name;

  /// Install a workspace tool.
  Future<bool> install(AiWorkspaceTool tool) async {
    if (_installing.contains(tool)) return false;
    // An explicit retry owns the card again; the previous failure is history,
    // and so is the progress line the previous attempt left behind (dropped by
    // clearError, which every user action goes through).
    clearError(tool);
    _installing.add(tool);
    _installElapsed[tool] = Stopwatch()..start();
    try {
      return await _install(tool);
    } finally {
      _installing.remove(tool);
      _installElapsed.remove(tool);
      _installCancels.remove(tool);
      // The install is over, so nothing is going to redraw the progress-bar
      // frame that may be sitting in _installProgress. Fall back to the last
      // line the installer actually committed, which is what a failed card
      // quotes back at the user.
      final committed = _installLastLine[tool];
      if (committed != null) _installProgress[tool] = committed;
    }
  }

  Future<bool> _install(AiWorkspaceTool tool) async {
    await ensureDistro();
    final config = _toolConfigs[tool]!;

    if (tool == AiWorkspaceTool.openWebUi) {
      try {
        await _ensureDockerReady();
      } catch (e) {
        _recordActionFailure(tool, e.toString());
        // The card carries the reason; the status bar only has to stop
        // spinning on the setup step that just failed.
        Notify.message('');
        return false;
      }
    }

    Notify.message(
      (tool == AiWorkspaceTool.openWebUi
              ? 'ai-workspace-pulling-image-text'
              : 'ai-workspace-installing-text')
          .i18n([config.name]),
      loading: true,
    );

    final cancelSignal = CancelSignal();
    _installCancels[tool] = cancelSignal;
    try {
      final result = await _runStreamed(
        // pipefail: `curl ... | sh` otherwise exits 0 even when curl fails.
        'set -o pipefail; ${config.installCommand}',
        silenceTimeout: _installSilenceTimeout,
        maxDuration: _installMaxDuration,
        cancelSignal: cancelSignal,
        onLine: (line, {required transient}) {
          _installProgress[tool] = line;
          if (!transient) _installLastLine[tool] = line;
        },
      );
      if (cancelSignal.isCancelled) {
        // The user stopped it; that is not a failure to report as one. The
        // card goes back to whatever it knew before the attempt.
        clearError(tool);
        _toolStates[tool]?.status = ToolStatus.notInstalled;
        Notify.message('ai-workspace-install-cancelled-text'.i18n([config.name]),
            severity: InfoBarSeverity.warning);
        return false;
      }
      if (result.isSuccess) {
        final state = _toolStates[tool];
        state?.status = ToolStatus.stopped;
        state?.installPath = config.defaultInstallPath;
        state?.errorMessage = null;
        state?.errorSticky = false;
        state?.checked = true;
        state?.hasKnownStatus = true;
        _persistConfirmedState(tool);
        Notify.message('ai-workspace-install-success-text'.i18n([config.name]),
            severity: InfoBarSeverity.success);
        final hook = onInstalled;
        if (hook != null) {
          try {
            await hook(tool);
          } catch (_) {
            // The tool is installed either way.
          }
        }
        return true;
      } else {
        _recordActionFailure(
          tool,
          _failureDetail(result.stderr,
              'ai-workspace-install-failed-text'.i18n([config.name])),
        );
        Notify.message('ai-workspace-install-failed-text'.i18n([config.name]),
            severity: InfoBarSeverity.error);
        return false;
      }
    } catch (e) {
      _recordActionFailure(tool, e.toString());
      Notify.message('ai-workspace-install-failed-text'.i18n([config.name]),
          severity: InfoBarSeverity.error);
      return false;
    }
  }

  /// Runs [script] in the distro with its output streamed back line by line
  /// through [onLine], and gives up only after [silenceTimeout] with nothing
  /// new on either stream — not after a fixed wall clock.
  ///
  /// [ExecutionBroker.run] can express only the latter, which is why this
  /// exists: by total runtime alone a slow-but-progressing install looks
  /// exactly like a hung one, and a Hermes install measured at 482s cold was
  /// being killed at 300s every time. [maxDuration] is the backstop for an
  /// installer that wedges while still dribbling output.
  ///
  /// The handle comes from [ExecutionBroker.startPersistent], so the child is
  /// ours to reap — every abandon path runs it through
  /// [ExecutionBroker.terminate] rather than leaving an orphaned `wsl.exe`
  /// behind.
  Future<ExecutionResult> _runStreamed(
    String script, {
    required Duration silenceTimeout,
    required Duration maxDuration,
    required InstallOutputSink onLine,
    CancelSignal? cancelSignal,
  }) async {
    final stopwatch = Stopwatch()..start();
    final process = await _broker.startPersistent(
      _req(script),
    );

    var stdoutTail = '';
    var stderrTail = '';
    String? abandonReason;
    // Only committed lines, never progress-bar frames — see [_LineAssembler].
    String? lastLine;
    Timer? silenceTimer;
    Timer? ceilingTimer;

    void abandon(String reason) {
      if (abandonReason != null) return;
      abandonReason = reason;
      silenceTimer?.cancel();
      ceilingTimer?.cancel();
      unawaited(ExecutionBroker.terminate(process));
    }

    void resetSilence() {
      if (abandonReason != null) return;
      silenceTimer?.cancel();
      silenceTimer = Timer(
        silenceTimeout,
        () => abandon(
          'Nothing was printed for '
          '${_describeDuration(silenceTimeout)}, so the command was '
          'stopped.',
        ),
      );
    }

    ceilingTimer = Timer(
      maxDuration,
      () => abandon(
        'Still running after ${_describeDuration(maxDuration)}, '
        'so the command was stopped.',
      ),
    );
    // A user cancel takes the same route as a timeout — the child has to be
    // reaped either way — and the caller tells the two apart by asking the
    // token, not by reading the reason back out of the result.
    cancelSignal?.onCancel(() => abandon('Stopped at your request.'));
    resetSilence();

    final drained = <Future<void>>[];
    final subscriptions = <StreamSubscription<List<int>>>[];

    void attach(Stream<List<int>> stream, {required bool isError}) {
      final assembler = _LineAssembler();
      final done = Completer<void>();
      drained.add(done.future);
      subscriptions.add(
        stream.listen(
          (data) {
            // The same UTF-16LE-with-null-bytes decode every other wsl.exe
            // reader does. Chunk boundaries are safe here: the payload is ASCII
            // installer output, not arbitrary text.
            final text = ExecutionBroker.decodeWslOutput(data);
            if (text.isEmpty) return;
            // Any byte at all is progress, whichever stream it arrived on —
            // installers report progress on stderr as readily as on stdout.
            resetSilence();
            if (isError) {
              stderrTail = _appendTail(stderrTail, text);
            } else {
              stdoutTail = _appendTail(stdoutTail, text);
            }
            for (final segment in assembler.add(text)) {
              if (!segment.transient) lastLine = segment.text;
              onLine(segment.text, transient: segment.transient);
            }
          },
          onDone: () {
            final rest = assembler.flush();
            if (rest != null) {
              lastLine = rest.text;
              onLine(rest.text, transient: false);
            }
            if (!done.isCompleted) done.complete();
          },
          onError: (Object _) {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        ),
      );
    }

    attach(process.stdout, isError: false);
    attach(process.stderr, isError: true);

    final exitCode = await process.exitCode;
    // A dead child's pipes close with it, but the wait is bounded anyway: a
    // stream that never closes must not hold the install open forever.
    await Future.wait(
      drained,
    ).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
    silenceTimer?.cancel();
    ceilingTimer.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    stopwatch.stop();

    final reason = abandonReason;
    if (reason == null) {
      return ExecutionResult(
        exitCode: exitCode,
        stdout: stdoutTail,
        stderr: stderrTail,
        duration: stopwatch.elapsed,
        auditSeverity: exitCode == 0 ? AuditSeverity.info : AuditSeverity.error,
      );
    }

    // The card shows this verbatim, so it has to say what happened and where
    // the command got to: a bare "install failed" over a killed process is
    // untraceable, and a killed shell writes nothing to stderr of its own.
    final detail = [
      lastLine == null ? reason : '$reason Last output: $lastLine',
      stderrTail.trim(),
    ].where((part) => part.isNotEmpty).join('\n');
    return ExecutionResult(
      // A process killed on a signal can still report 0 on some paths; the
      // abandon is the answer here, not the exit code.
      exitCode: exitCode == 0 ? -1 : exitCode,
      stdout: stdoutTail,
      stderr: detail,
      duration: stopwatch.elapsed,
      error: TimeoutException(reason, stopwatch.elapsed),
      auditSeverity: AuditSeverity.error,
    );
  }

  /// Start a running tool instance.
  Future<bool> start(AiWorkspaceTool tool) async {
    final state = _toolStates[tool];
    if (state == null || state.status == ToolStatus.notInstalled) {
      return false;
    }

    // An explicit start is a user action: it takes the card back from any
    // sticky failure left by the previous attempt.
    clearError(tool);

    await ensureDistro();
    // Must be held before the tool starts, or the distro tears the service
    // back down as soon as this call returns.
    await ensureKeepAlive();
    final config = _toolConfigs[tool]!;

    if (tool == AiWorkspaceTool.openWebUi) {
      try {
        await _ensureDockerReady();
      } catch (e) {
        _recordActionFailure(tool, e.toString());
        // The card carries the reason; the status bar only has to stop
        // spinning on the setup step that just failed.
        Notify.message('');
        return false;
      }
    }

    Notify.message('ai-workspace-starting-text'.i18n([config.name]),
        loading: true);

    final request = _req(config.startCommand,
        timeout: const Duration(minutes: 2));

    try {
      final result = await _broker.run(request);
      if (result.isSuccess) {
        state.status = ToolStatus.running;
        state.lastStarted = DateTime.now();
        state.errorMessage = null;
        state.errorSticky = false;
        state.checked = true;
        state.hasKnownStatus = true;
        _persistConfirmedState(tool);
        // The start command returning is not the tool serving. A tool with a
        // health gate has to be asked, or the card claims running for the
        // whole ~2 minute migration window and "Open Dashboard" walks the
        // user straight into the failure the gate exists to prevent.
        if (config.healthCheck != null) {
          await refreshStatus(tool);
        }
        // Announce what the gate found, not what was asked for. Notifying
        // before the re-probe put "Open WebUI is running" on screen next to a
        // card correctly reading "Starting up...".
        Notify.message(
            (state.status == ToolStatus.starting
                    ? 'ai-workspace-starting-text'
                    : 'ai-workspace-started-text')
                .i18n([config.name]),
            severity: state.status == ToolStatus.starting
                ? InfoBarSeverity.info
                : InfoBarSeverity.success);
        return true;
      } else {
        _recordActionFailure(
          tool,
          _failureDetail(result.stderr,
              'ai-workspace-start-failed-text'.i18n([config.name])),
        );
        Notify.message('ai-workspace-start-failed-text'.i18n([config.name]),
            severity: InfoBarSeverity.error);
        return false;
      }
    } catch (e) {
      _recordActionFailure(tool, e.toString());
      Notify.message('ai-workspace-start-failed-text'.i18n([config.name]),
          severity: InfoBarSeverity.error);
      return false;
    }
  }

  /// Stop a running tool instance.
  Future<bool> stop(AiWorkspaceTool tool) async {
    // Another explicit action — releases any sticky failure for this tool.
    clearError(tool);
    await ensureDistro();
    final config = _toolConfigs[tool]!;
    final request = _req(config.stopCommand,
        timeout: const Duration(minutes: 2));

    try {
      final result = await _broker.run(request);
      if (result.isSuccess) {
        _toolStates[tool]?.status = ToolStatus.stopped;
        _toolStates[tool]?.lastStopped = DateTime.now();
        _toolStates[tool]?.errorMessage = null;
        _toolStates[tool]?.checked = true;
        _toolStates[tool]?.hasKnownStatus = true;
        _persistConfirmedState(tool);
        return true;
      } else {
        // Stop has no toast of its own — the card's `Error:` line is the only
        // feedback — and the port-closed check that decides this exit code
        // writes nothing to stderr at all, so the fallback is the whole
        // message here more often than not.
        //
        // Through _recordActionFailure, not by assigning errorMessage: a bare
        // assignment left `status` on `running`, so the card showed a red
        // error line under a green "running" pill, and left the failure
        // non-sticky, so the next background probe silently erased it
        // (audit PS-32).
        _recordActionFailure(
          tool,
          _failureDetail(result.stderr,
              'ai-workspace-stop-failed-text'.i18n([config.name])),
        );
        return false;
      }
    } catch (e) {
      _recordActionFailure(tool, e.toString());
      return false;
    }
  }

  /// Uninstall a workspace tool.
  Future<bool> uninstall(AiWorkspaceTool tool) async {
    final state = _toolStates[tool];
    if (state != null && state.status == ToolStatus.running) {
      await stop(tool);
    }
    // Explicit action, and the closing refreshStatus() below would otherwise
    // be skipped while a sticky failure is showing.
    clearError(tool);

    try {
      await ensureDistro(forUninstall: true);
    } catch (e) {
      _toolStates[tool]?.errorMessage = e.toString();
      return false;
    }

    final config = _toolConfigs[tool]!;
    String uninstallCmd;
    if (config.defaultInstallPath.startsWith('docker://')) {
      final imageName = config.defaultInstallPath.substring('docker://'.length);
      uninstallCmd =
          'docker rm -f $imageName && docker rmi ghcr.io/open-webui/$imageName:latest';
    } else if (tool == AiWorkspaceTool.hermesAgent) {
      // No documented uninstall command — remove every known install root and
      // the launcher. The launcher matters: the installer writes
      // `<bindir>/hermes` as a 147-byte wrapper *script*, not a symlink into
      // the install root, so removing only the roots left it behind and
      // `command -v hermes` kept answering "exists". The card then read
      // "Installed" over a tool whose first line was
      // `venv/bin/python: No such file or directory`, with Install disabled —
      // the app could not get itself back to a clean state (measured
      // 2026-08-28). Both bin dirs: the installer picks by privilege.
      uninstallCmd = '${_killByPattern(_kHermesPattern)}; '
          'rm -rf \$HOME/.hermes /usr/local/lib/hermes-agent; '
          'rm -f /usr/local/bin/hermes \$HOME/.local/bin/hermes; hash -r';
    } else if (tool == AiWorkspaceTool.openClaw) {
      // Covers both install methods: git wrapper and global npm. The kill has
      // to survive its own command line here too — the `rm`/`npm` lines below
      // both name `openclaw` unbracketed, so a plain `pkill` took the shell
      // down before anything was removed.
      uninstallCmd = '${_killByPattern(_kOpenClawPattern)}; '
          'rm -f \$HOME/.local/bin/openclaw; '
          'npm uninstall -g openclaw >/dev/null 2>&1 || true; hash -r';
    } else if (tool == AiWorkspaceTool.openCode) {
      // Removal by hand rather than through the CLI's own `opencode
      // uninstall`: this file already carries the scar from a third-party
      // installer that opened `/dev/tty` behind a `--non-interactive` flag
      // and sat there until the timeout reaped it, and a subcommand that
      // wants to confirm before deleting is exactly the shape that goes
      // wrong unattended. The rm list is everything the install command
      // created plus the state the tool writes, so the CLI has nothing to
      // add.
      // `/usr/local/bin/opencode` in particular must go: a leftover launcher
      // is what kept `command -v hermes` answering "exists" over a dead
      // install, leaving the card reading "Installed" with Install disabled.
      // The kill has to survive its own command line: the lines below name
      // `opencode` unbracketed.
      uninstallCmd = '${_killByPattern(_kOpenCodePattern)}; '
          'rm -rf \$HOME/.opencode \$HOME/.local/share/opencode '
          '\$HOME/.cache/opencode \$HOME/.config/opencode; '
          'rm -f /usr/local/bin/opencode; hash -r';
    } else {
      uninstallCmd = 'rm -rf ${config.defaultInstallPath}';
    }

    final request = _req(uninstallCmd,
        timeout: const Duration(minutes: 2));

    try {
      final result = await _broker.run(request);
      if (result.isSuccess) {
        // Clears installPath too — see the ToolState.status setter.
        _toolStates[tool]?.status = ToolStatus.notInstalled;
      } else {
        _toolStates[tool]?.errorMessage = _failureDetail(
            result.stderr, 'ai-workspace-uninstall-failed'.i18n());
        return false;
      }
    } catch (e) {
      _toolStates[tool]?.errorMessage = e.toString();
      return false;
    }

    await refreshStatus(tool);
    return true;
  }

  /// Builds the "is this still installed" check for [installPath].
  static String _existsCheck(String installPath) {
    if (installPath.startsWith('docker://')) {
      final container = installPath.substring('docker://'.length);
      return 'docker inspect $container >/dev/null 2>&1 && echo exists || echo missing';
    }
    if (installPath.startsWith('cmd://')) {
      // PATH check, not a path check: `~` does not expand inside double
      // quotes, so `[ -d "~/.foo" ]` never matches.
      final binary = installPath.substring('cmd://'.length);
      return 'command -v $binary >/dev/null 2>&1 && echo exists || echo missing';
    }
    return '[ -d $installPath ] && echo exists || echo missing';
  }

  Future<void> refreshStatus(AiWorkspaceTool tool) async {
    // An install in flight is the authority on this tool's state. Probing
    // mid-install reports "missing" and would persist notInstalled over a
    // download that is still running.
    if (_installing.contains(tool)) return;

    // A failed install or start is the user's to read. This probe runs
    // immediately afterwards and would report the tool as plain "not
    // installed" with no message, so the reason it failed never reached the
    // screen. Only an explicit action ([clearError]) hands the card back.
    final failed = _toolStates[tool];
    if (failed != null && failed.errorSticky) {
      failed.checked = true;
      failed.hasKnownStatus = true;
      return;
    }

    await ensureDistro();
    final config = _toolConfigs[tool]!;
    final isDockerBacked = config.defaultInstallPath.startsWith('docker://');

    // `service docker start` returns as soon as the init script forks, but
    // dockerd needs several seconds more to create its socket. Probing in
    // that window fails, and the failure is indistinguishable from "the
    // container is gone" — which is how an installed tool ends up cached as
    // notInstalled after a reboot. Wait for the daemon, and if it never
    // comes up say so rather than guessing.
    final dockerPrefix = isDockerBacked
        ? 'service docker start >/dev/null 2>&1; '
            '$_kDockerWaitLoop'
            'docker info >/dev/null 2>&1 || { echo $_kDockerDownMarker; exit 0; }; '
        : '';

    // Status, health and existence check in one shell invocation — each
    // `wsl -d` call carries real spawn overhead. The health gate only runs
    // once the tool is up, so a tool without one costs nothing.
    final healthGate = config.healthCheck ?? 'echo running';
    final combinedCommand = '$dockerPrefix'
        '_s=\$(${config.statusCheck}); '
        'if [ \$_s = running ]; then $healthGate; '
        'else ${_existsCheck(config.defaultInstallPath)}; fi';

    // Covers the daemon wait above plus the checks themselves. A cold
    // environment takes several seconds just to boot before it runs
    // anything, so 10s was routinely too tight for the first probe.
    final request = _req(combinedCommand,
        timeout: isDockerBacked
            ? const Duration(seconds: 40)
            : const Duration(seconds: 20));

    try {
      final result = await _broker.run(request);
      final rawOutput = result.stdout.trim().toLowerCase();
      if (result.isSuccess && rawOutput.contains(_kDockerDownMarker)) {
        // Docker never came up. That says nothing about whether the tool is
        // installed, so keep whatever was last confirmed and report the real
        // problem instead of silently downgrading to notInstalled.
        _toolStates[tool]?.errorMessage =
            'ai-workspace-docker-unavailable-text'.i18n();
      } else if (result.isSuccess) {
        final output = rawOutput;
        // `starting` first: it is the health gate's answer for a container
        // that is up but still migrating, and must not be read as running.
        if (output.contains('starting')) {
          _toolStates[tool]?.status = ToolStatus.starting;
        } else if (output.contains('running')) {
          _toolStates[tool]?.status = ToolStatus.running;
        } else if (output.contains('exists') || output.contains('stopped')) {
          // `stopped` comes from the health gate (up, but unhealthy) — the
          // tool is installed either way, so it must not fall through to
          // notInstalled and lose its install path.
          _toolStates[tool]?.status = ToolStatus.stopped;
        } else {
          // The setter drops installPath with it: "Not installed" and
          // "Installed: <path>" must never appear on the same card.
          _toolStates[tool]?.status = ToolStatus.notInstalled;
        }
        // Any answer other than notInstalled is a confirmation of exactly the
        // path the check was built from, so re-assert it — the probe that
        // last said notInstalled cleared it.
        if (_toolStates[tool]?.status != ToolStatus.notInstalled) {
          _toolStates[tool]?.installPath = config.defaultInstallPath;
        }
        _toolStates[tool]?.errorMessage = null;
        _persistConfirmedState(tool);
      } else if (_indicatesMissingDistro(result)) {
        // An explicit WSL error code is still a confirmed answer.
        _toolStates[tool]?.status = ToolStatus.notInstalled;
        _toolStates[tool]?.errorMessage = null;
        _persistConfirmedState(tool);
      } else {
        // Not a confirmed signal — leave the cache alone.
        _toolStates[tool]?.status = ToolStatus.error;
        _toolStates[tool]?.errorMessage = result.stderr;
      }
    } catch (e) {
      // A timeout or a dead WSL call says nothing about whether the tool is
      // installed. Claiming notInstalled here is how a cold distro — where the
      // first call routinely exceeds the timeout — makes an installed tool
      // read as missing. Keep the last known status and report the failure.
      _toolStates[tool]?.errorMessage = e.toString();
    } finally {
      // Set on every path: the UI cares that a check was attempted.
      _toolStates[tool]?.checked = true;
      _toolStates[tool]?.hasKnownStatus = true;
    }
  }

  // ---------------------------------------------------------------------
  // Background pre-fetch
  // ---------------------------------------------------------------------

  Future<void>? _initFuture;

  /// Seeds state and probes every tool, memoized. Kicked off fire-and-forget
  /// from app startup so the screen has results by the time it opens;
  /// concurrent callers join the same run.
  Future<void> ensureInitialized() {
    return _initFuture ??= _runInitialCheck();
  }

  Future<void> _runInitialCheck() async {
    if (_toolStates.isEmpty) {
      seedToolStates();
    }
    try {
      await ensureDistro();
    } on Exception catch (e) {
      // A distro the user deleted with automatic setup off is a choice, not
      // a startup failure to log on every launch; the page offers setup.
      if (e.toString().contains(notProvisionedKey)) return;
      rethrow;
    }
    await Future.wait(AiWorkspaceTool.values.map(refreshStatus));
  }

  /// Static port URL, no WSL call. Only valid for tools without a
  /// [ToolConfig.dashboardCommand] — use [getDashboardUrl] for the rest.
  ///
  /// The host is the environment's own loopback, which is the address the
  /// service actually listens on; [getDashboardUrl] is what turns that into
  /// something this machine can dial.
  String? getUrl(AiWorkspaceTool tool) {
    final state = _toolStates[tool];
    if (state == null || state.status != ToolStatus.running) {
      return null;
    }

    return 'http://localhost:${state.port}';
  }

  /// Hosts that mean "the machine this URL was printed on".
  ///
  /// Every tool here prints one — and [getUrl] builds one — because that is
  /// what they bound. It is the right answer only when the environment shares
  /// a loopback with this app.
  static bool _isLoopbackHost(String host) =>
      host == 'localhost' ||
      host == '::1' ||
      host.startsWith('127.');

  /// The forward that carries [url]'s port out of the workspace, opened on
  /// first use. Null when [url] is dialable from here as it is: under WSL,
  /// or when it already names a routable host.
  Future<_PortForward?> _forwardFor(String url) async {
    if (_runtime.sharesLoopback) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || !_isLoopbackHost(uri.host)) {
      return null;
    }
    return _ensureForward(uri.port);
  }

  /// The live forward for [remotePort], opening one when there is none.
  ///
  /// One per port, reused across dashboard opens, because the browser tab
  /// keeps using it long after "Open Dashboard" returned. A forward whose
  /// guest went away exits on its own (vmctl's keep-alives see to that),
  /// and the next call opens a fresh one. Calls that overlap while one is
  /// still opening share it; otherwise the first forward would be orphaned,
  /// holding its port with nothing left to kill it.
  Future<_PortForward> _ensureForward(int remotePort) {
    final existing = _forwards[remotePort];
    if (existing != null && !existing.exited) return Future.value(existing);
    // A block body on purpose: `remove` returns the future stored here, and
    // whenComplete waits on whatever its callback returns. An arrow would
    // make this future wait on itself.
    return _openingForwards[remotePort] ??=
        _openForward(remotePort).whenComplete(() {
      _openingForwards.remove(remotePort);
    });
  }

  Future<_PortForward> _openForward(int remotePort) async {
    final localPort = await _pickLocalPort(remotePort);
    final process = await _broker.startPersistent(_runtime.portForward(
      remotePort: remotePort,
      localPort: localPort,
    ));
    final forward = _PortForward(process, remotePort, localPort);
    _forwards[remotePort] = forward;
    // ssh prints nothing on stdout, but an undrained pipe can still stall
    // it. stderr is kept: it is the only place a failed forward says why.
    process.stdout.listen((_) {}, onError: (Object _) {});
    process.stderr.listen(
      (data) => forward.stderrTail = _appendTail(
          forward.stderrTail, ExecutionBroker.decodeWslOutput(data)),
      onError: (Object _) {},
    );
    unawaited(process.exitCode.then((_) {
      forward.exited = true;
      if (identical(_forwards[remotePort], forward)) {
        _forwards.remove(remotePort);
      }
    }));
    return forward;
  }

  /// Starts the dashboard server if the tool needs one, then waits until
  /// the URL actually answers. Null means "could not open" — a container
  /// reporting "Up" does not mean its web server is serving yet.
  Future<String?> getDashboardUrl(AiWorkspaceTool tool) async {
    final state = _toolStates[tool];
    if (state == null || state.status != ToolStatus.running) {
      return null;
    }

    final config = _toolConfigs[tool]!;
    final url = config.dashboardCommand == null
        ? getUrl(tool)
        : await _runDashboardCommand(tool, config);
    // "Could not open the dashboard" on its own is untraceable; say which
    // step gave up.
    if (url == null) {
      state.errorMessage = config.dashboardCommand == null
          ? 'No dashboard URL for ${config.name}'
          : 'No dashboard URL from: ${config.dashboardCommand}';
      return null;
    }
    // The URL the tool printed names the loopback it bound, which is this
    // machine's loopback only under WSL. Anywhere else it has to be carried
    // out of the workspace first.
    final _PortForward? forward;
    try {
      forward = await _forwardFor(url);
    } catch (e) {
      state.errorMessage = 'Could not forward ${config.name} from '
          '${_runtime.target} to ${_runtime.hostName}: $e';
      return null;
    }
    final hostUrl = forward?.localUrl(url) ?? url;
    if (!await _waitUntilReachable(hostUrl,
        hopeless: () => forward?.exited ?? false)) {
      state.errorMessage = _unreachableMessage(hostUrl, forward);
      return null;
    }
    state.errorMessage = null;
    return hostUrl;
  }

  /// What the card says when [url] never answered. A forward that died on
  /// the way is the likelier story, and ssh's own words are the useful part
  /// of it: a taken port, no lease, a refused key.
  String _unreachableMessage(String url, _PortForward? forward) {
    final base = 'Dashboard URL not reachable from ${_runtime.hostName}: $url';
    if (forward == null) return base;
    final via = '$base (forwarded from port ${forward.remotePort} in '
        '${_runtime.target})';
    if (!forward.exited) return via;
    final why = forward.stderrTail.trim();
    return why.isEmpty
        ? '$via; the forward ended'
        : '$via; the forward ended: $why';
  }

  Future<String?> _runDashboardCommand(
      AiWorkspaceTool tool, ToolConfig config) async {
    await ensureDistro();

    // The command runs in the foreground and its output is parsed in Dart.
    // Doing the extraction in shell meant grep patterns, redirections and
    // `$(...)` had to survive Dart's Windows argument escaping on the way into
    // wsl.exe; they did not, and the failure was silent. Keeping the shell
    // side to a bare command removes that whole class of bug.
    final request = _req(config.dashboardCommand!,
        timeout: const Duration(seconds: 40));

    try {
      final result = await _broker.run(request);
      final output = '${result.stdout}\n${result.stderr}';
      final url = _firstServiceUrl(output);
      if (url == null) return null;
      // A GATEWAY_TOKEN marker line (OpenClaw) carries the auth the URL
      // itself lacks; the control UI reads it from the `token` fragment.
      final token =
          RegExp(r'GATEWAY_TOKEN:(\S+)').firstMatch(output)?.group(1);
      if (token != null && token.isNotEmpty && !url.contains('token')) {
        return '$url#token=$token';
      }
      return url;
    } catch (_) {
      return null;
    }
  }

  /// Picks the tool's own URL out of [output].
  ///
  /// Prefers a loopback address: these tools also print documentation links,
  /// and those are reachable, so a naive match opens the docs instead.
  static String? _firstServiceUrl(String output) {
    final urls = RegExp(r'https?://[^\s]+')
        .allMatches(output)
        .map((m) => m.group(0)!)
        // Trailing punctuation from prose lines.
        .map((u) => u.replaceAll(RegExp(r'[.,)\]]+$'), ''))
        .toList();
    if (urls.isEmpty) return null;
    return urls.firstWhere(
      (u) => u.contains('127.0.0.1') || u.contains('localhost'),
      orElse: () => urls.first,
    );
  }

  /// Polls [url] until something actually answers, or [timeout] elapses, or
  /// [hopeless] says nothing ever will (the forward carrying it has died).
  Future<bool> _waitUntilReachable(
    String url, {
    Duration timeout = const Duration(seconds: 10),
    bool Function()? hopeless,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await _isReachable(url)) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      if (hopeless != null && hopeless()) return false;
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }
}
