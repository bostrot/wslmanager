import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chunked_downloader/chunked_downloader.dart' as cd;
import 'package:dio/dio.dart';
import 'package:async/async.dart';
import 'package:wsl2distromanager/api/docker_images.dart';
import 'package:wsl2distromanager/api/remote_command.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/components/helpers.dart';

class MockHttpClientAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (options.path.contains('releases')) {
      return ResponseBody.fromString(
          jsonEncode([
            {
              'tag_name': 'v2.0.0',
              'published_at': DateTime.now()
                  .subtract(const Duration(days: 3))
                  .toIso8601String(),
              'html_url': 'https://github.com/example/release.msix'
            }
          ]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    }
    if (options.path.contains('motd')) {
      return ResponseBody.fromString(jsonEncode({'motd': 'Hello Test'}), 200,
          headers: {
            Headers.contentTypeHeader: [Headers.textPlainContentType]
          });
    }
    if (options.path.contains('images.json')) {
      return ResponseBody.fromString(
          jsonEncode({'Debian': 'http://example.com/debian.tar.gz'}), 200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    }
    return ResponseBody.fromString('', 404);
  }

  @override
  void close({bool force = false}) {}
}

class MockShell implements Shell {
  final List<String> distros = [];
  List<String> lastStartArguments = [];

  /// Every child [start] handed back, in order, so a test can read what was
  /// streamed into one — `runCmds` writes the snippet into the distro over
  /// stdin and nothing else records those bytes.
  final List<MockProcess> processes = [];

  /// Whether the last command — through [run] or [start] — was routed through
  /// cmd.exe. In-distro WSL commands must not be, on either channel: `cmd /c`
  /// eats `&`, `|`, `<`, `>` and `^` before wsl.exe ever sees them. See
  /// lib/api/wsl_args.dart.
  bool lastRunInShell = false;
  String lastStartExecutable = '';
  List<String> lastRunArguments = [];
  String lastRunExecutable = '';
  String? execCmdAsRootResponse;
  String defaultUserHome = '/home/tester';

  /// In-distro `/etc/wsl.conf`, so a write can be read back.
  ///
  /// Null means the file does not exist, which is what `cat` reports on most
  /// freshly imported distros — the case the audit's CC-3 is about.
  String? wslConfContents;

  /// `wsl.exe` itself fails, e.g. the distro will not start. The config
  /// writer has to leave the file alone rather than replace it with the one
  /// key it was asked to set.
  bool simulateWslConfUnreachable = false;

  /// The redirection into `/etc/wsl.conf` fails — a read-only filesystem.
  bool simulateWslConfReadOnly = false;

  /// Every in-distro shell script [run] has been handed, in order. Counting
  /// them is how the settings dialog's debounce is measured.
  final List<String> runCommands = [];

  /// In-distro commands (matched by substring) that exit non-zero, for
  /// callers that must notice a script failing rather than assume success.
  final Set<String> failingRunCommands = {};

  /// What `wsl --version` prints. Empty is the *inbox* build, which answers
  /// nothing useful — and is the default here so a test that does not opt in
  /// keeps taking the pre-WSL-2.5 code paths (`--manage` unavailable).
  String wslVersionOutput = '';

  /// Exit code of `wsl --version`. Non-zero is the documented inbox-build
  /// signature (`systemd.md:30`).
  int wslVersionExitCode = 0;

  /// What `wsl --status` prints.
  String wslStatusOutput = '';

  /// What `wsl --list --verbose` prints. Null falls back to the plain
  /// `--list` answer, which is the name column on its own — a shape the
  /// version parser is supposed to ignore rather than mis-read.
  String? wslListVerboseOutput;

  /// `wsl --list --verbose` fails with this message and no stdout — what a
  /// host without WSL, or one whose wsl.exe timed out, looks like.
  String? wslListVerboseFailure;

  /// Every `wsl --set-version` / `wsl --set-default-version` argument list.
  final List<List<String>> versionCalls = <List<String>>[];

  /// Both version verbs fail with this message instead of succeeding.
  String? versionFailure;

  /// `wsl --terminate` throws instead of answering — what a host with no
  /// wsl.exe does, since [WSLApi.stop] spawns the process directly rather
  /// than through the broker that turns a failure into an exit code.
  bool throwOnTerminate = false;

