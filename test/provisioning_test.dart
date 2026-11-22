/// Unit tests for lib/api/provisioning.dart (bostrot/ai-tasks#78): the
/// document check, the steps a document compiles to, the scripts they run
/// (syntax-checked by a real bash, and the command/file steps run for real
/// in a temp directory), the marker protocol, the runner against a scripted
/// backend, and both stores.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/provisioning.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'fake_provisioning_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    PlaybookStore.instance.reload();
    PlaybookRunStore.instance.reload();
    PlaybookRunStore.instance.now = DateTime.now;
  });

  group('validatePlaybook', () {
    test('accepts a cloud-config mapping with a handled key', () {
      expect(validatePlaybook('#cloud-config\npackages: [git]\n'), isNull);
    });

    test('accepts a list of Ansible plays', () {
      const doc = '- hosts: all\n  tasks:\n    - ping:\n';
      expect(validatePlaybook(doc), isNull);
    });

    test('refuses an empty document', () {
      expect(validatePlaybook('  \n')?.key, 'playbookcontentrequired-text');
      expect(validatePlaybook('[]')?.key, 'playbookcontentrequired-text');
    });

    test('refuses YAML that does not parse, with the parser message', () {
      final problem = validatePlaybook('packages:\n  - git\n bad: [\n');
      expect(problem?.key, 'playbookyamlinvalid-text');
      expect(problem?.detail, isNotEmpty);
    });

    test('refuses a scalar and a list whose entries are not plays', () {
      expect(validatePlaybook('just text')?.key, 'playbookshape-text');
      expect(validatePlaybook('- git\n- curl\n')?.key, 'playbooknotplay-text');
      expect(validatePlaybook('- tasks: []\n')?.key, 'playbooknotplay-text');
    });

    test('refuses a mapping with no key the engine handles, naming them', () {
      final problem = validatePlaybook('hostname: box\nbootcmd: [ls]\n');
      expect(problem?.key, 'playbooknothing-text');
      expect(problem?.detail, contains('packages'));
      expect(problem?.detail, contains('runcmd'));
    });
  });

  group('compilePlaybook', () {
    test('orders the steps the way cloud-init does and titles them', () {
      const doc = '''
runcmd:
  - echo hi
packages:
  - git
  - [curl, "8.0"]
package_update: true
users:
  - default
  - name: dev
write_files:
  - path: /etc/motd
    content: hello
services:
  - ssh
timezone: Europe/Berlin
package_upgrade: yes
''';
      final tasks = compilePlaybook(doc);
      expect(tasks.map((t) => t.titleKey).toList(), [
        'playbooktaskuser-text',
        'playbooktaskfile-text',
        'playbooktaskupdate-text',
        'playbooktaskpackages-text',
        'playbooktaskupgrade-text',
        'playbooktasktimezone-text',
        'playbooktaskservice-text',
        'playbooktaskcommand-text',
      ]);
      expect(tasks[0].titleArgs, ['dev']);
      expect(tasks[1].titleArgs, ['/etc/motd']);
      // The version of a `[name, version]` pair is left to the package
      // manager; the name is what gets installed.
      expect(tasks[3].titleArgs, ['git, curl']);
      expect(tasks[3].script, contains("for p in 'git' 'curl'; do"));
      expect(tasks[5].titleArgs, ['Europe/Berlin']);
      // Both sides resolved, so a zone that is itself a link (UTC ->
      // Etc/UTC) compares equal after the first apply.
      expect(tasks[5].script,
          contains('= "\$(readlink -f "/usr/share/zoneinfo/\$tz")" ]'));
      expect(tasks[6].titleArgs, ['ssh']);
      expect(tasks[7].titleArgs, ['echo hi']);
      expect(tasks.every((t) => !t.skipped), isTrue);
    });

    test('a key the engine does not handle becomes a skipped step', () {
      final tasks = compilePlaybook('packages: [git]\nhostname: box\n');
      expect(tasks, hasLength(2));
      expect(tasks.last.titleKey, 'playbooktaskunsupported-text');
      expect(tasks.last.titleArgs, ['hostname']);
      expect(tasks.last.skipped, isTrue);
    });

    test('false switches and empty lists add no step', () {
      expect(compilePlaybook('package_update: false\npackages: []\nruncmd:\n'),
          isEmpty);
    });

    test('runcmd takes strings, argument lists and cmd/creates mappings', () {
      final tasks = compilePlaybook('''
runcmd:
  - echo "a b"
  - [touch, /tmp/x y]
  - cmd: install.sh
    creates: /usr/local/bin/tool
  - cmd: [rm, -f, /x]
    unless: test -f /y
  - ""
''');
      expect(tasks, hasLength(4));
      expect(tasks[0].script, contains("\nsh -c 'echo \"a b\"'\n"));
      // An argument list runs as it is, without a shell.
      expect(tasks[1].script, contains("\n'touch' '/tmp/x y'\n"));
      expect(tasks[1].titleArgs, ['touch /tmp/x y']);
      expect(tasks[2].script, contains("creates='/usr/local/bin/tool'"));
      expect(tasks[3].script, contains("unless='test -f /y'"));
      expect(tasks[3].script, contains("\n'rm' '-f' '/x'\n"));
    });

    test('a long command is shortened in the title, not in the script', () {
      final long = 'echo ${'x' * 100}';
      final task = compilePlaybook('runcmd:\n  - $long\n').single;
      expect(task.titleArgs.single.length, 60);
      expect(task.titleArgs.single, endsWith('...'));
      expect(task.script, contains(long));
    });

    test('services default to enabled and started, and take a mapping', () {
      final tasks = compilePlaybook('''
services:
  - nginx
  - name: docker
    enabled: false
    state: stopped
''');
      expect(tasks[0].script, contains('enabled=1\nstate=\'started\''));
      expect(tasks[1].script, contains('enabled=0\nstate=\'stopped\''));
    });

    test('a user step carries shell, groups, sudo rules and keys', () {
      final task = compilePlaybook('''
users:
  - name: dev
    shell: /bin/bash
    groups: sudo, docker
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh_authorized_keys:
      - ssh-ed25519 AAAA one
      - ssh-ed25519 BBBB two
''').single;
      expect(task.script, contains("shell='/bin/bash'"));
      expect(task.script, contains("want_groups='sudo docker'"));
      expect(task.script, contains("sudo_lines='dev ALL=(ALL) NOPASSWD:ALL'"));
      expect(task.script,
          contains("keys='ssh-ed25519 AAAA one\nssh-ed25519 BBBB two'"));
    });

    test('a file step ships the content base64-encoded and normalises the mode',
        () {
      final task = compilePlaybook('''
write_files:
  - path: /etc/motd
    content: "it's \$HOME\\n"
    permissions: "0644"
    owner: root:root
''').single;
      final payload = base64.encode(utf8.encode("it's \$HOME\n"));
      expect(task.script, contains("printf %s '$payload' | base64 -d"));
      expect(task.script, contains("mode='644'"));
      expect(task.script, contains("owner='root:root'"));
      expect(task.script, contains('stat -c %U:%G'));
      // Numeric ids are accepted for `owner` too.
      expect(task.script, contains('stat -c %u:%g'));
      // The content itself never appears as shell text.
      expect(task.script, isNot(contains('\$HOME')));
    });

    test('an Ansible playbook compiles to an install step and a run step', () {
      const doc = '- hosts: all\n  tasks:\n    - ping:\n';
      final tasks = compilePlaybook(doc);
      expect(tasks.map((t) => t.titleKey), [
        'playbooktaskansible-text',
        'playbooktaskansiblerun-text',
      ]);
      expect(tasks[0].script, contains('pkg_install ansible'));
      expect(tasks[1].script,
          contains("ansible-playbook -i 'localhost,' -c local"));
      // `changed` is read off the recap line, not off any task's output.
      expect(tasks[1].script,
          contains("'^localhost[[:space:]]*:.*changed=[1-9]'"));
      expect(tasks[1].script, contains(base64.encode(utf8.encode(doc))));
    });

    test('refuses what validatePlaybook refuses', () {
      expect(() => compilePlaybook('just text'), throwsFormatException);
    });
  });

  group('the step scripts', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('wslm-playbook-');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    Future<ProcessResult> runScript(ProvisioningTask task,
        {bool check = false}) async {
      final file = File('${dir.path}/step.sh');
      await file.writeAsString(task.script!);
      return Process.run('bash', [file.path],
          environment: {'WSLM_CHECK': check ? '1' : '0'},
          workingDirectory: dir.path);
    }

    TaskResult resultOf(
            ProvisioningTask task, ProcessResult r) =>
        parseTaskOutput(
            task,
            VmCommandOutput(
                r.exitCode, r.stdout.toString(), r.stderr.toString()));

    test('every script a full document compiles to is valid bash', () async {
      const doc = '''
users:
  - name: dev
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: [ssh-ed25519 AAAA]
write_files:
  - path: /etc/motd
    content: hi
    permissions: "0644"
    owner: root
  - path: /etc/x
    content: more
    append: true
package_update: true
packages: [git]
package_upgrade: true
timezone: UTC
services:
  - ssh
runcmd:
  - cmd: echo hi
    creates: /tmp/x
''';
      final all = [
        ...compilePlaybook(doc),
        ...compilePlaybook('- hosts: all\n  tasks: []\n'),
      ];
      for (final task in all) {
        final file = File('${dir.path}/check.sh');
        await file.writeAsString(task.script!);
        final r = await Process.run('bash', ['-n', file.path]);
        expect(r.exitCode, 0,
            reason: '${task.titleKey} ${task.titleArgs}: ${r.stderr}');
      }
    }, skip: !Platform.isMacOS && !Platform.isLinux);

    test('a command step answers changed, ok on creates, skipped on check',
        () async {
      final marker = '${dir.path}/made';
      final task = compilePlaybook(
              'runcmd:\n  - cmd: "echo ran && touch $marker"\n    creates: $marker\n')
          .single;

      var result = resultOf(task, await runScript(task, check: true));
      expect(result.status, TaskStatus.skipped);
      expect(File(marker).existsSync(), isFalse);

      result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.changed);
      expect(result.output, 'ran');
      expect(File(marker).existsSync(), isTrue);

      result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.ok);
      expect(result.output, contains('exists'));
    }, skip: !Platform.isMacOS && !Platform.isLinux);

    test('output without a trailing newline does not swallow the marker',
        () async {
      final task = compilePlaybook("runcmd:\n  - printf 'hello'\n").single;
      final result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.changed);
      expect(result.output, 'hello');
    }, skip: !Platform.isMacOS && !Platform.isLinux);

    test('a failing command answers failed with its exit status', () async {
      final task =
          compilePlaybook('runcmd:\n  - "echo oops >&2; exit 3"\n').single;
      final result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.failed);
      expect(result.output, contains('oops'));
      expect(result.output, contains('command exited 3'));
    }, skip: !Platform.isMacOS && !Platform.isLinux);

    test('a file step writes once and is ok afterwards, in check mode too',
        () async {
      final path = '${dir.path}/motd';
      final task = compilePlaybook(
              'write_files:\n  - path: $path\n    content: "hello \$USER\\n"\n')
          .single;

      var result = resultOf(task, await runScript(task, check: true));
      expect(result.status, TaskStatus.changed);
      expect(result.output, contains('create'));
      expect(File(path).existsSync(), isFalse);

      result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.changed);
      expect(File(path).readAsStringSync(), 'hello \$USER\n');
      // cloud-config's default, not mktemp's 0600.
      expect(File(path).statSync().mode & 0x1FF, 0x1A4);

      result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.ok);
      expect(result.output, contains('unchanged'));

      // An edit in the instance is put back.
      File(path).writeAsStringSync('drift\n');
      result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.changed);
      expect(result.output, contains('replace'));
      expect(File(path).readAsStringSync(), 'hello \$USER\n');
    }, skip: !Platform.isMacOS && !Platform.isLinux);

    test('an append step adds the content once', () async {
      final path = '${dir.path}/rc';
      File(path).writeAsStringSync('first\n');
      final task = compilePlaybook(
              'write_files:\n  - path: $path\n    content: "second\\n"\n    append: true\n')
          .single;
      var result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.changed);
      expect(File(path).readAsStringSync(), 'first\nsecond\n');
      result = resultOf(task, await runScript(task));
      expect(result.status, TaskStatus.ok);
      expect(File(path).readAsStringSync(), 'first\nsecond\n');
    }, skip: !Platform.isMacOS && !Platform.isLinux);
  });

  group('parseTaskOutput', () {
    const task = ProvisioningTask(titleKey: 't', script: 'x');

    test('reads the marker and keeps the rest as output', () {
      final r = parseTaskOutput(
          task, const VmCommandOutput(0, 'git: present\n__wslm__:ok\n', ''));
      expect(r.status, TaskStatus.ok);
      expect(r.output, 'git: present');
    });

    test('appends stderr to the output', () {
      final r = parseTaskOutput(
          task, const VmCommandOutput(0, '__wslm__:failed\n', 'no apt\n'));
      expect(r.status, TaskStatus.failed);
      expect(r.output, 'no apt');
    });

    test('a non-zero exit or a missing marker is a failure', () {
      expect(
          parseTaskOutput(task, const VmCommandOutput(1, '__wslm__:ok\n', ''))
              .status,
          TaskStatus.failed);
      expect(
          parseTaskOutput(task, const VmCommandOutput(0, 'nothing\n', ''))
              .status,
          TaskStatus.failed);
      expect(
          parseTaskOutput(
                  task, const VmCommandOutput(0, '__wslm__:maybe\n', ''))
              .status,
          TaskStatus.failed);
    });

    test('survives CRLF output and a lone CR progress line', () {
      var r = parseTaskOutput(
          task, const VmCommandOutput(0, 'a\r\n__wslm__:changed\r\n', ''));
      expect(r.status, TaskStatus.changed);
      expect(r.output, 'a');
      r = parseTaskOutput(
          task, const VmCommandOutput(0, '10%\r100%\n__wslm__:ok\n', ''));
      expect(r.status, TaskStatus.ok);
      expect(r.output, '10%\n100%');
    });
  });

  test('shellQuote makes any string one literal word', () {
    expect(shellQuote('plain'), "'plain'");
    expect(shellQuote("it's \$x `y`"), "'it'\\''s \$x `y`'");
  });

  group('ProvisioningRunner', () {
    const playbook = Playbook(
      name: 'dev',
      content: 'packages: [git]\nhostname: box\nruncmd:\n  - echo hi\n',
    );

    test('runs every step as root through the backend and records the run',
        () async {
      final backend = ScriptedBackend();
      backend.answers.addAll([
        answer('changed', stdout: 'git: missing'),
        answer('changed', stdout: 'hi'),
      ]);
      final seen = <int>[];
      final report = await ProvisioningRunner(backend).apply(
        'ubuntu',
        playbook,
        onProgress: (r) => seen.add(r.results.length),
      );
      // Keys the engine does not handle are reported after the ones it
      // does, so the skipped `hostname` comes last.
      expect(report.results.map((r) => r.status), [
        TaskStatus.changed,
        TaskStatus.changed,
        TaskStatus.skipped,
      ]);
      expect(seen, [1, 2, 3]);
      expect(report.finished, isTrue);
      expect(report.stopped, isFalse);
      expect(report.status, TaskStatus.changed);
      // The skipped step never reached the instance.
      expect(backend.commands, hasLength(2));
      expect(backend.targets, ['ubuntu', 'ubuntu']);
      expect(backend.commands.first, contains('WSLM_CHECK=0 sh'));
      expect(scriptOf(backend.commands.first), contains("for p in 'git'"));
      expect(backend.timeouts.first, const Duration(minutes: 60));

      final run = PlaybookRunStore.instance.forPlaybook('dev').single;
      expect(run.instance, 'ubuntu');
      expect(run.check, isFalse);
      expect(run.status, TaskStatus.changed);
      expect(run.changed, 2);
      expect(run.skipped, 1);
      expect(run.failed, 0);
    });

    test('check mode sets WSLM_CHECK=1 and is recorded as a check', () async {
      final backend = ScriptedBackend();
      final report = await ProvisioningRunner(backend)
          .apply('ubuntu', playbook, check: true);
      expect(report.check, isTrue);
      expect(backend.commands.first, contains('WSLM_CHECK=1 sh'));
      expect(PlaybookRunStore.instance.forPlaybook('dev').single.check, isTrue);
    });

    test('stops at the first failed step', () async {
      final backend = ScriptedBackend();
      backend.answers.add(answer('failed', stderr: 'no apt'));
      final report =
          await ProvisioningRunner(backend).apply('ubuntu', playbook);
      expect(report.results, hasLength(1));
      expect(report.results.single.status, TaskStatus.failed);
      expect(report.results.single.output, 'no apt');
      expect(report.stopped, isTrue);
      expect(report.finished, isTrue);
      expect(report.failed, isTrue);
      expect(report.status, TaskStatus.failed);
      expect(backend.commands, hasLength(1));
      expect(PlaybookRunStore.instance.forPlaybook('dev').single.status,
          TaskStatus.failed);
    });

    test(
        'a check run goes on past a failed step and is kept apart from applies',
        () async {
      final backend = ScriptedBackend();
      await ProvisioningRunner(backend).apply('ubuntu', playbook);
      backend.answers.add(answer('failed', stderr: 'no systemd'));
      final report = await ProvisioningRunner(backend)
          .apply('ubuntu', playbook, check: true);
      expect(report.results.map((r) => r.status), [
        TaskStatus.failed,
        TaskStatus.ok,
        TaskStatus.skipped,
      ]);
      expect(report.stopped, isFalse);
      expect(report.failed, isTrue);
      final runs = PlaybookRunStore.instance.forPlaybook('dev');
      expect(runs.map((r) => r.check), [true, false]);
      expect(runs.last.status, TaskStatus.ok,
          reason: 'the applied record survives a later check');
    });

    test('two runs recorded in the same clock tick still list newest first',
        () async {
      // A coarse clock, or an apply and a check back to back, can stamp two
      // runs with one instant; the later record must still come first.
      PlaybookRunStore.instance.now = () => DateTime(2026, 9, 17, 12);
      final backend = ScriptedBackend();
      await ProvisioningRunner(backend).apply('ubuntu', playbook);
      await ProvisioningRunner(backend).apply('ubuntu', playbook, check: true);
      final runs = PlaybookRunStore.instance.forPlaybook('dev');
      expect(runs.map((r) => r.at).toSet(), hasLength(1));
      expect(runs.map((r) => r.check), [true, false]);
    });

    test('a run the user stopped is not recorded', () async {
      final backend = ScriptedBackend();
      var calls = 0;
      await ProvisioningRunner(backend).apply(
        'ubuntu',
        playbook,
        shouldStop: () => calls++ >= 1,
      );
      expect(PlaybookRunStore.instance.forPlaybook('dev'), isEmpty);
    });

    test('the caller may hand in the compiled steps', () async {
      final backend = ScriptedBackend();
      final tasks = compilePlaybook(playbook.content);
      final report = await ProvisioningRunner(backend)
          .apply('ubuntu', playbook, tasks: tasks);
      expect(identical(report.tasks, tasks), isTrue);
    });

    test('a backend that throws is a failed step, not a crash', () async {
      final backend = ScriptedBackend()..failure = StateError('gone');
      final report =
          await ProvisioningRunner(backend).apply('ubuntu', playbook);
      expect(report.results.single.status, TaskStatus.failed);
      expect(report.results.single.output, contains('gone'));
    });

    test('stop is honoured between steps', () async {
      final backend = ScriptedBackend();
      var calls = 0;
      final report = await ProvisioningRunner(backend).apply(
        'ubuntu',
        playbook,
        shouldStop: () => calls++ >= 1,
      );
      expect(report.results, hasLength(1));
      expect(report.stopped, isTrue);
      expect(report.finished, isTrue);
      expect(report.failed, isFalse);
    });

    test('commandFor lands the script in a temp file and cleans it up', () {
      const task = ProvisioningTask(titleKey: 't', script: 'echo "\$x" \'q\'');
      final command = ProvisioningRunner.commandFor(task, check: false);
      expect(command, startsWith('t=\$(mktemp) && printf %s '));
      // POSIX sh, so the script does not need bash once it is in.
      expect(command, contains('WSLM_CHECK=0 sh \$t'));
      expect(command, endsWith('rm -f \$t; exit \$rc'));
      // No quote of either kind on the command line (see commandFor).
      expect(command, isNot(contains("'")));
      expect(command, isNot(contains('"')));
      expect(scriptOf(command), 'echo "\$x" \'q\'');
      // Nothing of the script is on the command line in the clear.
      expect(command, isNot(contains('"\$x"')));
    });
  });

  group('PlaybookStore', () {
    final store = PlaybookStore.instance;

    test('saves, lists, finds and removes, normalising line endings', () async {
      await store.save(const Playbook(
          name: 'dev', description: 'd', content: 'packages: [git]\r\n'));
      expect(store.items.map((e) => e.name), ['dev']);
      expect(store.byName('dev')?.content, 'packages: [git]\n');
      expect(store.byName('nope'), isNull);
      expect(await store.remove('dev'), isTrue);
      expect(await store.remove('dev'), isFalse);
      expect(store.items, isEmpty);
    });

    test('a rename keeps the slot and never leaves two entries', () async {
      await store.save(const Playbook(name: 'a', content: 'packages: [x]'));
      await store.save(const Playbook(name: 'b', content: 'packages: [y]'));
      await store.save(const Playbook(name: 'a2', content: 'packages: [z]'),
          previousName: 'a');
      expect(store.items.map((e) => e.name), ['a2', 'b']);
      await store.save(const Playbook(name: 'b', content: 'packages: [w]'),
          previousName: 'a2');
      expect(store.items.map((e) => e.name), ['b']);
      expect(store.byName('b')?.content, 'packages: [w]\n');
    });

    test('a rename carries the run history along', () async {
      await store.save(const Playbook(name: 'dev', content: 'packages: [x]'));
      await ProvisioningRunner(ScriptedBackend())
          .apply('ubuntu', store.byName('dev')!);
      await store.save(const Playbook(name: 'prod', content: 'packages: [x]'),
          previousName: 'dev');
      expect(PlaybookRunStore.instance.forPlaybook('dev'), isEmpty);
      expect(PlaybookRunStore.instance.forPlaybook('prod').single.instance,
          'ubuntu');
    });

    test('survives a corrupt preference and a bad entry', () async {
      SharedPreferences.setMockInitialValues({
        PlaybookStore.prefsKey:
            '[{"name":"ok","content":"packages: [x]"},{"nope":1},3]'
      });
      prefs = await SharedPreferences.getInstance();
      store.reload();
      expect(store.items.map((e) => e.name), ['ok']);

      SharedPreferences.setMockInitialValues({PlaybookStore.prefsKey: '{'});
      prefs = await SharedPreferences.getInstance();
      store.reload();
      expect(store.items, isEmpty);
    });

    test('deleting a playbook drops its run history', () async {
      await store.save(const Playbook(name: 'dev', content: 'packages: [x]'));
      await ProvisioningRunner(ScriptedBackend())
          .apply('ubuntu', store.byName('dev')!);
      expect(PlaybookRunStore.instance.forPlaybook('dev'), hasLength(1));
      await store.remove('dev');
      expect(PlaybookRunStore.instance.forPlaybook('dev'), isEmpty);
    });
  });

  group('PlaybookRunStore', () {
    final runs = PlaybookRunStore.instance;
    const playbook = Playbook(name: 'dev', content: 'packages: [x]');

    test('keeps the newest run per playbook and instance, newest first',
        () async {
      var clock = DateTime(2026, 9, 14, 10);
      runs.now = () => clock;
      final runner = ProvisioningRunner(ScriptedBackend());
      await runner.apply('ubuntu', playbook);
      clock = DateTime(2026, 9, 14, 11);
      await runner.apply('alpine', playbook);
      clock = DateTime(2026, 9, 14, 12);
      await runner.apply('ubuntu', playbook, check: true);

      clock = DateTime(2026, 9, 14, 13);
      await runner.apply('ubuntu', playbook);

      // One applied and one checked line per instance; the newest apply
      // replaced the 10:00 one.
      final list = runs.forPlaybook('dev');
      expect(list.map((r) => r.instance), ['ubuntu', 'ubuntu', 'alpine']);
      expect(list.map((r) => r.check), [false, true, false]);
      expect(list.first.at, DateTime(2026, 9, 14, 13));
      expect(runs.runs, hasLength(3));
    });

    test('round-trips through the preferences and follows a rename', () async {
      runs.now = () => DateTime.utc(2026, 9, 14, 10);
      await ProvisioningRunner(ScriptedBackend()).apply('ubuntu', playbook);
      runs.reload();
      final run = runs.forPlaybook('dev').single;
      expect(run.at, DateTime.utc(2026, 9, 14, 10));
      expect(run.ok, 1);
      await runs.renamePlaybook('dev', 'prod');
      expect(runs.forPlaybook('dev'), isEmpty);
      expect(runs.forPlaybook('prod').single.instance, 'ubuntu');
    });

    test('ignores an unreadable record', () async {
      SharedPreferences.setMockInitialValues({
        PlaybookRunStore.prefsKey:
            '[{"playbook":"a","instance":"u","at":"2026-09-14T10:00:00Z","status":"ok"},{"at":"nope"}]'
      });
      prefs = await SharedPreferences.getInstance();
      runs.reload();
      expect(runs.runs, hasLength(1));
      expect(runs.runs.single.status, TaskStatus.ok);
      expect(runs.runs.single.changed, 0);
    });
  });
}
