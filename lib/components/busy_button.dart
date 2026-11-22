import 'package:fluent_ui/fluent_ui.dart';

/// A button that keeps its shape and its name while it is working.
///
/// The pattern this replaces was `child: busy ? SizedBox.square(dimension: 16,
/// child: ProgressRing()) : Text(label)`, written out at five call sites. It
/// shrank the Create button from 64 px to 38 px the instant it was pressed and
/// dragged the Cancel button 26 px sideways with it (audit CI-15), and it also
/// threw the label away — a spinner alone says something is happening, not
/// what.
///
/// So the spinner sits *next to* a retained label, and [minWidth] holds the
/// floor so a shorter busy label cannot make the row jump either.
class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.busyLabel,
    this.filled = false,
    this.minWidth = 88.0,
  });

  /// Shown when idle, and while busy unless [busyLabel] is given.
  final String label;

  /// Shown instead of [label] while [busy] — "Creating…" rather than "Create".
  final String? busyLabel;

  final bool busy;

  /// `null` disables the button. A busy button is normally also disabled, but
  /// not always: a Cancel stays live while the work it cancels runs.
  final VoidCallback? onPressed;

  /// [FilledButton] rather than [Button], for the primary action in a row.
  final bool filled;

  /// The width the button will not go below, busy or idle.
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy) ...[
          const SizedBox.square(
            dimension: 14,
            child: ProgressRing(strokeWidth: 2.0),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            busy ? (busyLabel ?? label) : label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final child = ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: content,
    );
    return filled
        ? FilledButton(onPressed: onPressed, child: child)
        : Button(onPressed: onPressed, child: child);
  }
}
