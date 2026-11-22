/// Tests for the safe_paths class.
@TestOn('windows')
library safepaths_test;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/safe_paths.dart';

void main() {
  test('SafePath init', () async {
    SafePath safePath = SafePath('C:\\test');
    expect(safePath.path, 'C:\\test');
    // Delete if empty
    if (await Directory(safePath.path).list().isEmpty) {
      Directory(safePath.path).deleteSync();
    }
  });

  test('SafePath dir up', () async {
    SafePath safePath = SafePath('C:\\test\\test2');
    safePath.cdUp();
    expect(safePath.path, 'C:\\test');
    // Delete if empty
    if (await Directory('C:\\test\\test2').list().isEmpty) {
      Directory('C:\\test\\test2').deleteSync();
    }
    if (await Directory(safePath.path).list().isEmpty) {
      Directory(safePath.path).deleteSync();
    }
  });

  test('SafePath cd', () async {
    SafePath safePath = SafePath('C:\\test');
    safePath.cd('test2');
    expect(safePath.path, 'C:\\test\\test2');
    // Delete if empty
    if (await Directory(safePath.path).list().isEmpty) {
      Directory(safePath.path).deleteSync();
    }
    if (await Directory('C:\\test').list().isEmpty) {
      Directory('C:\\test').deleteSync();
    }
  });

  test('SafePath file', () async {
    SafePath safePath = SafePath('C:\\test');
    // Create file test2 in test
    File file = File('C:\\test\\test2');
    file.createSync();
    expect(safePath.file('test2'), 'C:\\test\\test2');
    // Delete file
    file.deleteSync();
    // Delete if empty
    if (await Directory(safePath.path).list().isEmpty) {
      Directory(safePath.path).deleteSync();
    }
  });

  test('SafePath parent', () async {
    SafePath safePath = SafePath('C:\\test\\test2');
    expect(safePath.parent, 'C:\\test');
    // Delete if empty
    if (await Directory(safePath.path).list().isEmpty) {
      Directory(safePath.path).deleteSync();
    }
    if (await Directory('C:\\test').list().isEmpty) {
      Directory('C:\\test').deleteSync();
    }
  });

  test('SafePath creation and normalization', () async {
    String path = 'C:/test_safepath_creation';
    // Ensure clean state
    if (Directory(path).existsSync()) {
      Directory(path).deleteSync(recursive: true);
    }

    SafePath safePath = SafePath(path);
    expect(Directory(path).existsSync(), true);
    // Expect path to match
    expect(safePath.path.replaceAll('/', '\\'), path.replaceAll('/', '\\'));

    Directory(path).deleteSync();
  });

  test('SafePath non-existent path cleanup', () {
    // Should not throw even if the target path doesn't exist.
    // Use a unique directory under the system temp folder to avoid touching real drives.
    final Directory baseTempDir =
        Directory.systemTemp.createTempSync('safepath_non_existent_');
    final String path = '${baseTempDir.path}\\non_existent_path_test_12345';
    try {
      SafePath safePath = SafePath(path);
      expect(safePath.path, path);
    } finally {
      // Clean up any directories created by the test.
      final Directory targetDir = Directory(path);
      if (targetDir.existsSync()) {
        targetDir.deleteSync(recursive: true);
      }
      if (baseTempDir.existsSync()) {
        baseTempDir.deleteSync(recursive: true);
      }
    }
  });

  test('SafePath special characters', () {
    // Using the character from the issue: ¤
    final baseTempDir = Directory.systemTemp.createTempSync('safepath_special_');
    String path = '${baseTempDir.path}\\test_special_¤_char';
    Directory(path).createSync(recursive: true);

    try {
      SafePath safePath = SafePath(path);
      expect(safePath.path, path);
      expect(Directory(path).existsSync(), true);
    } finally {
      if (baseTempDir.existsSync()) {
        baseTempDir.deleteSync(recursive: true);
      }
    }
  });

  test('SafePath unicode characters', () {
    // Unicode characters
    final baseTempDir = Directory.systemTemp.createTempSync('safepath_unicode_');
    String path = '${baseTempDir.path}\\test_unicode_😊';
    Directory(path).createSync(recursive: true);

    try {
      SafePath safePath = SafePath(path);
      expect(safePath.path, path);
    } finally {
      if (baseTempDir.existsSync()) {
        baseTempDir.deleteSync(recursive: true);
      }
    }
  });

  test('SafePath file with special characters', () {
    final baseTempDir = Directory.systemTemp.createTempSync('safepath_file_special_');
    String folder = '${baseTempDir.path}\\test_special_¤_folder';
    Directory(folder).createSync(recursive: true);
    String filePath = '$folder\\test_file.txt';
    File(filePath).writeAsStringSync('test');

    try {
      SafePath safePath = SafePath(filePath);
      expect(safePath.path, filePath);
    } finally {
      if (baseTempDir.existsSync()) {
        baseTempDir.deleteSync(recursive: true);
      }
    }
  });

  test('SafePath isFile: parent returns folder', () {
    final dir = Directory.systemTemp.createTempSync('safepath_file_parent_');
    final filePath = '${dir.path}\\testfile.txt';
    File(filePath).writeAsStringSync('data');
    try {
      SafePath safePath = SafePath(filePath);
      expect(safePath.isFile, true);
      expect(safePath.parent, dir.path);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('SafePath isFile: file() returns own path', () {
    final dir = Directory.systemTemp.createTempSync('safepath_file_file_');
    final filePath = '${dir.path}\\testfile.txt';
    File(filePath).writeAsStringSync('data');
    try {
      SafePath safePath = SafePath(filePath);
      expect(safePath.isFile, true);
      // file() on an isFile path should return _path regardless of name argument
      expect(safePath.file('anything'), filePath);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('SafePath isFile: cdUp does nothing', () {
    final dir = Directory.systemTemp.createTempSync('safepath_file_cdup_');
    final filePath = '${dir.path}\\testfile.txt';
    File(filePath).writeAsStringSync('data');
    try {
      SafePath safePath = SafePath(filePath);
      expect(safePath.isFile, true);
      safePath.cdUp();
      expect(safePath.path, filePath);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('SafePath isFile: cd does nothing', () {
    final dir = Directory.systemTemp.createTempSync('safepath_file_cd_');
    final filePath = '${dir.path}\\testfile.txt';
    File(filePath).writeAsStringSync('data');
    try {
      SafePath safePath = SafePath(filePath);
      expect(safePath.isFile, true);
      safePath.cd('subdir');
      expect(safePath.path, filePath);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('SafePath chained cd creates nested directories', () {
    final base = Directory.systemTemp.createTempSync('safepath_chained_');
    try {
      SafePath safePath = SafePath(base.path);
      safePath.cd('level1');
      safePath.cd('level2');
      safePath.cd('level3');
      expect(Directory(safePath.path).existsSync(), true);
      expect(safePath.path, endsWith('level3'));
    } finally {
      base.deleteSync(recursive: true);
    }
  });

  test('SafePath forward slashes are accepted', () {
    final base = Directory.systemTemp.createTempSync('safepath_fwdslash_');
    final path = base.path.replaceAll('\\', '/');
    try {
      SafePath safePath = SafePath(path);
      // Path should resolve to an existing directory regardless of slash style
      expect(Directory(safePath.path).existsSync(), true);
    } finally {
      base.deleteSync(recursive: true);
    }
  });
}
