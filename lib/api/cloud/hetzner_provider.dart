// Hetzner Cloud, over its documented REST API.
//
// Why the API and not the `hcloud` CLI, when Containers and Kubernetes both
// shell out to the user's own binary: nobody has `hcloud` installed. Docker
// and kubectl are already on the machine of anyone who would open those
// screens, and driving the tool they already trust buys every auth plugin
// for free. A cloud account has no such local tool — the credential is one
// API token the user pastes in — so the trade goes the other way.
//
// Everything here is one HTTP call plus a parse. Anything with a *policy* in
// it (which image to pick, how long to wait for a boot, what to do with the
// machine afterwards) belongs to CloudDeployService, not to this file.

import 'package:dio/dio.dart';
import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/api/cloud/cloud_provider.dart';

/// Hetzner's API root. Versioned in the path, so a breaking change arrives as
/// a new prefix rather than as a silently different answer.
const String hetznerApiBase = 'https://api.hetzner.cloud/v1';

/// Page size for the listing calls. Hetzner's maximum is 50.
const int _pageSize = 50;

/// How many pages a listing will walk before giving up. A project with more
/// than 500 servers is not what this screen is for, and an unbounded loop
/// against a paginating API is how a UI hangs forever.
const int _maxPages = 10;

class HetznerProvider implements CloudProvider {
  HetznerProvider({required this.token, Dio? dio, this.timeout = _defaultTimeout})
      : _dio = dio ?? Dio();

  static const Duration _defaultTimeout = Duration(seconds: 30);

  /// The account's API token, from Hetzner Cloud Console → Security → API
  /// tokens. Read/write is required: this app creates and deletes servers.
  final String token;

  final Dio _dio;

  /// How long any single API call may take.
  final Duration timeout;

  @override
  CloudProviderId get id => CloudProviderId.hetzner;

  /// Server type prices, kept for the life of the provider so the server list
  /// can show what each machine costs without a second round trip per row.
  Map<String, CloudServerType>? _typesByName;

  Options get _options => Options(
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        sendTimeout: timeout,
        receiveTimeout: timeout,
        // Every status is handled here: Hetzner puts a readable reason in the
        // body of a 4xx, and letting Dio throw would replace it with
        // "Http status error [403]".
        validateStatus: (_) => true,
      );

  @override
  Future<void> verifyToken() async {
    // The cheapest authenticated call there is: one page of one ssh key.
    await _get('/ssh_keys', query: {'per_page': 1});
  }

  @override
  Future<List<CloudServer>> listServers() async {
    final types = await _serverTypesByName();
    final servers = <CloudServer>[];
    await _paged('/servers', 'servers', (item) {
      servers.add(_parseServer(item, types));
    });
    // Newest first: ids are monotonic, and the machine somebody just created
    // is the one they are looking for.
    servers.sort((a, b) =>
        (int.tryParse(b.id) ?? 0).compareTo(int.tryParse(a.id) ?? 0));
    return servers;
  }

  @override
  Future<CloudServer> getServer(String serverId) async {
    final body = await _get('/servers/$serverId');
    final server = body['server'];
    if (server is! Map) {
      throw const CloudException('Hetzner did not return a server.');
    }
    return _parseServer(
        Map<String, dynamic>.from(server), await _serverTypesByName());
  }

