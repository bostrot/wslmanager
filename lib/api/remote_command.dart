// How a command reaches a remote **Windows** host over SSH without the host's
// login shell taking it apart.
//
// ## The problem
//
// `ssh host a b c` does not exec `a` with argv `[b, c]`. It joins the tokens
// with spaces and hands the string to whatever shell Windows OpenSSH is
// configured to run — cmd.exe by default, PowerShell on most machines where
// anyone has touched `DefaultShell`, occasionally Git Bash. Each of those
// re-parses the string by its own rules, and no quoting works for all three:
//
// * POSIX single quotes (`'wsl' '--list'`) are what a Linux target wants and
//   are exactly what PowerShell rejects — measured live on 2026-09-05 against
//   a Windows 11 VM: `Unerwartetes Token "'--list'" in Ausdruck oder
//   Anweisung.` That was the bug behind bostrot/ai-tasks#21: every remote
//   command failed to parse and the distro list never loaded.
// * Double quotes get eaten one layer early: sshd spawns `powershell -c
//   "<command>"`, so powershell.exe's own argv parser strips them (and
//   `\"`-escapes) before the PowerShell parser ever runs, collapsing runs of
//   whitespace on the way.
// * PowerShell's stop-parsing token `--%` still expands `%VAR%` and still sits
//   behind that argv parser, so quotes and newlines do not survive it either.
//
// ## The approach
//
// Send only characters every shell leaves alone. A command whose tokens are
// all *shell-neutral* (letters, digits, `_ . / : = + -`) goes across as-is —
// `wsl --list --quiet` is the same command under cmd, PowerShell and bash.
// Anything else is wrapped:
//
// ```
// powershell -NoProfile -NonInteractive -EncodedCommand <base64>
// ```
//
// Base64 is shell-neutral too, and `powershell.exe` is on the PATH of every
// Windows host that can run WSL. The decoded script starts the real command
// through `System.Diagnostics.Process` with a Windows command line built by
// [windowsCommandLine], which is exactly what the program's own argv parser
// expects — deterministic, independent of PowerShell's version and of its
// notoriously lossy native-argument passing (`& 'wsl' '-c' 'a "b" c'` drops
// the inner quotes on 5.1). Inside that script the program name and its
// command line are base64 literals, not quoted strings — PowerShell also
// closes a single-quoted string on the typographic quotes U+2018–U+201B, so
// an `it’s` in a script would otherwise end the literal and run the rest as
// PowerShell. The child inherits stdin/stdout/stderr, so
// wsl.exe's UTF-16 output, an interactive `-tt` session and piped input all
// pass through untouched, and its exit code is the exit code ssh reports.
//
// Verified live against the same host: a `bash -c` script with `|`, `$`,
// `%`, `"`, `'`, newlines, tabs and doubled spaces round-tripped byte for
// byte; `--terminate NoSuchDistro` came back with exit 1 and wsl's own
// message; `echo x | ssh … cat` printed `x`.
//
// ## Known limit
//
// The wrapper costs about 3.6 wire characters per payload byte (UTF-16LE,
// then base64, plus ~450 characters of script). A cmd.exe login shell caps
// the line it receives at 8191 characters, PowerShell at 32767, so an inline
// payload — `writeDistroFile`'s base64 file content, a `.wslconfig` write —
// is bounded at roughly 1.9 KB on a stock cmd.exe host and 8.5 KB on a
// PowerShell one. Every script the app ships is well under that; content
// large enough to hit it would have to travel over stdin instead.
//
// Shared by `WSLApi` and `MountService`; don't grow a second copy.

import 'dart:convert';

final RegExp _shellNeutralToken = RegExp(r'^[A-Za-z0-9_./:=+-]+$');
// Whitespace and quotes are what CommandLineToArgvW needs quoted; the cmd.exe
// metacharacters `& | < > ^ ( )` are quoted too, because a `cmd /c <line>`
// consumer reads the *raw* command line and would otherwise split on them.
// Quoting a token that did not need it is harmless to every other parser.
final RegExp _needsWindowsQuoting = RegExp(r'[ \t\r\n"&|<>^()]');
final RegExp _hostProcessFileName =
    RegExp(r"\$si\.FileName = " + _base64LiteralPattern);
final RegExp _hostProcessArguments =
    RegExp(r"\$si\.Arguments = " + _base64LiteralPattern);
const String _base64LiteralPattern =
    r"\[Text\.Encoding\]::Unicode\.GetString\(\[Convert\]::FromBase64String\('([A-Za-z0-9+/=]*)'\)\)";

