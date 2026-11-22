import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

/// Makes sure a snippet can reach [instance] over SSH as [user] before it is
/// run, and returns whether the caller may go ahead.
///
/// On the Apple backend snippets run through `vmctl exec`, which needs the
/// store's key in the guest. Cloud-init seeds it into VMs created from a
/// cloud image, but a VM installed by hand from an ISO never gets it, so
/// "Run in instance" opened a Terminal window that said
/// `Permission denied (publickey,...)` and nothing else. Now the access is
/// probed first; when the key is missing, a dialog asks for a guest account
/// and password once, installs the key for that account and root, and the
/// snippet runs. The password is used for that one sign-in and not stored.
///
/// Other backends have no such step and always get `true`.
Future<bool> ensureGuestAccess(
  BuildContext context,
  VmBackend api,
  String instance, {
  String? user,
}) async {
  if (api is! AppleVmApi) return true;
  // The same account runCommands would use when the caller names none:
  // root on a Linux guest, the instance's own account on a macOS one, where
  // root is refused by sshd no matter what key it carries.
  final target = (user == null || user.trim().isEmpty)
      ? await api.execUser(instance)
      : user.trim();

  var probe = await api.probeGuestAccess(instance, user: target);
  if (probe.ok) return true;
  if (!probe.denied) {
    Notify.message(
        'guestaccessunreachable-text'.i18n([distroLabel(instance), probe.message]),
        severity: InfoBarSeverity.error);
    return false;
  }
  if (!context.mounted) return false;

  final authorized = await showDialog<GuestAuthorization>(
    context: context,
    builder: (_) => GuestAccessDialog(
      api: api,
      instance: instance,
      initialUser: _suggestedLogin(instance, target),
    ),
  );
  if (authorized == null) return false;

  // The key went in for the account that signed in and (usually) root. Ask
  // the guest again rather than assume: a snippet's start user may be a
  // third account, or root login may be off in sshd.
  probe = await api.probeGuestAccess(instance, user: target);
  if (probe.ok) {
    Notify.message('guestaccessdone-text'.i18n([distroLabel(instance)]),
        severity: InfoBarSeverity.success);
    return true;
  }

  // The account the user just signed in with answers even though the target
  // does not — a macOS guest asked for as `user`, a Linux one with
  // `PermitRootLogin no`. Both used to end here with a message telling the
  // user to go and set that account as the instance's user, which is a
  // setting VMs had no dialog for (bostrot/ai-tasks#101). It is written down
  // for them instead, and said out loud, because it changes what every later
  // snippet run signs in as.
  if (authorized.user.trim().isNotEmpty && authorized.user != target) {
    if ((await api.probeGuestAccess(instance, user: authorized.user)).ok) {
      await AppleVmApi.setPreferredUser(instance, authorized.user);
      Notify.message(
          'guestaccessadopted-text'
              .i18n([distroLabel(instance), authorized.user, target]),
          severity: InfoBarSeverity.success,
          duration: const Duration(seconds: 15));
      return true;
    }
  }

  Notify.message(
      'guestaccessstilldenied-text'
          .i18n([target, distroLabel(instance), authorized.user]),
      severity: InfoBarSeverity.warning,
      duration: const Duration(seconds: 20));
  return false;
}

/// The account to run as now that [ensureGuestAccess] has said yes.
///
/// Read again rather than reused: the guard may have pinned the account that
/// actually took the key, and running as the one the guest just refused would
/// hand the user a Terminal window full of "Permission denied"
/// (bostrot/ai-tasks#101).
///
/// Null stays null. A backend reads its own default out of it — `root` on
/// both of them — and an empty string is not that: WSL would sign in with
/// `-u ''`.
String? guestRunUser(String instance, String? user) {
  final pinned = AppleVmApi.preferredUser(instance);
  return pinned.isEmpty ? user : pinned;
}

/// Which account to prefill: the snippet's own user when it is not root
/// (root cannot sign in with a password on most guests — sshd's
/// `PermitRootLogin prohibit-password`), else the VM's configured user.
String _suggestedLogin(String instance, String target) {
  if (target != 'root') return target;
  return AppleVmApi.preferredUser(instance);
}

/// Asks for a guest account and password, installs the app's SSH key with
/// them, and pops with the [GuestAuthorization] — or null on cancel.
///
/// Sign-in errors stay inside the dialog (under the fields, in ssh's own
/// words) so a typo does not cost the user the whole flow.
class GuestAccessDialog extends StatefulWidget {
  final AppleVmApi api;
  final String instance;
  final String initialUser;

  const GuestAccessDialog({
    super.key,
    required this.api,
    required this.instance,
    this.initialUser = '',
  });

  @override
  State<GuestAccessDialog> createState() => _GuestAccessDialogState();
}

class _GuestAccessDialogState extends State<GuestAccessDialog> {
  late final TextEditingController _user =
      TextEditingController(text: widget.initialUser);
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    plausible.event(page: 'guest_access_dialog');
  }

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = _user.text.trim();
    final password = _password.text;
    if (user.isEmpty || password.isEmpty) {
      setState(() => _error = 'guestaccessempty-text'.i18n());
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api
          .authorizeSshKey(widget.instance, user: user, password: password);
      if (!mounted) return;
      Navigator.pop(context, result);
    } on AppleVmException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 500.0),
      title: Text('guestaccess-text'.i18n([distroLabel(widget.instance)])),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('guestaccessbody-text'.i18n()),
          const SizedBox(height: 12.0),
          TextBox(
            key: const ValueKey('test-guest-access-user'),
            controller: _user,
            autofocus: widget.initialUser.isEmpty,
            placeholder: 'guestaccessuser-text'.i18n(),
            enabled: !_busy,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 8.0),
          PasswordBox(
            key: const ValueKey('test-guest-access-password'),
            controller: _password,
            autofocus: widget.initialUser.isNotEmpty,
            placeholder: 'password-text'.i18n(),
            enabled: !_busy,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _busy ? null : _submit(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6.0),
              child: Text(
                _error!,
                key: const ValueKey('test-guest-access-error'),
                style:
                    TextStyle(color: destructiveColor(context), fontSize: 12.0),
              ),
            ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(top: 10.0),
              child: Row(
                children: [
                  const SizedBox(
                      width: 16.0, height: 16.0, child: ProgressRing()),
                  const SizedBox(width: 8.0),
                  Text('guestaccessinstalling-text'.i18n()),
                ],
              ),
            ),
        ],
      ),
      actions: [
        FilledButton(
          key: const ValueKey('test-guest-access-submit'),
          onPressed: _busy ? null : _submit,
          child: Text('guestaccesssubmit-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-dialog-cancel'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text('cancel-text'.i18n()),
        ),
      ],
    );
  }
}
