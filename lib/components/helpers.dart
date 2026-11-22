import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:win32/win32.dart' show MEMORYSTATUSEX, GlobalMemoryStatusEx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/safe_paths.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/api/wsl_registry.dart';
import 'package:wsl2distromanager/nav/root_screen.dart';

late String language;
late SharedPreferences prefs;
bool initialized = false;
bool hasPushed = false;

String _getAppStateBaseDir() {
  final env = Platform.environment;
  if (Platform.isWindows) {
    return env['APPDATA'] ??
        '${env['USERPROFILE'] ?? Directory.current.path}\\AppData\\Roaming';
  }
  if (Platform.isLinux) {
    final home = env['HOME'] ?? Directory.current.path;
    return env['XDG_STATE_HOME'] ?? '$home/.local/state';
  }
  if (Platform.isMacOS) {
    final home = env['HOME'] ?? Directory.current.path;
    return '$home/Library/Application Support';
  }
  return Directory.current.path;
}

/// Get distro label from [item].
String distroLabel(String item) {
  String? distroName = prefs.getString('DistroName_$item');
  if (distroName == null || distroName == '') {
    distroName = item;
  }
  return distroName;
}

/// Replace special characters in [name] with underscores.
String replaceSpecialChars(String name) {
  return name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
}

/// Split a shell command string into arguments, respecting quoted strings.
List<String> splitShellArgs(String cmd) {
  final args = <String>[];
  var current = StringBuffer();
  var inSingleQuote = false;
  var inDoubleQuote = false;
  var escapeNext = false;

  for (var i = 0; i < cmd.length; i++) {
    final ch = cmd[i];

    if (escapeNext) {
      current.write(ch);
      escapeNext = false;
      continue;
    }

    if (ch == '\\') {
      if (inDoubleQuote) {
        escapeNext = true;
      } else {
        current.write(ch);
      }
      continue;
    }

    if (ch == '\'' && !inDoubleQuote) {
      inSingleQuote = !inSingleQuote;
      continue;
    }

    if (ch == '"' && !inSingleQuote) {
      inDoubleQuote = !inDoubleQuote;
      continue;
    }

    if (ch == ' ' && !inSingleQuote && !inDoubleQuote) {
      if (current.isNotEmpty) {
        args.add(current.toString());
        current.clear();
      }
      continue;
    }

    current.write(ch);
  }

  if (current.isNotEmpty) {
    args.add(current.toString());
  }

  return args;
}

/// Return the default storage root for distro/data paths.
String getDefaultStorageRootPath() {
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  if (Platform.isWindows) {
    return Platform.environment['APPDATA'] ??
        '${Platform.environment['USERPROFILE'] ?? Directory.current.path}\\AppData\\Roaming';
  }
  if (Platform.isLinux) {
    return Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  }
  if (Platform.isMacOS) {
    return '$home/Library/Application Support';
  }
  return Directory.current.path;
}

/// Utility: Validate JSON content. Returns the decoded JSON on success,
/// or `null` if the content is not valid JSON.
dynamic tryDecodeJson(String content) {
  try {
    return json.decode(content);
  } catch (e) {
    debugPrint('JSON decode failed: $e');
    return null;
  }
}

/// Utility: Attempts to “fix” the content by trimming unexpected characters.
/// Returns the fixed JSON string if successful, or the original if not.
String fixJsonContent(String content) {
  String trimmed = content.trim();
  // Quick check: if it already starts with valid JSON tokens, use it.
  if ((trimmed.startsWith('{') || trimmed.startsWith('[')) &&
      (trimmed.endsWith('}') || trimmed.endsWith(']'))) {
    return trimmed;
  }
  // Otherwise try removing first and/or last character
  if (trimmed.length > 1) {
    String candidate = trimmed.substring(1);
    if (tryDecodeJson(candidate) != null) return candidate;
    candidate = trimmed.substring(0, trimmed.length - 1);
    if (tryDecodeJson(candidate) != null) return candidate;
  }
  // Return original in worst case.
  return content;
}

/// Backs up a file by copying it to a new file with a `.bak` suffix.
void backupFile(String path) {
  try {
    File(path).copySync('$path.bak');
    debugPrint('Backed up file: $path to $path.bak');
  } catch (e) {
    debugPrint('Failed to backup file: $e');
  }
}

