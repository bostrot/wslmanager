/// Builds `cdn/scripts.json`: the whole community catalogue as one file,
/// published on this repository's `catalogue` branch and read raw from there.
///
/// The Community screen used to assemble this itself, at runtime, on every
/// machine that opened it: list `scripts/` in bostrot/wsl-scripts, then fetch
/// `info.yml` for each of its eighty folders, then ask the commits API when
/// each folder last changed. That is 161 requests, 81 of them against
/// api.github.com, where an anonymous caller gets sixty an hour — shared with
/// everyone else behind the same address. The screen was slow for the lucky
/// and rate-limited for the rest.
///
/// Doing it here instead costs nothing at runtime: Actions holds a token
/// worth a thousand requests an hour, the result is a static file on a CDN,
/// and the app makes one request. Deliberately dependency-free (dart:io and
/// dart:convert only) so CI can run it with `dart` and no `pub get`; the
/// pure functions below are what the tests drive.
// ignore_for_file: dangling_library_doc_comments

import 'dart:convert';
import 'dart:io';

/// One catalogue entry: a script folder and the manifest it ships.
class CatalogueEntry {
  const CatalogueEntry(
      {required this.name, required this.info, this.updatedAt});

  final String name;

  /// The folder's `info.yml`, verbatim. The app parses it with the same YAML
  /// code it uses when reading a folder directly, so this file never becomes
  /// a second definition of what a snippet is.
  final String info;

  /// When the folder last changed upstream, ISO 8601. Null when the commits
  /// API could not say — an unknown date costs a line in the UI, not the
  /// entry.
  final String? updatedAt;
}

/// The `dir` entries of a GitHub contents listing, in the order given.
///
/// Anything that is not a directory is skipped: the listing also carries
/// `README.md` and friends, and a file is not a script.
List<String> parseScriptFolders(String listingJson) {
  final decoded = jsonDecode(listingJson);
  if (decoded is! List) {
    throw const FormatException('the contents listing was not a list');
  }
  final names = <String>[];
  for (final row in decoded) {
    if (row is! Map) continue;
    if (row['type'] != 'dir') continue;
    final name = row['name'];
    if (name is String && name.isNotEmpty) names.add(name);
  }
  return names;
}

/// The newest commit date in a commits response, or null when it says none.
String? parseLatestCommitDate(String commitsJson) {
  final decoded = jsonDecode(commitsJson);
  if (decoded is! List || decoded.isEmpty) return null;
  final first = decoded.first;
  if (first is! Map) return null;
  final commit = first['commit'];
  if (commit is! Map) return null;
  final committer = commit['committer'];
  if (committer is! Map) return null;
  final date = committer['date'];
  return date is String && date.isNotEmpty ? date : null;
}

/// A manifest has to at least name itself; an HTML error page or an empty
/// file is not one, and shipping it would put a blank row in the catalogue.
bool looksLikeManifest(String info) =>
    info.trimLeft().isNotEmpty &&
    RegExp(r'^name:\s*\S', multiLine: true).hasMatch(info);

/// The catalogue document.
///
/// Sorted by name and carrying no timestamp of its own, so a run that finds
/// nothing new produces a byte-identical file and the workflow has nothing
/// to commit. Freshness is what git and the CDN already record.
Map<String, Object?> buildCatalogue(List<CatalogueEntry> entries) {
  final usable = entries.where((e) => looksLikeManifest(e.info)).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return {
    'source': 'https://github.com/bostrot/wsl-scripts',
    'count': usable.length,
    'scripts': [
      for (final entry in usable)
        {
          'name': entry.name,
          'info': entry.info,
          if (entry.updatedAt != null) 'updatedAt': entry.updatedAt,
        },
    ],
  };
}

/// Pretty-printed with a trailing newline: this file lands in a commit, and a
/// diff a human can read is worth the bytes on a CDN that gzips anyway.
String renderCatalogue(Map<String, Object?> catalogue) =>
    '${const JsonEncoder.withIndent('  ').convert(catalogue)}\n';

// ---------------------------------------------------------------------------
// Everything below talks to the network; the logic above does not.
// ---------------------------------------------------------------------------

const String _repo = 'bostrot/wsl-scripts';
const String _branch = 'main';

Future<String> _get(HttpClient client, Uri uri, {String? token}) async {
  final request = await client.getUrl(uri);
  // GitHub refuses an API request without one, and a named agent is what
  // lets them tell this job apart from a scraper if it ever misbehaves.
  request.headers
      .set(HttpHeaders.userAgentHeader, 'wsl2-distro-manager-catalogue');
  if (token != null && token.isNotEmpty && uri.host == 'api.github.com') {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode >= 300) {
    throw HttpException('${response.statusCode} for $uri: ${body.trim()}');
  }
  return body;
}

Future<void> main(List<String> args) async {
  final output = args.isNotEmpty ? args.first : 'cdn/scripts.json';
  final token = Platform.environment['GITHUB_TOKEN'];
  final client = HttpClient();
  try {
    final listing = await _get(client,
        Uri.parse('https://api.github.com/repos/$_repo/contents/scripts'),
        token: token);
    final folders = parseScriptFolders(listing);
    stdout.writeln('${folders.length} script folders');

    final entries = <CatalogueEntry>[];
    for (final name in folders) {
      String info;
      try {
        info = await _get(
            client,
            Uri.parse(
                'https://raw.githubusercontent.com/$_repo/$_branch/scripts/$name/info.yml'));
      } catch (e) {
        // One folder without a readable manifest is not a reason to publish
        // nothing; the same rule the app applies when it walks them itself.
        stderr.writeln('skipping $name: $e');
        continue;
      }

      String? updatedAt;
      try {
        final commits = await _get(
            client,
            Uri.parse('https://api.github.com/repos/$_repo/commits'
                '?path=scripts/$name&per_page=1'),
            token: token);
        updatedAt = parseLatestCommitDate(commits);
      } catch (e) {
        // A date is a nicety. Losing it must not cost the entry, and must
        // not fail the run — that is exactly how the app used to behave when
        // it ran out of anonymous requests.
        stderr.writeln('no date for $name: $e');
      }

      entries.add(CatalogueEntry(name: name, info: info, updatedAt: updatedAt));
    }

    final catalogue = buildCatalogue(entries);
    if ((catalogue['count'] as int) == 0) {
      stderr.writeln('refusing to write an empty catalogue');
      exitCode = 1;
      return;
    }

    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(renderCatalogue(catalogue));
    stdout.writeln('wrote $output with ${catalogue['count']} scripts');
  } finally {
    client.close(force: true);
  }
}
