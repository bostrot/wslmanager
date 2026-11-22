import 'dart:async';
import 'dart:io';
import 'dart:convert' show Encoding, Utf8Decoder, base64, utf8;
import 'package:wsl2distromanager/api/downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';

import 'package:path/path.dart' as p;
import 'package:wsl2distromanager/api/app.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/remote_command.dart';
import 'package:wsl2distromanager/api/remote_target.dart';
import 'package:wsl2distromanager/api/rootfs_architecture.dart';
import 'package:wsl2distromanager/api/safe_paths.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/execution/models.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/wsl_args.dart';
import 'package:wsl2distromanager/api/wsl_capabilities.dart';
import 'package:wsl2distromanager/api/wsl_conf.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/api/wsl_distribution_conf.dart';
import 'package:wsl2distromanager/api/wslconfig.dart';
import 'package:wsl2distromanager/api/windows_terminal_launcher.dart';
import 'package:wsl2distromanager/api/snippet_env.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/api/cloud_init.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';
import 'package:wsl2distromanager/components/notify.dart';

export 'package:wsl2distromanager/api/vm/vm_backend.dart' show Instances;

/// The command the "no terminal found" dialog offers to copy.
///
/// Named here rather than inlined so the dialog and any future retry path
/// cannot drift apart.
const String installTerminalCommand =
    'sudo apt update && sudo apt install -y xterm';

/// Adapter for unified access to [ExecutionResult] and [ProcessResult].
class _ShellResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  const _ShellResult(this.exitCode, this.stdout, this.stderr);
  factory _ShellResult.fromExecution(ExecutionResult r) =>
      _ShellResult(r.exitCode, r.stdout, r.stderr);
  factory _ShellResult.fromProcess(ProcessResult r) =>
      _ShellResult(r.exitCode, (r.stdout as String?).toString(), (r.stderr as String?).toString());
}

/// Which part of a create is running.
///
/// The phase is what the old status line could not express: it reported
/// `Downloading 100%` and then said nothing for the whole `wsl --import`,
/// which is the slowest part of a create (audit CI-16). A phase change is the
/// signal that the download is over even when nothing else moves.
enum CreatePhase { downloading, extracting, importing }

/// One repaint of a running create, as the UI needs to draw it.
///
/// [fraction] is 0..1 where a real proportion is known and null where it is
/// not — an import has no percentage, and inventing one would be worse than a
/// bar that says so.
class CreateProgress {
  const CreateProgress({
    required this.phase,
    required this.label,
    this.fraction,
  });

  final CreatePhase phase;

  /// Already translated: this is rendered verbatim.
  final String label;

  final double? fraction;
}

/// Formats [bytes] the way the progress line shows it.
///
/// MB below a gigabyte and GB above it, because a rootfs is hundreds of MB and
/// a VHDX is tens of GB, and one unit for both is unreadable at one end.
String formatTransferSize(int bytes) {
  if (bytes < 0) return '';
  const int mb = 1024 * 1024;
  if (bytes >= 1024 * mb) {
    return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
  }
  return '${(bytes / mb).toStringAsFixed(1)} MB';
}

/// `m:ss`, or `h:mm:ss` past an hour. Used by the elapsed counter that runs
/// beside a progress line which can legitimately sit still for minutes.
String formatElapsed(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  final s = (seconds % 60).toString().padLeft(2, '0');
  final m = (seconds ~/ 60) % 60;
  final h = seconds ~/ 3600;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
  return '$m:$s';
}

bool inited = false;

/// This class is used to interact with WSL. It contains all the functions
/// needed to interact with WSL based on Process.run and Process.start.
/// Most functions will return the UTF8 converted stdout of the process.
class WSLApi extends VmBackend {
  final Shell shell;
  final ExecutionBroker? _broker;
  static const Duration _remoteListTimeout = Duration(seconds: 12);

  /// Ceiling for a single in-distro `cat`/`printf`/`chmod`/`test`.
  ///
  /// Generous for the work — these read and write files of a few hundred bytes
  /// — and sized instead for the distro that has to *cold start* to answer,
  /// which is the slow case and takes seconds, not minutes. Anything past this
  /// is a distro that is not coming up, and the settings dialog needs to say so
  /// rather than spin.
  static const Duration _distroFileTimeout = Duration(seconds: 60);

  /// Default ceiling for a `wsl.exe` verb that did not name its own.
  static const Duration _verbTimeout = Duration(minutes: 5);

  /// Whether a [Shell] was handed in. Only tests do that, and it decides which
  /// capability cache this instance reads — see [capabilities].
  final bool _hasInjectedShell;

  WslCapabilityService? _capabilities;

  ExecutionBroker? _lazyBroker;

  /// How [create] fetches a rootfs. Only tests replace it.
  final ChunkedDownloaderFactory _downloaderFactory;

  /// How a start reaches Windows Terminal. Only tests replace it — off a
  /// Windows host it decides nothing.
  final WindowsTerminalLauncher _terminalLauncher;

  WSLApi(
      {Shell? shell,
      ExecutionBroker? broker,
      WslCapabilityService? capabilities,
      ChunkedDownloaderFactory? downloaderFactory,
      WindowsTerminalLauncher? terminalLauncher})
      : shell = shell ?? ProcessShell(),
        _broker = broker,
        _hasInjectedShell = shell != null,
        _capabilities = capabilities,
        _terminalLauncher = terminalLauncher ?? const WindowsTerminalLauncher(),
        _downloaderFactory =
            downloaderFactory ?? defaultChunkedDownloaderFactory {
    if (!inited) {
      inited = true;
      App().getDistroLinks();
    }
  }

  @override
  String get backendId => 'wsl';

  @override
  String get instanceNoun => 'distro';

  @override
  VmFeatures get features => VmFeatures(
        wslConfig: true,
        quickActions: true,
        packaging: true,
        mountDisk: true,
        // The AI Workspace lives in a dedicated distro on the *local*
        // wsl.exe; a macOS host driving a remote target has no local WSL to
        // put it in.
        aiWorkspace: Platform.isWindows,
        cleanup: true,
        hostIntegration: true,
        templatesDeprecated: true,
        rootfsExport: true,
        // The user-data file goes under the profile of the user running
        // wsl.exe; over SSH that profile is on the other machine.
        cloudInit: (localCloudInitOverride ?? Platform.isWindows) && !_useRemoteWsl,
      );

  /// Test seam: stands in for "this host runs wsl.exe itself" so the
  /// cloud-init create path can be exercised on a Mac. Reset to null in
  /// tearDown.
  static bool? localCloudInitOverride;

  /// Where `--version` / `--status` answers come from.
  ///
  /// The app-wide singleton in production, so the probe runs once for the whole
  /// process however many `WSLApi()` instances get constructed. An instance
  /// built around an **injected** shell gets its own service instead: otherwise
  /// a test's fake `wsl.exe` would be overruled by the real one on the
  /// developer's machine, and the code path under test would be chosen by the
  /// host rather than by the fixture.
  WslCapabilityService get capabilities {
    if (_capabilities != null) return _capabilities!;
    if (!_hasInjectedShell) return WslCapabilityService.instance;
    return _capabilities = WslCapabilityService(apiBuilder: () => this);
  }

  /// The broker every command added by Phase 05 runs through.
  ///
  /// `Process.run` hands back no handle, so a `.timeout()` wrapped around it
  /// can only *abandon* the child — the leak this repo already paid for once
  /// as hundreds of orphaned `wsl.exe` processes. [ExecutionBroker.run] spawns
  /// through `Shell.start`, keeps the handle, and reaps on timeout (SIGTERM,
  /// escalating to SIGKILL after 2s). A `--manage --move` of a 40 GB disk that
  /// wedges is then a failed command, not a process nobody can see or stop.
  ///
  /// Built here when the constructor was handed none, because in production
  /// nothing passes one — the `broker` parameter is only ever filled in by
  /// tests and by the remote-execution branches — and "routed through the
  /// broker" has to be true of the shipping app, not just of the test build.
  ExecutionBroker get executionBroker =>
      _broker ?? (_lazyBroker ??= ExecutionBroker(shell: shell));

  bool get _useRemoteWsl {
    final enabled = prefs.getBool('UseRemoteWSL') ?? false;
    final target = prefs.getString('RemoteWSLTarget')?.trim() ?? '';
    return enabled && _isValidRemoteTarget(target);
  }

  bool get useRemoteWsl => _useRemoteWsl;

  @override
  bool get isRemote => _useRemoteWsl;

  @override
  String get remoteLabel => remoteTargetLabel;

  String get remoteTargetLabel {
    final target = prefs.getString('RemoteWSLTarget')?.trim() ?? '';
    return target;
  }

  bool _isValidRemoteTarget(String target) => isValidRemoteTarget(target);

  String get _remoteTarget {
    final target = prefs.getString('RemoteWSLTarget')?.trim() ?? '';
    if (!_isValidRemoteTarget(target)) {
      throw StateError('Invalid remote WSL target configured.');
    }
    return target;
  }

  List<String> get _sshClientOptions => getSshClientOptions();

  String get _remoteRootPath => 'C:\\wsl2dm';

  String _remoteSafeComponent(String value) {
    return replaceSpecialChars(value).replaceAll(RegExp(r'_+'), '_');
  }

  String _remoteDefaultInstallPath(String distribution) {
    return '$_remoteRootPath\\instances\\${_remoteSafeComponent(distribution)}';
  }

  String remoteInstallPath(String distribution) {
    return _remoteDefaultInstallPath(distribution);
  }

  String _remoteInstallPathFor(String distribution) {
    final saved = prefs.getString('Path_$distribution')?.trim() ?? '';
    if (saved.isNotEmpty) {
      return saved;
    }
    return _remoteDefaultInstallPath(distribution);
  }

  String _remoteStagingPath(String distribution, String localPath) {
    return '$_remoteRootPath\\staging\\${_remoteSafeComponent(distribution)}\\${_remoteSafeComponent(p.basename(localPath))}';
  }

  String _remoteParentPath(String remotePath) {
    final lastSeparator = remotePath.lastIndexOf('\\');
    if (lastSeparator <= 0) {
      return remotePath;
    }
    return remotePath.substring(0, lastSeparator);
  }

  String _escapePowerShellSingleQuoted(String input) {
    return input.replaceAll("'", "''");
  }

  /// The remote `.wslconfig`, or null when the host could not be reached.
  ///
  /// The difference matters as much as it does for `/etc/wsl.conf`: an
  /// *unreadable* config must never come back as an *empty* one, or the next
  /// Save writes a file containing nothing but the key the user happened to
  /// touch and the rest of the remote host's configuration is gone. The
  /// PowerShell prints nothing when the file merely does not exist, which is
  /// still exit 0 — a genuinely empty config.
  Future<String?> _readRemoteWslConfigText() async {
    final script =
        r"$p = Join-Path $env:USERPROFILE '.wslconfig'; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw }";
    final result = (_broker != null)
        ? _ShellResult.fromExecution(await _broker!.run(ExecutionRequest(
            command: 'ssh',
            arguments: _buildRemotePowerShell(script),
          )))
        : _ShellResult.fromProcess(await shell.run(
            'ssh',
            _buildRemotePowerShell(script),
            runInShell: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          ));

    if (result.exitCode != 0) {
      logDebug(
          'Could not read the remote .wslconfig on $remoteTargetLabel: '
          '${result.stderr}',
          null,
          null);
      return null;
    }

    return result.stdout;
  }

  Future<void> _writeRemoteWslConfigText(String content) async {
    final escapedContent = _escapePowerShellSingleQuoted(content);
    final script =
        "\$p = Join-Path \$env:USERPROFILE '.wslconfig'; [IO.File]::WriteAllText(\$p, '$escapedContent', [Text.UTF8Encoding]::new(\$false))";

    final result = (_broker != null)
        ? _ShellResult.fromExecution(await _broker!.run(ExecutionRequest(
            command: 'ssh',
            arguments: _buildRemotePowerShell(script),
          )))
        : _ShellResult.fromProcess(await shell.run(
            'ssh',
            _buildRemotePowerShell(script),
            runInShell: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          ));

    if (result.exitCode != 0) {
      throw Exception(
          'Failed to write remote .wslconfig on $remoteTargetLabel: ${result.stderr}');
    }
  }

