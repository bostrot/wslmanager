// What an instance is actually using right now — CPU, memory, swap
// (bostrot/ai-tasks#109).
//
// The app could already say how much *disk* an instance took: a number
// `wsl.exe` or the VM's image file hands over without asking anyone. Live
// usage has no such source. `wsl.exe` has no `--stats`, `vmctl` reports the
// machine it configured rather than the load inside it, and the host's own
// task manager sees one `vmmem`/`virtiofsd` process covering every instance
// at once. The only place the answer exists is inside the guest, so that is
// where this reads it: `/proc`, over the one call every backend implements
// ([VmBackend.runInInstance]), which makes the same figures work for a WSL
// distro and an Apple VM without either backend growing a method.
//
// Two numbers are worth telling apart, because on WSL they are not the same
// thing at all. Every WSL2 distro shares one virtual machine and one kernel,
// so `/proc/meminfo` and `/proc/stat` describe *the VM* — what the distro the
// user is looking at contributes to that is invisible in them. Summing the
// instance's own processes is what separates the two: those live in the
// distro's PID namespace, so `/proc/[0-9]*/stat` inside it lists exactly the
// processes that belong to it and nothing from its neighbours. Both figures
// are reported and the UI labels them, rather than picking one and being
// quietly wrong about the other on whichever backend.
//
// CPU is a rate, so a single reading cannot answer it: the first sample only
// establishes a baseline and the percentages arrive with the second. The
// elapsed time between them comes from the guest's own `/proc/uptime` and not
// from the host clock, because a laptop that suspends between two samples
// would otherwise report hours of wall time against seconds of CPU.

import 'package:wsl2distromanager/api/vm/vm_backend.dart';

/// Usage figures that could not be read; [message] is what stood in the way.
class VmStatsException implements Exception {
  final String message;
  const VmStatsException(this.message);

  @override
  String toString() => message;
}

/// Thrown instead of probing an instance that is not running.
///
/// Its own type because it is not a failure: there is simply nothing to read,
/// and the caller should say so and stop asking rather than show an error.
class VmStatsNotRunningException extends VmStatsException {
  const VmStatsNotRunningException() : super('vmresourcesnotrunning-text');
}

/// One raw reading of a guest's `/proc`, before any rate is worked out.
///
/// Counters only — CPU ticks, byte totals, the guest's uptime. Everything a
/// user sees is derived from a pair of these by [deriveVmUsage].
class VmResourceSnapshot {
  /// Processors the guest can see, which is what a percentage of "all the
  /// CPU there is" has to be divided by.
  final int cpuCount;

  /// `USER_HZ`: how many of the ticks below make up a second.
  final int clockTicks;

  /// Seconds since the guest booted, from `/proc/uptime`. Monotonic inside
  /// the guest, which is what makes it a safe clock for a rate.
  final double uptimeSeconds;

  /// `utime + stime` summed over every process in the instance, in ticks.
  final int instanceCpuTicks;

  /// Resident memory summed over the same processes.
  ///
  /// Shared pages are counted once per process that maps them, so this is an
  /// upper bound on the instance's footprint rather than an exact figure —
  /// the same approximation `ps` and every process list makes.
  final int instanceResidentBytes;

  /// How many processes those two sums cover.
  final int processCount;

  final int memTotalBytes;

  /// Memory the kernel thinks is available for new work. Falls back to
  /// `MemFree` on a kernel too old to publish `MemAvailable` (pre-3.14).
  final int memAvailableBytes;

  final int swapTotalBytes;
  final int swapFreeBytes;

  /// Busy and total CPU ticks for the whole guest, from `/proc/stat`.
  final int guestCpuBusyTicks;
  final int guestCpuTotalTicks;

  const VmResourceSnapshot({
    required this.cpuCount,
    required this.clockTicks,
    required this.uptimeSeconds,
    required this.instanceCpuTicks,
    required this.instanceResidentBytes,
    required this.processCount,
    required this.memTotalBytes,
    required this.memAvailableBytes,
    required this.swapTotalBytes,
    required this.swapFreeBytes,
    required this.guestCpuBusyTicks,
    required this.guestCpuTotalTicks,
  });
}

