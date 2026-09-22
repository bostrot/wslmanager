import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm_restart.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_vmctl_shell.dart';
import 'vm_backend_test.dart' show FakeBackend;

const String _running = '{"vms":[{"name":"dev","state":"running"}]}';
const String _stopped = '{"vms":[{"name":"dev","state":"stopped"}]}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {};
  });

  late FakeVmctlShell shell;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    shell = FakeVmctlShell();
    shell.responses['list'] = _running;
    shell.responses['stop'] = '{"stopped":"dev"}';
    shell.responses['start'] = '{"started":"dev"}';
    shell.responses['ip'] = '{"ip":"192.168.64.10"}';
  });

  AppleVmApi apiWith() => AppleVmApi(
        shell: shell,
        helperPathOverride: '/fake/vmctl',
        storeDirOverride: '/tmp/vm-restart-test',
        earlyExitProbeDelay: Duration.zero,
      );

  VmRestartService serviceWith({
    Duration stopTimeout = Duration.zero,
    Duration leaseTimeout = Duration.zero,
  }) =>
      VmRestartService(
        apiWith(),
        stopTimeout: stopTimeout,
        leaseTimeout: leaseTimeout,
        pollInterval: Duration.zero,
      );

  /// The vmctl invocations, in order, ignoring the `hdiutil info` probe the
  /// start does.
  List<List<String>> vmctlCalls() =>
      shell.calls.where((c) => c.first == '/fake/vmctl').toList();

  /// The subcommand of one invocation: the first argument after the
  /// executable that is not part of a leading `--flag value` pair.
  String verbOf(List<String> call) {
    var index = 1;
    while (index < call.length && call[index].startsWith('--')) {
      index += 2;
    }
    return index < call.length ? call[index] : '';
  }

  List<String> verbs() => vmctlCalls().map(verbOf).toList();

  group('support', () {
    test('only the Apple backend can be restarted this way', () {
      expect(VmRestartService.isSupported(apiWith()), isTrue);
      expect(VmRestartService.isSupported(FakeBackend()), isFalse);
    });
  });

  group('restart', () {
    test('stops, waits for it to be down, then starts it headless', () async {
      // Running, still running while stopping, down, up again after start.
      shell.responseQueue['list'] = [_running, _stopped, _running];
      final result = await serviceWith().restart('dev');

      expect(verbs(), ['list', 'stop', 'list', 'start', 'list', 'ip']);
      final stop = vmctlCalls()[1];
      expect(stop, containsAllInOrder(['stop', '--name', 'dev']));
      expect(stop, isNot(contains('--force')));
      expect(vmctlCalls()[3], isNot(contains('--gui')));
      expect(result.wasRunning, isTrue);
      expect(result.forced, isFalse);
      expect(result.ip, '192.168.64.10');
    });

    test('gui opens the display window instead', () async {
      shell.responseQueue['list'] = [_running, _stopped, _running];
      final result = await serviceWith().restart('dev', gui: true);
      expect(vmctlCalls()[3], contains('--gui'));
      expect(result.gui, isTrue);
    });

    test('a guest that ignores the shutdown request is powered off', () async {
      shell.exitCodeQueue['stop'] = [1, 0];
      shell.errors['stop'] = 'VM dev did not stop in time; retry with --force.';
      // Still running after the polite request, down once forced.
      shell.responseQueue['list'] = [_running, _running, _stopped, _running];

      final result = await serviceWith().restart('dev');

      final stops = vmctlCalls().where((c) => verbOf(c) == 'stop').toList();
      expect(stops, hasLength(2));
      expect(stops.first, isNot(contains('--force')));
      expect(stops.last, contains('--force'));
      expect(result.forced, isTrue);
      expect(verbs(), contains('start'));
    });

    test('a stop that failed but left nothing running is not forced', () async {
      shell.exitCodeQueue['stop'] = [1];
      shell.errors['stop'] = 'vmctl stop: broken pipe';
      // The daemon was gone by the time the helper complained.
      shell.responseQueue['list'] = [_running, _stopped, _stopped, _running];

      final result = await serviceWith().restart('dev');

      expect(vmctlCalls().where((c) => c.contains('--force')), isEmpty);
      expect(result.forced, isFalse);
      expect(verbs(), contains('start'));
    });

    test('a VM that will not go down is never started again', () async {
      shell.responses['list'] = _running;

      await expectLater(
        serviceWith().restart('dev'),
        throwsA(isA<VmRestartException>()
            .having((e) => e.message, 'message', contains('still running'))),
      );
      expect(verbs(), isNot(contains('start')));
    });

    test('a guest that comes back without a lease is reported as such',
        () async {
      shell.responseQueue['list'] = [_running, _stopped, _running];
      shell.responses['ip'] = '{}';

      final result = await serviceWith().restart('dev');

      expect(result.ip, isNull);
      expect(result.waitedForIp, isTrue);
    });

    test('wait_for_ip off skips the lease probe entirely', () async {
      shell.responseQueue['list'] = [_running, _stopped, _running];
      final result = await serviceWith().restart('dev', waitForIp: false);
      expect(verbs(), isNot(contains('ip')));
      expect(result.waitedForIp, isFalse);
    });

    test('a stopped VM is simply started', () async {
      shell.responseQueue['list'] = [_stopped, _running];
      final result = await serviceWith().restart('dev');
      expect(verbs(), isNot(contains('stop')));
      expect(result.wasRunning, isFalse);
    });

    test('an unknown VM is refused before anything is stopped', () async {
      shell.responses['list'] = '{"vms":[]}';
      await expectLater(
        serviceWith().restart('ghost'),
        throwsA(isA<VmRestartException>()
            .having((e) => e.message, 'message', contains('No VM named'))),
      );
      expect(verbs(), ['list']);
    });

    test('a start that fails comes back as a restart failure', () async {
      shell.responseQueue['list'] = [_running, _stopped, _stopped];
      shell.exitCodeQueue['start'] = [1];
      shell.errors['start'] = 'VM failed to start: no boot device';

      await expectLater(
        serviceWith().restart('dev'),
        throwsA(isA<VmRestartException>()
            .having((e) => e.message, 'message', contains('no boot device'))),
      );
    });
  });

  group('stop', () {
    test('an already stopped VM is left alone', () async {
      shell.responses['list'] = _stopped;
      final result = await serviceWith().stop('dev');
      expect(result.wasRunning, isFalse);
      expect(result.forced, isFalse);
      expect(verbs(), ['list']);
    });

    test('force: false reports the refusal instead of pulling the plug',
        () async {
      shell.exitCodeQueue['stop'] = [1];
      shell.errors['stop'] = 'VM dev did not stop in time; retry with --force.';
      shell.responses['list'] = _running;

      await expectLater(
        serviceWith().stop('dev', force: false),
        throwsA(isA<VmRestartException>().having(
            (e) => e.message, 'message', contains('did not stop in time'))),
      );
      expect(vmctlCalls().where((c) => c.contains('--force')), isEmpty);
    });

    test('a forced stop that fails too says what both attempts reported',
        () async {
      shell.exitCodeQueue['stop'] = [1, 1];
      shell.errors['stop'] = 'no such process';
      shell.responses['list'] = _running;

      await expectLater(
        serviceWith().stop('dev'),
        throwsA(isA<VmRestartException>().having((e) => e.message, 'message',
            allOf(contains('would not stop'), contains('no such process')))),
      );
    });
  });
}
