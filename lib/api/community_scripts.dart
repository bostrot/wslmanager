import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// One entry of the community catalogue: the metadata from its `info.yml`
/// plus what the browser knows about it locally.
class CommunityScript {
  CommunityScript({required this.item, this.updatedAt});

  final QuickActionItem item;

  /// When the script folder last changed upstream, once [CommunityScripts]
  /// has looked it up. Null while unknown — the listing renders without it
  /// rather than blocking on a per-script request.
  DateTime? updatedAt;

  String get name => item.name;
  String get description => item.description;
  String get author => item.author;
  String get version => item.version;

  /// The distros the script declares, as a flat list.
  List<String> get distros {
    final raw = item.distro;
    if (raw is List) {
      return raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final single = raw?.toString().trim() ?? '';
    return single.isEmpty ? [] : [single];
  }
}

/// Fetches the community script catalogue and the scripts themselves.
///
/// Split out of the browser widget so the network shape is testable on its
/// own, and so the listing, the search and the download all read the same
/// cache instead of each refetching.
class CommunityScripts {
  CommunityScripts({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// Process-lifetime cache of the catalogue.
  static List<CommunityScript> _cache = [];

  /// How long a looked-up "last updated" stays good. Script folders change
  /// rarely and the commits API is rate limited for anonymous callers, so a
  /// day-old answer is worth far more than a fresh 403.
  static const Duration updatedTtl = Duration(hours: 24);

  static void clearCache() => _cache = [];

  /// Every script in the catalogue, from cache when it has been loaded.
  Future<List<CommunityScript>> list({bool force = false}) async {
    if (!force && _cache.isNotEmpty) return _cache;
    if (force) _cache = [];

    final aggregate = await _listFromCatalogue();
    if (aggregate != null) {
      _cache = aggregate;
      return _cache;
    }

    final listing = await _dio.get(gitApiScriptsLink);
    final folders = (listing.data as List)
        .map((e) => e['name'].toString())
        .where((name) => name.isNotEmpty)
        .toList();

    final loaded = <CommunityScript>[];
    for (final name in folders) {
      try {
        final info = await _dio.get('$repoScripts$name/info.yml');
        loaded.add(CommunityScript(
            item: QuickActionItem.fromYamlString(info.data.toString())));
      } catch (_) {
        // One malformed entry must not cost the user the whole catalogue.
        continue;
      }
    }
    if (loaded.isEmpty && folders.isNotEmpty) {
      throw Exception('No readable scripts in the catalogue');
    }
    _cache = loaded;
    return _cache;
  }

  /// The catalogue in a single request, or null when that route did not work
  /// and the per-folder walk should be used instead.
  ///
  /// Eighty scripts meant eighty-one sequential requests before this — a
  /// listing, then one `info.yml` each — and the listing counted against
  /// api.github.com's sixty-an-hour anonymous budget, as did the eighty
  /// commit lookups behind the "updated" line. CI does that walk once, with
  /// a token worth a thousand an hour, and publishes the answer as a page.
  ///
  /// Every failure here is deliberately silent: a CDN that is down, stale or
  /// serving something unexpected should cost latency, never the catalogue.
  Future<List<CommunityScript>?> _listFromCatalogue() async {
    try {
      final response = await _dio.get(
        communityCatalogUrl,
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      final data = response.data;
      final payload = data is String ? jsonDecode(data) : data;
      if (payload is! Map) return null;
      final entries = payload['scripts'];
      if (entries is! List || entries.isEmpty) return null;

      final loaded = <CommunityScript>[];
      for (final entry in entries) {
        if (entry is! Map) continue;
        final info = entry['info'];
        if (info is! String || info.isEmpty) continue;
        try {
          // The catalogue carries the date CI resolved, so the background
          // pass below finds nothing left to look up — which is what keeps
          // the screen off api.github.com entirely.
          final updated = entry['updatedAt'];
          loaded.add(CommunityScript(
            item: QuickActionItem.fromYamlString(info),
            updatedAt: updated is String ? DateTime.tryParse(updated) : null,
          ));
        } catch (_) {
          // Same rule as the per-folder path: one unreadable manifest is
          // skipped, it does not cost the catalogue.
          continue;
        }
      }
      return loaded.isEmpty ? null : loaded;
    } catch (_) {
      return null;
    }
  }

  /// Fills in [CommunityScript.updatedAt] for [scripts], newest commit
  /// touching each folder. Cached in prefs for [updatedTtl].
  ///
  /// Best effort by design: the commits API allows 60 anonymous requests an
  /// hour, so a rate-limited or offline lookup leaves the date null and the
  /// card simply renders without it.
  Future<void> loadUpdatedDates(List<CommunityScript> scripts) async {
    for (final script in scripts) {
      if (script.updatedAt != null) continue;

      final cachedIso = prefs.getString('ScriptUpdated_${script.name}');
      final cachedAt = prefs.getInt('ScriptUpdatedFetched_${script.name}');
      if (cachedIso != null && cachedAt != null) {
        final age = DateTime.now().millisecondsSinceEpoch - cachedAt;
        if (age < updatedTtl.inMilliseconds) {
          script.updatedAt = DateTime.tryParse(cachedIso);
          continue;
        }
      }

      try {
        final response = await _dio.get(
          gitApiCommitsLink,
          queryParameters: {
            'path': 'scripts/${script.name}',
            'per_page': 1,
          },
        );
        final commits = response.data as List;
        if (commits.isEmpty) continue;
        final iso = commits.first['commit']?['committer']?['date']?.toString();
        if (iso == null) continue;
        script.updatedAt = DateTime.tryParse(iso);
        await prefs.setString('ScriptUpdated_${script.name}', iso);
        await prefs.setInt('ScriptUpdatedFetched_${script.name}',
            DateTime.now().millisecondsSinceEpoch);
      } catch (_) {
        // Rate limited or offline — leave it unknown.
        return;
      }
    }
  }

  /// Downloads [script]'s body and saves it as a local snippet.
  Future<void> install(CommunityScript script) async {
    final response =
        await _dio.get('$repoScripts${script.name}/script.noshell');
    script.item.content = response.data.toString();
    QuickAction.addToPrefs(script.item);
  }

  /// Names of the scripts already saved locally.
  static Set<String> installedNames() =>
      QuickAction().getFromPrefs().map((item) => item.name).toSet();
}
