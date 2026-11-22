import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Copy Dialog
/// @param item: distro name
copyDialog(item) async {
  final VmBackend api = vmBackend();
  plausible.event(page: 'copy');
  // Fetched before the dialog opens so the validator below can refuse a
  // duplicate name up front — Copy used to skip the duplicate check Create
  // has always run, and only WSL's own failure said no (audit CI-05).
  List<String> existing;
  try {
    existing = (await api.list(true)).all;
  } catch (_) {
    existing = const <String>[];
  }
  dialog(
      item: item,
      title: '${'copy-text'.i18n()} \'$item\'',
      // A copy is an export + import (or a VHD copy) of the whole distro, and
      // it stops the source first. None of that was said anywhere before the
      // user committed to it (audit CI-31).
      body: '${'copyinstance-text'.i18n([
            distroLabel(item)
          ])}\n\n${'copyinstancewarning-text'.i18n()}',
      submitText: 'copy-text'.i18n(),
      submitStyle: const ButtonStyle(),
      // An empty name used to pop the dialog and surface as a toast after the
      // fact; the box also showed the *source* name as its placeholder, so it
      // read as pre-filled (audit CI-30).
      validateInput: (inputText) {
        if (inputText.isEmpty) return 'errorentername-text'.i18n();
        final name = sanitizeDistroName(inputText);
        if (existing.any((e) => e.toLowerCase() == name.toLowerCase())) {
          return 'distroexists-text'.i18n();
        }
        return null;
      },
      onSubmit: (inputText) async {
        Notify.message('copyinginstance-text'.i18n([item]), loading: true);

        // The same sanitiser Create uses (audit CI-05).
        inputText = sanitizeDistroName(inputText);
        String results;
        final useRemoteWsl = prefs.getBool('UseRemoteWSL') ?? false;

        if (api is WSLApi) {
          // Check if old distro has path
          String? oldDistroPath = prefs.getString('Path_$item');
          if (oldDistroPath != null && oldDistroPath.isNotEmpty) {
            // Stop distro
            await api.stop(item);
            // Copy vhd
            results = await api.copyVhd(item, inputText);
          } else {
            // Export and import copy
            results = await api.copy(item, inputText);
          }
        } else {
          // Other backends clone through export/import; the source must not
          // be running while its disk is copied.
          await api.stop(item);
          results = await api.copy(item, inputText);
        }

        // Error catching
        if (results.contains('Error')) {
          Notify.message(results,
              severity: InfoBarSeverity.error, loading: false);
          return;
        }
        // Copy settings
        String? startPath = prefs.getString('StartPath_$item') ?? '';
        String? startName = prefs.getString('StartUser_$item') ?? '';
        prefs.setString('DistroName_$inputText', inputText);
        prefs.setString('StartPath_$inputText', startPath);
        prefs.setString('StartUser_$inputText', startName);
        // Save distro path
        if (api is WSLApi) {
          prefs.setString(
              'Path_$inputText',
              useRemoteWsl
                  ? api.remoteInstallPath(inputText)
                  : getInstancePath(inputText).path);
        }
        Notify.message(
            'donecopyinginstance-text'.i18n([distroLabel(item), inputText]),
            severity: InfoBarSeverity.success,
            loading: false);
      });
}
