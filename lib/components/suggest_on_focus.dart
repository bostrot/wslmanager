import 'package:fluent_ui/fluent_ui.dart';

/// A one-line suggestion for an [AutoSuggestBox].
///
/// fluent_ui's default tile lets a long label wrap onto a second line inside
/// a row of fixed height, which overflows the moment the box is narrower
/// than the label — the create forms cap their width, and the catalogue
/// names ("Debian 13 (cloud image)") are not short. An ellipsis keeps the
/// row intact; the full name is still what gets filled in on selection.
AutoSuggestBoxItem<String> suggestionItem(String label) =>
    AutoSuggestBoxItem<String>(
      value: label,
      label: label,
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );

/// Opens an [AutoSuggestBox]'s list as soon as its field is clicked or
/// focused, instead of fluent_ui's default of waiting for the first
/// keystroke.
///
/// The default hides every catalogue box in the app behind a guessing game:
/// the distro list on the Windows create page and the installer/cloud-image
/// list on the macOS one only appeared once the user typed a letter that
/// happened to match an entry (bostrot/ai-tasks#4). fluent_ui's
/// `_handleFocusChanged` deliberately skips the overlay while the text is
/// empty, so the fix has to come from outside.
///
/// [builder] is handed the key and focus node the box must be built with;
/// everything else about the box (controller, items, trailing widgets) stays
/// with the caller. Two paths open the list:
///
///  * a focus gain — a click on an unfocused field, or Tab reaching it;
///  * a click on a field that already has focus, which is what happens after
///    Escape closed the list and the user wants it back.
///
/// Choosing an item still closes the list: fluent_ui unfocuses the field on
/// selection, and the item tiles live in the overlay, outside this widget's
/// pointer listener, so nothing reopens it.
class SuggestOnFocus<T> extends StatefulWidget {
  const SuggestOnFocus({super.key, required this.builder, this.focusNode});

  final Widget Function(
    BuildContext context,
    GlobalKey<AutoSuggestBoxState<T>> boxKey,
    FocusNode focusNode,
  ) builder;

  /// A focus node the caller wants to keep control of. Left out, the widget
  /// owns (and disposes) one of its own.
  final FocusNode? focusNode;

  @override
  State<SuggestOnFocus<T>> createState() => _SuggestOnFocusState<T>();
}

class _SuggestOnFocusState<T> extends State<SuggestOnFocus<T>> {
  final GlobalKey<AutoSuggestBoxState<T>> _boxKey = GlobalKey();
  late FocusNode _node = widget.focusNode ?? FocusNode();

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(SuggestOnFocus<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode) {
      _node.removeListener(_onFocusChange);
      if (oldWidget.focusNode == null) _node.dispose();
      _node = widget.focusNode ?? FocusNode();
      _node.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_node.hasFocus) _open();
  }

  void _open() {
    if (!mounted) return;
    _boxKey.currentState?.showOverlay();
  }

  /// The tap that focuses the field is only recognised after the pointer
  /// goes up, and the focus itself lands a microtask later, so the check has
  /// to wait for the frame that follows. A click on a still-focused field
  /// (after Escape) reaches the same place without a focus change.
  void _onPointerUp(PointerUpEvent _) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _node.hasFocus) _open();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerUp: _onPointerUp,
      child: widget.builder(context, _boxKey, _node),
    );
  }
}
