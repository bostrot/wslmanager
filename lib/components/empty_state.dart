import 'package:fluent_ui/fluent_ui.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// The centred icon-title-body block a screen shows instead of a list.
///
/// Extracted from the Containers screen when Kubernetes grew the same four
/// states (no tool installed, nothing configured, the backend refused, the
/// list is empty). One widget so the two screens cannot drift into two
/// different-looking ways of saying "there is nothing here"
/// (bostrot/ai-tasks#61).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;

  /// One line saying what is missing.
  final String title;

  /// What the user can do about it. Never an exception's `toString()` on its
  /// own — a message the reader can act on, with the technical text after it.
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color:
                    FluentTheme.of(context).accentColor.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(icon,
                  size: 26, color: FluentTheme.of(context).accentColor),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: secondaryTextColor(context), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
