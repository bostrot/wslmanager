import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Ask once, on a start, whether this install wants anything AI at all.
///
/// The assistant, the error diagnosis and the AI Workspace used to be on
/// from the first launch, and on Windows the workspace distro was set up
/// without anyone asking for it — which read to Store reviewers as the app
/// "installing AI stuff that had nothing to do with WSL management"
/// (bostrot/ai-tasks#98). So nothing AI-shaped exists until this question
/// has an answer: [AiService.featuresEnabled] is false while it is
/// unanswered, which keeps the nav entry, the chat dock and the startup
/// provisioning away.
///
/// Asked exactly once. Both buttons write the answer, so "no" is as final as
/// "yes"; either can be changed later in Settings → Bring Your Own AI Key,
/// which is what the dialog's last line points at.
///
/// [after] is whatever this start already put on screen — the welcome on a
/// genuine first run, the release notes on an upgrade — awaited so the
/// question lands after it rather than on top of it.
Future<void> maybeAskAiConsent({Future<void>? after}) async {
  if (AiService.featuresDecided) return;
  if (after != null) await after;

  while (GlobalVariable.infobox.currentContext == null) {
    await Future.delayed(const Duration(milliseconds: 100));
  }
  plausible.event(page: 'ai_consent_prompt');

  await showDialog(
    context: GlobalVariable.infobox.currentContext!,
    builder: (context) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 460.0),
      title: Text('ai-consent-title'.i18n()),
      content:
          Text('ai-consent-text'.i18n(), style: const TextStyle(height: 1.4)),
      actions: [
        Button(
          key: const ValueKey('test-ai-consent-decline'),
          child: Text('ai-consent-no'.i18n()),
          onPressed: () {
            AiService.setFeaturesEnabled(false);
            Navigator.pop(context);
          },
        ),
        FilledButton(
          key: const ValueKey('test-ai-consent-accept'),
          child: Text('ai-consent-yes'.i18n()),
          onPressed: () {
            AiService.setFeaturesEnabled(true);
            Navigator.pop(context);
          },
        ),
      ],
    ),
  );
}
