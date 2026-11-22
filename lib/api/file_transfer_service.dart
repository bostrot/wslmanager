// Picking files out of one instance and putting them in another
// (bostrot/ai-tasks#92, upstream bostrot/wsl2-distro-manager#236).
//
// ## Why a browser and not "open the folder"
//
// The app already has a folder button, and the upstream report is what it
// looks like when that button is the whole answer: "when I click the folder
// button it's blank". It opens `\\wsl.localhost\<distro>` in Explorer, which
// is a Windows share served by WSL — it needs the distro running, it shows
// nothing at all on a stopped one, and on the Apple backend there is no share
// to open in the first place. So the one thing the reporter wanted to do
// before deleting an old distro — take a handful of files across to the new
// one — had no route through the app at all.
//
// This lists the guest's own filesystem through the backend that already runs
// commands inside it, which is the only surface that exists on every backend
// and does not care whether the host can mount anything.
//
// ## How the bytes actually move
//
// Two instances share no filesystem, so something has to carry the files.
// What carries them is a gzipped tar and a staging file on the host:
//
//   0. both instances are checked to be reachable, and started if they are
//      not (see [FileTransferService.ensureRunning] for why this comes
//      first rather than being discovered on the way),
//   1. the source packs the picked names into an archive,
//   2. the archive is brought to the host,
//   3. the host's copy is put inside the target,
//   4. the target unpacks it.
//
// Steps 2 and 3 have a fast path and a slow one. The fast path is
// `wslpath`: every WSL distro mounts the Windows drives, so the host's
// staging folder has a path *inside the guest*, and the archive can be
// written and read straight there — no copying, whatever its size. A guest
// without `wslpath`, or with automount switched off, falls back to moving the
// archive through the command channel in base64 chunks.
//
// The chunk sizes are not tunable decoration, they are the limits of that
// channel. A command reaches a local distro as a Windows command line, capped
// at 32767 characters, and a remote one as a base64 PowerShell payload that
// costs ~3.6 wire characters per byte and is capped at ~1.9 KB on a cmd.exe
// login shell (see `remote_command.dart`). Reading has no such cap — that
// half travels on stdout — so only the write leg is small.
//
// Nothing here interpolates a user-supplied string into a script unquoted:
// every path and every picked name goes through [shellQuote], and the names
// are checked for separators first, so "pick this file" can never become
// "pick this file and also run that".

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/provisioning.dart' show shellQuote;
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';

/// One entry of a guest directory listing.
class InstanceFileEntry {
  const InstanceFileEntry({
    required this.name,
    required this.isDirectory,
    this.isSymlink = false,
    this.sizeBytes = 0,
  });

  final String name;
  final bool isDirectory;

  /// Symlinks are shown but never followed by the listing itself; a link to a
  /// directory still navigates, because that is what the user means by
  /// clicking it, and `tar` resolves it the same way.
  final bool isSymlink;

  /// Size of the file, or 0 for a directory — a directory's own inode size
  /// says nothing about what is in it and only ever confused the row.
  final int sizeBytes;
}

/// Where a running transfer has got to.
enum TransferStage {
  /// An instance was not reachable and is being started.
  starting,

  /// The source is building the archive.
  packing,

  /// The archive is being brought to the host.
  reading,

  /// The host's copy is being put inside the target.
  writing,

  /// The target is unpacking it.
  unpacking,

  /// Everything landed.
  done,
}

/// One progress report. [bytesTotal] is 0 until the archive exists, because
/// until then there is nothing to be a fraction of.
class TransferStep {
  const TransferStep({
    required this.stage,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.instance = '',
  });

  final TransferStage stage;
  final int bytesDone;
  final int bytesTotal;

  /// Which instance the step is about. Only [TransferStage.starting] fills
  /// it: the rest of the stages are about the transfer, and naming an
  /// instance there would say the same thing the dialog's own fields already
  /// say. A start can be either end, so that one has to name which.
  final String instance;

