import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Hover feedback that adds contrast instead of removing it.
///
/// The old version signalled hover with `Opacity(0.5)` — the one hover state
/// in the app that made its row *harder* to read, and the only feedback the
/// row gave (audit IA-22). A subtle fill behind the child is the same signal
/// every fluent control uses.
class Hoverable extends StatefulWidget {
  const Hoverable({super.key, required this.child});
  final Widget child;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool isHovering = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
        cursor: SystemMouseCursors.click,
        onExit: (PointerExitEvent event) {
          // Do not change state if already hovering
          if (isHovering) {
            setState(() {
              isHovering = false;
            });
          }
        },
        onEnter: (PointerEnterEvent event) {
          // Do not change state if already hovering
          if (!isHovering) {
            setState(() {
              isHovering = true;
            });
          }
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isHovering ? subtleFillColor(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(4.0),
          ),
          child: widget.child,
        ));
  }
}