  /// `mkdir` [path] on the remote host unless it exists. The path is passed
  /// as a plain token: quoting for the host is [_buildRemoteArgs]'s job, and
  /// a pre-quoted `"path"` would reach cmd.exe with the quotes doubled.
  Future<void> _ensureRemoteDirectory(String path) async {
    if (_broker != null) {
      await _broker!.run(ExecutionRequest(
        command: 'ssh',
        arguments: _buildRemoteArgs('cmd', [
          '/c',
          'if',
          'not',
          'exist',
          path,
          'mkdir',
          path,
        ]),
      ));
    } else {
      await shell.run(
        'ssh',
        _buildRemoteArgs('cmd', [
          '/c',
          'if',
          'not',
          'exist',
          path,
          'mkdir',
          path,
        ]),
        runInShell: false,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
    }
  }

  Future<String> _stageLocalFileToRemote(String localPath, String remotePath) async {
    await _ensureRemoteDirectory(_remoteParentPath(remotePath));

    if (_broker != null) {
      await _broker!.run(ExecutionRequest(
        command: 'scp',
        arguments: [
          ..._sshClientOptions,
          localPath,
          '$_remoteTarget:$remotePath',
        ],
      ));
    } else {
      await shell.run(
        'scp',
        [
          ..._sshClientOptions,
          localPath,
          '$_remoteTarget:$remotePath',
        ],
        runInShell: false,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
    }

    return remotePath;
  }

  /// ssh arguments that run [executable] with [args] on the remote Windows
  /// host.
  ///
  /// ssh's own options and the target stay raw — the local ssh consumes them.
  /// The command itself goes through [remoteHostCommand]: `ssh host a b c`
  /// joins the tokens with spaces and the host's *login shell* re-parses the
  /// result, and that shell is cmd.exe, PowerShell or bash depending on how
  /// OpenSSH was set up there. POSIX single quotes, the previous answer, made
  /// every command a parse error on a PowerShell host (bostrot/ai-tasks#21);
  /// see lib/api/remote_command.dart for what survives all three.
  List<String> _buildRemoteArgs(
    String executable,
    List<String> args, {
    bool allocateTty = false,
  }) =>
      sshRemoteCommand(_remoteTarget, executable, args,
          allocateTty: allocateTty);

  /// ssh arguments that run the PowerShell [script] itself on the remote
  /// host, with a failure reported as a non-zero exit code and a plain-text
  /// message on stderr.
  List<String> _buildRemotePowerShell(String script) =>
      sshRemotePowerShell(_remoteTarget, script);

  Future<ProcessResult> _runWsl(
    List<String> args, {
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    if (!_useRemoteWsl) {
      return shell.run(
        'wsl',
        args,
        runInShell: runInShell,
        stdoutEncoding: stdoutEncoding,
        stderrEncoding: stderrEncoding,
      );
    }

    return shell.run(
      'ssh',
      _buildRemoteArgs('wsl', args),
      runInShell: false,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );
  }

  /// Run `wsl <args>` through [executionBroker] and hand back both channels.
  ///
  /// The local/remote split is [_runWsl]'s, so a remote target keeps working;
  /// what is different is that [timeout] is **required** and enforced by a
  /// broker that owns the child. Every Phase-05 verb and every in-distro file
  /// read or write goes through here rather than through [_runWsl], so none of
  /// them can hang the caller forever or leave a `wsl.exe` behind.
  ///
  /// Decoding is the broker's [ExecutionBroker.decodeWslOutput], which is
  /// [utf8Convert] — lenient UTF-8 with the control characters stripped. That
  /// is load-bearing rather than cosmetic: wsl.exe answers `--version`,
  /// `--status` and its own failures in UTF-16, and a strict decoder throws a
  /// `FormatException` on that instead of returning the text.
  Future<WslOutput> _brokeredWsl(
    List<String> args, {
    required Duration timeout,
  }) async {
    final ExecutionRequest request = _useRemoteWsl
        ? ExecutionRequest(
            command: 'ssh',
            arguments: _buildRemoteArgs('wsl', args),
            timeout: timeout,
          )
        : ExecutionRequest(
            command: 'wsl',
            arguments: args,
            timeout: timeout,
          );

    final ExecutionResult result = await executionBroker.run(request);
    if (result.error != null) {
      logDebug('wsl ${args.join(' ')} failed: ${result.error}', null, null);
    }
    return WslOutput(result.exitCode, result.stdout, result.stderr);
  }

  Future<Process> _startWsl(
    List<String> args, {
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
    bool allocateTty = false,
  }) {
    if (!_useRemoteWsl) {
      return shell.start(
        'wsl',
        args,
        runInShell: runInShell,
        mode: mode,
      );
    }

    return shell.start(
      'ssh',
      _buildRemoteArgs('wsl', args, allocateTty: allocateTty),
      runInShell: false,
      mode: mode,
    );
  }

  /// Byte size of a file on the remote host, or null if it doesn't exist or
  /// the check fails.
  Future<int?> _remoteFileSize(String path) async {
    final escapedPath = _escapePowerShellSingleQuoted(path);
    final script =
        "if (Test-Path -LiteralPath '$escapedPath') { (Get-Item -LiteralPath '$escapedPath').Length }";

    final result = (_broker != null)
        ? _ShellResult.fromExecution(await _broker!.run(ExecutionRequest(
            command: 'ssh',
            arguments: _buildRemotePowerShell(script),
          )))
        : _ShellResult.fromProcess(await shell.run(
            'ssh',
            _buildRemotePowerShell(script),
            runInShell: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          ));

    if (result.exitCode != 0) {
      return null;
    }
    return int.tryParse(result.stdout.trim());
  }

  /// Where [distro]'s disk actually lives right now.
  ///
  /// [findVhdxPath] resolves the registry **before** the stored `Path_`
  /// preference, which is the right order for a *current location* question:
  /// the preference goes stale whenever the distro is moved by anything other
  /// than this app, restored from a config, or written by an older version.
  /// [getInstancePath] has the opposite order — it is the "where should a new
  /// instance go" answer, and it writes the preference back — so it is only
  /// the fallback here, for a distro whose disk cannot be found on disk at all.
  @override
  String currentDistroPath(String distro) {
    final vhdx = findVhdxPath(distro);
    if (vhdx != null) return p.dirname(vhdx);
    return getInstancePath(distro).path;
  }

  /// Byte length of [distro]'s `ext4.vhdx`, or 0 when it cannot be found.
  int vhdxSizeBytes(String distro) {
    final vhdx = findVhdxPath(distro);
    if (vhdx == null) return 0;
    try {
      return File(vhdx).lengthSync();
    } on FileSystemException catch (error, stack) {
      logDebug(error, stack, null);
      return 0;
    }
  }

  /// Get distro size of [distroName] a string with a GB suffix.
  /// Returns null if size is 0.
  /// e.g. "2.00 GB"
  @override
  Future<String?> getSize(String distroName) async {
    if (_useRemoteWsl) {
      final vhdxPath = '${_remoteInstallPathFor(distroName)}\\ext4.vhdx';
      final byteSize = await _remoteFileSize(vhdxPath);
      if (byteSize == null || byteSize <= 0) {
        return null;
      }

      final size = byteSize / 1024 / 1024 / 1024;
      return '${'size-text'.i18n()}: ${size.toStringAsFixed(2)} GB';
    }

    // Through findVhdxPath, so a distro moved outside this app still reports a
    // size instead of silently reading as 0 from the stale preference.
    final int byteSize = vhdxSizeBytes(distroName);
    if (byteSize == 0) {
      return null;
    }
    final double size = byteSize / 1024 / 1024 / 1024; // Convert to GB
    return '${'size-text'.i18n()}: ${size.toStringAsFixed(2)} GB';
  }

  @override
  String instanceSizeLabel(String distribution) =>
      getInstanceSize(distribution);

  /// Create directory
  void mkRootDir({String? path}) {
    SafePath(path ?? getDefaultStorageRootPath());
  }

  /// Install WSL
  void installWSL() async {
    if (_useRemoteWsl) {
      final result = await _runWsl(['--install']);
      if (result.exitCode == 0) {
        Notify.message('remoteinstalltriggered-text'.i18n([remoteTargetLabel]),
            severity: InfoBarSeverity.success);
      } else {
        final failure = WslFailure.fromStreams(result.stdout, result.stderr);
        Notify.message(
            '${'remoteinstallfailed-text'.i18n([
              remoteTargetLabel
            ])} ${failure.shortReason}'.trim(),
            severity: InfoBarSeverity.error);
      }
      return;
    }

    shell.start(
        'powershell',
        [
          'Start-Process cmd -ArgumentList "/c wsl --install" -Verb RunAs',
        ],
        mode: ProcessStartMode.detached,
        runInShell: true);
  }

  /// Start a WSL distro by name
  /// Start a WSL distro in a terminal window.
  ///
  /// Returns a future rather than `void` so the caller can report the outcome:
  /// as an `async void` the spawn failure never reached the call site's catch,
  /// and the "started" toast fired before the process existed.
  @override
  Future<void> start(String distribution,
      {String startPath = '',
      String startUser = '',
      String startCmd = ''}) async {
    List<String> wslArgs = [];
    wslArgs.addAll(['-d', distribution]);
    if (startPath != '') {
      wslArgs.addAll(['--cd', startPath]);
    }
    if (startUser != '') {
      wslArgs.addAll(['--user', startUser]);
    }
    if (startCmd != '') {
      // Deliberately NOT wslShellArgs(): this is the one call site that
      // *wants* wsl.exe's default-shell re-parse. The trailing `;/bin/sh`
      // only becomes a second command because the distro's shell re-parses
      // the flattened argv, and that is what keeps the terminal window open
      // after startCmd finishes. Adding `--exec` here would exec `;/bin/sh`
      // as a literal argument instead. See lib/api/wsl_args.dart.
      for (String cmd in splitShellArgs(startCmd)) {
        wslArgs.add(cmd);
      }
      // Run shell to keep open
      wslArgs.add(';/bin/sh');
    }

    // When remote, `args` must include the literal 'ssh' executable token:
    // unlike _runWsl/_startWsl (which pass 'ssh' as the process executable
    // directly), this method launches via Windows `start`/`wt`/a terminal
    // executable, which needs 'ssh' as part of the argument list it hands
    // off — _buildRemoteArgs only returns ssh's own options, not 'ssh'
    // itself.
    List<String> args = _useRemoteWsl
        ? ['ssh', ..._buildRemoteArgs('wsl', wslArgs, allocateTty: true)]
        : ['wsl', ...wslArgs];

    String executable = 'start';
    String? terminal = prefs.getString('Terminal');
    if (terminal != null && terminal.isNotEmpty) {
      executable = terminal;
    }

    // A distro's colours, font and opacity live in its Windows Terminal
    // profile, and `wsl -d <name>` reaches none of it: the window that opens
    // does not know which distro it is showing and uses the default profile.
    // The launcher turns the command into `wt -w 0 nt -p <name> …`, which is
    // the same tab Windows Terminal's own dropdown opens.
    final launch = _terminalLauncher.resolve(
      instance: distribution,
      executable: executable,
      arguments: args,
      remote: _useRemoteWsl,
    );
    executable = launch.executable;
    args = launch.arguments;

    if (Platform.isLinux) {
      await _startLinuxTerminal(args);
      if (kDebugMode) {
        print("Done starting $distribution");
      }
      return;
    }
    if (_useRemoteWsl && Platform.isMacOS) {
      await _startMacosTerminal(args);
      if (kDebugMode) {
        print("Done starting $distribution");
      }
      return;
    }

    await shell.start(executable, args,
        mode: ProcessStartMode.detached, runInShell: true);
    if (kDebugMode) {
      print("Done starting $distribution");
    }
  }

  @override
  /// Stop a WSL distro by name
  Future<String> stop(String distribution) async {
    ProcessResult results = await _runWsl(['--terminate', distribution]);
    return results.stdout;
  }

  /// Open bashrc with notepad from WSL
  Future<String> openBashrc(String distribution) async {
    String editor = prefs.getString('Editor') ?? 'notepad.exe';
    // See start() for why 'ssh' must be included explicitly here.
    List<String> argsRc = _useRemoteWsl
        ? ['ssh', ..._buildRemoteArgs('wsl', ['-d', distribution, editor, '.bashrc'])]
        : ['wsl', '-d', distribution, editor, '.bashrc'];

    if (Platform.isLinux) {
      await _startLinuxTerminal(argsRc);
      return '';
    }
    if (_useRemoteWsl && Platform.isMacOS) {
      await _startMacosTerminal(argsRc);
      return '';
    }

    Process results = await shell.start('start', argsRc,
        mode: ProcessStartMode.normal, runInShell: true);
    return results.stdout.toString();
  }

  /// Shutdown WSL
  @override
  Future<String> shutdown() async {
    ProcessResult results = await _runWsl(['--shutdown']);
    return results.stdout;
  }

  /// Start VSCode
  /// Home directory of the distro's default user, or '' if it can't be read.
  Future<String> getDefaultUserHome(String distribution) async {
    try {
      final result = await _runWsl(
          wslShellArgs(distribution, 'echo \$HOME', shell: 'sh'),
          stdoutEncoding: null,
          stderrEncoding: null);
      if (result.exitCode != 0) return '';
      final raw = result.stdout;
      final home =
          (raw is List<int> ? utf8Convert(raw) : raw.toString()).trim();
      return home.startsWith('/') ? home : '';
    } catch (error, stack) {
      logError(error, stack, null);
      return '';
    }
  }

  Future<void> startVSCode(String distribution, {String path = ''}) async {
    String codeCmd = prefs.getString('VSCodeCmd') ?? 'code';
    if (codeCmd.isEmpty) {
      codeCmd = 'code';
    }

    // Without a target `code` opens an empty window rather than the distro's
    // file system, so fall back to the default user's home.
    var target = path;
    if (target.isEmpty) {
      target = await getDefaultUserHome(distribution);
    }

    final wslArgs = <String>[
      '-d',
      distribution,
      codeCmd,
      if (target != '') target,
    ];
    // See start() for why 'ssh' must be included explicitly here. The path
    // is part of the remote command, so it goes in before _buildRemoteArgs
    // wraps that command for the host's shell — appended afterwards it would
    // land behind the wrapper instead of inside it.
    List<String> args = _useRemoteWsl
        ? ['ssh', ..._buildRemoteArgs('wsl', wslArgs)]
        : ['wsl', ...wslArgs];

    if (Platform.isLinux) {
      await _startLinuxTerminal(args);
      return;
    }
    if (_useRemoteWsl && Platform.isMacOS) {
      await _startMacosTerminal(args);
      return;
    }

    // /b keeps `start` from opening a console window that sticks around for
    // as long as the VS Code launcher runs.
    shell.start('start', ['/b', ...args],
        mode: ProcessStartMode.normal, runInShell: true);
  }