  @override
  Future<CloudCatalogue> catalogue() async {
    final currency = await _currency();
    final types = <CloudServerType>[];
    await _paged('/server_types', 'server_types', (item) {
      final type = _parseServerType(item, currency);
      if (type != null) types.add(type);
    });
    types.sort((a, b) => a.name.compareTo(b.name));

    final locations = <CloudLocation>[];
    await _paged('/locations', 'locations', (item) {
      locations.add(CloudLocation(
        id: '${item['id'] ?? ''}',
        name: '${item['name'] ?? ''}',
        description: '${item['description'] ?? ''}',
        country: '${item['country'] ?? ''}',
        city: '${item['city'] ?? ''}',
      ));
    });
    locations.sort((a, b) => a.name.compareTo(b.name));

    // Keyed by name, which also deduplicates: Hetzner ships every system
    // image once per architecture, so `ubuntu-24.04` comes back twice. Two
    // entries with the same value in one ComboBox is an assertion failure in
    // fluent_ui, not a cosmetic duplicate — and there is nothing to choose
    // between them anyway, since creating a server *by name* makes Hetzner
    // pick the build matching the server type's architecture.
    final images = <String, CloudImage>{};
    await _paged('/images', 'images', (item) {
      // Servers are created from an image *name* ("ubuntu-24.04"), which is
      // stable across the rebuilds Hetzner does; the numeric id is not.
      final name = '${item['name'] ?? ''}'.trim();
      if (name.isEmpty || images.containsKey(name)) return;
      images[name] = CloudImage(
        id: name,
        name: name,
        description: '${item['description'] ?? ''}',
        architecture: '${item['architecture'] ?? ''}',
      );
    }, query: {'type': 'system', 'status': 'available'});
    final imageList = images.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return CloudCatalogue(
        serverTypes: types, locations: locations, images: imageList);
  }

  @override
  Future<List<CloudSshKey>> listSshKeys() async {
    final keys = <CloudSshKey>[];
    await _paged('/ssh_keys', 'ssh_keys', (item) {
      keys.add(CloudSshKey(
        id: '${item['id'] ?? ''}',
        name: '${item['name'] ?? ''}',
        fingerprint: '${item['fingerprint'] ?? ''}',
      ));
    });
    return keys;
  }

  @override
  Future<CloudSshKey> createSshKey(String name, String publicKey) async {
    final body = await _post('/ssh_keys', {
      'name': name,
      'public_key': publicKey.trim(),
    });
    final key = body['ssh_key'];
    if (key is! Map) {
      throw const CloudException('Hetzner did not return the new SSH key.');
    }
    return CloudSshKey(
      id: '${key['id'] ?? ''}',
      name: '${key['name'] ?? ''}',
      fingerprint: '${key['fingerprint'] ?? ''}',
    );
  }

  @override
  Future<CloudServer> createServer({
    required String name,
    required String serverType,
    required String image,
    required String location,
    List<String> sshKeyIds = const [],
    String userData = '',
    Map<String, String> labels = const {},
  }) async {
    final body = await _post('/servers', {
      'name': name,
      'server_type': serverType,
      'image': image,
      'location': location,
      'start_after_create': true,
      if (sshKeyIds.isNotEmpty)
        // Hetzner takes ids as numbers or names as strings; ints keep a key
        // literally named "42" from resolving to the wrong one.
        'ssh_keys': sshKeyIds.map((id) => int.tryParse(id) ?? id).toList(),
      if (userData.isNotEmpty) 'user_data': userData,
      if (labels.isNotEmpty) 'labels': labels,
    });
    final server = body['server'];
    if (server is! Map) {
      throw const CloudException('Hetzner did not return the new server.');
    }
    return _parseServer(
        Map<String, dynamic>.from(server), await _serverTypesByName());
  }

  @override
  Future<void> powerOn(String serverId) =>
      _post('/servers/$serverId/actions/poweron', const {});

  @override
  Future<void> powerOff(String serverId) =>
      _post('/servers/$serverId/actions/poweroff', const {});

  @override
  Future<void> deleteServer(String serverId) async {
    final response = await _request(
        () => _dio.delete('$hetznerApiBase/servers/$serverId',
            options: _options));
    _check(response, 'DELETE /servers/$serverId');
  }

