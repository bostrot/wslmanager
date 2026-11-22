import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/api/cloud/hetzner_provider.dart';

/// A scripted Hetzner Cloud API: answers per path and records every request,
/// so the tests can assert on the exact body a create sends.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.responses);

  /// Bodies keyed by `<METHOD> <path>`, e.g. `GET /servers`.
  final Map<String, Object> responses;

  /// Status codes, same keys. Absent means 200.
  final Map<String, int> statuses = {};

  /// Every `<METHOD> <uri>` seen, in order.
  final List<String> calls = [];

  /// Decoded request bodies, same order as the POSTs in [calls].
  final List<Map<String, dynamic>> bodies = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final method = options.method;
    final path = options.uri.path.replaceFirst('/v1', '');
    calls.add('$method ${options.uri}');
    if (options.data is Map) {
      bodies.add(Map<String, dynamic>.from(options.data as Map));
    }
    final key = '$method $path';
    final status = statuses[key] ?? 200;
    final body = responses[key];
    if (body == null) {
      return ResponseBody.fromString(jsonEncode({}), status, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      });
    }
    // A page-aware answer gets the page number; everything else is static.
    final page = int.tryParse('${options.uri.queryParameters['page'] ?? 1}');
    final resolved =
        body is Map<int, Object> ? (body[page] ?? const {}) : body;
    return ResponseBody.fromString(jsonEncode(resolved), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
  }

  @override
  void close({bool force = false}) {}
}

HetznerProvider _provider(_Adapter adapter, {String token = 'tok'}) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return HetznerProvider(token: token, dio: dio);
}

Map<String, dynamic> _server({
  int id = 1,
  String name = 'srv',
  String status = 'running',
  String ipv4 = '203.0.113.10',
  String ipv6 = '2001:db8::/64',
  Map<String, String> labels = const {},
}) =>
    {
      'id': id,
      'name': name,
      'status': status,
      'public_net': {
        'ipv4': {'ip': ipv4},
        'ipv6': {'ip': ipv6},
      },
      'server_type': {'name': 'cx22'},
      'datacenter': {
        'name': 'nbg1-dc3',
        'location': {'name': 'nbg1'},
      },
      'image': {'name': 'ubuntu-24.04', 'description': 'Ubuntu 24.04'},
      'labels': labels,
    };

const Map<String, dynamic> _pricing = {
  'pricing': {'currency': 'EUR'}
};

Map<String, dynamic> _serverTypes({bool deprecated = false}) => {
      'server_types': [
        {
          'id': 22,
          'name': 'cx22',
          'description': 'CX22',
          'cores': 2,
          'memory': 4,
          'disk': 40,
          'architecture': 'x86',
          'prices': [
            {
              'location': 'nbg1',
              'price_monthly': {'net': '3.29', 'gross': '3.92'}
            },
            {
              'location': 'hel1',
              'price_monthly': {'net': '3.10', 'gross': '3.69'}
            },
          ],
        },
        if (deprecated)
          {
            'id': 11,
            'name': 'cx11',
            'deprecation': {'announced': '2024-06-01T00:00:00+00:00'},
            'prices': const [],
          },
      ]
    };

