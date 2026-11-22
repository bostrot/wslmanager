import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

/// A Mac driving a remote Windows host: terminal-opening flows must go
/// through Terminal.app (a .command bridge), never the Windows `start` verb.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!Platform.isMacOS) {
    test('mac remote-terminal behavior only testable on macOS', () {});
    return;
  }

  late MockShell shell;
  late WSLApi api;
  late Directory dataDir;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('remote-mac-test');
    SharedPreferences.setMockInitialValues({
      'UseRemoteWSL': true,
      'RemoteWSLTarget': 'eric@192.168.1.20',
      'DataPath': dataDir.path,
    });
    prefs = await SharedPreferences.getInstance();
    shell = MockShell();
    api = WSLApi(shell: shell);
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('start opens Terminal.app on an ssh command', () async {
    await api.start('Ubuntu');

    // The bridge went through `open <something>.command` ...
    expect(shell.lastStartExecutable, 'open');
    final scriptPath = shell.lastStartArguments.single;
    expect(scriptPath, endsWith('.command'));
    // ... and the script runs ssh against the configured target with the
    // distro's wsl invocation, all shell-quoted.
    final script = File(scriptPath).readAsStringSync();
    expect(script, contains("'ssh'"));
    expect(script, contains('eric@192.168.1.20'));
    expect(script, contains("'-d' 'Ubuntu'"));
  });

  test('openBashrc, startVSCode and passwd all bridge through Terminal.app',
      () async {
    await api.openBashrc('Ubuntu');
    expect(shell.lastStartExecutable, 'open');
    var script =
        File(shell.lastStartArguments.single).readAsStringSync();
    expect(script, contains("'ssh'"));
    expect(script, contains('.bashrc'));

    await api.startVSCode('Ubuntu', path: '/home/eric');
    script = File(shell.lastStartArguments.single).readAsStringSync();
    expect(script, contains("'ssh'"));
    expect(script, contains('/home/eric'));

    await api.exec('Ubuntu', ['passwd eric']);
    script = File(shell.lastStartArguments.single).readAsStringSync();
    expect(script, contains("'ssh'"));
    expect(script, contains('passwd'));
  });

  test('the remote explorer opens an sftp URL, not xdg-open', () async {
    api.startExplorer('Ubuntu');
    await Future<void>.delayed(Duration.zero);
    expect(shell.lastStartExecutable, 'open');
    expect(shell.lastStartArguments.single, startsWith('sftp://eric@'));
  });
}
