import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// Shows how to sign in to a VM by hand, and lets the account be corrected.
///
/// Everything the app itself does — snippets, the terminal button, templating
/// — goes in by SSH key and never asks for any of this. The VM's own screen
/// does ask: it shows a `login:` prompt, and before bostrot/ai-tasks#60 the
/// account behind it had no password at all and nothing named it, so a guest
/// created with a custom user was unreachable from its own window.
///
/// The account is a text box rather than a label because on a macOS guest
/// the app's idea of it can simply be wrong: the name is typed into Setup
/// Assistant on the guest's own screen, `vmctl create` never learns it, and
/// what stays behind is the placeholder it was given. Every SSH path then
/// signs in as a user that does not exist, and the only advice the app could
/// give was to change a setting VMs have no settings dialog for
/// (bostrot/ai-tasks#101). This is that setting.
Future<void> showVmCredentialsDialog(BuildContext context, AppleVmApi api,
    String instance) async {
  await showDialog<void>(
    context: context,
    builder: (_) => VmCredentialsDialog(api: api, instance: instance),
  );
}

class VmCredentialsDialog extends StatefulWidget {
  final AppleVmApi api;
  final String instance;

  const VmCredentialsDialog(
      {super.key, required this.api, required this.instance});

  @override
  State<VmCredentialsDialog> createState() => _VmCredentialsDialogState();
}

class _VmCredentialsDialogState extends State<VmCredentialsDialog> {
  GuestCredentials? _credentials;
  String? _error;

  /// The password is masked until asked for: this dialog is the kind of thing
  /// that ends up on a screen share.
  bool _revealed = false;

  /// The account every SSH path into this instance uses. Prefilled with what
  /// the user has already pinned, else with what the helper reports.
  final TextEditingController _user = TextEditingController();

  /// What the helper reports, kept so that typing it back in clears the pin
  /// rather than freezing today's answer into a setting.
  String _configuredUser = '';

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'vm_credentials_dialog');
    _load();
  }

  @override
  void dispose() {
    _user.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final credentials = await widget.api.guestCredentials(widget.instance);
      if (!mounted) return;
      setState(() {
        _credentials = credentials;
        _configuredUser = credentials.user;
        final pinned = AppleVmApi.preferredUser(widget.instance);
        _user.text = pinned.isEmpty ? credentials.user : pinned;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  /// Pin the typed account for this instance — or clear the pin when it is
  /// back to the helper's own answer, so a VM whose config is right keeps
  /// tracking it.
  Future<void> _save() async {
    final account = _user.text.trim();
    await AppleVmApi.setPreferredUser(
        widget.instance, account == _configuredUser.trim() ? '' : account);
    if (!mounted) return;
    Navigator.pop(context);
    Notify.message(
        'vmloginusersaved-text'.i18n([
          distroLabel(widget.instance),
          account.isEmpty ? _configuredUser : account,
        ]),
        severity: InfoBarSeverity.success);
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    Notify.message('copied-text'.i18n(),
        severity: InfoBarSeverity.success,
        duration: const Duration(seconds: 2));
  }

  /// One labelled, selectable value with a copy button beside it.
  Widget _field(String label, String value,
      {required String testKey, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 10.0),
      child: InfoLabel(
        label: label,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SelectableText(
                obscure ? '•' * value.length : value,
                key: ValueKey(testKey),
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 8.0),
            // The name says *what* is being copied: three identical "Copy"
            // buttons in one dialog name nothing to a screen reader.
            NamedIconButton(
              key: ValueKey('$testKey-copy'),
              label: '${'copy-text'.i18n()}: $label',
              icon: FluentIcons.copy,
              iconSize: 14.0,
              onPressed: () => _copy(value),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final error = _error;
    if (error != null) {
      return Text(error,
          key: const ValueKey('test-vm-credentials-error'),
          style: TextStyle(color: destructiveColor(context)));
    }
    final credentials = _credentials;
    if (credentials == null) {
      return Row(children: [
        const SizedBox.square(
            dimension: 16.0, child: ProgressRing(strokeWidth: 2.0)),
        const SizedBox(width: 8.0),
        Text('loading-text'.i18n()),
      ]);
    }
    final password = credentials.password;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('vmlogindetailsbody-text'.i18n()),
        Padding(
          padding: const EdgeInsets.only(top: 10.0),
          child: InfoLabel(
            label: 'vmloginuser-text'.i18n(),
            child: TextBox(
              key: const ValueKey('test-vm-credentials-user'),
              controller: _user,
              placeholder: 'vmloginuser-text'.i18n(),
              onSubmitted: (_) => _save(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Text('vmloginuserhint-text'.i18n(),
              key: const ValueKey('test-vm-credentials-user-hint'),
              style: FluentTheme.of(context).typography.caption),
        ),
        if (password != null)
          _field('password-text'.i18n(), password,
              testKey: 'test-vm-credentials-password', obscure: !_revealed),
        if (password == null)
          Padding(
            padding: const EdgeInsets.only(top: 10.0),
            child: Text('vmloginnopassword-text'.i18n(),
                key: const ValueKey('test-vm-credentials-nopassword')),
          ),
        if (credentials.appliedOnNextBoot)
          Padding(
            padding: const EdgeInsets.only(top: 10.0),
            child: InfoBar(
              key: const ValueKey('test-vm-credentials-pending'),
              title: Text('vmloginpending-text'.i18n()),
              severity: InfoBarSeverity.warning,
              isLong: true,
            ),
          ),
        _field('vmloginsshkey-text'.i18n(), credentials.sshKeyPath,
            testKey: 'test-vm-credentials-key'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPassword = _credentials?.password != null;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 520.0),
      title: Text('vmlogindetails-text'.i18n([distroLabel(widget.instance)])),
      content: _body(),
      actions: [
        if (hasPassword)
          Button(
            key: const ValueKey('test-vm-credentials-reveal'),
            onPressed: () => setState(() => _revealed = !_revealed),
            child: Text(_revealed
                ? 'vmloginhide-text'.i18n()
                : 'vmloginreveal-text'.i18n()),
          ),
        // Nothing to save before the helper has answered: the box is empty
        // then, and saving an empty account would clear a pin the user came
        // here to read.
        FilledButton(
          key: const ValueKey('test-vm-credentials-save'),
          onPressed: _credentials == null ? null : _save,
          child: Text('save-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-dialog-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text('close-text'.i18n()),
        ),
      ],
    );
  }
}
