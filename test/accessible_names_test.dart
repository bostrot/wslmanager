/// Tests for the accessible-name slice of the UI/UX audit (FIX-07): the
/// wrapper that names an icon-only control actually puts the name on the
/// button's own semantics node, no tap target in `lib/` is left without one,
/// and the two places where a name has to come from `Semantics(label:)`
/// rather than a tooltip carry one.
// ignore_for_file: dangling_library_doc_comments

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/beta_badge.dart';
import 'package:wsl2distromanager/components/named_button.dart';

/// Index of the `)` closing the `(` at [open], ignoring parentheses inside
/// string literals. Line-based matching cannot tell an icon-only button from
/// one that also carries a `Text`.
int _matchParen(String s, int open) {
  var depth = 0;
  var inStr = false;
  var quote = '';
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (inStr) {
      if (c == r'\') {
        i++;
        continue;
      }
      if (c == quote) inStr = false;
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      quote = c;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return s.length - 1;
}

int _lineOf(String s, int idx) =>
    '\n'.allMatches(s.substring(0, idx)).length + 1;

/// Every tap target in `lib/` that renders an icon and no text, paired with
/// whether it has an accessible name.
List<String> _unnamedTapTargets() {
  final offenders = <String>[];
  final files = <File>[];
  for (final entity in Directory('lib').listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final src = file.readAsStringSync();
    final path = file.path.replaceAll(r'\', '/');

    void check(RegExpMatch m, {required bool iconOnlyRequired}) {
      final body = src.substring(m.start, _matchParen(src, m.end - 1) + 1);
      if (iconOnlyRequired && (body.contains('Text(') || !body.contains('Icon('))) {
        return;
      }
      // Far enough back to cover Padding(child: MergeSemantics(child:
      // Tooltip(child: <button>.
      final before =
          src.substring((m.start - 400).clamp(0, src.length), m.start);
      if (before.contains('Tooltip(') && before.contains('MergeSemantics(')) {
        return;
      }
      offenders.add('$path:${_lineOf(src, m.start)}');
    }

    // NamedIconButton *is* the MergeSemantics(Tooltip(IconButton)) pair, so
    // its call sites are named by construction and its own IconButton is
    // covered by the lookback.
    for (final m in RegExp(r'(?<!Named)\bIconButton\(').allMatches(src)) {
      final body = src.substring(m.start, _matchParen(src, m.end - 1) + 1);
      if (body.contains('Text(')) continue;
      check(m, iconOnlyRequired: false);
    }
    for (final m in RegExp(r'\b(FilledButton|HyperlinkButton|Button)\(')
        .allMatches(src)) {
      check(m, iconOnlyRequired: true);
    }
  }
  return offenders;
}

void main() {
  group('NamedIconButton', () {
    testWidgets('puts the label on the button semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        FluentApp(
          home: ScaffoldPage(
            content: Center(
              child: NamedIconButton(
                label: 'Copy the token',
                icon: FluentIcons.copy,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      final node = tester.getSemantics(find.byType(NamedIconButton));
      expect(node.label, 'Copy the token');
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
    });

    testWidgets('keeps the name when the button is disabled', (tester) async {
      // A control the user cannot reach the point of is still a control they
      // have to be able to identify.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const FluentApp(
          home: ScaffoldPage(
            content: Center(
              child: NamedIconButton(
                label: 'Reset to the default',
                icon: FluentIcons.undo,
                onPressed: null,
              ),
            ),
          ),
        ),
      );

      final node = tester.getSemantics(find.byType(NamedIconButton));
      expect(node.label, 'Reset to the default');
      expect(node.hasFlag(SemanticsFlag.isEnabled), isFalse);
      handle.dispose();
    });

    testWidgets('carries the same string as its hover tooltip', (tester) async {
      // IA-11: the seven pickers with no tooltip were unnamed for sighted
      // users too, so the accessible name and the tooltip are one string.
      await tester.pumpWidget(
        FluentApp(
          home: ScaffoldPage(
            content: Center(
              child: NamedIconButton(
                label: 'Choose folder',
                icon: FluentIcons.open_folder_horizontal,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );

      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        'Choose folder',
      );
    });
  });

  group('accessible names', () {
    test('no icon-only tap target in lib/ is left without a name', () {
      // Counted, not sampled: 22 of the app's 38 tap targets had no
      // accessible name at all (audit IA-09), and a fluent_ui IconButton
      // opens its own semantics container, so the Tooltip has to be merged
      // into it or the name never arrives.
      expect(_unnamedTapTargets(), isEmpty);
    });

    testWidgets('the BETA pill announces more than the four letters',
        (tester) async {
      // IA-10: the app had no Semantics(label:) anywhere, so anything that is
      // decoration rather than a control was silent by construction.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const FluentApp(
          home: ScaffoldPage(content: Center(child: BetaBadge())),
        ),
      );

      expect(tester.getSemantics(find.byType(BetaBadge)).label,
          'beta-badge-label-text');
      handle.dispose();
    });
  });
}
