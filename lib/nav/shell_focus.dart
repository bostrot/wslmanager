import 'package:fluent_ui/fluent_ui.dart';

/// Marks the subtree that renders the current page, so [ShellTraversalPolicy]
/// can tell page content apart from the shell's own chrome — the navigation
/// pane and the app bar.
///
/// It has to sit *outside* the body's [FocusTraversalGroup]: a nested group is
/// handed to the parent policy as a single node whose context is the group's
/// own, not one of its members'.
class ShellBodyScope extends InheritedWidget {
  const ShellBodyScope({super.key, required super.child});

  /// Whether [context] is inside a body. Deliberately a lookup rather than a
  /// dependency — a traversal policy has no element to rebuild.
  static bool contains(BuildContext? context) =>
      context?.getInheritedWidgetOfExactType<ShellBodyScope>() != null;

  @override
  bool updateShouldNotify(ShellBodyScope oldWidget) => false;
}

/// Whether the app is in the dead state audit IA-01 measured: focus parked on
/// the root scope, where Tab has nowhere to go and no key gets it out again.
///
/// Anything else holding focus is left alone — an open dialog, a text box the
/// user is typing in and a control they just clicked all focus a node below
/// the root scope, and stealing that back would be worse than the bug.
bool shouldAdoptKeyboardFocus() {
  final primary = FocusManager.instance.primaryFocus;
  return primary == null || primary == FocusManager.instance.rootScope;
}

/// Tab order that follows the screen instead of the widget tree.
///
/// fluent_ui builds the pane after the body, so the measured cycle ran
/// content -> app bar -> navigation pane: the first thing on screen was the
/// last thing a keyboard could reach (audit IA-05). Chrome sorts first, page
/// content after it; inside each half the normal reading order applies, which
/// puts the app bar above the pane and the pane left of the page.
class ShellTraversalPolicy extends ReadingOrderTraversalPolicy {
  @override
  Iterable<FocusNode> sortDescendants(
    Iterable<FocusNode> descendants,
    FocusNode currentNode,
  ) {
    final chrome = <FocusNode>[];
    final content = <FocusNode>[];
    for (final node in descendants) {
      (ShellBodyScope.contains(node.context) ? content : chrome).add(node);
    }
    if (chrome.isEmpty || content.isEmpty) {
      return super.sortDescendants(descendants, currentNode);
    }
    return [
      ...super.sortDescendants(chrome, currentNode),
      ...super.sortDescendants(content, currentNode),
    ];
  }
}
