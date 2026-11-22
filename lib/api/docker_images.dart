import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:wsl2distromanager/api/downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/layer_processor.dart';
import 'package:wsl2distromanager/api/rootfs_architecture.dart';
import 'package:wsl2distromanager/api/safe_paths.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// API to download docker images from DockerHub and extract them
/// into a rootfs.
class Manifests {
  List<Manifest> manifests = [];
  String mediaType = '';
  int schemaVersion = 2;

  Manifests(
      {required this.manifests,
      required this.mediaType,
      required this.schemaVersion});

  factory Manifests.fromMap(Map<String, dynamic> map) => Manifests(
      manifests:
          List<Manifest>.from(map["manifests"].map((x) => Manifest.fromMap(x))),
      mediaType: map["mediaType"],
      schemaVersion: map["schemaVersion"]);
}

class Manifest {
  String digest = '';
  String mediaType = '';
  PlatformManifest? platform;
  int size = 0;

  Manifest(
      {required this.digest,
      required this.mediaType,
      this.platform,
      required this.size});

  Manifest.empty();

  Manifest.fromMap(Map<String, dynamic> map) {
    digest = map["digest"];
    mediaType = map["mediaType"];
    if (map["platform"] != null) {
      platform = PlatformManifest.fromMap(map["platform"]);
    }
    size = map["size"];
  }
}

class ImageManifestV1 {
  int schemaVersion = 1;
  String name = '';
  String tag = '';
  String architecture = '';
  List fsLayers = [];
  List history = [];
  List signatures = [];

  ImageManifestV1(
      {required this.schemaVersion,
      required this.name,
      required this.tag,
      required this.architecture,
      required this.fsLayers,
      required this.history,
      required this.signatures});

  factory ImageManifestV1.fromMap(Map<String, dynamic> map) => ImageManifestV1(
      schemaVersion: map["schemaVersion"],
      name: map["name"],
      tag: map["tag"],
      architecture: map["architecture"],
      fsLayers: List.from(map["fsLayers"]),
      history: List.from(map["history"]),
      signatures: List.from(map["signatures"]));
}

class ImageManifest {
  Config config = Config.empty();
  List<Manifest> layers = [];
  String mediaType = '';
  int schemaVersion = 2;

  ImageManifest(
      {required this.config,
      required this.layers,
      required this.mediaType,
      required this.schemaVersion});

  factory ImageManifest.fromMap(Map<String, dynamic> map) => ImageManifest(
      config: Config.fromMap(map["config"]),
      layers:
          List<Manifest>.from(map["layers"].map((x) => Manifest.fromMap(x))),
      mediaType: map["mediaType"],
      schemaVersion: map["schemaVersion"]);
}

class Config {
  String mediaType = '';
  String digest = '';
  int size = 0;

  Config({required this.mediaType, required this.digest, required this.size});
  Config.empty();

  factory Config.fromMap(Map<String, dynamic> map) => Config(
      mediaType: map["mediaType"], digest: map["digest"], size: map["size"]);
}

class PlatformManifest {
  String architecture = '';
  String os = '';

  PlatformManifest({required this.architecture, required this.os});

  factory PlatformManifest.fromMap(Map<String, dynamic> map) =>
      PlatformManifest(architecture: map["architecture"], os: map["os"]);
}

/// What Docker calls the architecture of [family] — the Go spelling, which is
/// what a manifest list uses. An unknown machine is served the Intel image,
/// the way the whole catalogue is.
String dockerArchitectureName(String family) =>
    family == rootfsArmFamily ? 'arm64' : 'amd64';

