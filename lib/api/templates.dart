import 'dart:io';

import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/safe_paths.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// This class handles all template related functions.
/// Templates are instances exported to a file (ext4 tarballs on WSL, raw
/// disk images on the Apple backend) with additional metadata saved in the
/// SharedPreferences.
class Templates {
  final VmBackend wslApi;

  Templates({VmBackend? wslApi}) : wslApi = wslApi ?? vmBackend();

  /// File extension for template files on this backend, without the dot.
  String get extension => wslApi.templateExtension;

  /// Save a distro as a template by [name]
  Future<void> saveTemplate(String name) async {
    String templateName = name;
    // Check if template already exists
    var templates = prefs.getStringList('templates');
    var i = 2;
    while (templates != null && templates.contains(templateName)) {
      if (i > 2) {
        templateName =
            '${templateName.substring(0, templateName.length - 2)}-$i';
      } else {
        templateName = '$templateName-2';
      }
      i++;
    }

    plausible.event(name: "wsl_saveastemplate");
    Notify.message('$templateName ${'savingastemplate-text'.i18n()}.',
        loading: true);
    await wslApi.export(
        name, getTemplatePath().file('$templateName.$extension'));
    templates ??= [];
    templates.add(templateName);
    prefs.setStringList('templates', templates);
    Notify.message('$templateName ${'savedastemplate-text'.i18n()}.',
        severity: InfoBarSeverity.success,
        duration: const Duration(seconds: 3));
  }

  /// Use a template by [templateName] and create a new instance with [newName].
  Future<void> useTemplate(String templateName, String newName) async {
    final targetName = newName.trim().isEmpty ? templateName : newName.trim();

    if (targetName.isEmpty) {
      Notify.message('errorentername-text'.i18n(),
          severity: InfoBarSeverity.error);
      return;
    }

    Notify.message('creatinginstance-text'.i18n([targetName]), loading: true);

    try {
      final result = await wslApi.import(targetName,
          getInstancePath(targetName).path, getTemplateFilePath(templateName));
      final output = result.trim();
      Notify.message(output.isNotEmpty ? output : 'createdinstance-text'.i18n(),
          severity: InfoBarSeverity.success);
    } catch (e) {
      final failure = WslFailure.from(e);
      Notify.message(
          '${'createinstancefailed-text'.i18n([targetName])} ${failure.shortReason}'.trim(),
          severity: InfoBarSeverity.error);
    }
  }

  /// Delete a template by [name] and update the SharedPreferences.
  /// [Warning] This will also delete the template file.
  Future<void> deleteTemplate(String name) async {
    // Remove from prefs StringList
    var templates = prefs.getStringList('templates');
    if (templates == null) return;
    templates.remove(name);
    prefs.setStringList('templates', templates);
    // Remove description
    prefs.remove('template_description_$name');
    // Delete template file. The prefs entry is already gone, so a file
    // something else removed must not turn the cleanup into a crash.
    final file = File(getTemplateFilePath(name));
    if (await file.exists()) await file.delete();
    Notify.message('deletedinstance-text'.i18n([name]),
        severity: InfoBarSeverity.success);
  }

  /// Get a list of all templates.
  ///
  /// The stored list is reconciled with the template folder so templates
  /// survive a lost or reset preferences file: any .ext4 sitting in the
  /// template directory is adopted, and entries whose file is gone are
  /// dropped.
  List<String> getTemplates() {
    final stored = prefs.getStringList('templates') ?? [];
    final onDisk = scanTemplateFiles();

    final merged = <String>[
      ...stored.where((name) => onDisk.contains(name)),
      ...onDisk.where((name) => !stored.contains(name)),
    ];

    if (merged.length != stored.length ||
        !merged.every((name) => stored.contains(name))) {
      prefs.setStringList('templates', merged);
    }
    return merged;
  }

  /// Template names derived from the .ext4 files in the template folder.
  List<String> scanTemplateFiles() {
    try {
      final dir = Directory(getTemplatePath().path);
      if (!dir.existsSync()) return [];
      return dir
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((file) => file.endsWith('.$extension'))
          .map((file) =>
              file.substring(0, file.length - '.$extension'.length))
          .toList()
        ..sort();
    } on FileSystemException {
      return [];
    }
  }

  /// Return the general template path. Templates are saved here by default.
  /// It will be created if it does not exist. Relative to DistroPath.
  ///
  /// e.g. C:\WSL2-Distros\templates
  SafePath getTemplatePath() {
    return getDataPath()..cd('templates');
  }

  /// Return the path to a template by [name].
  /// e.g. C:\WSL2-Distros\templates\ubuntu.ext4
  String getTemplateFilePath(String name) {
    return getTemplatePath().file('$name.$extension');
  }

  /// Get template size by [name], in a unit that keeps digits.
  ///
  /// Empty, not '0 GB', when the file is missing: the screen used to drop
  /// any template whose size formatted to that string (audit ST-37, ST-42).
  String getTemplateSize(String name) {
    var path = getTemplateFilePath(name);
    if (File(path).existsSync() == false) return '';
    return formatBytes(File(path).lengthSync());
  }

  /// Get template description by [name].
  String getTemplateDescription(String name) {
    return prefs.getString('template_description_$name') ?? '';
  }

  /// Set template description by [name].
  Future<void> setTemplateDescription(String name, String description) async {
    await prefs.setString('template_description_$name', description);
  }

  /// Rename a template from [oldName] to [newName].
  Future<void> renameTemplate(String oldName, String newName) async {
    if (oldName == newName) return;

    // Rename file
    File oldFile = File(getTemplateFilePath(oldName));
    if (await oldFile.exists()) {
      await oldFile.rename(getTemplateFilePath(newName));
    }

    // Update prefs list
    var templates = prefs.getStringList('templates');
    if (templates != null) {
      int index = templates.indexOf(oldName);
      if (index != -1) {
        templates[index] = newName;
        await prefs.setStringList('templates', templates);
      }
    }

    // Move description
    String? description = prefs.getString('template_description_$oldName');
    if (description != null) {
      await prefs.setString('template_description_$newName', description);
      await prefs.remove('template_description_$oldName');
    }
  }
}
