import 'package:fluent_ui/fluent_ui.dart';

/// An icon-only button that carries an accessible name.
///
/// A `fluent_ui` `IconButton` opens its own semantics container, so a `Tooltip`
/// wrapped around one never reaches the button's node — the pair has to be
/// merged before the name is announced at all (AGENTS.md). Nineteen controls
/// across nine files were missing one half of that pair or both, and the seven
/// with no tooltip at all were unnamed for sighted users too (audit IA-09,
/// IA-11), so the pattern lives here once instead of being retyped per call
/// site.
///
/// [label] is both the hover tooltip and the accessible name: an icon-only
/// control has nothing else to be called.
class NamedIconButton extends StatelessWidget {
  const NamedIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.iconSize,
  });

  /// The accessible name, shown on hover and announced by a screen reader.
  final String label;

  final IconData icon;

  /// `null` disables the button; the name is still announced.
  final VoidCallback? onPressed;

  /// Passed straight to [Icon]; `null` keeps the ambient icon size.
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Tooltip(
        message: label,
        child: IconButton(
          icon: Icon(icon, size: iconSize),
          onPressed: onPressed,
        ),
      ),
    );
  }
}
