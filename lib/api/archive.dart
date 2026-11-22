import 'dart:io';

class ArchiveService {
  Future<void> extract(String archivePath, String destinationPath) async {
    await ArchiveApi.extract(archivePath, destinationPath);
  }

  Future<void> merge(List<String> archivePaths, String destinationPath) async {
    await ArchiveApi.merge(archivePaths, destinationPath);
  }

  Future<void> compress(String filePath, String destinationPath) async {
    await ArchiveApi.compress(filePath, destinationPath);
  }
}

/// API for 7-Zip archive operations
class ArchiveApi {
  static const _exe = './7zip/7za.exe';

  /// Extracts the archive at [archivePath] to [destinationPath]
  static Future<void> extract(
      String archivePath, String destinationPath) async {
    // 7zr.exe x layer2.tar.gz -olayer
    // Extract archive
    try {
      await Process.run(_exe, ['x', archivePath, '-o$destinationPath']);
    } catch (e) {
      throw Exception('Failed to extract archive: $e');
    }
  }

  /// Merge the archives at [archivePaths] into [destinationPath]
  static Future<void> merge(
      List<String> archivePaths, String destinationPath) async {
    // Merge archives
    try {
      // remove trailing zeros from the files
      final outputFile = File(destinationPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      for (var i = 0; i < archivePaths.length; i++) {
        final fileName = archivePaths[i];
        // Read file as byte stream
        final file = File(fileName);
        final bytes = await file.readAsBytes();
        final length = bytes.length;

        // Last layer
        if (i == archivePaths.length - 1) {
          await outputFile.writeAsBytes(bytes, mode: FileMode.append);
          break;
        }

        // Remove trailing zeros
        int lastBytePos = 0;
        for (var i = length - 1; i >= 0; i--) {
          if (bytes[i] != 0) {
            lastBytePos = i;
            break;
          }
        }

        // Write to new file
        await outputFile.writeAsBytes(bytes.sublist(0, lastBytePos + 1),
            mode: FileMode.append);
      }
    } catch (e) {
      throw Exception('Failed to merge archives: $e');
    }
  }

  /// Compress the tar archive at [filePath] to [destinationPath]
  static Future<void> compress(String filePath, String destinationPath) async {
    // 7zr.exe a -tgzip full_image.tar.gz full_image.tar
    // Compress tar archive
    try {
      // 7zr.exe a -ttar combined_image.tar merged\*
      await Process.run(_exe, ['a', '-tgzip', destinationPath, filePath]);
    } catch (e) {
      throw Exception('Failed to compress tar archive: $e');
    }
  }
}
