import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// This function displays a dialog box with the given [item], which is a widget
/// that is displayed in the dialog box. It also takes an optional [onSubmit]
/// parameter, which is a function that is called
/// when the user presses the submit button. The rest of the parameters are
/// optional and are used to customize the dialog box. The [onSubmit] function
/// is called with the text input by the user as a parameter. This function
/// returns a future that resolves when the dialog is closed.
///
/// The submit button renders filled — the house primary — and first in the
/// action row, which is the order every dialog in the app uses (audit ST-62,
/// CI-29). [validateInput] runs before the dialog pops: a non-null return is
/// shown under the text box and the dialog stays open, so a primary button
/// can never silently swallow an empty required field (audit CI-30).
dialog({
  required item,
  Function? onSubmit,
  bool bodyIsWidget = false,
  Widget bodyAsWidget = const Text(''),
  String title = '',
  String body = '',
  String submitText = '',
  ButtonStyle submitStyle = const ButtonStyle(),
  bool submitInput = true,
  bool centerText = false,
  String cancelText = '',
  Function? onCancel,
  BuildContext? hostContext,
  String placeholder = '',
  String? Function(String)? validateInput,
}) {
  // Get root context by Key. `GlobalVariable.infobox` is the *home* screen's
  // key, so a caller on another route has to hand over its own context or the
  // key resolves to an unmounted element (audit ST-04).
  final context = hostContext ?? GlobalVariable.infobox.currentContext!;
  final controller = TextEditingController();
  plausible.event(page: 'base_dialog');
  showDialog(
    context: context,
    builder: (context) {
      // The message a failed [validateInput] left behind; cleared the moment
      // the input changes, because a complaint about a state that no longer
      // exists is noise.
      String? validation;
      return StatefulBuilder(builder: (context, setState) {
        return ContentDialog(
          constraints: const BoxConstraints(maxHeight: 500.0, maxWidth: 500.0),
          title: centerText ? Center(child: Text(title)) : Text(title),
          content: SingleChildScrollView(
            child: Column(
              children: [
                !bodyIsWidget
                    ? centerText
                        ? Center(child: Text(body))
                        : Text(body)
                    : SizedBox(
                        width: double.infinity,
                        height: 120.0,
                        child: SingleChildScrollView(child: bodyAsWidget)),
                submitInput
                    ? Padding(
                        padding: const EdgeInsets.only(top: 10.0),
                        // The box used to show the *item* — the source's own
                        // name — as its placeholder, so an empty field read
                        // as pre-filled with exactly the value a user would
                        // accept (audit CI-30, ST-43).
                        child: TextBox(
                          autofocus: true,
                          controller: controller,
                          placeholder: placeholder,
                          onChanged: (_) {
                            if (validation != null) {
                              setState(() => validation = null);
                            }
                          },
                        ),
                      )
                    : const Text(''),
                if (validation != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        validation!,
                        key: const ValueKey('test-dialog-validation'),
                        style: TextStyle(
                            color: destructiveColor(context), fontSize: 12.0),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            submitText != ''
                ? FilledButton(
                    style: submitStyle,
                    onPressed: () {
                      final message = validateInput?.call(controller.text);
                      if (message != null) {
                        setState(() => validation = message);
                        return;
                      }
                      Navigator.pop(context);
                      if (onSubmit != null) {
                        onSubmit(controller.text);
                      }
                    },
                    child: Text(submitText))
                : Container(),
            // The safe action takes the initial focus. This dialog confirms
            // deletes, so opening it and hitting Tab, Enter — the reflex on a
            // modal — used to destroy the distro (audit IA-08). A dialog that
            // asks for text focuses the box instead.
            Button(
                key: const ValueKey('test-dialog-cancel'),
                autofocus: !submitInput,
                child:
                    Text(cancelText == '' ? 'cancel-text'.i18n() : cancelText),
                onPressed: () {
                  if (onCancel != null) {
                    onCancel();
                  }
                  Navigator.pop(context);
                }),
          ],
        );
      });
    },
  );
}
