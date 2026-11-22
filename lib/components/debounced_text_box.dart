import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

/// A [TextBox] that reports its value once it settles instead of once per
/// keystroke.
///
/// Extracted from the `wsl.conf` editor, where writing per character meant a
/// full in-distro `wsl.exe` invocation for every letter of a hostname (audit
/// wslconf-keys CC-5). Every config editor in the app has the same shape —
/// there is no Save button, the value is written when the user stops typing or
/// leaves the field — so the behaviour lives here rather than being written a
/// second time for `/etc/wsl-distribution.conf`.
///
/// [onCommit] is called with the current text when the debounce expires, when
/// the field loses focus, and on submit — but only when the value actually
/// changed since the last commit, so tabbing through a form writes nothing.
class DebouncedTextBox extends StatefulWidget {
  final String initialValue;
  final String? placeholder;
  final bool enabled;
  final Duration debounce;
  final Future<void> Function(String value) onCommit;

  const DebouncedTextBox({
    super.key,
    required this.initialValue,
    required this.onCommit,
    this.placeholder,
    this.enabled = true,
    this.debounce = const Duration(milliseconds: 700),
  });

  @override
  State<DebouncedTextBox> createState() => _DebouncedTextBoxState();
}

class _DebouncedTextBoxState extends State<DebouncedTextBox> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late String _committed;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _committed = widget.initialValue;
    _controller = TextEditingController(text: _committed);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(DebouncedTextBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A value replaced from the outside — a reload, or a different distro
    // selected — has to reach the box, but not while the user is mid-edit.
    if (widget.initialValue != oldWidget.initialValue &&
        widget.initialValue != _controller.text &&
        !_focusNode.hasFocus) {
      _committed = widget.initialValue;
      _controller.text = _committed;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    _timer?.cancel();
    final value = _controller.text;
    if (value == _committed) return;
    _committed = value;
    await widget.onCommit(value);
  }

  @override
  Widget build(BuildContext context) {
    return TextBox(
      controller: _controller,
      focusNode: _focusNode,
      enabled: widget.enabled,
      placeholder: widget.placeholder,
      onChanged: (_) {
        _timer?.cancel();
        _timer = Timer(widget.debounce, _commit);
      },
      onSubmitted: (_) => _commit(),
    );
  }
}
