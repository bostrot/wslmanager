/// The community script browser.
///
/// Replaces the 420px modal that showed a flat list of names. The catalogue
/// is now big enough that finding something in it is the whole job, so the
/// filters, the sort and the installed-state marking are what these tests
/// cover — plus the failure paths the dialog got wrong before it: a failed
/// catalogue load must offer a retry, and a failed download must say so
/// rather than reporting success.
///
/// There is no localization delegate here, so `.i18n()` returns the key it
/// was handed, which is what the assertions match on.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/community_scripts.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/components/busy_button.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/community_screen.dart';

String _info(String name, String description, String distro, String author) =>
    'name: $name\n'
    'description: $description\n'
    'version: 1.0.0\n'
    'author: $author\n'
    'license: MIT\n'
    'git: https://github.com/bostrot/wsl-scripts\n'
    'distro: $distro\n';

/// Serves the folder listing, each info.yml, the commits API and the script
/// bodies, and can fail any of them on demand.
class _CatalogueAdapter implements HttpClientAdapter {
  _CatalogueAdapter(this.scripts);

  /// name -> (description, distro, author)
  final Map<String, List<String>> scripts;
  bool failCatalogue = false;
  bool failScript = false;
  bool failCommits = false;
  final List<String> fetchedScripts = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.toString();

    if (path.contains('/commits')) {
      if (failCommits) return ResponseBody.fromString('rate limited', 403);
      return ResponseBody.fromString(
          jsonEncode([
            {
              'commit': {
                'committer': {'date': '2026-09-01T10:00:00Z'}
              }
            }
          ]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    }
    if (path.contains('api.github.com')) {
      if (failCatalogue) return ResponseBody.fromString('nope', 500);
      return ResponseBody.fromString(
          jsonEncode([for (final name in scripts.keys) {'name': name}]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    }
    if (path.endsWith('info.yml')) {
      final name = scripts.keys.firstWhere((n) => path.contains('/$n/'));
      final meta = scripts[name]!;
      return ResponseBody.fromString(
          _info(name, meta[0], meta[1], meta[2]), 200, headers: {
        Headers.contentTypeHeader: [Headers.textPlainContentType]
      });
    }
    if (path.endsWith('script.noshell')) {
      if (failScript) return ResponseBody.fromString('nope', 500);
      fetchedScripts.add(path);
      return ResponseBody.fromString('echo hi', 200, headers: {
        Headers.contentTypeHeader: [Headers.textPlainContentType]
      });
    }
    return ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CatalogueAdapter adapter;
  final messages = <String>[];

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {
      messages.add(msg);
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    messages.clear();
    CommunityScripts.clearCache();
    adapter = _CatalogueAdapter({
      'apt-upgrade': ['Update every package', 'Ubuntu', 'bostrot'],
      'redis': ['Redis key/value store', 'Debian', 'bostrot'],
      'go-toolchain': ['Go compiler', 'Alpine', 'someone-else'],
    });
    communityScriptsBuilder = () =>
        CommunityScripts(dio: Dio()..httpClientAdapter = adapter);
  });

  tearDown(() {
    communityScriptsBuilder = () => CommunityScripts();
    CommunityScripts.clearCache();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const FluentApp(home: CommunityPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the catalogue as cards', (tester) async {
    await pumpPage(tester);
    expect(find.text('apt-upgrade'), findsOneWidget);
    expect(find.text('redis'), findsOneWidget);
    expect(find.text('go-toolchain'), findsOneWidget);
    // The distro each script declares is shown on its card.
    expect(find.text('Ubuntu'), findsOneWidget);
    expect(find.text('Alpine'), findsOneWidget);
  });

  testWidgets('search matches name, description and author', (tester) async {
    await pumpPage(tester);
    final box = find.byKey(const ValueKey('test-community-search'));

    await tester.enterText(box, 'redis');
    await tester.pumpAndSettle();
    // Scoped to the grid: the search box itself now contains "redis" too.
    expect(
        find.descendant(
            of: find.byType(GridView), matching: find.text('redis')),
        findsOneWidget);
    expect(find.text('apt-upgrade'), findsNothing);

    // Description text.
    await tester.enterText(box, 'compiler');
    await tester.pumpAndSettle();
    expect(find.text('go-toolchain'), findsOneWidget);
    expect(find.text('redis'), findsNothing);

    // Author.
    await tester.enterText(box, 'someone-else');
    await tester.pumpAndSettle();
    expect(find.text('go-toolchain'), findsOneWidget);

    // A search with no hits says so rather than showing an empty grid.
    await tester.enterText(box, 'nothing-matches-this');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('test-community-no-results')),
        findsOneWidget);
  });

  testWidgets('the distro filter narrows the list', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('test-community-distro')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpine').last);
    await tester.pumpAndSettle();

    expect(find.text('go-toolchain'), findsOneWidget);
    expect(find.text('redis'), findsNothing);
    expect(find.text('apt-upgrade'), findsNothing);
  });

  testWidgets('selecting and installing writes the snippets', (tester) async {
    await pumpPage(tester);
    // Nothing selected: the install button is disabled, so it cannot no-op.
    expect(
        tester
            .widget<BusyButton>(
                find.byKey(const ValueKey('test-community-install')))
            .onPressed,
        isNull);

    await tester.tap(find.text('redis'));
    await tester.pumpAndSettle();
    expect(find.text('nselected-text'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('test-community-install')));
    await tester.pumpAndSettle();

    final saved = QuickAction().getFromPrefs().map((e) => e.name);
    expect(saved, contains('redis'));
    expect(saved, isNot(contains('apt-upgrade')));
    expect(messages, contains('snippetsdownloaded-text'));
  });

  testWidgets('an installed script is marked and can be hidden',
      (tester) async {
    QuickAction.addToPrefs(QuickActionItem(
        name: 'redis', description: 'Redis key/value store', content: 'echo'));
    await pumpPage(tester);

    // Marked as installed, and not selectable into the download set.
    expect(find.byIcon(FluentIcons.completed_solid), findsOneWidget);
    await tester.tap(find.text('redis'));
    await tester.pumpAndSettle();
    expect(find.text('nselected-text'), findsNothing);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('redis'), findsNothing);
    expect(find.text('apt-upgrade'), findsOneWidget);
  });