  /// Read `%UserProfile%\.wslconfig` as a mutable, section-aware model, or null
  /// when the file could not be read at all.
  ///
  /// A machine with no `.wslconfig` reads as an **empty** config, not an error,
  /// and the file is *not* created as a side effect of reading it — the old
  /// [readConfig] called `createSync()` on the read path, so merely opening
  /// Settings left an empty `.wslconfig` behind on a machine that never had
  /// one.
  ///
  /// Null is reserved for "could not read": an unreachable remote host, or a
  /// local file that exists and will not open. Handing an empty config back for
  /// those would let the next Save replace the whole file with the one key the
  /// user touched — the same distinction [readWSLConf] draws for `wsl.conf`.
  Future<WslConfigFile?> readWslConfig() async {
    if (_useRemoteWsl) {
      final String? text = await _readRemoteWslConfigText();
      return text == null ? null : WslConfigFile.parse(text);
    }

    final File file = File(getWslConfigPath());
    if (!file.existsSync()) {
      return WslConfigFile.empty();
    }
    try {
      return WslConfigFile.parse(file.readAsStringSync());
    } on FileSystemException catch (error, stack) {
      logError(error, stack, null);
      return null;
    }
  }

  /// Write [config] back, whole file at once.
  ///
  /// Whole-file is the point: the old [setConfig] ran one unanchored
  /// `replaceAll` per key across the entire text, which is where the
  /// section-blindness (CC-3), the case-sensitivity (CC-4) and the
  /// comment-absorbing write (CC-5) all came from. Returns whether the write
  /// succeeded so a Save can say so instead of assuming.
  Future<bool> writeWslConfig(WslConfigFile config) async {
    try {
      if (_useRemoteWsl) {
        await _writeRemoteWslConfigText(config.serialize());
        return true;
      }

      final File file = File(getWslConfigPath());
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(config.serialize());
      return true;
    } catch (error, stack) {
      logError(error, stack, null);
      return false;
    }
  }

  /// Read, [mutate] and write back `.wslconfig` in one pass.
  ///
  /// A config that could not be read is not written: the rest of the file is
  /// not ours to replace with the one key we were asked to change.
  Future<bool> updateWslConfig(
      void Function(WslConfigFile config) mutate) async {
    final WslConfigFile? config = await readWslConfig();
    if (config == null) return false;
    mutate(config);
    return writeWslConfig(config);
  }

  /// Set one `.wslconfig` key, in the section WSL will actually read it from.
  Future<bool> setConfig(String key, String value) => updateWslConfig(
      (config) => config.set(config.sectionFor(key), key, value));

  /// Remove one `.wslconfig` key so its documented default applies again.
  Future<bool> removeConfig(String key) =>
      updateWslConfig((config) => config.remove(config.sectionFor(key), key));

  /// Every documented key currently in `.wslconfig`, by key name. Empty when
  /// the file could not be read.
  Future<Map<String, String>> readConfig() async =>
      (await readWslConfig())?.flatten() ?? <String, String>{};


  /// Open wslconfig file
  void editConfig() async {
    if (_useRemoteWsl) {
      Notify.message('remoteconfignotsupported-text'.i18n(),
          severity: InfoBarSeverity.warning);
      return;
    }

    String editor = prefs.getString('Editor') ?? 'notepad.exe';
    shell.start('start', ['""', editor, getWslConfigPath()],
        mode: ProcessStartMode.normal, runInShell: true);
  }

  /// Launch [command] in a fresh Terminal.app window — macOS's stand-in for
  /// the Windows `start` verb when this backend drives a remote target from
  /// a Mac. A `.command` file avoids the automation-permission prompt an
  /// AppleScript approach would raise.
  Future<void> _startMacosTerminal(List<String> command) async {
    String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
    final script =
        '#!/bin/bash\nexec ${command.map(quote).join(' ')}\n';
    final scriptPath = getTmpPath().file('remote_terminal.command');
    File(scriptPath).writeAsStringSync(script);
    await shell.run('chmod', ['+x', scriptPath], runInShell: false);
    await shell.start('open', [scriptPath],
        mode: ProcessStartMode.detached, runInShell: false);
  }

  Future<bool> _startLinuxTerminal(List<String> command) async {
    final launchAttempts = <List<String>>[
      ['xdg-terminal-exec', ...command],
      ['kgx', ...command],
      ['kitty', ...command],
      ['alacritty', '-e', ...command],
      ['wezterm', 'start', '--', ...command],
      ['x-terminal-emulator', '-e', ...command],
      ['gnome-terminal', '--', ...command],
      ['konsole', '-e', ...command],
      ['xfce4-terminal', '-x', ...command],
      ['xterm', '-e', ...command],
    ];

    for (final attempt in launchAttempts) {
      try {
        await shell.start(
          attempt.first,
          attempt.sublist(1),
          mode: ProcessStartMode.detached,
        );
        return true;
      } catch (_) {
        continue;
      }
    }

    await _showMissingTerminalDialog();
    return false;
  }

