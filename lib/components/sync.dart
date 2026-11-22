import 'dart:io';

import 'package:wsl2distromanager/api/downloader.dart';
import 'package:localization/localization.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'helpers.dart';

typedef ServerFactory = Future<HttpServer> Function(
    Handler handler, Object address, int port);

Future<HttpServer> _defaultServerFactory(
    Handler handler, Object address, int port) {
  return io.serve(handler, address, port);
}

class Sync {
  late String distroName;
  late String distroLocation;
  static late HttpServer server;

  /// The distro currently being served, or null. Static like [server] —
  /// there is one real server — so the per-distro dialog can say which of
  /// start/stop its button will actually do (audit ST-31).
  static String? servingDistro;

  final WSLApi wslApi;
  final ChunkedDownloaderFactory chunkedDownloaderFactory;
  final ServerFactory serverFactory;

  Sync({
    WSLApi? wslApi,
    ChunkedDownloaderFactory? chunkedDownloaderFactory,
    ServerFactory? serverFactory,
  })  : wslApi = wslApi ?? WSLApi(),
        chunkedDownloaderFactory =
            chunkedDownloaderFactory ?? defaultChunkedDownloaderFactory,
        serverFactory = serverFactory ?? _defaultServerFactory;

  /// Constructor
  Sync.instance(
    this.distroName, {
    WSLApi? wslApi,
    ChunkedDownloaderFactory? chunkedDownloaderFactory,
    ServerFactory? serverFactory,
  })  : wslApi = wslApi ?? WSLApi(),
        chunkedDownloaderFactory =
            chunkedDownloaderFactory ?? defaultChunkedDownloaderFactory,
        serverFactory = serverFactory ?? _defaultServerFactory;

  /// Check if distro has path in settings
  bool hasPath(String distroName) {
    return prefs.getString('Path_$distroName') != null ? true : false;
  }

  /// Start the server
  Future<void> startServer() async {
    var handler = createFileHandler(
        getInstancePath(distroName).file('ext4.vhdx'),
        contentType: "application/octet-stream");

    String? syncPassword = prefs.getString('SyncPassword');
    Handler finalHandler = handler;

    if (syncPassword != null && syncPassword.isNotEmpty) {
      finalHandler = const Pipeline().addMiddleware((innerHandler) {
        return (request) {
          if (request.headers['x-sync-password'] != syncPassword) {
            return Response.forbidden('Access denied');
          }
          return innerHandler(request);
        };
      }).addHandler(handler);
    }

    try {
      server = await serverFactory(finalHandler, '0.0.0.0', 59132);
      servingDistro = distroName;
    } catch (e) {
      // Do nothing
    }
  }

  /// Stop the server
  void stopServer() {
    server.close();
    servingDistro = null;
  }

  /// Download from sync IP
  Future<void> download() async {
    String? syncIP = prefs.getString('SyncIP');
    if (syncIP == null) {
      Notify.message('syncipnotset-text'.i18n(),
          severity: InfoBarSeverity.error, loading: false);
      return;
    }
    Notify.message('${'shuttingdownwsl-text'.i18n()}...', loading: true);

    final vhdxPath = getInstancePath(distroName).file('ext4.vhdx');
    final vhdxPathTmp = getInstancePath(distroName).file('ext4.vhdx.tmp');
    final vhdxPathOld = getInstancePath(distroName).file('ext4.vhdx.old');

    await wslApi.shutdown();
    Notify.message('${'connectingtoip-text'.i18n()}: "$syncIP"...',
        loading: true);

    var downloader = chunkedDownloaderFactory(
        url: 'http://$syncIP:59132/ext4.vhdx',
        saveFilePath: vhdxPathTmp,
        headers: prefs.getString('SyncPassword') != null &&
                prefs.getString('SyncPassword')!.isNotEmpty
            ? {'x-sync-password': prefs.getString('SyncPassword')!}
            : null,
        onProgress: (progress, total, speed) {
          String rec = (progress / 1024 / 1024).toStringAsFixed(2);
          String tot = (total / 1024 / 1024).toStringAsFixed(2);
          Notify.message(
              '${'downloading-text'.i18n()} $distroName, $rec MB / $tot MB',
              loading: true);
        },
        onError: (error) {
          Notify.message(
              '${'syncdownloadfailed-text'.i18n([distroName])} '
              '${friendlyErrorReason(error)}'.trim(),
              severity: InfoBarSeverity.error,
              loading: false);
        });

    var response = await downloader.start();

    while (!response.done) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    Notify.message('${'downloaded-text'.i18n()} $distroName',
        severity: InfoBarSeverity.success);
    File oldFile = File(vhdxPath);
    if (await oldFile.exists()) {
      await oldFile.rename(vhdxPathOld);
    }
    File file = File(vhdxPathTmp);
    if (await file.exists()) {
      await file.rename(vhdxPath);
    }
  }
}