  /// Every `ssh` invocation fails — the remote host is unreachable.
  bool sshFails = false;

  /// Every argument list this shell has been handed, in order, through either
  /// [run] or [start]. `lastRunArguments` only remembers one, which is not
  /// enough to assert that a *sequence* happened — "terminate, then move" — or
  /// that a step did **not**. Both channels feed it because the commands that
  /// go through `ExecutionBroker` (and so through `start`) interleave with the
  /// ones that still call `run`, and an order assertion has to see both.
  final List<List<String>> runCalls = <List<String>>[];

  /// Every `wsl --manage` argument list this shell has been handed.
  final List<List<String>> manageCalls = <List<String>>[];

  /// Every `wsl --update` argument list.
  final List<List<String>> updateCalls = <List<String>>[];

  /// Every `wsl --install` argument list, so a `--from-file` install can be
  /// asserted on order and flags rather than on "something ran".
  final List<List<String>> installCalls = <List<String>>[];

  /// `wsl --install --from-file` fails with this message instead of
  /// succeeding.
  String? installFromFileFailure;

  /// In-distro `/etc/wsl-distribution.conf`, so a write can be read back.
  /// Null means the file does not exist, which is what every `--import`ed
  /// distro looks like (audit F-8).
  String? distributionConfContents;

  /// Absolute paths [readDistroFileList] should report as present.
  final Set<String> existingDistroFiles = <String>{};

  /// Paths `test -x` should answer yes for.
  final Set<String> executableDistroFiles = <String>{};

  /// Every `chmod` argument list the distro has been handed.
  final List<List<String>> chmodCalls = <List<String>>[];

  /// Arbitrary in-distro files this shell has been asked to write, by path.
  final Map<String, String> writtenDistroFiles = <String, String>{};

  /// Canned stdout for an in-distro script, keyed by the script itself.
  ///
  /// The escape hatch for commands that do not deserve a hand-written branch
  /// below — one caller, one fixed answer. Consulted only when nothing more
  /// specific matched, so it cannot shadow the simulated `wsl.conf`
  /// read/write pair.
  final Map<String, String> commandOutputs = <String, String>{};

  /// `wsl --manage` fails with this message instead of succeeding.
  String? manageFailure;

  /// What `wsl --system … df -k …` prints.
  String dfOutput = '';

  bool simulateExportFailure = false;
  bool simulatePermissionDenied = false;
  bool simulateInvalidPath = false;
  String importFailureStdout = '';
  bool simulateSmallExport = false;
  bool simulateRemoveFailure = false;
  bool simulateCodeMissing = false;
  bool simulateCodiumMissing = false;
  // Bytes reported by the remote `Get-Item -LiteralPath ... .Length`
  // PowerShell probe used by WSLApi._remoteFileSize (getSize/move safety
  // checks). Defaults large enough to pass move()'s size-safety check.
  int remoteFileSizeBytes = 10 * 1024 * 1024;

  /// The remote `%UserProfile%\.wslconfig`, as the PowerShell probe sees it.
  ///
  /// This is the one `.wslconfig` transport a test can own: the local one
  /// resolves through `%USERPROFILE%`, which a test process cannot move, so a
  /// local round trip would be a round trip through the developer's own file.
  /// Null is a host with no `.wslconfig` at all — which reads as an *empty*
  /// config, never as a failure.
  String? remoteWslConfigContents;

