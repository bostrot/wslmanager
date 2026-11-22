import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';

/// Bug dialog
bugDialog() {
  // Get root context by Key
  final context = GlobalVariable.infobox.currentContext!;

  plausible.event(page: 'bug_dialog');
  // Show dialog that asks if the user wants to upload the log file or just open a github issue or cancel
  showDialog(
    context: context,
    builder: (context) => ContentDialog(
      // Wide enough for three action labels to stay on one line once
      // translated.
      constraints: const BoxConstraints(maxWidth: 560.0),
      title: Text('🐞 ${'reportbug-text'.i18n()}'),
      content: Text('report-text'.i18n()),
      actions: [
        Button(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: Text('cancelreport-text'.i18n()),
        ),
        Button(
          onPressed: () {
            Navigator.of(context).pop();
            uploadLog();
          },
          child: Text('uploadlogfile-text'.i18n()),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            launchUrlString(githubIssues);
          },
          child: Text('githubissue-text'.i18n()),
        ),
      ],
    ),
  );
}
