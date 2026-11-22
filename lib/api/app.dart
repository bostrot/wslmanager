import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:wsl2distromanager/api/rootfs_architecture.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';

class App {
  final Dio dio;

  App({Dio? dio}) : dio = dio ?? Dio();

  /// Debug builds read the repo's own bundled `images.json` instead of the
  /// CDN, so a catalogue change is testable in `flutter run` before the
  /// manual CDN push — the CDN copy, not the repo copy, is what release
  /// users get (see Working/cdn-upload.md), and with the CDN queried first a
  /// developer could never see their own edit. Static so a test can pick the
  /// path it is exercising; excluded under `flutter test` by default so the
  /// existing remote-path tests keep meaning what they say.
  static bool preferBundledCatalogue =
      kDebugMode && !Platform.environment.containsKey('FLUTTER_TEST');

  /// Returns an int of the string
  /// '1.2.3' -> 123
  double versionToDouble(String version) {
    return double.tryParse(version
            .toString()
            .replaceAll('v', '')
            .replaceAll('.', '')
            .replaceAll('+', '.')) ??
        -1;
  }

  /// Returns an url as String when the app is not up-to-date otherwise empty string
  Future<String> checkUpdate(String version) async {
    try {
      var response = await dio.get(updateUrl);
      if (response.data.length > 0) {
        var latest = response.data[0];
        String tagName = latest['tag_name'];
        String publishedAt = latest['published_at'];

        // Newer version and at least 2 days old
        if (versionToDouble(tagName) > versionToDouble(version) &&
            DateTime.now().difference(DateTime.parse(publishedAt)).inDays > 2) {
          return latest['html_url'];
        }
      }
    } catch (e) {
      // ignored
    }
    return '';
  }

  /// Returns the message of the day
  Future<String> checkMotd() async {
    try {
      var response = await dio.get(motdUrl);
      if (response.data.length > 0) {
        var jsonData = json.decode(response.data);
        String motd = jsonData['motd'];
        // Check if same as last time
        if (prefs.getString('motd') == motd) {
          return '';
        }
        prefs.setString('motd', motd);
        return motd;
      }
    } catch (e) {
      // ignored
    }
    return '';
  }

  /// Get list of distros from Repo
  ///
  /// Only the entries that can run on this machine: on a Windows-on-ARM PC a
  /// catalogue of x86-64 root filesystems is a list of downloads that all end
  /// in an instance where nothing starts (see [rootfsLinksFor]). A source
  /// whose entries are all for the other architecture therefore counts as
  /// unusable, and the next one is tried — the copy the CDN serves is uploaded
  /// by hand and may still be the Intel-only one while the repo's own already
  /// lists both.
  ///
  /// [architecture] is a seam for tests, which have to be able to describe a
  /// machine other than the one running them.
  Future<Map<String, String>> getDistroLinks({String? architecture}) async {
    final family = architecture ?? rootfsHostArchitecture();

    // Debug: the bundled catalogue first, the CDN only as a fallback when
    // the asset is missing or unreadable.
    if (preferBundledCatalogue) {
      final local = await _getLocalDistroLinks(family);
      if (local.isNotEmpty) {
        distroRootfsLinks = local;
        return local;
      }
    }

    try {
      final response = await dio.get(gitRepoLink);
      if (response.statusCode != null && response.statusCode! < 300) {
        final distros = _parseCatalogue(response.data, family);
        if (distros.isNotEmpty) {
          distroRootfsLinks = distros;
          return distros;
        }
      }
    } catch (e) {
      // ignored
    }

    // The CDN caches this file from GitHub; when it answers with nothing
    // usable, read the same file at the source before falling back to a copy
    // frozen at build time.
    try {
      final response = await dio.get(gitRepoRawLink);
      if (response.statusCode != null && response.statusCode! < 300) {
        final distros = _parseCatalogue(response.data, family);
        if (distros.isNotEmpty) {
          distroRootfsLinks = distros;
          return distros;
        }
      }
    } catch (e) {
      // ignored
    }

    // Fallback: bundled images.json in app assets.
    final local = await _getLocalDistroLinks(family);
    if (local.isNotEmpty) {
      distroRootfsLinks = local;
      return local;
    }

    // Last resort: in-memory cache.
    return distroRootfsLinks;
  }

  /// A catalogue response, decoded when the server sent it as text, reduced to
  /// the downloads [family] can run. Empty when the body is not a catalogue.
  Map<String, String> _parseCatalogue(dynamic data, String family) {
    final parsed = data is String ? json.decode(data) : data;
    if (parsed is Map) return rootfsLinksFor(parsed, family);
    return {};
  }

  Future<Map<String, String>> _getLocalDistroLinks(String family) async {
    try {
      final raw = await rootBundle.loadString('images.json');
      final jsonData = json.decode(raw);
      if (jsonData is Map<String, dynamic>) {
        return rootfsLinksFor(jsonData, family);
      }
    } catch (e) {
      // ignored
    }
    return {};
  }
}