/// Initialize shared preferences and perform any necessary file migration
/// or repair operations.
Future initPrefs() async {
  // Define app paths for migration.
  final appData = _getAppStateBaseDir();
  final oldDirPath =
      '$appData${Platform.pathSeparator}com.bostrot${Platform.pathSeparator}WSL Manager';
  final newDirPath =
      '$appData${Platform.pathSeparator}com.bostrot${Platform.pathSeparator}WSL Distro Manager';
  Directory(newDirPath).createSync(recursive: true);

  final oldFilePath =
      '$oldDirPath${Platform.pathSeparator}shared_preferences.json';
  final newFilePath =
      '$newDirPath${Platform.pathSeparator}shared_preferences.json';
  final oldFile = File(oldFilePath);
  final newFile = File(newFilePath);

  // Migration: If the old file exists, try to incorporate its contents.
  if (oldFile.existsSync()) {
    try {
      String oldContent = oldFile.readAsStringSync();
      // Fix the content if there are small corruption issues.
      oldContent = fixJsonContent(oldContent);
      final oldJson = tryDecodeJson(oldContent);
      if (oldJson == null) {
        // Could not decode old file, back it up and delete.
        backupFile(oldFilePath);
        oldFile.deleteSync();
      } else {
        // If a new file exists, merge the data.
        if (newFile.existsSync() && newFile.readAsStringSync().isNotEmpty) {
          String newContent = newFile.readAsStringSync();
          newContent = fixJsonContent(newContent);
          final newJson = tryDecodeJson(newContent);
          if (newJson != null) {
            // For simplicity, assume both files contain maps.
            if (newJson is Map && oldJson is Map) {
              // Merge: old data supplements new data.
              newJson.addAll(oldJson);
            }
            // Backup new file, then write merged contents.
            backupFile(newFilePath);
            newFile.writeAsStringSync(json.encode(newJson),
                mode: FileMode.writeOnly);
            // Backup and remove old file after migration.
            backupFile(oldFilePath);
            oldFile.deleteSync();
          }
        }
      }
    } catch (e) {
      debugPrint('Error during old file migration: $e');
    }
  }

  final backupFilePath = '$newFilePath.backup';
  final prefsBackupFile = File(backupFilePath);

  if (newFile.existsSync()) {
    bool isCorrupted = false;
    try {
      String content = newFile.readAsStringSync();
      content = fixJsonContent(content);
      if (tryDecodeJson(content) == null) {
        isCorrupted = true;
      }
    } catch (e) {
      debugPrint("Failed to validate new shared_preferences.json: $e");
      isCorrupted = true;
    }

    if (!isCorrupted) {
      // File is valid, create/update backup
      try {
        newFile.copySync(backupFilePath);
      } catch (e) {
        debugPrint("Failed to create preferences backup: $e");
      }
    } else {
      // File is corrupted
      debugPrint('New shared_preferences.json is corrupted.');

      // Backup the corrupted file for analysis (creates .bak)
      backupFile(newFilePath);

      // Try to restore from good backup
      bool restored = false;
      if (prefsBackupFile.existsSync()) {
        try {
          // Validate backup before restoring
          String backupContent = prefsBackupFile.readAsStringSync();
          backupContent = fixJsonContent(backupContent);
          if (tryDecodeJson(backupContent) != null) {
            debugPrint('Restoring preferences from valid backup...');
            prefsBackupFile.copySync(newFilePath);
            restored = true;
          } else {
            debugPrint('Backup file is also corrupted. Ignoring.');
          }
        } catch (e) {
          debugPrint("Failed to validate or restore from backup: $e");
        }
      }

      if (!restored) {
        debugPrint('No valid backup found. Deleting corrupted file...');
        try {
          newFile.deleteSync();
        } catch (e) {
          debugPrint("Failed to delete corrupted preferences file: $e");
        }
      }
    }
  } else if (prefsBackupFile.existsSync()) {
    // File doesn't exist, try to restore from backup if available
    debugPrint('Preferences file missing. Restoring from backup...');
    try {
      // Validate backup before restoring
      String backupContent = prefsBackupFile.readAsStringSync();
      backupContent = fixJsonContent(backupContent);
      if (tryDecodeJson(backupContent) != null) {
        prefsBackupFile.copySync(newFilePath);
      } else {
        debugPrint('Backup file is corrupted. Cannot restore.');
      }
    } catch (e) {
      debugPrint("Failed to restore from backup: $e");
    }
  }

  // Now safely initialize SharedPreferences.
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (e) {
    debugPrint("Error initializing SharedPreferences: $e");
    // Retry once after deleting the file if it exists
    if (newFile.existsSync()) {
      try {
        debugPrint(
            "Retrying SharedPreferences initialization after cleanup...");
        backupFile(newFilePath);
        newFile.deleteSync();
        prefs = await SharedPreferences.getInstance();
      } catch (e2) {
        debugPrint("Fatal error initializing SharedPreferences: $e2");
      }
    }
  }

  initialized = true;
}

/// Global variables for global context access.
class GlobalVariable {
  static final GlobalKey<RootPageState> root = GlobalKey<RootPageState>();
  static GlobalKey<NavigatorState> infobox = GlobalKey<NavigatorState>();
  static Instances? initialSnapshot;

