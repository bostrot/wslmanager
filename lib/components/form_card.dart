import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The heading block a full-page form opens with.
///
/// A bare `titleLarge` line over a paragraph of grey text is what both create
/// screens used to start with, and on a 640px column it read as the top of a
/// wall rather than the start of a form (bostrot/ai-tasks#50). The icon in its
/// accent wash gives the page a fixed point, and the description keeps its
/// place under the title instead of running the full width.
class FormPageHeader extends StatelessWidget {
  const FormPageHeader({
    super.key,
    required this.icon,
    required this.title,
    this.description,
  });

  /// Decorative: [title] next to it carries the meaning.
  final IconData icon;
  final String title;

  /// One or two lines of context under the title, or null for none.
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor.defaultBrushFor(theme.brightness);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: theme.typography.subtitle),
              if (description != null) ...[
                const SizedBox(height: 4),
                Text(description!,
                    style: TextStyle(color: secondaryTextColor(context))),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One titled group of fields inside a long form.
///
/// The create screens were a single flat column of a dozen controls, each the
/// same weight as the next and grouped only by how far apart two
/// `Container(height: 10)`s happened to sit. A card gives every group a
/// surface, a heading and one consistent gap between its fields, so "what does
/// this VM boot from" can be found without reading every label above it.
class FormCard extends StatelessWidget {
  const FormCard({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.spacing = 12.0,
  });

  /// Decorative: [title] next to it carries the meaning.
  final IconData icon;
  final String title;

  /// The fields, laid out in a column with [spacing] between them. A null
  /// entry is dropped rather than laid out, so a control that is hidden for
  /// the current selection does not leave a gap behind — the old form used
  /// an empty `Container()` for that and kept the spacing around it.
  final List<Widget?> children;

  /// The gap between two fields of the same group.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final fields = children.whereType<Widget>().toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardFillColor(context),
        border: Border.all(color: surfaceBorderColor(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon,
                  size: 14,
                  color: theme.accentColor.defaultBrushFor(theme.brightness)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 12.0, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) SizedBox(height: spacing),
            fields[i],
          ],
        ],
      ),
    );
  }
}
