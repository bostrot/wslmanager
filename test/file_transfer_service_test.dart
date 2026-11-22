/// Browsing one instance and copying picked files into another
/// (bostrot/ai-tasks#92, upstream bostrot/wsl2-distro-manager#236).
///
/// The fake below is not a recording of commands: it runs them against two
/// in-memory filesystems, so the chunked route is asserted on the bytes that
/// came out the other end rather than on the scripts that moved them. A
/// chunk boundary that split a base64 group would round-trip garbage and no
/// amount of script matching would notice.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/file_transfer_service.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';

import 'fake_provisioning_backend.dart';

/// Two guests with a filesystem each, driven by the same shell scripts the
/// service writes.
class _FakeGuests extends ScriptedBackend {
  _FakeGuests({required this.hostDirectory})
      : super(instances: const ['old', 'new']);

  /// The host folder the service stages through, and the path the guests in
  /// [bridged] see it at.
  final String hostDirectory;
  static const String bridgeMount = '/mnt/host';

  /// Whether the backend is driving another machine.
  bool remote = false;

  @override
  bool get isRemote => remote;

  /// Instances whose `wslpath` answers — i.e. that can reach the host folder
  /// without the archive being carried command by command.
  final Set<String> bridged = <String>{};

  /// Instance name to its files.
  final Map<String, Map<String, Uint8List>> disks = {
    'old': <String, Uint8List>{},
    'new': <String, Uint8List>{},
  };

  /// What a `tar -czf` of these names produces, keyed by the instance it ran
  /// in; the test seeds it so the bytes are recognisable on arrival.
  final Map<String, Uint8List> packs = {};

  /// Where `tar -xzf` unpacked, and what it unpacked.
  final List<String> unpackedInto = [];
  final List<Uint8List> unpacked = [];

  /// Every command, so the route taken can be asserted as well as the bytes.
  List<String> get seen => commands;

  /// Instances no command can reach — a stopped VM. [start] takes one out of
  /// the set once [bootProbes] further probes have failed, which is what a
  /// guest that needs a moment to come up looks like from outside.
  final Set<String> stopped = <String>{};

  /// How many probes after a start still fail before the instance answers.
  int bootProbes = 0;

  /// Instances [start] was called on, in order.
  final List<String> started = [];

  /// Instances [start] refuses to start.
  final Set<String> refuseStart = <String>{};

  /// How many archives had been packed each time [start] was called. The
  /// whole point of starting up front is that this is always zero.
  final List<int> packsBeforeStart = [];

  /// Runs before every command is answered, so a test can cancel or break
  /// something partway through a transfer.
  void Function(String command)? onCommand;

  final Map<String, int> _probesLeft = {};

  @override
  Future<void> start(String distribution,
      {String startPath = '',
      String startUser = '',
      String startCmd = ''}) async {
    started.add(distribution);
    packsBeforeStart
        .add(commands.where((c) => c.startsWith('tar -czf')).length);
    if (refuseStart.contains(distribution)) {
      throw const WslFailure(details: 'the hypervisor refused');
    }
    _probesLeft[distribution] = bootProbes;
  }

  /// The reachability probe, answered the way a stopped Apple VM answers it.
  VmCommandOutput _probe(String instance) {
    if (!stopped.contains(instance)) return const VmCommandOutput(0, '', '');
    final left = _probesLeft[instance];
    if (left == null) {
      return VmCommandOutput(
          255, '', 'VM $instance has no IP address yet (no DHCP lease).');
    }
    if (left <= 0) {
      stopped.remove(instance);
      return const VmCommandOutput(0, '', '');
    }
    _probesLeft[instance] = left - 1;
    return VmCommandOutput(
        255, '', 'VM $instance has no IP address yet (no DHCP lease).');
  }

  /// A guest path that lives in the host folder instead of the guest's disk.
  String? _hostFile(String path) => path.startsWith('$bridgeMount/')
      ? '$hostDirectory/${path.substring(bridgeMount.length + 1)}'
      : null;

