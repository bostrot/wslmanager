/// The environment a snippet is run with has to survive the trip into the
/// guest on both backends: WSL writes the script line by line through a shell,
/// the Apple helper sends it over SSH (bostrot/ai-tasks#99).
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

/// A value with one of every character that means something to a shell.
const String awkward = 'p\$ass`word"with\'quotes and a \\slash';

void main() {
  late MockShell shell;
  late WSLApi api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    shell = MockShell();
    api = WSLApi(shell: shell);
  });

  /// Everything `runCmds` streamed into the distro to build /tmp/wdmcmds.
  String written() => utf8.decode(shell.processes.first.stdinBytes);

  test('the snippet script is written with the environment in front of it',
      () async {
    await api.runCommands('Ubuntu', ['echo hi'],
        env: {'RUNNER_URL': 'https://example.test/org'});

    final script = written();
    final encoded = base64.encode(utf8.encode('https://example.test/org'));
    expect(script, contains('export RUNNER_URL='));
    expect(script, contains(encoded));
    expect(script.indexOf('export RUNNER_URL='),
        lessThan(script.indexOf('echo hi')),
        reason: 'the exports have to run before the snippet does');
  });

  test('a value full of metacharacters reaches the guest unchanged', () async {
    await api.runCommands('Ubuntu', ['echo hi'], env: {'PASSWORD': awkward});

    final script = written();
    // Nothing of the value is in the line, so the writing shell cannot expand
    // any of it: `$`, a backtick and a quote would all be read otherwise.
    expect(script, isNot(contains('quotes')));
    expect(script, contains(base64.encode(utf8.encode(awkward))));
    // The `$(…)` that decodes it in the guest is escaped for the writer.
    expect(script, contains('\\\$(printf %s'));
  });

  test('no environment means no exports at all', () async {
    await api.runCommands('Ubuntu', ['echo hi']);

    expect(written(), isNot(contains('export ')));
  });
}