/// What the UI shows: totals as read, rates worked out over a pair of
/// snapshots.
class VmResourceUsage {
  /// Share of the guest's total CPU capacity spent by this instance's own
  /// processes, or null on the first reading — a rate needs two.
  final double? instanceCpuPercent;

  /// Share of that capacity busy across the whole guest. On WSL that is
  /// every distro plus the VM's own kernel work; on a VM of its own it is
  /// the machine's load.
  final double? guestCpuPercent;

  /// Resident memory of the instance's processes. See
  /// [VmResourceSnapshot.instanceResidentBytes] for what that counts.
  final int instanceMemoryBytes;

  /// Memory in use across the guest, and how much there is in total.
  final int memoryUsedBytes;
  final int memoryTotalBytes;

  final int swapUsedBytes;
  final int swapTotalBytes;

  final int processCount;
  final int cpuCount;

  const VmResourceUsage({
    required this.instanceCpuPercent,
    required this.guestCpuPercent,
    required this.instanceMemoryBytes,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.swapUsedBytes,
    required this.swapTotalBytes,
    required this.processCount,
    required this.cpuCount,
  });

  /// [instanceMemoryBytes] as a share of the guest's memory, 0–100. Zero
  /// when the total is unknown, so a graph never divides by it.
  double get instanceMemoryPercent => memoryTotalBytes <= 0
      ? 0
      : (instanceMemoryBytes * 100 / memoryTotalBytes).clamp(0, 100).toDouble();

  /// [memoryUsedBytes] as a share of the same, 0–100.
  double get memoryUsedPercent => memoryTotalBytes <= 0
      ? 0
      : (memoryUsedBytes * 100 / memoryTotalBytes).clamp(0, 100).toDouble();
}

/// Reads [VmResourceSnapshot]s out of a guest and turns consecutive ones into
/// [VmResourceUsage].
///
/// One service per screen: the previous snapshot per instance is the state
/// that makes a CPU percentage possible, so a caller that throws the service
/// away between samples gets a baseline every time and never a rate.
class VmStatsService {
  VmStatsService(this.backend);

  final VmBackend backend;

  /// The last reading per instance, kept to work the rates out against.
  final Map<String, VmResourceSnapshot> _previous = {};

  /// A sample has to come back well inside the poll interval; a guest that
  /// needs longer than this for four `/proc` reads is not going to give a
  /// useful reading anyway.
  static const Duration probeTimeout = Duration(seconds: 20);

  /// The whole reading in one command, because a second round trip is a
  /// second point in time and the rates would be worked out across a gap
  /// nothing measured.
  ///
  /// `awk`'s `match($0, /\)[^)]*$/)` finds the *last* `)` in a
  /// `/proc/<pid>/stat` line, which is the only safe way to skip the comm
  /// field: a process is free to call itself `(evil) 1 2 3`, and splitting on
  /// the first `)` would read its name as its CPU time. The fields after it
  /// are `state ppid …`, so the line's 14th, 15th and 24th columns — utime,
  /// stime, rss — land at 12, 13 and 22.
  ///
  /// `exit 0` last: a process that exits while `awk` is walking the glob
  /// leaves an unreadable path behind and `awk` reports it, which would
  /// otherwise read as "the instance could not be reached" for a completely
  /// healthy guest. Whether the output is usable is decided by parsing it.
  static const String probeScript = r'''
echo "CPUS $(nproc 2>/dev/null || echo 1)"
echo "TICK $(getconf CLK_TCK 2>/dev/null || echo 100)"
echo "PAGE $(getconf PAGESIZE 2>/dev/null || echo 4096)"
echo "UP $(cut -d' ' -f1 /proc/uptime)"
grep -E '^(MemTotal|MemAvailable|MemFree|SwapTotal|SwapFree):' /proc/meminfo
head -n 1 /proc/stat
awk 'match($0, /\)[^)]*$/) { s = substr($0, RSTART + 2); split(s, f, " "); print "P", f[12], f[13], f[22] }' /proc/[0-9]*/stat 2>/dev/null
exit 0
''';

