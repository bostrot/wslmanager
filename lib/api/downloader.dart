import 'dart:io';

import 'package:chunked_downloader/chunked_downloader.dart';

/// Builds the [ChunkedDownloader] a download runs on.
///
/// One shape for the three places in the app that fetch a file — the rootfs
/// catalogue ([WSLApi.create]), Docker layers ([DockerImage]) and VHDX sync
/// ([Sync]). It exists so tests can hand those a fake without reaching the
/// network; every parameter past the URL and the destination is optional, so a
/// caller names only what it uses.
///
/// Two properties of the package this indirection has to preserve, because
/// callers get them wrong otherwise:
///
/// * [ChunkedDownloader.start] returns a `Future` that **throws** on a non-2xx
///   response. Awaiting it is what turns a dead URL into an error; a
///   `..start()` cascade drops the exception and leaves `done` false forever.
/// * The package writes to `'$saveFilePath.tmp'` and renames that onto
///   [saveFilePath] itself. Pass the *final* path, not a temp one.
typedef ChunkedDownloaderFactory = ChunkedDownloader Function({
  required String url,
  required String saveFilePath,
  Map<String, String>? headers,
  int? chunkSize,
  Function(int, int, double)? onProgress,
  Function(File)? onDone,
  Function(dynamic)? onError,
});

/// The real downloader. Anything that takes a [ChunkedDownloaderFactory]
/// defaults to this.
ChunkedDownloader defaultChunkedDownloaderFactory({
  required String url,
  required String saveFilePath,
  Map<String, String>? headers,
  int? chunkSize,
  Function(int, int, double)? onProgress,
  Function(File)? onDone,
  Function(dynamic)? onError,
}) {
  return ChunkedDownloader(
    url: url,
    saveFilePath: saveFilePath,
    headers: headers,
    chunkSize: chunkSize ?? 1024 * 1024,
    onProgress: onProgress,
    onDone: onDone,
    onError: onError,
  );
}
