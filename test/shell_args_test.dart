import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/helpers.dart';

void main() {
  group('splitShellArgs', () {
    test('splits simple arguments', () {
      expect(splitShellArgs('echo hello'), ['echo', 'hello']);
    });

    test('handles multiple spaces between arguments', () {
      expect(splitShellArgs('echo    hello    world'), ['echo', 'hello', 'world']);
    });

    test('handles double-quoted arguments with spaces', () {
      expect(splitShellArgs('echo "hello world"'), ['echo', 'hello world']);
    });

    test('handles single-quoted arguments with spaces', () {
      expect(splitShellArgs("echo 'hello world'"), ['echo', 'hello world']);
    });

    test('handles escaped spaces in double quotes', () {
      expect(splitShellArgs('echo "hello\\ world"'), ['echo', 'hello world']);
    });

    test('handles empty string', () {
      expect(splitShellArgs(''), isEmpty);
    });

    test('handles leading and trailing spaces', () {
      expect(splitShellArgs('  echo hello  '), ['echo', 'hello']);
    });

    test('handles mixed quoted and unquoted arguments', () {
      expect(splitShellArgs('echo hello "world foo" bar'), ['echo', 'hello', 'world foo', 'bar']);
    });

    test('handles nested quotes within different quote types', () {
      expect(splitShellArgs("echo 'hello \"world\"'"), ['echo', 'hello "world"']);
    });

    test('handles command with flags', () {
      expect(splitShellArgs('ls -la /path/to/dir'), ['ls', '-la', '/path/to/dir']);
    });

    test('handles arguments with equals sign', () {
      expect(splitShellArgs('env KEY=value'), ['env', 'KEY=value']);
    });

    test('handles escaped quotes in double-quoted string', () {
      expect(splitShellArgs(r'echo "hello \"world\""'), ['echo', 'hello "world"']);
    });
  });
}