  /// Read [instance] once and report what it is using.
  ///
  /// Throws [VmStatsNotRunningException] when the instance is stopped and
  /// [VmStatsException] when a running one could not be read.
  ///
  /// The running check comes first and is asked of the backend rather than
  /// taken on trust, because reading `/proc` means running a command inside
  /// the instance and `wsl.exe` *starts* a stopped distro to do it. An
  /// instance that goes down while the monitor is open — a `wsl --shutdown`,
  /// an idle timeout, a guest that crashed — would otherwise be booted again
  /// by the very poll watching it.
  Future<VmResourceUsage> sample(String instance) async {
    final List<String> running;
    try {
      running = await backend.listRunning();
    } catch (error) {
      throw VmStatsException('$error');
    }
    if (!running.contains(instance)) {
      // Its counters restart from zero on the next boot, so the baseline is
      // no longer something a rate can be measured against.
      _previous.remove(instance);
      throw const VmStatsNotRunningException();
    }

    final VmCommandOutput result;
    try {
      result = await backend.runInInstance(instance, probeScript,
          timeout: probeTimeout);
    } catch (error) {
      throw VmStatsException('$error');
    }
    if (!result.ok && result.stdout.trim().isEmpty) {
      throw VmStatsException(result.stderr.trim().isEmpty
          ? 'exit ${result.exitCode}'
          : result.stderr.trim());
    }
    final snapshot = parseVmResourceProbe(result.stdout);
    final usage = deriveVmUsage(snapshot, _previous[instance]);
    _previous[instance] = snapshot;
    return usage;
  }

  /// Drop [instance]'s baseline, so the next [sample] starts a fresh series.
  /// Used when an instance stops: its counters restart at zero on the next
  /// boot, and a delta across that boundary is meaningless.
  void forget(String instance) => _previous.remove(instance);
}

/// The `kB` values `/proc/meminfo` reports are kibibytes, whatever the label
/// says.
const int _meminfoUnit = 1024;

/// Column [index] of [parts], or '' when the line is shorter than that.
String _field(List<String> parts, int index) =>
    index < parts.length ? parts[index] : '';

int? _kbLine(Map<String, int> meminfo, String key) {
  final value = meminfo[key];
  return value == null ? null : value * _meminfoUnit;
}

