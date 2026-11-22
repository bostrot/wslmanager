import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/badge_pill.dart';

/// Amber "BETA" pill marking features that ship before they are fully
/// polished. Amber rather than the accent color so it does not read as
/// [ProBadge]. The label stays untranslated. [BadgePill] carries the
/// geometry that centres the four capitals in it, and documents the one
/// offset it cannot correct.
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  /// The badge's wash and border colour.
  static const Color color = Color(0xFFFFBF00);

  /// The text colour, per brightness. Raw amber on its own wash measured
  /// **1.40:1** over a light background and 5.89:1 over a dark one — the one
  /// defect in the theme pass that dark mode passed and light mode failed
  /// (audit TL-05, PS-09). The darkened amber clears AA on the light wash.
  static Color foregroundFor(Brightness brightness) =>
      brightness == Brightness.dark ? color : const Color(0xFF7A5C00);

  @override
  Widget build(BuildContext context) {
    final foreground = foregroundFor(FluentTheme.of(context).brightness);
    return Semantics(
      label: 'beta-badge-label-text'.i18n(),
      excludeSemantics: true,
      child: Tooltip(
        message: 'beta-info-text'.i18n(),
        child: BadgePill(
          label: 'BETA',
          foreground: foreground,
          background: color.withValues(alpha: 0.18),
          border: color.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

/// Screen-level notice for pages that are beta in their entirety.
class BetaBanner extends StatelessWidget {
  const BetaBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return InfoBar(
      title: Text('beta-banner-title'.i18n()),
      content: Text('beta-info-text'.i18n()),
      severity: InfoBarSeverity.warning,
    );
  }
}

/// The [BetaBadge] as a `PaneItem.infoBadge`.
///
/// infoBadge, not a Row in the item's title — fluent_ui only extracts the pane
/// label from a literal Text title, so a Row renders an unnamed entry.
///
/// Below fluent's 1008px threshold the pane collapses to a 48px icon rail and
/// the badge has nowhere to go but *over* the item's glyph, hiding the
/// destination's only affordance (audit LN-10, PS-10) — so compact mode gets a
/// corner dot instead of the full pill. The dot carries the pill's accessible
/// name so the marker is still announced either way.
class BetaPaneBadge extends StatelessWidget {
  const BetaPaneBadge({super.key});

  /// The pane width below which fluent_ui shows the icon rail rather than the
  /// open pane.
  static const double compactPaneThreshold = 1008;

  /// The corner dot's diameter, in the compact rail.
  static const double dotSize = 8;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).size.width >= compactPaneThreshold) {
      return const BetaBadge();
    }
    return Semantics(
      label: 'beta-badge-label-text'.i18n(),
      excludeSemantics: true,
      child: Container(
        width: dotSize,
        height: dotSize,
        decoration: const BoxDecoration(
          color: BetaBadge.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