/// The manifest a multi-architecture tag offers for [family], or null when it
/// offers nothing that can run there.
///
/// The pick is explicit rather than "the first entry with that architecture":
/// a tag routinely also carries Windows images, which this app cannot import
/// into WSL, and 32-bit `arm` is not a substitute for `arm64` — WSL on a
/// Windows-on-ARM machine is 64-bit only. Before this there was no pick at
/// all: the amd64 entry was taken on every machine, so a Docker distro on such
/// a machine imported an image whose binaries it could not run.
Manifest? manifestForArchitecture(List<Manifest> manifests, String family) {
  final wanted = dockerArchitectureName(family);
  for (final entry in manifests) {
    final platform = entry.platform;
    if (platform == null || platform.architecture != wanted) continue;
    // An entry that does not say which OS it is for is taken at its word.
    if (platform.os.isNotEmpty && platform.os != 'linux') continue;
    if (entry.digest.isEmpty) continue;
    return entry;
  }
  return null;
}

typedef ProgressCallback = void Function(int count, int total);
typedef TotalProgressCallback = void Function(
    int count, int total, int countStep, int totalStep);

class DockerImage {
  String registryUrl;
  String authUrl;
  String svcUrl;
  String? distroName;
  final Dio dio;
  final ChunkedDownloaderFactory chunkedDownloaderFactory;

  DockerImage(
      {Dio? dio,
      ChunkedDownloaderFactory? chunkedDownloaderFactory,
      String? registryUrl,
      this.authUrl = 'https://auth.docker.io/token',
      this.svcUrl = 'registry.docker.io'})
      : dio = dio ?? Dio(),
        registryUrl = registryUrl ??
            prefs.getString('DockerRepoLink') ??
            'https://registry-1.docker.io',
        chunkedDownloaderFactory =
            chunkedDownloaderFactory ?? defaultChunkedDownloaderFactory {
    String? mirror = prefs.getString('DockerMirror');
    if (mirror != null && mirror.isNotEmpty) {
      this.registryUrl = mirror;
    }
  }

  /// Setup registry and auth for custom images
  Future<String> _setupRegistry(String image) async {
    final parts = image.split('/');
    if (parts.length > 1 &&
        (parts[0].contains('.') ||
            parts[0].contains(':') ||
            parts[0] == 'localhost')) {
      String registry = parts[0];
      String repo = parts.sublist(1).join('/');

      // Update registry URL
      if (!registry.startsWith('http')) {
        registryUrl = 'https://$registry';
      } else {
        registryUrl = registry;
      }

      // Discover auth endpoint
      try {
        await dio.get('$registryUrl/v2/');
      } on DioException catch (e) {
        if (e.response?.statusCode == 401) {
          final authHeader = e.response?.headers.value('www-authenticate');
          if (authHeader != null) {
            final realmMatch =
                RegExp(r'realm="([^"]+)"').firstMatch(authHeader);
            final serviceMatch =
                RegExp(r'service="([^"]+)"').firstMatch(authHeader);

            if (realmMatch != null) {
              authUrl = realmMatch.group(1)!;
            }
            if (serviceMatch != null) {
              svcUrl = serviceMatch.group(1)!;
            } else {
              svcUrl = '';
            }
          }
        }
      }
      return repo;
    }
    return image;
  }

  /// Get auth token
  Future<String> _authenticate(String image) async {
    Uri uri = Uri.parse(authUrl);
    Map<String, String> queryParameters = Map.from(uri.queryParameters);
    queryParameters['scope'] = 'repository:$image:pull';
    if (svcUrl.isNotEmpty) {
      queryParameters['service'] = svcUrl;
    }
    uri = uri.replace(queryParameters: queryParameters);

    Response<dynamic> response = await dio.get(uri.toString());
    if (response.data == null) {
      throw Exception('No response data');
    }
    final token = response.data['token'];
    if (token == null) {
      throw Exception('No token found');
    }
    return token as String;
  }

