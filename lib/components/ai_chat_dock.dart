// The shell's right-hand chat dock: the page on the left, the AI chat on the
// right, and a grab handle between them.
//
// The dock used to be a fixed 360px column (a share of the window below
// 1000px) with no way to change it — a long answer, a table or a code block
// was read three or four words per line while the page beside it sat mostly
// empty (ai-tasks#104). The handle drags the split, and the expand toggle
// gives the chat the whole page area. Both are remembered.
//
// It lives inside the shell's pane body, so "expanded" still leaves the
// navigation pane on the left in place — the chat takes the page, not the
// window.

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Builds the docked panel. [expanded] is the current state and
/// [toggleExpanded] flips it — the toggle sits in the panel's own header,
/// next to the buttons it belongs with.
typedef AiChatDockPanelBuilder = Widget Function(
  BuildContext context,
  bool expanded,
  VoidCallback toggleExpanded,
);

class AiChatDock extends StatefulWidget {
  const AiChatDock({
    super.key,
    required this.page,
    required this.statusBar,
    required this.panelBuilder,
  });

  /// What the dock sits beside.
  final Widget page;

  /// The shell's status and notification row. It belongs under the page
  /// while the two sit side by side; expanded, there is no page left to put
  /// it under, so it goes under the chat rather than disappearing with the
  /// page — a message about the very operation the assistant just started
  /// must not be the thing that vanishes.
  final Widget statusBar;

  final AiChatDockPanelBuilder panelBuilder;

  /// Narrower than this the panel's own header runs out of room.
  static const double minWidth = 300;

  /// The page keeps at least this much, so dragging the handle to the far
  /// left cannot hide the thing the chat is talking about.
  static const double minPageWidth = 320;

  /// The width the dock had before it could be resized, kept as the default.
  static const double defaultWidth = 360;

  /// The grab area around the 1px separator. Wider than the line it draws:
  /// a 1px target is not a target.
  static const double handleWidth = 8;

  /// How far one arrow key press moves the split.
  static const double keyboardStep = 24;

  static const String widthPrefsKey = 'AiPanelWidth';
  static const String expandedPrefsKey = 'AiPanelExpanded';

  /// A fixed 360px dock took 40% of a narrow window; below 1000px it scales
  /// with the window instead (audit PS-38). Only the starting width — once
  /// the user drags the handle, their width is used.
  static double defaultWidthFor(double available) =>
      available < 1000 ? (available * 0.36).roundToDouble() : defaultWidth;

  /// [width] brought inside what [available] can actually show.
  static double clampWidth(double width, double available) {
    final upper =
        math.max(math.min(minWidth, available), available - minPageWidth);
    final lower = math.min(minWidth, upper);
    return width.clamp(lower, upper);
  }

  @override
  State<AiChatDock> createState() => _AiChatDockState();
}

class _AiChatDockState extends State<AiChatDock> {
  /// The user's width, or null while they have not set one.
  double? _width;
  bool _expanded = false;

  /// The pane body width of the last layout pass — what a drag or an arrow
  /// key clamps against.
  double _available = 0;

  @override
  void initState() {
    super.initState();
    final storedWidth = prefs.getDouble(AiChatDock.widthPrefsKey);
    if (storedWidth != null && storedWidth > 0) _width = storedWidth;
    _expanded = prefs.getBool(AiChatDock.expandedPrefsKey) ?? false;
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    prefs.setBool(AiChatDock.expandedPrefsKey, _expanded);
  }

  /// Moves the split by [delta] logical pixels, positive widening the chat.
  void _resizeBy(double delta) {
    final current = _width ?? AiChatDock.defaultWidthFor(_available);
    final next = AiChatDock.clampWidth(current + delta, _available);
    if (next == _width) return;
    setState(() => _width = next);
    prefs.setDouble(AiChatDock.widthPrefsKey, next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _available = constraints.maxWidth;
        final panel =
            widget.panelBuilder(context, _expanded, _toggleExpanded);
        // Expanded: the chat takes the whole pane body — sized explicitly,
        // like the collapsed branch, so the panel fills it rather than
        // shrinking to its own content. The navigation pane is drawn
        // outside this widget, so it stays where it is.
        if (_expanded) {
          return SizedBox.expand(
            child: Column(
              children: [
                // Width spelled out rather than stretching the column: the
                // status row below keeps the alignment it has always had.
                Expanded(child: SizedBox(width: double.infinity, child: panel)),
                widget.statusBar,
              ],
            ),
          );
        }

        final width = AiChatDock.clampWidth(
          _width ?? AiChatDock.defaultWidthFor(_available),
          _available,
        );
        return Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  Expanded(child: widget.page),
                  widget.statusBar,
                ],
              ),
            ),
            AiChatDockHandle(
              onDrag: (dx) => _resizeBy(-dx),
              onNudge: (steps) => _resizeBy(-steps * AiChatDock.keyboardStep),
            ),
            SizedBox(width: width, child: panel),
          ],
        );
      },
    );
  }
}

/// The separator between the page and the chat, turned into a control.
///
/// A [HoverButton] rather than a bare `GestureDetector`: this is the only way
/// to change the split, and a `GestureDetector` has no focus node and no
/// semantics action, so a keyboard could not reach it at all (audit IA-04 —
/// enforced by keyboard_focus_test). It carries the drag, the hover and focus
/// states, and the arrow keys that move the split without a mouse.
class AiChatDockHandle extends StatelessWidget {
  const AiChatDockHandle({
    super.key,
    required this.onDrag,
    required this.onNudge,
  });

  /// Horizontal pointer movement, in logical pixels, rightwards positive.
  final ValueChanged<double> onDrag;

  /// One arrow key press: 1 for right, -1 for left.
  final ValueChanged<double> onNudge;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Semantics(
      slider: true,
      child: HoverButton(
        key: const ValueKey('test-chat-resize'),
        semanticLabel: 'ai-chat-resize-text'.i18n(),
        cursor: SystemMouseCursors.resizeLeftRight,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft): _NudgeIntent(-1),
          SingleActivator(LogicalKeyboardKey.arrowRight): _NudgeIntent(1),
        },
        customActions: {
          _NudgeIntent: CallbackAction<_NudgeIntent>(
            onInvoke: (intent) {
              onNudge(intent.steps);
              return null;
            },
          ),
        },
        builder: (context, states) {
          final active = states.isHovered || states.isFocused;
          return SizedBox(
            width: AiChatDock.handleWidth,
            child: Center(
              child: AnimatedContainer(
                duration: theme.fasterAnimationDuration,
                curve: theme.animationCurve,
                width: active ? 2 : 1,
                height: double.infinity,
                color: active ? theme.accentColor : surfaceBorderColor(context),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NudgeIntent extends Intent {
  const _NudgeIntent(this.steps);

  final double steps;
}
