// Changing a VM's CPU count, memory and disk size after it was created
// (bostrot/ai-tasks#103).
//
// The Apple backend chose all three exactly once — on the create page — and
// offered no way back. A WSL distro has had `--manage --resize` behind the
// disk dialog for a while; a Mac VM that ran out of its 32 GB had to be
// thrown away and rebuilt.
//
// This is the app side of `vmctl resize`, which holds the rules that matter:
// the VM has to be stopped, the disk can only grow, and everything takes
// effect on the next start. The service keeps the same shape as
// [VolumeMountService] — it drives the helper through the backend's public
// surface rather than reaching into it — so nothing here is specific to how
// `AppleVmApi` talks to vmctl beyond the helper path and store it exposes.

import 'dart:convert';
import 'dart:io';

import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';

const int _bytesPerGb = 1024 * 1024 * 1024;

/// Bytes as whole gigabytes, rounded up: a 32 GB disk whose image is a
/// handful of bytes short still reads as 32 in the box the user edits.
int gigabytesOf(int bytes) => bytes <= 0 ? 0 : (bytes + _bytesPerGb - 1) ~/ _bytesPerGb;

/// What a VM is made of right now.
class VmResources {
  final String name;

  /// `linux` or `macos`.
  final String os;
  final bool running;
  final int cpus;
  final int memoryBytes;
  final int diskSizeBytes;

  const VmResources({
    required this.name,
    required this.os,
    required this.running,
    required this.cpus,
    required this.memoryBytes,
    required this.diskSizeBytes,
  });

  int get memoryGb => gigabytesOf(memoryBytes);
  int get diskGb => gigabytesOf(diskSizeBytes);

  /// Whether this guest grows its own root filesystem once the image is
  /// bigger. Only a Linux guest does, through cloud-init's growpart; the
  /// helper has the last word (it can see whether the VM has a seed at all)
  /// and says so in [VmResizeResult.guestGrowsFilesystem].
  bool get guestMayGrowItself => os == 'linux';
}

/// What changed, as the helper reported it.
class VmResizeResult {
  final int cpus;
  final int memoryBytes;
  final int diskSizeBytes;

  /// The image got bigger — so somebody, guest or user, has to grow the
  /// filesystem inside it.
  final bool diskGrew;

  /// The guest does that by itself on its next boot.
  final bool guestGrowsFilesystem;

  const VmResizeResult({
    required this.cpus,
    required this.memoryBytes,
    required this.diskSizeBytes,
    required this.diskGrew,
    required this.guestGrowsFilesystem,
  });

  /// True when the user has to grow the guest's own filesystem by hand.
  bool get needsGuestAction => diskGrew && !guestGrowsFilesystem;
}

/// A resize that could not be done; [message] is an i18n key when the reason
/// is one this app knows, and the helper's own text otherwise.
class VmResizeException implements Exception {
  final String message;
  const VmResizeException(this.message);

  @override
  String toString() => message;
}

/// The i18n key describing what is wrong with resizing [current] to the given
/// numbers, or null when the request is acceptable.
///
/// These are the checks worth making before a process is started — the ones
/// whose answer is already here. Whether this Mac can actually give a guest
/// 12 CPUs is Virtualization.framework's to say, and the helper passes its
/// refusal straight through.
String? validateVmResize({
  required VmResources current,
  required int cpus,
  required int memoryGb,
  required int diskGb,
}) {
  if (current.running) return 'vmresizerunning-text';
  if (cpus < 1 || memoryGb < 1 || diskGb < 1) return 'vmresizepositive-text';
  // A raw disk image carries the guest's partition table and filesystem;
  // truncating it shorter cuts through whatever sits at the end.
  if (diskGb < current.diskGb) return 'vmresizeshrink-text';
  if (cpus == current.cpus &&
      memoryGb == current.memoryGb &&
      diskGb == current.diskGb) {
    return 'vmresizenochange-text';
  }
  return null;
}