  /// 0..1, or null while the total is unknown — what a progress bar needs to
  /// decide between a value and an indeterminate spin.
  double? get fraction =>
      bytesTotal <= 0 ? null : (bytesDone / bytesTotal).clamp(0.0, 1.0);
}

/// Listing a guest's filesystem and moving picked files to another guest.
/// See the file header for why it is written against [VmBackend].
class FileTransferService {
  FileTransferService({
    VmBackend? backend,
    Directory? stagingDirectory,
    int? readChunkBytes,
    int? writeChunkBytes,
    this.maxBytes = _defaultMaxBytes,
    this.probeTimeout = _defaultProbeTimeout,
    this.startTimeout = _defaultStartTimeout,
    this.startPollInterval = _defaultStartPoll,
  })  : backend = backend ?? vmBackend(),
        stagingDirectory = stagingDirectory ?? Directory.systemTemp,
        readChunkBytes = readChunkBytes ?? _defaultReadChunk,
        _writeChunkOverride = writeChunkBytes;

  final VmBackend backend;

  /// Where the archive rests between the two instances.
  final Directory stagingDirectory;

  final int readChunkBytes;

  final int? _writeChunkOverride;

  /// How much of the archive one write command may carry. A getter rather
  /// than a field because the default is the backend's own limit, and the
  /// backend is only known once the constructor has resolved it.
  ///
  /// Rounded to a multiple of three so every chunk's base64 is whole: the
  /// guest decodes each one on its own and appends the bytes, which only
  /// reconstructs the archive when no chunk ends mid-group.
  int get writeChunkBytes => _roundToTriple(_writeChunkOverride ??
      (backend.isRemote ? _remoteWriteChunk : _localWriteChunk));

  /// Refused above this, rather than started and abandoned hours later. A
  /// whole instance belongs in an export, not in a file picker.
  final int maxBytes;

  /// How long one "can I reach this instance" command may take. Deliberately
  /// far below [VmBackend.runInInstance]'s own five minutes: this question is
  /// asked about an instance that may well be off, and the answer "no" has to
  /// arrive while the user is still watching.
  final Duration probeTimeout;

  /// How long an instance gets to come up after being started. A stopped
  /// Apple VM boots a whole guest OS and waits for a DHCP lease, so this is
  /// minutes, not seconds.
  final Duration startTimeout;

  /// Gap between two probes while waiting for a start.
  final Duration startPollInterval;

  static const Duration _defaultProbeTimeout = Duration(seconds: 20);

  static const Duration _defaultStartTimeout = Duration(minutes: 3);

  static const Duration _defaultStartPoll = Duration(seconds: 2);

  /// stdout on a read leg is not capped, so this is only about how much text
  /// to hold at once.
  static const int _defaultReadChunk = 256 * 1024;

  /// A local command line is capped at 32767 characters; 16 KiB of payload is
  /// ~21.8 K of base64, leaving room for the script around it.
  static const int _localWriteChunk = 16 * 1024;

  /// A remote one is capped at roughly 1.9 KB of inline payload.
  static const int _remoteWriteChunk = 1024;

  static const int _defaultMaxBytes = 4 * 1024 * 1024 * 1024;

  /// Matches this feature's own staging archives, wherever they turn up.
  static const String _archiveGlob = 'wslmanager-transfer-*.tar.gz';

  /// Printed by the listing script when the directory could not be entered,
  /// which is not the same as an empty directory and must not read as one.
  static const String _noDirectoryMarker = '__wslm_nodir__';

  static int _roundToTriple(int bytes) {
    final rounded = bytes - (bytes % 3);
    return rounded < 3 ? 3 : rounded;
  }