  Uint8List? _read(String instance, String path) {
    final host = _hostFile(path);
    if (host != null) {
      final file = File(host);
      return file.existsSync() ? file.readAsBytesSync() : null;
    }
    return disks[instance]![path];
  }

  void _write(String instance, String path, Uint8List bytes) {
    final host = _hostFile(path);
    if (host != null) {
      File(host).writeAsBytesSync(bytes);
      return;
    }
    disks[instance]![path] = bytes;
  }

  @override
  Future<VmCommandOutput> runInInstance(
    String instance,
    String command, {
    String user = 'root',
    String cwd = '',
    Duration timeout = const Duration(minutes: 5),
  }) async {
    commands.add(command);
    targets.add(instance);
    onCommand?.call(command);

    // Answered before [failure], because an unreachable instance is exactly
    // what a transfer has to notice before it does anything else.
    if (command == 'exit 0') return _probe(instance);

    if (failure != null) throw failure!;

    if (command.contains('command -v wslpath')) {
      return bridged.contains(instance)
          ? const VmCommandOutput(0, bridgeMount, '')
          : const VmCommandOutput(9, '', '');
    }

    final pack = RegExp(
      r"tar -czf '([^']+)' --exclude='([^']+)' -C '([^']+)' (.*)",
    ).firstMatch(command);
    if (pack != null) {
      _write(instance, pack.group(1)!, packs[instance] ?? Uint8List(0));
      return const VmCommandOutput(0, '', '');
    }

    final size = RegExp(r"stat -c %s -- '([^']+)'").firstMatch(command);
    if (size != null) {
      final bytes = _read(instance, size.group(1)!);
      if (bytes == null) return const VmCommandOutput(1, '', 'no such file');
      return VmCommandOutput(0, '${bytes.length}\n', '');
    }

    final read = RegExp(r"dd if='([^']+)' bs=(\d+) skip=(\d+) count=1")
        .firstMatch(command);
    if (read != null) {
      final bytes = _read(instance, read.group(1)!) ?? Uint8List(0);
      final block = int.parse(read.group(2)!);
      final start = int.parse(read.group(3)!) * block;
      if (start >= bytes.length) return const VmCommandOutput(0, '', '');
      final end = start + block > bytes.length ? bytes.length : start + block;
      // Wrapped the way coreutils wraps it, so the service has to unwrap it.
      final encoded = base64.encode(bytes.sublist(start, end));
      final lines = <String>[
        for (var i = 0; i < encoded.length; i += 76)
          encoded.substring(
              i, i + 76 > encoded.length ? encoded.length : i + 76),
      ];
      return VmCommandOutput(0, '${lines.join('\n')}\n', '');
    }

    final write =
        RegExp(r"printf %s '([A-Za-z0-9+/=]*)' \| base64 -d (>>?) '([^']+)'")
            .firstMatch(command);
    if (write != null) {
      final chunk = base64.decode(write.group(1)!);
      final path = write.group(3)!;
      final existing = write.group(2) == '>>'
          ? _read(instance, path) ?? Uint8List(0)
          : Uint8List(0);
      _write(instance, path, Uint8List.fromList(<int>[...existing, ...chunk]));
      return const VmCommandOutput(0, '', '');
    }

    final unpack =
        RegExp(r"tar -xzf '([^']+)' -C '([^']+)'").firstMatch(command);
    if (unpack != null) {
      final bytes = _read(instance, unpack.group(1)!);
      if (bytes == null) {
        return const VmCommandOutput(2, '', 'archive is not there');
      }
      unpackedInto.add(unpack.group(2)!);
      unpacked.add(bytes);
      return const VmCommandOutput(0, '', '');
    }

    if (command.startsWith('mkdir -p') || command.startsWith('rm -f')) {
      return const VmCommandOutput(0, '', '');
    }
    if (answers.isNotEmpty) return answers.removeAt(0);
    return const VmCommandOutput(0, '', '');
  }
}

