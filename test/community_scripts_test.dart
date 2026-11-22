import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/community_scripts.dart';
import 'package:wsl2distromanager/components/helpers.dart';

const String _info = 'name: redis\n'
    'description: Redis\n'
    'version: 1.0.0\n'
    'author: bostrot\n'
    'license: MIT\n'
    'git: https://github.com/bostrot/wsl-scripts\n'
    'distro:\n  - Debian\n  - Alpine\n';

const String _broken = 'this is not: valid: yaml: at all\n';

class _Adapter implements HttpClientAdapter {
  _Adapter({
    this.names = const ['redis'],
    this.brokenFor = const {},
    this.catalogue,
    this.catalogueContentType = Headers.jsonContentType,
  });
  final List<String> names;
  final Set<String> brokenFor;

  /// Body the aggregate CDN endpoint answers with. Null means it is not
  /// serving anything usable, which is how the per-folder fallback is
  /// exercised — and how every test written before that endpoint existed
  /// keeps testing what it used to.
  final String? catalogue;

  /// What the catalogue is served as. raw.githubusercontent.com, where it
  /// lives, answers `text/plain` for a `.json` file.
  final String catalogueContentType;
  int commitCalls = 0;
  int listingCalls = 0;
  int catalogueCalls = 0;
  bool failCommits = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.toString();
    if (path.contains('/commits')) {
      commitCalls++;
      if (failCommits) return ResponseBody.fromString('limited', 403);
      return ResponseBody.fromString(
          jsonEncode([
            {
              'commit': {
                'committer': {'date': '2026-08-20T08:00:00Z'}
              }
            }
          ]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    }
    if (path.contains('/catalogue/cdn/scripts.json')) {
      catalogueCalls++;
      if (catalogue == null) return ResponseBody.fromString('nope', 503);
      return ResponseBody.fromString(catalogue!, 200, headers: {
        Headers.contentTypeHeader: [catalogueContentType]
      });
    }
    if (path.contains('api.github.com')) {
      listingCalls++;
      return ResponseBody.fromString(
          jsonEncode([
            for (final n in names) {'name': n}
          ]),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType]
          });
    }
    if (path.endsWith('info.yml')) {
      final name = names.firstWhere((n) => path.contains('/$n/'));
      return ResponseBody.fromString(
          brokenFor.contains(name) ? _broken : _info.replaceAll('redis', name),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.textPlainContentType]
          });
    }
    return ResponseBody.fromString('echo hi', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    CommunityScripts.clearCache();
  });

  CommunityScripts build(_Adapter adapter) =>
      CommunityScripts(dio: Dio()..httpClientAdapter = adapter);

  /// The shape `scripts/build_community_catalogue.dart` publishes.
  String catalogueOf(Map<String, String> scripts) => jsonEncode({
        'generatedAt': '2026-09-09T18:00:00Z',
        'source': 'https://github.com/bostrot/wsl-scripts',
        'count': scripts.length,
        'scripts': [
          for (final entry in scripts.entries)
            {'name': entry.key, 'info': entry.value},
        ],
      });

  group('the published catalogue', () {
    test('a date in the file spares the commits API entirely', () async {
      final adapter = _Adapter(
        catalogue: jsonEncode({
          'count': 1,
          'scripts': [
            {
              'name': 'redis',
              'info': _info,
              'updatedAt': '2026-08-20T08:00:00Z'
            }
          ],
        }),
      );
      final service = build(adapter);
      final scripts = await service.list();
      expect(scripts.single.updatedAt, DateTime.parse('2026-08-20T08:00:00Z'));

      // The background pass has nothing left to look up, which is what keeps
      // the screen off a sixty-an-hour budget.
      await service.loadUpdatedDates(scripts);
      expect(adapter.commitCalls, 0);
    });

    test('one request replaces the listing and every info.yml', () async {
      final adapter = _Adapter(
          catalogue: catalogueOf({
        'redis': _info,
        'mysql': _info.replaceAll('redis', 'mysql'),
      }));
      final scripts = await build(adapter).list();

      expect(scripts.map((s) => s.name), ['redis', 'mysql']);
      expect(adapter.catalogueCalls, 1);
      // The point of the endpoint: neither the folder listing nor any
      // per-script fetch happens at all.
      expect(adapter.listingCalls, 0);
    });

    test('served as text/plain, as the raw branch URL does, it still parses',
        () async {
      final adapter = _Adapter(
        catalogue: catalogueOf({'redis': _info}),
        catalogueContentType: 'text/plain; charset=utf-8',
      );
      final scripts = await build(adapter).list();
      expect(scripts.map((s) => s.name), ['redis']);
      expect(adapter.listingCalls, 0);
    });

    test('a manifest it cannot parse is skipped, not fatal', () async {
      final adapter = _Adapter(
          catalogue: catalogueOf({
        'redis': _info,
        'broken': _broken,
      }));
      expect((await build(adapter).list()).map((s) => s.name), ['redis']);
    });

    test('an endpoint that is down falls back to walking the folders',
        () async {
      final adapter = _Adapter(names: ['redis', 'mysql']);
      final scripts = await build(adapter).list();

      expect(adapter.catalogueCalls, 1, reason: 'it is tried first');
      expect(adapter.listingCalls, 1, reason: 'and then the walk takes over');
      expect(scripts.map((s) => s.name), ['redis', 'mysql']);
    });

    test('an empty or unexpected body falls back rather than showing nothing',
        () async {
      for (final body in [
        jsonEncode({'scripts': []}),
        jsonEncode({'count': 0}),
        jsonEncode(['not', 'a', 'map']),
        'plain text',
      ]) {
        CommunityScripts.clearCache();
        final adapter = _Adapter(names: ['redis'], catalogue: body);
        final scripts = await build(adapter).list();
        expect(scripts.map((s) => s.name), ['redis'],
            reason: 'fell back for body: $body');
        expect(adapter.listingCalls, 1, reason: 'for body: $body');
      }
    });
  });

  test('a distro list in info.yml is exposed as a flat list', () async {
    final scripts = await build(_Adapter()).list();
    expect(scripts.single.distros, ['Debian', 'Alpine']);
  });

  test('the catalogue is cached until cleared or forced', () async {
    final adapter = _Adapter();
    final service = build(adapter);
    await service.list();
    await service.list();
    expect(adapter.listingCalls, 1);

    await service.list(force: true);
    expect(adapter.listingCalls, 2);
  });

  test('one malformed info.yml does not cost the whole catalogue', () async {
    final adapter =
        _Adapter(names: ['redis', 'broken', 'mysql'], brokenFor: {'broken'});
    final scripts = await build(adapter).list();
    expect(scripts.map((s) => s.name), ['redis', 'mysql']);
  });

  test('update dates are fetched once and then read from the cache', () async {
    final adapter = _Adapter();
    final service = build(adapter);
    final scripts = await service.list();

    await service.loadUpdatedDates(scripts);
    expect(scripts.single.updatedAt, DateTime.parse('2026-08-20T08:00:00Z'));
    expect(adapter.commitCalls, 1);

    // A fresh catalogue object with the same prefs must not re-request.
    CommunityScripts.clearCache();
    final again = await service.list(force: true);
    await service.loadUpdatedDates(again);
    expect(again.single.updatedAt, isNotNull);
    expect(adapter.commitCalls, 1, reason: 'the cached date should be reused');
  });

  test('a rate-limited commits API leaves dates null, not an exception',
      () async {
    final adapter = _Adapter()..failCommits = true;
    final service = build(adapter);
    final scripts = await service.list();

    await service.loadUpdatedDates(scripts);
    expect(scripts.single.updatedAt, isNull);
  });
}