  /// The remote write fails — a read-only profile, or a host that let the read
  /// through and not the write. [WSLApi.writeWslConfig] has to report that
  /// rather than assume it landed.
  bool remoteWslConfigWriteFails = false;

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      Encoding? stdoutEncoding = systemEncoding,
      Encoding? stderrEncoding = systemEncoding}) async {
    lastRunExecutable = executable;
    lastRunArguments = arguments;

    final outcome = _simulate(executable, arguments, runInShell);

    dynamic stdoutData = outcome.stdout;
    if (stdoutEncoding == null) {
      stdoutData = utf8.encode(outcome.stdout);
    }

    dynamic stderrData = outcome.stderr;
    if (stderrEncoding == null) {
      stderrData = utf8.encode(outcome.stderr);
    }

    return ProcessResult(0, outcome.exitCode, stdoutData, stderrData);
  }

  /// Answer one command, whichever channel it arrived on.
  ///
  /// [run] and [start] share this because the code under test now uses both
  /// for the same commands: `ExecutionBroker` spawns through `Shell.start` so
  /// it can reap a timed-out child, so every `wsl.exe` verb and every
  /// in-distro file read/write reaches this mock through `start`, while the
  /// older direct-`Process.run` paths still reach it through `run`. A
  /// simulation that lived in `run` alone would answer half of them with an
  /// empty, exit-0 process — which is not a failing test, it is a passing one
  /// that proves nothing.
  _MockOutcome _simulate(
      String executable, List<String> arguments, bool runInShell) {
    lastRunInShell = runInShell;
    runCalls.add(List<String>.from(arguments));
    arguments = _unwrapRemote(arguments);

    String stdout = '';
    String stderr = '';
    int exitCode = 0;

    if (sshFails && executable == 'ssh') {
      return const _MockOutcome(
          255, '', 'ssh: connect to host: Connection refused');
    }

    // Every in-distro invocation now arrives as `--exec <shell> -c <script>`
    // (see lib/api/wsl_args.dart), so the command is the last argument
    // rather than a run of separate argv entries.
    if ((arguments.contains('sh') || arguments.contains('bash')) &&
        arguments.contains('-c')) {
      String cmd = arguments.last;
      runCommands.add(cmd);
      if (failingRunCommands.any(cmd.contains)) exitCode = 1;
      if (cmd == 'command -v code') {
        if (simulateCodeMissing) {
          exitCode = 1;
        }
      } else if (cmd == 'command -v codium') {
        if (simulateCodiumMissing) {
          exitCode = 1;
        }
      } else if (cmd == r'echo $HOME') {
        stdout = defaultUserHome;
      } else if (cmd == 'ls /testfile') {
        stdout = '/testfile\n';
      } else if (cmd == 'cat /etc/wsl.conf' && execCmdAsRootResponse != null) {
        stdout = execCmdAsRootResponse!;
      } else if (cmd == 'cat /etc/wsl.conf 2>/dev/null; exit 0') {
        // WSLApi.readWSLConf. `exit 0` means bash ran, so a non-zero status
        // here can only come from wsl.exe failing to reach the distro.
        if (simulateWslConfUnreachable) {
          stderr = 'There is no distribution with the supplied name.';
          exitCode = 1;
        } else {
          stdout = wslConfContents ?? execCmdAsRootResponse ?? '';
        }
      } else if (cmd.startsWith('cat ') &&
          cmd.endsWith(' 2>/dev/null; exit 0')) {
        // WSLApi.readDistroFile, of which readWSLConf and
        // readDistributionConf are the two schema-aware callers.
        final path = cmd.substring(
            'cat '.length, cmd.length - ' 2>/dev/null; exit 0'.length);
        if (simulateWslConfUnreachable) {
          stderr = 'There is no distribution with the supplied name.';
          exitCode = 1;
        } else if (path == '/etc/wsl-distribution.conf') {
          stdout = distributionConfContents ?? '';
        } else {
          // A file that is not there `cat`s as empty with status 0, which is
          // what the `2>/dev/null; exit 0` is for.
          stdout = writtenDistroFiles[path] ?? '';
        }
      } else if (cmd.startsWith('for f in ') && cmd.contains(r'[ -e $f ]')) {
        // WSLApi.readDistroFileList.
        if (simulateWslConfUnreachable) {
          exitCode = 1;
        } else {
          final paths =
              cmd.substring('for f in '.length, cmd.indexOf('; do')).split(' ');
          stdout = paths.where(existingDistroFiles.contains).join('\n');
        }
      } else if (cmd.startsWith("printf %s '") &&
          cmd.contains("' | base64 -d > ")) {
        // WSLApi.writeDistroFile, of which writeWSLConf is one caller.
        final marker = "' | base64 -d > ";
        final split = cmd.indexOf(marker);
        final path = cmd.substring(split + marker.length);
        if (simulateWslConfUnreachable || simulateWslConfReadOnly) {
          stderr = '$path: Read-only file system';
          exitCode = 1;
        } else {
          final payload = cmd.substring("printf %s '".length, split);
          final content = utf8.decode(base64.decode(payload));
          writtenDistroFiles[path] = content;
          if (path == '/etc/wsl.conf') {
            wslConfContents = content;
          } else if (path == '/etc/wsl-distribution.conf') {
            distributionConfContents = content;
          }
          existingDistroFiles.add(path);
        }
      } else if (commandOutputs.containsKey(cmd)) {
        stdout = commandOutputs[cmd]!;
        // An empty answer is a command the distro does not have — busybox
        // `passwd` has no `-S` — which is a failure, not an empty success.
        if (stdout.isEmpty) exitCode = 1;
      }
    }

    // `--exec test -x <path>`: WSLApi.isExecutableInDistro. argv, not a
    // script, so it never reaches the `bash -c` branch above.
    if (arguments.contains('test') && arguments.contains('-x')) {
      final path = arguments.last;
      exitCode = executableDistroFiles.contains(path) ? 0 : 1;
    }

    if (arguments.contains('chmod')) {
      chmodCalls.add(List<String>.from(arguments));
      final path = arguments.last;
      if (arguments.contains('0755')) executableDistroFiles.add(path);
    }

    if (arguments.contains('--list')) {
      if (arguments.contains('--verbose')) {
        if (wslListVerboseFailure != null) {
          stderr = wslListVerboseFailure!;
          exitCode = 1;
        } else {
          stdout = wslListVerboseOutput ?? distros.join('\n');
        }
      } else {
        stdout = distros.join('\n');
      }
    }

    if (throwOnTerminate && arguments.contains('--terminate')) {
      throw ProcessException('wsl', arguments, 'No such file or directory', 2);
    }

    if (arguments.isNotEmpty &&
        (arguments.first == '--set-version' ||
            arguments.first == '--set-default-version')) {
      versionCalls.add(List<String>.from(arguments));
      if (versionFailure != null) {
        stderr = versionFailure!;
        exitCode = 1;
      }
    }

    if (arguments.length == 1 && arguments.first == '--version') {
      stdout = wslVersionOutput;
      exitCode = wslVersionExitCode;
      if (wslVersionExitCode != 0) {
        stderr = 'Invalid command line option: --version';
      }
    }

    if (arguments.length == 1 && arguments.first == '--status') {
      stdout = wslStatusOutput;
    }

    if (arguments.isNotEmpty && arguments.first == '--manage') {
      manageCalls.add(List<String>.from(arguments));
      if (manageFailure != null) {
        stderr = manageFailure!;
        exitCode = 1;
      } else if (arguments.contains('--move')) {
        // The native move relocates the disk without unregistering anything,
        // which is the whole point of preferring it (audit cli-flags CC-2).
        final target = arguments[arguments.indexOf('--move') + 1];
        File('$target/ext4.vhdx').createSync(recursive: true);
      }
    }

    if (arguments.isNotEmpty && arguments.first == '--update') {
      updateCalls.add(List<String>.from(arguments));
      stdout = 'The most recent version of WSL is already installed.';
    }

    if (arguments.contains('--system') && arguments.contains('df')) {
      stdout = dfOutput;
    }

    if (arguments.contains('-Command') &&
        arguments.isNotEmpty &&
        arguments.last.contains('Get-Item')) {
      stdout = remoteFileSizeBytes.toString();
    }

    // WSLApi._readRemoteWslConfigText / _writeRemoteWslConfigText. The whole
    // file crosses the wire inside a PowerShell **single-quoted** string
    // literal, so the doubled `''` is undone here on the way in: a writer that
    // stopped escaping would land a truncated script rather than the value.
    if (arguments.contains('-Command') &&
        arguments.isNotEmpty &&
        arguments.last.contains('.wslconfig')) {
      final String script = arguments.last;
      const String writeMarker = "WriteAllText(\$p, '";
      const String writeSuffix = "', [Text.UTF8Encoding]::new(\$false))";

      if (script.contains(writeMarker)) {
        if (remoteWslConfigWriteFails) {
          stderr = 'Access to the path is denied.';
          exitCode = 1;
        } else {
          final start = script.indexOf(writeMarker) + writeMarker.length;
          final end = script.lastIndexOf(writeSuffix);
          remoteWslConfigContents =
              script.substring(start, end).replaceAll("''", "'");
        }
      } else if (script.contains('Get-Content')) {
        // `Get-Content -Raw` on a file that is not there prints nothing, and
        // the `if (Test-Path …)` around it keeps the exit code at 0.
        stdout = remoteWslConfigContents ?? '';
      }
    }

    if (arguments.contains('--unregister')) {
      if (simulateRemoveFailure) {
        stderr = 'Unregister failed';
        exitCode = 1;
      } else {
        distros.remove(arguments[1]);
      }
    }

    if (arguments.contains('--export')) {
      String location = arguments[2];
      if (simulatePermissionDenied) {
        stderr = 'Permission denied';
        exitCode = 1;
      } else if (simulateExportFailure) {
        stderr = 'Export failed';
        exitCode = 2;
      } else {
        File(location).createSync(recursive: true);
        // Create a file large enough to pass the >10MB safety check
        final f = File(location).openSync(mode: FileMode.write);
        if (simulateSmallExport) {
          f.truncateSync(1024); // 1KB
        } else {
          f.truncateSync(10 * 1024 * 1024 + 100); // 10MB + 100 bytes
        }
        f.closeSync();
      }
    }

    if (arguments.contains('--import')) {
      String distro = arguments[1];
      String installLocation = arguments[2];
      if (simulateInvalidPath) {
        stderr = 'Invalid installation path: $installLocation';
        stdout = importFailureStdout;
        exitCode = 3;
      } else if (simulatePermissionDenied) {
        stderr = 'Permission denied';
        exitCode = 1;
      } else {
        if (!distros.contains(distro)) {
          distros.add(distro);
        }
        File('$installLocation/ext4.vhdx').createSync(recursive: true);
      }
    }

    if (arguments.contains('--install')) {
      installCalls.add(List<String>.from(arguments));
      if (arguments.contains('-d')) {
        String distro = arguments[arguments.indexOf('-d') + 1];
        distros.add(distro);
      }
      if (arguments.contains('--from-file')) {
        if (installFromFileFailure != null) {
          stderr = installFromFileFailure!;
          exitCode = 1;
        } else if (arguments.contains('--name')) {
          distros.add(arguments[arguments.indexOf('--name') + 1]);
        }
      }
    }

    return _MockOutcome(exitCode, stdout, stderr);
  }

  @override
  Future<Process> start(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      ProcessStartMode mode = ProcessStartMode.normal}) async {
    lastStartExecutable = executable;
    lastStartArguments = arguments;

    final outcome = _simulate(executable, arguments, runInShell);
    final process = MockProcess(
      exitCode: outcome.exitCode,
      stdout: outcome.stdout,
      stderr: outcome.stderr,
    );
    processes.add(process);
    return process;
  }
}

