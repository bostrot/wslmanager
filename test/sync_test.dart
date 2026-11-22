import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/components/sync.dart';

import 'mocks.dart';

void main() {
  late MockShell mockShell;
  late WSLApi wslApi;
  late MockChunkedDownloader mockDownloader;
  late MockHttpServer mockServer;
  late Directory tempDir;

  void statusMsg(
    String msg, {
    Duration? duration,
    dynamic severity = "",
    bool loading = false,
    bool useWidget = false,
    bool leadingIcon = true,
    dynamic widget,
  }) {}

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_test');

    SharedPreferences.setMockInitialValues({
      'SyncIP': '192.168.1.100',
      'Path_test': tempDir.path,
    });
    prefs = await SharedPreferences.getInstance();

    Notify.message = statusMsg;

    mockShell = MockShell();
    wslApi = WSLApi(shell: mockShell);
    mockDownloader = MockChunkedDownloader();
    mockServer = MockHttpServer();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('Sync.startServer starts server', () async {
    final vhdx = File('${tempDir.path}/ext4.vhdx');
    await vhdx.create();

    final sync = Sync.instance(
      'test',
      wslApi: wslApi,
      serverFactory: (handler, address, port) async {
        return mockServer;
      },
    );

    await sync.startServer();
    expect(Sync.server, mockServer);

    sync.stopServer();
    expect(mockServer.closed, true);
  });

  test('Sync.download downloads file', () async {
    final vhdx = File('${tempDir.path}/ext4.vhdx');
    final vhdxTmp = File('${tempDir.path}/ext4.vhdx.tmp');
    await vhdx.create();
    await vhdxTmp.create();

    final syncWithProgress = Sync.instance(
      'test',
      wslApi: wslApi,
      chunkedDownloaderFactory: ({
        required String url,
        required String saveFilePath,
        Map<String, String>? headers,
        int? chunkSize,
        Function(int, int, double)? onProgress,
        Function(File)? onDone,
        Function(dynamic)? onError,
      }) {
        mockDownloader.url = url;
        mockDownloader.saveFilePath = saveFilePath;
        mockDownloader.onProgress = onProgress;
        mockDownloader.done = false;

        Future.delayed(const Duration(milliseconds: 100), () {
          if (onProgress != null) {
            onProgress(100, 100, 1.0);
          }
          mockDownloader.done = true;
        });

        return mockDownloader;
      },
    );

    await syncWithProgress.download();

    expect(mockDownloader.url, 'http://192.168.1.100:59132/ext4.vhdx');

    expect(await File('${tempDir.path}/ext4.vhdx.old').exists(), true);
    expect(await File('${tempDir.path}/ext4.vhdx').exists(), true);
    expect(await File('${tempDir.path}/ext4.vhdx.tmp').exists(), false);
  });
}