  /// Whether the AI chat dock is open. A notifier, not a plain bool, because
  /// the dock now lives in the shell (so a notification bar can sit beside it
  /// instead of under it) while the button that toggles it lives on the home
  /// page — the two rebuild independently off this.
  static final ValueNotifier<bool> aiPanel = ValueNotifier<bool>(false);
  static bool get aiPanelVisible => aiPanel.value;
  static set aiPanelVisible(bool value) => aiPanel.value = value;

  /// Which sandbox chat the dock shows, or null for the app assistant.
  /// Sticky across open/close so reopening returns to the same conversation.
  static final ValueNotifier<String?> sandboxChat =
      ValueNotifier<String?>(null);
  /// Override for testing: when true, Pro features are always accessible.
  static bool testProEnabled = false;
}

/// Return the general distro path. Distros are saved here by default.
/// It will be created if it does not exist.
///
/// e.g. C:\WSL2-Distros\distros
SafePath getDistroPath() {
  String path = prefs.getString('DistroPath') ?? getDefaultStorageRootPath();
  return SafePath(path)..cd('distros');
}

/// Get the tmp folder path. This is used for the download of docker layers.
/// It will be created if it does not exist.
///
/// e.g. C:\WSL2-Distros\tmp
SafePath getTmpPath() {
  return getDataPath()..cd('tmp');
}

/// Get the instance path for the [name] instance.
/// It will be created if it does not exist.
///
/// e.g. C:\WSL2-Distros\ubuntu
SafePath getInstancePath(String name) {
  String? instanceLocation = prefs.getString('Path_$name');
  if (instanceLocation != null && instanceLocation.isNotEmpty) {
    // Fix path for older versions
    var safePath = SafePath(instanceLocation);
    prefs.setString('Path_$name', safePath.path);
    return safePath;
  }

  // Try getting from Registry
  String? regPath = WslRegistry.getDistributionPath(name);
  if (regPath != null && regPath.isNotEmpty) {
    // Handle Windows path prefixes mainly \\?\
    if (regPath.startsWith('\\\\?\\')) {
      regPath = regPath.substring(4);
    }
    prefs.setString('Path_$name', regPath);
    return SafePath(regPath);
  }

  return getDistroPath()
    ..cdUp()
    ..cd(name);
}

/// Per-distro preference key prefixes. Everything the app stores keyed by
/// distro name lives here so deleting an instance can wipe all of it.
const List<String> distroPrefKeyPrefixes = [
  'Path_',
  'StartPath_',
  'StartUser_',
  'StartCmd_',
  'DistroName_',
  'DistroSize_',
  'UserCmds_',
  'GroupCmds_',
  'TurnkeyFirstStart_',
  'GuestGreeting_',
  'quickSettingsMeta_',
  'mount_vhd_',
];

/// Drop every stored setting for [name].
///
/// Without this, recreating an instance under a name that existed before
/// inherits the old start user, start path and mount registration, which makes
/// the new instance fail to start.
Future<void> clearDistroPrefs(String name) async {
  for (final prefix in distroPrefKeyPrefixes) {
    await prefs.remove('$prefix$name');
  }
}

