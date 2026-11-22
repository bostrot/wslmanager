import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

import 'mocks.dart';

void main() {
  late MockShell mockShell;
  late WSLApi wslApi;
  late WslTerminalManager terminalManager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    mockShell = MockShell();
    wslApi = WSLApi(shell: mockShell);
    terminalManager = WslTerminalManager(wslApi: wslApi);
  });

  McpTool tool(String name) => buildWslMcpTools(wslApi, terminalManager)
      .firstWhere((t) => t.name == name);

  group('wsl_list_distros', () {
    test('lists distros with running/stopped status', () async {
      mockShell.distros.addAll(['Ubuntu', 'ai-workspace']);
      // list() only reports something "running" via a separate mechanism in
      // the real WSLApi.list(); MockShell always returns the same names for
      // both --list variants, so just assert the tool surfaces every distro.
      final result = await tool('wsl_list_distros').handler({});
      expect(result, contains('Ubuntu'));
      expect(result, contains('ai-workspace'));
    });

    test('reports when there are no distros', () async {
      final result = await tool('wsl_list_distros').handler({});
      expect(result, 'No WSL distros installed.');
    });
  });

  group('wsl_run_command', () {
    test('runs the command as root in the named distro', () async {
      await tool('wsl_run_command')
          .handler({'distro': 'Ubuntu', 'command': 'echo hi'});

      // Through the broker now (start channel), so assert on runCalls,
      // which sees both channels.
      expect(mockShell.runCalls.last,
          ['-d', 'Ubuntu', '-u', 'root', '--exec', 'bash', '-c', 'echo hi']);
    });

    test('forwards the client command verbatim, quoting intact', () async {
      // This tool hands an MCP client's command straight to the distro, so it
      // is the call site that suffered most from the old pre-split form: the
      // split stripped the quotes and wsl.exe's default shell then re-parsed
      // the unquoted result. See lib/api/wsl_args.dart.
      const cmd = "grep -c 'root:x:0' /etc/passwd | tee /tmp/n";
      await tool('wsl_run_command')
          .handler({'distro': 'Ubuntu', 'command': cmd});

      expect(mockShell.runCalls.last.last, cmd);
      expect(mockShell.runCalls.last, contains('--exec'));
      expect(mockShell.lastRunInShell, isFalse);
    });

    test('rejects a missing distro argument', () async {
      expect(
        () => tool('wsl_run_command').handler({'command': 'echo hi'}),
        throwsArgumentError,
      );
    });

    test('rejects a missing command argument', () async {
      expect(
        () => tool('wsl_run_command').handler({'distro': 'Ubuntu'}),
        throwsArgumentError,
      );
    });

    test('reports "(no output)" instead of an empty string', () async {
      final result = await tool('wsl_run_command')
          .handler({'distro': 'Ubuntu', 'command': 'true'});
      expect(result, '(no output)');
    });
  });

  group('wsl_stop_distro', () {
    test('terminates the named distro', () async {
      final result =
          await tool('wsl_stop_distro').handler({'distro': 'Ubuntu'});

      expect(mockShell.lastRunArguments, contains('--terminate'));
      expect(mockShell.lastRunArguments, contains('Ubuntu'));
      expect(result, contains('Ubuntu'));
    });

    test('rejects a missing distro argument', () async {
      expect(
        () => tool('wsl_stop_distro').handler({}),
        throwsArgumentError,
      );
    });
  });

  test('the tool surface covers the whole lifecycle', () {
    // container_* is gated with the Containers screen; this assertion is
    // about the whole surface, so open the gate for it.
    ExperimentalFeatures.overrideAll = true;
    addTearDown(() => ExperimentalFeatures.overrideAll = null);
    final names =
        buildWslMcpTools(wslApi, terminalManager).map((t) => t.name).toSet();
    // v2 exposes create → configure → operate → destroy. The one-way
    // operations (unregister, container_remove) are confirm-gated rather than
    // hidden — see the dedicated group below. The container_* family rides
    // along on every backend: the engine belongs to the host, not to WSL
    // (bostrot/ai-tasks#57). The kube_* and cloud_* families ride along for
    // the same reason and are read-only throughout (bostrot/ai-tasks#67).
    expect(names, {
      'container_list',
      'container_engines',
      'container_start',
      'container_stop',
      'container_restart',
      'container_remove',
      'container_logs',
      'container_exec',
      'container_inspect',
      'container_images',
      'container_volumes',
      'container_networks',
      'container_stats',
      'container_processes',
      'container_disk_usage',
      'kube_contexts',
      'kube_namespaces',
      'kube_workloads',
      'kube_pods',
      'kube_pod_logs',
      'kube_describe',
      'kube_get',
      'kube_events',
      'kube_top',
      'cloud_servers',
      'cloud_server_info',
      'wsl_list_distros',
      'wsl_distro_info',
      'wsl_status',
      'wsl_list_online_distros',
      'wsl_list_catalog',
      'wsl_install_distro',
      'wsl_import_distro',
      'wsl_import_in_place',
      'wsl_export_distro',
      'wsl_package_distro',
      'wsl_install_package',
      'wsl_unregister_distro',
      'wsl_get_wsl_conf',
      'wsl_set_wsl_conf',
      'wsl_get_wslconfig',
      'wsl_set_wslconfig',
      'wsl_set_default_user',
      'wsl_set_default_distro',
      'wsl_set_version',
      'wsl_set_default_version',
      'wsl_run_command',
      'wsl_stop_distro',
      'wsl_shutdown',
      'wsl_copy_to',
      'wsl_copy_from',
      'wsl_move_distro',
      'wsl_resize_distro',
      'wsl_compact_disk',
      'wsl_mount_disk',
      'wsl_unmount_disk',
      'wsl_list_snippets',
      'wsl_get_snippet',
      'wsl_create_snippet',
      'wsl_delete_snippet',
      'wsl_list_physical_disks',
      'wsl_list_mounted_disks',
      'wsl_list_recipes',
      'wsl_install_service',
      'wsl_terminal_start',
      'wsl_terminal_send',
      'wsl_terminal_read',
      'wsl_terminal_signal',
      'wsl_terminal_list',
      'wsl_terminal_close',
    });
  });

  group('snippets', () {
    test('create, list, get and delete round-trip through prefs', () async {
      expect(await tool('wsl_list_snippets').handler({}), 'No snippets saved.');

      final created = await tool('wsl_create_snippet').handler({
        'name': 'update',
        'content': 'apt update && apt upgrade -y',
        'description': 'refresh packages',
      });
      expect(created, contains('Created'));

      final list = await tool('wsl_list_snippets').handler({});
      expect(list, contains('update'));
      expect(list, contains('refresh packages'));

      final body = await tool('wsl_get_snippet').handler({'name': 'update'});
      expect(body, 'apt update && apt upgrade -y');

      // A second create with the same name updates rather than duplicates.
      final updated = await tool('wsl_create_snippet')
          .handler({'name': 'update', 'content': 'apt update'});
      expect(updated, contains('Updated'));

      await tool('wsl_delete_snippet').handler({'name': 'update'});
      expect(await tool('wsl_list_snippets').handler({}), 'No snippets saved.');
    });

    test('get and delete reject an unknown snippet', () async {
      await expectLater(
          tool('wsl_get_snippet').handler({'name': 'nope'}),
          throwsArgumentError);
      await expectLater(
          tool('wsl_delete_snippet').handler({'name': 'nope'}),
          throwsArgumentError);
    });
  });

  group('wsl_run_command overrides', () {
    test('user, cwd and timeout reshape the argv', () async {
      await tool('wsl_run_command').handler({
        'distro': 'Ubuntu',
        'command': 'make',
        'user': 'dev',
        'cwd': '/src',
        'timeout_seconds': 10,
      });

      expect(mockShell.runCalls.last, [
        '-d',
        'Ubuntu',
        '--cd',
        '/src',
        '-u',
        'dev',
        '--exec',
        'bash',
        '-c',
        'make',
      ]);
    });
  });

  group('wsl_unregister_distro', () {
    test('refuses without confirm and touches nothing', () async {
      await expectLater(
        tool('wsl_unregister_distro')
            .handler({'distro': 'Ubuntu', 'confirm': false}),
        throwsArgumentError,
      );
      expect(mockShell.runCalls, isEmpty);
    });

    test('unregisters with confirm: true', () async {
      final result = await tool('wsl_unregister_distro')
          .handler({'distro': 'Ubuntu', 'confirm': true});

      expect(mockShell.runCalls.any((c) => c.contains('--unregister')), true);
      expect(mockShell.runCalls.any((c) => c.contains('Ubuntu')), true);
      expect(result, contains('Unregistered'));
    });
  });

  group('lifecycle argv shapes', () {
    test('wsl_list_online_distros asks the catalog', () async {
      await tool('wsl_list_online_distros').handler({});
      expect(mockShell.runCalls.last, ['--list', '--online']);
    });

    test('wsl_install_distro installs headless', () async {
      await tool('wsl_install_distro').handler({'distro': 'Ubuntu-24.04'});
      expect(mockShell.runCalls.last,
          ['--install', '-d', 'Ubuntu-24.04', '--no-launch']);
    });

    test('wsl_set_default_distro uses --set-default', () async {
      await tool('wsl_set_default_distro').handler({'distro': 'Ubuntu'});
      expect(mockShell.runCalls.last, ['--set-default', 'Ubuntu']);
    });

    test('wsl_set_version rejects anything but 1 or 2', () async {
      await expectLater(
        tool('wsl_set_version').handler({'distro': 'Ubuntu', 'version': 3}),
        throwsArgumentError,
      );
    });

    test('wsl_import_distro refuses a missing local tarball', () async {
      await expectLater(
        tool('wsl_import_distro').handler({
          'name': 'fresh',
          'tarball': 'C:\\definitely\\missing\\rootfs.tar.gz',
        }),
        throwsArgumentError,
      );
      expect(mockShell.runCalls, isEmpty);
    });

    test('wsl_import_in_place refuses a missing vhdx', () async {
      await expectLater(
        tool('wsl_import_in_place').handler({
          'name': 'fresh',
          'vhdx_path': 'C:\\definitely\\missing\\disk.vhdx',
        }),
        throwsArgumentError,
      );
      expect(mockShell.runCalls, isEmpty);
    });
  });

  group('wsl_terminal_signal', () {
    test('rejects an unknown session id', () async {
      await expectLater(
        tool('wsl_terminal_signal')
            .handler({'session_id': 'nope', 'signal': 'ctrl-c'}),
        throwsArgumentError,
      );
    });

    test('kill on an unknown session is still an error, not a no-op',
        () async {
      await expectLater(
        tool('wsl_terminal_signal')
            .handler({'session_id': 'nope', 'signal': 'kill'}),
        throwsArgumentError,
      );
    });
  });

  group('wsl_terminal_*', () {
    test('start returns a session id and the manager tracks it', () async {
      final result = await tool('wsl_terminal_start').handler({'distro': 'Ubuntu'});

      expect(result, contains('Ubuntu'));
      expect(terminalManager.sessions, hasLength(1));
      expect(mockShell.lastStartExecutable, 'wsl');
      expect(mockShell.lastStartArguments, containsAllInOrder(['-d', 'Ubuntu', '-u', 'root']));
    });

    test('send rejects an unknown session id', () async {
      expect(
        () => tool('wsl_terminal_send')
            .handler({'session_id': 'nope', 'input': 'echo hi'}),
        throwsArgumentError,
      );
    });

    test('read rejects an unknown session id', () async {
      expect(
        () => tool('wsl_terminal_read').handler({'session_id': 'nope'}),
        throwsArgumentError,
      );
    });

    test('close rejects an unknown session id', () async {
      expect(
        () => tool('wsl_terminal_close').handler({'session_id': 'nope'}),
        throwsArgumentError,
      );
    });

    test('list reports no sessions when none are open', () async {
      final result = await tool('wsl_terminal_list').handler({});
      expect(result, 'No open terminal sessions.');
    });

    test('start, list, then close round-trips through the manager',
        () async {
      final startResult =
          await tool('wsl_terminal_start').handler({'distro': 'Ubuntu'});
      final sessionId = terminalManager.sessions.single.id;
      expect(startResult, contains(sessionId));

      final listResult = await tool('wsl_terminal_list').handler({});
      expect(listResult, contains(sessionId));
      expect(listResult, contains('Ubuntu'));

      final closeResult =
          await tool('wsl_terminal_close').handler({'session_id': sessionId});
      expect(closeResult, contains(sessionId));
      expect(terminalManager.sessions, isEmpty);
    });
  });
  group('recording declarations (ai-tasks#77)', () {
    test('the tools that change an instance declare how they are recorded,'
        ' read-only ones do not', () {
      ExperimentalFeatures.overrideAll = true;
      addTearDown(() => ExperimentalFeatures.overrideAll = null);
      final tools = buildWslMcpTools(wslApi, terminalManager);
      final recorded =
          tools.where((t) => t.recording != null).map((t) => t.name).toSet();

      expect(
          recorded,
          containsAll({
            'wsl_unregister_distro',
            'wsl_run_command',
            'wsl_install_service',
            'wsl_install_distro',
            'wsl_import_distro',
            'wsl_import_in_place',
            'wsl_install_package',
            'wsl_set_wsl_conf',
            'wsl_set_wslconfig',
            'wsl_set_default_user',
            'wsl_set_default_distro',
            'wsl_set_version',
            'wsl_set_default_version',
            'wsl_copy_to',
            'wsl_move_distro',
            'wsl_resize_distro',
            'wsl_compact_disk',
            'wsl_mount_disk',
            'wsl_unmount_disk',
            'wsl_terminal_send',
            'container_start',
            'container_stop',
            'container_restart',
            'container_remove',
            'container_exec',
          }));
      // Looking is not a change; nor is a stop, which the next boot undoes;
      // nor are the snippet tools, whose product is the record itself.
      for (final name in recorded) {
        expect(
            name,
            isNot(matches(RegExp(r'^(wsl_list_|wsl_get_|kube_|'
                r'cloud_|wsl_status|wsl_distro_info|wsl_stop_distro|'
                r'wsl_shutdown|wsl_.*snippet|wsl_terminal_(start|read|list|'
                r'close|signal)|container_(list|engines|logs|inspect|images|'
                r'volumes|networks|stats|processes|disk_usage))'))));
      }
    });

    test('every declared target or shell argument exists on its tool', () {
      ExperimentalFeatures.overrideAll = true;
      addTearDown(() => ExperimentalFeatures.overrideAll = null);
      for (final t in buildWslMcpTools(wslApi, terminalManager)) {
        final recording = t.recording;
        if (recording == null) continue;
        final properties =
            (t.inputSchema['properties'] as Map).keys.cast<String>().toSet();
        for (final key in [recording.target, recording.shell]) {
          if (key == null) continue;
          expect(properties, contains(key),
              reason: '${t.name} records "$key", which it has no argument for');
        }
      }
    });

    test('a shell command tool records exactly the command it ran', () {
      final run = tool('wsl_run_command');
      expect(run.recording?.target, 'distro');
      expect(run.recording?.shell, 'command');
      // A mount point's `name` is not an instance.
      expect(tool('wsl_mount_disk').recording?.target, isNull);
    });
  });
}
