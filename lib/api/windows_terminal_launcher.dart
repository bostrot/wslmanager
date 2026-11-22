import 'dart:io';

import 'package:wsl2distromanager/components/helpers.dart';

/// What a start resolves to: the program that is spawned and the arguments it
/// is spawned with.
class TerminalLaunch {
  const TerminalLaunch(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// Starts an instance through the Windows Terminal profile that belongs to it
/// (bostrot/wsl2-distro-manager#279).
///
/// Windows Terminal keeps colours, font, opacity and the rest per profile, and
/// it generates one profile per registered WSL distro. None of that is reached
/// by launching `wsl.exe -d <name>`: whatever window opens — Windows Terminal
/// as the default terminal application included — has no idea which distro the
/// process belongs to and dresses the tab in the *default* profile. Naming the
/// profile with `wt -p <name>` is what picks it up, so a start from this app
/// looks like a start from Windows Terminal's own dropdown.
///
/// The instance name is the profile name: Windows Terminal names a generated
/// WSL profile after the distro, and the profiles this app contributes as a
/// fragment carry the same name. A name Windows Terminal cannot match falls
/// back to the default profile, which is exactly the behaviour without `-p`.
class WindowsTerminalLauncher {
  const WindowsTerminalLauncher({
    bool? hostIsWindows,
    String? executablePath,
  })  : _hostIsWindows = hostIsWindows,
        _executablePath = executablePath;

  /// Stands in for the host check and for the `wt.exe` lookup while testing:
  /// neither is true on the machines the suite runs on, and the argument list
  /// they decide is the only thing worth pinning. An empty
  /// [executablePath] means "Windows Terminal is not installed".
  final bool? _hostIsWindows;
  final String? _executablePath;

  /// Off switch for the profile. There is no UI for it — the setting that
  /// already covers "do not open my instances like this" is the default
  /// terminal path in Settings — but a written preference is honoured, so a
  /// machine whose Windows Terminal cannot resolve the profile name goes back
  /// to starting without `-p`.
  static const String prefEnabled = 'WindowsTerminalProfileStart';

  /// The `start` verb, i.e. "no custom terminal was configured".
  static const String startVerb = 'start';

  bool get hostIsWindows => _hostIsWindows ?? Platform.isWindows;

  bool get enabled => prefs.getBool(prefEnabled) ?? true;

  /// Where `wt.exe` sits, or null when it is not installed. Only ever used as
  /// a "may I" probe: the command line passes the bare `wt` token, because
  /// `start "<path with spaces>"` would read the quoted path as the window
  /// title rather than as the program to run.
  String? get executablePath => _executablePath ?? locateExecutable();

  bool get isInstalled {
    final path = executablePath;
    return path != null && path.isNotEmpty;
  }

  /// Windows Terminal ships as a Store app whose execution alias lands in
  /// `WindowsApps`; a scoop/choco install puts it on `PATH` instead.
  static String? locateExecutable() {
    if (!Platform.isWindows) return null;
    final local = Platform.environment['LOCALAPPDATA'];
    final candidates = <String>[
      if (local != null && local.isNotEmpty)
        '$local\\Microsoft\\WindowsApps\\wt.exe',
      for (final dir in (Platform.environment['PATH'] ?? '').split(';'))
        if (dir.trim().isNotEmpty) '${dir.trim()}\\wt.exe',
    ];
    for (final candidate in candidates) {
      try {
        if (File(candidate).existsSync()) return candidate;
      } catch (_) {
        // An unreadable PATH entry is not an answer, just not this one.
      }
    }
    return null;
  }

  /// Whether [executable] is Windows Terminal, as configured by hand in the
  /// default terminal setting.
  static bool isWindowsTerminal(String executable) {
    final name = executable.toLowerCase().trim();
    return name == 'wt' || name.endsWith('wt.exe');
  }

  /// The Windows Terminal profile an instance is launched with.
  static String profileNameFor(String instance) => instance.trim();

  /// Windows Terminal splits its own command line on `;`, which is how
  /// `wt nt ; split-pane` works. The start command ends in `;/bin/sh` to keep
  /// the window open after a start command has run, and a start command may
  /// hold semicolons of its own — unescaped, every one of those would be read
  /// as "and now a second terminal command".
  static List<String> escapeArguments(List<String> arguments) =>
      [for (final argument in arguments) argument.replaceAll(';', r'\;')];

  /// How a start of [instance] should reach the terminal.
  ///
  /// [executable]/[arguments] are the command as it would be run without
  /// Windows Terminal — `start` plus `wsl -d <name> …`, or a terminal from the
  /// settings. [remote] instances are left alone: their distros live on
  /// another machine, so this machine has no profile for them, and `-p` would
  /// name one that does not exist.
  TerminalLaunch resolve({
    required String instance,
    required String executable,
    required List<String> arguments,
    bool remote = false,
  }) {
    final withProfile = enabled && !remote;
    final profile = profileNameFor(instance);
    final nameable = withProfile && profile.isNotEmpty;

    if (isWindowsTerminal(executable)) {
      // Already going through Windows Terminal: -w 0 opens in the window that
      // is there (or the first one), nt puts it in a new tab.
      return TerminalLaunch(executable, [
        '-w',
        '0',
        'nt',
        if (nameable) ...['-p', profile],
        ...escapeArguments(arguments),
      ]);
    }

    if (!nameable ||
        !hostIsWindows ||
        executable != startVerb ||
        !isInstalled) {
      return TerminalLaunch(executable, arguments);
    }

    return TerminalLaunch(executable, [
      'wt',
      '-w',
      '0',
      'nt',
      '-p',
      profile,
      ...escapeArguments(arguments),
    ]);
  }
}