  /// Server types keyed by name, fetched at most once per provider instance.
  ///
  /// Best effort: a failure here must not take down the server list, which is
  /// the one thing on the screen a user with a runaway bill needs.
  Future<Map<String, CloudServerType>> _serverTypesByName() async {
    final cached = _typesByName;
    if (cached != null) return cached;
    try {
      final currency = await _currency();
      final types = <String, CloudServerType>{};
      await _paged('/server_types', 'server_types', (item) {
        final type = _parseServerType(item, currency);
        if (type != null) types[type.name] = type;
      });
      return _typesByName = types;
    } on CloudException {
      return _typesByName = const {};
    }
  }

  String? _currencyCache;

  /// The account's billing currency. Hetzner bills most accounts in EUR but
  /// not all, and printing the wrong symbol next to a price is worse than
  /// printing none — so a failure falls back to the documented default.
  Future<String> _currency() async {
    final cached = _currencyCache;
    if (cached != null) return cached;
    try {
      final body = await _get('/pricing');
      final pricing = body['pricing'];
      final currency =
          pricing is Map ? '${pricing['currency'] ?? ''}'.trim() : '';
      return _currencyCache = currency.isEmpty ? 'EUR' : currency.toUpperCase();
    } on CloudException {
      return _currencyCache = 'EUR';
    }
  }

  CloudServer _parseServer(
      Map<String, dynamic> item, Map<String, CloudServerType> types) {
    final publicNet = item['public_net'];
    String ip(String family) {
      if (publicNet is! Map) return '';
      final entry = publicNet[family];
      if (entry is! Map) return '';
      final value = '${entry['ip'] ?? ''}'.trim();
      // Hetzner reports IPv6 as the whole /64 the server owns; the address
      // that answers is the first one in it.
      if (family == 'ipv6' && value.contains('/')) {
        return '${value.split('/').first}1';
      }
      return value;
    }

    final serverType = item['server_type'];
    final typeName =
        serverType is Map ? '${serverType['name'] ?? ''}'.trim() : '';
    final datacenter = item['datacenter'];
    var locationName = '';
    if (datacenter is Map) {
      final location = datacenter['location'];
      locationName = location is Map
          ? '${location['name'] ?? ''}'.trim()
          : '${datacenter['name'] ?? ''}'.trim();
    }
    final image = item['image'];
    final imageName = image is Map
        ? '${image['description'] ?? image['name'] ?? ''}'.trim()
        : '';
    final priced = types[typeName];
    final rawLabels = item['labels'];
    final labels = <String, String>{};
    if (rawLabels is Map) {
      rawLabels.forEach((key, value) => labels['$key'] = '${value ?? ''}');
    }

    return CloudServer(
      id: '${item['id'] ?? ''}',
      name: '${item['name'] ?? ''}',
      state: CloudServerState.parse('${item['status'] ?? ''}'),
      provider: CloudProviderId.hetzner,
      ipv4: ip('ipv4'),
      ipv6: ip('ipv6'),
      serverType: typeName,
      location: locationName,
      image: imageName,
      monthlyPrice: priced?.monthlyPrice ?? '',
      currency: priced?.currency ?? '',
      labels: labels,
    );
  }

  CloudServerType? _parseServerType(Map<String, dynamic> item, String currency) {
    final name = '${item['name'] ?? ''}'.trim();
    if (name.isEmpty) return null;
    // Deprecated types can still be listed but not ordered; offering one is a
    // create that fails a minute later with an error about a type the user
    // never chose on purpose.
    if (item['deprecation'] != null) return null;
    return CloudServerType(
      id: '${item['id'] ?? ''}',
      name: name,
      description: '${item['description'] ?? ''}',
      cores: _int(item['cores']),
      memoryGb: _double(item['memory']),
      diskGb: _int(item['disk']),
      monthlyPrice: _cheapestMonthly(item['prices']),
      currency: currency,
      architecture: '${item['architecture'] ?? ''}',
    );
  }