  /// Get manifest
  Future<dynamic> _getManifest(
      String image, String token, String? digest) async {
    if (!image.contains("/")) {
      image = "library/$image";
    }
    Response<dynamic> response = await dio.get(
      '$registryUrl/v2/$image/manifests/${digest ?? 'latest'}', // https://registry-1.docker.io/v2/nginx/manifests/latest
      // accept application/json
      options: Options(headers: {
        'Authorization': 'Bearer $token',
        // see https://github.com/opencontainers/image-spec/blob/main/media-types.md#oci-image-media-types
        'Accept': 'application/vnd.oci.descriptor.v1+json,'
            'application/vnd.oci.descriptor.v1+json,'
            'application/vnd.oci.layout.header.v1+json,'
            'application/vnd.oci.image.index.v1+json,'
            'application/vnd.oci.image.manifest.v1+json,'
            'application/vnd.oci.image.config.v1+json,'
            'application/vnd.oci.image.layer.v1.tar,'
            'application/vnd.oci.image.layer.v1.tar+gzip,'
            'application/vnd.oci.image.layer.v1.tar+zstd,'
            'application/vnd.oci.artifact.manifest.v1+json'
      }),
    );
    if (response.data == null) {
      throw Exception('No response data');
    }
    return response.data;
  }

  /// Download blob to file
  Future<bool> _downloadBlob(String image, String token, String digest,
      String file, ProgressCallback progressCallback) async {
    var downloader = chunkedDownloaderFactory(
      url: '$registryUrl/v2/$image/blobs/$digest',
      saveFilePath: file,
      headers: {
        'Authorization': 'Bearer $token',
      },
      onProgress: (progress, total, speed) => progressCallback(progress, total),
      onDone: (file) {
        if (kDebugMode) {
          print('Download complete: $file');
        }
      },
      onError: (error) => throw Exception('Download failed $error'),
    );

    downloader.start();

    while (!downloader.done) {
      await Future.delayed(const Duration(milliseconds: 1000));
    }
    return true;
  }