/// An `ssh <options> -- <target> <command>` argument list with the remote
/// command put back into the shape the host will run it in.
///
/// `remoteHostCommand` (lib/api/remote_command.dart) sends anything with
/// spaces or metacharacters as `powershell … -EncodedCommand <base64>`, so
/// without this the `bash -c` matching in [MockShell._simulate] would never
/// see a remote in-distro script. Bare remote commands and anything that is
/// not ssh-shaped come back unchanged. `runCalls`/`lastRunArguments` keep the
/// raw list — a test that wants to assert on what actually crossed the wire
/// still can.
List<String> _unwrapRemote(List<String> arguments) {
  // Locate the encoded five-token run wherever it sits — behind a terminal
  // launcher's own prefix, or with tokens a caller wrongly appended after it —
  // so a mismatch shows up as a failing assertion, not a vacuous pass.
  final marker = arguments.indexOf('-EncodedCommand');
  if (marker < 3 || marker + 1 >= arguments.length) return arguments;
  final start = marker - 3;
  final encoded = arguments.sublist(start, marker + 2);
  final decoded = decodeRemoteCommand(encoded);
  if (identical(decoded, encoded)) return arguments;
  return <String>[
    ...arguments.sublist(0, start),
    ...decoded,
    ...arguments.sublist(marker + 2),
  ];
}

