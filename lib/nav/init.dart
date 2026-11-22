import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter/gestures.dart';
import 'package:localization/localization.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/app.dart';
import 'package:wsl2distromanager/api/updater.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/ai_consent_dialog.dart';
import 'package:wsl2distromanager/dialogs/changelog_dialog.dart';
import 'package:wsl2distromanager/dialogs/firststart_dialog.dart';
import 'package:wsl2distromanager/api/rating_prompt.dart';
import 'package:wsl2distromanager/dialogs/update_dialog.dart';
import 'package:wsl2distromanager/theme.dart';

initRoot(NotifyMessage statusMsg) async {
  // Call constructor to initialize
  Notify();
  Notify.message = statusMsg;

  // First start with this version.
  //
  // Read before it is overwritten below — and, more to the point, read here
  // rather than anywhere earlier in startup: LicenseManager.init() runs in
  // main() before this, and the Store grandfather rule needs the version of
  // the *previous* run to tell a copy bought in the paid era from a free
  // download (see storeGrandfathers). Moving this write earlier would erase
  // that evidence.
  String? version = prefs.getString('version');
  String? lastChangelogVersion = prefs.getString('LastChangelogVersion');
  recordAppLaunch();

  // Seed the theme from the system only on a first run. The setter persists,
  // so doing this unconditionally overwrote the user's saved choice on every
  // start.
  if (prefs.getString('themeMode') == null) {
    var brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    AppTheme().mode =
        brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
  }

  // Whichever of the welcome and the release notes this start raises, while
  // it is up, so the AI question can wait for it instead of covering it.
  Future<void>? greeting;

  if (version == null) {
    // First start
    await prefs.setString('version', currentVersion);
    while (GlobalVariable.infobox.currentContext == null) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    greeting = firststartDialog();
  } else if (version != currentVersion) {
    // First start with this version
    await prefs.setString('version', currentVersion);

    // Show changelog once per app version.
    if (lastChangelogVersion != currentVersion) {
      // Get changelog
      var response = await Dio().get(updateUrl);
      if (response.data.length > 0) {
        var latest = response.data[0];
        String tagName = latest['tag_name'];
        String body = latest['body'];

        greeting = changelogDialog(prefs, tagName, body);
      }

      await prefs.setString('LastChangelogVersion', currentVersion);
    }
  }

  // The prompts a start can raise, one after another rather than on top of
  // each other: the release that introduces the AI question is the one where
  // every existing install answers it. The rating sheet never shares a start
  // with any of them.
  Future<void> startupPrompts() async {
    final consentDue = !AiService.featuresDecided;
    // Whether this install wants anything AI at all, asked once and never
    // again (bostrot/ai-tasks#98), and behind the greeting that a first run
    // or an upgrade puts up first.
    await maybeAskAiConsent(after: greeting);
    // Asked on a later start rather than right after a creation, so the
    // sheet never lands on top of the dialog the user just closed.
    await maybeRequestStoreRating(
        otherPromptShown: greeting != null || consentDue);
  }

  // Not awaited: a user who leaves a prompt open still gets the update check
  // and the message of the day.
  unawaited(startupPrompts());

  // Check for interrupted move operation
  String? moveOpDistro = prefs.getString('MoveOp_Distro');
  String? moveOpBackupPath = prefs.getString('MoveOp_BackupPath');
  if (moveOpDistro != null && moveOpBackupPath != null) {
    while (GlobalVariable.infobox.currentContext == null) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // Show recovery dialog
    showDialog(
      context: GlobalVariable.infobox.currentContext!,
      builder: (context) => ContentDialog(
        title: const Text('Recovery Detected'),
        content: Text(
            'It appears that a move operation for "$moveOpDistro" was interrupted.\n\nYour data should be safe in:\n$moveOpBackupPath\n\nPlease verify this file exists and try importing it manually or moving it to a safe location.'),
        actions: [
          Button(
            child: const Text('OK'),
            onPressed: () {
              // Clear the marker so we don't show this again
              prefs.remove('MoveOp_Distro');
              prefs.remove('MoveOp_BackupPath');
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  // Check for a new release.
  //
  // A direct install can apply one itself, so it is offered the real thing:
  // the banner opens the updater's dialog, which downloads and installs. A
  // Store install is updated by the Store, so it still gets nothing but the
  // pointer at the listing (see lib/api/updater.dart).
  App app = App();
  final updater = UpdateService();
  if (updater.canSelfUpdate) {
    updater.checkOnStartup().then((info) {
      if (info == null) return;
      statusMsg('',
          useWidget: true,
          duration: const Duration(minutes: 1),
          widget: Text.rich(
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.clip,
              TextSpan(children: [
                TextSpan(
                    text: '${'newversion-text'.i18n()} ',
                    style: const TextStyle(fontSize: 14.0)),
                TextSpan(
                    text: '${'update-install-text'.i18n()} ',
                    style: TextStyle(
                        color: Colors.purple,
                        fontSize: 14.0,
                        fontWeight: FontWeight.bold),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => showUpdateDialog(info, service: updater)),
              ])));
    });
  } else {
    app.checkUpdate(currentVersion).then((updateUrl) {
      if (updateUrl != '') {
        statusMsg('',
            useWidget: true,
            duration: const Duration(minutes: 1),
            // Text.rich rather than RichText: the spans with no colour of
            // their own inherit the surrounding DefaultTextStyle, where
            // RichText would need a hardcoded per-theme guess (audit TL-03).
            widget: Text.rich(
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.clip,
                TextSpan(children: [
                  TextSpan(
                      text: '${'newversion-text'.i18n()} ',
                      style: const TextStyle(fontSize: 14.0)),
                  TextSpan(
                      text: '${'downloadnow-text'.i18n()} ',
                      style: TextStyle(
                          color: Colors.purple,
                          fontSize: 14.0,
                          fontWeight: FontWeight.bold),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () => launchUrl(Uri.parse(updateUrl))),
                  // The Store alternative only exists for the Windows build.
                  if (!isAppleHost) ...[
                    TextSpan(
                        text: '${'orcheck-text'.i18n()} ',
                        style: const TextStyle(fontSize: 14.0)),
                    TextSpan(
                        text: '${'windowsstore-text'.i18n()} ',
                        style: TextStyle(
                            color: Colors.purple,
                            fontSize: 14.0,
                            fontWeight: FontWeight.bold),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () => launchUrl(Uri.parse(windowsStoreUrl))),
                  ],
                ])));
      }
    });
  }

  // Check motd once per day
  final String today = DateTime.now().toIso8601String().substring(0, 10);
  if (prefs.getString('LastMotd') != today) {
    // Update preference immediately to prevent multiple checks
    prefs.setString('LastMotd', today);
    app.checkMotd().then((String motd) {
      if (motd != '') {
        Notify.message(motd, duration: const Duration(seconds: 60));
      }
    });
  }
}
