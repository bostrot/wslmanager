import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/dialogs/backup_dialog.dart';

/// The "Back up & restore" section of Settings: the two buttons that open
/// [BackupDialog], on the side the user asked for
/// (bostrot/ai-tasks#89, upstream bostrot/wsl2-distro-manager#203).
///
/// Settings rather than the instance list, which is where this first landed:
/// the list is about the instance under the pointer, and a control above it
/// that acts on *all* of them reads as one more per-instance action. It is
/// also not a nav pane entry — the pane runs out of height before it runs
/// out of entries at 800x600 (see the note on Cloud in nav/panelist.dart).
///
/// Two buttons instead of one, because the two halves are reached from
/// opposite ends: a backup is something you decide to do, a restore is
/// something you came here for. The dialog can still switch between them.
class BackupSettingsSection extends StatelessWidget {
  const BackupSettingsSection({super.key, this.isRemote, this.onOpen});

  /// Whether the app is driving a remote host. The Settings screen passes
  /// it so that a change there reaches this section; left out, it is read
  /// from the preferences.
  final bool? isRemote;

  /// How the buttons open the dialog. The seam the widget tests replace, so
  /// a test does not have to drive the whole dialog to check the section.
  final void Function(BuildContext context, {required bool restore})? onOpen;

  static const Key backupKey = ValueKey('test-settings-backup');
  static const Key restoreKey = ValueKey('test-settings-restore');
  static const Key remoteKey = ValueKey('test-settings-backup-remote');

  /// Nothing here works against a remote host: `wsl --export` runs on that
  /// machine and writes to its disk, while the folder picked in the dialog
  /// is on this one. Said here, with the buttons disabled, rather than
  /// hiding the section — a setting that is missing sends people looking
  /// for it, and the answer they need is the sentence, not the absence.
  ///
  /// [remoteWslActive] rather than a backend's `isRemote`: the two agree on
  /// every host, and this one is a preference read with its own guard, not
  /// a constructor with a side effect.
  bool get _remote => isRemote ?? remoteWslActive;

  void _open(BuildContext context, {required bool restore}) {
    final open = onOpen;
    if (open != null) {
      open(context, restore: restore);
      return;
    }
    showBackupDialog(context, restore: restore);
  }

  @override
  Widget build(BuildContext context) {
    final remote = _remote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('backupsettingsinfo-text'.i18n()),
        const SizedBox(height: 12.0),
        if (remote) ...[
          InfoBar(
            key: remoteKey,
            title: Text('backupremote-title'.i18n()),
            content: Text('backupremote-text'.i18n()),
            severity: InfoBarSeverity.warning,
          ),
          const SizedBox(height: 12.0),
        ],
        Row(
          children: [
            FilledButton(
              key: backupKey,
              onPressed: remote ? null : () => _open(context, restore: false),
              child: Text('backup-text'.i18n()),
            ),
            const SizedBox(width: 8.0),
            Button(
              key: restoreKey,
              onPressed: remote ? null : () => _open(context, restore: true),
              child: Text('restore-text'.i18n()),
            ),
          ],
        ),
      ],
    );
  }
}
