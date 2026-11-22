import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/recommender_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/named_button.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Stateful, because dismissing a card has to take it off the screen.
///
/// The old panel wrote `DismissedRecommendations` and changed nothing — the
/// card stayed until something else happened to rebuild the page (audit
/// PS-41). Following a card's link also dismissed it as a side effect, so a
/// user who came back found the recommendation gone (PS-42).
class RecommendationsPanel extends StatefulWidget {
  final List<String> distroNames;

  const RecommendationsPanel({
    Key? key,
    required this.distroNames,
  }) : super(key: key);

  @override
  State<RecommendationsPanel> createState() => _RecommendationsPanelState();
}

class _RecommendationsPanelState extends State<RecommendationsPanel> {
  @override
  Widget build(BuildContext context) {
    final recommender = RecommenderService();
    // Dismissed cards are filtered *before* the empty check, so a panel whose
    // every recommendation was dismissed disappears instead of sitting as an
    // empty bordered box (audit PS-44).
    final recommendations = recommender
        .analyze(widget.distroNames)
        .where((rec) => !recommender.isDismissed(rec.key))
        .toList();

    if (recommendations.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardFillColor(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: surfaceBorderColor(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FluentIcons.lightbulb,
                size: 14,
                color: FluentTheme.of(context).accentColor,
              ),
              const SizedBox(width: 6),
              Text(
                'recommendations-title'.i18n(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: FluentTheme.of(context).accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...recommendations.map((rec) {
            return _buildRecommendationItem(
              context,
              rec,
              recommender,
            );
          }),
        ],
      ),
    );
  }

  Widget _buildRecommendationItem(
    BuildContext context,
    Recommendation rec,
    RecommenderService recommender,
  ) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).accentColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Expanded, not Flexible: the dismiss X sits at the card's right
          // edge instead of trailing the text by however wide it happens to
          // be (audit PS-45).
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rec.key.i18n(),
                  style: const TextStyle(fontSize: 12),
                ),
                if (rec.actionRoute != null) ...[
                  const SizedBox(height: 6),
                  // A link the keyboard can reach: as a GestureDetector the
                  // recommendation's only action was unfocusable (IA-04).
                  // Following it no longer dismisses the card (PS-42), and
                  // the label is one key with the destination as its
                  // placeholder, not three English fragments glued in Dart
                  // (PS-43, IA-21).
                  HyperlinkButton(
                    style: const ButtonStyle(
                      padding: WidgetStatePropertyAll(EdgeInsets.zero),
                    ),
                    onPressed: () => router.pushNamed(rec.actionRoute!),
                    child: Text(
                      'goto-text'.i18n([
                        rec.actionRoute == '/templates'
                            ? 'templates-text'.i18n()
                            : 'settings-text'.i18n()
                      ]),
                      style: TextStyle(
                        fontSize: 11,
                        color: FluentTheme.of(context).accentColor,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          NamedIconButton(
            key: ValueKey('test-recommendation-dismiss-${rec.key}'),
            label: 'dismissrecommendation-text'.i18n(),
            icon: FluentIcons.cancel,
            iconSize: 12,
            // setState is the whole fix: the card leaves the screen on the
            // click, not on the next unrelated rebuild (PS-41).
            onPressed: () => setState(() => recommender.dismiss(rec.key)),
          ),
        ],
      ),
    );
  }
}
