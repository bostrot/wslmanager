/// Picking a root filesystem for the machine that will run it
/// (bostrot/wsl2-distro-manager#229).
///
/// WSL does not emulate, so on a Windows-on-ARM PC an x86-64 image installs
/// and then cannot run a single binary. These cover the three places that
/// used to assume Intel: the architecture read off the machine, the catalogue
/// in `images.json`, and the architecture list of a Docker manifest.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/app.dart';
import 'package:wsl2distromanager/api/docker_images.dart';
import 'package:wsl2distromanager/api/rootfs_architecture.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Answers each URL from [responses]; anything else is a 404, so a test that
/// expects a source to be skipped fails loudly if it is queried anyway.
class _CatalogueAdapter implements HttpClientAdapter {
  _CatalogueAdapter(this.responses);

  final Map<String, Object> responses;
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final url = options.uri.toString();
    requested.add(url);
    final body = responses[url];
    if (body == null) return ResponseBody.fromString('', 404);
    return ResponseBody.fromString(
        body is String ? body : jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }

  @override
  void close({bool force = false}) {}
}

Manifest _manifest(String digest, String architecture, String os) =>
    Manifest(
        digest: digest,
        mediaType: 'application/vnd.oci.image.manifest.v1+json',
        platform: PlatformManifest(architecture: architecture, os: os),
        size: 1);

