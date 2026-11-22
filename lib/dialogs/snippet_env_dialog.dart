import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/api/snippet_env.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Asks for the environment [action] needs and returns what to export with
/// it, or null when the user closed the dialog without running anything.
///
/// A snippet with nothing to ask for never shows a dialog, so the common case
/// — pick a snippet, it runs — is unchanged.
Future<Map<String, String>?> askSnippetEnv(
    BuildContext context, QuickActionItem action) async {
  final vars = action.envPrompts;
  if (vars.isEmpty) return const <String, String>{};
  final values = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => SnippetEnvDialog(action: action, vars: vars),
  );
  if (values == null) return null;
  _remember(action.name, vars, values);
  return SnippetEnv.filled(values);
}

/// The key a non-secret value is remembered under, so running the same
/// snippet in a second instance does not mean typing the same URL again.
String _prefsKey(String snippet, String name) => 'SnippetEnv_${snippet}_$name';

/// Keeps what may be kept. A value marked `secret` — a token, a password — is
/// deliberately not written anywhere: this dialog exists so those stop living
/// in the snippet's own text.
void _remember(
    String snippet, List<SnippetEnvVar> vars, Map<String, String> values) {
  for (final variable in vars) {
    if (variable.secret) continue;
    final value = values[variable.name] ?? '';
    if (value.isEmpty) {
      prefs.remove(_prefsKey(snippet, variable.name));
    } else {
      prefs.setString(_prefsKey(snippet, variable.name), value);
    }
  }
}

/// One field per variable the snippet declares or reads, filled in before it
/// runs (bostrot/ai-tasks#99).
class SnippetEnvDialog extends StatefulWidget {
  const SnippetEnvDialog({
    super.key,
    required this.action,
    required this.vars,
  });

  final QuickActionItem action;
  final List<SnippetEnvVar> vars;

  @override
  State<SnippetEnvDialog> createState() => _SnippetEnvDialogState();
}

class _SnippetEnvDialogState extends State<SnippetEnvDialog> {
  final Map<String, TextEditingController> _controllers = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'snippet_env_dialog');
    for (final variable in widget.vars) {
      // Last run's value first, then the author's default: a snippet run
      // again usually wants the same URL and a fresh token.
      final previous = variable.secret
          ? null
          : prefs.getString(_prefsKey(widget.action.name, variable.name));
      _controllers[variable.name] = TextEditingController(
          text: (previous != null && previous.isNotEmpty)
              ? previous
              : variable.defaultValue);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    for (final variable in widget.vars) {
      if (!variable.isRequired) continue;
      if ((_controllers[variable.name]?.text ?? '').trim().isEmpty) {
        setState(
            () => _error = 'snippetenvrequired-text'.i18n([variable.name]));
        return;
      }
    }
    Navigator.pop(context, {
      for (final entry in _controllers.entries) entry.key: entry.value.text,
    });
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520.0, maxHeight: 620.0),
      title: Text('snippetenv-text'.i18n([widget.action.name])),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('snippetenvbody-text'.i18n()),
            for (final variable in widget.vars) _field(context, variable),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  _error!,
                  key: const ValueKey('test-snippet-env-error'),
                  style: TextStyle(
                      color: destructiveColor(context), fontSize: 12.0),
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('test-snippet-env-run'),
          onPressed: _submit,
          child: Text('snippetenvrun-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-dialog-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text('cancel-text'.i18n()),
        ),
      ],
    );
  }

  Widget _field(BuildContext context, SnippetEnvVar variable) {
    final controller = _controllers[variable.name]!;
    // A variable the manifest describes shows that description; one the app
    // found in the script itself can only say where it came from.
    final hint = variable.description.isNotEmpty
        ? variable.description
        : 'snippetenvdetected-text'.i18n();
    return Padding(
      padding: const EdgeInsets.only(top: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(variable.name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (!variable.isRequired)
                Padding(
                  padding: const EdgeInsets.only(left: 6.0),
                  child: Text('snippetenvoptional-text'.i18n(),
                      style: TextStyle(
                          fontSize: 12.0, color: secondaryTextColor(context))),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2.0, bottom: 4.0),
            child: Text(hint,
                style: TextStyle(
                    fontSize: 12.0, color: secondaryTextColor(context))),
          ),
          if (variable.secret)
            PasswordBox(
              key: ValueKey('test-snippet-env-${variable.name}'),
              controller: controller,
              placeholder: variable.name,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            )
          else
            TextBox(
              key: ValueKey('test-snippet-env-${variable.name}'),
              controller: controller,
              placeholder: variable.name,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
          if (variable.secret)
            Padding(
              padding: const EdgeInsets.only(top: 2.0),
              child: Text('snippetenvsecret-text'.i18n(),
                  style: TextStyle(
                      fontSize: 11.0, color: secondaryTextColor(context))),
            ),
        ],
      ),
    );
  }
}
