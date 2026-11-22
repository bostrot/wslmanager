// Managing containers on whatever engine the host already has.
//
// The decision behind this file (bostrot/ai-tasks#57): the app is a *front
// end* for an engine the user installed, not an engine of its own. It shells
// out to `docker` or `podman` on the host — the same binary the user types in
// a terminal — instead of bundling a runtime or installing one inside a
// distro/VM and proxying through it. Nothing to keep in sync with the engine's
// releases, nothing to tear down when the app is uninstalled, and a container
// started here is the same object the user's own `docker ps` shows.
//
// Docker and Podman take the same subcommands, so one service drives either;
// the engine is a value on the service rather than a subclass. WSL's own
// `wslc.exe` (bostrot/ai-tasks#111) joined on the same terms: it ships inside
// WSL instead of being installed, but it is still someone else's engine
// driven through its CLI, and it takes Docker's spellings as aliases. Where
// it genuinely differs — a `--format` that is a vocabulary and not a template
// language, a one-shot `stats`, a `--since` that wants an instant, and two
// reads it does not have — the argv is built per [ContainerCli]. Every
// difference below was checked against `wslc 3.0.1.0` on a Windows host, not
// read off the docs: Microsoft's tutorial and reference pages contradict each
// other, and the CLI's own help is the only thing that turned out to be right.

import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;

import 'package:wsl2distromanager/api/containers/container_create_request.dart';
import 'package:wsl2distromanager/api/containers/container_models.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/execution/models.dart';
import 'package:wsl2distromanager/api/remote_target.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Preference key holding the engine the user pinned, as an executable name.
const String containerEnginePrefKey = 'ContainerEngine';

/// Field separator of the `ps` template below. A tab cannot occur inside any
/// of the fields the engines print, which a space very much can (`Status` is
/// "Exited (0) 3 minutes ago").
const String _fieldSeparator = '\t';

/// The `ps --format` template. Fields both engines document, in one order.
const String _psTemplate = '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}'
    '\t{{.Status}}\t{{.Ports}}';

/// Container names and ids accepted from callers. Matches what the engines
/// themselves allow, and — because it cannot start with `-` — keeps a crafted
/// name from arriving as another flag on the command line.
final RegExp _refPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$');

/// Durations as the engines' `--since` writes them: `30s`, `15m`, `2h`.
final RegExp _durationPattern = RegExp(r'^[0-9]{1,6}[smh]$');

/// `images --format`: repository:tag, id, size and age, the four columns
/// anyone reads when asking what is taking up the disk.
const String _imagesTemplate =
    '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}';

/// `volume ls --format`. Podman's `{{.Driver}}` and `{{.Name}}` match
/// Docker's, which is why one template drives both.
const String _volumesTemplate = '{{.Name}}\t{{.Driver}}';

/// `network ls --format`.
const String _networksTemplate = '{{.Name}}\t{{.Driver}}\t{{.Scope}}';

/// `stats --format`: what a container is actually costing right now.
const String _statsTemplate = '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
    '\t{{.NetIO}}\t{{.BlockIO}}';

/// Drives `docker`/`podman` on the host.
class ContainerService {
  /// Every engine command goes through the broker rather than `Process.run`.
  /// A plain `run` hands back no handle, so a timeout could only *stop
  /// waiting* on a hung `docker ps` and leave the child behind — the same
  /// leak that once orphaned hundreds of `wsl.exe` processes (see
  /// `ExecutionBroker.run`). The broker reaps it, and strips the engines'
  /// ANSI colouring out of the output on the way.
  final ExecutionBroker _broker;

  /// How long any single engine command may take before it is abandoned.
  final Duration timeout;

  /// Whether this host is Windows. Injected rather than read from [Platform]
  /// at every call site so the Windows-only engine can be exercised from a
  /// test on any machine — and so the tests that predate it keep probing the
  /// same two engines on the Windows CI job as on a Mac.
  final bool _isWindows;

  ContainerService({
    Shell? shell,
    ExecutionBroker? broker,
    bool? isWindows,
    this.timeout = const Duration(seconds: 30),
  })  : _isWindows = isWindows ?? Platform.isWindows,
        _broker = broker ?? ExecutionBroker(shell: shell ?? ProcessShell());