/// The same refusals as plain English, for callers with no user in front of
/// them — the MCP tools, whose every other description and result is English
/// too. The UI reads [validateVmResize]'s key out of `lib/i18n` instead.
const Map<String, String> vmResizeProblemSummaries = {
  'vmresizerunning-text':
      'The VM is running; stop it first. Its hardware is fixed while it runs.',
  'vmresizepositive-text': 'Sizes must be whole numbers greater than zero.',
  'vmresizeshrink-text': 'A disk can only grow. Shrinking a raw disk image '
      "would cut through the guest's own partitions.",
  'vmresizenochange-text': 'These are the values the VM already has; pass a '
      'cpus, memory_gb or disk_gb that differs.',
  'vmresizeunknown-text': 'No VM by that name.',
};

/// Reads and changes a VM's hardware through `vmctl`.
class VmResizeService {
  final AppleVmApi api;

  VmResizeService(this.api);

  /// Whether [api] is a backend this service knows how to drive. WSL keeps
  /// its own sizing behind the disk dialog (`wsl --manage --resize`), which
  /// works on a *running* distro and has nothing in common with this.
  static bool isSupported(VmBackend api) => api is AppleVmApi;

  Future<Map<String, dynamic>> _run(List<String> args) async {
    final ProcessResult result;
    try {
      result = await api.shell.run(
        api.helperPath(),
        ['--store', api.storeDir, ...args],
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException catch (e) {
      throw VmResizeException(
          'Could not run the vmctl helper (${api.helperPath()}): ${e.message}');
    }
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw VmResizeException(stderr.isNotEmpty
          ? stderr
          : 'vmctl ${args.join(' ')} failed with exit code ${result.exitCode}');
    }
    final stdout = result.stdout.toString();
    try {
      final decoded = json.decode(stdout.trim().isEmpty ? '{}' : stdout);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // Fall through to the same complaint an unusable shape gets.
    }
    throw VmResizeException('vmctl returned unreadable output: $stdout');
  }

  /// What [instance] is made of, or a [VmResizeException] when the backend
  /// has never heard of it.
  Future<VmResources> read(String instance) async {
    final AppleVmInfo? vm;
    try {
      vm = await api.vmInfo(instance);
    } on AppleVmException catch (error) {
      throw VmResizeException(error.toString());
    }
    if (vm == null) throw const VmResizeException('vmresizeunknown-text');
    return VmResources(
      name: vm.name,
      os: vm.os,
      running: vm.running,
      cpus: vm.cpus,
      memoryBytes: vm.memoryBytes,
      // The list reports the image's own length, which is what the guest
      // will see; the config's number only matters until the next start.
      diskSizeBytes: vm.diskSizeBytes,
    );
  }

  /// Applies the numbers the user typed. Only what actually differs is sent,
  /// so a resize that touches memory alone never mentions the disk.
  Future<VmResizeResult> apply(
    String instance, {
    required int cpus,
    required int memoryGb,
    required int diskGb,
  }) async {
    final current = await read(instance);
    final problem = validateVmResize(
        current: current, cpus: cpus, memoryGb: memoryGb, diskGb: diskGb);
    if (problem != null) throw VmResizeException(problem);

    final args = <String>['resize', '--name', instance];
    if (cpus != current.cpus) args.addAll(['--cpus', '$cpus']);
    if (memoryGb != current.memoryGb) args.addAll(['--memory', '$memoryGb']);
    final diskGrew = diskGb != current.diskGb;
    if (diskGrew) args.addAll(['--disk-size', '$diskGb']);

    final json = await _run(args);
    return VmResizeResult(
      cpus: (json['cpus'] as num?)?.toInt() ?? cpus,
      memoryBytes:
          (json['memoryBytes'] as num?)?.toInt() ?? memoryGb * _bytesPerGb,
      diskSizeBytes:
          (json['diskSizeBytes'] as num?)?.toInt() ?? diskGb * _bytesPerGb,
      diskGrew: diskGrew,
      // Absent means a helper that predates this report; assume the guest
      // needs a hand rather than promising something that will not happen.
      guestGrowsFilesystem: json['guestGrowsFilesystem'] == true,
    );
  }
}
