import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/remote_command.dart';

/// How a command reaches a remote Windows host without its login shell
/// (cmd.exe, PowerShell or bash — whichever OpenSSH was configured with)
/// taking it apart. Everything here was checked against a real PowerShell
/// host on 2026-09-05; the assertions pin the shapes that worked there.
void main() {
  group('isShellNeutralToken', () {
    test('accepts what every shell passes through unchanged', () {
      for (final token in [
        'wsl',
        '--list',
        '--quiet',
        '-d',
        'Ubuntu-22.04',
        'ai-workspace',
        'user@host'.replaceAll('@', '-'),
        '/home/eric',
        'C:/wsl2dm/x',
        'a=b',
        'explorer.exe',
        '1.2.3+4',
      ]) {
        expect(isShellNeutralToken(token), isTrue, reason: token);
      }
    });

    test('rejects anything some shell would reinterpret', () {
      for (final token in [
        '',
        'a b',
        r'C:\wsl2dm\x', // `\` escapes in bash
        '%PATH%', // cmd expands it
        'a,b', // PowerShell makes an array of it
        '@splat', // PowerShell splatting
        r'$HOME',
        'a;b',
        'a|b',
        'a&b',
        '(x)',
        "'q'",
        '"q"',
        ';/bin/sh',
        'x\ny',
        'x\ty',
      ]) {
        expect(isShellNeutralToken(token), isFalse, reason: token);
      }
    });
  });

  group('windowsCommandLine', () {
    test('leaves plain tokens bare and quotes the rest', () {
      expect(windowsCommandLine(['--list', '--quiet']), '--list --quiet');
      expect(windowsCommandLine(['a b']), '"a b"');
      expect(windowsCommandLine(['']), '""');
      expect(windowsCommandLine([r'C:\dir\x']), r'C:\dir\x');
    });

    test('escapes quotes and only the backslashes that precede them', () {
      expect(windowsCommandLine(['say "hi"']), r'"say \"hi\""');
      expect(windowsCommandLine([r'C:\a b\']), r'"C:\a b\\"');
      expect(windowsCommandLine([r'a\\"b']), r'"a\\\\\"b"');
      expect(windowsCommandLine([r'\"']), r'"\\\""');
    });

    test('quotes cmd.exe metacharacters so a cmd /c line cannot split', () {
      // `cmd /c if not exist D:\WSL&Data mkdir D:\WSL&Data` would run `mkdir`
      // as a second command; quoted, cmd.exe leaves the path alone.
      expect(windowsCommandLine([r'D:\WSL&Data']), r'"D:\WSL&Data"');
      expect(windowsCommandLine(['a|b', '(x)', 'c^d', 'e<f>g']),
          '"a|b" "(x)" "c^d" "e<f>g"');
      expect(splitWindowsCommandLine(r'"D:\WSL&Data"'), [r'D:\WSL&Data']);
    });

    test('keeps a multi-line script one argument', () {
      expect(windowsCommandLine(['echo one\necho two']),
          '"echo one\necho two"');
    });

    test('round-trips through splitWindowsCommandLine', () {
      const samples = <List<String>>[
        ['--list', '--quiet'],
        ['-d', 'Ubuntu', '--exec', 'bash', '-c', 'echo "a b" | tr a-z A-Z'],
        ['', 'a b', r'C:\dir\', r'C:\a b\', 'q"q', r'\"', r'a\\"b'],
        ['tab\tsep', 'new\nline', 'two  spaces', "it's"],
        [r'echo "path=C:\dir\\"; echo %PATH%; V=1; echo "v=$V" & wait'],
      ];
      for (final argv in samples) {
        expect(splitWindowsCommandLine(windowsCommandLine(argv)), argv,
            reason: argv.join(' | '));
      }
    });
  });

  group('encodePowerShellScript', () {
    test('is base64 of UTF-16LE, as -EncodedCommand expects', () {
      // "ab" → 61 00 62 00
      expect(encodePowerShellScript('ab'), 'YQBiAA==');
      expect(decodePowerShellScript('YQBiAA=='), 'ab');
    });

    test('round-trips non-ASCII and quotes', () {
      const script = "Write-Output 'Grüße \"quoted\" \$env:OS'";
      expect(decodePowerShellScript(encodePowerShellScript(script)), script);
    });
  });

  group('remoteHostCommand', () {
    test('sends an all-neutral command bare, with no quotes at all', () {
      // The regression: `'wsl' '--list' '--quiet'` is a parse error on a
      // PowerShell login shell. The bare form is the same command under
      // cmd.exe, PowerShell and bash.
      expect(remoteHostCommand('wsl', ['--list', '--quiet']),
          ['wsl', '--list', '--quiet']);
      expect(remoteHostCommand('wsl', ['--terminate', 'Ubuntu']),
          ['wsl', '--terminate', 'Ubuntu']);
    });

    test('wraps anything else so only neutral tokens cross the wire', () {
      final tokens = remoteHostCommand(
          'wsl', ['-d', 'Ubuntu', '--exec', 'bash', '-c', 'echo "a b" | cat']);
      expect(tokens.take(4),
          ['powershell', '-NoProfile', '-NonInteractive', '-EncodedCommand']);
      expect(tokens.length, 5);
      expect(tokens.every(isShellNeutralToken), isTrue,
          reason: tokens.join(' '));
    });

    test('the wrapper starts the program with the exact argv', () {
      const argv = [
        '-d',
        'Ubuntu',
        '--exec',
        'bash',
        '-c',
        r'echo "a b" | tr a-z A-Z; printf %s "$HOME"; echo it'
            "'"
            's'
            '\n  indented',
      ];
      final tokens = remoteHostCommand('wsl', argv);
      final script = decodePowerShellScript(tokens.last);
      expect(script, startsWith(remotePowerShellPreamble));
      expect(script,
          contains(r'$si.FileName = ' + powerShellStringExpression('wsl')));
      expect(script, contains(r'$si.UseShellExecute = $false'));
      expect(script, contains(r'[System.Diagnostics.Process]::Start($si)'));
      expect(script, contains(r'exit $p.ExitCode'));
      // Not Start-Process: its -Wait also waits for every descendant.
      expect(script, isNot(contains('Start-Process')));
      expect(decodeRemoteCommand(tokens), ['wsl', ...argv]);
    });

    test('a Windows path with backslashes is wrapped, not sent bare', () {
      // bash would eat the backslashes; the wrapper hands cmd.exe the path
      // intact, and unquoted unless it has spaces — a pre-quoted "path" would
      // arrive with its quotes doubled.
      final tokens = remoteHostCommand('cmd', [
        '/c',
        'if',
        'not',
        'exist',
        r'C:\wsl2dm\instances\x',
        'mkdir',
        r'C:\wsl2dm\instances\x',
      ]);
      expect(tokens, contains('-EncodedCommand'));
      final script = decodePowerShellScript(tokens.last);
      expect(
          script,
          contains(r'$si.Arguments = ' +
              powerShellStringExpression(
                  r'/c if not exist C:\wsl2dm\instances\x mkdir C:\wsl2dm\instances\x')));
    });

    test('an empty argument survives as ""', () {
      expect(decodeRemoteCommand(remoteHostCommand('x', ['', 'y'])),
          ['x', '', 'y']);
    });

    test('quotes of every kind in the argv cannot escape the script', () {
      // PowerShell closes a single-quoted literal on ' and on U+2018–U+201B,
      // so a curly apostrophe in a quoted literal would end it early and run
      // the remainder as PowerShell on the host. Base64 literals have no
      // quote characters at all.
      const argv = ['-d', 'U', "it's", 'it’s', "‘q’; Remove-Item x; ‚r‛"];
      final tokens = remoteHostCommand('wsl', argv);
      final script = decodePowerShellScript(tokens.last);
      expect(script, isNot(contains("it's")));
      expect(script, isNot(contains('’')));
      expect(script, isNot(contains('Remove-Item')));
      expect(RegExp("'").allMatches(script).length, 8,
          reason: 'only the two preamble values and the two base64 literals '
              'are quoted');
      expect(decodeRemoteCommand(tokens), ['wsl', ...argv]);
    });
  });

  group('remotePowerShellScript', () {
    test('runs the script itself behind -EncodedCommand', () {
      const script =
          r"$p = Join-Path $env:USERPROFILE '.wslconfig'; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw }";
      final tokens = remotePowerShellScript(script);
      expect(tokens.take(4),
          ['powershell', '-NoProfile', '-NonInteractive', '-EncodedCommand']);
      expect(tokens.every(isShellNeutralToken), isTrue);
      final decoded = decodePowerShellScript(tokens.last);
      expect(decoded, startsWith(remotePowerShellPreamble));
      expect(decoded, contains('try {\n$script\n} catch {'));
    });

    test('a trailing comment in the script cannot swallow the catch', () {
      final decoded = decodePowerShellScript(
          remotePowerShellScript("Write-Output 'x' # done").last);
      expect(decoded, contains("# done\n} catch {"));
      expect(decodeRemoteCommand(remotePowerShellScript("Write-Output 'x' # done")),
          ['powershell', '-NoProfile', '-Command', "Write-Output 'x' # done"]);
    });

    test('a terminating error becomes exit 1 with a plain message', () {
      final decoded =
          decodePowerShellScript(remotePowerShellScript('Get-Item x').last);
      // Progress records would otherwise be CLIXML on stderr, and a
      // non-terminating error would leave the exit code at 0.
      expect(decoded, contains(r"$ProgressPreference = 'SilentlyContinue'"));
      expect(decoded, contains(r"$ErrorActionPreference = 'Stop'"));
      expect(decoded,
          contains(r'catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }'));
    });

    test('powerShellStringExpression round-trips through the encoder', () {
      const value = "it’s 'a' \"b\"\nline two";
      final expression = powerShellStringExpression(value);
      final literal =
          RegExp(r"FromBase64String\('([A-Za-z0-9+/=]*)'\)").firstMatch(expression);
      expect(decodePowerShellScript(literal!.group(1)!), value);
    });

    test('decodes back to the powershell -Command shape', () {
      const script = "if (\$x) { 'a }' } else { 'b' }";
      expect(decodeRemoteCommand(remotePowerShellScript(script)),
          ['powershell', '-NoProfile', '-Command', script]);
    });
  });

  group('decodeRemoteCommand', () {
    test('leaves bare and non-encoded commands alone', () {
      expect(decodeRemoteCommand(['wsl', '--list']), ['wsl', '--list']);
      expect(
          decodeRemoteCommand(
              ['powershell', '-NoProfile', '-NonInteractive', '-EncodedCommand']),
          ['powershell', '-NoProfile', '-NonInteractive', '-EncodedCommand']);
      expect(
          decodeRemoteCommand([
            'powershell',
            '-NoProfile',
            '-NonInteractive',
            '-EncodedCommand',
            'not base64!'
          ]),
          hasLength(5));
    });
  });
}