  /// Download image
  Future<String> _download(
      String image, String path, TotalProgressCallback progressCallback,
      {String? tag}) async {
    // Handle custom registry
    image = await _setupRegistry(image);

    // Get token
    final token = await _authenticate(image);

    var manifestData = await _getManifest(image, token, tag ?? 'latest');
    dynamic imageManifest;

    // TODO: When the manifest is in hand, the client must verify the signature to ensure the names and layers are valid.

    // Check if manifestData is a string
    if (manifestData is String) {
      // Get manifest
      manifestData = json.decode(manifestData);
    }

    // For logging
    Object? exception;
    StackTrace? stacktrace;

    // Multiple architectures per tag
    if (manifestData['manifests'] != null) {
      // Get manifest
      final data = Manifests.fromMap(manifestData);

      // Find the digest for this machine's architecture
      final family = rootfsHostArchitecture();
      final manifest = manifestForArchitecture(data.manifests, family);
      if (manifest == null) {
        logError(
            StateError('$image has no ${dockerArchitectureName(family)} image'),
            StackTrace.current,
            null);
        return "false";
      }
      final digest = manifest.digest;

      // Download the blob for that architecture
      if (kDebugMode) {
        print('Downloading $image ${dockerArchitectureName(family)} blob');
      }
      try {
        imageManifest =
            ImageManifest.fromMap(await _getManifest(image, token, digest));

        final config = imageManifest.config.digest;
        final configPath = SafePath(path).file('config.json');
        await _downloadBlob(image, token, config, configPath, (p0, p1) {});

        // Parse config.json for metadata (V2)
        try {
          if (await File(configPath).exists()) {
            final configContent = await File(configPath).readAsString();
            final configJson = json.decode(configContent);

            if (configJson['config'] != null) {
              final parsedConfig = configJson['config'];
              final env = parsedConfig['Env'];
              final cmd = parsedConfig['Cmd'];
              final entrypoint = parsedConfig['Entrypoint'];
              final user = parsedConfig['User'];

              // Handle User
              if (user != null && user is String && user.isNotEmpty) {
                var userStr = user;
                if (userStr.contains(':')) {
                  userStr = userStr.split(':')[0];
                }
                if (int.tryParse(userStr) == null) {
                  prefs.setString('StartUser_$distroName', userStr);
                } else {
                  Notify.message('dockerusernumber-text'.i18n(),
                      severity: InfoBarSeverity.warning);
                }
              }

              // Handle Env, Entrypoint, Cmd
              var entrypointCmd = '';
              if (entrypoint != null && entrypoint is List) {
                entrypointCmd = entrypoint.map((e) => e.toString()).join(' ');
              }

              String exportEnv = '';
              if (env != null && env is List) {
                exportEnv = env.map((e) => 'export $e;').join(' ');
              }

              // Use distroName for StartCmd so it applies to the instance
              if (cmd != null && cmd is List) {
                prefs.setString('StartCmd_$distroName',
                    '$exportEnv $entrypointCmd; ${cmd.map((e) => e.toString()).join(' ')}');
              } else if (entrypointCmd.isNotEmpty) {
                prefs.setString(
                    'StartCmd_$distroName', '$exportEnv $entrypointCmd');
              }
            }

            // Handle history for UserCmds/GroupCmds
            // These need to be saved under image filename to be picked up by create_dialog
            String imageName = filename(image, tag);
            List<String> userCmds = [];
            List<String> groupCmds = [];

            if (configJson['history'] != null &&
                configJson['history'] is List) {
              for (var item in configJson['history']) {
                final createdBy = item['created_by'] as String?;
                if (createdBy != null) {
                  if (createdBy.contains('adduser') ||
                      createdBy.contains('useradd')) {
                    userCmds.add(createdBy);
                  }
                  if (createdBy.contains('groupadd') ||
                      createdBy.contains('addgroup')) {
                    groupCmds.add(createdBy);
                  }
                }
              }
            }
            prefs.setStringList('UserCmds_$imageName', userCmds);
            prefs.setStringList('GroupCmds_$imageName', groupCmds);
          }
        } catch (e, stack) {
          logDebug(e, stack, 'Failed to parse V2 config');
        }
      } catch (e, stackTrace) {
        if (kDebugMode) {
          print(e);
        }
        logError(e, stackTrace, null);
        return "false";
      }
    } else {
      // Single architecture
      try {
        imageManifest = ImageManifest.fromMap(manifestData);
      } catch (e, stack) {
        exception = e;
        stacktrace = stack;
      }
      try {
        imageManifest = ImageManifestV1.fromMap(manifestData);
      } catch (e, stack) {
        exception = e;
        stacktrace = stack;
      }
    }

    if (imageManifest is ImageManifest) {
      // Download layers
      final layers = imageManifest.layers;
      for (var i = 0; i < layers.length; i++) {
        final digest = layers[i].digest;
        if (kDebugMode) {
          print('Downloading $image layer ${i + 1} of ${layers.length}');
        }
        progressCallback(i, layers.length, 0, 100);
        await _downloadBlob(
            image, token, digest, SafePath(path).file('layer_$i.tar.gz'),
            (currentStep, totalStep) {
          progressCallback(i, layers.length, currentStep, totalStep);
        });
      }
    } else if (imageManifest is ImageManifestV1) {
      // Get ENV
      final config = imageManifest.history.first;
      // Parse
      final parsedConfig = json.decode(config["v1Compatibility"]);
      var parsedConfig2 = parsedConfig["config"];
      final env = parsedConfig2["Env"];
      final cmd = parsedConfig2["Cmd"];

      // Check if adduser or groupadd is in one of the commands
      List<String> userCmds = [];
      List<String> groupCmds = [];
      for (var item in imageManifest.history) {
        try {
          if (item["v1Compatibility"] == null) {
            continue;
          }
          item = json.decode(item["v1Compatibility"]);
          if (item["container_config"] == null) {
            continue;
          }
          item["container_config"]["Cmd"].forEach((element) {
            // User commands
            if (element.contains("adduser") || element.contains("useradd")) {
              userCmds.add(element);
            }
            // Group commands
            if (element.contains("groupadd") || element.contains("addgroup")) {
              groupCmds.add(element);
            }
            // Default user
            if (element.contains("USER")) {
              var user = element.split(' ')[1];
              if (user.contains(':')) {
                user = user.split(':')[0];
              }
              user = int.tryParse(user) ?? user;
              if (user is String) {
                // Add to shared preferences
                prefs.setString('StartUser_$distroName', user);
              } else {
                // User is a number
                // TODO: implement docker user is a number
                Notify.message('dockerusernumber-text'.i18n(),
                    severity: InfoBarSeverity.warning);
              }
            }
          });
        } catch (e, stacktrace) {
          if (kDebugMode) {
            print(e);
          }
          logDebug(e, stacktrace, null);
        }
      }

      // Check if it has an entrypoint
      final entrypoint = parsedConfig2["Entrypoint"];
      var entrypointCmd = '';
      if (entrypoint != null && entrypoint is List) {
        entrypointCmd = entrypoint.map((e) => e).join(' ');
      }
      // Create export env command
      final exportEnv = env.map((e) => 'export $e;').join(' ');

      // Set image specific commands
      String name = filename(image, tag);
      if (cmd != null) {
        prefs.setString('StartCmd_$distroName',
            '$exportEnv $entrypointCmd; ${cmd.join(' ')}');
      }
      prefs.setStringList('UserCmds_$name', userCmds);
      prefs.setStringList('GroupCmds_$name', groupCmds);

      // Download layers
      final layers = imageManifest.fsLayers;
      for (var i = 0; i < layers.length; i++) {
        final digest = layers[i]["blobSum"];

        if (kDebugMode) {
          print('Downloading $image layer ${i + 1} of ${layers.length}');
        }
        progressCallback(i, layers.length, 0, 100);
        await _downloadBlob(
            image, token, digest, SafePath(path).file('layer_$i.tar.gz'),
            (currentStep, totalStep) {
          progressCallback(i, layers.length, currentStep, totalStep);
        });
      }
    } else {
      Notify.message('unknownmanifest-text'.i18n(),
          severity: InfoBarSeverity.error);
      logError(exception ?? "No exception", stacktrace ?? StackTrace.current,
          imageManifest.toString());
      return "false";
    }

    return "true";
  }