  /// The lowest monthly gross price across the locations a type is sold in.
  /// Hetzner prices the same type differently per location, and the number
  /// next to a size in a picker is a ballpark, not an invoice.
  String _cheapestMonthly(dynamic prices) {
    if (prices is! List) return '';
    double? lowest;
    for (final entry in prices) {
      if (entry is! Map) continue;
      final monthly = entry['price_monthly'];
      if (monthly is! Map) continue;
      final value = double.tryParse('${monthly['gross'] ?? ''}');
      if (value == null) continue;
      if (lowest == null || value < lowest) lowest = value;
    }
    return lowest == null ? '' : lowest.toStringAsFixed(2);
  }

  static int _int(dynamic value) =>
      value is int ? value : int.tryParse('$value') ?? 0;

  static double _double(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

  /// Walk every page of a listing, handing each item to [onItem].
  Future<void> _paged(
    String path,
    String field,
    void Function(Map<String, dynamic> item) onItem, {
    Map<String, dynamic> query = const {},
  }) async {
    var page = 1;
    for (var i = 0; i < _maxPages; i++) {
      final body = await _get(path, query: {
        ...query,
        'page': page,
        'per_page': _pageSize,
      });
      final items = body[field];
      if (items is! List) return;
      for (final item in items) {
        if (item is Map) onItem(Map<String, dynamic>.from(item));
      }
      final next = _nextPage(body);
      if (next == null) return;
      page = next;
    }
  }

  int? _nextPage(Map<String, dynamic> body) {
    final meta = body['meta'];
    if (meta is! Map) return null;
    final pagination = meta['pagination'];
    if (pagination is! Map) return null;
    final next = pagination['next_page'];
    if (next == null) return null;
    return next is int ? next : int.tryParse('$next');
  }

  Future<Map<String, dynamic>> _get(String path,
      {Map<String, dynamic> query = const {}}) async {
    final response = await _request(() => _dio.get(
          '$hetznerApiBase$path',
          queryParameters: query.isEmpty ? null : query,
          options: _options,
        ));
    return _check(response, 'GET $path');
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    final response = await _request(() => _dio.post(
          '$hetznerApiBase$path',
          data: body,
          options: _options,
        ));
    return _check(response, 'POST $path');
  }

  /// Turn transport failures into [CloudException] before anything reads the
  /// response: a DNS failure and a 401 must both arrive at the UI as one
  /// exception type with a sentence in it.
  Future<Response<dynamic>> _request(
      Future<Response<dynamic>> Function() send) async {
    if (token.trim().isEmpty) {
      throw const CloudException(
          'No API token configured for this cloud provider.');
    }
    try {
      return await send();
    } on DioException catch (e) {
      throw CloudException(
          'Could not reach Hetzner Cloud: ${e.message ?? e.type.name}');
    }
  }

  /// Validate one response and hand back its decoded body.
  Map<String, dynamic> _check(Response<dynamic> response, String what) {
    final status = response.statusCode ?? 0;
    final data = response.data;
    final body = data is Map ? Map<String, dynamic>.from(data) : null;
    if (status >= 200 && status < 300) {
      // 204 on a delete: no body, nothing to read, not an error.
      return body ?? <String, dynamic>{};
    }
    final error = body?['error'];
    final message = error is Map ? '${error['message'] ?? ''}'.trim() : '';
    if (status == 401 || status == 403) {
      throw CloudException(message.isEmpty
          ? 'Hetzner Cloud rejected the API token.'
          : 'Hetzner Cloud rejected the API token: $message');
    }
    throw CloudException(message.isEmpty
        ? 'Hetzner Cloud refused "$what" (HTTP $status).'
        : 'Hetzner Cloud refused "$what" (HTTP $status): $message');
  }
}

/// Build the provider for [id] with the token stored for it.
///
/// The single place production code obtains a provider; tests inject their
/// own [CloudProvider] into the service and the screen instead.
CloudProvider buildCloudProvider(CloudProviderId id, String token) {
  switch (id) {
    case CloudProviderId.hetzner:
      return HetznerProvider(token: token);
  }
}