  /// Engines found on this host, cached for the life of the service: probing
  /// costs two process launches and the answer only changes when the user
  /// installs something.
  List<ContainerEngine>? _available;

  /// Whether the app is driving a remote Windows host over SSH. The container
  /// commands follow the rest of the app: with a remote target configured the
  /// engine that matters is the remote one, not the laptop's.
  bool get _useRemote {
    try {
      final enabled = prefs.getBool('UseRemoteWSL') ?? false;
      final target = prefs.getString('RemoteWSLTarget')?.trim() ?? '';
      return enabled && isValidRemoteTarget(target);
    } catch (_) {
      // Preferences not initialised (tests, early startup) — stay local.
      return false;
    }
  }

  /// Whether the engine commands land on a Windows host — this machine, or
  /// the remote one when the app is driving WSL over SSH, where `wslc` is as
  /// real as it is locally.
  bool get _windowsHost => _isWindows || _useRemote;

  String get _remoteTarget {
    try {
      return prefs.getString('RemoteWSLTarget')?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// The engine the user pinned in settings, or null when they never did.
  ContainerEngine? get preferredEngine {
    try {
      return ContainerEngine.byExecutable(
          prefs.getString(containerEnginePrefKey));
    } catch (_) {
      return null;
    }
  }

  /// Pin [engine] as the one to use, or clear the pin with null.
  Future<void> setPreferredEngine(ContainerEngine? engine) async {
    if (engine == null) {
      await prefs.remove(containerEnginePrefKey);
    } else {
      await prefs.setString(containerEnginePrefKey, engine.executable);
    }
  }

  /// Forget the probe result, so the next call looks for engines again. Used
  /// by the Containers screen's refresh: installing Docker while the app is
  /// open must not need a restart.
  void invalidateEngineCache() => _available = null;

  /// Every engine installed on the host, in [ContainerEngine] order.
  ///
  /// "Installed" means the binary answered `--version` — which `wslc` takes
  /// as well as its own `wslc version`. An engine whose
  /// daemon is down still shows up here — that failure belongs to [list],
  /// which can say *why* instead of pretending nothing is installed. A
  /// Windows-only engine is not probed at all off Windows: `wslc` cannot
  /// exist on a Mac, and the launch would only cost a process.
  Future<List<ContainerEngine>> availableEngines() async {
    final cached = _available;
    if (cached != null) return cached;
    final found = <ContainerEngine>[];
    for (final engine in ContainerEngine.values) {
      if (engine.windowsOnly && !_windowsHost) continue;
      final result = await _run(engine, ['--version']);
      if (result.exitCode == 0) found.add(engine);
    }
    return _available = found;
  }

  /// The engine commands run against: the pinned one when it is installed,
  /// otherwise the first one found. Null when the host has none.
  Future<ContainerEngine?> activeEngine() async {
    final available = await availableEngines();
    if (available.isEmpty) return null;
    final preferred = preferredEngine;
    if (preferred != null && available.contains(preferred)) return preferred;
    return available.first;
  }

  /// All containers known to [engine] (or to [activeEngine] when omitted),
  /// stopped ones included unless [runningOnly] is set.
  ///
  /// Throws [ContainerException] when no engine is installed or the engine
  /// refuses to answer — a stopped Docker daemon is the common case, and its
  /// own message is the one worth showing.
  Future<List<ContainerInfo>> list({
    ContainerEngine? engine,
    bool runningOnly = false,
  }) async {
    final target = engine ?? await activeEngine();
    if (target == null) throw const ContainerException(_noEngineMessage);
    final result = await _run(target, [
      'ps',
      if (!runningOnly) '--all',
      '--no-trunc',
      ..._listFormat(target),
    ]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(target, result, 'ps'));
    }
    return target.cli == ContainerCli.wslc
        ? parseJsonOutput(result.stdout, target)
        : parsePsOutput(result.stdout, target);
  }

  /// Containers across every installed engine. A host with both Docker and
  /// Podman gets one list, each row carrying the engine that reported it.
  ///
  /// Engines that fail are skipped rather than failing the whole call — with
  /// Podman installed but never initialised, Docker's containers must still
  /// render. When *every* engine fails, all of their messages are thrown
  /// together: "podman machine is not running" alone would send someone
  /// after the wrong engine when Docker is the one they use.
  Future<List<ContainerInfo>> listAll({bool runningOnly = false}) async {
    final engines = await availableEngines();
    if (engines.isEmpty) throw const ContainerException(_noEngineMessage);
    final containers = <ContainerInfo>[];
    final failures = <String>[];
    var anySucceeded = false;
    for (final engine in engines) {
      try {
        containers.addAll(await list(engine: engine, runningOnly: runningOnly));
        anySucceeded = true;
      } on ContainerException catch (e) {
        failures.add(e.message);
      }
    }
    if (!anySucceeded && failures.isNotEmpty) {
      throw ContainerException(failures.join('\n\n'));
    }
    return containers;
  }

  /// Create and start a container from [request], on [engine] or on
  /// [activeEngine].
  ///
  /// Returns the id the engine prints. The container is started detached, so
  /// this answers as soon as the engine has accepted it rather than when the
  /// workload inside is ready — a row that appears and immediately reads
  /// "Exited" is an image whose command finished, not a failure here.
  ///
  /// The engine's own refusal is what comes back on failure: "port is already
  /// allocated", "no such image" and "invalid reference format" are all worth
  /// reading, and a generic "could not create container" would be worth
  /// nothing.
  Future<String> create(
    ContainerCreateRequest request, {
    ContainerEngine? engine,
  }) async {
    final target = engine ?? await activeEngine();
    if (target == null) throw const ContainerException(_noEngineMessage);
    final result = await _run(target, request.toArguments());
    if (result.exitCode != 0) {
      throw ContainerCreateException(
          _failureText(target, result, 'run ${request.image}'));
    }
    return result.stdout.trim();
  }

  /// Start a stopped container.
  Future<String> start(ContainerEngine engine, String ref) =>
      _lifecycle(engine, 'start', ref);

  /// Stop a running container, giving it the engine's default grace period.
  Future<String> stop(ContainerEngine engine, String ref) =>
      _lifecycle(engine, 'stop', ref);

  /// Restart a container, running or not.
  Future<String> restart(ContainerEngine engine, String ref) =>
      _lifecycle(engine, 'restart', ref);

  /// Delete a container. A running one is only removed with [force], which
  /// kills it first — the engines refuse otherwise, and that refusal is the
  /// safety net worth keeping.
  Future<String> remove(ContainerEngine engine, String ref,
      {bool force = false}) async {
    _checkRef(ref);
    final result = await _run(engine, ['rm', if (force) '--force', ref]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'rm $ref'));
    }
    return result.stdout.trim();
  }

  /// The last [lines] of a container's log.
  ///
  /// [since] bounds the window to a duration (`5m`, `2h`) so "what happened
  /// since I restarted it" is not a day of log, and [timestamps] prefixes
  /// each line with the engine's own clock — the only way to line a container
  /// log up against anything else that happened.
  Future<String> logs(ContainerEngine engine, String ref,
      {int lines = 200, String since = '', bool timestamps = false}) async {
    _checkRef(ref);
    if (lines <= 0) {
      throw ArgumentError.value(lines, 'lines', 'must be greater than zero');
    }
    if (since.isNotEmpty && !_durationPattern.hasMatch(since)) {
      throw ArgumentError.value(
          since, 'since', 'must be a duration like 30s, 15m or 2h');
    }
    final result = await _run(engine, [
      'logs',
      '--tail',
      '$lines',
      if (since.isNotEmpty) '--since=${_sinceValue(engine, since)}',
      if (timestamps) '--timestamps',
      ref,
    ]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'logs $ref'));
    }
    // Engines write a container's stderr to *their* stderr, so a log that is
    // only diagnostics would come back empty without this.
    final merged = [result.stdout.trimRight(), result.stderr.trimRight()]
        .where((part) => part.isNotEmpty)
        .join('\n');
    return merged;
  }

  /// Run [command] inside a running container through its `sh`, returning
  /// stdout and stderr together.
  Future<String> exec(ContainerEngine engine, String ref, String command) async {
    _checkRef(ref);
    if (command.trim().isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
    final result = await _run(engine, ['exec', ref, 'sh', '-c', command]);
    final output = [result.stdout.trimRight(), result.stderr.trimRight()]
        .where((part) => part.isNotEmpty)
        .join('\n');
    if (result.exitCode != 0) {
      throw ContainerException(output.isEmpty
          ? _failureText(engine, result, 'exec $ref')
          : 'Command exited with ${result.exitCode}:\n$output');
    }
    return output;
  }

  /// The engine's own JSON description of a container.
  Future<String> inspect(ContainerEngine engine, String ref) async {
    _checkRef(ref);
    final result = await _run(engine, ['inspect', ref]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'inspect $ref'));
    }
    return result.stdout.trim();
  }

  // ---------------------------------------------------------------------
  // Read-only host inspection (bostrot/ai-tasks#67).
  //
  // The screen only needed containers; someone debugging needs the rest of
  // what the engine knows. Each of these hardcodes a read subcommand and
  // takes at most a container ref, so none of them can prune, remove or
  // build anything — `system df` reports what `system prune` would reclaim
  // without being able to reclaim it.
  // ---------------------------------------------------------------------

  /// Images on the host, newest first the way the engines list them.
  Future<String> images(ContainerEngine engine) async {
    final result = await _run(
        engine, ['images', ..._textFormat(engine, _imagesTemplate)]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'images'));
    }
    return result.stdout.trim();
  }

  /// Named volumes. The answer to "where did this database's data go" when a
  /// container was recreated and the data survived — or did not.
  Future<String> volumes(ContainerEngine engine) async {
    final result = await _run(
        engine, ['volume', 'ls', ..._textFormat(engine, _volumesTemplate)]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'volume ls'));
    }
    return result.stdout.trim();
  }

  /// Networks, which is how "these two containers cannot see each other" gets
  /// answered.
  Future<String> networks(ContainerEngine engine) async {
    final result = await _run(
        engine, ['network', 'ls', ..._textFormat(engine, _networksTemplate)]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'network ls'));
    }
    return result.stdout.trim();
  }

  /// A one-shot CPU/memory/IO sample.
  ///
  /// `--no-stream` is not optional here: without it `docker stats` never
  /// exits and the command would run into the broker's timeout every time.
  Future<String> stats(ContainerEngine engine, {String ref = ''}) async {
    if (ref.isNotEmpty) _checkRef(ref);
    final result = await _run(engine, [
      'stats',
      // Docker streams until it is told not to. `wslc` only ever takes one
      // sample and rejects the flag outright, so sending it there would fail
      // every call.
      if (engine.cli == ContainerCli.docker) '--no-stream',
      ..._textFormat(engine, _statsTemplate),
      if (ref.isNotEmpty) ref,
    ]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'stats'));
    }
    return result.stdout.trim();
  }

  /// The processes running inside a container, as the *host* sees them —
  /// which is why this works on a container with no shell, where
  /// [exec] with `ps` cannot.
  Future<String> processes(ContainerEngine engine, String ref) async {
    _checkRef(ref);
    _requireDockerCli(engine, 'top');
    final result = await _run(engine, ['top', ref]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'top $ref'));
    }
    return result.stdout.trim();
  }

  /// What images, containers, volumes and the build cache are costing on
  /// disk, and how much of it is reclaimable.
  Future<String> diskUsage(ContainerEngine engine) async {
    _requireDockerCli(engine, 'system df');
    final result = await _run(engine, ['system', 'df']);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, 'system df'));
    }
    return result.stdout.trim();
  }

  // ---------------------------------------------------------------------
  // Where WSL's CLI differs (bostrot/ai-tasks#111).
  //
  // Everything the app sends is a Docker spelling `wslc` accepts as an alias,
  // so there is no per-engine command table — only the four differences
  // below, each one checked against `wslc 3.0.1.0`.
  // ---------------------------------------------------------------------

  /// `--format` for the one listing the app *parses*.
  ///
  /// Docker is handed the template above. `wslc` has no template language —
  /// `--format` takes `json` or `table` — so it is asked for JSON, whose keys
  /// are English on a German Windows where every table heading is not
  /// (`CONTAINER-ID`, `BILD`, `NAMEN`).
  static List<String> _listFormat(ContainerEngine engine) =>
      engine.cli == ContainerCli.wslc
          ? const ['--format', 'json']
          : const ['--format', _psTemplate];

  /// `--format` for a read the app only passes through as text.
  ///
  /// There is no template to ask `wslc` for, and its own table is what the
  /// user would see in a terminal, so the flag is simply left off.
  static List<String> _textFormat(ContainerEngine engine, String template) =>
      engine.cli == ContainerCli.wslc ? const [] : ['--format', template];

  /// `--since` as [engine] reads it.
  ///
  /// Docker takes the duration the caller gave. `wslc` wants a Unix epoch or
  /// an RFC3339 instant — and quietly reads `15m` as epoch 15, which turns
  /// "the last fifteen minutes" into "since 1970" with no error at all, so
  /// the duration is resolved against the clock here instead.
  static String _sinceValue(ContainerEngine engine, String since) {
    if (engine.cli != ContainerCli.wslc) return since;
    final amount = int.parse(since.substring(0, since.length - 1));
    final unit = since[since.length - 1];
    final window = unit == 's'
        ? Duration(seconds: amount)
        : unit == 'm'
            ? Duration(minutes: amount)
            : Duration(hours: amount);
    final from = DateTime.now().toUtc().subtract(window);
    return '${from.millisecondsSinceEpoch ~/ 1000}';
  }

  /// Refuse a read [what] that [engine] has no command for, rather than
  /// sending one and showing the user a usage dump in whatever language
  /// Windows is set to. `wslc 3.0.1` has `network ls` and `volume ls`, but
  /// neither `top` nor `system df`.
  static void _requireDockerCli(ContainerEngine engine, String what) {
    if (engine.cli == ContainerCli.docker) return;
    throw ContainerException(
        '${engine.label} has no "$what" command — only Docker and Podman '
        'report that.');
  }

  Future<String> _lifecycle(
      ContainerEngine engine, String verb, String ref) async {
    _checkRef(ref);
    final result = await _run(engine, [verb, ref]);
    if (result.exitCode != 0) {
      throw ContainerException(_failureText(engine, result, '$verb $ref'));
    }
    return result.stdout.trim();
  }

  void _checkRef(String ref) {
    if (!_refPattern.hasMatch(ref)) {
      throw ArgumentError.value(ref, 'ref', 'not a valid container name or id');
    }
  }

  /// Run one engine command, locally or over SSH.
  ///
  /// Never throws for an ordinary failure: a missing binary and a refusing
  /// daemon both come back as a non-zero [_EngineResult], because "docker is
  /// not installed" is the answer [availableEngines] is asking for. A timeout
  /// is the exception — there is no exit code to report, and the caller has
  /// to say so rather than treat it as "no containers".
  Future<_EngineResult> _run(
    ContainerEngine engine,
    List<String> arguments,
  ) async {
    final remote = _useRemote;
    final executable = remote ? 'ssh' : engine.executable;
    final args = remote
        ? sshRemoteCommand(_remoteTarget, engine.executable, arguments)
        : arguments;
    final result = await _broker.run(ExecutionRequest(
      command: executable,
      arguments: args,
      timeout: timeout,
      runInShell: false,
    ));
    if (result.error is TimeoutException) {
      throw ContainerException(
          '${engine.label} did not answer within ${timeout.inSeconds}s: '
          '${engine.executable} ${arguments.join(' ')}');
    }
    return _EngineResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  String _failureText(
      ContainerEngine engine, _EngineResult result, String what) {
    final detail = result.stderr.trim().isNotEmpty
        ? result.stderr.trim()
        : result.stdout.trim();
    final suffix = detail.isEmpty ? '' : '\n$detail';
    return '${engine.label} failed to run "$what" '
        '(exit ${result.exitCode}).$suffix';
  }

  static const String _noEngineMessage =
      'No container engine found. On Windows, WSL 2.9.3 and later ship the '
      '"wslc" command — run "wsl --update" to get it. Otherwise install '
      'Docker or Podman and make sure its command is on your PATH.';

  /// Message shown when the host has no engine at all. Public so the UI and
  /// the MCP tools say the same thing.
  static String get noEngineMessage => _noEngineMessage;

  /// Turn `ps --format` output into rows.
  ///
  /// Static and public because the parsing is the part worth testing on its
  /// own, and because the AI Workspace reads the same shape. Lines that do not
  /// carry at least an id and a name are skipped: engines print warnings on
  /// stdout ("Emulate Docker CLI using podman…") and one of those must not
  /// become a container row.
  static List<ContainerInfo> parsePsOutput(
      String output, ContainerEngine engine) {
    final containers = <ContainerInfo>[];
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) continue;
      final fields = line.split(_fieldSeparator);
      if (fields.length < 2) continue;
      final id = fields[0].trim();
      final name = fields[1].trim();
      if (id.isEmpty && name.isEmpty) continue;
      String field(int index) =>
          index < fields.length ? fields[index].trim() : '';
      final status = field(4);
      final rawState = field(3);
      containers.add(ContainerInfo(
        id: id,
        name: name,
        image: field(2),
        // Older engines leave `.State` empty; the first word of `.Status`
        // ("Up 2 hours", "Exited (0) …") says the same thing.
        state: ContainerState.parse(
            rawState.isNotEmpty ? rawState : status.split(' ').first),
        status: status,
        ports: field(5),
        engine: engine,
      ));
    }
    return containers;
  }

  /// Turn a `--format json` listing into rows.
  ///
  /// The output is not one JSON document: `wslc` prints one object per line,
  /// the way Docker's own `--format json` does, so each line is decoded on
  /// its own. A line that does not parse is skipped rather than failing the
  /// listing — engines print notices on stdout, and one of those must not
  /// become a container row, nor hide the rows around it. A pretty-printed
  /// array is decoded as a whole instead, so a future engine that answers
  /// with one still lists.
  ///
  /// The keys are the engine's own and are English whatever the host's
  /// display language, which is what makes this the listing worth parsing:
  /// `wslc`'s table headings are translated (`CONTAINER-ID`, `BILD`,
  /// `NAMEN` on a German Windows) and its `State` values are not.
  static List<ContainerInfo> parseJsonOutput(
      String output, ContainerEngine engine) {
    final trimmed = output.trim();
    if (trimmed.startsWith('[')) {
      final decoded = _decode(trimmed);
      if (decoded is List) {
        final containers = <ContainerInfo>[];
        for (final entry in decoded) {
          final row = _rowFrom(entry, engine);
          if (row != null) containers.add(row);
        }
        return containers;
      }
    }
    final containers = <ContainerInfo>[];
    for (final line in trimmed.split('\n')) {
      final row = _rowFrom(_decode(line.trim()), engine);
      if (row != null) containers.add(row);
    }
    return containers;
  }

  /// [text] as JSON, or null when it is not JSON at all.
  static Object? _decode(String text) {
    if (!text.startsWith('{') && !text.startsWith('[')) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// One decoded object as a container, or null when it carries neither an id
  /// nor a name and so describes nothing the app can address.
  static ContainerInfo? _rowFrom(Object? decoded, ContainerEngine engine) {
    if (decoded is! Map) return null;
    String field(String key) {
      final value = decoded[key];
      return value is String ? value.trim() : '';
    }

    final id = field('ID');
    final name = field('Names');
    if (id.isEmpty && name.isEmpty) return null;
    final status = field('Status');
    final state = field('State');
    return ContainerInfo(
      id: id,
      // Docker can list several comma-separated names for one container; the
      // first is the one its own table shows.
      name: name.split(',').first.trim(),
      image: field('Image'),
      state: ContainerState.parse(
          state.isNotEmpty ? state : status.split(' ').first),
      status: status,
      ports: field('Ports'),
      engine: engine,
    );
  }
}

/// Engine output normalised to text, whatever encoding the shell handed back.
class _EngineResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const _EngineResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}
