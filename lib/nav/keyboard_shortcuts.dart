import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart' hide Page;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localization/localization.dart';
import 'package:url_launcher/url_launcher.dart';

/// Keyboard shortcuts that work anywhere in the shell, and the vocabulary the
/// Home list's own keys (`list.dart`) share with them.
///
/// Both are global [HardwareKeyboard] handlers rather than [Shortcuts]
/// widgets, for the reason `DistroListState._onKey` gives: after a click on
/// the pane or on blank space nothing below the shell holds focus, and a
/// focus-scoped binding would then never fire. The price is that each
/// handler has to stand aside on its own while somebody types or a dialog is
/// up — [textFieldHasFocus] and [popupHasKeyboard].

/// Whether "the command key" means ⌘ here rather than Ctrl.
bool get macShortcuts => !kIsWeb && Platform.isMacOS;

/// Ctrl on Windows and Linux, ⌘ on a Mac — and only that one, so Ctrl+N on a
/// Mac stays the terminal-style key it is there.
bool commandHeld() {
  final keyboard = HardwareKeyboard.instance;
  return macShortcuts
      ? keyboard.isMetaPressed && !keyboard.isControlPressed
      : keyboard.isControlPressed && !keyboard.isMetaPressed;
}

/// The command key and nothing else. Alt stays free so Alt+F4 and the
/// AltGr characters of European layouts (Ctrl+Alt underneath) never match.
bool onlyCommandHeld({bool shift = false}) {
  final keyboard = HardwareKeyboard.instance;
  return commandHeld() &&
      keyboard.isShiftPressed == shift &&
      !keyboard.isAltPressed;
}

bool noModifierHeld() {
  final keyboard = HardwareKeyboard.instance;
  return !keyboard.isControlPressed &&
      !keyboard.isMetaPressed &&
      !keyboard.isAltPressed &&
      !keyboard.isShiftPressed;
}

/// A text field (other than [except]) has the keyboard, so letters, Delete,
/// Home and End belong to it.
bool textFieldHasFocus({FocusNode? except}) {
  final focused = FocusManager.instance.primaryFocus;
  if (focused == null || focused == except) return false;
  final context = focused.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// A dialog, flyout or menu has the keyboard. Those keep their own keys —
/// Esc closes them — and nothing behind them may react.
bool popupHasKeyboard() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return ModalRoute.of(focused) is PopupRoute;
}

/// One key combination as the user reads it: "Ctrl+Shift+T" on Windows,
/// "⌘⇧T" on a Mac. [key] is either the literal key cap ("N", "F2", ",") or
/// an i18n key (ending in `-text`) for caps whose name is translated —
/// "Entf" and "Pos1" on a German keyboard.
class KeyCombo {
  const KeyCombo(this.key, {this.command = false, this.shift = false});

  final String key;
  final bool command;
  final bool shift;

  String get _cap => key.endsWith('-text') ? key.i18n() : key;

  String get label {
    if (macShortcuts) {
      return '${command ? '⌘' : ''}${shift ? '⇧' : ''}$_cap';
    }
    return [
      if (command) 'key-ctrl-text'.i18n(),
      if (shift) 'key-shift-text'.i18n(),
      _cap,
    ].join('+');
  }
}

/// The combinations the app answers to, in one place so the cheat sheet and
/// the tooltips cannot drift apart from what the handlers do.
class AppKeys {
  static const newInstance = KeyCombo('N', command: true);
  static const settings = KeyCombo(',', command: true);
  static const goToPage = KeyCombo('1…9', command: true);
  static const help = KeyCombo('F1');
  static const cheatSheet = KeyCombo('/', command: true);
  static const cheatSheetAlt = KeyCombo('?', shift: true);
  static const escape = KeyCombo('key-esc-text');