/// Every place [name]'s disk could live, most authoritative first.
///
/// The stored `Path_` preference goes stale (moved instance, restored config,
/// path written by an older version), so it must not win over the registry,
/// which is what WSL itself reads.
List<String> vhdxPathCandidates(String name) {
  final candidates = <String>[];
  void add(String? dir) {
    if (dir == null || dir.isEmpty) return;
    final path = SafePath(dir).file('ext4.vhdx');
    if (!candidates.contains(path)) candidates.add(path);
  }

  var regPath = WslRegistry.getDistributionPath(name);
  if (regPath != null && regPath.startsWith(r'\\?\')) {
    regPath = regPath.substring(4);
  }
  add(regPath);
  add(prefs.getString('Path_$name'));
  add((getDistroPath()
        ..cdUp()
        ..cd(name))
      .path);
  return candidates;
}

/// Locate the ext4.vhdx of [name], or null when no candidate exists on disk.
String? findVhdxPath(String name) {
  for (final candidate in vhdxPathCandidates(name)) {
    try {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

/// Get instance size for [name] instance.
String getInstanceSize(String name) {
  var path = getInstancePath(name).file('ext4.vhdx');
  try {
    var size = File(path).lengthSync();
    if (size > 0) {
      var sizeGB = size / 1024 / 1024 / 1024;
      return '${sizeGB.toStringAsFixed(2)} GB';
    } else {
      return '';
    }
  } catch (e) {
    return '';
  }
}

/// The user's profile directory: `%USERPROFILE%` on Windows, `$HOME`
/// elsewhere, the working directory when neither is set. Where the
/// per-user files Windows tools read live — `.wslconfig`, `.cloud-init\`.
String userProfileDir() {
  final home = Platform.isWindows
      ? Platform.environment['USERPROFILE']
      : Platform.environment['HOME'];
  return home ?? Directory.current.path;
}

/// Get the wslconfig path
String getWslConfigPath() =>
    '${userProfileDir()}${Platform.pathSeparator}.wslconfig';

/// Return the general data path. Templates and downloads are saved here by default.
/// It will be created if it does not exist.
///
/// e.g. C:\WSL2-Distros
SafePath getDataPath() {
  String? path = prefs.getString('DataPath');
  if (path != null && path.isNotEmpty) {
    return SafePath(path);
  }
  // Fallback to DistroPath logic (Root Path)
  String distroPath = prefs.getString('DistroPath') ?? getDefaultStorageRootPath();
  return SafePath(distroPath);
}

/// Clear all stored distro path prefs. Useful for recovering from
/// stale "fake install" paths left over from previous installations.
/// Returns the list of keys that were removed.
Future<List<String>> clearAllDistroPrefs() async {
  final removed = <String>[];

  // Remove all Path_* entries
  final keys = prefs.getKeys();
  for (final key in keys) {
    if (key.startsWith('Path_')) {
      await prefs.remove(key);
      removed.add(key);
    }
  }

  // Remove DistroPath and DataPath
  if (prefs.containsKey('DistroPath')) {
    await prefs.remove('DistroPath');
    removed.add('DistroPath');
  }
  if (prefs.containsKey('DataPath')) {
    await prefs.remove('DataPath');
    removed.add('DataPath');
  }

  return removed;
}

/// Secondary text colour that follows the theme.
///
/// A hardcoded [Colors.grey] is close to invisible against the dark theme's
/// background, so supporting copy has to read this instead.
Color secondaryTextColor(BuildContext context) =>
    FluentTheme.of(context).resources.textFillColorSecondary;

/// Colour for something present but inactive, e.g. a "not included" marker.
Color disabledTextColor(BuildContext context) =>
    FluentTheme.of(context).resources.textFillColorDisabled;

/// Foreground colour for a control that destroys something.
///
/// A flat [Colors.red] is one value for both themes: it reads against the
/// light background and turns muddy against the dark one. fluent's own
/// per-brightness brush picks the shade that stays legible in each (audit
/// LN-04).
Color destructiveColor(BuildContext context) =>
    Colors.red.defaultBrushFor(FluentTheme.of(context).brightness);

/// Border and divider colour that follows the theme.
///
/// Dividers, card borders and code-chip outlines were drawn with
/// `Colors.grey` at six different alphas across five files, and every one of
/// them sank into the dark background (audit TL-02, TL-08).
Color surfaceBorderColor(BuildContext context) =>
    FluentTheme.of(context).resources.dividerStrokeColorDefault;

/// Subtle fill for chips, message bubbles and card washes (audit TL-08).
Color subtleFillColor(BuildContext context) =>
    FluentTheme.of(context).resources.subtleFillColorSecondary;

/// Card fill that follows the theme (audit TL-08).
Color cardFillColor(BuildContext context) =>
    FluentTheme.of(context).resources.cardBackgroundFillColorDefault;

/// Total physical memory in bytes, straight from Win32.
///
/// `SysInfo.getTotalPhysicalMemory()` returns 0 on some hosts, which scaled
/// the `.wslconfig` memory/swap sliders to nothing (audit ST-08). Returns 0
/// when the call fails, so callers can fall back.
int hostPhysicalMemoryBytes() {
  if (!Platform.isWindows) return 0;
  final status = calloc<MEMORYSTATUSEX>();
  try {
    status.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
    if (GlobalMemoryStatusEx(status) == 0) return 0;
    return status.ref.ullTotalPhys;
  } catch (_) {
    return 0;
  } finally {
    calloc.free(status);
  }
}

/// One sanitiser for new instance names, shared by Create and Copy.
///
/// The two flows used to disagree — Create replaced `[^A-Za-z0-9]`, Copy
/// replaced `[^a-zA-Z0-9_-]` — so the same typed name could produce two
/// different distros (audit CI-05). Underscore and hyphen are legal in WSL
/// distribution names and are kept.
String sanitizeDistroName(String label) =>
    label.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');

/// Bytes as a human-readable size, picking the unit that keeps digits.
///
/// Moved here from disk_dialog.dart so the template list can share it — its
/// own formatter was pinned to GB with two decimals, printing "0.04 GB" and
/// rounding anything under ~5 MB to "0 GB" (audit ST-37, ST-42).
String formatBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
}
