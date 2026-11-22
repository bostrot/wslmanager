import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// Whether an AI diagnosis could actually run right now.
///
/// The button used to be offered unconditionally and, without Pro or a key,
/// answered a click with a go-configure-something-else toast (audit LN-19,
/// CI-23). An affordance that cannot do its job is not shown.
bool canDiagnoseWithAi() {
  try {
    return AiService.featuresEnabled &&
        LicenseManager().isPro &&
        AiService().hasAiConfigured;
  } catch (_) {
    return false;
  }
}

/// Shows an AI-powered diagnosis for the given error message.
Future<void> diagnoseWithAi(String errorMessage) async {
  if (!canDiagnoseWithAi()) return;

  try {
    Notify.message('ai-generating-text'.i18n(), loading: true);
    final diagnosis = await AiService().diagnoseError(errorMessage);
    if (diagnosis.isEmpty) {
      Notify.message('ai-error-text'.i18n(), severity: InfoBarSeverity.error);
      return;
    }
    Notify.message('');
    // A dialog, not a 30-second toast: a multi-sentence answer in a one-line
    // status bar could not be scrolled, selected or copied, and then
    // vanished (audit CI-23).
    final context = GlobalVariable.infobox.currentContext;
    if (context == null || !context.mounted) return;
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 560.0, maxHeight: 560.0),
        title: Text('ai-diagnose-text'.i18n()),
        content: SingleChildScrollView(
          child: SelectableText(diagnosis),
        ),
        actions: [
          Button(
            child: Text('ok-text'.i18n()),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  } catch (_) {
    Notify.message('ai-error-text'.i18n(), severity: InfoBarSeverity.error);
  }
}

/// Small inline button that triggers AI diagnosis for the given error.
///
/// Renders nothing when the diagnosis could not run — a user without Pro or
/// without a key gets the error view's own remedies instead of a dead end.
class AiDiagnoseButton extends StatelessWidget {
  final String errorMessage;

  const AiDiagnoseButton({super.key, required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    if (!canDiagnoseWithAi()) return const SizedBox.shrink();
    return Button(
      onPressed: () => diagnoseWithAi(errorMessage),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(FluentIcons.chat, size: 12),
          const SizedBox(width: 4),
          Text('ai-diagnose-text'.i18n()),
        ],
      ),
    );
  }
}
