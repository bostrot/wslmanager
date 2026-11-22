import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:chunked_downloader/chunked_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/apple/vm_image_catalog.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Serves canned directory listings for the catalog's mirror indexes.
class _FakeListingAdapter implements HttpClientAdapter {
  final Map<String, String> pages;
  final List<String> requested = [];
  _FakeListingAdapter(this.pages);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requested.add(options.uri.toString());
    for (final entry in pages.entries) {
      if (options.uri.toString().startsWith(entry.key)) {
        return ResponseBody.fromString(entry.value, 200);
      }
    }
    return ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// A downloader whose "network" is a byte payload handed in by the test.
class _FakeDownloader implements ChunkedDownloader {
  _FakeDownloader({
    required this.url,
    required this.saveFilePath,
    this.onProgress,
    this.payload = const [1, 2, 3],
    this.announceTotal,
    this.failWith,
  });

  @override
  final String url;
  @override
  final String saveFilePath;
  @override
  final Function(int, int, double)? onProgress;
  final List<int> payload;
  final int? announceTotal;
  final Object? failWith;
  bool stopped = false;

  @override
  Future<ChunkedDownloader> start() async {
    if (failWith != null) throw failWith!;
    onProgress?.call(
        payload.length, announceTotal ?? payload.length, 1000);
    if (!stopped) {
      final file = File(saveFilePath);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(payload);
    }
    return this;
  }