/// Whether [token] means the same thing to cmd.exe, PowerShell and a POSIX
/// shell when it appears on a command line unquoted.
///
/// Deliberately conservative: `\` is an escape in bash, `%` expands in cmd,
/// `,` splits into an array in PowerShell, `@` splats there, and `$ ; & | < >
/// ( ) ^ ! ~ * ? # " '` and whitespace are special somewhere. An empty token
/// is not neutral either — it vanishes from a joined command line.
bool isShellNeutralToken(String token) => _shellNeutralToken.hasMatch(token);

/// Quote [args] into one Windows command line the way `CommandLineToArgvW`
/// and the MSVC runtime split it back: tokens without whitespace, quotes or
/// cmd.exe metacharacters stay bare, everything else is double-quoted with
/// `"` escaped as `\"` and backslashes doubled only where they precede a
/// quote (or the closing one).
///
/// Same rules as Python's `subprocess.list2cmdline`, plus quoting of `& | < >
/// ^ ( )` so a `cmd /c` line cannot split on them. Newlines and tabs count as
/// whitespace so a multi-line script stays one argument. `%VAR%` cannot be
/// protected from cmd.exe by quoting; keep `%` out of paths handed to `cmd`.
String windowsCommandLine(List<String> args) {
  final parts = <String>[];
  for (final arg in args) {
    final needsQuotes = arg.isEmpty || arg.contains(_needsWindowsQuoting);
    if (!needsQuotes) {
      parts.add(arg);
      continue;
    }
    final buffer = StringBuffer('"');
    var backslashes = 0;
    for (var i = 0; i < arg.length; i++) {
      final char = arg[i];
      if (char == r'\') {
        backslashes++;
      } else if (char == '"') {
        buffer.write(r'\' * (backslashes * 2 + 1));
        buffer.write('"');
        backslashes = 0;
      } else {
        buffer.write(r'\' * backslashes);
        buffer.write(char);
        backslashes = 0;
      }
    }
    buffer.write(r'\' * (backslashes * 2));
    buffer.write('"');
    parts.add(buffer.toString());
  }
  return parts.join(' ');
}

/// Split a command line produced by [windowsCommandLine] back into argv.
///
/// The inverse of [windowsCommandLine] for round-trip tests and the test
/// shell, following the MSVC runtime rules for backslashes and quotes. It
/// does not implement every historical quirk of `CommandLineToArgvW` (the
/// `""` literal inside quotes, for one) — nothing here emits those.
List<String> splitWindowsCommandLine(String commandLine) {
  final args = <String>[];
  final current = StringBuffer();
  var inToken = false;
  var inQuotes = false;
  var i = 0;
  while (i < commandLine.length) {
    final char = commandLine[i];
    if (char == r'\') {
      var backslashes = 0;
      while (i < commandLine.length && commandLine[i] == r'\') {
        backslashes++;
        i++;
      }
      final quoteFollows = i < commandLine.length && commandLine[i] == '"';
      if (quoteFollows) {
        current.write(r'\' * (backslashes ~/ 2));
        if (backslashes.isOdd) {
          current.write('"');
          i++;
        }
      } else {
        current.write(r'\' * backslashes);
      }
      inToken = true;
      continue;
    }
    if (char == '"') {
      inQuotes = !inQuotes;
      inToken = true;
      i++;
      continue;
    }
    if (!inQuotes && (char == ' ' || char == '\t' || char == '\r' || char == '\n')) {
      if (inToken) {
        args.add(current.toString());
        current.clear();
        inToken = false;
      }
      i++;
      continue;
    }
    current.write(char);
    inToken = true;
    i++;
  }
  if (inToken) args.add(current.toString());
  return args;
}

/// [value] as a PowerShell expression that evaluates to exactly that string.
///
/// Not a quoted literal: PowerShell's tokenizer closes a single-quoted string
/// on `'` *and* on the typographic quotes U+2018–U+201B, and doubling those
/// is lossy (measured live: `'a’’b'` prints `a'b`). Base64 has none of that
/// — an apostrophe, a curly quote or a newline in a distro path or a script
/// cannot end the literal early, so nothing in the argv can become PowerShell
/// code on the host.
String powerShellStringExpression(String value) =>
    "[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('${encodePowerShellScript(value)}'))";

/// [script] in the form `powershell -EncodedCommand` takes: base64 of the
/// UTF-16LE text. Also the encoding [powerShellStringExpression] uses for a
/// literal inside a script.
String encodePowerShellScript(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return base64Encode(bytes);
}

/// The script an [encodePowerShellScript] value stands for.
String decodePowerShellScript(String encoded) {
  final bytes = base64Decode(encoded);
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

/// Opens every wrapped script. Progress records would otherwise be
/// serialised as CLIXML onto stderr the moment a module autoloads, and a
/// non-terminating error would otherwise leave the exit code at 0.
const String remotePowerShellPreamble =
    r"$ProgressPreference = 'SilentlyContinue'; $ErrorActionPreference = 'Stop'; ";

const List<String> _powerShellEncodedPrefix = <String>[
  'powershell',
  '-NoProfile',
  '-NonInteractive',
  '-EncodedCommand',
];

List<String> _encodedInvocation(String script) => <String>[
      ..._powerShellEncodedPrefix,
      encodePowerShellScript(script),
    ];

/// The PowerShell that runs [executable] with [args] on the host, handing it
/// the caller's standard streams and exiting with its exit code.
///
/// `System.Diagnostics.Process` rather than `Start-Process`: the latter's
/// `-Wait` also waits for every descendant, which would hang on anything that
/// leaves a helper behind, and it autoloads a module whose progress output
/// lands on stderr.
String remoteHostProcessScript(String executable, List<String> args) {
  final buffer = StringBuffer(remotePowerShellPreamble)
    ..write('try {\n')
    ..write(r'$si = New-Object System.Diagnostics.ProcessStartInfo; ')
    ..write(r'$si.FileName = ')
    ..write(powerShellStringExpression(executable))
    ..write('; ')
    ..write(r'$si.Arguments = ')
    ..write(powerShellStringExpression(windowsCommandLine(args)))
    ..write('; ')
    ..write(r'$si.UseShellExecute = $false; ')
    ..write(r'$p = [System.Diagnostics.Process]::Start($si); ')
    ..write(r'$p.WaitForExit(); exit $p.ExitCode')
    ..write(_remoteScriptCatch);
  return buffer.toString();
}

/// Closes the `try {` every wrapped script opens. On its own line, so a
/// script whose last line is a `#` comment cannot comment the `catch` away.
const String _remoteScriptCatch =
    '\n} catch { [Console]::Error.WriteLine(\$_.Exception.Message); exit 1 }';

/// The tokens to put after `ssh <options> -- <target>` so that the host runs
/// [executable] with exactly [args], whatever its login shell is.
///
/// A command made only of [isShellNeutralToken]s is sent bare — it survives
/// every shell as it is, and it is what the common polling calls look like:
/// `wsl --list --quiet`, `wsl --terminate Ubuntu`. Anything else travels as
/// [remoteHostProcessScript] behind `-EncodedCommand`.
List<String> remoteHostCommand(String executable, List<String> args) {
  final tokens = <String>[executable, ...args];
  if (tokens.every(isShellNeutralToken)) {
    return tokens;
  }
  return _encodedInvocation(remoteHostProcessScript(executable, args));
}

/// The tokens to put after `ssh <options> -- <target>` so that the host runs
/// the PowerShell [script] itself.
///
/// A terminating error prints its message — plain text, not CLIXML — on
/// stderr and exits 1, so callers can trust a non-zero exit code.
List<String> remotePowerShellScript(String script) {
  return _encodedInvocation(
      '${remotePowerShellPreamble}try {\n$script$_remoteScriptCatch');
}

/// What the host will actually run for [tokens], as `[executable, ...argv]`.
///
/// The inverse of [remoteHostCommand] and [remotePowerShellScript], for tests
/// and the test shell: bare tokens come back unchanged, an encoded host
/// process decodes to its executable and argv, and an encoded script comes
/// back as `powershell -NoProfile -Command [script]` — the shape the same
/// script had before it was wrapped, minus the wrapper's own preamble and
/// try/catch.
List<String> decodeRemoteCommand(List<String> tokens) {
  if (tokens.length != _powerShellEncodedPrefix.length + 1) return tokens;
  for (var i = 0; i < _powerShellEncodedPrefix.length; i++) {
    if (tokens[i] != _powerShellEncodedPrefix[i]) return tokens;
  }
  final String script;
  try {
    script = decodePowerShellScript(tokens.last);
  } on FormatException {
    return tokens;
  }

  final fileName = _hostProcessFileName.firstMatch(script);
  final arguments = _hostProcessArguments.firstMatch(script);
  if (fileName != null && arguments != null) {
    return <String>[
      decodePowerShellScript(fileName.group(1)!),
      ...splitWindowsCommandLine(decodePowerShellScript(arguments.group(1)!)),
    ];
  }

  const tryOpen = 'try {\n';
  const tryClose = _remoteScriptCatch;
  final start = script.indexOf(tryOpen);
  final end = script.lastIndexOf(tryClose);
  if (start < 0 || end <= start) return tokens;
  return <String>[
    'powershell',
    '-NoProfile',
    '-Command',
    script.substring(start + tryOpen.length, end),
  ];
}
