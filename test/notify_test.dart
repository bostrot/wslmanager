/// Tests for lib/components/notify.dart — the app-wide status bar.
///
/// Covers the audit findings the status bar is the root cause of:
/// CI-19 / PS-46 (one decoration for every outcome), IA-02 (an empty bar that
/// still takes space and clicks), IA-14 (a close button on a running
/// operation) and CI-20 / TL-14 (severity shouted in the message text).
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/components/notify.dart';

Widget _wrap(Widget child) => FluentApp(home: ScaffoldPage(content: child));

void main() {
  group('statusBuilder', () {
    testWidgets('renders nothing at all while there is no message',
        (tester) async {
      final bar = statusBuilder(
        '',
        const Text(''),
        false,
        true,
        InfoBarSeverity.info,
        () {},
      );
      // Mirrors the real layout: the bar is the last child of a column whose
      // other child takes the remaining height.
      await tester.pumpWidget(_wrap(Column(
        children: [const Expanded(child: SizedBox.expand()), bar],
      )));

      expect(find.byType(InfoBar), findsNothing);
      // IA-02: the empty bar used to keep a 126x62 invisible hit target and a
      // tab stop on every screen.
      expect(bar, isA<SizedBox>());
      expect(tester.getSize(find.byWidget(bar)), Size.zero);
    });

    testWidgets('carries the severity it was given through to the InfoBar',
        (tester) async {
      for (final severity in InfoBarSeverity.values) {
        await tester.pumpWidget(_wrap(statusBuilder(
          'something happened',
          const Text(''),
          false,
          true,
          severity,
          () {},
        )));

        final bar = tester.widget<InfoBar>(find.byType(InfoBar));
        expect(bar.severity, severity);
      }
    });

    testWidgets('offers no close button while an operation is running',
        (tester) async {
      await tester.pumpWidget(_wrap(statusBuilder(
        'working',
        const Text(''),
        true,
        true,
        InfoBarSeverity.info,
        () {},
      )));

      // IA-14: closing only hid the progress — the work carried on.
      expect(tester.widget<InfoBar>(find.byType(InfoBar)).onClose, isNull);
      expect(find.byType(ProgressRing), findsOneWidget);
    });

    testWidgets('is closable once the operation has finished', (tester) async {
      var closed = false;
      await tester.pumpWidget(_wrap(statusBuilder(
        'done',
        const Text(''),
        false,
        true,
        InfoBarSeverity.success,
        () => closed = true,
      )));

      tester.widget<InfoBar>(find.byType(InfoBar)).onClose!();
      expect(closed, isTrue);
      expect(find.byType(ProgressRing), findsNothing);
    });

    testWidgets('honours the leading-icon flag', (tester) async {
      await tester.pumpWidget(_wrap(statusBuilder(
        'quiet',
        const Text(''),
        false,
        false,
        InfoBarSeverity.info,
        () {},
      )));

      expect(tester.widget<InfoBar>(find.byType(InfoBar)).isIconVisible,
          isFalse);
    });
  });

  group('message text', () {
    late Map<String, dynamic> en;

    setUpAll(() {
      en = jsonDecode(File('lib/i18n/en.json').readAsStringSync())
          as Map<String, dynamic>;
    });

    test('no user-facing string shouts its own severity', () {
      // CI-20 / TL-14: the InfoBar carries the severity now, so the message
      // must not repeat it — least of all in capitals that eight locales each
      // translated differently ("TAMAM:", "KÉSZ:", "CONCLUÍDO:").
      final shouting = RegExp(r'^(DONE|ERROR|WARNING|FAILED|SUCCESS)\s*:');
      final offenders = <String>[];
      en.forEach((key, value) {
        if (value is String && shouting.hasMatch(value)) offenders.add(key);
      });
      expect(offenders, isEmpty,
          reason: 'severity belongs on the InfoBar, not in the string');
    });

    test('the in-flight messages exist and take the distro name', () {
      for (final key in [
        'startinginstance-text',
        'stoppinginstance-text',
        'deletinginstance-text',
      ]) {
        expect(en, contains(key));
        expect(en[key], contains('%s'),
            reason: '$key has to name the distro it is talking about');
      }
    });
  });

  test('a message without a spinner expires on its own', () {
    // CI-18: messages used to live until the next one replaced them, which is
    // how a "Created instance" toast followed the user across screens.
    expect(notifyDefaultDuration.inSeconds, greaterThan(0));
    expect(notifyDefaultDuration.inMinutes, lessThan(1));
  });
}