  static const filter = KeyCombo('F', command: true);
  static const reload = KeyCombo('F5');
  static const selectStep = KeyCombo('↑ / ↓');
  static const selectFirst = KeyCombo('key-home-text');
  static const selectLast = KeyCombo('key-end-text');
  static const open = KeyCombo('key-enter-text');
  static const terminal = KeyCombo('T', command: true, shift: true);
  static const stop = KeyCombo('S', command: true, shift: true);
  static const rename = KeyCombo('F2');
  static const duplicate = KeyCombo('D', command: true);

  /// A Mac keyboard's "delete" is backspace, and Finder deletes with ⌘⌫.
  static KeyCombo get delete => macShortcuts
      ? const KeyCombo('⌫', command: true)
      : const KeyCombo('key-delete-text');

  static String get nextPage => _tabLabel(shift: false);
  static String get previousPage => _tabLabel(shift: true);

  /// Ctrl+Tab is Ctrl on every platform, the way a browser has it.
  static String _tabLabel({required bool shift}) {
    if (macShortcuts) return '⌃${shift ? '⇧' : ''}⇥';
    return [
      'key-ctrl-text'.i18n(),
      if (shift) 'key-shift-text'.i18n(),
      'key-tab-text'.i18n(),
    ].join('+');
  }
}

/// "Rename (F2)": a control's tooltip with the key that does the same.
String withShortcut(String label, KeyCombo combo) => '$label (${combo.label})';

/// Whether [event] is the cheat-sheet key: Ctrl+/ (⌘/), or "?" typed on
/// whatever layout puts it under which key.
bool isCheatSheetKey(KeyEvent event) {
  if (event.logicalKey == LogicalKeyboardKey.slash && onlyCommandHeld()) {
    return true;
  }
  final keyboard = HardwareKeyboard.instance;
  return event.character == '?' &&
      !keyboard.isControlPressed &&
      !keyboard.isMetaPressed;
}

const documentationUrl = 'https://github.com/bostrot/wslmanager/wiki';

/// Shell-wide keys: new instance, settings, page switching, help and the
/// cheat sheet. Each fires only while nobody is typing and no dialog is up.
///
/// [destinations] are the pane's own entries in pane order, so Ctrl+3 is
/// always the third entry on screen and navigating reuses each entry's
/// guarded `onTap` instead of a second route table.
class AppShortcuts extends StatefulWidget {
  const AppShortcuts({
    super.key,
    required this.child,
    required this.destinations,
    required this.currentPath,
    this.onHelp,
  });

  final Widget child;
  final List<PaneItem> Function() destinations;
  final String Function() currentPath;

  /// F1. Opens the documentation unless a test hands in something else.
  final VoidCallback? onHelp;

  @override
  State<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends State<AppShortcuts> {
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  List<PaneItem> get _pages =>
      widget.destinations().where((item) => item.key != null).toList();

  bool _go(String path) {
    for (final item in _pages) {
      if (item.key == Key(path)) {
        item.onTap?.call();
        return true;
      }
    }
    return false;
  }

  bool _step(int delta) {
    final pages = _pages;
    if (pages.isEmpty) return false;
    final current = pages.indexWhere(
      (item) => item.key == Key(widget.currentPath()),
    );
    final next = current == -1
        ? (delta > 0 ? 0 : pages.length - 1)
        : (current + delta) % pages.length;
    pages[next].onTap?.call();
    return true;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    if (textFieldHasFocus() || popupHasKeyboard() || _sheetOpen) return false;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.keyN && onlyCommandHeld()) {
      return _go('/addinstance');
    }
    if (key == LogicalKeyboardKey.comma && onlyCommandHeld()) {
      return _go('/settings');
    }
    final digit = _digits.indexOf(key);
    if (digit != -1 && onlyCommandHeld()) {
      final pages = _pages;
      if (digit >= pages.length) return false;
      pages[digit].onTap?.call();
      return true;
    }
    if (key == LogicalKeyboardKey.tab) {
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed &&
          !keyboard.isMetaPressed &&
          !keyboard.isAltPressed) {
        return _step(keyboard.isShiftPressed ? -1 : 1);
      }
      return false;
    }
    if (key == LogicalKeyboardKey.f1 && noModifierHeld()) {
      (widget.onHelp ?? _openDocumentation)();
      return true;
    }
    if (isCheatSheetKey(event)) {
      _showSheet();
      return true;
    }
    return false;
  }

  Future<void> _showSheet() async {
    _sheetOpen = true;
    try {
      await showKeyboardShortcutsDialog(context);
    } finally {
      _sheetOpen = false;
    }
  }

  static void _openDocumentation() => launchUrl(Uri.parse(documentationUrl));

  @override
  Widget build(BuildContext context) => widget.child;
}

