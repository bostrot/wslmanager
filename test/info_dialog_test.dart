/// The About dialog (ai-tasks#25): identity and plan up top, one named tile
/// per destination, the usage-data status readable without opening anything,
/// and a way to copy the version for a bug report.
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed — which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_analytics/plausible_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/info_dialog.dart';
import 'package:wsl2distromanager/oss_licenses.dart';

class _MockPlausible implements Plausible {
  @override
  bool enabled = true;

  @override
  Future<int> event(
          {String? name,
          String? page,
          Map<String, String>? props,
          String? referrer,
          PlausibleRevenue? revenue,
          bool interactive = true}) async =>
      200;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late List<String> copied;
  late List<String> notified;

  setUpAll(() {
    Notify();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    plausible = _MockPlausible();

    notified = [];
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      notified.add(msg);
    };

    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Opens the dialog the way the navigation pane does, through [infoDialog],
  /// from a host context so the home screen need not be mounted.
  Future<void> pumpAndOpen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(FluentApp(
      home: ScaffoldPage(
        content: Builder(
          builder: (context) => Button(
            child: const Text('open'),
            onPressed: () => infoDialog(prefs, '1.11.0', hostContext: context),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the app name, version, platform and plan', (tester) async {
    await pumpAndOpen(tester);

    expect(find.byType(AppAboutDialog), findsOneWidget);
    expect(find.text('WSL Manager'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('test-about-version')),
            matching: find.text('v1.11.0')),
        findsOneWidget);
    // No licence in the test environment: the plan chip says so, rather
    // than being hidden — a user asking "am I on Pro?" looks here.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('test-about-plan')),
            matching: find.text('plan-free')),
        findsOneWidget);
    expect(find.text('about-tagline'), findsOneWidget);
  });

  testWidgets('every destination is a titled tile with a description',
      (tester) async {
    await pumpAndOpen(tester);

    for (final pair in const {
      'visitgithub-text': 'about-github-desc',
      'changelog-text': 'about-changelog-desc',
      'documentation-text': 'about-documentation-desc',
      'donate-text': 'about-donate-desc',
      'dependencies-text': 'about-dependencies-desc',
      'license-text': 'about-license-desc',
    }.entries) {
      expect(find.text(pair.key), findsOneWidget, reason: pair.key);
      expect(find.text(pair.value), findsOneWidget, reason: pair.value);
    }
    // Six links plus the privacy row, all keyboard-reachable tiles (IA-04).
    expect(find.byType(AboutTile), findsNWidgets(7));
  });

  testWidgets('the privacy tile reads the stored choice', (tester) async {
    SharedPreferences.setMockInitialValues({'privacyMode': true});
    prefs = await SharedPreferences.getInstance();
    await pumpAndOpen(tester);

    final privacy = find.byKey(const ValueKey('test-about-privacy'));
    expect(
        find.descendant(
            of: privacy, matching: find.text('notsharingdata-text')),
        findsOneWidget);
    expect(
        find.descendant(of: privacy, matching: find.text('sharingdata-text')),
        findsNothing);
  });

  testWidgets('changing the usage-data choice redraws the privacy tile',
      (tester) async {
    await pumpAndOpen(tester);
    final privacy = find.byKey(const ValueKey('test-about-privacy'));
    expect(
        find.descendant(of: privacy, matching: find.text('sharingdata-text')),
        findsOneWidget);

    await tester.tap(privacy);
    await tester.pumpAndSettle();
    // The usage-data dialog: "Do not share" is its filled submit button.
    expect(find.text('usagedata-text'), findsOneWidget);
    await tester.tap(find.text('donotshare-text'));
    await tester.pumpAndSettle();

    expect(prefs.getBool('privacyMode'), isTrue);
    expect(find.byType(AppAboutDialog), findsOneWidget,
        reason: 'the About dialog stays open underneath');
    expect(
        find.descendant(
            of: privacy, matching: find.text('notsharingdata-text')),
        findsOneWidget);
  });

  testWidgets('the dependencies tile opens a scrollable package list',
      (tester) async {
    await pumpAndOpen(tester);

    await tester.tap(find.text('dependencies-text'));
    await tester.pumpAndSettle();

    expect(find.byType(DependencyList), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    // Sorted by name, so the alphabetically first package heads the list;
    // the rest is built lazily as the user scrolls.
    final names = ossLicenses.map((p) => p.name.toLowerCase()).toList()..sort();
    final first =
        ossLicenses.firstWhere((p) => p.name.toLowerCase() == names.first);
    expect(find.text(first.name), findsOneWidget);
    expect(find.text(first.version), findsWidgets);
  });

  testWidgets('copy puts the version and host on the clipboard',
      (tester) async {
    await pumpAndOpen(tester);

    await tester.tap(find.byKey(const ValueKey('test-about-copy')));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, startsWith('WSL Manager 1.11.0'));
    expect(notified, ['copied-text']);
  });

  testWidgets('a single filled Close button dismisses the dialog',
      (tester) async {
    await pumpAndOpen(tester);

    // One action, filled: there is nothing to confirm or cancel here.
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('test-about-close')));
    await tester.pumpAndSettle();

    expect(find.byType(AppAboutDialog), findsNothing);
  });
}