/// Parse the output of [VmStatsService.probeScript].
///
/// Throws [VmStatsException] when the text is not a reading at all — an empty
/// answer, or a guest with no `/proc` to read. Missing *optional* lines (no
/// swap configured, a kernel without `MemAvailable`) are filled in instead,
/// because those are ordinary guests and refusing them would leave the user
/// with an error where a number belongs.
VmResourceSnapshot parseVmResourceProbe(String output) {
  var cpuCount = 0;
  var clockTicks = 0;
  var pageSize = 0;
  double? uptime;
  final meminfo = <String, int>{};
  var cpuTicks = 0;
  var residentPages = 0;
  var processes = 0;
  var guestBusy = 0;
  var guestTotal = 0;

  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    final tag = parts.first;
    if (tag == 'CPUS') {
      cpuCount = int.tryParse(_field(parts, 1)) ?? 0;
    } else if (tag == 'TICK') {
      clockTicks = int.tryParse(_field(parts, 1)) ?? 0;
    } else if (tag == 'PAGE') {
      pageSize = int.tryParse(_field(parts, 1)) ?? 0;
    } else if (tag == 'UP') {
      uptime = double.tryParse(_field(parts, 1));
    } else if (tag == 'cpu') {
      // `cpu  user nice system idle iowait irq softirq steal …`. Idle and
      // iowait are the two the machine was not working; everything else
      // counts as busy — including `steal`, which is the host taking the CPU
      // away and is very much time the guest did not get to use.
      for (var i = 1; i < parts.length; i++) {
        final value = int.tryParse(parts[i]);
        if (value == null) continue;
        guestTotal += value;
        if (i != 4 && i != 5) guestBusy += value;
      }
    } else if (tag == 'P') {
      // A line that lost a field to a process exiting mid-read is still a
      // process; counting it and adding what it did report beats dropping it.
      processes++;
      cpuTicks += (int.tryParse(_field(parts, 1)) ?? 0) +
          (int.tryParse(_field(parts, 2)) ?? 0);
      residentPages += int.tryParse(_field(parts, 3)) ?? 0;
    } else if (tag.endsWith(':') && parts.length >= 2) {
      // `MemTotal:  8123456 kB` and friends.
      final value = int.tryParse(parts[1]);
      if (value != null) {
        meminfo[tag.substring(0, tag.length - 1)] = value;
      }
    }
  }

  final memTotal = _kbLine(meminfo, 'MemTotal');
  if (uptime == null || memTotal == null) {
    throw const VmStatsException('vmresourcesnoproc-text');
  }

  return VmResourceSnapshot(
    // A guest that cannot count its own processors still has at least one,
    // and a zero here would divide a percentage by nothing.
    cpuCount: cpuCount > 0 ? cpuCount : 1,
    clockTicks: clockTicks > 0 ? clockTicks : 100,
    uptimeSeconds: uptime,
    instanceCpuTicks: cpuTicks,
    instanceResidentBytes: residentPages * (pageSize > 0 ? pageSize : 4096),
    processCount: processes,
    memTotalBytes: memTotal,
    memAvailableBytes:
        _kbLine(meminfo, 'MemAvailable') ?? _kbLine(meminfo, 'MemFree') ?? 0,
    swapTotalBytes: _kbLine(meminfo, 'SwapTotal') ?? 0,
    swapFreeBytes: _kbLine(meminfo, 'SwapFree') ?? 0,
    guestCpuBusyTicks: guestBusy,
    guestCpuTotalTicks: guestTotal,
  );
}

/// Turn [now] — and [previous], when there is one — into displayable figures.
///
/// The percentages are null without a usable pair: no previous reading, no
/// time between them, or counters that went backwards, which is what a
/// rebooted guest looks like from here.
VmResourceUsage deriveVmUsage(
    VmResourceSnapshot now, VmResourceSnapshot? previous) {
  double? instanceCpu;
  double? guestCpu;

  if (previous != null) {
    final elapsed = now.uptimeSeconds - previous.uptimeSeconds;
    if (elapsed > 0) {
      final ticks = now.instanceCpuTicks - previous.instanceCpuTicks;
      if (ticks >= 0) {
        final seconds = ticks / now.clockTicks;
        instanceCpu = (seconds * 100 / (elapsed * now.cpuCount))
            .clamp(0, 100)
            .toDouble();
      }
    }
    final totalDelta = now.guestCpuTotalTicks - previous.guestCpuTotalTicks;
    final busyDelta = now.guestCpuBusyTicks - previous.guestCpuBusyTicks;
    if (totalDelta > 0 && busyDelta >= 0) {
      guestCpu = (busyDelta * 100 / totalDelta).clamp(0, 100).toDouble();
    }
  }

  // `MemAvailable` can exceed `MemTotal` on a guest with a ballooning
  // driver; the subtraction must not come out negative.
  final used =
      (now.memTotalBytes - now.memAvailableBytes).clamp(0, now.memTotalBytes);

  return VmResourceUsage(
    instanceCpuPercent: instanceCpu,
    guestCpuPercent: guestCpu,
    instanceMemoryBytes: now.instanceResidentBytes,
    memoryUsedBytes: used,
    memoryTotalBytes: now.memTotalBytes,
    swapUsedBytes:
        (now.swapTotalBytes - now.swapFreeBytes).clamp(0, now.swapTotalBytes),
    swapTotalBytes: now.swapTotalBytes,
    processCount: now.processCount,
    cpuCount: now.cpuCount,
  );
}