const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

class _ShortcutRow {
  const _ShortcutRow(this.keys, this.description);
  final List<String> keys;
  final String description;
}

/// The cheat sheet: every key the app answers to, read from [AppKeys].
Future<void> showKeyboardShortcutsDialog(BuildContext context) {
  final general = [
    _ShortcutRow([AppKeys.newInstance.label], 'addinstance-text'.i18n()),
    _ShortcutRow([AppKeys.settings.label], 'settings-text'.i18n()),
    _ShortcutRow([AppKeys.goToPage.label], 'shortcutgotopage-text'.i18n()),
    _ShortcutRow([
      AppKeys.nextPage,
      AppKeys.previousPage,
    ], 'shortcutnextpage-text'.i18n()),
    _ShortcutRow([AppKeys.help.label], 'documentation-text'.i18n()),
    _ShortcutRow([
      AppKeys.cheatSheet.label,
      AppKeys.cheatSheetAlt.label,
    ], 'shortcutshowlist-text'.i18n()),
    _ShortcutRow([AppKeys.escape.label], 'shortcutescape-text'.i18n()),
  ];
  final instances = [
    _ShortcutRow([AppKeys.filter.label], 'filterinstances-text'.i18n()),
    _ShortcutRow([AppKeys.reload.label], 'shortcutreload-text'.i18n()),
    _ShortcutRow([AppKeys.selectStep.label], 'shortcutselect-text'.i18n()),
    _ShortcutRow([
      AppKeys.selectFirst.label,
      AppKeys.selectLast.label,
    ], 'shortcutselectends-text'.i18n()),
    _ShortcutRow([
      AppKeys.open.label,
      'doubleclick-text'.i18n(),
    ], 'shortcutstartorterminal-text'.i18n()),
    _ShortcutRow([AppKeys.terminal.label], 'shortcutterminal-text'.i18n()),
    _ShortcutRow([AppKeys.stop.label], 'stop-text'.i18n()),
    _ShortcutRow([AppKeys.rename.label], 'rename-text'.i18n()),
    _ShortcutRow([AppKeys.duplicate.label], 'copy-text'.i18n()),
    _ShortcutRow([AppKeys.delete.label], 'delete-text'.i18n()),
  ];
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => ContentDialog(
      key: const ValueKey('test-shortcuts-dialog'),
      constraints: const BoxConstraints(maxWidth: 560.0),
      title: Text('keyboardshortcuts-text'.i18n()),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section(context, 'shortcutsgeneral-text'.i18n(), general),
            const SizedBox(height: 16),
            _section(context, 'shortcutsinstances-text'.i18n(), instances),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('test-shortcuts-close'),
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: Text('close-text'.i18n()),
        ),
      ],
    ),
  );
}

Widget _section(BuildContext context, String title, List<_ShortcutRow> rows) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: FluentTheme.of(context).typography.bodyStrong),
      const SizedBox(height: 6),
      for (final row in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(row.description)),
              const SizedBox(width: 12),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [for (final key in row.keys) _KeyCap(key)],
              ),
            ],
          ),
        ),
    ],
  );
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.resources.controlStrokeColorDefault),
        borderRadius: BorderRadius.circular(4),
        color: theme.resources.controlFillColorSecondary,
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
