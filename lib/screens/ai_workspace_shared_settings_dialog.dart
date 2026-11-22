// The assistant's endpoint, key and model, and the button that writes them
// into every installed AI Workspace tool (bostrot/ai-tasks#81).
//
// There is no form here on purpose: the values are the assistant's own
// "Bring Your Own AI Key" settings, edited in Settings and nowhere else, so
// the tools and the chat can never disagree. Saving them in Settings pushes
// them into the tools already; this dialog applies them again by hand — after
// a tool was reconfigured on its own, say — and lists per tool what
// happened, because one tool refusing says nothing about the others.

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';

import '../api/ai_workspace/service.dart';
import '../api/ai_workspace/shared_settings.dart';
import '../components/busy_button.dart';
import '../components/helpers.dart';
import '../components/notify.dart';

/// Opens the dialog. Resolves true when the settings were applied.
Future<bool?> showAiWorkspaceSharedSettingsDialog({
  required BuildContext context,
  required AiWorkspaceSharedSettingsService service,
  required String Function(AiWorkspaceTool tool) toolName,
  required VoidCallback openSettings,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => AiWorkspaceSharedSettingsDialog(
      service: service,
      toolName: toolName,
      openSettings: openSettings,
    ),
  );
}

class AiWorkspaceSharedSettingsDialog extends StatefulWidget {
  final AiWorkspaceSharedSettingsService service;
  final String Function(AiWorkspaceTool tool) toolName;

  /// Takes the user to the Settings page, where the values are edited. The
  /// dialog closes first; the caller owns the navigation.
  final VoidCallback openSettings;

  const AiWorkspaceSharedSettingsDialog({
    super.key,
    required this.service,
    required this.toolName,
    required this.openSettings,
  });

  @override
  State<AiWorkspaceSharedSettingsDialog> createState() =>
      _AiWorkspaceSharedSettingsDialogState();
}

class _AiWorkspaceSharedSettingsDialogState
    extends State<AiWorkspaceSharedSettingsDialog> {
  /// Read once: the dialog is modal, so Settings cannot change under it.
  late final AiWorkspaceSharedSettings _settings = widget.service.current();

  bool _applying = false;

  /// What the last apply did per tool. Non-null once something was applied.
  List<SharedSettingsResult>? _results;

  Future<void> _apply() async {
    final problem = _settings.problemKey;
    if (problem != null) {
      Notify.message(problem.i18n(), severity: InfoBarSeverity.error);
      return;
    }
    setState(() {
      _applying = true;
      _results = null;
    });
    try {
      final results = await widget.service.applyToAll(_settings);
      if (!mounted) return;
      setState(() {
        _results = results;
        _applying = false;
      });
      if (results.every((r) => r.outcome != SharedSettingsOutcome.failed)) {
        Notify.message(
          'ai-workspace-shared-tools-updated-text'.i18n(),
          severity: InfoBarSeverity.success,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      Notify.message(
        'ai-workspace-config-save-failed-text'.i18n([e.toString()]),
        severity: InfoBarSeverity.error,
      );
    }
  }

  void _openSettings() {
    Navigator.of(context, rootNavigator: true).pop(_results != null);
    widget.openSettings();
  }

  @override
  Widget build(BuildContext context) {
    final hint = TextStyle(fontSize: 12, color: secondaryTextColor(context));
    final configured = _settings.isConfigured;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
      title: Text('ai-workspace-shared-title'.i18n()),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ai-workspace-shared-subtitle'.i18n(), style: hint),
            const SizedBox(height: 12),
            if (!configured)
              InfoBar(
                key: const ValueKey('test-ai-shared-unset'),
                title: Text('ai-workspace-shared-unset-text'.i18n()),
                severity: InfoBarSeverity.info,
              )
            else ...[
              _valueRow(
                'ai-workspace-shared-endpoint-label',
                _settings.endpoint,
                const ValueKey('test-ai-shared-endpoint'),
              ),
              _valueRow(
                'ai-workspace-shared-model-label',
                _settings.model,
                const ValueKey('test-ai-shared-model'),
              ),
              // Never the key itself: it is shown nowhere but the field
              // that edits it.
              _valueRow(
                'ai-workspace-shared-key-label',
                (_settings.apiKey.isEmpty
                        ? 'ai-workspace-shared-key-unset-text'
                        : 'ai-workspace-shared-key-set-text')
                    .i18n(),
                const ValueKey('test-ai-shared-key'),
              ),
            ],
            if (_results != null) ...[
              const SizedBox(height: 8),
              _buildResults(context, _results!),
            ],
          ],
        ),
      ),
      actions: [
        BusyButton(
          key: const ValueKey('test-ai-shared-apply'),
          filled: true,
          label: 'ai-workspace-shared-apply-btn'.i18n(),
          busyLabel: 'ai-workspace-shared-applying-text'.i18n(),
          busy: _applying,
          onPressed: configured && !_applying ? _apply : null,
        ),
        Button(
          key: const ValueKey('test-ai-shared-settings'),
          onPressed: _applying ? null : _openSettings,
          child: Text('ai-workspace-shared-settings-btn'.i18n()),
        ),
        Button(
          key: const ValueKey('test-ai-shared-close'),
          onPressed: _applying
              ? null
              : () => Navigator.of(context, rootNavigator: true)
                  .pop(_results != null),
          child: Text('close-text'.i18n()),
        ),
      ],
    );
  }

  Widget _valueRow(String labelKey, String value, Key key) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InfoLabel(
        label: labelKey.i18n(),
        child: Text(value, key: key),
      ),
    );
  }

  /// One line per tool, plus what a skipped one needs instead.
  Widget _buildResults(
      BuildContext context, List<SharedSettingsResult> results) {
    final hint = TextStyle(fontSize: 12, color: secondaryTextColor(context));
    if (results.isEmpty) {
      return Text(
        'ai-workspace-shared-none-installed-text'.i18n(),
        key: const ValueKey('test-ai-shared-none'),
        style: hint,
      );
    }
    final skippedReasons = results
        .where((r) => r.outcome == SharedSettingsOutcome.skipped)
        .map((r) => r.reasonKey)
        .whereType<String>()
        .toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final result in results) _buildResultRow(context, result),
        for (final key in skippedReasons)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(key.i18n(), style: hint),
          ),
        if (results.any((r) => r.outcome == SharedSettingsOutcome.applied))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('ai-workspace-shared-restart-hint-text'.i18n(),
                style: hint),
          ),
      ],
    );
  }

  Widget _buildResultRow(BuildContext context, SharedSettingsResult result) {
    final IconData icon;
    final Color color;
    switch (result.outcome) {
      case SharedSettingsOutcome.applied:
        icon = FluentIcons.check_mark;
        color = Colors.green;
        break;
      case SharedSettingsOutcome.skipped:
        icon = FluentIcons.info;
        color = secondaryTextColor(context);
        break;
      case SharedSettingsOutcome.failed:
        icon = FluentIcons.error_badge;
        color = destructiveColor(context);
        break;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        key: ValueKey('test-ai-shared-result-${result.tool.name}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(_describe(result))),
        ],
      ),
    );
  }

  String _describe(SharedSettingsResult result) {
    final name = widget.toolName(result.tool);
    switch (result.outcome) {
      case SharedSettingsOutcome.applied:
        return 'ai-workspace-shared-applied-text'.i18n([name]);
      case SharedSettingsOutcome.skipped:
        return 'ai-workspace-shared-skipped-text'.i18n([name]);
      case SharedSettingsOutcome.failed:
        return 'ai-workspace-shared-failed-text'
            .i18n([name, result.error ?? '']);
    }
  }
}
