import 'package:flutter_markdown/flutter_markdown.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;

import 'package:localization/localization.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Info Dialog
/// @param prefs: SharedPreferences
/// @param currentVersion: String
///
/// Returns once it is closed, so a caller can queue something behind it —
/// the AI question does, rather than opening on top of the release notes.
Future<void> changelogDialog(prefs, currentVersion, body) {
  plausible.event(page: 'changelog');

  // Get root context by Key
  final context = GlobalVariable.infobox.currentContext!;

  return showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        constraints: const BoxConstraints(maxHeight: 500.0, maxWidth: 500.0),
        title: Text('🚀 ${'changelog-text'.i18n()} $currentVersion'),
        content: Markdown(
          onTapLink: (text, href, title) {
            if (href == null) return;
            launchUrlString(href);
          },
          shrinkWrap: true,
          data: body,
          extensionSet: md.ExtensionSet(
            md.ExtensionSet.gitHubFlavored.blockSyntaxes,
            [
              md.EmojiSyntax(),
              ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes
            ],
          ),
        ),
        actions: [
          Button(
              style: ButtonStyle(
                backgroundColor: ButtonState.all(Colors.blue),
                foregroundColor: ButtonState.all(Colors.white),
              ),
              onPressed: () {
                Navigator.pop(context);
              },
              child: Text('ok-text'.i18n())),
        ],
      );
    },
  );
}