void main() {
  test('parses servers, joining the price of their type', () async {
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': _serverTypes(),
      'GET /servers': {
        'servers': [_server()],
      },
    });

    final servers = await _provider(adapter).listServers();

    expect(servers, hasLength(1));
    final server = servers.single;
    expect(server.name, 'srv');
    expect(server.state, CloudServerState.running);
    expect(server.ipv4, '203.0.113.10');
    expect(server.serverType, 'cx22');
    expect(server.location, 'nbg1');
    // Cheapest of the two locations the type is sold in, gross.
    expect(server.monthlyPrice, '3.69');
    expect(server.currency, 'EUR');
  });

  test('turns the reported IPv6 network into an address that answers',
      () async {
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': _serverTypes(),
      'GET /servers': {
        'servers': [_server(ipv4: '', ipv6: '2001:db8:1234::/64')],
      },
    });

    final server = (await _provider(adapter).listServers()).single;

    expect(server.ipv6, '2001:db8:1234::1');
    // With no IPv4 the address falls back to IPv6 rather than being empty.
    expect(server.address, '2001:db8:1234::1');
  });

  test('reads the instance a deploy left on the server labels', () async {
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': _serverTypes(),
      'GET /servers': {
        'servers': [
          _server(labels: const {
            CloudServer.managedLabel: 'true',
            CloudServer.deployedInstanceLabel: 'Ubuntu',
          }),
          _server(id: 2, name: 'hand-made'),
        ],
      },
    });

    final servers = await _provider(adapter).listServers();

    // Newest first: id 2 sorts ahead of id 1.
    expect(servers.map((s) => s.name), ['hand-made', 'srv']);
    expect(servers[0].deployedInstance, isNull);
    expect(servers[1].deployedInstance, 'Ubuntu');
  });

  test('walks every page of a listing', () async {
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': _serverTypes(),
      'GET /servers': <int, Object>{
        1: {
          'servers': [_server(id: 1, name: 'one')],
          'meta': {
            'pagination': {'next_page': 2}
          },
        },
        2: {
          'servers': [_server(id: 2, name: 'two')],
          'meta': {
            'pagination': {'next_page': null}
          },
        },
      },
    });

    final servers = await _provider(adapter).listServers();

    expect(servers.map((s) => s.name), ['two', 'one']);
  });

  test('drops deprecated server types from the catalogue', () async {
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': _serverTypes(deprecated: true),
      'GET /locations': {
        'locations': [
          {'id': 1, 'name': 'nbg1', 'city': 'Nuremberg', 'country': 'DE'}
        ]
      },
      'GET /images': {
        'images': [
          {
            'id': 5,
            'name': 'ubuntu-24.04',
            'description': 'Ubuntu 24.04',
            'architecture': 'x86'
          }
        ]
      },
    });

    final catalogue = await _provider(adapter).catalogue();

    expect(catalogue.serverTypes.map((t) => t.name), ['cx22']);
    expect(catalogue.serverTypes.single.label,
        'cx22 · x86 · 2 vCPU · 4 GB · 40 GB · 3.69 EUR/mo');
    expect(catalogue.locations.single.label, 'nbg1 · Nuremberg, DE');
    // Images are addressed by name, which survives Hetzner's rebuilds; the
    // numeric id does not.
    expect(catalogue.images.single.id, 'ubuntu-24.04');
  });

  test('offers each image once, however many architectures it ships for',
      () async {
    // Hetzner lists every system image per architecture, so the same name
    // comes back twice. Two ComboBox items with one value is an assertion
    // failure in fluent_ui, and there is nothing to choose between them:
    // creating by name makes Hetzner pick the matching build.
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': _serverTypes(),
      'GET /locations': {'locations': []},
      'GET /images': {
        'images': [
          {'id': 5, 'name': 'ubuntu-24.04', 'architecture': 'x86'},
          {'id': 6, 'name': 'ubuntu-24.04', 'architecture': 'arm'},
          {'id': 7, 'name': 'debian-12', 'architecture': 'x86'},
        ]
      },
    });

    final catalogue = await _provider(adapter).catalogue();

    expect(catalogue.images.map((i) => i.id), ['debian-12', 'ubuntu-24.04']);
  });

  test('sends the create body Hetzner documents, with labels and cloud-init',
      () async {
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': _serverTypes(),
      'POST /servers': {
        'server': _server(id: 9, name: 'deploy-1', status: 'initializing'),
      },
    });

    final server = await _provider(adapter).createServer(
      name: 'deploy-1',
      serverType: 'cx22',
      image: 'ubuntu-24.04',
      location: 'nbg1',
      sshKeyIds: const ['77'],
      userData: '#cloud-config',
      labels: const {'wslmanager': 'true'},
    );

    expect(server.state, CloudServerState.initializing);
    final body = adapter.bodies.single;
    expect(body['name'], 'deploy-1');
    expect(body['server_type'], 'cx22');
    expect(body['image'], 'ubuntu-24.04');
    expect(body['location'], 'nbg1');
    expect(body['start_after_create'], isTrue);
    // Ids go as numbers: a key literally named "77" must not be picked up
    // instead of the key whose id is 77.
    expect(body['ssh_keys'], [77]);
    expect(body['user_data'], '#cloud-config');
    expect(body['labels'], {'wslmanager': 'true'});
  });

  test('a rejected token says so instead of leaking an HTTP status', () async {
    final adapter = _Adapter({
      'GET /ssh_keys': {
        'error': {'code': 'unauthorized', 'message': 'invalid input in field'}
      },
    })
      ..statuses['GET /ssh_keys'] = 401;

    expect(
      () => _provider(adapter).verifyToken(),
      throwsA(isA<CloudException>().having((e) => e.message, 'message',
          contains('rejected the API token'))),
    );
  });

  test('an ordinary refusal carries Hetzner\'s own words', () async {
    final adapter = _Adapter({
      'POST /servers': {
        'error': {
          'code': 'resource_unavailable',
          'message': 'server type not available in this location'
        }
      },
    })
      ..statuses['POST /servers'] = 400;

    expect(
      () => _provider(adapter).createServer(
        name: 'x',
        serverType: 'cx22',
        image: 'ubuntu-24.04',
        location: 'fsn1',
      ),
      throwsA(isA<CloudException>().having((e) => e.message, 'message',
          contains('server type not available in this location'))),
    );
  });

  test('an empty token fails before any request is made', () async {
    final adapter = _Adapter(const {});

    await expectLater(
      _provider(adapter, token: '  ').listServers(),
      throwsA(isA<CloudException>()),
    );
    expect(adapter.calls, isEmpty);
  });

  test('a delete accepts the empty body Hetzner returns', () async {
    final adapter = _Adapter(const {})..statuses['DELETE /servers/7'] = 204;

    await _provider(adapter).deleteServer('7');

    expect(adapter.calls.single, contains('/servers/7'));
  });

  test('the server list survives a server_types call that fails', () async {
    final adapter = _Adapter({
      'GET /pricing': _pricing,
      'GET /server_types': {
        'error': {'code': 'rate_limit_exceeded', 'message': 'slow down'}
      },
      'GET /servers': {
        'servers': [_server()],
      },
    })
      ..statuses['GET /server_types'] = 429;

    final servers = await _provider(adapter).listServers();

    expect(servers, hasLength(1));
    // No price to show, but the row — and its delete button — still renders.
    expect(servers.single.monthlyPrice, '');
  });
}
