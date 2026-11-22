// The cloud_* MCP family (bostrot/ai-tasks#67).
//
// Read-only by construction: a create is a recurring bill and a delete
// destroys a disk, so both stay on the Cloud screen behind a confirmation a
// person clicks. The registration test below is the guard on that — a
// cloud_delete_server added later fails here before it can ship.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/experimental_features.dart';
import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/api/cloud/cloud_provider.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';

import 'fake_cloud.dart';
import 'vm_backend_test.dart' show FakeBackend;

/// A backend that can hand an instance over as a rootfs tarball: the cloud_*
/// family follows the Cloud destination, which is only offered on one that
/// can (bostrot/ai-tasks#62, #87).
class _CloudBackend extends FakeBackend {
  @override
  VmFeatures get features => const VmFeatures(rootfsExport: true);
}

CloudServer server({
  String id = '1',
  String name = 'deploy-1',
  CloudServerState state = CloudServerState.running,
  String ip = '203.0.113.10',
  Map<String, String> labels = const {},
}) =>
    CloudServer(
      id: id,
      name: name,
      state: state,
      provider: CloudProviderId.hetzner,
      ipv4: ip,
      serverType: 'cx22',
      location: 'nbg1',
      monthlyPrice: '3.69',
      currency: 'EUR',
      image: 'ubuntu-24.04',
      labels: labels,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Notify();
    Notify.message = (msg,
        {duration,
        severity = InfoBarSeverity.info,
        loading = false,
        useWidget = false,
        leadingIcon = true,
        dynamic widget}) {};
  });

  late FakeCloudProvider provider;
  late Map<String, Future<String> Function(Map<String, dynamic>)> handlers;
  late List<String> names;

  /// Rebuild the registry against [supplied] as the connected account.
  void build({CloudProvider? Function()? supplied}) {
    final backend = _CloudBackend();
    final tools = buildWslMcpTools(
      backend,
      WslTerminalManager(wslApi: backend),
      cloudProvider: supplied ?? () => provider,
    );
    handlers = {for (final t in tools) t.name: t.handler};
    names = tools.map((t) => t.name).toList();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    ExperimentalFeatures.overrideAll = true;
    provider = FakeCloudProvider(servers: [server()]);
    build();
  });

  tearDown(() => ExperimentalFeatures.overrideAll = null);

  test('only the two read tools are registered', () {
    expect(names, containsAll(['cloud_servers', 'cloud_server_info']));
    expect(names.where((n) => n.startsWith('cloud_')),
        everyElement(isIn({'cloud_servers', 'cloud_server_info'})));
  });

  test('the family is not registered while Cloud is switched off', () {
    ExperimentalFeatures.overrideAll = false;
    final backend = _CloudBackend();
    final hidden =
        buildWslMcpTools(backend, WslTerminalManager(wslApi: backend))
            .map((t) => t.name);
    expect(hidden.where((n) => n.startsWith('cloud_')), isEmpty);
  });

  test('nor on a backend that cannot export a rootfs, even switched on', () {
    // Like the pane entry: a Cloud that cannot deploy is not offered, and
    // its tools go with it (bostrot/ai-tasks#62).
    final backend = FakeBackend();
    final hidden =
        buildWslMcpTools(backend, WslTerminalManager(wslApi: backend))
            .map((t) => t.name);
    expect(hidden.where((n) => n.startsWith('cloud_')), isEmpty);
  });

  test('cloud_servers reports state, address, type and price', () async {
    final out = await handlers['cloud_servers']!({});
    expect(out, contains('deploy-1'));
    expect(out, contains('running'));
    expect(out, contains('203.0.113.10'));
    expect(out, contains('cx22'));
    // A forgotten server is the expensive mistake this feature can cause, so
    // the price is on the row rather than a call away.
    expect(out, contains('3.69 EUR/mo'));
  });

  test('a deployed server names the instance running on it', () async {
    provider.servers = [
      server(labels: const {CloudServer.deployedInstanceLabel: 'Ubuntu-Dev'}),
    ];
    expect(await handlers['cloud_servers']!({}), contains('Ubuntu-Dev'));
  });

  test('running_only drops the stopped ones', () async {
    provider.servers = [
      server(id: '1', name: 'up'),
      server(id: '2', name: 'down', state: CloudServerState.off),
    ];
    final out = await handlers['cloud_servers']!({'running_only': true});
    expect(out, contains('up'));
    expect(out, isNot(contains('down')));
  });

  test('an empty account is a sentence, not a blank', () async {
    provider.servers = [];
    expect(await handlers['cloud_servers']!({}),
        'The account has no servers.');
  });

  test('cloud_server_info takes the name a person would say', () async {
    final out = await handlers['cloud_server_info']!({'server': 'DEPLOY-1'});
    expect(out, contains('id: 1'));
    expect(out, contains('ipv4: 203.0.113.10'));
    expect(out, contains('image: ubuntu-24.04'));
  });

  test('cloud_server_info also takes the provider id', () async {
    expect(await handlers['cloud_server_info']!({'server': '1'}),
        contains('deploy-1'));
  });

  test('an unknown server points at the tool that lists them', () async {
    final out = await handlers['cloud_server_info']!({'server': 'nope'});
    expect(out, contains('No server called "nope"'));
    expect(out, contains('cloud_servers'));
  });

  test('no connected account is explained rather than thrown as a null',
      () async {
    build(supplied: () => null);
    await expectLater(
        handlers['cloud_servers']!({}),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            contains('No cloud account is connected'))));
  });

  test('the provider is resolved per call, so a token typed after startup '
      'takes effect', () async {
    // A provider built once at registration would stay null for the session.
    CloudProvider? connected;
    build(supplied: () => connected);
    await expectLater(handlers['cloud_servers']!({}), throwsArgumentError);
    connected = provider;
    expect(await handlers['cloud_servers']!({}), contains('deploy-1'));
  });
}
