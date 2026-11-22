import 'package:fluent_ui/fluent_ui.dart';

/// Re-exported so a caller can name a severity without pulling all of
/// fluent_ui into an api/ file.
export 'package:fluent_ui/fluent_ui.dart' show InfoBarSeverity;

/// Signature of the app-wide status bar callback.
///
/// [RootPageState.statusMsg] is the only implementation; tests install their
/// own stub. Keep the two in sync — this is a plain function type, so a stub
/// that is missing a named parameter fails to assign.
typedef NotifyMessage = void Function(
  String msg, {
  Duration? duration,
  InfoBarSeverity severity,
  bool loading,
  bool useWidget,
  bool leadingIcon,
  Widget widget,
});

/// How long a status message stays on screen when the caller does not say.
///
/// Messages used to live until the next one replaced them, so a "Created
/// instance" from the create screen followed the user around for minutes.
const Duration notifyDefaultDuration = Duration(seconds: 8);

/// Notification bar at the bottom of the screen
class Notify {
  static late NotifyMessage message;
  static late Notify instance;

  Notify() {
    instance = this;
  }
}

/// Widget
///
/// Returns a zero-sized widget while there is nothing to say: the empty bar
/// used to keep a 126x62 invisible hit target — and a tab stop — on every
/// screen.
Widget statusBuilder(
  String status,
  Widget statusWidget,
  bool loading,
  bool leadingIcon,
  InfoBarSeverity severity,
  VoidCallback onClose,
) {
  if (status.isEmpty) return const SizedBox.shrink();

  return Padding(
    padding: const EdgeInsets.fromLTRB(10.0, 4.0, 10.0, 10.0),
    child: InfoBar(
      title: status == 'WIDGET'
          ? SingleChildScrollView(
              scrollDirection: Axis.horizontal, child: statusWidget)
          : Text(status),
      action: loading
          ? const SizedBox.square(dimension: 20.0, child: ProgressRing())
          : null,
      severity: severity,
      isIconVisible: leadingIcon,
      // Closing a running operation only hid its progress; the work carried on
      // regardless, which is worse than offering no control at all.
      onClose: loading ? null : onClose,
    ),
  );
}
