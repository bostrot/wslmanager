import 'dart:io';

import 'package:flutter/foundation.dart';

/// Safe path handling.
class SafePath {
  String _path;
  bool isFile = false;

  /// Create a safe path from [_path].
  /// It will try to create it as a folder if it does not exist.
  ///
  /// Use [exists] when the caller needs to verify creation succeeded.
  SafePath(this._path) {
    // Check if path exists and see if it is a file or a folder
    Directory dir = Directory(_path);
    File file = File(_path);
    bool dirExists = false;
    try {
      dirExists = dir.existsSync();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SafePath: Error checking directory $_path: $e');
      }
    }

    if (!dirExists) {
      bool fileExists = false;
      try {
        fileExists = file.existsSync();
      } catch (e) {
        if (kDebugMode) {
          debugPrint('SafePath: Error checking file $_path: $e');
        }
      }

      if (fileExists) {
        isFile = true;
      } else {
        // Create path
        try {
          dir.createSync(recursive: true);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('SafePath: Could not create directory $_path: $e');
          }
        }
      }
    }

    // Set path
    if (isFile) {
      _path = file.path;
    } else {
      _path = dir.path;
    }
  }

  /// Get the path.
  String get path => _path;

  /// Whether the resolved path currently exists.
  bool get exists {
    try {
      return isFile ? File(_path).existsSync() : Directory(_path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Get the parent path.
  /// If it is a file, the parent folder will be returned.
  String get parent {
    if (isFile) {
      return File(_path).parent.path;
    } else {
      return Directory(_path).parent.path;
    }
  }

  /// Change directory to parent folder.
  /// If it is a file, the parent folder will be returned.
  /// Returns the new path.
  void cdUp() {
    if (isFile) {
      // Do nothing
    } else {
      _path = Directory(_path).parent.path;
    }
  }

  /// Get a file path from [name] if it is a folder.
  /// If it is a file, the file path will be returned.
  String file(String name) {
    if (isFile) {
      return _path;
    } else {
      return File('$_path${Platform.pathSeparator}$name').path;
    }
  }

  /// Change directory to subfolder [name].
  /// It will be created if it does not exist.
  /// If it is a file, the parent folder will be returned.
  /// Returns the new path.
  void cd(String name) {
    if (isFile) {
      // Do nothing
    } else {
      String path = '$_path${Platform.pathSeparator}$name';
      // Check if path exists
      Directory dir = Directory(path);
      bool dirExists = false;
      try {
        dirExists = dir.existsSync();
      } catch (_) {}

      if (!dirExists) {
        // Create path
        try {
          dir.createSync(recursive: true);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('SafePath: Could not create directory $path: $e');
          }
        }
      }
      _path = dir.path;
    }
  }
}
