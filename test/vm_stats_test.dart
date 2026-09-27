/// Tests for lib/api/vm_stats.dart — the per-instance CPU and memory readings
/// behind the resource monitor (bostrot/ai-tasks#109).
///
/// The probe outputs below are the shape a real guest produces: the fixtures
/// were taken from `/proc` on Ubuntu 24.04 and Alpine 3.20 guests, which is
/// also where the two `awk` implementations the script has to survive live.
// ignore_for_file: dangling_library_doc_comments

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm_stats.dart';

import 'fake_provisioning_backend.dart';

/// A probe answer, with every line the script emits and sensible defaults.
String probe({
  int cpus = 4,
  int tick = 100,
  int page = 4096,
  double uptime = 100.0,
  int memTotalKb = 8 * 1024 * 1024,
  int? memAvailableKb = 6 * 1024 * 1024,
  int memFreeKb = 5 * 1024 * 1024,
  int? swapTotalKb = 2 * 1024 * 1024,
  int? swapFreeKb = 2 * 1024 * 1024,
  List<int> cpuLine = const [1000, 0, 500, 9000, 100, 0, 0, 0, 0, 0],
  List<List<int>> processes = const [
    [100, 50, 1000],
    [10, 5, 500],
  ],
}) {
  final lines = <String>[
    'CPUS $cpus',
    'TICK $tick',
    'PAGE $page',
    'UP $uptime',
    'MemTotal:       $memTotalKb kB',
    if (memAvailableKb != null) 'MemAvailable:   $memAvailableKb kB',
    'MemFree:        $memFreeKb kB',
    if (swapTotalKb != null) 'SwapTotal:      $swapTotalKb kB',
    if (swapFreeKb != null) 'SwapFree:       $swapFreeKb kB',
    'cpu  ${cpuLine.join(' ')}',
    for (final p in processes) 'P ${p[0]} ${p[1]} ${p[2]}',
  ];
  return '${lines.join('\n')}\n';
}

