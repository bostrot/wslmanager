// Guards the invariant documented in lib/api/wsl_args.dart: wsl.exe re-parses
// a flattened command through the distro's default shell unless `--exec` is
// present, which silently destroys one level of quoting.
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/wsl_args.dart';

void main() {
  group('wslExecArgs', () {
    test('puts --exec between the distro options and the argv', () {
      expect(
        wslExecArgs('Ubuntu', ['whoami']),
        ['-d', 'Ubuntu', '--exec', 'whoami'],
      );
    });

    test('adds -u only when a user is given', () {
      expect(wslExecArgs('Ubuntu', ['id'], user: 'root'),
          ['-d', 'Ubuntu', '-u', 'root', '--exec', 'id']);
      expect(wslExecArgs('Ubuntu', ['id'], user: ''), isNot(contains('-u')));
      expect(wslExecArgs('Ubuntu', ['id']), isNot(contains('-u')));
    });

    test('keeps argv entries separate rather than joining them', () {
      final args = wslExecArgs('Ubuntu', ['tail', '-n', '+1', '-f', '/tmp/x']);
      expect(args.sublist(args.indexOf('--exec') + 1),
          ['tail', '-n', '+1', '-f', '/tmp/x']);
    });
  });

  group('wslShellArgs', () {
    test('passes the whole script as one argument to bash -c', () {
      const script = 'X=hello; echo [\$X]';
      final args = wslShellArgs('Ubuntu', script, user: 'root');

      expect(
          args, ['-d', 'Ubuntu', '-u', 'root', '--exec', 'bash', '-c', script]);
      // The script must survive as a single element — splitting it is exactly
      // the bug this module exists to prevent.
      expect(args.last, script);
      expect(args.where((a) => a.contains('echo')).length, 1);
    });

    test('--exec precedes the shell, so the default shell never re-parses', () {
      final args = wslShellArgs('Ubuntu', 'echo hi');
      expect(args.indexOf(kWslExecFlag), lessThan(args.indexOf('bash')));
    });

    test('honours an alternative shell', () {
      expect(wslShellArgs('Ubuntu', r'echo $HOME', shell: 'sh'),
          ['-d', 'Ubuntu', '--exec', 'sh', '-c', r'echo $HOME']);
    });

    test('leaves shell metacharacters untouched', () {
      // A double quote reaches bash literally under runInShell: false, so the
      // builder must not add quoting of its own either.
      const script = "echo 'a ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/x";
      expect(wslShellArgs('Ubuntu', script).last, script);
    });
  });
}
