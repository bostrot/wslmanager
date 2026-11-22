/// Simple file-based logging and error reporting

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/constants.dart';

/// Get log file path
String getLogFilePath() {
  final env = Platform.environment;
  late final String baseDir;

  if (Platform.isWindows) {
    baseDir = env['APPDATA'] ??
        '${env['USERPROFILE'] ?? Directory.current.path}\\AppData\\Roaming';
  } else if (Platform.isLinux) {
    final home = env['HOME'] ?? Directory.current.path;
    baseDir = env['XDG_STATE_HOME'] ?? '$home/.local/state';
  } else if (Platform.isMacOS) {
    final home = env['HOME'] ?? Directory.current.path;
    baseDir = '$home/Library/Logs';
  } else {
    baseDir = Directory.current.path;
  }

  final logsDir = Directory(
      '$baseDir${Platform.pathSeparator}com.bostrot${Platform.pathSeparator}WSL Distro Manager');
  if (!logsDir.existsSync()) {
    logsDir.createSync(recursive: true);
  }
  return '${logsDir.path}${Platform.pathSeparator}wslmanager_01.log';
}

/// Initialize logging
Future<void> initLogging() async {
  // Log file
  var logfile = File(getLogFilePath());
  // Delete if file is larger than 1MB
  if (await logfile.exists() && await logfile.length() > 10 * 1024 * 1024) {
    await logfile.delete();
  }

  // File does not contain current version
  if (await logfile.exists() &&
      !(await logfile.readAsString()).contains(currentVersion)) {
    await logfile.delete();
  }

  // Check if file exists
  if (!await logfile.exists()) {
    await logfile.create();
    // Write header with version info and OS info
    await logfile.writeAsString(
        'WSL Manager v$currentVersion on ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}\r\n\r\n'
        '============================================================'
        '\r\n\r\n');
  }
}

/// Log a debug message to file
void logDebug(Object error, StackTrace? stack, String? library) {
  // Log to file
  logInfo('$error at $stack in $library');
}

/// Log a message to file
void logInfo(String msg) {
  // Append to file
  File(getLogFilePath()).writeAsStringSync(msg, mode: FileMode.append);
}

/// Log an error to file
void logError(Object error, StackTrace? stack, String? library) {
  // Print to console
  if (kDebugMode) {
    print('$error at $stack in $library');
    return;
  }
  // Log to file
  logInfo('$error at $stack in $library');
  // Send to webhook if analytics are enabled
  if (!plausible.enabled) return;
}

/// Manually trigger upload of log file
void uploadLog() async {
  var file = File(getLogFilePath());
  if (!await file.exists()) return;

  // Date only
  var date = DateTime.now().toIso8601String().split('T')[0];

  // Generate ID based on hostname, date and OS
  var name = 'Logfile from $date on '
      '${Platform.operatingSystem} with ${Platform.operatingSystemVersion}';

  Dio().post(
    errorUrl,
    data: {
      'error': name,
      'stack': await file.readAsString(),
    },
  );
}
