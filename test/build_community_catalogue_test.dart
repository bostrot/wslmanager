/// Tests for scripts/build_community_catalogue.dart — the generator behind
/// cdn/scripts.json, which GitHub Pages serves to the Community screen.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/build_community_catalogue.dart';

const String _info = 'name: redis\n'
    'description: Redis\n'
    'version: 1.0.0\n'
    'author: bostrot\n'
    'distro:\n  - Debian\n';

void main() {
  group('parseScriptFolders', () {
    test('takes the directories and leaves everything else', () {
      final listing = jsonEncode([
        {'name': 'redis', 'type': 'dir'},
        {'name': 'README.md', 'type': 'file'},
        {'name': 'mysql', 'type': 'dir'},
      ]);
      expect(parseScriptFolders(listing), ['redis', 'mysql']);
    });

    test('tolerates rows that are not shaped like entries', () {
      final listing = jsonEncode([
        {'name': 'redis', 'type': 'dir'},
        'not a row',
        {'type': 'dir'},
        {'name': '', 'type': 'dir'},
      ]);
      expect(parseScriptFolders(listing), ['redis']);
    });

    test('a listing that is not a list is an error, not an empty catalogue',
        () {
      expect(() => parseScriptFolders(jsonEncode({'message': 'Not Found'})),
          throwsFormatException);
    });
  });

  group('parseLatestCommitDate', () {
    test('reads the committer date of the newest commit', () {
      final commits = jsonEncode([
        {
          'commit': {
            'committer': {'date': '2026-08-20T08:00:00Z'}
          }
        }
      ]);
      expect(parseLatestCommitDate(commits), '2026-08-20T08:00:00Z');
    });

    test('says nothing rather than throwing when the shape is unexpected', () {
      for (final body in [
        jsonEncode([]),
        jsonEncode([{}]),
        jsonEncode([
          {'commit': {}}
        ]),
        jsonEncode({'message': 'API rate limit exceeded'}),
      ]) {
        expect(parseLatestCommitDate(body), isNull, reason: body);
      }
    });
  });

  group('looksLikeManifest', () {
    test('accepts a manifest that names itself', () {
      expect(looksLikeManifest(_info), isTrue);
    });

    test('rejects what a missing file actually returns', () {
      // raw.githubusercontent answers 404 with a page, and an empty folder
      // gives an empty string; neither should reach the app as an entry.
      expect(looksLikeManifest(''), isFalse);
      expect(looksLikeManifest('   \n'), isFalse);
      expect(looksLikeManifest('<!DOCTYPE html><title>404</title>'), isFalse);
      expect(looksLikeManifest('name:\n'), isFalse);
    });
  });

  group('buildCatalogue', () {
    test('sorts by name so the file only changes when the data does', () {
      final built = buildCatalogue([
        CatalogueEntry(name: 'zsh', info: _info),
        CatalogueEntry(name: 'adminer', info: _info),
        CatalogueEntry(name: 'mysql', info: _info),
      ]);
      expect((built['scripts'] as List).map((s) => (s as Map)['name']),
          ['adminer', 'mysql', 'zsh']);
      expect(built['count'], 3);
    });

    test('carries the manifest verbatim and the date when there is one', () {
      final built = buildCatalogue([
        CatalogueEntry(
            name: 'redis', info: _info, updatedAt: '2026-08-20T08:00:00Z'),
      ]);
      final entry = (built['scripts'] as List).single as Map;
      expect(entry['info'], _info);
      expect(entry['updatedAt'], '2026-08-20T08:00:00Z');
    });

    test('omits the date rather than emitting a null the app must handle', () {
      final built =
          buildCatalogue([CatalogueEntry(name: 'redis', info: _info)]);
      expect((built['scripts'] as List).single, isNot(contains('updatedAt')));
    });

    test('drops an unreadable manifest instead of publishing a blank row', () {
      final built = buildCatalogue([
        CatalogueEntry(name: 'redis', info: _info),
        CatalogueEntry(name: 'broken', info: '<html>404</html>'),
      ]);
      expect(
          (built['scripts'] as List).map((s) => (s as Map)['name']), ['redis']);
      expect(built['count'], 1);
    });

    test('carries no timestamp of its own', () {
      // A generatedAt would rewrite the file on every run and commit noise
      // for days when nothing changed.
      final built =
          buildCatalogue([CatalogueEntry(name: 'redis', info: _info)]);
      expect(built.keys, ['source', 'count', 'scripts']);
    });
  });

  group('renderCatalogue', () {
    test('is stable across runs for the same data', () {
      final entries = [
        CatalogueEntry(
            name: 'redis', info: _info, updatedAt: '2026-08-20T08:00:00Z'),
        CatalogueEntry(name: 'adminer', info: _info),
      ];
      expect(renderCatalogue(buildCatalogue(entries)),
          renderCatalogue(buildCatalogue(entries.reversed.toList())));
    });

    test('ends with a newline and parses back to what went in', () {
      final rendered = renderCatalogue(
          buildCatalogue([CatalogueEntry(name: 'redis', info: _info)]));
      expect(rendered, endsWith('\n'));
      final parsed = jsonDecode(rendered) as Map<String, dynamic>;
      expect((parsed['scripts'] as List).single['info'], _info);
    });
  });
}