  Future<void> _showMissingTerminalDialog() async {
    final rootContext = GlobalVariable.infobox.currentContext;
    if (rootContext == null) {
      Notify.message('terminalnotfoundbody-text'.i18n(),
          severity: InfoBarSeverity.warning);
      return;
    }

    await showDialog(
      useRootNavigator: false,
      context: rootContext,
      builder: (context) {
        return ContentDialog(
          title: Text('terminalnotfound-text'.i18n()),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('terminalnotfoundbody-text'.i18n()),
              const SizedBox(height: 8.0),
              SelectableText(installTerminalCommand),
            ],
          ),
          actions: [
            // The old body named three packages and stopped there. Handing
            // over the command is the part the user was missing (IA-20).
            Button(
              key: const ValueKey('test-terminal-copy-command'),
              onPressed: () {
                Clipboard.setData(
                    const ClipboardData(text: installTerminalCommand));
                Notify.message('commandcopied-text'.i18n(),
                    severity: InfoBarSeverity.success);
              },
              child: Text('copycommand-text'.i18n()),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text('close-text'.i18n()),
            ),
          ],
        );
      },
    );
  }

  String _windowsPathToSftpUriPath(String windowsPath) {
    final normalized = windowsPath.replaceAll('\\', '/');
    if (normalized.length > 2 && normalized[1] == ':') {
      return '/${normalized[0]}:${normalized.substring(2)}';
    }
    return '/$normalized';
  }

  /// Start Explorer
  @override
  void startExplorer(String distribution) async {
    if (_useRemoteWsl) {
      if (Platform.isLinux || Platform.isMacOS) {
        final remotePath = _windowsPathToSftpUriPath(
          _remoteDefaultInstallPath(distribution),
        );
        final uri = 'sftp://$_remoteTarget$remotePath';
        await shell.start(Platform.isLinux ? 'xdg-open' : 'open', [uri],
            mode: ProcessStartMode.detached, runInShell: false);
        return;
      }

      if (_broker != null) {
        await _broker!.run(ExecutionRequest(
          command: 'ssh',
          arguments: _buildRemoteArgs(
              'explorer.exe', [_remoteDefaultInstallPath(distribution)]),
        ));
      } else {
        await shell.run(
          'ssh',
          _buildRemoteArgs(
              'explorer.exe', [_remoteDefaultInstallPath(distribution)]),
          runInShell: false,
        );
      }
      return;
    }

    final path = getInstancePath(distribution).path;
    if (Platform.isWindows) {
      await shell.start('start', ['explorer.exe', path],
          mode: ProcessStartMode.normal, runInShell: true);
      return;
    }

    await shell.start('xdg-open', [path],
        mode: ProcessStartMode.detached, runInShell: false);
  }

  /// Start Windows Terminal or PowerShell
  void startWindowsTerminal(String distribution) async {
    // See start() for why 'ssh' must be included explicitly here.
    List<String> launchWslHome = _useRemoteWsl
        ? ['ssh', ..._buildRemoteArgs('wsl', ['-d', distribution, '--cd', '~'])]
        : ['wsl', '-d', distribution, '--cd', '~'];

    if (_useRemoteWsl && Platform.isLinux) {
      await _startLinuxTerminal(launchWslHome);
      return;
    }
    if (_useRemoteWsl && Platform.isMacOS) {
      await _startMacosTerminal(launchWslHome);
      return;
    }

      try {
        // Run windows terminal in same window wt -w 0 nt, dressed in the
        // instance's own profile.
        final launch = _terminalLauncher.resolve(
          instance: distribution,
          executable: 'wt',
          arguments: launchWslHome,
          remote: _useRemoteWsl,
        );
        var args = [launch.executable, ...launch.arguments];

        if (_broker != null) {
          await _broker!.run(ExecutionRequest(command: 'start', arguments: args));
        } else {
          await shell.run('start', args);
        }
      } catch (_) {
        // Windows Terminal not installed
        Notify.message('openwithwt-not-found-error'.i18n());

        var args = ['powershell', '-noexit', '-command', launchWslHome.join(' ')];
        if (_broker != null) {
          await _broker!.run(ExecutionRequest(command: 'start', arguments: args, runInShell: true));
        } else {
          await shell.run('start', args, runInShell: true);
        }
      }
  }

  /// Copy a WSL distro by name
  @override
  Future<String> copy(String distribution, String newName) async {
    String exportPath;
    if (_useRemoteWsl) {
      exportPath = _remoteStagingPath(distribution, '$distribution.ext4');
      await _ensureRemoteDirectory(_remoteParentPath(exportPath));
    } else {
      exportPath = getInstancePath(distribution).file('$distribution.ext4');
    }

    // Copy
    String exportRes = await export(distribution, exportPath);
    String importRes = await import(
      newName,
      _useRemoteWsl ? '' : getInstancePath(newName).path,
      exportPath,
    );

    // Cleanup, delete file
    if (_useRemoteWsl) {
      if (_broker != null) {
        await _broker!.run(ExecutionRequest(
          command: 'ssh',
          arguments: _buildRemoteArgs('cmd', ['/c', 'del', '/q', exportPath]),
        ));
      } else {
        await shell.run(
          'ssh',
          _buildRemoteArgs('cmd', ['/c', 'del', '/q', exportPath]),
          runInShell: false,
        );
      }
    } else {
      File file = File(exportPath);
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
    return '$exportRes $importRes';
  }

  /// Copy a WSL distro by name and vhd
  Future<String> copyVhd(String name, String newName) async {
    if (_useRemoteWsl) {
      String vhdPath = '${_remoteDefaultInstallPath(name)}\\ext4.vhdx';
      String copyPath = _remoteStagingPath(name, 'ext4.copy.vhdx');

      await _ensureRemoteDirectory(_remoteParentPath(copyPath));
      final copyResult = (_broker != null)
          ? _ShellResult.fromExecution(await _broker!.run(ExecutionRequest(
              command: 'ssh',
              arguments: _buildRemoteArgs('cmd',
                  ['/c', 'copy', '/Y', vhdPath, copyPath]),
            )))
          : _ShellResult.fromProcess(await shell.run(
              'ssh',
              _buildRemoteArgs('cmd',
                  ['/c', 'copy', '/Y', vhdPath, copyPath]),
              runInShell: false,
            ));

      if (copyResult.exitCode != 0) {
        return 'File not found';
      }

      String importRes = await import(newName, '', copyPath, isVhd: true);

      if (_broker != null) {
        await _broker!.run(ExecutionRequest(
          command: 'ssh',
          arguments: _buildRemoteArgs('cmd', ['/c', 'del', '/q', copyPath]),
        ));
      } else {
        await shell.run(
          'ssh',
          _buildRemoteArgs('cmd', ['/c', 'del', '/q', copyPath]),
          runInShell: false,
        );
      }
      return importRes;
    }

    String vhdPath = getInstancePath(name).file('ext4.vhdx');
    String copyPath = getInstancePath(name).file('ext4.copy.vhdx');
    // Copy path to new location so instance doesn't have to be stopped
    File file = File(vhdPath);
    if (file.existsSync()) {
      file.copySync(copyPath);
    } else {
      return 'File not found';
    }

    String importRes = await import(
        newName, getInstancePath(newName).path, copyPath,
        isVhd: true);

    // Cleanup, delete file
    File file2 = File(copyPath);
    if (file2.existsSync()) {
      file2.deleteSync();
    }
    return importRes;
  }

  /// Export a WSL distro by name.
  ///
  /// [format] is `wsl --export --format <tar|tar.gz|tar.xz|vhd>`. Omitted, the
  /// export is an uncompressed tar, which is what every existing caller has
  /// always produced and what they keep producing. `.wsl` packaging passes
  /// `tar.gz`, the format `build-custom-distro.md` recommends — "other
  /// compression formats run the risk of breaking compatibility with older WSL
  /// versions". The flag itself needs WSL 2.4.4, so callers gate on
  /// [WslCapabilities.supportsWslPackages] before passing it.
  @override
  Future<String> export(String distribution, String location,
      {String? format}) async {
    ProcessResult results = await _runWsl([
      '--export',
      distribution,
      location,
      if (format != null) ...['--format', format],
    ], stdoutEncoding: null, stderrEncoding: null);

    // Check if the export command was successful
    if (results.exitCode != 0) {
      String errorMsg = utf8Convert(results.stderr ?? []);
      throw Exception(
          'WSL export failed with exit code ${results.exitCode}: $errorMsg');
    }

    return utf8Convert(results.stdout);
  }

  /// Remove a WSL distro by name.
  /// Uses Process.start with a timeout to avoid hanging on stuck distros.
  @override
  Future<String> remove(String distribution) async {
    final timeout = const Duration(seconds: 30);
    Process process;

    try {
      process = await _startWsl(['--unregister', distribution]);
    } catch (e) {
      throw Exception('Failed to start WSL unregister: $e');
    }

    // Capture stdout/stderr as raw bytes (matching _runWsl behavior)
    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    process.stdout.cast<List<int>>().forEach(stdoutBytes.addAll);
    process.stderr.cast<List<int>>().forEach(stderrBytes.addAll);

    // Kill the process if it takes too long
    final timer = Timer(timeout, () {
      process.kill();
    });

    final result = await process.exitCode;
    timer.cancel();

    if (result != 0) {
      final errorMsg = utf8Convert(stderrBytes);
      throw Exception(
          'WSL unregister failed with exit code $result: $errorMsg');
    }

    // Settings keyed by distro name would otherwise be inherited by the next
    // instance created under the same name.
    await clearDistroPrefs(distribution);
    // So would a cloud-init user-data file the create flow left behind (a
    // crash mid-create, a first boot that never confirmed it finished).
    if (!_useRemoteWsl) await CloudInitFiles.remove(distribution);

    // Check if folder is empty and delete
    if (!_useRemoteWsl) {
      String path = getInstancePath(distribution).path;
      // Wait 10 seconds in async then delete for Windows to release file
      Future.delayed(const Duration(seconds: 10), () {
        Directory dir = Directory(path);
        if (dir.existsSync()) {
          if (dir.listSync().isEmpty) {
            dir.deleteSync(recursive: true);
          }
        }
      });
    }
    return utf8Convert(stdoutBytes);
  }

  /// Install a WSL distro by name
  Future<String> install(String distribution) async {
    ProcessResult results = await _runWsl(['--install', '-d', distribution]);
    return results.stdout;
  }

  List<String> resultQueue = [];

  /// Get the current cached output
  String getCurrentOutput() {
    String tmp = resultQueue.join('\n');
    resultQueue = [];
    return tmp;
  }

  /// Executes a command list in a WSL distro
  Future<List<int>> execCmds(
    String distribution,
    List<String> cmds, {
    String? user,
    required Function(String) onMsg,
    required Function onDone,
    bool showOutput = true,
  }) async {
    List<int> processes = [];
    Process result = await _startWsl(
      ['-d', distribution, '-u', user ?? 'root'],
      mode: ProcessStartMode.normal,
      runInShell: !_useRemoteWsl,
      allocateTty: _useRemoteWsl,
    );

    Timer currentWaiter = Timer(const Duration(seconds: 60), () {
      result.kill();
      onDone();
    });

    result.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .listen((String line) {
      resultQueue.add(line);
      onMsg(line);
      currentWaiter.cancel();
      // No new output within the last 30 seconds
      currentWaiter = Timer(const Duration(seconds: 15), () {
        result.kill();
        onDone();
      });
    });

    // Log output to file
    result.stdin.writeln('script -B /tmp/currentsessionlog -f');
    // Start windows with output
    await _startWsl(
      wslExecArgs(
        distribution,
        const ['tail', '-n', '+1', '-f', '/tmp/currentsessionlog'],
        user: user ?? 'root',
      ),
      mode: showOutput ? ProcessStartMode.detached : ProcessStartMode.normal,
      runInShell: !_useRemoteWsl,
      allocateTty: _useRemoteWsl,
    );

    // Delay to allow tail to start
    await Future.delayed(const Duration(milliseconds: 500));

    for (var cmd in cmds) {
      result.stdin.writeln(cmd);
    }
    return processes;
  }

  @override
  Future<void> runCommands(String instance, List<String> commands,
          {String? user, Map<String, String> env = const {}}) =>
      runCmds(instance, commands, user: user, env: env);

  /// Executes a command list in a WSL distro and open a terminal
  Future<Process> runCmds(
    String distribution,
    List<String> cmds, {
    String? user,
    Map<String, String> env = const {},
  }) async {
    // Write commands to /tmp/cmds
    Process fileProcess = await _startWsl(
      ['-d', distribution, '-u', user ?? 'root'],
      mode: ProcessStartMode.normal,
      runInShell: !_useRemoteWsl,
      allocateTty: _useRemoteWsl,
    );

    fileProcess.stdin.writeln('echo "#!/bin/bash" > /tmp/wdmcmds');
    // The snippet's environment goes in first, and unlike the snippet's own
    // lines it is escaped for this writer: it carries what the user typed,
    // and a `$` or a backtick in a password would otherwise be expanded here
    // — while the script is being written — instead of landing in it.
    for (final line in SnippetEnv.exportLines(env)) {
      fileProcess.stdin.writeln('echo "${_echoLiteral(line)}" >> /tmp/wdmcmds');
    }
    for (var cmd in cmds) {
      cmd = cmd.replaceAll('"', '\\"');
      fileProcess.stdin.writeln('echo "$cmd" >> /tmp/wdmcmds');
    }
    var waitCmd = 'read -n1 -r -p \\"\n\nDone running the action. '
        'Press any key to exit...\\" key';
    fileProcess.stdin.writeln('echo "$waitCmd" >> /tmp/wdmcmds');

    // Wait for commands to be written
    await Future.delayed(const Duration(milliseconds: 500));

    // Execute commands in /tmp/cmds
    List<String> args = wslExecArgs(
      distribution,
      const ['/bin/bash', '/tmp/wdmcmds'],
      user: user ?? 'root',
    );

    Process results = await _startWsl(
      args,
      runInShell: !_useRemoteWsl,
      mode: ProcessStartMode.detached,
      allocateTty: _useRemoteWsl,
    );

    return results;
  }

  /// Keeps a line literal through the `echo "…" >> /tmp/wdmcmds` writer,
  /// which is itself a shell.
  static String _echoLiteral(String line) => line
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\$', '\\\$')
      .replaceAll('`', '\\`');

  /// Executes a shell command in a WSL distro as root and returns its stdout.
  ///
  /// [cmd] is a *shell* command, not argv — callers pass pipelines,
  /// redirections and quoted arguments, and `WslMcpTools` forwards whatever
  /// the MCP client asks for — so it goes to `bash -c` as a single argument
  /// via [wslShellArgs].
  ///
  /// This used to append `splitShellArgs(cmd)` to the argument list and leave
  /// the rest to wsl.exe's default-shell re-parse. That silently corrupted
  /// every command carrying quotes: the split strips them, wsl.exe re-joins
  /// the pieces with spaces, and the shell inside the distro then parses the
  /// unquoted result. `runInShell` is false for the same class of reason —
  /// `cmd.exe /c` would eat `&`, `|`, `<`, `>` and `^` before wsl.exe ever
  /// saw them. See lib/api/wsl_args.dart.
  @override
  Future<String> execCmdAsRoot(String distribution, String cmd) async {
    ProcessResult results = await _runWsl(
        wslShellArgs(distribution, cmd, user: 'root'),
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8);
    return results.stdout;
  }

  /// Starts a persistent interactive shell process in a WSL distro (its
  /// default shell, reading commands from stdin) rather than running one
  /// command and exiting. Same underlying spawn as [execCmds]/[runCmds]'s
  /// first step, exposed directly for callers (e.g. the MCP terminal tools)
  /// that need to drive a session across multiple calls: write lines to
  /// `process.stdin`, read `process.stdout`/`process.stderr` as they arrive,
  /// and `process.kill()` when done.
  @override
  Future<Process> startShell(String distribution, {String? user}) {
    return _startWsl(
      ['-d', distribution, '-u', user ?? 'root'],
      mode: ProcessStartMode.normal,
      runInShell: !_useRemoteWsl,
      allocateTty: _useRemoteWsl,
    );
  }

  /// Executes a command in a WSL distro. passwd will open a shell.
  ///
  /// The `passwd` branch opens a console window *outside* the app, and it used
  /// to be fire-and-forget: `start` hands its child to a new console and exits
  /// at once, so awaiting its exit code awaited nothing. The create flow
  /// reported success while the user was still typing into a window the app
  /// does not own, and closing that window without setting a password left the
  /// account passwordless with no sign of it (audit CI-13). `start /wait`
  /// makes the await real; the caller checks afterwards whether a password was
  /// actually set.
  Future<List<int>> exec(String distribution, List<String> cmds) async {
    List<String> args;
    List<int> processes = [];
    int exitCode;
    for (String cmd in cmds) {
      if (cmd.contains('passwd')) {
        // See start() for why 'ssh' must be included explicitly here.
        // The command is part of what the host runs, so it joins the wsl
        // argv before _buildRemoteArgs wraps it — see startVSCode.
        final wslArgs = <String>['-d', distribution, ...splitShellArgs(cmd)];
        args = _useRemoteWsl
            ? ['ssh', ..._buildRemoteArgs('wsl', wslArgs, allocateTty: true)]
            : ['wsl', ...wslArgs];
        if (_useRemoteWsl && Platform.isLinux) {
          await _startLinuxTerminal(args);
          exitCode = 0;
        } else if (_useRemoteWsl && Platform.isMacOS) {
          await _startMacosTerminal(args);
          exitCode = 0;
        } else {
          // `""` is the console title `start` would otherwise take the first
          // quoted argument for; `/wait` is what makes the exit code below
          // belong to the password prompt rather than to `start` itself.
          Process result = await shell.start('start', ['', '/wait', ...args],
              mode: ProcessStartMode.normal, runInShell: true);
          exitCode = await result.exitCode;
        }
        processes.add(exitCode);
      } else {
        // A shell command, not argv: create_dialog feeds this lines like
        // `echo 'someone ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/wslsudo`.
        // Splitting it here stripped the quotes and left the bare `(` for
        // wsl.exe's default-shell re-parse to choke on. Hand the whole string
        // to `bash -c` instead. See lib/api/wsl_args.dart.
        args = wslShellArgs(distribution, cmd);
        ProcessResult result = await _runWsl(args, runInShell: false);
        exitCode = result.exitCode;
        processes.add(exitCode);
      }
    }
    return processes;
  }

  /// Restart WSL
  Future<String> restart() async {
    ProcessResult results = await _runWsl(['--shutdown']);
    results = await _runWsl(['--shutdown']);
    return results.stdout;
  }

  /// Import a WSL distro by name
  @override
  Future<String> import(
      String distribution, String installLocation, String filename,
      {bool isVhd = false}) async {
    if (_useRemoteWsl) {
      if (installLocation.trim().isEmpty) {
        installLocation = _remoteDefaultInstallPath(distribution);
      }
      await _ensureRemoteDirectory(_remoteParentPath(installLocation));
      await _ensureRemoteDirectory(installLocation);
      if (File(filename).existsSync()) {
        filename = await _stageLocalFileToRemote(
          filename,
          _remoteStagingPath(distribution, filename),
        );
      }
    } else {
      if (installLocation == '') {
        installLocation = getInstancePath(distribution).path;
      } else {
        installLocation = SafePath(installLocation).path;
      }
    }
    ProcessResult results;
    if (isVhd) {
      results = await _runWsl(
          ['--import', distribution, installLocation, filename, '--vhd'],
          stdoutEncoding: null, stderrEncoding: null);
    } else {
      results = await _runWsl(
          ['--import', distribution, installLocation, filename],
          stdoutEncoding: null, stderrEncoding: null);
    }

    // Check if the import command was successful
    if (results.exitCode != 0) {
      String errorMsg = utf8Convert(results.stderr ?? []);
      throw Exception(
          'WSL import failed with exit code ${results.exitCode}: $errorMsg');
    }

    return utf8Convert(results.stdout);
  }

  /// Import a WSL distro by name.
  ///
  /// [status] is the one-line status bar text and stays as it was. [onProgress]
  /// is the structured version the create screen draws a bar from, and
  /// [cancelSignal] makes the whole thing abortable: the download is stopped at
  /// the socket and the `wsl --import` child is killed and unregistered, which
  /// is the only way out of a multi-GB install that does not involve killing
  /// the app (audit CI-14, CI-16).
  Future<dynamic> create(String distribution, String filename,
      String installPath, Function(String) status,
      {bool image = false,
      bool isVhd = false,
      void Function(CreateProgress)? onProgress,
      CancelSignal? cancelSignal}) async {
    if (_useRemoteWsl) {
      if (installPath.trim().isEmpty) {
        installPath = _remoteDefaultInstallPath(distribution);
      }
      await _ensureRemoteDirectory(_remoteParentPath(installPath));
      await _ensureRemoteDirectory(installPath);
    } else {
      if (installPath == '') {
        installPath = getInstancePath(distribution).path;
      } else {
        installPath = SafePath(installPath).path;
      }
    }

    // Download
    var dataPath = getDataPath()..cd('distros');
    String downloadPath = dataPath.file('$filename.tar.gz');
    bool fileExists = await File(downloadPath).exists();
    if (!image && distroRootfsLinks[filename] != null && !fileExists) {
      String url = distroRootfsLinks[filename]!;
      try {
        await _downloadRootfs(url, downloadPath, status,
            onProgress: onProgress, cancelSignal: cancelSignal);
      } on CancelledException {
        // Nothing was registered and the package deleted its own `.tmp`, so
        // there is nothing to undo — and nothing to report as a failure
        // either. The caller distinguishes this from an error.
        rethrow;
      } catch (error) {
        // Strip the leading exception class only. A blanket
        // `replaceAll('Exception: ', '')` turns `HttpException: HTTP 404`
        // into `HttpHTTP 404`, which is what the create screen showed.
        final message = error
            .toString()
            .replaceFirst(RegExp(r'^[A-Za-z]*Exception: '), '');
        status('${'errordownloading-text'.i18n()} $filename');
        // Do not fall through to `wsl --import`: the file is missing or
        // partial, and importing it would either fail with an unrelated WSL
        // error or register a broken distro. Report the download failure with
        // the same shape a failed `wsl.exe` has, so the caller's existing
        // error path shows it.
        return ProcessResult(0, 1, '',
            '${'errordownloading-text'.i18n()} $filename: $message');
      }
    }

    // Downloaded or extracted
    if (!image && distroRootfsLinks[filename] == null) {
      downloadPath = filename;
    }

    if (_useRemoteWsl) {
      downloadPath = await _stageLocalFileToRemote(
        downloadPath,
        _remoteStagingPath(distribution, downloadPath),
      );
    }

    cancelSignal?.throwIfCancelled();

    // Create from local file
    List<String> args = ['--import', distribution, installPath, downloadPath];
    if (isVhd) {
      args.add('--vhd');
    }

    return _runImport(distribution, args,
        onProgress: onProgress, cancelSignal: cancelSignal);
  }

  /// Runs `wsl --import` so that it can be watched and stopped.
  ///
  /// Two things [_runWsl] cannot do. The import is the slowest step of a
  /// create and reports nothing at all, so the caller was left showing
  /// `Downloading 100%` for minutes (audit CI-16); an elapsed counter ticking
  /// once a second beside a phase that says "Importing" is the cheapest
  /// honest signal, and a frozen line next to a moving clock is unambiguous.
  /// And `Process.run` hands back no handle, so there was nothing to kill when
  /// the user asked to stop (audit CI-14).
  ///
  /// A killed import can leave the distro half-registered, so the cancel path
  /// unregisters it — best effort, because there is nothing useful to say if
  /// that fails too.
  Future<ProcessResult> _runImport(
    String distribution,
    List<String> args, {
    void Function(CreateProgress)? onProgress,
    CancelSignal? cancelSignal,
  }) async {
    if (onProgress == null && cancelSignal == null) {
      // Nothing to watch and nothing to stop: keep the cheap path, which is
      // also the one every existing test exercises.
      return _runWsl(args, stdoutEncoding: null);
    }

    final stopwatch = Stopwatch()..start();
    void report() => onProgress?.call(CreateProgress(
          phase: CreatePhase.importing,
          label: '${'importing-text'.i18n()} '
              '${formatElapsed(stopwatch.elapsed)}',
        ));
    report();
    final ticker = onProgress == null
        ? null
        : Timer.periodic(const Duration(seconds: 1), (_) => report());

    final Process process = await _startWsl(args);
    var cancelled = false;
    void kill() {
      cancelled = true;
      unawaited(ExecutionBroker.terminate(process));
    }

    cancelSignal?.onCancel(kill);
    try {
      // Collected before the exit code is awaited: a child whose pipes fill up
      // blocks instead of exiting.
      final stdoutBytes = <int>[];
      final stderrBytes = <int>[];
      final drained = <Future<void>>[
        process.stdout.forEach(stdoutBytes.addAll),
        process.stderr.forEach(stderrBytes.addAll),
      ];
      final exitCode = await process.exitCode;
      await Future.wait(drained)
          .timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
      if (cancelled) {
        // The import got as far as registering the name on some paths, and a
        // half-imported distro is worse than none: it lists, it will not
        // start, and the same name cannot be used again.
        try {
          await _runWsl(['--unregister', distribution]);
        } catch (_) {
          // Never registered, or WSL is unreachable — either way the create
          // is over and this is the last thing it does.
        }
        throw const CancelledException();
      }
      return ProcessResult(process.pid, exitCode, stdoutBytes, stderrBytes);
    } finally {
      ticker?.cancel();
      stopwatch.stop();
      if (cancelSignal != null) cancelSignal.removeListener(kill);
    }
  }

  /// Fetches [url] to [savePath], or throws with a reason the UI can show.
  ///
  /// Everything here is a guard against a download that *looks* like it
  /// worked, which is what the old code shipped:
  ///
  /// * [ChunkedDownloader.start] is **awaited**. It used to be a `..start()`
  ///   cascade, which threw the returned future away — so the `HttpException`
  ///   a 404 raises never reached a `catch`, `done` was only ever set on the
  ///   success path, and the poll loop that waited on it spun forever. A dead
  ///   catalogue URL hung the create dialog instead of reporting an error.
  /// * [savePath] is handed over as-is. The package downloads to
  ///   `'$savePath.tmp'` and renames that onto [savePath] itself; passing it a
  ///   path that already ended in `.tmp` and renaming again here is what left
  ///   `<name>.tar.gz.tmp.tmp` behind, and that second rename was not awaited.
  /// * A stale `.tmp` is removed first. The package *appends* to it, so a
  ///   leftover from a killed run would be glued in front of the new download.
  /// * The finished file is checked against the `Content-Length` the server
  ///   announced. The package's read loop ends on any short chunk, so a
  ///   connection cut mid-transfer renames a partial file into place and
  ///   reports success; `wsl --import` then fails on a truncated archive with
  ///   no hint that the download was the problem.
  /// * A [cancelSignal] stops it at the socket. [ChunkedDownloader.stop]
  ///   breaks the read loop and deletes its own `.tmp`, and it returns
  ///   *normally* afterwards — so the cancel has to be detected here rather
  ///   than caught, or the size check below reports the user's own cancel as
  ///   "the server returned an empty file".
  Future<void> _downloadRootfs(
      String url, String savePath, Function(String) status,
      {void Function(CreateProgress)? onProgress,
      CancelSignal? cancelSignal}) async {
    cancelSignal?.throwIfCancelled();
    final tmpFile = File('$savePath.tmp');
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }

    // -1 until the first progress callback. Stays -1 for a server that sends
    // no Content-Length, which is not an error — it only means the size check
    // below has nothing to compare against.
    int expectedBytes = -1;
    final downloader = _downloaderFactory(
      url: url,
      saveFilePath: savePath,
      onProgress: (int count, int total, double speed) {
        expectedBytes = total;
        // Without a Content-Length `total` is -1, and the percentage the old
        // code printed counted *downwards* through negative numbers. Show
        // megabytes instead.
        status(total > 0
            ? '${'downloading-text'.i18n()} '
                '${(count / total * 100).toStringAsFixed(0)}%'
            : '${'downloading-text'.i18n()} '
                '${(count / 1024 / 1024).toStringAsFixed(0)} MB');
        // The bar gets bytes and a rate as well as the percentage: a
        // percentage alone cannot tell a slow download from a stopped one,
        // which is half of what CI-16 measured.
        onProgress?.call(CreateProgress(
          phase: CreatePhase.downloading,
          fraction: total > 0 ? (count / total).clamp(0.0, 1.0) : null,
          label: total > 0
              ? '${'downloading-text'.i18n()} '
                  '${(count / total * 100).toStringAsFixed(0)}% '
                  '(${formatTransferSize(count)} / '
                  '${formatTransferSize(total)}, '
                  '${formatTransferSize(speed.round())}/s)'
              : '${'downloading-text'.i18n()} '
                  '${formatTransferSize(count)} '
                  '(${formatTransferSize(speed.round())}/s)',
        ));
      },
    );
    void stop() => downloader.stop();
    cancelSignal?.onCancel(stop);
    try {
      await downloader.start();
    } finally {
      if (cancelSignal != null) cancelSignal.removeListener(stop);
    }
    cancelSignal?.throwIfCancelled();

    final file = File(savePath);
    final actualBytes = await file.exists() ? await file.length() : -1;
    if (actualBytes <= 0) {
      throw Exception('the server returned an empty file');
    }
    if (expectedBytes > 0 && actualBytes != expectedBytes) {
      // Leaving it on disk would poison every later create: the cache is keyed
      // on the file existing, not on it being complete.
      await file.delete();
      throw Exception(
          'incomplete download, got $actualBytes of $expectedBytes bytes');
    }
  }

  /// A POSIX user name this app is willing to interpolate into a shell script.
  ///
  /// Same reasoning as [isPlainDistroPath]: [createUser] hands its script to
  /// `sh -c`, so an unchecked name is code, not data. Refuse rather than quote
  /// — there is no legitimate user name with a space or a `;` in it.
  static bool isPlainUserName(String user) =>
      RegExp(r'^[a-z_][a-z0-9_-]{0,31}$').hasMatch(user);

  /// The script [createUser] runs. Exposed for tests.
  ///
  /// Written for `/bin/sh`, not bash, and it detects the package manager
  /// rather than assuming `apt-get`. The version this replaced ran
  /// `apt-get update`, `apt-get install -y sudo`,
  /// `useradd -m -s /bin/bash -G sudo <user>` through `bash -c`, which failed
  /// on thirteen of the nineteen catalogue entries: Alpine has no `bash` at
  /// all (every command exited 1), and Fedora, Rocky, AlmaLinux, openSUSE,
  /// SLES and Arch have no `apt-get` (127) and no `sudo` *group* — `useradd
  /// -G sudo` exits 6 with `group 'sudo' does not exist`, so no user was
  /// created there either.
  static String buildUserSetupScript(String user) {
    // Installing sudo needs the network and is allowed to fail: a user with a
    // home directory and a login shell is still worth having, and the sudoers
    // drop-in below costs nothing if sudo shows up later.
    const installSudo = '''
if ! command -v sudo >/dev/null 2>&1; then
if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo >/dev/null 2>&1;
elif command -v dnf >/dev/null 2>&1; then dnf install -y -q sudo >/dev/null 2>&1;
elif command -v microdnf >/dev/null 2>&1; then microdnf install -y sudo >/dev/null 2>&1;
elif command -v yum >/dev/null 2>&1; then yum install -y -q sudo >/dev/null 2>&1;
elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive --quiet install sudo >/dev/null 2>&1;
elif command -v apk >/dev/null 2>&1; then apk add --no-cache sudo >/dev/null 2>&1;
elif command -v pacman >/dev/null 2>&1; then pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1; pacman -Sy --noconfirm --needed sudo >/dev/null 2>&1;
fi
fi''';

    // Alpine's minirootfs has no bash, so `-s /bin/bash` would hand the new
    // user a login shell that does not exist. `sudo` and `wheel` are split by
    // family — Debian/Ubuntu/Kali use `sudo`, everyone else uses `wheel` —
    // and `getent` is absent on a busybox userland, hence /etc/group.
    return '''
set -u
u=$user
$installSudo
sh=/bin/sh
[ -x /bin/bash ] && sh=/bin/bash
grp=
for g in sudo wheel; do if cut -d: -f1 /etc/group | grep -qx \$g; then grp=\$g; break; fi; done
if [ -z "\$grp" ]; then
if command -v groupadd >/dev/null 2>&1; then groupadd wheel >/dev/null 2>&1 && grp=wheel;
elif command -v addgroup >/dev/null 2>&1; then addgroup wheel >/dev/null 2>&1 && grp=wheel; fi
fi
if ! id -u \$u >/dev/null 2>&1; then
if command -v useradd >/dev/null 2>&1; then
if [ -n "\$grp" ]; then useradd -m -s \$sh -G \$grp \$u; else useradd -m -s \$sh \$u; fi
elif command -v adduser >/dev/null 2>&1; then
adduser -D -s \$sh \$u && { [ -z "\$grp" ] || addgroup \$u \$grp; }
else
echo 'no useradd or adduser in this distro' >&2; exit 1
fi
fi
id -u \$u >/dev/null 2>&1 || { echo 'user was not created' >&2; exit 1; }
mkdir -p /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\\n' \$u > /etc/sudoers.d/wslsudo
chmod 0440 /etc/sudoers.d/wslsudo
if [ -f /etc/sudoers ] && ! grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers; then printf '#includedir /etc/sudoers.d\\n' >> /etc/sudoers; fi
exit 0''';
  }

  /// Creates [user] inside [distribution] with a home, a login shell that
  /// exists there, and passwordless sudo. Returns the process result so the
  /// caller can show stderr when it fails.
  ///
  /// Runs through `sh`, not `bash` — see [buildUserSetupScript].
  Future<ProcessResult> createUser(String distribution, String user) async {
    if (!isPlainUserName(user)) {
      return ProcessResult(0, 1, '', 'Invalid user name: $user');
    }
    return _runWsl(
      wslShellArgs(distribution, buildUserSetupScript(user),
          user: 'root', shell: 'sh'),
      runInShell: false,
    );
  }

  /// Whether [user] in [distribution] actually has a password set.
  ///
  /// The password is typed into a console window the app does not own, so the
  /// only way to know whether the user set one — rather than closing the
  /// window — is to ask afterwards (audit CI-13). `passwd -S` prints
  /// `<user> P ...` for a usable password and `NP` (none) or `L` (locked) for
  /// the two ways of having none.
  ///
  /// Null when the question cannot be answered: busybox `passwd` has no `-S`,
  /// and guessing "no password" there would warn about a distro that is fine.
  Future<bool?> hasPassword(String distribution, String user) async {
    if (!isPlainUserName(user)) return null;
    final result = await _runWsl(
      wslShellArgs(distribution, 'passwd -S $user 2>/dev/null',
          user: 'root', shell: 'sh'),
      runInShell: false,
    );
    if (result.exitCode != 0) return null;
    final fields = result.stdout.toString().trim().split(RegExp(r'\s+'));
    if (fields.length < 2) return null;
    return fields[1] == 'P';
  }

  /// Returns list of WSL distros
  @override
  Future<Instances> list(bool showDocker) async {
    ProcessResult results;
    try {
      results = await _runWsl(['--list', '--quiet'], stdoutEncoding: null)
          .timeout(_useRemoteWsl ? _remoteListTimeout : const Duration(days: 1));
    } on TimeoutException {
      if (_useRemoteWsl) {
        throw Exception(
            'Remote WSL host unreachable: timed out while connecting to $remoteTargetLabel.');
      }
      throw Exception('WSL list timed out.');
    } on ProcessException catch (e) {
      if (_useRemoteWsl) {
        throw Exception(
            'Remote WSL SSH connection failed for $remoteTargetLabel: ${e.message}');
      }
      rethrow;
    }

    String output = utf8Convert(results.stdout);
    String stderr = utf8Convert(results.stderr is List<int>
      ? results.stderr as List<int>
      : utf8.encode(results.stderr?.toString() ?? ''));

    if (results.exitCode != 0) {
      final combined = [stderr.trim(), output.trim()]
        .where((part) => part.isNotEmpty)
        .join('\n');

      final lowerCombined = combined.toLowerCase();
      final hasAskpassIssue = lowerCombined.contains('ssh_askpass') ||
        lowerCombined.contains('askpass') ||
        lowerCombined.contains('libcrypto');
      if (hasAskpassIssue && _useRemoteWsl) {
      throw Exception(
        'Remote SSH authentication is not available in non-interactive mode for $remoteTargetLabel. Configure key-based SSH authentication (or an ssh-agent) and retry.\n$combined');
      }

      // Keep existing UX for genuinely empty setups while surfacing real failures.
      final likelyNoDistro =
        lowerCombined.contains('no installed distributions') ||
          lowerCombined.contains('distributions can be installed') ||
          lowerCombined.contains('keine installierten distributionen') ||
          lowerCombined.contains(
            'distribution kann mit folgenden befehlen installiert werden');
      if (likelyNoDistro) {
      lastDistroList = Instances([], []);
      return lastDistroList;
      }

      throw Exception(combined.isEmpty
        ? 'Failed to list WSL distros (exit code ${results.exitCode}).'
        : combined);
    }
    List<String> list = [];
    bool wslInstalled = true;
    // Check if wsl is installed
    if (output.contains('wsl.exe') || output.contains('ProcessException')) {
      wslInstalled = false;
    }
    if (wslInstalled) {
      if (output.contains('ERROR_FILE_NOT_FOUND')) {
        return lastDistroList;
      }
      output.split('\n').forEach((line) {
        final cleanLine = _sanitizeDistroName(line);
        var dockerfilter = showDocker
            ? true
            : (!cleanLine.startsWith('docker-desktop-data') &&
                !cleanLine.startsWith('docker-desktop'));
        // Filter out docker data
        if (cleanLine.isNotEmpty && dockerfilter) {
          list.add(cleanLine);
        }
      });
      List<String> running;
      try {
        running = await listRunning();
      } catch (_) {
        running = lastDistroList.running;
      }
      lastDistroList = Instances(list, running);
      return Instances(list, running);
    } else {
      return Instances(['wslNotInstalled'], []);
    }
  }

  /// Bytes still available on the volume holding [path], or null when the
  /// query fails (non-Windows, unmapped drive, permission error).
  Future<int?> freeSpaceBytes(String path) async {
    if (!Platform.isWindows) return null;
    final escaped = _escapePowerShellSingleQuoted(path);
    try {
      final result = (_broker != null)
          ? _ShellResult.fromExecution(await _broker!.run(ExecutionRequest(
              command: 'powershell',
              arguments: [
                '-NoProfile',
                '-Command',
                "[System.IO.DriveInfo]::new('$escaped').AvailableFreeSpace"
              ],
            )))
          : _ShellResult.fromProcess(await shell.run('powershell', [
              '-NoProfile',
              '-Command',
              "[System.IO.DriveInfo]::new('$escaped').AvailableFreeSpace"
            ]));
      if (result.exitCode != 0) return null;
      return int.tryParse(result.stdout.toString().trim());
    } catch (error, stack) {
      logError(error, stack, null);
      return null;
    }
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  /// Clean up WSL distros. Compacting the VHDX file.
  Future<String> cleanup(String distribution,
      {Function(String)? onProgress, bool force = false}) async {
    if (_useRemoteWsl) {
      try {
        onProgress?.call('stopping-distro'.i18n());
        await stop(distribution);

        onProgress?.call('compacting-vdisk'.i18n());
        final remoteInstallPath = _remoteInstallPathFor(distribution);
        final vhdxPath = '$remoteInstallPath\\ext4.vhdx';
        final escapedVhdxPath = _escapePowerShellSingleQuoted(vhdxPath);
        final scriptName =
            'wsl2dm_diskpart_${_remoteSafeComponent(distribution)}.txt';
        final escapedScriptName = _escapePowerShellSingleQuoted(scriptName);
        final script = """
\$ErrorActionPreference = 'Stop'
\$vhdxPath = '$escapedVhdxPath'
if (-not (Test-Path -LiteralPath \$vhdxPath)) {
  throw "VHDX file not found: \$vhdxPath"
}
\$scriptPath = Join-Path \$env:TEMP '$escapedScriptName'
\$diskpartScript = @"
select vdisk file="\$vhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
"@
[IO.File]::WriteAllText(\$scriptPath, \$diskpartScript, [Text.Encoding]::ASCII)
try {
  & diskpart /s "\$scriptPath"
  if (\$LASTEXITCODE -ne 0) {
    throw "Diskpart failed with exit code \$LASTEXITCODE"
  }
} finally {
  if (Test-Path -LiteralPath \$scriptPath) {
    Remove-Item -LiteralPath \$scriptPath -Force -ErrorAction SilentlyContinue
  }
}
""";

        final compactResult = (_broker != null)
            ? _ShellResult.fromExecution(await _broker!.run(ExecutionRequest(
                command: 'ssh',
                arguments: _buildRemotePowerShell(script),
              )))
            : _ShellResult.fromProcess(await shell.run(
                'ssh',
                _buildRemotePowerShell(script),
                runInShell: false,
                stdoutEncoding: utf8,
                stderrEncoding: utf8,
              ));

        if (compactResult.exitCode != 0) {
          throw Exception(compactResult.stderr.trim().isNotEmpty
              ? compactResult.stderr
              : compactResult.stdout.trim().isNotEmpty
                  ? compactResult.stdout
                  : 'Remote diskpart compaction failed');
        }

        return 'Cleanup completed successfully';
      } catch (error, stack) {
        logError(error, stack, null);
        throw Exception('Cleanup failed: ${error.toString()}');
      }
    }

    final vhdxPath = findVhdxPath(distribution);
    if (vhdxPath == null) {
      throw Exception('VHDX file not found for "$distribution". Looked in:\n'
          '${vhdxPathCandidates(distribution).join('\n')}');
    }
    // Keep the stored path in step with where the disk actually is.
    prefs.setString('Path_$distribution', SafePath(vhdxPath).parent);

    // diskpart writes the compacted image alongside the original, so a drive
    // with less free space than the disk is large runs full mid-compact and
    // leaves the distro unusable.
    if (!force) {
      final vhdxSize = File(vhdxPath).lengthSync();
      final free = await freeSpaceBytes(SafePath(vhdxPath).parent);
      if (free != null && free < vhdxSize) {
        throw Exception('compact-nospace-text'
            .i18n([_formatBytes(vhdxSize), _formatBytes(free)]));
      }
    }

    try {
      // Step 1: Stop the distribution
      onProgress?.call('stopping-distro'.i18n());
      await stop(distribution);

      // Step 2: Create diskpart script
      onProgress?.call('compacting-vdisk'.i18n());
      String scriptContent = 'select vdisk file="$vhdxPath"\n'
          'attach vdisk readonly\n'
          'compact vdisk\n'
          'detach vdisk';

      // Use temp path for script after sanitizing distro name
      final safeDistribution =
          distribution.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      String scriptPath = getTmpPath().file('diskpart_$safeDistribution.txt');
      File(scriptPath).writeAsStringSync(scriptContent);

      try {
        // Step 3: Run diskpart with admin privileges
        // We use PowerShell to elevate the process and capture its exit code
        var result = (_broker != null)
            ? _ShellResult.fromExecution(await _broker!.run(ExecutionRequest(
                command: 'powershell',
                arguments: [
                  '-Command',
                  '\$p = Start-Process diskpart -ArgumentList "/s \\"$scriptPath\\"" -Verb RunAs -Wait -PassThru; exit \$p.ExitCode'
                ],
              )))
            : _ShellResult.fromProcess(await shell.run('powershell', [
                '-Command',
                '\$p = Start-Process diskpart -ArgumentList "/s \\"$scriptPath\\"" -Verb RunAs -Wait -PassThru; exit \$p.ExitCode'
              ]));

        if (result.exitCode != 0) {
          throw Exception(
              'Diskpart failed with exit code ${result.exitCode}: ${result.stderr}');
        }
      } finally {
        // Step 4: Cleanup script
        final scriptFile = File(scriptPath);
        if (scriptFile.existsSync()) {
          scriptFile.deleteSync();
        }
      }

      return 'Cleanup completed successfully';
    } catch (error, stack) {
      logError(error, stack, null);
      throw Exception('Cleanup failed: ${error.toString()}');
    }
  }

  /// Returns list of WSL distros
  @override
  Future<List<String>> listRunning() async {
    ProcessResult results;
    try {
      results =
          await _runWsl(['--list', '--running', '--quiet'], stdoutEncoding: null)
              .timeout(_useRemoteWsl
                  ? _remoteListTimeout
                  : const Duration(days: 1));
    } on TimeoutException {
      if (_useRemoteWsl) {
        return lastDistroList.running;
      }
      rethrow;
    } on ProcessException {
      if (_useRemoteWsl) {
        return lastDistroList.running;
      }
      rethrow;
    }

    String output = utf8Convert(results.stdout);
    String stderr = utf8Convert(results.stderr is List<int>
      ? results.stderr as List<int>
      : utf8.encode(results.stderr?.toString() ?? ''));

    if (results.exitCode != 0) {
      final combined = [stderr.trim(), output.trim()]
        .where((part) => part.isNotEmpty)
        .join('\n');
      throw Exception(combined.isEmpty
        ? 'Failed to list running WSL distros (exit code ${results.exitCode}).'
        : combined);
    }

    List<String> list = [];
    output.split('\n').forEach((line) {
      final cleanLine = _sanitizeDistroName(line);
      // Filter out docker data
      if (cleanLine.isNotEmpty) {
        list.add(cleanLine);
      }
    });
    return list;
  }

  String _sanitizeDistroName(String value) {
    return value
        .replaceAll('\u0000', '')
        .replaceAll('\r', '')
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
        .trim();
  }

  /// Returns list of downloadable WSL distros
  Future<List<String>> getDownloadable(
      String repo, Function(String) onError) async {
    // Get list of distros from git
    distroRootfsLinks = await App().getDistroLinks();
    // Get list of distros from custom repo link and try to format
    final scraped = <String, String>{};
    try {
      await Dio().get(repo).then((value) => {
            value.data.split('\n').forEach((line) {
              if (line.contains('tar.gz') && line.contains('href=')) {
                var parts = line.split(RegExp(r'href=["' ']'));
                if (parts.length < 2) return;
                String filename = parts[1].split(RegExp(r'["' ']'))[0];

                if (!filename.endsWith('.tar.gz')) return;

                String name = filename
                    .replaceAll('.tar.gz', '')
                    .replaceAll('1_amd64', '')
                    .replaceAll(RegExp(r'-|_'), ' ')
                    .replaceAllMapped(RegExp(r' .|^.'),
                        (Match m) => m[0].toString().toUpperCase());
                scraped.addAll({name: repo + filename});
              }
            })
          });
    } catch (e) {
      onError(e.toString());
    }
    // A scraped directory listing is not a catalogue: the only thing that says
    // which architecture a file is built for is its name. Read through the
    // same filter as `images.json`, so a Windows-on-ARM machine is not offered
    // the x86-64 appliances it cannot run.
    distroRootfsLinks
        .addAll(rootfsLinksFor(scraped, rootfsHostArchitecture()));
    List<String> list = [];
    list.addAll(distroRootfsLinks.keys);
    return list;
  }

  /// Whether two paths name the same directory.
  ///
  /// Case-insensitive on Windows, where the remote branch always is: the remote
  /// host is a Windows machine even when this app is not running on one.
  bool _isSamePath(String a, String b) {
    final canonicalA = p.canonicalize(a);
    final canonicalB = p.canonicalize(b);
    if (Platform.isWindows || _useRemoteWsl) {
      return canonicalA.toLowerCase() == canonicalB.toLowerCase();
    }
    return canonicalA == canonicalB;
  }

  /// Where a move of [distro] would currently go: the supported one-liner, or
  /// the export → unregister → import fallback.
  ///
  /// Public so the confirmation dialog can say which one it is about to run.
  /// #280 is a user who clicked **Move**, came back to a closed app and a
  /// missing distro; naming the destructive path before starting it is exactly
  /// what that report asked for.
  Future<bool> supportsNativeMove() async =>
      (await capabilities.load()).supportsManage;

  /// Move WSL distro to another location by [distro] and [newPath].
  ///
  /// Prefers `wsl --manage <distro> --move <path>` (WSL 2.5+), which is one
  /// supported operation that never unregisters anything. The export →
  /// unregister → import path below is kept only for older builds: it is
  /// careful — size floor, recovery marker, startup recovery dialog — but it
  /// has a window in which the distro exists **only** as a tar file, and that
  /// window is what #280 fell into (audit cli-flags CC-2, P05-15).
  ///
  /// The fallback is never used as a *recovery* from a failed native move: if
  /// wsl.exe has the verb and the verb failed, the reason is reported and the
  /// distro is left alone. Retrying a failure with the destructive path is how
  /// a recoverable error becomes an unrecoverable one.
  Future<String> move(String distro, String newPath) async {
    if (await supportsNativeMove()) {
      // Only the remote branch has a documented default location to fall back
      // to. Locally, an empty target would canonicalize to the process's
      // working directory, which is not where anyone means to put a distro.
      final targetPath = newPath.trim().isEmpty
          ? (_useRemoteWsl ? _remoteDefaultInstallPath(distro) : '')
          : newPath;
      if (targetPath.isEmpty) {
        throw Exception("Cannot move '$distro': no target path was given.");
      }
      final currentPath = _useRemoteWsl
          ? _remoteInstallPathFor(distro)
          : currentDistroPath(distro);
      if (_isSamePath(currentPath, targetPath)) {
        throw Exception(
            "Cannot move '$distro': new path must be different from current path ($currentPath).");
      }

      // A running distro holds its VHD open. `--manage` reports that as a
      // failure rather than working around it, so terminate first — this is a
      // per-distro stop, not a global shutdown.
      await stop(distro);

      final result = await manageMove(distro, targetPath);
      if (result.ok) {
        await prefs.setString('Path_$distro', targetPath);
        return result.text;
      }
      throw Exception('WSL move failed: ${result.text}');
    }

    if (_useRemoteWsl) {
      final targetPath = newPath.trim().isEmpty
          ? _remoteDefaultInstallPath(distro)
          : newPath;

      // Same safety net as the local branch below: refuse a no-op move
      // instead of exporting/removing/reimporting for nothing.
      final currentPath = _remoteInstallPathFor(distro);
      if (_isSamePath(currentPath, targetPath)) {
        throw Exception(
            "Cannot move '$distro': new path must be different from current path ($currentPath).");
      }

      String exportFilePath = _remoteStagingPath(distro, 'export.ext4');
      await _ensureRemoteDirectory(_remoteParentPath(exportFilePath));

      await export(distro, exportFilePath);

      // Verify the export actually produced something before touching the
      // original — a truncated/empty remote export must not be allowed to
      // reach remove(). We don't have an easy way to read the original
      // vhdx size from here the way the local branch does, so this uses
      // the same conservative 1MB floor the local branch applies to small
      // distros.
      const minSize = 1024 * 1024;
      final exportSize = await _remoteFileSize(exportFilePath);
      if (exportSize == null || exportSize < minSize) {
        throw Exception(
            "Export failed or file too small (<${minSize ~/ (1024 * 1024)}MB). Aborting move to prevent data loss.");
      }

      // Recovery marker — same mechanism the local branch uses (surfaced by
      // the startup recovery dialog in lib/nav/init.dart) so an interrupted
      // remote move is recoverable too.
      await prefs.setString('MoveOp_Distro', distro);
      await prefs.setString(
          'MoveOp_BackupPath', '$remoteTargetLabel:$exportFilePath');

      await remove(distro);

      try {
        var res = await import(distro, newPath, exportFilePath);
        if (_broker != null) {
          await _broker!.run(ExecutionRequest(
            command: 'ssh',
            arguments: _buildRemoteArgs(
                'cmd', ['/c', 'del', '/q', exportFilePath]),
          ));
        } else {
          await shell.run(
            'ssh',
            _buildRemoteArgs(
                'cmd', ['/c', 'del', '/q', exportFilePath]),
            runInShell: false,
          );
        }

        prefs.setString('Path_$distro', targetPath);
        await prefs.remove('MoveOp_Distro');
        await prefs.remove('MoveOp_BackupPath');
        return res;
      } catch (e) {
        throw Exception(
            "Import failed: $e. Your data is safe in: $exportFilePath. Please do not delete this file.");
      }
    }

    SafePath path = SafePath(newPath);
    String exportFilePath = path.file('export.ext4');

    // Check if new path is same as old path (normalize + absolute paths, compare case-insensitive on Windows)
    String currentPath = currentDistroPath(distro);
    if (_isSamePath(currentPath, path.path)) {
      throw Exception(
          "Cannot move '$distro': new path must be different from current path (${p.canonicalize(currentPath)}).");
    }

    // Export
    await export(distro, exportFilePath);

    // Verify export
    File exportFile = File(exportFilePath);

    // Get original VHDX size to determine safety threshold. Resolved through
    // findVhdxPath: a stale `Path_` reads as "no VHD", which silently drops
    // the export floor from 10MB to 1MB on exactly the large distros the
    // higher floor exists to protect.
    final int vhdxSize = vhdxSizeBytes(distro);

    // Determine minimum safe size based on original VHDX
    // If VHDX is large (>1GB), expect at least 10MB export to catch "header-only" corruptions.
    // Otherwise, expect at least 1MB to support minimal distros like Alpine.
    int minSize =
        (vhdxSize > 1024 * 1024 * 1024) ? 10 * 1024 * 1024 : 1024 * 1024;

    if (!exportFile.existsSync() || exportFile.lengthSync() < minSize) {
      if (exportFile.existsSync()) {
        exportFile.deleteSync();
      }
      throw Exception(
          "Export failed or file too small (<${minSize ~/ (1024 * 1024)}MB). Aborting move to prevent data loss.");
    }

    // Set recovery marker
    await prefs.setString('MoveOp_Distro', distro);
    await prefs.setString('MoveOp_BackupPath', exportFilePath);

    // Remove old
    await remove(distro);

    // Import new
    try {
      var res = await import(distro, newPath, exportFilePath);

      // Cleanup export file only if import succeeded
      await exportFile.delete();

      // Update preference
      prefs.setString('Path_$distro', newPath);

      // Clear recovery marker
      await prefs.remove('MoveOp_Distro');
      await prefs.remove('MoveOp_BackupPath');

      return res;
    } catch (e) {
      throw Exception(
          "Import failed: $e. Your data is safe in: $exportFilePath. Please do not delete this file.");
    }
  }

  /// The backend-neutral in-instance run: `wsl -d <distro> --exec bash -c`,
  /// with the exit code kept. See [VmBackend.runInInstance].
  @override
  Future<VmCommandOutput> runInInstance(
    String instance,
    String command, {
    String user = 'root',
    String cwd = '',
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final out = await runVerb([
      '-d',
      instance,
      if (cwd.isNotEmpty) ...['--cd', cwd],
      '-u',
      user.trim().isEmpty ? 'root' : user.trim(),
      '--exec',
      'bash',
      '-c',
      command,
    ], timeout: timeout);
    return VmCommandOutput(out.exitCode, out.stdout, out.stderr);
  }

  @override
  Future<String?> readInstanceFile(String instance, String path) =>
      readDistroFile(instance, path);

  @override
  Future<bool> writeInstanceFile(
          String instance, String path, String content) =>
      writeDistroFile(instance, path, content);

  /// Read [path] from inside [distro] as root.
  ///
  /// Returns null when the distro could not be reached at all, which is the
  /// difference that keeps every update-in-place caller safe: a *missing* file
  /// is an empty file and may be created, but an *unreadable* one must never
  /// be overwritten with just the key the user happened to toggle. The
  /// `2>/dev/null; exit 0` makes bash's own status say only "the distro ran
  /// this", leaving wsl.exe free to report the failures that matter.
  ///
  /// [path] is interpolated into the script, so it is checked against
  /// [isPlainDistroPath] first and refused rather than quoted. Every caller
  /// names an `/etc` constant, so nothing legitimate is turned away.
  Future<String?> readDistroFile(String distro, String path) async {
    if (!isPlainDistroPath(path)) {
      logDebug('Refusing to read $path from $distro: not a plain path', null,
          null);
      return null;
    }

    final WslOutput result = await _brokeredWsl(
        wslShellArgs(distro, 'cat $path 2>/dev/null; exit 0',
            user: 'root', shell: 'sh'),
        timeout: _distroFileTimeout);

    if (!result.ok) {
      logDebug(
          'Could not read $path from $distro: ${result.stderr}', null, null);
      return null;
    }
    return result.stdout;
  }

  /// Write [content] to [path] inside [distro] as root, whole file at once.
  ///
  /// The payload travels base64-encoded. That is not obfuscation: the old
  /// `wsl.conf` writer interpolated the value into a `sed` expression and into
  /// an `echo -e "…"` that ran as root, so a `/` broke the write and a `"` or
  /// a `$(…)` ran as a command (audit CC-2, CC-7). base64's alphabet has no
  /// character a shell interprets, so there is nothing left to escape.
  ///
  /// Pass [mode] to `chmod` the file afterwards — `build-custom-distro.md`'s
  /// configuration recommendations call for `0644` on both config files, and
  /// an OOBE script WSL cannot execute is a distro whose first launch fails.
  ///
  /// Returns whether the file was actually written — a read-only filesystem
  /// fails the redirection and the caller has to say so instead of reporting a
  /// change that never happened.
  ///
  /// The base64 encoding covers the *payload*; the redirection target is the
  /// half it cannot cover, because `> $path` has to be shell syntax for the
  /// redirection to happen at all. [isPlainDistroPath] closes that half.
  ///
  /// Runs through `sh`, not bash. The script is plain POSIX, and Alpine's
  /// minirootfs — a catalogue entry — has no bash at all, so this and
  /// [readDistroFile] failed there with `execvpe(bash) failed`. That is what
  /// left a freshly created Alpine instance with no `/etc/wsl.conf` and hence
  /// no default user, even after the account itself was created.
  Future<bool> writeDistroFile(String distro, String path, String content,
      {String? mode}) async {
    if (!isPlainDistroPath(path)) {
      logDebug(
          'Refusing to write $path in $distro: not a plain path', null, null);
      return false;
    }

    final String payload = base64.encode(utf8.encode(content));
    final WslOutput result = await _brokeredWsl(
        wslShellArgs(distro, "printf %s '$payload' | base64 -d > $path",
            user: 'root', shell: 'sh'),
        timeout: _distroFileTimeout);

    if (!result.ok) {
      logDebug(
          'Could not write $path in $distro: ${result.stderr}', null, null);
      return false;
    }

    if (mode != null) {
      final WslOutput chmod = await _brokeredWsl(
          wslExecArgs(distro, ['chmod', mode, path], user: 'root'),
          timeout: _distroFileTimeout);
      if (!chmod.ok) {
        logDebug('Could not chmod $mode $path in $distro: ${chmod.stderr}',
            null, null);
        return false;
      }
    }
    return true;
  }

  /// Which of [paths] exist inside [distro], in one round trip.
  ///
  /// Only literal absolute paths this app names itself are accepted — anything
  /// with a shell metacharacter in it is dropped rather than interpolated,
  /// because this is the one probe that does build a script out of its
  /// arguments. Callers with a path that came out of a config file use
  /// [isExecutableInDistro], which runs no shell at all.
  Future<Set<String>> readDistroFileList(
      String distro, List<String> paths) async {
    final safe = paths.where(isPlainDistroPath).toList();
    if (safe.isEmpty) return <String>{};

    final script =
        'for f in ${safe.join(' ')}; do [ -e \$f ] && echo \$f; done; exit 0';
    final WslOutput result = await _brokeredWsl(
        wslShellArgs(distro, script, user: 'root', shell: 'sh'),
        timeout: _distroFileTimeout);
    if (!result.ok) return <String>{};

    return result.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();
  }

  /// Whether [path] is executable inside [distro].
  ///
  /// argv, not a script: [path] comes out of `/etc/wsl-distribution.conf`,
  /// which the user edits, so it must never reach a shell. `--exec` hands the
  /// arguments to `test` untouched.
  Future<bool> isExecutableInDistro(String distro, String path) async {
    final WslOutput result = await _brokeredWsl(
        wslExecArgs(distro, ['test', '-x', path], user: 'root'),
        timeout: _distroFileTimeout);
    return result.ok;
  }

  /// Read `/etc/wsl.conf` from [distro] as a mutable, section-aware model.
  Future<WslConfFile?> readWSLConf(String distro) async {
    final String? text = await readDistroFile(distro, '/etc/wsl.conf');
    if (text == null) return null;
    return WslConfFile.parse(text);
  }

  /// Write [conf] back to `/etc/wsl.conf` in [distro], whole file at once.
  Future<bool> writeWSLConf(String distro, WslConfFile conf) =>
      writeDistroFile(distro, '/etc/wsl.conf', conf.serialize());

  /// Pending read-modify-write cycle per in-distro config file, so the next
  /// one starts after it rather than on top of it.
  static final Map<String, Future<void>> _configWriteQueue =
      <String, Future<void>>{};

  /// Run [action] after every earlier cycle on the same file has finished.
  ///
  /// The config editors write per key — a debounce for a text box, the tap
  /// itself for a toggle — and each write is a whole-file read, mutate and
  /// write back over `wsl.exe`, which takes a second or more. Two edits made
  /// inside that window both read the *pre-edit* file, and the second write
  /// puts back a copy that never had the first key in it. Measured live
  /// 2026-08-28 against a real distro: a `[network] hostname` typed 1.2s
  /// before a `generateHosts` toggle never reached `/etc/wsl.conf`, and
  /// neither did `[boot] protectBinfmt` set next to `[boot] command`. Both
  /// writes reported success, because both of them succeeded.
  ///
  /// Static, because the callers build a fresh [WSLApi] per write.
  static Future<T> _serialiseConfigWrite<T>(
      String key, Future<T> Function() action) {
    final Future<void> previous =
        _configWriteQueue[key] ?? Future<void>.value();
    final Future<T> result = previous.then((_) => action());
    // The queue tail must not carry the failure forward, or one unreachable
    // distro would poison every later write to it.
    final Future<void> tail = result.then<void>((_) {}, onError: (_) {});
    _configWriteQueue[key] = tail;
    tail.whenComplete(() {
      if (identical(_configWriteQueue[key], tail)) {
        _configWriteQueue.remove(key);
      }
    });
    return result;
  }

  /// Read, [mutate] and write back `/etc/wsl.conf` in one pass.
  ///
  /// Every key-level change goes through here so that the sections the user
  /// did not touch come back out unchanged — the whole point of replacing the
  /// section-blind `sed` writer.
  Future<bool> updateWSLConf(
          String distro, void Function(WslConfFile conf) mutate) =>
      _serialiseConfigWrite('$distro|/etc/wsl.conf', () async {
        final WslConfFile? conf = await readWSLConf(distro);
        if (conf == null) return false;
        mutate(conf);
        return writeWSLConf(distro, conf);
      });

  /// Change setting in wsl.conf with key and value
  Future<bool> setSetting(
      String distro, String parent, String key, String value) {
    return updateWSLConf(distro, (conf) => conf.set(parent, key, value));
  }

  /// Remove a key from wsl.conf, letting the distro's own default apply again.
  Future<bool> removeSetting(String distro, String parent, String key) =>
      _serialiseConfigWrite('$distro|/etc/wsl.conf', () async {
        final WslConfFile? conf = await readWSLConf(distro);
        if (conf == null) return false;
        if (!conf.remove(parent, key)) return true;
        return writeWSLConf(distro, conf);
      });

  /// Read `/etc/wsl-distribution.conf` from [distro].
  ///
  /// Null means the distro could not be reached; an *absent* file parses as an
  /// empty config, which is what every distro this app has created reads as —
  /// `wsl --import` writes no distribution config at all (audit F-8).
  Future<WslDistributionConfFile?> readDistributionConf(String distro) async {
    final String? text = await readDistroFile(distro, kWslDistributionConfPath);
    if (text == null) return null;
    return WslDistributionConfFile.parse(text);
  }

  /// Write [conf] back to `/etc/wsl-distribution.conf` in [distro].
  ///
  /// `0644`, owned by root, is what `build-custom-distro.md`'s configuration
  /// recommendations require of both config files in a packaged distro.
  Future<bool> writeDistributionConf(
          String distro, WslDistributionConfFile conf) =>
      writeDistroFile(distro, kWslDistributionConfPath, conf.serialize(),
          mode: '0644');

  /// Read, [mutate] and write back `/etc/wsl-distribution.conf` in one pass,
  /// so the sections the user did not touch come back out unchanged.
  Future<bool> updateDistributionConf(String distro,
          void Function(WslDistributionConfFile conf) mutate) =>
      _serialiseConfigWrite('$distro|$kWslDistributionConfPath', () async {
        final WslDistributionConfFile? conf =
            await readDistributionConf(distro);
        if (conf == null) return false;
        mutate(conf);
        return writeDistributionConf(distro, conf);
      });

  /// Set one `wsl-distribution.conf` key.
  Future<bool> setDistributionSetting(
          String distro, String section, String key, String value) =>
      updateDistributionConf(distro, (conf) => conf.set(section, key, value));

  /// Remove one `wsl-distribution.conf` key, letting WSL's own default apply
  /// again. Writing `enabled = true` back is not the same thing — the
  /// documented default has to be reachable, which is only true if the line
  /// can go away (the tri-state rule of audit CC-11).
  Future<bool> removeDistributionSetting(
          String distro, String section, String key) =>
      _serialiseConfigWrite('$distro|$kWslDistributionConfPath', () async {
        final WslDistributionConfFile? conf =
            await readDistributionConf(distro);
        if (conf == null) return false;
        if (!conf.remove(section, key)) return true;
        return writeDistributionConf(distro, conf);
      });

  /// Get wsl.conf settings
  Future<Map<String, Map<String, String>>> getWSLConf(String distro) async {
    final WslConfFile? conf = await readWSLConf(distro);
    return conf?.toMap() ?? <String, Map<String, String>>{};
  }

  /// Get default user of a distro
  @override
  Future<String> getDefaultUser(String distribution) async {
    ProcessResult result = await _runWsl(wslExecArgs(distribution, ['whoami']),
        stdoutEncoding: null, stderrEncoding: null);

    if (result.exitCode != 0) {
      logDebug('Failed to get default user for $distribution', null, null);
      return 'root';
    }
    return utf8Convert(result.stdout).trim();
  }

  // ===========================================================================
  // wsl.exe verbs added by Phase 05 (P05-08, P05-15, P05-16, P05-23).
  //
  // Every one of them routes through [runVerb] rather than assembling its own
  // process call, so the argument list stays a `List<String>` — no quoting, no
  // shell — and stderr comes back to the caller instead of being discarded.
  // That last part is the point of P05-08: wsl.exe reports a refused
  // `.wslconfig` key, an unsupported host CPU and a clamped `processors` value
  // on stderr with exit code 0, so a caller that reads only the exit code
  // cannot tell a working command from a silently ignored one (runtime R-1,
  // R-4, R-9).
  //
  // [runVerb] in turn goes through [_brokeredWsl], so each verb's timeout is
  // enforced by something holding the child's handle. The old `.timeout()`
  // around `Process.run` could only stop *waiting*: a `--manage --move` that
  // wedged went on holding the VHD open with nothing left pointing at it.
  // ===========================================================================

  /// Run [args] and hand back **both** channels and the exit code.
  ///
  /// [timeout] bounds the whole call and kills the child when it expires;
  /// callers give it the shape of the work — 20s for a version probe, half an
  /// hour for a move that copies a disk.
  Future<WslOutput> runVerb(List<String> args,
          {Duration timeout = _verbTimeout}) =>
      _brokeredWsl(args, timeout: timeout);

  /// `wsl --version`. Inbox WSL rejects the flag outright, which is the
  /// documented probe for "is this the Store build" (`systemd.md:30`).
  Future<WslOutput> versionInfo() =>
      runVerb(['--version'], timeout: const Duration(seconds: 20));

  /// `wsl --status`: default distro, default version, and on some builds the
  /// kernel version.
  Future<WslOutput> statusInfo() =>
      runVerb(['--status'], timeout: const Duration(seconds: 20));

  /// `wsl --manage <distro> <option> [value]`, the WSL 2.5+ verb.
  ///
  /// Callers must check [WslCapabilities.supportsManage] first — an older
  /// wsl.exe answers with `Invalid command line option` and no side effect,
  /// which is recoverable but not a message to show a user.
  Future<WslOutput> manage(String distribution, String option,
          [String? value]) =>
      runVerb([
        '--manage',
        distribution,
        option,
        if (value != null) value,
      ], timeout: const Duration(minutes: 30));

  /// Move [distribution]'s storage to [newPath] in one supported operation.
  ///
  /// This is the whole reason P05-15 exists: [move] does the same job as
  /// export → **unregister** → import, and issue #280 is a user who lost a
  /// distro inside that window. `--manage --move` never unregisters anything.
  Future<WslOutput> manageMove(String distribution, String newPath) =>
      manage(distribution, '--move', newPath);

  /// Grow [distribution]'s VHD to [size].
  ///
  /// `disk-space.md:52-58`: the format is `<Value>B|MB|GB|TB` and **decimals
  /// are rejected** — `2.5TB` is not a size. Requires `wsl --shutdown` first,
  /// which is the caller's job.
  Future<WslOutput> manageResize(String distribution, String size) =>
      manage(distribution, '--resize', size);

  /// Make [distribution]'s **existing** VHD sparse, so freed space is returned
  /// to Windows.
  ///
  /// Distinct from `[experimental] sparseVhd`, which only affects VHDs created
  /// *after* it is set — the confusion the audit records as F-3.
  Future<WslOutput> manageSetSparse(String distribution, bool sparse) =>
      manage(distribution, '--set-sparse', sparse ? 'true' : 'false');

  /// Set [distribution]'s default user without editing `wsl.conf`.
  ///
  /// The modern replacement for `<distro> config --default-user`, which
  /// `basic-commands.md:152` documents as not working for imported distros —
  /// and this app imports everything it creates.
  Future<WslOutput> manageSetDefaultUser(String distribution, String user) =>
      manage(distribution, '--set-default-user', user);

  /// `wsl --list --online`: the catalog names `wsl --install -d` accepts.
  Future<WslOutput> listOnline() =>
      runVerb(['--list', '--online'], timeout: const Duration(minutes: 2));

  /// `wsl --install -d <distro>`, brokered and headless — the interactive
  /// [install] opens a terminal window instead, which no MCP client wants.
  Future<WslOutput> installOnline(String distribution,
          {bool noLaunch = true}) =>
      runVerb([
        '--install',
        '-d',
        distribution,
        if (noLaunch) '--no-launch',
      ], timeout: const Duration(minutes: 60));

  /// `wsl --set-version <distro> <1|2>` — converts the disk, takes minutes.
  Future<WslOutput> setVersion(String distribution, int version) =>
      runVerb(['--set-version', distribution, '$version'],
          timeout: const Duration(minutes: 30));

  /// `wsl --set-default <distro>`.
  Future<WslOutput> setDefaultDistro(String distribution) =>
      runVerb(['--set-default', distribution],
          timeout: const Duration(seconds: 20));

  /// `wsl --import-in-place <name> <path.vhdx>`: register an existing VHDX
  /// where it lies — no copy, unlike [import].
  Future<WslOutput> importInPlace(String distribution, String vhdxPath) =>
      runVerb(['--import-in-place', distribution, vhdxPath],
          timeout: const Duration(minutes: 5));

  /// `wsl --update`, optionally through the documented Store-free path.
  ///
  /// `--web-download` is `compare-versions.md:102`'s answer for machines where
  /// the Microsoft Store is blocked by policy, which is most managed fleets.
  Future<WslOutput> updateWsl({bool webDownload = false}) => runVerb([
        '--update',
        if (webDownload) '--web-download',
      ], timeout: const Duration(minutes: 20));

  /// `wsl --install --from-file <path>`: install a packaged `.wsl` distro.
  ///
  /// The documented install path for a custom distribution
  /// (`build-custom-distro.md:195`), and the half of audit F-8 that this app
  /// could not do at all. Unlike `--import`, this one honours the
  /// `/etc/wsl-distribution.conf` inside the archive, so the result gets its
  /// OOBE run, its default user, its Start-menu shortcut and its Windows
  /// Terminal profile — none of which an `--import`ed distro has ever had.
  ///
  /// [name] overrides `oobe.defaultName`; without either, wsl.exe has no name
  /// to register the distro under. [noLaunch] suppresses the first-run shell,
  /// which is what a GUI wants: the OOBE script is interactive and there is no
  /// console attached to answer it.
  ///
  /// Requires WSL 2.4.4 — see [WslCapabilities.supportsWslPackages]. Callers
  /// must check first; an older wsl.exe answers `Invalid command line option`.
  Future<WslOutput> installFromFile(
    String path, {
    String? name,
    String? location,
    bool noLaunch = true,
  }) {
    // Trimmed here rather than at the call site: `--name ''` is not "no name",
    // it is wsl.exe being told to register the distro under nothing.
    final trimmedName = name?.trim() ?? '';
    final trimmedLocation = location?.trim() ?? '';

    // A `"` in the name is refused at registration rather than carried: the
    // name is argv here, but [start] launches a terminal through `cmd.exe`
    // (`runInShell: true`, deliberately — see its own comment), and a quote
    // in the distro name makes that command line unparseable. Registering a
    // distro this app could never open again is worse than saying no now.
    if (trimmedName.contains('"')) {
      return Future.value(const WslOutput(
          -1, '', 'A distribution name cannot contain a double quote.'));
    }

    return runVerb([
      '--install',
      '--from-file',
      path,
      if (trimmedName.isNotEmpty) ...['--name', trimmedName],
      if (trimmedLocation.isNotEmpty) ...['--location', trimmedLocation],
      if (noLaunch) '--no-launch',
    ], timeout: const Duration(minutes: 60));
  }

  /// Disk usage of [distribution] as the system distro sees it.
  ///
  /// `disk-space.md:30`'s documented incantation. It reports what the distro
  /// *uses*, which is the number [getSize]'s `ext4.vhdx` length cannot give —
  /// a VHD never shrinks on its own, so the two together are what makes
  /// "80 GB allocated, 12 GB used, reclaim it" sayable.
  Future<WslDiskUsage?> diskUsage(String distribution) async {
    final result = await runVerb(
        ['--system', '-d', distribution, 'df', '-k', '/mnt/wslg/distro'],
        timeout: const Duration(seconds: 30));
    if (!result.ok) {
      logDebug(
          'df in the system distro failed for $distribution: '
          '${result.stderr}',
          null,
          null);
      return null;
    }
    return WslDiskUsage.parseDf(result.stdout);
  }
}