  /// Putting layers into single tar file
  Future<bool> getRootfs(String name, String image,
      {String? tag,
      required TotalProgressCallback progress,
      bool skipDownload = false}) async {
    distroName = name;
    var distroPath = getDistroPath().path;

    // Add library to image name
    if (image.split('/').length == 1) {
      image = 'library/$image';
    }

    // Replace special chars
    final imageName = filename(image, tag);
    final tmpImagePath = (getTmpPath()..cd(imageName)).path;

    // Create distro folder

    var layers = 0;

    if (!skipDownload) {
      String result = await _download(image, tmpImagePath,
          (current, total, currentStep, totalStep) {
        layers = total;
        if (kDebugMode) {
          print('${current + 1}/$total');
        }
        progress(current, total, currentStep, totalStep);
      }, tag: tag);

      if (result == "false") {
        throw Exception("Download failed");
      }

      // Ensure downloads have actually finished before proceeding to extraction.
      // Poll for the expected layer files in the temporary image path with a timeout.
      final parent = SafePath(tmpImagePath);
      final timeout = const Duration(minutes: 5);
      final pollInterval = const Duration(milliseconds: 500);
      final startTime = DateTime.now();

      if (layers > 0) {
        while (true) {
          var allExist = true;
          for (var i = 0; i < layers; i++) {
            if (!File(parent.file('layer_$i.tar.gz')).existsSync()) {
              allExist = false;
              break;
            }
          }
          if (allExist) {
            break;
          }
          if (DateTime.now().difference(startTime) > timeout) {
            throw Exception('Download did not complete within timeout');
          }
          await Future.delayed(pollInterval);
        }
      } else {
        // If layer count was not reported, wait for at least one layer or config.json to appear.
        while (true) {
          final hasLayer0 = File(parent.file('layer_0.tar.gz')).existsSync();
          final hasConfig = File(parent.file('config.json')).existsSync();
          if (hasLayer0 || hasConfig) {
            break;
          }
          if (DateTime.now().difference(startTime) > timeout) {
            throw Exception(
                'Download did not produce expected files within timeout');
          }
          await Future.delayed(pollInterval);
        }
      }
    }

    Notify.message('extractinglayersall-text'.i18n());

    // Extract layers
    // Write the compressed tar file to disk.
    int retry = 0;

    final parentPath = SafePath(tmpImagePath);
    String outTarGz = SafePath(distroPath).file('$imageName.tar.gz');
    while (retry < 2) {
      try {
        List<String> layerPaths = [];
        for (var i = 0; i < layers; i++) {
          layerPaths.add(parentPath.file('layer_$i.tar.gz'));
        }

        await LayerProcessor()
            .mergeLayers(layerPaths, outTarGz, (msg) => Notify.message(msg));

        retry = 2;
        break;
      } catch (e, stackTrace) {
        retry++;
        if (retry == 2) {
          logDebug(e, stackTrace, null);
          Notify.message('mergelayersfailed-text'.i18n(),
              severity: InfoBarSeverity.error);
          return false;
        }
        await Future.delayed(const Duration(seconds: 1));
        if (kDebugMode) {
          print('Retrying $retry');
        }
      }
    }

    Notify.message('creatinginstance-text'.i18n());

    // Check if tar file is created
    if (!File(outTarGz).existsSync()) {
      throw Exception('Tar file is not created');
    }
    // Wait for tar file to be created
    await Future.delayed(const Duration(seconds: 1));
    // Cleanup
    await Directory(tmpImagePath).delete(recursive: true);
    return true;
  }

