import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/wsl_errors.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// A failure, told twice: the sentence first, the tool's own words on request.
///
/// Every error surface in the app used to render one of two things — a raw
/// `Exception.toString()`, or nothing at all. This is the shape the audit asks
/// for instead (FIX-05): an actionable sentence in the primary position and
/// the original output folded away underneath, still selectable so it can be
/// pasted into a bug report.
class ErrorBody extends StatelessWidget {
  const ErrorBody({
    super.key,
    required this.failure,
    this.leading,
    this.hint,
  });

  /// The failure to describe.
  final WslFailure failure;

  /// Optional sentence in front of the mapped one, e.g. "Could not start Ubuntu."
  final String? leading;

  /// Optional extra paragraph after it — the one remedy the caller knows and
  /// the error code does not, e.g. taking a disk offline in Disk Management.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final sentence = leading == null || leading!.isEmpty
        ? failure.message
        : '$leading ${failure.message}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectableText(sentence),
        if (hint != null && hint!.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(hint!),
        ],
        if (failure.hasDetails) ...[
          const SizedBox(height: 8),
          ErrorDetails(details: failure.details),
        ],
      ],
    );
  }
}

/// The collapsed "Technical details" disclosure on its own.
///
/// Split out because the create banner already has its own sentence and only
/// needs the disclosure part.
class ErrorDetails extends StatefulWidget {
  const ErrorDetails({super.key, required this.details});

  final String details;

  @override
  State<ErrorDetails> createState() => _ErrorDetailsState();
}

class _ErrorDetailsState extends State<ErrorDetails> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    // A plain toggle rather than fluent's Expander: the banner and the dialog
    // that host this are both height-constrained, and Expander insists on a
    // card of its own.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        HyperlinkButton(
          key: const ValueKey('test-error-details-toggle'),
          onPressed: () => setState(() => _open = !_open),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_open ? FluentIcons.chevron_up : FluentIcons.chevron_down,
                  size: 10.0),
              const SizedBox(width: 6),
              Text('errordetails-text'.i18n()),
            ],
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: SelectableText(
              widget.details,
              style: TextStyle(
                  fontSize: 12.0, color: secondaryTextColor(context)),
            ),
          ),
      ],
    );
  }
}