void main() {
  late Directory staging;
  late _FakeGuests guests;

  setUp(() {
    staging = Directory.systemTemp.createTempSync('wslm-transfer-test');
    guests = _FakeGuests(hostDirectory: staging.path);
  });

  tearDown(() {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  });

  // The start timings are tiny here so a test that waits for an instance to
  // come up takes milliseconds rather than the three minutes a real VM gets.
  FileTransferService serviceWith(
          {int? writeChunk,
          int? readChunk,
          int? max,
          Duration? startTimeout,
          Duration? poll}) =>
      FileTransferService(
        backend: guests,
        stagingDirectory: staging,
        writeChunkBytes: writeChunk,
        readChunkBytes: readChunk,
        maxBytes: max ?? 4 * 1024 * 1024,
        probeTimeout: const Duration(seconds: 1),
        startTimeout: startTimeout ?? const Duration(milliseconds: 60),
        startPollInterval: poll ?? const Duration(milliseconds: 5),
      );

  group('listing a folder', () {
    test('reads type, size and symlink off every entry, folders first',
        () async {
      guests.answers.add(const VmCommandOutput(
          0,
          'f\tn\t12\tnotes.txt\n'
              'd\tn\t4096\tprojects\n'
              'f\ty\t7\tlink-to-thing\n',
          ''));
      final entries = await serviceWith().list('old', '/home/eric');

      expect(entries.map((e) => e.name),
          ['projects', 'link-to-thing', 'notes.txt']);
      expect(entries.first.isDirectory, isTrue);
      // A directory's own inode size says nothing about what is in it.
      expect(entries.first.sizeBytes, 0);
      expect(entries[1].isSymlink, isTrue);
      expect(entries.last.sizeBytes, 12);
      expect(guests.seen.single, contains("cd -- '/home/eric'"));
    });

    test('a name with a tab in it keeps every character of it', () async {
      guests.answers.add(const VmCommandOutput(0, 'f\tn\t3\ttwo\tparts\n', ''));
      final entries = await serviceWith().list('old', '/tmp');
      expect(entries.single.name, 'two\tparts');
    });

    test('an unreadable folder is a failure, never an empty list', () async {
      guests.answers.add(const VmCommandOutput(0, '__wslm_nodir__', ''));
      await expectLater(
        serviceWith().list('old', '/root/secret'),
        throwsA(isA<WslFailure>()
            .having((e) => e.details, 'details', contains('/root/secret'))),
      );
    });

    test('a file named like the failure marker is still just a file', () async {
      guests.answers
          .add(const VmCommandOutput(0, 'f\tn\t0\t__wslm_nodir__\n', ''));
      final entries = await serviceWith().list('old', '/tmp');
      expect(entries.single.name, '__wslm_nodir__');
    });

    test('a command that failed outright reports what it said', () async {
      guests.answers
          .add(const VmCommandOutput(1, '', 'the distro is not running'));
      await expectLater(
        serviceWith().list('old', '/'),
        throwsA(isA<WslFailure>()
            .having((e) => e.details, 'details', contains('not running'))),
      );
    });
  });

  group('picking what to transfer', () {
    test('an entry with a separator in it is refused, not quoted', () async {
      await expectLater(
        serviceWith().transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const ['../../etc/shadow'],
          targetInstance: 'new',
          targetDirectory: '/home/eric',
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.seen, isEmpty);
    });

    test('nothing picked is refused before anything runs', () async {
      await expectLater(
        serviceWith().transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const [],
          targetInstance: 'new',
          targetDirectory: '/home/eric',
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.seen, isEmpty);
    });

    test('the same folder of the same instance is refused', () async {
      await expectLater(
        serviceWith().transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric/',
          names: const ['notes.txt'],
          targetInstance: 'old',
          targetDirectory: '/home/eric',
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.seen, isEmpty);
    });
  });

  group('moving the bytes', () {
    /// An archive big enough to need several chunks, and not a multiple of
    /// any of them.
    Uint8List archive(int length) => Uint8List.fromList(
        List<int>.generate(length, (i) => (i * 7 + 13) % 251));

    test('chunked both ways, the bytes arrive exactly as they were packed',
        () async {
      final payload = archive(7777);
      guests.packs['old'] = payload;

      final moved =
          await serviceWith(writeChunk: 300, readChunk: 1024).transfer(
        sourceInstance: 'old',
        sourceDirectory: '/home/eric',
        names: const ['notes.txt', 'projects'],
        targetInstance: 'new',
        targetDirectory: '/home/eric/from-old',
      );

      expect(moved, payload.length);
      expect(guests.unpacked.single, payload);
      expect(guests.unpackedInto.single, '/home/eric/from-old');
      // Picked names travel as `./name`, so one starting with a dash is an
      // entry and never an option.
      expect(guests.seen.firstWhere((c) => c.startsWith('tar -czf')),
          contains("'./notes.txt' './projects'"));
      // The archive being written is never packed into itself.
      expect(guests.seen.firstWhere((c) => c.startsWith('tar -czf')),
          contains("--exclude='wslmanager-transfer-*.tar.gz'"));
      expect(guests.seen.any((c) => c.contains('dd if=')), isTrue);
      // Exactly one truncating write, the rest append: a second `>` would
      // throw away everything carried before it.
      expect(guests.seen.where((c) => c.contains("base64 -d > '")).length, 1);
      expect(guests.seen.where((c) => c.contains("base64 -d >> '")).length,
          greaterThan(1));
      // The staging file does not outlive the transfer.
      expect(staging.listSync(), isEmpty);
    });

    test('a write chunk is rounded down to a whole base64 group', () {
      // 16 KiB is not divisible by three; a chunk that ends mid-group would
      // decode to the wrong bytes once the next one is appended.
      expect(serviceWith(writeChunk: 16 * 1024).writeChunkBytes % 3, 0);
      expect(serviceWith(writeChunk: 1).writeChunkBytes, 3);
    });

    test('a guest that can see the host folder is never chunked', () async {
      guests.bridged.addAll(['old', 'new']);
      final payload = archive(4096);
      guests.packs['old'] = payload;

      final moved = await serviceWith().transfer(
        sourceInstance: 'old',
        sourceDirectory: '/home/eric',
        names: const ['notes.txt'],
        targetInstance: 'new',
        targetDirectory: '/root',
      );

      expect(moved, payload.length);
      expect(guests.unpacked.single, payload);
      expect(guests.seen.any((c) => c.contains('dd if=')), isFalse);
      expect(guests.seen.any((c) => c.contains('base64 -d')), isFalse);
      expect(guests.seen.firstWhere((c) => c.startsWith('tar -czf')),
          contains("'/mnt/host/"));
      expect(staging.listSync(), isEmpty);
    });

    test('only the source can see the host folder: read is free, write is not',
        () async {
      guests.bridged.add('old');
      guests.packs['old'] = archive(2048);

      await serviceWith(writeChunk: 600).transfer(
        sourceInstance: 'old',
        sourceDirectory: '/home/eric',
        names: const ['notes.txt'],
        targetInstance: 'new',
        targetDirectory: '/root',
      );

      expect(guests.seen.any((c) => c.contains('dd if=')), isFalse);
      expect(guests.seen.any((c) => c.contains('base64 -d')), isTrue);
      expect(guests.unpacked.single, guests.packs['old']);
    });

    test('a remote backend never takes the host-folder shortcut', () async {
      // Its guests mount the remote host's drives; a `/tmp` they say they can
      // see is not the `/tmp` this machine staged into.
      guests.bridged.addAll(['old', 'new']);
      guests.remote = true;
      guests.packs['old'] = archive(1500);

      await serviceWith(writeChunk: 600, readChunk: 512).transfer(
        sourceInstance: 'old',
        sourceDirectory: '/home/eric',
        names: const ['notes.txt'],
        targetInstance: 'new',
        targetDirectory: '/root',
      );

      expect(guests.seen.any((c) => c.contains('wslpath')), isFalse);
      expect(guests.seen.any((c) => c.contains('dd if=')), isTrue);
      expect(guests.unpacked.single, guests.packs['old']);
    });

    test('an archive bigger than the cap is refused before it is carried',
        () async {
      guests.packs['old'] = archive(5000);
      await expectLater(
        serviceWith(max: 1024).transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const ['huge'],
          targetInstance: 'new',
          targetDirectory: '/root',
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.seen.any((c) => c.contains('dd if=')), isFalse);
      expect(guests.unpacked, isEmpty);
    });

    test('an empty archive is reported rather than unpacked', () async {
      guests.packs['old'] = Uint8List(0);
      await expectLater(
        serviceWith().transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const ['gone'],
          targetInstance: 'new',
          targetDirectory: '/root',
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.unpacked, isEmpty);
    });

    test('cancelling stops the run and takes the staging file with it',
        () async {
      guests.packs['old'] = archive(4000);
      // Cancelled once the archive exists, not before the run starts: the
      // cleanup this asserts only has something to clean from that point on,
      // and a signal that is already cancelled now stops the transfer at the
      // readiness check, before a single guest command (see the test below).
      final cancel = CancelSignal();
      guests.onCommand = (command) {
        if (command.startsWith('tar -czf')) cancel.cancel();
      };
      await expectLater(
        serviceWith(writeChunk: 300).transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const ['notes.txt'],
          targetInstance: 'new',
          targetDirectory: '/root',
          cancel: cancel,
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.unpacked, isEmpty);
      expect(staging.listSync(), isEmpty);
      // The archive it had already built in the guest is cleaned up too.
      expect(guests.seen.any((c) => c.startsWith('rm -f')), isTrue);
    });

    test('a signal already cancelled never touches either guest', () async {
      guests.packs['old'] = archive(4000);
      await expectLater(
        serviceWith().transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const ['notes.txt'],
          targetInstance: 'new',
          targetDirectory: '/root',
          cancel: CancelSignal()..cancel(),
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.seen, isEmpty);
      expect(guests.started, isEmpty);
      expect(staging.listSync(), isEmpty);
    });

    test('progress is reported in order and ends at the whole archive',
        () async {
      guests.packs['old'] = archive(2500);
      final stages = <TransferStage>[];
      TransferStep? last;
      await serviceWith(writeChunk: 600, readChunk: 1024).transfer(
        sourceInstance: 'old',
        sourceDirectory: '/home/eric',
        names: const ['notes.txt'],
        targetInstance: 'new',
        targetDirectory: '/root',
        onStep: (step) {
          if (stages.isEmpty || stages.last != step.stage) {
            stages.add(step.stage);
          }
          last = step;
        },
      );

      expect(stages, [
        TransferStage.packing,
        TransferStage.reading,
        TransferStage.writing,
        TransferStage.unpacking,
        TransferStage.done,
      ]);
      expect(last!.fraction, 1.0);
      expect(const TransferStep(stage: TransferStage.packing).fraction, isNull);
    });
  });

  group('where the browser opens', () {
    test('the default user home when the instance answers with one', () async {
      guests.answers.add(const VmCommandOutput(0, '/home/eric\n', ''));
      expect(await serviceWith().homeDirectory('old'), '/home/eric');
    });

    test('the filesystem root when it does not', () async {
      guests.answers.add(const VmCommandOutput(1, '', 'no such user'));
      expect(await serviceWith().homeDirectory('old'), '/');
    });
  });

  // What the reworked issue is about: a transfer into a stopped VM used to
  // run the whole source leg and only then fail on `mkdir -p` with "no IP
  // address yet (no DHCP lease)".
  group('getting both ends up first', () {
    Uint8List archive(int length) => Uint8List.fromList(
        List<int>.generate(length, (i) => (i * 31 + 7) % 251));

    Future<int> run(FileTransferService service,
            {CancelSignal? cancel, void Function(TransferStep step)? onStep}) =>
        service.transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const ['notes.txt'],
          targetInstance: 'new',
          targetDirectory: '/root',
          cancel: cancel,
          onStep: onStep,
        );

    setUp(() => guests.packs['old'] = archive(600));

    test('two reachable instances are never started', () async {
      final steps = <TransferStep>[];
      await run(serviceWith(), onStep: steps.add);

      expect(guests.started, isEmpty);
      expect(
          steps.map((s) => s.stage), isNot(contains(TransferStage.starting)));
    });

    test('a stopped target is started before anything is packed', () async {
      guests.stopped.add('new');
      await run(serviceWith());

      expect(guests.started, ['new']);
      // The assertion the whole change exists for: no packing had happened
      // when the start was needed.
      expect(guests.packsBeforeStart, [0]);
      expect(guests.unpacked, hasLength(1));
    });

    test('the starting step names the instance being started', () async {
      guests.stopped.add('new');
      final steps = <TransferStep>[];
      await run(serviceWith(), onStep: steps.add);

      final starting =
          steps.where((s) => s.stage == TransferStage.starting).toList();
      expect(starting, hasLength(1));
      expect(starting.single.instance, 'new');
      // And it is the first thing reported, before the packing line.
      expect(steps.first.stage, TransferStage.starting);
    });

    test('a stopped source is started too, and before the target', () async {
      guests.stopped.addAll({'old', 'new'});
      final steps = <TransferStep>[];
      await run(serviceWith(), onStep: steps.add);

      expect(guests.started, ['old', 'new']);
      expect(
          steps
              .where((s) => s.stage == TransferStage.starting)
              .map((s) => s.instance),
          ['old', 'new']);
    });

    test('an instance that needs a moment is waited for, not given up on',
        () async {
      guests.stopped.add('new');
      guests.bootProbes = 3;
      await run(serviceWith(startTimeout: const Duration(seconds: 5)));

      expect(guests.started, ['new']);
      expect(guests.unpacked, hasLength(1));
    });

    test('one that never comes up fails by name, having packed nothing',
        () async {
      guests.stopped.add('new');
      guests.bootProbes = 1000;

      await expectLater(
        run(serviceWith()),
        throwsA(isA<WslFailure>().having((e) => e.details, 'details',
            allOf(contains('new'), contains('did not come up')))),
      );
      expect(guests.seen.any((c) => c.startsWith('tar -czf')), isFalse);
      expect(staging.listSync(), isEmpty);
    });

    test('a start the backend refuses is reported, not worked around',
        () async {
      guests.stopped.add('new');
      guests.refuseStart.add('new');

      await expectLater(
        run(serviceWith()),
        throwsA(isA<WslFailure>().having((e) => e.details, 'details',
            allOf(contains('new'), contains('Could not start')))),
      );
      expect(guests.seen.any((c) => c.startsWith('tar -czf')), isFalse);
    });

    test('cancelling while waiting for a start stops the wait', () async {
      guests.stopped.add('new');
      guests.bootProbes = 1000;
      final cancel = CancelSignal();
      guests.onCommand = (command) {
        if (command == 'exit 0') cancel.cancel();
      };

      await expectLater(
        run(serviceWith(startTimeout: const Duration(seconds: 5)),
            cancel: cancel),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.seen.any((c) => c.startsWith('tar -czf')), isFalse);
    });

    test('one instance on both ends is only started once', () async {
      guests.stopped.add('old');
      guests.packs['old'] = archive(600);
      await serviceWith().transfer(
        sourceInstance: 'old',
        sourceDirectory: '/home/eric',
        names: const ['notes.txt'],
        targetInstance: 'old',
        targetDirectory: '/root',
      );

      expect(guests.started, ['old']);
    });

    test('a refused transfer is refused before any instance is started',
        () async {
      guests.stopped.addAll({'old', 'new'});

      // A name with a separator in it never reaches a guest, so it must not
      // boot one either.
      await expectLater(
        serviceWith().transfer(
          sourceInstance: 'old',
          sourceDirectory: '/home/eric',
          names: const ['../etc/shadow'],
          targetInstance: 'new',
          targetDirectory: '/root',
        ),
        throwsA(isA<WslFailure>()),
      );
      expect(guests.started, isEmpty);
    });
  });
}