void main() {
  group('rootfsTokenFamily', () {
    test('reads the catalogue keys', () {
      expect(rootfsTokenFamily('x64'), rootfsX86Family);
      expect(rootfsTokenFamily('arm64'), rootfsArmFamily);
      expect(rootfsTokenFamily('aarch64'), rootfsArmFamily);
    });

    test('reads the architecture out of a real image URL', () {
      expect(
          rootfsTokenFamily(
              'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-root.tar.xz'),
          rootfsX86Family);
      expect(
          rootfsTokenFamily(
              'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64-root.tar.xz'),
          rootfsArmFamily);
      // Underscores, not just dashes: the AlmaLinux assets are named this way
      // and a plain word-boundary match misses them.
      expect(
          rootfsTokenFamily(
              'https://github.com/AlmaLinux/wsl-images/releases/download/v10.2.20260526.0/AlmaLinux-10.2_x64_20260526.0.wsl'),
          rootfsX86Family);
      expect(
          rootfsTokenFamily(
              'https://github.com/AlmaLinux/wsl-images/releases/download/v10.2.20260526.0/AlmaLinux-10.2_ARM64_20260526.0.wsl'),
          rootfsArmFamily);
      // Debian's arm64 branch carries the ARM version in the same word.
      expect(
          rootfsTokenFamily(
              'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/dist-arm64v8/trixie/oci/blobs/rootfs.tar.gz'),
          rootfsArmFamily);
      expect(
          rootfsTokenFamily(
              'https://download.opensuse.org/tumbleweed/appliances/opensuse-tumbleweed-image.x86_64-networkd.tar.xz'),
          rootfsX86Family);
    });

    test('a URL that names no architecture belongs to neither family', () {
      expect(rootfsTokenFamily('https://geo.mirror.pkgbuild.com/wsl/latest/'),
          '');
      // A release name that merely contains the letters is not an
      // architecture.
      expect(rootfsTokenFamily('https://example.invalid/charm/rootfs.tar.gz'),
          '');
    });
  });

  group('rootfsHostArchitecture', () {
    test('a Windows-on-ARM PC running the x64 build asks for arm64', () {
      // The app itself is emulated there, so its own ABI says x64 and only
      // the environment tells the truth.
      expect(
          rootfsHostArchitecture(
              isWindows: true,
              remote: false,
              abi: Abi.windowsX64,
              environment: {'PROCESSOR_ARCHITEW6432': 'ARM64'}),
          rootfsArmFamily);
    });

    test('an ordinary Windows PC asks for x86-64', () {
      expect(
          rootfsHostArchitecture(
              isWindows: true,
              remote: false,
              abi: Abi.windowsX64,
              environment: const {}),
          rootfsX86Family);
    });

    test('a remote host has an architecture this machine cannot know', () {
      expect(
          rootfsHostArchitecture(
              isWindows: true,
              remote: true,
              abi: Abi.windowsArm64,
              environment: const {}),
          '');
    });

    test('off Windows there is no WSL to install into', () {
      expect(
          rootfsHostArchitecture(
              isWindows: false,
              remote: false,
              abi: Abi.macosArm64,
              environment: const {}),
          '');
    });
  });

  group('rootfsLinksFor', () {
    final catalogue = <String, dynamic>{
      'Both': {'x64': 'https://example.invalid/both-amd64.tar.gz',
        'arm64': 'https://example.invalid/both-arm64.tar.gz'},
      'Intel only': {'x64': 'https://example.invalid/intel.wsl'},
      'Legacy Intel': 'https://example.invalid/legacy-x86_64.tar.gz',
      'Legacy unlabelled': 'https://example.invalid/legacy.tar.gz',
    };

    test('an ARM machine gets the arm64 URLs and nothing it cannot run', () {
      expect(rootfsLinksFor(catalogue, rootfsArmFamily), {
        'Both': 'https://example.invalid/both-arm64.tar.gz',
        'Legacy unlabelled': 'https://example.invalid/legacy.tar.gz',
      });
    });

    test('an Intel machine sees the catalogue it always saw', () {
      expect(rootfsLinksFor(catalogue, rootfsX86Family), {
        'Both': 'https://example.invalid/both-amd64.tar.gz',
        'Intel only': 'https://example.invalid/intel.wsl',
        'Legacy Intel': 'https://example.invalid/legacy-x86_64.tar.gz',
        'Legacy unlabelled': 'https://example.invalid/legacy.tar.gz',
      });
    });

    test('an unknown machine is served the Intel entries', () {
      expect(rootfsLinksFor(catalogue, ''), {
        'Both': 'https://example.invalid/both-amd64.tar.gz',
        'Intel only': 'https://example.invalid/intel.wsl',
        'Legacy Intel': 'https://example.invalid/legacy-x86_64.tar.gz',
        'Legacy unlabelled': 'https://example.invalid/legacy.tar.gz',
      });
    });

    test('the catalogue order is kept', () {
      expect(rootfsLinksFor(catalogue, rootfsX86Family).keys.toList(),
          ['Both', 'Intel only', 'Legacy Intel', 'Legacy unlabelled']);
    });

    test('an entry that is neither a URL nor an architecture map is dropped',
        () {
      final broken = <String, dynamic>{
        'Number': 3,
        'Nothing': null,
        'Empty': '',
        'Empty map': <String, dynamic>{},
        'Wrong type inside': {'arm64': 7},
        'Good': 'https://example.invalid/good.tar.gz',
      };
      expect(rootfsLinksFor(broken, rootfsArmFamily),
          {'Good': 'https://example.invalid/good.tar.gz'});
    });
  });

  group('the shipped catalogue', () {
    final catalogue =
        json.decode(File('images.json').readAsStringSync()) as Map;

    test('every distro offers an x86-64 download', () {
      for (final entry in catalogue.entries) {
        final links = rootfsLinksFor({entry.key: entry.value}, rootfsX86Family);
        expect(links.keys, [entry.key],
            reason: '${entry.key} has no x64 image');
      }
    });

    test('no URL is filed under the wrong architecture', () {
      // Most mirrors name the architecture in the file name, so a URL copied
      // into the wrong slot — the easiest mistake to make when adding a
      // distro — is caught here. The few that name nothing (Arch publishes one
      // image and says so only in the release notes) are taken at their word.
      catalogue.forEach((name, value) {
        expect(value, isA<Map>(),
            reason: '$name should list a URL per architecture');
        (value as Map).forEach((architecture, url) {
          final named = rootfsTokenFamily(url as String);
          if (named.isEmpty) return;
          expect(named, rootfsTokenFamily(architecture as String),
              reason: '$name: the $architecture URL is for $named');
        });
      });
    });

    test('a Windows-on-ARM PC is offered a usable part of the catalogue', () {
      final arm = rootfsLinksFor(catalogue, rootfsArmFamily);
      // Not a number for its own sake: an empty list would mean the Create
      // dialog has nothing to offer such a machine at all.
      expect(arm.length, greaterThan(10));
      expect(arm.keys.any((name) => name.startsWith('Ubuntu')), isTrue);
      // The distributions that publish no arm64 image stay out of it.
      expect(arm.containsKey('Arch Linux'), isFalse);
    });
  });

  group('App.getDistroLinks', () {
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await initPrefs();
      distroRootfsLinks = {};
    });

    tearDown(() => distroRootfsLinks = {});

    test('an Intel-only CDN copy is skipped on an ARM machine', () async {
      // The CDN copy is uploaded by hand and lags the repo's own, so the
      // machine that needs arm64 has to fall through to the file on GitHub
      // rather than end up with an empty list.
      final adapter = _CatalogueAdapter({
        gitRepoLink: {'Debian 12': 'https://example.invalid/bookworm-amd64.tar.gz'},
        gitRepoRawLink: {
          'Debian 12': {
            'x64': 'https://example.invalid/bookworm-amd64.tar.gz',
            'arm64': 'https://example.invalid/bookworm-arm64.tar.gz',
          }
        },
      });
      final dio = Dio()..httpClientAdapter = adapter;

      final links =
          await App(dio: dio).getDistroLinks(architecture: rootfsArmFamily);

      expect(links, {'Debian 12': 'https://example.invalid/bookworm-arm64.tar.gz'});
      expect(adapter.requested, contains(gitRepoRawLink));
    });

    test('the same CDN copy is used as it is on an Intel machine', () async {
      final adapter = _CatalogueAdapter({
        gitRepoLink: {'Debian 12': 'https://example.invalid/bookworm-amd64.tar.gz'},
      });
      final dio = Dio()..httpClientAdapter = adapter;

      final links =
          await App(dio: dio).getDistroLinks(architecture: rootfsX86Family);

      expect(links, {'Debian 12': 'https://example.invalid/bookworm-amd64.tar.gz'});
      expect(adapter.requested, [gitRepoLink]);
    });

    test('a catalogue served as text is still read', () async {
      final adapter = _CatalogueAdapter({
        gitRepoLink: jsonEncode({
          'Debian 12': {'arm64': 'https://example.invalid/bookworm-arm64.tar.gz'}
        }),
      });
      final dio = Dio()..httpClientAdapter = adapter;

      final links =
          await App(dio: dio).getDistroLinks(architecture: rootfsArmFamily);

      expect(links, {'Debian 12': 'https://example.invalid/bookworm-arm64.tar.gz'});
    });
  });

  group('manifestForArchitecture', () {
    final manifests = [
      _manifest('sha256:windows', 'amd64', 'windows'),
      _manifest('sha256:intel', 'amd64', 'linux'),
      _manifest('sha256:arm32', 'arm', 'linux'),
      _manifest('sha256:arm', 'arm64', 'linux'),
    ];

    test('an ARM machine takes the arm64 image', () {
      expect(manifestForArchitecture(manifests, rootfsArmFamily)?.digest,
          'sha256:arm');
    });

    test('an Intel machine takes the Linux amd64 image, not the Windows one',
        () {
      expect(manifestForArchitecture(manifests, rootfsX86Family)?.digest,
          'sha256:intel');
    });

    test('an unknown machine takes the Intel image', () {
      expect(manifestForArchitecture(manifests, '')?.digest, 'sha256:intel');
    });

    test('32-bit arm is not offered to an arm64 machine', () {
      final noArm64 = [
        _manifest('sha256:intel', 'amd64', 'linux'),
        _manifest('sha256:arm32', 'arm', 'linux'),
      ];
      expect(manifestForArchitecture(noArm64, rootfsArmFamily), isNull);
    });

    test('an image with no entry for this machine reports nothing', () {
      expect(
          manifestForArchitecture(
              [_manifest('sha256:intel', 'amd64', 'linux')], rootfsArmFamily),
          isNull);
    });

    test('dockerArchitectureName spells the families the Go way', () {
      expect(dockerArchitectureName(rootfsArmFamily), 'arm64');
      expect(dockerArchitectureName(rootfsX86Family), 'amd64');
      expect(dockerArchitectureName(''), 'amd64');
    });
  });
}
