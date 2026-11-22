import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The WSL-not-installed panel, rendered inline on the home list.
///
/// The install action is a real button that says an administrator prompt is
/// coming — it used to be a hyperlink under the sentence "You can install it
/// with following command in the Terminal:", which described the one control
/// on the screen as text to copy (audit CI-38, CI-39). The command itself
/// stays visible beside it for anyone who prefers their own terminal.
class InstallDialog extends StatelessWidget {
  const InstallDialog({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text('wslnotinstalled-text'.i18n(),
                style: FluentTheme.of(context).typography.subtitle),
            Padding(
              padding: const EdgeInsets.only(top: 8.0, bottom: 12.0),
              child: Text('wslnotinstalledbody-text'.i18n()),
            ),
            FilledButton(
              key: const ValueKey('test-install-wsl'),
              onPressed: () {
                plausible.event(name: "wsl_install");
                WSLApi().installWSL();
              },
              child: Text('installwsl-text'.i18n()),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('wslinstallhint-text'.i18n(),
                      style:
                          TextStyle(color: secondaryTextColor(context))),
                  const SizedBox(width: 6.0),
                  Container(
                    // A 20% black wash is near-invisible over the dark
                    // surface (audit CI-40).
                    color: subtleFillColor(context),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6.0, vertical: 2.0),
                    child: const Text('wsl --install',
                        style: TextStyle(fontFamily: 'Consolas')),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text('wslinstallinfo-text'.i18n(),
                  style: TextStyle(color: secondaryTextColor(context))),
            ),
          ],
        ),
      ),
    );
  }
}