/// What [MockShell._simulate] decided, before it is shaped into a
/// [ProcessResult] or a [MockProcess].
class _MockOutcome {
  final int exitCode;
  final String stdout;
  final String stderr;

  const _MockOutcome(this.exitCode, this.stdout, this.stderr);
}

class MockProcess implements Process {
  final int _exitCode;
  final List<List<int>> _stdoutChunks;
  final List<List<int>> _stderrChunks;
  final Completer<int> _exited = Completer<int>();
  Timer? _exitTimer;

  /// How many times [kill] was called. `ExecutionBroker.run()` must reap a
  /// timed-out child exactly once, so tests assert on this.
  int killCount = 0;

  /// The signal handed to the last [kill] call, if any.
  ProcessSignal? lastKillSignal;

  /// Everything written to the process's stdin, so a test can pin what was
  /// streamed *into* a command — a root filesystem restore hands its whole
  /// archive over that way and nothing else records it.
  final List<int> stdinBytes = [];
  late final StreamController<List<int>> _stdinController =
      StreamController<List<int>>()..stream.listen(stdinBytes.addAll);

  /// When set, the process stays alive for [delay] before exiting — the shape
  /// of a hung command. [kill] cuts it short.
  ///
  /// [stdoutChunks]/[stderrChunks] override the [stdout]/[stderr] strings and
  /// emit raw bytes in as many stream events as they contain, so tests can pin
  /// that a reader buffers the bytes before decoding rather than decoding each
  /// chunk on its own (a multi-byte sequence can straddle a chunk boundary).
  MockProcess({
    int exitCode = 0,
    String stdout = '',
    String stderr = '',
    List<List<int>>? stdoutChunks,
    List<List<int>>? stderrChunks,
    Duration? delay,
  })  : _exitCode = exitCode,
        _stdoutChunks = stdoutChunks ?? _asChunks(stdout),
        _stderrChunks = stderrChunks ?? _asChunks(stderr) {
    if (delay == null) {
      _exited.complete(exitCode);
    } else {
      _exitTimer = Timer(delay, () {
        if (!_exited.isCompleted) _exited.complete(_exitCode);
      });
    }
  }

