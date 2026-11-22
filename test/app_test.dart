import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/app.dart';
import 'package:wsl2distromanager/components/helpers.dart';

class MockAdapter implements HttpClientAdapter {
  final Map<String, ResponseBody> responses;

  MockAdapter(this.responses);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future? cancelFuture) async {
    if (responses.containsKey(options.path)) {
      return responses[options.path]!;
    }
    return ResponseBody.fromString('Not Found', 404);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late App app;
  late Dio dio;
  late MockAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();

    dio = Dio();
    adapter = MockAdapter({});
    dio.httpClientAdapter = adapter;
    app = App(dio: dio);
  });

  test('versionToDouble converts correctly', () {
    expect(app.versionToDouble('v1.2.3'), 123.0);
    expect(app.versionToDouble('1.2.3'), 123.0);
    expect(app.versionToDouble('1.2.3+4'), 123.4);
    expect(app.versionToDouble('invalid'), -1.0);
  });

  test('checkUpdate returns url if update available', () async {
    final updateResponse = [
      {
        'tag_name': 'v2.0.0',
        'published_at':
            DateTime.now().subtract(Duration(days: 3)).toIso8601String(),
        'html_url': 'https://example.com/update',
      }
    ];

    adapter.responses[
            'https://api.github.com/repos/bostrot/wslmanager/releases'] =
        ResponseBody.fromString(jsonEncode(updateResponse), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

    final url = await app.checkUpdate('1.0.0');
    expect(url, 'https://example.com/update');
  });

  test('checkUpdate returns empty if no update', () async {
    final updateResponse = [
      {
        'tag_name': 'v1.0.0',
        'published_at':
            DateTime.now().subtract(Duration(days: 3)).toIso8601String(),
        'html_url': 'https://example.com/update',
      }
    ];

    adapter.responses[
            'https://api.github.com/repos/bostrot/wslmanager/releases'] =
        ResponseBody.fromString(jsonEncode(updateResponse), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

    final url = await app.checkUpdate('1.0.0');
    expect(url, '');
  });

  test('checkMotd returns motd', () async {
    final motdResponse = {'motd': 'Hello World'};

    adapter.responses[
            'https://raw.githubusercontent.com/bostrot/wslmanager/main/motd.json'] =
        ResponseBody.fromString(jsonEncode(motdResponse), 200, headers: {
      Headers.contentTypeHeader: [Headers.textPlainContentType],
    });

    final motd = await app.checkMotd();
    expect(motd, 'Hello World');
    expect(prefs.getString('motd'), 'Hello World');
  });

  test('getDistroLinks returns distros', () async {
    final distrosResponse = {'Ubuntu': 'url1', 'Debian': 'url2'};

    adapter.responses['https://n8n.aachen.dev/webhook/cdn/images.json'] =
        ResponseBody.fromString(jsonEncode(distrosResponse), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

    final distros = await app.getDistroLinks();
    expect(distros, {'Ubuntu': 'url1', 'Debian': 'url2'});
  });
}