  /// What [path] holds inside [instance], directories first.
  ///
  /// Throws a [WslFailure] when the directory could not be read — a caller
  /// showing an empty list for an unreadable path is the bug this feature
  /// exists to fix.
  Future<List<InstanceFileEntry>> list(String instance, String path) async {
    final script = '''
cd -- ${shellQuote(path)} 2>/dev/null || { printf %s $_noDirectoryMarker; exit 0; }
for e in .* *; do
  case "\$e" in .|..) continue;; esac
  [ -e "\$e" ] || [ -L "\$e" ] || continue
  t=f; [ -d "\$e" ] && t=d
  l=n; [ -L "\$e" ] && l=y
  s=\$(stat -c %s -- "\$e" 2>/dev/null) || s=0
  printf '%s\\t%s\\t%s\\t%s\\n' "\$t" "\$l" "\$s" "\$e"
done
exit 0''';

    final out = await backend.runInInstance(instance, script);
    if (!out.ok) {
      throw WslFailure(
          details: out.stderr.trim().isEmpty
              ? 'Could not list $path in $instance.'
              : out.stderr.trim());
    }
    // Matched whole, not searched for: the script prints the marker and
    // nothing else, so a file that happens to be called this is still a file.
    if (out.stdout.trim() == _noDirectoryMarker) {
      throw WslFailure(details: 'Could not open $path in $instance.');
    }

    final entries = <InstanceFileEntry>[];
    for (final line in const LineSplitter().convert(out.stdout)) {
      final fields = line.split('\t');
      if (fields.length < 4) continue;
      final name = fields.sublist(3).join('\t');
      if (name.isEmpty) continue;
      final isDirectory = fields[0] == 'd';
      entries.add(InstanceFileEntry(
        name: name,
        isDirectory: isDirectory,
        isSymlink: fields[1] == 'y',
        sizeBytes: isDirectory ? 0 : int.tryParse(fields[2].trim()) ?? 0,
      ));
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Where the browser should open: the default user's home, or `/` when the
  /// instance will not say.
  Future<String> homeDirectory(String instance) async {
    try {
      final user = (await backend.getDefaultUser(instance)).trim();
      final out = await backend.runInInstance(
          instance, 'cd ~ 2>/dev/null && pwd',
          user: user.isEmpty ? 'root' : user);
      final home = out.stdout.trim();
      if (out.ok && home.startsWith('/')) return home;
    } catch (_) {
      // A home directory is a convenience; the root of the filesystem is
      // always there and is never the wrong answer.
    }
    return '/';
  }

  /// Make sure [instance] can actually be reached, starting it when it cannot.
  ///
  /// This exists because of what the transfer used to do instead: the first
  /// thing it asked of the target was `mkdir -p`, at the *end* of the source
  /// leg. On a stopped Apple VM that fails with "no IP address yet (no DHCP
  /// lease)" — after the user has sat through the packing and the copy out,
  /// for an archive that is then thrown away. Anything that is going to
  /// refuse a transfer has to refuse it before that work, not after it.
  ///
  /// The reachability probe is the test, not [VmBackend.listRunning]: a WSL
  /// distro boots by itself the moment a command runs in it, so a distro that
  /// "is not running" is already fine and starting it explicitly would open a
  /// terminal window nobody asked for. Only an instance that a command cannot
  /// reach — which is what a stopped VM looks like — is started.
  ///
  /// [onStarting] fires only when a start is actually needed, so a caller can
  /// keep quiet in the common case where both ends are already up.
  Future<void> ensureRunning(
    String instance, {
    CancelSignal? cancel,
    void Function()? onStarting,
  }) async {
    _throwIfCancelled(cancel);
    if (await _reachable(instance)) return;
    _throwIfCancelled(cancel);
    onStarting?.call();
    try {
      await backend.start(instance);
    } catch (e) {
      throw WslFailure(
          details: 'Could not start $instance, so nothing was copied. '
                  '${friendlyErrorReason(e)}'
              .trim());
    }
    final deadline = DateTime.now().add(startTimeout);
    // At least one probe after the start, however short [startTimeout] is:
    // an instance that came up immediately must not be called too slow.
    while (true) {
      _throwIfCancelled(cancel);
      await Future<void>.delayed(startPollInterval);
      _throwIfCancelled(cancel);
      if (await _reachable(instance)) return;
      if (!DateTime.now().isBefore(deadline)) break;
    }
    throw WslFailure(
        details: '$instance did not come up in time, so nothing was copied. '
            'Start it yourself and try again.');
  }

  /// Whether a command runs inside [instance] at all. Every failure is the
  /// same answer here — unreachable is unreachable, whether the backend threw
  /// or the guest said no.
  Future<bool> _reachable(String instance) async {
    try {
      final out = await backend.runInInstance(instance, 'exit 0',
          timeout: probeTimeout);
      return out.ok;
    } catch (_) {
      return false;
    }
  }

  /// Copy [names] out of [sourceDirectory] in [sourceInstance] into
  /// [targetDirectory] in [targetInstance], and answer how many bytes of
  /// archive it took.
  ///
  /// [names] are entries of [sourceDirectory], not paths: a separator in one
  /// means the caller sent something the picker cannot have produced, and it
  /// is refused rather than quoted into the script.
  Future<int> transfer({
    required String sourceInstance,
    required String sourceDirectory,
    required List<String> names,
    required String targetInstance,
    required String targetDirectory,
    CancelSignal? cancel,
    void Function(TransferStep step)? onStep,
  }) async {
    if (names.isEmpty) {
      throw const WslFailure(details: 'Nothing was picked to transfer.');
    }
    for (final name in names) {
      if (name.isEmpty ||
          name == '.' ||
          name == '..' ||
          name.contains('/') ||
          name.contains('\n')) {
        throw WslFailure(details: 'Cannot transfer the entry "$name".');
      }
    }
    if (!sourceDirectory.startsWith('/') || !targetDirectory.startsWith('/')) {
      throw const WslFailure(
          details: 'Both folders have to be absolute paths inside the '
              'instances.');
    }
    if (sourceInstance == targetInstance &&
        p.posix.normalize(sourceDirectory) ==
            p.posix.normalize(targetDirectory)) {
      throw const WslFailure(
          details: 'The source and the destination are the same folder.');
    }

    // Both ends first, before a single byte is packed: see [ensureRunning].
    // The source is checked too — the dialog reaches it to list a folder, but
    // an instance can be stopped between opening the dialog and pressing the
    // button, and half a transfer is worse than a refused one.
    await ensureRunning(sourceInstance, cancel: cancel, onStarting: () {
      onStep?.call(TransferStep(
          stage: TransferStage.starting, instance: sourceInstance));
    });
    if (targetInstance != sourceInstance) {
      await ensureRunning(targetInstance, cancel: cancel, onStarting: () {
        onStep?.call(TransferStep(
            stage: TransferStage.starting, instance: targetInstance));
      });
    }
    _throwIfCancelled(cancel);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final archiveName = 'wslmanager-transfer-$stamp.tar.gz';
    final hostArchive = File(p.join(stagingDirectory.path, archiveName));
    final guestArchive = '/tmp/$archiveName';

    // Asked for before anything is built, so a guest that can reach the host
    // folder never pays for a chunked leg it does not need.
    final sourceBridge =
        await _bridgedPath(sourceInstance, requireWritable: true);
    final targetBridge =
        await _bridgedPath(targetInstance, requireWritable: false);
    final packInto =
        sourceBridge == null ? guestArchive : '$sourceBridge/$archiveName';

    try {
      onStep?.call(const TransferStep(stage: TransferStage.packing));
      await _run(
        sourceInstance,
        // The exclude is about the archive itself: picking a folder that
        // happens to contain /tmp would otherwise hand tar the file it is
        // still writing, and GNU tar fails the whole run over it. The glob
        // also skips whatever a crashed earlier run left behind.
        'tar -czf ${shellQuote(packInto)} '
            "--exclude='$_archiveGlob' "
            '-C ${shellQuote(sourceDirectory)} '
            '${names.map((n) => shellQuote('./$n')).join(' ')}',
        'Could not read the picked files from $sourceInstance.',
      );
      _throwIfCancelled(cancel);

      final int total;
      if (sourceBridge == null) {
        total = await _archiveSize(sourceInstance, guestArchive);
        _guardSize(total);
        await _download(sourceInstance, guestArchive, hostArchive, total,
            cancel: cancel, onStep: onStep);
      } else {
        // The source wrote it where the host can see it; there is nothing to
        // carry.
        total = hostArchive.existsSync() ? hostArchive.lengthSync() : 0;
        _guardSize(total);
        onStep?.call(TransferStep(
            stage: TransferStage.reading, bytesDone: total, bytesTotal: total));
      }
      if (total <= 0) {
        throw const WslFailure(details: 'The archive came out empty.');
      }
      _throwIfCancelled(cancel);

      await _run(
        targetInstance,
        'mkdir -p ${shellQuote(targetDirectory)}',
        'Could not create $targetDirectory in $targetInstance.',
      );

      final String unpackFrom;
      if (targetBridge == null) {
        await _upload(targetInstance, hostArchive, guestArchive, total,
            cancel: cancel, onStep: onStep);
        unpackFrom = guestArchive;
      } else {
        unpackFrom = '$targetBridge/$archiveName';
        onStep?.call(TransferStep(
            stage: TransferStage.writing, bytesDone: total, bytesTotal: total));
      }
      _throwIfCancelled(cancel);

      onStep?.call(TransferStep(
          stage: TransferStage.unpacking, bytesDone: total, bytesTotal: total));
      await _run(
        targetInstance,
        'tar -xzf ${shellQuote(unpackFrom)} -C ${shellQuote(targetDirectory)}',
        'Could not unpack the files in $targetInstance.',
      );

      onStep?.call(TransferStep(
          stage: TransferStage.done, bytesDone: total, bytesTotal: total));
      return total;
    } finally {
      // Best effort on every route out, including the cancelled one: a
      // half-written archive in /tmp is invisible and stays until a reboot.
      await _cleanUp(sourceInstance, sourceBridge == null ? guestArchive : '');
      await _cleanUp(targetInstance, targetBridge == null ? guestArchive : '');
      try {
        if (hostArchive.existsSync()) hostArchive.deleteSync();
      } catch (_) {}
    }
  }

  /// [stagingDirectory] as [instance] sees it, or null when it cannot see it.
  ///
  /// `wslpath` is the question and the answer both: a guest that has it is a
  /// WSL distro, and a WSL distro with automount switched off answers with a
  /// path that is not there — which the `-d` test catches.
  Future<String?> _bridgedPath(String instance,
      {required bool requireWritable}) async {
    // A remote backend's guests mount the *remote* host's drives, not this
    // machine's. Asking anyway is worse than not asking: an app running on
    // Linux stages in `/tmp`, every distro has a `/tmp`, and the guest would
    // answer yes about a folder this side has never seen.
    if (backend.isRemote) return null;
    final host = stagingDirectory.path;
    final writable = requireWritable ? '[ -w "\$p" ] || exit 9\n' : '';
    try {
      final out = await backend.runInInstance(instance, '''
command -v wslpath >/dev/null 2>&1 || exit 9
p=\$(wslpath -u ${shellQuote(host)} 2>/dev/null) || exit 9
[ -n "\$p" ] || exit 9
[ -d "\$p" ] || exit 9
${writable}printf %s "\$p"''');
      if (!out.ok) return null;
      final path = out.stdout.trim();
      return path.startsWith('/') ? path : null;
    } catch (_) {
      return null;
    }
  }

  Future<int> _archiveSize(String instance, String path) async {
    final out = await _run(
      instance,
      'stat -c %s -- ${shellQuote(path)}',
      'Could not measure the archive in $instance.',
    );
    return int.tryParse(out.stdout.trim()) ?? 0;
  }

  void _guardSize(int bytes) {
    if (bytes > maxBytes) {
      throw WslFailure(
          details: 'That is ${_megabytes(bytes)} MB of files. Move a whole '
              'instance with Backup instead.');
    }
  }

  static String _megabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(0);

  /// Bring the guest's archive to [hostFile], one stdout-sized bite at a time.
  Future<void> _download(
    String instance,
    String guestPath,
    File hostFile,
    int total, {
    CancelSignal? cancel,
    void Function(TransferStep step)? onStep,
  }) async {
    final sink = hostFile.openSync(mode: FileMode.write);
    try {
      var done = 0;
      var block = 0;
      while (done < total) {
        _throwIfCancelled(cancel);
        onStep?.call(TransferStep(
            stage: TransferStage.reading, bytesDone: done, bytesTotal: total));
        final out = await _run(
          instance,
          'dd if=${shellQuote(guestPath)} bs=$readChunkBytes skip=$block '
              'count=1 2>/dev/null | base64',
          'Could not read the archive from $instance.',
        );
        final bytes = base64.decode(_compact(out.stdout));
        if (bytes.isEmpty) {
          throw WslFailure(details: 'The archive stopped short in $instance.');
        }
        sink.writeFromSync(bytes);
        done += bytes.length;
        block++;
      }
      onStep?.call(TransferStep(
          stage: TransferStage.reading, bytesDone: total, bytesTotal: total));
    } finally {
      sink.closeSync();
    }
  }

  /// Put [hostFile] inside the guest at [guestPath], one command-line-sized
  /// bite at a time. The first chunk truncates, the rest append.
  Future<void> _upload(
    String instance,
    File hostFile,
    String guestPath,
    int total, {
    CancelSignal? cancel,
    void Function(TransferStep step)? onStep,
  }) async {
    final handle = hostFile.openSync();
    try {
      var done = 0;
      var first = true;
      while (done < total) {
        _throwIfCancelled(cancel);
        onStep?.call(TransferStep(
            stage: TransferStage.writing, bytesDone: done, bytesTotal: total));
        final chunk = handle.readSync(writeChunkBytes);
        if (chunk.isEmpty) break;
        await _run(
          instance,
          "printf %s '${base64.encode(chunk)}' | base64 -d "
              '${first ? '>' : '>>'} ${shellQuote(guestPath)}',
          'Could not write the files into $instance.',
        );
        first = false;
        done += chunk.length;
      }
      onStep?.call(TransferStep(
          stage: TransferStage.writing, bytesDone: total, bytesTotal: total));
    } finally {
      handle.closeSync();
    }
  }

  Future<void> _cleanUp(String instance, String path) async {
    if (path.isEmpty) return;
    try {
      await backend.runInInstance(instance, 'rm -f ${shellQuote(path)}');
    } catch (_) {}
  }

  Future<VmCommandOutput> _run(
      String instance, String command, String failure) async {
    final VmCommandOutput out;
    try {
      out = await backend.runInInstance(instance, command);
    } catch (e) {
      throw WslFailure(details: '$failure ${friendlyErrorReason(e)}'.trim());
    }
    if (!out.ok) {
      final detail = out.stderr.trim();
      throw WslFailure(details: detail.isEmpty ? failure : '$failure $detail');
    }
    return out;
  }

  void _throwIfCancelled(CancelSignal? cancel) {
    if (cancel?.isCancelled ?? false) {
      throw const WslFailure(details: 'The transfer was stopped.');
    }
  }

  /// base64 the guest printed, with the line breaks its `base64` added — the
  /// width differs between coreutils and busybox, so none of it is assumed.
  static String _compact(String raw) => raw.replaceAll(RegExp(r'\s'), '');
}