  static List<List<int>> _asChunks(String text) =>
      text.isEmpty ? const <List<int>>[] : <List<int>>[utf8.encode(text)];

  @override
  Future<int> get exitCode => _exited.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount++;
    lastKillSignal = signal;
    _exitTimer?.cancel();
    if (_exited.isCompleted) return false;
    _exited.complete(-1);
    return true;
  }

  @override
  int get pid => 123;

  @override
  Stream<List<int>> get stderr => Stream.fromIterable(_stderrChunks);

  @override
  late final IOSink stdin = IOSink(_stdinController.sink);

  @override
  Stream<List<int>> get stdout => Stream.fromIterable(_stdoutChunks);
}

class MockDockerImage extends DockerImage {
  @override
  Future<bool> isDownloaded(String image, {String? tag}) async {
    return false;
  }

  @override
  Future<bool> hasImage(String image, {String? tag}) async {
    return true;
  }

  @override
  Future<bool> getRootfs(String name, String image,
      {String? tag,
      bool skipDownload = false,
      required Function(int, int, int, int) progress}) async {
    progress(100, 100, 100, 100);
    String filename = this.filename(image, tag);
    String path = getDistroPath().file('$filename.tar.gz');
    File(path).createSync(recursive: true);
    File(path).writeAsBytesSync(List.filled(3 * 1024 * 1024, 0));
    return true;
  }
}

class MockChunkedDownloader implements cd.ChunkedDownloader {
  @override
  String url = '';
  @override
  String saveFilePath = '';
  @override
  int chunkSize = 0;
  @override
  cd.ProgressCallback? onProgress;
  @override
  cd.OnDoneCallback? onDone;
  @override
  cd.OnErrorCallback? onError;
  @override
  void Function()? onCancel;
  @override
  void Function()? onPause;
  @override
  void Function()? onResume;
  @override
  ChunkedStreamReader<int>? reader;
  @override
  Map<String, String>? headers;
  @override
  double speed = 0;
  @override
  bool paused = false;
  @override
  bool done = false;

  @override
  Future<cd.ChunkedDownloader> start() async {
    if (onDone != null) {
      onDone!(File(saveFilePath));
    }
    return this;
  }

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  void stop() {}
}

class MockHttpServer extends Stream<HttpRequest> implements HttpServer {
  bool closed = false;

  @override
  Future close({bool force = false}) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }

  @override
  StreamSubscription<HttpRequest> listen(
      void Function(HttpRequest event)? onData,
      {Function? onError,
      void Function()? onDone,
      bool? cancelOnError}) {
    return const Stream<HttpRequest>.empty().listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}

