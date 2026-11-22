// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility that Flutter provides. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

@TestOn('windows')
library dockerimages_test;

import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/docker_images.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/create_dialog.dart';

import 'mocks.dart';

bool useRealIntegrations = Platform.environment['INTEGRATION_TESTS'] == 'true';

void main() {
  void statusMsg(
    String msg, {
    Duration? duration,
    dynamic severity = "",
    bool loading = false,
    bool useWidget = false,
    bool leadingIcon = true,
    dynamic widget,
  }) {}

  // Stuff before tests
  setUpAll(() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    // Pin the distro root: these tests stage rootfs fixtures under
    // C:\WSL2-Distros, so they must not depend on the per-user default
    // storage root (%APPDATA%) that getDistroPath() otherwise falls back to.
    SharedPreferences.setMockInitialValues({'DistroPath': defaultPath});
    await initPrefs();

    Notify();
    Notify.message = statusMsg;
  });

  Future<bool> isInstance(String name, WSLApi api) async {
    bool found = false;
    // Get list
    var list = await api.list(false);
    found = false;

    for (var item in list.all) {
      if (item == name) {
        found = true;
      }
    }
    return found;
  }

  test('Create instance test alpine', () async {
    WSLApi api = useRealIntegrations ? WSLApi() : WSLApi(shell: MockShell());
    DockerImage? dockerImage = useRealIntegrations ? null : MockDockerImage();

    TextEditingController nameController = TextEditingController(text: 'test');
    TextEditingController locationController = TextEditingController(text: '');
    TextEditingController autoSuggestBox =
        TextEditingController(text: 'dockerhub:alpine:latest');

    final file = File('C:/WSL2-Distros/distros/library_alpine_latest.tar.gz');
    if (await file.exists()) {
      await file.delete();
    }

    // Test build context
    await createInstance(
      nameController,
      locationController,
      api,
      autoSuggestBox,
      TextEditingController(text: ''),
      dockerImage: dockerImage,
    );

    expect(await file.exists(), true);
    expect(await file.length(), greaterThan(2 * 1024 * 1024));

    expect(await isInstance('test', api), true);

    await api.remove('test');

    expect(await isInstance('test', api), false);

    await createInstance(
      nameController,
      locationController,
      api,
      autoSuggestBox,
      TextEditingController(text: ''),
      dockerImage: dockerImage,
    );

    expect(await isInstance('test', api), true);

    // Delete the instance
    await api.remove('test');
  });

  test('Create instance test nginx (nonroot)', () async {
    WSLApi api = useRealIntegrations ? WSLApi() : WSLApi(shell: MockShell());
    DockerImage? dockerImage = useRealIntegrations ? null : MockDockerImage();

    TextEditingController nameController = TextEditingController(text: 'test');
    TextEditingController locationController = TextEditingController(text: '');
    TextEditingController autoSuggestBox =
        TextEditingController(text: 'dockerhub:bitnami/nginx:latest');

    final file = File('C:/WSL2-Distros/distros/bitnami_nginx_latest.tar.gz');
    if (await file.exists()) {
      await file.delete();
    }

    // Delete the instance
    await api.remove('test');

    // Test build context
    await createInstance(
      nameController,
      locationController,
      api,
      autoSuggestBox,
      TextEditingController(text: ''),
      dockerImage: dockerImage,
    );

    // Verify that the file exists and has > 2MB
    expect(await file.exists(), true);
    expect(await file.length(), greaterThan(2 * 1024 * 1024));
    expect(await isInstance('test', api), true);

    // Delete the instance
    await api.remove('test');

    expect(await isInstance('test', api), false);

    // Test creating it without re-downloading the rootfs
    await createInstance(
      nameController,
      locationController,
      api,
      autoSuggestBox,
      TextEditingController(text: ''),
      dockerImage: dockerImage,
    );

    expect(await isInstance('test', api), true);

    // Delete the instance
    await api.remove('test');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('Docker rootfs download single layer', () async {
    DockerImage docker =
        useRealIntegrations ? DockerImage() : MockDockerImage();
    const String image = 'library/alpine';
    const String tag = 'latest';
    const String distroPath = 'C:/WSL2-Distros/distros';
    final String filename = docker.filename(image, tag);

    final file = File('$distroPath/$filename.tar.gz');
    if (await file.exists()) {
      await file.delete();
    }

    // Get rootfs
    await docker.getRootfs("test", image, tag: tag,
        progress: ((count, total, countStep, totalStep) {
      if (kDebugMode) {
        print('Downloading $count/$total ($countStep/$totalStep)');
      }
    }));

    // Verify that the file exists and has > 2MB
    expect(await file.exists(), true);
    expect(await file.length(), greaterThan(2 * 1024 * 1024));
  });

// timeout test 2 minutes
  test('Docker rootfs download multi layer', () async {
    DockerImage docker =
        useRealIntegrations ? DockerImage() : MockDockerImage();
    const String image = 'jekyll/jekyll';
    const String tag = 'latest';
    const String distroPath = 'C:/WSL2-Distros/distros';
    final String filename = docker.filename(image, tag);
    // Get rootfs
    await docker.getRootfs("test", image, tag: tag, skipDownload: false,
        progress: ((count, total, countStep, totalStep) {
      if (kDebugMode) {
        print('Downloading $count/$total ($countStep/$totalStep)');
      }
    }));
    final file = File('$distroPath/$filename.tar.gz');

    // Verify that the file exists and has > 2MB
    expect(await file.exists(), true);
    expect(await file.length(), greaterThan(2 * 1024 * 1024));
  }, timeout: const Timeout(Duration(minutes: 10)));

  // Test almalinux latest
  test('Create instance test almalinux:latest', () async {
    WSLApi api = useRealIntegrations ? WSLApi() : WSLApi(shell: MockShell());
    DockerImage? dockerImage = useRealIntegrations ? null : MockDockerImage();

    TextEditingController nameController = TextEditingController(text: 'test');
    TextEditingController locationController = TextEditingController(text: '');
    TextEditingController autoSuggestBox =
        TextEditingController(text: 'dockerhub:almalinux:latest');

    final file =
        File('C:/WSL2-Distros/distros/library_almalinux_latest.tar.gz');
    if (await file.exists()) {
      await file.delete();
    }

    // Delete the instance
    await api.remove('test');

    // Test build context
    await createInstance(
      nameController,
      locationController,
      api,
      autoSuggestBox,
      TextEditingController(text: ''),
      dockerImage: dockerImage,
    );

    // Verify that the file exists and has > 2MB
    expect(await file.exists(), true);
    expect(await file.length(), greaterThan(2 * 1024 * 1024));
    expect(await isInstance('test', api), true);

    // Delete the instance
    await api.remove('test');

    expect(await isInstance('test', api), false);

    // Test creating it without re-downloading the rootfs
    await createInstance(
      nameController,
      locationController,
      api,
      autoSuggestBox,
      TextEditingController(text: ''),
      dockerImage: dockerImage,
    );

    expect(await isInstance('test', api), true);

    // Delete the instance
    await api.remove('test');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