  testWidgets('a failed download reports instead of claiming success',
      (tester) async {
    adapter.failScript = true;
    await pumpPage(tester);
    await tester.tap(find.text('redis'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test-community-install')));
    await tester.pumpAndSettle();

    expect(messages.any((m) => m.contains('snippetdownloadfailed-text')), isTrue);
    expect(messages, isNot(contains('snippetsdownloaded-text')));
    expect(QuickAction().getFromPrefs(), isEmpty);
  });

  testWidgets('a failed catalogue load offers a retry', (tester) async {
    adapter.failCatalogue = true;
    await pumpPage(tester);
    expect(
        find.byKey(const ValueKey('test-community-load-error')), findsOneWidget);

    // The retry re-fetches, so a recovered network fills the page.
    adapter.failCatalogue = false;
    await tester.tap(find.byKey(const ValueKey('test-community-retry')));
    await tester.pumpAndSettle();
    expect(find.text('redis'), findsOneWidget);
  });

  testWidgets('rate-limited update dates leave the cards intact',
      (tester) async {
    adapter.failCommits = true;
    await pumpPage(tester);
    // The catalogue still renders; the date is simply absent, replaced by
    // the version from info.yml.
    expect(find.text('redis'), findsOneWidget);
    expect(find.text('v1.0.0'), findsWidgets);
  });

  testWidgets('the update date sits flush with the card edge', (tester) async {
    // A short and an overlong author: the date must land in the same place
    // either way, instead of wandering off with the author's leftover space.
    adapter = _CatalogueAdapter({
      'apt-upgrade': ['Update every package', 'Ubuntu', 'bo'],
      'redis': [
        'Redis key/value store',
        'Debian',
        'an-author-name-that-is-far-too-long-to-fit-on-one-line-of-a-card',
      ],
    });
    await pumpPage(tester);

    for (final name in ['apt-upgrade', 'redis']) {
      final card = find
          .ancestor(of: find.text(name), matching: find.byType(HoverButton))
          .first;
      final date = find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').startsWith('updated')));
      expect(date, findsOneWidget, reason: name);
      // The title spans the card's full content width, so the date belongs
      // exactly where the title ends — no padding or border arithmetic.
      expect(tester.getTopRight(date).dx,
          moreOrLessEquals(tester.getTopRight(find.text(name)).dx),
          reason: '$name: the date drifted away from the card edge');
    }
  });
}