/// A minimal mock shell that returns configurable results.
///
/// Shared: the AI Workspace service tests and the screen tests both drive
/// an [ExecutionBroker] over this rather than each rolling their own.
class TestShell implements Shell {
  String stdoutData = '';
  String stderrData = '';
  int exitCode = 0;
  Duration? artificialDelay;
  bool throwOnRun = false;

  /// Hands back a caller-supplied [Process] from [start] instead of the
  /// canned [MockProcess]. The streamed install path needs a child it can
  /// feed output to over time; everything else is happy with the default.
  Process Function()? processFactory;

  List<String> lastCommand = [];
  List<List<String>> allCommands = [];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments,
      {String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      Encoding? stdoutEncoding,
      Encoding? stderrEncoding}) async {
    if (throwOnRun) throw Exception('shell error');
    lastCommand = [executable, ...arguments];
    allCommands.add([executable, ...arguments]);
    if (artificialDelay != null) await Future.delayed(artificialDelay!);
    return ProcessResult(
      -1, // pid placeholder
      exitCode,
      utf8.encode(stdoutData),
      utf8.encode(stderrData),
    );
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    ProcessStartMode mode = ProcessStartMode.inheritStdio,
    bool runInShell = false,
  }) async {
    if (throwOnRun) throw Exception('shell error');
    lastCommand = [executable, ...arguments];
    allCommands.add([executable, ...arguments]);
    final factory = processFactory;
    if (factory != null) return factory();
    // ExecutionBroker.run() goes through start() so it owns a killable handle;
    // startPersistent() uses the same entry point for keep-alive sessions.
    return MockProcess(
      exitCode: exitCode,
      stdout: stdoutData,
      stderr: stderrData,
      delay: artificialDelay,
    );
  }

  void reset() {
    stdoutData = '';
    stderrData = '';
    exitCode = 0;
    lastCommand.clear();
    allCommands.clear();
    artificialDelay = null;
    throwOnRun = false;
    processFactory = null;
  }
}

/// A [Process] whose output and exit are driven by the test, one chunk at a
/// time.
///
/// [MockProcess] emits everything it has at once and (unless given a delay)
/// has already exited by the time anyone listens, which cannot express "still
/// running, still printing" — the shape the AI workspace install path's
/// silence timeout is built around.
class ControlledProcess implements Process {
  // Single-subscription, like a real process pipe. A broadcast controller
  // drops anything written before someone listens, and its cancel() never
  // completes under a widget test's fake clock — which strands any test that
  // drives an install through the UI.
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exited = Completer<int>();

  /// How many times [kill] was called, so a test can assert the child really
  /// was reaped rather than abandoned.
  int killCount = 0;
  ProcessSignal? lastKillSignal;

  /// What [exitCode] reports once the child has been killed. `-1` is the
  /// ordinary "died on a signal" answer, but `wsl.exe` is a Windows launcher
  /// around a Linux process and a terminated one can still hand back a
  /// perfectly clean `0` — which is why the service decides a killed install
  /// by its abandon reason and not by the exit code.
  int exitCodeOnKill = -1;

  /// WSL writes UTF-16LE, so every ASCII byte is followed by a null one —
  /// this mimics that on the way out, which is what the reader decodes.
  static List<int> _asWslBytes(String text) =>
      utf8.encode(text).expand((byte) => [byte, 0]).toList();

  void emit(String text) {
    if (!_stdout.isClosed) _stdout.add(_asWslBytes(text));
  }

  void emitError(String text) {
    if (!_stderr.isClosed) _stderr.add(_asWslBytes(text));
  }

  /// Ends the process normally with [code].
  void exit([int code = 0]) {
    _close();
    if (!_exited.isCompleted) _exited.complete(code);
  }

  void _close() {
    if (!_stdout.isClosed) _stdout.close();
    if (!_stderr.isClosed) _stderr.close();
  }

  @override
  Future<int> get exitCode => _exited.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount++;
    lastKillSignal = signal;
    _close();
    if (_exited.isCompleted) return false;
    _exited.complete(exitCodeOnKill);
    return true;
  }

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Stream<List<int>> get stdout => _stdout.stream;
}