  /// Check if registry has image
  Future<bool> _hasImageOnly(String image) async {
    try {
      await _authenticate(image);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check if registry has image tag
  Future<bool> hasImage(String image, {String? tag}) async {
    image = await _setupRegistry(image);
    bool hasImage = await _hasImageOnly(image);
    if (tag == null) {
      return hasImage;
    }
    try {
      if (!hasImage) {
        return false;
      }
      await _getManifest(image, await _authenticate(image), tag);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Check if image is already downloaded
  Future<bool> isDownloaded(String image, {String? tag = 'latest'}) async {
    return File(getDistroPath().file('${filename(image, tag)}.tar.gz'))
        .existsSync();
  }

  /// Formate image and tag to filename format
  String filename(String image, String? tag) {
    if (image.isEmpty) {
      throw Exception('Image is not valid');
    }
    // Add library to image name
    if (image.split('/').length == 1) {
      image = 'library/$image';
    }
    final filename = image.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    if (tag == null) {
      return filename;
    }
    final tagFilename = tag.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    return '${filename}_$tagFilename';
  }

  /// List local Docker images available on the system.
  /// Returns a list of strings in format "repository:tag" or "<none>:<none>".
  static Future<List<String>> listLocalImages() async {
    final result = await Process.run(
      'docker',
      ['image', 'ls', '--format', '{{.Repository}}:{{.Tag}}'],
    );

    if (result.exitCode != 0) {
      throw Exception('Failed to list Docker images: ${result.stderr}');
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return [];
    }

    return output.split('\n').where((line) => line.isNotEmpty).toList();
  }

  /// Export a local Docker image to a tar file using docker save, then extract
  /// layers for WSL import. Reuses the existing layer processing pipeline.
  Future<bool> getRootfsFromLocalImage(
    String name,
    String imagePath, {
    required TotalProgressCallback progress,
  }) async {
    distroName = name;
    var distroPath = getDistroPath().path;
    final imageName = filename(imagePath.split(':')[0], imagePath.split(':').length > 1 ? imagePath.split(':')[1] : null);
    final tmpImagePath = (getTmpPath()..cd('local_$imageName')).path;

    Notify.message('exportinglocalimage-text'.i18n());

    // Create temp directory for docker save output
    await Directory(tmpImagePath).create(recursive: true);
    final tarFilePath = SafePath(tmpImagePath).file('image.tar');

    // Run docker save to export the image
    if (kDebugMode) {
      print('Running: docker save -o $tarFilePath $imagePath');
    }
    final saveResult = await Process.run(
      'docker',
      ['save', '-o', tarFilePath, imagePath],
    );

    if (saveResult.exitCode != 0) {
      final err = '${saveResult.stderr.toString()}';
      throw Exception('Failed to export Docker image: $err');
    }

    // Parse the docker save tarball to extract layers
    Notify.message('extractinglayersall-text'.i18n());

    await _processDockerSaveTar(
      tarFilePath,
      tmpImagePath,
      imagePath,
      progress,
    );

    final outTarGz = SafePath(distroPath).file('$imageName.tar.gz');

    // Get layer paths from the extracted directory
    List<String> layerPaths = [];
    final parentPath = SafePath(tmpImagePath);
    int i = 0;
    while (File(parentPath.file('layer_$i.tar')).existsSync()) {
      layerPaths.add(parentPath.file('layer_$i.tar'));
      i++;
    }

    if (layerPaths.isEmpty) {
      throw Exception('No layers found in Docker image');
    }

    int retry = 0;
    while (retry < 2) {
      try {
        await LayerProcessor()
            .mergeLayers(layerPaths, outTarGz, (msg) => Notify.message(msg));
        retry = 2;
        break;
      } catch (e, stackTrace) {
        retry++;
        if (retry == 2) {
          logDebug(e, stackTrace, null);
          Notify.message('mergelayersfailed-text'.i18n(),
              severity: InfoBarSeverity.error);
          return false;
        }
        await Future.delayed(const Duration(seconds: 1));
        if (kDebugMode) {
          print('Retrying $retry');
        }
      }
    }

    // Check if tar file is created
    if (!File(outTarGz).existsSync()) {
      throw Exception('Tar file is not created');
    }

    // Cleanup temp directory
    await Directory(tmpImagePath).delete(recursive: true);
    return true;
  }

  /// Process a docker save tarball: parse manifest.json and extract layers.
  Future<void> _processDockerSaveTar(
    String tarPath,
    String outputPath,
    String imagePath,
    TotalProgressCallback progress,
  ) async {
    // Read the tar file bytes
    final tarBytes = File(tarPath).readAsBytesSync();

    // Use archive package v4 to read the tar
    final decoder = TarDecoder().decodeBytes(tarBytes);

    // Find manifest.json
    String? manifestContent;
    for (final file in decoder) {
      if (file.name == 'manifest.json') {
        manifestContent = utf8.decode(file.readBytes()!);
        break;
      }
    }

    if (manifestContent == null) {
      throw Exception('No manifest.json found in docker save archive');
    }

    // Parse manifest.json to get layer info
    final manifestList = json.decode(manifestContent) as List<dynamic>;
    if (manifestList.isEmpty) {
      throw Exception('Empty manifest.json');
    }

    final manifest = manifestList[0] as Map<String, dynamic>;
    final layers = manifest['Layers'] as List<dynamic>;

    // Ensure output directory exists
    await Directory(outputPath).create(recursive: true);

    // Extract each layer from the tar archive
    for (int idx = 0; idx < layers.length; idx++) {
      progress(idx, layers.length, 0, 100);
      final layerRef = layers[idx] as String;
      final layerTarPath = '$layerRef/layer.tar';

      if (kDebugMode) {
        print('Extracting layer $idx: $layerTarPath');
      }

      // Extract this specific layer from the tar
      final outLayerPath = SafePath(outputPath).file('layer_$idx.tar');
      await _extractFileFromTar(tarBytes, layerTarPath, outLayerPath);

      if (!(await File(outLayerPath).exists())) {
        throw Exception('Failed to extract layer $idx: $layerTarPath');
      }
    }

    progress(layers.length - 1, layers.length, 100, 100);
  }

  /// Extract a single file from a tar archive.
  Future<void> _extractFileFromTar(
    List<int> tarBytes,
    String entryName,
    String outputPath,
  ) async {
    final decoder = TarDecoder().decodeBytes(tarBytes);

    for (final file in decoder) {
      if (file.name == entryName) {
        await File(outputPath).writeAsBytes(file.readBytes()!);
        return;
      }
    }

    throw Exception('Entry not found in tar: $entryName');
  }
}