  @override
  void stop() {
    stopped = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// One mirror listing as the catalog would scrape it: the entry [id], the
/// file names the listing carries, and the one the pattern has to pick.
class _PatternCase {
  final String id;
  final List<String> listing;
  final String want;
  const _PatternCase(this.id, this.listing, this.want);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('iso-catalog-test');
    SharedPreferences.setMockInitialValues({'DataPath': dataDir.path});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  VmIsoCatalogEntry alpine() => VmImageCatalog.entryFor('Alpine Linux (virt)')!;

  Dio fakeDio(Map<String, String> pages) =>
      Dio()..httpClientAdapter = _FakeListingAdapter(pages);

  group('catalog shape', () {
    test('the ready-to-use cloud image is curated and marked as such', () {
      final entry = VmImageCatalog.entryById('debian-13-cloud');
      expect(entry, isNotNull);
      expect(entry!.isCloudImage, isTrue);
      expect(entry.pattern.pattern, contains('genericcloud-arm64'));
      expect(entry.pattern.pattern, contains('raw'),
          reason: 'only raw images boot without a conversion tool');
      // Every other cloud image rides the same path (qcow2, converted by
      // vmctl); the netinst/virt/standard/Server entries stay installers.
      expect(
          VmImageCatalog.entries
              .where((e) => e.isCloudImage)
              .map((e) => e.id),
          [
            'debian-13-cloud',
            'alpine-cloud',
            'ubuntu-26-04-cloud',
            'ubuntu-24-04-cloud',
            'fedora-44-cloud',
            'rocky-10-cloud',
            'almalinux-10-cloud',
            'centos-stream-10-cloud',
            'opensuse-leap-16-cloud',
            'amazon-linux-2023-cloud',
          ]);
      final alpine = VmImageCatalog.entryById('alpine-cloud')!;
      expect(alpine.pattern.pattern, isNot(contains('metal')));
      expect('generic_alpine-3.24.1-aarch64-uefi-cloudinit-metal-r0.qcow2',
          isNot(matches(alpine.pattern)));
      expect('generic_alpine-3.24.1-aarch64-uefi-cloudinit-r0.qcow2',
          matches(alpine.pattern));
    });

    test('cloud images lead the list and every entry has a unique id', () {
      final kinds =
          VmImageCatalog.entries.map((e) => e.isCloudImage).toList();
      final firstIso = kinds.indexOf(false);
      expect(kinds.sublist(firstIso).contains(true), isFalse,
          reason: 'the ready-to-use images are the ones to recommend, so '
              'they come before every installer');
      expect(VmImageCatalog.entries.first.id, 'debian-13-cloud');
      final ids = VmImageCatalog.entries.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'ids are MCP handles');
      final names = VmImageCatalog.names;
      expect(names.toSet().length, names.length);
      for (final entry in VmImageCatalog.entries) {
        expect(entry.indexUrl, startsWith('https://'));
        expect(entry.indexUrl, endsWith('/'),
            reason: 'the resolved URL is indexUrl + file name');
        expect(entry.isCloudImage, entry.name.contains('(cloud image)'),
            reason: '${entry.name}: the label tells the user how it boots');
      }
    });

    test('cloud image patterns pin the dated arm64 file, not the aliases',
        () {
      // Each row: id, a listing's file names, the one the pattern must pick.
      // The rejects are the neighbours each mirror really lists: `latest`
      // aliases, LVM/ext4 variants, the Ignition-flavoured openSUSE build,
      // other architectures, checksums and tarballs.
      final cases = <_PatternCase>[
        _PatternCase(
          'ubuntu-26-04-cloud',
          [
            'ubuntu-26.04-server-cloudimg-arm64.img',
            'ubuntu-26.04-server-cloudimg-amd64.img',
            'ubuntu-26.04-server-cloudimg-arm64-root.tar.xz',
            'ubuntu-26.04-server-cloudimg-arm64.manifest',
          ],
          'ubuntu-26.04-server-cloudimg-arm64.img',
        ),
        _PatternCase(
          'ubuntu-24-04-cloud',
          ['ubuntu-24.04-server-cloudimg-arm64.img'],
          'ubuntu-24.04-server-cloudimg-arm64.img',
        ),
        _PatternCase(
          'fedora-44-cloud',
          [
            'Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2',
            'Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2',
            'Fedora-Cloud-Base-UEFI-UKI-44-1.7.aarch64.qcow2',
            'Fedora-Cloud-44-1.7-aarch64-CHECKSUM',
          ],
          'Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2',
        ),
        _PatternCase(
          'rocky-10-cloud',
          [
            'Rocky-10-GenericCloud-Base-10.2-20260525.0.aarch64.qcow2',
            'Rocky-10-GenericCloud-Base.latest.aarch64.qcow2',
            'Rocky-10-GenericCloud-LVM-10.2-20260525.0.aarch64.qcow2',
            'Rocky-10-GenericCloud.latest.aarch64.qcow2',
            'Rocky-10-GenericCloud-Base-10.2-20260525.0.aarch64.qcow2.CHECKSUM',
          ],
          'Rocky-10-GenericCloud-Base-10.2-20260525.0.aarch64.qcow2',
        ),
        _PatternCase(
          'almalinux-10-cloud',
          [
            'AlmaLinux-10-GenericCloud-10.2-20260526.0.aarch64.qcow2',
            'AlmaLinux-10-GenericCloud-10.2-20260817.0.aarch64.qcow2',
            'AlmaLinux-10-GenericCloud-ext4-10.2-20260817.0.aarch64.qcow2',
            'AlmaLinux-10-GenericCloud-latest.aarch64.qcow2',
          ],
          'AlmaLinux-10-GenericCloud-10.2-20260817.0.aarch64.qcow2',
        ),
        _PatternCase(
          'centos-stream-10-cloud',
          [
            'CentOS-Stream-GenericCloud-10-20250904.0.aarch64.qcow2',
            'CentOS-Stream-GenericCloud-10-20260728.1.aarch64.qcow2',
            'CentOS-Stream-GenericCloud-10-latest.aarch64.qcow2',
            'CentOS-Stream-GenericCloud-10-20260728.1.aarch64.qcow2.SHA256SUM',
          ],
          'CentOS-Stream-GenericCloud-10-20260728.1.aarch64.qcow2',
        ),
        _PatternCase(
          'opensuse-leap-16-cloud',
          [
            'Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2',
            'Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2',
            'Leap-16.0-Minimal-VM.aarch64-kvm-Build18.7.qcow2',
            'Leap-16.0-Minimal-VM.x86_64-Cloud-Build18.7.qcow2',
          ],
          'Leap-16.0-Minimal-VM.aarch64-Cloud-Build18.7.qcow2',
        ),
        _PatternCase(
          'amazon-linux-2023-cloud',
          [
            'al2023-kvm-2023.12.20260831.0-kernel-6.1-arm64.xfs.gpt.qcow2',
            'al2023-kvm-2023.12.20260831.0-kernel-6.1-x86_64.xfs.gpt.qcow2',
            'SHA256SUMS',
          ],
          'al2023-kvm-2023.12.20260831.0-kernel-6.1-arm64.xfs.gpt.qcow2',
        ),
      ];
      for (final c in cases) {
        final entry = VmImageCatalog.entryById(c.id);
        expect(entry, isNotNull, reason: c.id);
        // Same steps as resolveUrl: every match across the listing (a
        // checksum file yields the image name it is named after, which the
        // set then folds away), newest last.
        final listing = c.listing.map((name) => '<a href="$name">').join();
        final picked = entry!.pattern
            .allMatches(listing)
            .map((match) => match.group(0)!)
            .toSet()
            .toList()
          ..sort(VmImageCatalog.compareVersionish);
        expect(picked, isNotEmpty, reason: '${c.id} matches nothing');
        expect(picked.last, c.want, reason: c.id);
        expect(picked, everyElement(matches(RegExp(r'\.(qcow2|img)$'))),
            reason: '${c.id}: only disk images, not their neighbours');
        for (final name in c.listing) {
          if (!name.startsWith(c.want)) continue;
          expect(entry.pattern.stringMatch(name), c.want,
              reason: '${c.id}: the match is appended to indexUrl as-is, so '
                  'it must be exactly the image file name');
        }
      }
    });

    test('names cover the curated distros and resolve back to entries', () {
      expect(VmImageCatalog.names.length, greaterThanOrEqualTo(4));
      for (final name in VmImageCatalog.names) {
        expect(VmImageCatalog.entryFor(name), isNotNull);
      }
      // Lookup is case-insensitive — the box's text is user-typed.
      expect(VmImageCatalog.entryFor('alpine linux (VIRT)'), isNotNull);
      expect(VmImageCatalog.entryFor('/tmp/some/local.iso'), isNull);
      expect(VmImageCatalog.entryFor(''), isNull);
    });
  });

  group('version-aware ordering', () {
    test('numeric runs compare as numbers, not text', () {
      final names = [
        'alpine-virt-3.9.2-aarch64.iso',
        'alpine-virt-3.24.1-aarch64.iso',
        'alpine-virt-3.24.0-aarch64.iso',
      ]..sort(VmImageCatalog.compareVersionish);
      expect(names.last, 'alpine-virt-3.24.1-aarch64.iso');
      expect(names.first, 'alpine-virt-3.9.2-aarch64.iso');
    });
  });

  group('resolveUrl', () {
    test('scrapes the listing and picks the newest match', () async {
      final entry = alpine();
      final catalog = VmImageCatalog(dio: fakeDio({
        entry.indexUrl: '<a href="alpine-virt-3.24.0-aarch64.iso">x</a>'
            '<a href="alpine-virt-3.24.1-aarch64.iso">y</a>'
            '<a href="alpine-standard-3.24.1-aarch64.iso">z</a>',
      }));
      expect(await catalog.resolveUrl(entry),
          '${entry.indexUrl}alpine-virt-3.24.1-aarch64.iso');
    });

    test('a dated build beats the alias and the variant on a real listing',
        () async {
      // The Rocky mirror, as it lists today: the pattern has to walk past
      // the `latest` symlinks and the LVM build to the dated Base file.
      final entry = VmImageCatalog.entryById('rocky-10-cloud')!;
      final catalog = VmImageCatalog(dio: fakeDio({
        entry.indexUrl:
            '<a href="Rocky-10-GenericCloud-Base.latest.aarch64.qcow2">a</a>'
            '<a href="Rocky-10-GenericCloud-Base-10.1-20251110.0.aarch64.qcow2">b</a>'
            '<a href="Rocky-10-GenericCloud-Base-10.2-20260525.0.aarch64.qcow2">c</a>'
            '<a href="Rocky-10-GenericCloud-LVM-10.2-20260525.0.aarch64.qcow2">d</a>'
            '<a href="Rocky-10-GenericCloud.latest.aarch64.qcow2">e</a>',
      }));
      expect(
          await catalog.resolveUrl(entry),
          '${entry.indexUrl}'
          'Rocky-10-GenericCloud-Base-10.2-20260525.0.aarch64.qcow2');
    });

    test('a listing with no match is an error, not a null download', () {
      final entry = alpine();
      final catalog =
          VmImageCatalog(dio: fakeDio({entry.indexUrl: '<html>empty</html>'}));
      expect(() => catalog.resolveUrl(entry), throwsException);
    });

    test('resolution is cached per catalog instance', () async {
      final entry = alpine();
      final adapter = _FakeListingAdapter({
        entry.indexUrl: '<a href="alpine-virt-3.24.1-aarch64.iso">y</a>',
      });
      final catalog = VmImageCatalog(dio: Dio()..httpClientAdapter = adapter);
      await catalog.resolveUrl(entry);
      await catalog.resolveUrl(entry);
      expect(adapter.requested, hasLength(1));
    });
  });

  group('download', () {
    VmImageCatalog catalogWith(_FakeDownloader Function(
            {required String url,
            required String saveFilePath,
            Function(int, int, double)? onProgress})
        make) {
      final entry = alpine();
      return VmImageCatalog(
        dio: fakeDio({
          entry.indexUrl: '<a href="alpine-virt-3.24.1-aarch64.iso">y</a>',
        }),
        downloaderFactory: ({
          required url,
          required saveFilePath,
          headers,
          chunkSize,
          onProgress,
          onDone,
          onError,
        }) =>
            make(url: url, saveFilePath: saveFilePath, onProgress: onProgress),
      );
    }

    test('fetches into the iso cache and reports progress', () async {
      final progress = <List<int>>[];
      final catalog = catalogWith(
          ({required url, required saveFilePath, onProgress}) =>
              _FakeDownloader(
                  url: url,
                  saveFilePath: saveFilePath,
                  onProgress: onProgress,
                  payload: List.filled(64, 7)));
      final path = await catalog.download(alpine(),
          onProgress: (received, total) => progress.add([received, total]));
      expect(path, contains('isos'));
      expect(path, endsWith('alpine-virt-3.24.1-aarch64.iso'));
      expect(File(path).lengthSync(), 64);
      expect(progress, isNotEmpty);
    });

    test('a cached file is reused without a new download', () async {
      var downloads = 0;
      final catalog = catalogWith(
          ({required url, required saveFilePath, onProgress}) {
        downloads++;
        return _FakeDownloader(
            url: url, saveFilePath: saveFilePath, onProgress: onProgress);
      });
      await catalog.download(alpine());
      await catalog.download(alpine());
      expect(downloads, 1);
    });

    test('a short download is deleted and reported, not cached', () async {
      final catalog = catalogWith(
          ({required url, required saveFilePath, onProgress}) =>
              _FakeDownloader(
                  url: url,
                  saveFilePath: saveFilePath,
                  onProgress: onProgress,
                  payload: List.filled(10, 1),
                  // The server announced more than arrived.
                  announceTotal: 999));
      await expectLater(
          catalog.download(alpine()),
          throwsA(predicate(
              (e) => e.toString().contains('incomplete download'))));
      final cache = Directory('${dataDir.path}/isos');
      expect(
          cache.existsSync() &&
              cache.listSync().any((f) => f.path.endsWith('.iso')),
          isFalse,
          reason: 'a partial file must not poison the cache');
    });

    test('a downloader error propagates and leaves nothing cached', () async {
      final catalog = catalogWith(
          ({required url, required saveFilePath, onProgress}) =>
              _FakeDownloader(
                  url: url,
                  saveFilePath: saveFilePath,
                  onProgress: onProgress,
                  failWith: const SocketException('connection reset')));
      await expectLater(
          catalog.download(alpine()), throwsA(isA<SocketException>()));
      final cache = Directory('${dataDir.path}/isos');
      expect(
          cache.existsSync() &&
              cache.listSync().any((f) => f.path.endsWith('.iso')),
          isFalse,
          reason: 'a failed download must not leave a file behind');
    });

    test('cancel stops the downloader and surfaces as CancelledException',
        () async {
      _FakeDownloader? made;
      final signal = CancelSignal();
      final catalog = catalogWith(
          ({required url, required saveFilePath, onProgress}) {
        made = _FakeDownloader(
            url: url,
            saveFilePath: saveFilePath,
            onProgress: (c, t, s) {
              signal.cancel();
              onProgress?.call(c, t, s);
            });
        return made!;
      });
      await expectLater(catalog.download(alpine(), cancelSignal: signal),
          throwsA(isA<CancelledException>()));
      expect(made!.stopped, isTrue);
    });
  });
}
