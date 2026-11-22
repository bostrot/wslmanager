import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';

/// What the user picked when asked about unsaved edits.
enum UnsavedChangesChoice { save, discard, cancel }

/// The one screen that currently holds unsaved edits, if any.
///
/// Settings threw away every edit made before Save was pressed: clicking Home
/// in the nav pane simply built the next screen, and the `dispose()` that was
/// meant to commit observably never fired (audit ST-01). Rather than teach
/// every navigation call site about the settings screen, a dirty screen
/// registers a guard here and each exit route asks [confirmLeave] first.
class UnsavedChangesGuard {
  UnsavedChangesGuard._();

  static Future<bool> Function()? _guard;

  /// True while some screen holds unsaved edits.
  static bool get isDirty => _guard != null;

  /// Register [guard]; it resolves true when leaving is allowed. Registering
  /// twice replaces the previous guard — only one screen is on screen at a
  /// time.
  static void register(Future<bool> Function() guard) => _guard = guard;

  /// Drop [guard], but only while it is still the registered one, so a screen
  /// disposing after its replacement registered cannot clear the new guard.
  static void release(Future<bool> Function() guard) {
    if (identical(_guard, guard)) _guard = null;
  }

  /// Forget any guard. For tests and for the paths that have already committed.
  static void reset() => _guard = null;

  /// Whether the caller may leave the current screen.
  static Future<bool> confirmLeave() async {
    final guard = _guard;
    if (guard == null) return true;
    return guard();
  }
}

/// The Save / Discard / Cancel prompt shown when a dirty screen is left.
Future<UnsavedChangesChoice> showUnsavedChangesDialog(
    BuildContext context) async {
  final choice = await showDialog<UnsavedChangesChoice>(
    context: context,
    builder: (dialogContext) => ContentDialog(
      title: Text('unsavedchanges-title'.i18n()),
      content: Text('unsavedchanges-text'.i18n()),
      actions: [
        Button(
          key: const ValueKey('test-unsaved-cancel'),
          onPressed: () =>
              Navigator.pop(dialogContext, UnsavedChangesChoice.cancel),
          child: Text('cancel-text'.i18n()),
        ),
        Button(
          key: const ValueKey('test-unsaved-discard'),
          onPressed: () =>
              Navigator.pop(dialogContext, UnsavedChangesChoice.discard),
          child: Text('discardchanges-text'.i18n()),
        ),
        FilledButton(
          key: const ValueKey('test-unsaved-save'),
          onPressed: () =>
              Navigator.pop(dialogContext, UnsavedChangesChoice.save),
          child: Text('save-text'.i18n()),
        ),
      ],
    ),
  );
  // Dismissed by Escape or a tap outside: the safe reading is "I did not mean
  // to leave", never "throw the edits away".
  return choice ?? UnsavedChangesChoice.cancel;
}