void main() {
  group('parseVmResourceProbe', () {
    test('reads a whole guest reading', () {
      final snapshot = parseVmResourceProbe(probe());
      expect(snapshot.cpuCount, 4);
      expect(snapshot.clockTicks, 100);
      expect(snapshot.uptimeSeconds, 100.0);
      expect(snapshot.instanceCpuTicks, 165);
      expect(snapshot.instanceResidentBytes, 1500 * 4096);
      expect(snapshot.processCount, 2);
      expect(snapshot.memTotalBytes, 8 * 1024 * 1024 * 1024);
      expect(snapshot.memAvailableBytes, 6 * 1024 * 1024 * 1024);
      expect(snapshot.swapTotalBytes, 2 * 1024 * 1024 * 1024);
      expect(snapshot.swapFreeBytes, 2 * 1024 * 1024 * 1024);
      // Everything but idle (4th) and iowait (5th) is time the guest spent
      // doing something.
      expect(snapshot.guestCpuTotalTicks, 10600);
      expect(snapshot.guestCpuBusyTicks, 1500);
    });

    test('a 16K-page guest is not read as four times smaller', () {
      // Arm64 kernels are free to use a 16K page, and RSS is reported in
      // pages — hardcoding 4096 would understate an Apple VM by 4x.
      final snapshot = parseVmResourceProbe(probe(page: 16384));
      expect(snapshot.instanceResidentBytes, 1500 * 16384);
    });

    test('falls back to MemFree on a kernel without MemAvailable', () {
      final snapshot = parseVmResourceProbe(probe(memAvailableKb: null));
      expect(snapshot.memAvailableBytes, 5 * 1024 * 1024 * 1024);
    });

    test('a guest with no swap reads as zero, not as unreadable', () {
      final snapshot =
          parseVmResourceProbe(probe(swapTotalKb: null, swapFreeKb: null));
      expect(snapshot.swapTotalBytes, 0);
      expect(snapshot.swapFreeBytes, 0);
    });

    test('substitutes a divisor for counts a guest would not report', () {
      final snapshot = parseVmResourceProbe(probe(cpus: 0, tick: 0, page: 0));
      expect(snapshot.cpuCount, 1);
      expect(snapshot.clockTicks, 100);
      expect(snapshot.instanceResidentBytes, 1500 * 4096);
    });

    test('a process line truncated by a race still counts as a process', () {
      // `awk` walks a glob of /proc entries; one of them exiting halfway
      // leaves a short line behind.
      final snapshot = parseVmResourceProbe('${probe()}P 7\n');
      expect(snapshot.processCount, 3);
      expect(snapshot.instanceCpuTicks, 172);
    });

    test('no reading at all is an error, not an empty one', () {
      expect(() => parseVmResourceProbe(''),
          throwsA(isA<VmStatsException>()));
      // A guest that answered but has no /proc — a macOS VM, an appliance.
      expect(() => parseVmResourceProbe('CPUS 4\nTICK 100\n'),
          throwsA(isA<VmStatsException>()));
      // The message is an i18n key the dialog translates.
      expect(
          () => parseVmResourceProbe(''),
          throwsA(predicate((error) =>
              error is VmStatsException &&
              error.message == 'vmresourcesnoproc-text')));
    });

    test('an instance with no processes of its own reads as zero', () {
      final snapshot = parseVmResourceProbe(probe(processes: const []));
      expect(snapshot.processCount, 0);
      expect(snapshot.instanceCpuTicks, 0);
      expect(snapshot.instanceResidentBytes, 0);
    });
  });

  group('deriveVmUsage', () {
    test('the first reading has totals but no rates', () {
      final usage = deriveVmUsage(parseVmResourceProbe(probe()), null);
      expect(usage.instanceCpuPercent, isNull);
      expect(usage.guestCpuPercent, isNull);
      expect(usage.instanceMemoryBytes, 1500 * 4096);
      expect(usage.memoryUsedBytes, 2 * 1024 * 1024 * 1024);
      expect(usage.memoryTotalBytes, 8 * 1024 * 1024 * 1024);
      expect(usage.swapUsedBytes, 0);
      expect(usage.processCount, 2);
    });

    test('a pair of readings gives a share of the whole machine', () {
      final first = parseVmResourceProbe(probe(uptime: 100.0));
      // Two seconds later, 200 more ticks — two full seconds of CPU — on a
      // four-processor guest: a quarter of everything there is.
      final second = parseVmResourceProbe(probe(
        uptime: 102.0,
        processes: const [
          [250, 100, 1000],
          [10, 5, 500],
        ],
      ));
      final usage = deriveVmUsage(second, first);
      expect(usage.instanceCpuPercent, closeTo(25.0, 0.001));
    });

    test('the whole guest\'s share comes from its own tick deltas', () {
      final first = parseVmResourceProbe(probe(uptime: 100.0));
      final second = parseVmResourceProbe(probe(
        uptime: 102.0,
        // 300 busy ticks and 700 idle ones later: 30% of the machine.
        cpuLine: const [1300, 0, 500, 9700, 100, 0, 0, 0, 0, 0],
      ));
      expect(deriveVmUsage(second, first).guestCpuPercent,
          closeTo(30.0, 0.001));
    });

    test('a restarted guest reports no rate rather than a wrong one', () {
      final before = parseVmResourceProbe(probe(uptime: 5000.0));
      // Counters back near zero and an uptime that went backwards is what a
      // reboot between two samples looks like from in here.
      final after = parseVmResourceProbe(probe(
        uptime: 12.0,
        cpuLine: const [10, 0, 5, 90, 1, 0, 0, 0, 0, 0],
        processes: const [
          [1, 0, 100]
        ],
      ));
      final usage = deriveVmUsage(after, before);
      expect(usage.instanceCpuPercent, isNull);
      expect(usage.guestCpuPercent, isNull);
      // The totals are still worth showing.
      expect(usage.instanceMemoryBytes, 100 * 4096);
    });

    test('two readings from the same instant are not divided by zero', () {
      final snapshot = parseVmResourceProbe(probe(uptime: 100.0));
      final usage = deriveVmUsage(snapshot, snapshot);
      expect(usage.instanceCpuPercent, isNull);
      expect(usage.guestCpuPercent, isNull);
    });

    test('more CPU than the machine has still reads as 100%', () {
      final first = parseVmResourceProbe(probe(cpus: 1, uptime: 100.0));
      final second = parseVmResourceProbe(probe(
        cpus: 1,
        uptime: 100.5,
        processes: const [
          [10000, 0, 1000],
        ],
      ));
      expect(deriveVmUsage(second, first).instanceCpuPercent, 100.0);
    });

    test('a ballooned guest does not report negative memory in use', () {
      // `MemAvailable` above `MemTotal` happens with a balloon driver.
      final snapshot = parseVmResourceProbe(probe(
          memTotalKb: 1024 * 1024, memAvailableKb: 2 * 1024 * 1024));
      final usage = deriveVmUsage(snapshot, null);
      expect(usage.memoryUsedBytes, 0);
      expect(usage.memoryUsedPercent, 0);
    });

    test('percentages of an unknown total are zero, never a division by it',
        () {
      final usage = deriveVmUsage(
          parseVmResourceProbe(probe(memTotalKb: 0)), null);
      expect(usage.memoryTotalBytes, 0);
      expect(usage.instanceMemoryPercent, 0);
      expect(usage.memoryUsedPercent, 0);
    });
  });

  group('VmStatsService', () {
    test('asks the guest once and reports rates from the second reading',
        () async {
      final backend =
          ScriptedBackend(runningInstances: const ['ubuntu', 'alpine']);
      final service = VmStatsService(backend);
      backend.answers.add(VmCommandOutput(0, probe(uptime: 100.0), ''));
      backend.answers.add(VmCommandOutput(
          0,
          probe(uptime: 102.0, processes: const [
            [250, 100, 1000],
            [10, 5, 500],
          ]),
          ''));

      final first = await service.sample('ubuntu');
      expect(first.instanceCpuPercent, isNull);
      final second = await service.sample('ubuntu');
      expect(second.instanceCpuPercent, closeTo(25.0, 0.001));

      expect(backend.targets, ['ubuntu', 'ubuntu']);
      expect(backend.commands.first, VmStatsService.probeScript);
      expect(backend.timeouts.first, VmStatsService.probeTimeout);
    });

    test('each instance keeps a baseline of its own', () async {
      final backend =
          ScriptedBackend(runningInstances: const ['ubuntu', 'alpine']);
      final service = VmStatsService(backend);
      backend.answers.addAll([
        VmCommandOutput(0, probe(uptime: 100.0), ''),
        VmCommandOutput(0, probe(uptime: 100.0), ''),
        VmCommandOutput(
            0,
            probe(uptime: 102.0, processes: const [
              [250, 100, 1000],
              [10, 5, 500],
            ]),
            ''),
      ]);
      await service.sample('ubuntu');
      await service.sample('alpine');
      // The third answer is alpine's second reading, so it must be measured
      // against alpine's own first and not against ubuntu's.
      expect((await service.sample('alpine')).instanceCpuPercent,
          closeTo(25.0, 0.001));
    });

    test('forget() drops the baseline so a rate is not spanned over a stop',
        () async {
      final backend =
          ScriptedBackend(runningInstances: const ['ubuntu', 'alpine']);
      final service = VmStatsService(backend);
      backend.answers.addAll([
        VmCommandOutput(0, probe(uptime: 100.0), ''),
        VmCommandOutput(0, probe(uptime: 102.0), ''),
      ]);
      await service.sample('ubuntu');
      service.forget('ubuntu');
      expect((await service.sample('ubuntu')).instanceCpuPercent, isNull);
    });

    test('a guest that could not be reached says why', () async {
      final backend =
          ScriptedBackend(runningInstances: const ['ubuntu', 'alpine']);
      final service = VmStatsService(backend);
      backend.answers
          .add(const VmCommandOutput(1, '', 'There is no distribution.'));
      await expectLater(
          service.sample('ubuntu'),
          throwsA(predicate((error) =>
              error is VmStatsException &&
              error.message == 'There is no distribution.')));

      backend.answers.add(const VmCommandOutput(255, '', ''));
      await expectLater(
          service.sample('ubuntu'),
          throwsA(predicate((error) =>
              error is VmStatsException && error.message == 'exit 255')));
    });

    test('a failing exit code with a usable reading is still a reading',
        () async {
      // The script ends in `exit 0` for exactly this reason, but a transport
      // that reports its own non-zero status must not throw away output the
      // guest did produce.
      final backend =
          ScriptedBackend(runningInstances: const ['ubuntu', 'alpine']);
      final service = VmStatsService(backend);
      backend.answers.add(VmCommandOutput(1, probe(), 'awk: cannot open'));
      final usage = await service.sample('ubuntu');
      expect(usage.processCount, 2);
    });

    test('a stopped instance is refused rather than started to read it',
        () async {
      // `wsl.exe -d X --exec …` boots a stopped distro, so a probe is the one
      // thing that must not happen here.
      final backend = ScriptedBackend(runningInstances: const []);
      final service = VmStatsService(backend);
      backend.answers.add(VmCommandOutput(0, probe(), ''));
      await expectLater(service.sample('ubuntu'),
          throwsA(isA<VmStatsNotRunningException>()));
      expect(backend.commands, isEmpty);
      expect(backend.answers, hasLength(1));
    });

    test('an instance that stops mid-series loses its baseline', () async {
      final backend = ScriptedBackend(runningInstances: const ['ubuntu']);
      final service = VmStatsService(backend);
      backend.answers.addAll([
        VmCommandOutput(0, probe(uptime: 100.0), ''),
        VmCommandOutput(0, probe(uptime: 102.0), ''),
      ]);
      await service.sample('ubuntu');
      // Down and back up again: the counters restarted, so the reading after
      // it is a baseline and not a rate measured across the reboot.
      backend.runningInstances = const [];
      await expectLater(service.sample('ubuntu'),
          throwsA(isA<VmStatsNotRunningException>()));
      backend.runningInstances = const ['ubuntu'];
      expect((await service.sample('ubuntu')).instanceCpuPercent, isNull);
    });

    test('the not-running signal carries a key the dialog translates',
        () async {
      expect(const VmStatsNotRunningException().message,
          'vmresourcesnotrunning-text');
      expect(const VmStatsNotRunningException(), isA<VmStatsException>());
    });

    test('a backend that throws is reported, not propagated raw', () async {
      final backend =
          ScriptedBackend(runningInstances: const ['ubuntu', 'alpine']);
      backend.failure = StateError('helper is gone');
      await expectLater(VmStatsService(backend).sample('ubuntu'),
          throwsA(isA<VmStatsException>()));
    });
  });

  group('probeScript', () {
    /// The field offsets are the one part of the script that cannot be
    /// checked from Dart, and the one a well-meaning simplification breaks:
    /// `/proc/<pid>/stat`'s 14th, 15th and 24th columns are only at 12, 13
    /// and 22 once the comm field — which may itself contain `) ` — has been
    /// skipped by matching the *last* `)` on the line.
    test('skips the comm field and reads utime, stime and rss past it', () {
      expect(VmStatsService.probeScript, contains(r'match($0, /\)[^)]*$/)'));
      expect(VmStatsService.probeScript, contains(r'substr($0, RSTART + 2)'));
      expect(VmStatsService.probeScript,
          contains('print "P", f[12], f[13], f[22]'));
    });

    test('a guest that lost a process mid-read still exits clean', () {
      // Without the trailing `exit 0`, `awk` complaining about a path that
      // vanished would read as "the instance could not be reached".
      expect(VmStatsService.probeScript.trim(), endsWith('exit 0'));
    });

    test('everything is read in one command, so the rates share a clock', () {
      for (final source in const [
        '/proc/uptime',
        '/proc/meminfo',
        '/proc/stat',
        r'/proc/[0-9]*/stat',
      ]) {
        expect(VmStatsService.probeScript, contains(source));
      }
    });
  });
}
