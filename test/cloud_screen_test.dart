// Widget tests for lib/screens/cloud_screen.dart — the quick-deploy surface
// added for bostrot/ai-tasks#62.
//
// There is no localization delegate here, so `.i18n()` returns the key it was
// given; asserting on `cloud-text` is what proves the label goes through i18n
// rather than being a hardcoded English string.

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wsl2distromanager/api/cloud/cloud_deploy_service.dart';
import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/api/cloud/cloud_provider.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/screens/cloud_screen.dart';

import 'fake_cloud.dart';

CloudServer _server({
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
      labels: labels,
    );

void main() {
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
      messages.add(msg.toString());
    };
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    messages.clear();
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(FluentApp(home: ScaffoldPage(content: page)));
    await tester.pumpAndSettle();
  }

  Future<void> openRow(WidgetTester tester, String name) async {
    await tester.tap(find.textContaining(name).first);
    await tester.pumpAndSettle();
  }

  testWidgets('with no token stored the screen asks for one', (tester) async {
    await pump(tester, const CloudPage());

    expect(find.byKey(const ValueKey('test-cloud-setup')), findsOneWidget);
    expect(find.byKey(const ValueKey('test-cloud-token')), findsOneWidget);
    // Nothing that talks to a provider is offered before there is an account.
    expect(find.byKey(const ValueKey('test-cloud-deploy')), findsNothing);
    expect(find.byKey(const ValueKey('test-cloud-list')), findsNothing);
  });

  testWidgets('an empty token is refused before any request', (tester) async {
    await pump(tester, const CloudPage());

    await tester.tap(find.byKey(const ValueKey('test-cloud-connect')));
    await tester.pumpAndSettle();

    expect(messages, contains('cloudtokenmissing-text'));
    expect(prefs.getString(cloudTokenPrefKey(CloudProviderId.hetzner)), isNull);
  });

  testWidgets('servers render with their address, size and price',
      (tester) async {
    final provider = FakeCloudProvider(servers: [_server()]);
    await pump(tester, CloudPage(provider: provider));

    expect(find.byKey(const ValueKey('test-cloud-server-1')), findsOneWidget);
    expect(find.textContaining('203.0.113.10'), findsOneWidget);
    expect(find.textContaining('cx22'), findsOneWidget);
    expect(find.textContaining('nbg1'), findsOneWidget);
    // The price goes through i18n, so with no delegate the caption carries
    // the key rather than the formatted number — what matters here is that
    // the row shows a price at all, since a forgotten server is the
    // expensive mistake this screen can cause.
    expect(find.textContaining('cloudpermonth-text'), findsOneWidget);
  });

  testWidgets('an account with no servers gets an explanation', (tester) async {
    await pump(tester, CloudPage(provider: FakeCloudProvider()));

    expect(find.byKey(const ValueKey('test-cloud-empty')), findsOneWidget);
    expect(find.text('nocloudservershint-text'), findsOneWidget);
  });

  testWidgets('a provider that refuses shows its own words', (tester) async {
    final provider = FakeCloudProvider()
      ..failure = const CloudException('Hetzner Cloud rejected the API token.');
    await pump(tester, CloudPage(provider: provider));

    expect(find.byKey(const ValueKey('test-cloud-error')), findsOneWidget);
    expect(find.textContaining('rejected the API token'), findsOneWidget);
  });

  testWidgets('pull back is offered only for a server this app deployed',
      (tester) async {
    final provider = FakeCloudProvider(servers: [
      _server(labels: const {CloudServer.deployedInstanceLabel: 'Ubuntu'}),
      _server(id: '2', name: 'hand-made'),
    ]);
    await pump(tester, CloudPage(provider: provider));

    await openRow(tester, 'deploy-1');
    expect(find.byKey(const ValueKey('test-cloud-pull-1')), findsOneWidget);

    await openRow(tester, 'hand-made');
    // Nothing of this app's is on it, so there is nothing to bring back.
    expect(find.byKey(const ValueKey('test-cloud-pull-2')), findsNothing);
  });

  testWidgets('powering a server off goes through the provider',
      (tester) async {
    final provider = FakeCloudProvider(servers: [_server()]);
    await pump(tester, CloudPage(provider: provider));

    await openRow(tester, 'deploy-1');
    await tester.tap(find.byKey(const ValueKey('test-cloud-toggle-1')));
    await tester.pumpAndSettle();

    expect(provider.poweredOff, ['1']);
    expect(messages, contains('cloudpoweredoff-text'));
  });

  testWidgets('deleting a server asks first and never deletes on its own',
      (tester) async {
    final provider = FakeCloudProvider(servers: [_server()]);
    await pump(tester, CloudPage(provider: provider));

    await openRow(tester, 'deploy-1');
    await tester.tap(find.byKey(const ValueKey('test-cloud-delete-1')));
    await tester.pumpAndSettle();

    // The confirmation is up and nothing has been deleted yet.
    expect(find.text('clouddeletequestion-text'), findsOneWidget);
    expect(provider.deleted, isEmpty);
  });

  testWidgets('a stopped server cannot be pulled from', (tester) async {
    final provider = FakeCloudProvider(servers: [
      _server(
        state: CloudServerState.off,
        labels: const {CloudServer.deployedInstanceLabel: 'Ubuntu'},
      ),
    ]);
    await pump(tester, CloudPage(provider: provider));

    await openRow(tester, 'deploy-1');
    final button = tester.widget<Button>(
        find.byKey(const ValueKey('test-cloud-pull-1')));
    expect(button.onPressed, isNull);
  });

  testWidgets('the deploy form offers the host instances and a suggested name',
      (tester) async {
    final provider = FakeCloudProvider(
      catalogueValue: const CloudCatalogue(
        serverTypes: [CloudServerType(id: '22', name: 'cx22', cores: 2)],
        locations: [CloudLocation(id: '1', name: 'nbg1')],
        images: [CloudImage(id: 'ubuntu-24.04', name: 'ubuntu-24.04')],
      ),
    );
    final backend = FakeDeployBackend(instances: ['Ubuntu', 'Debian']);
    await pump(
      tester,
      CloudPage(
        provider: provider,
        backend: backend,
        service: CloudDeployService(provider: provider, backend: backend),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-cloud-deploy')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-cloud-deploy-dialog')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('test-cloud-instance-combo')),
        findsOneWidget);
    final name = tester
        .widget<TextBox>(find.byKey(const ValueKey('test-cloud-server-name')))
        .controller!
        .text;
    expect(name, startsWith('ubuntu-'));
    expect(cloudNamePattern.hasMatch(name), isTrue);
  });

  testWidgets('the preselected server type is one the instances can run on',
      (tester) async {
    // Hetzner's list is alphabetical, which puts its ARM types first; an
    // x86 machine offered `cax11` by default would fail every deploy with
    // "exec format error", minutes and one billed server later.
    final provider = FakeCloudProvider(
      catalogueValue: const CloudCatalogue(
        serverTypes: [
          CloudServerType(id: '45', name: 'cax11', architecture: 'arm'),
          CloudServerType(id: '22', name: 'cx22', architecture: 'x86'),
        ],
        locations: [CloudLocation(id: '1', name: 'nbg1')],
        images: [CloudImage(id: 'ubuntu-24.04', name: 'ubuntu-24.04')],
      ),
    );
    final backend = FakeDeployBackend(instances: ['Ubuntu']);
    await pump(
      tester,
      CloudPage(
        provider: provider,
        backend: backend,
        service: CloudDeployService(
            provider: provider, backend: backend, localArchitecture: 'x86'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-cloud-deploy')));
    await tester.pumpAndSettle();

    final combo = tester.widget<ComboBox<String>>(
        find.byKey(const ValueKey('test-cloud-type-combo')));
    expect(combo.value, 'cx22');
    // The other one is listed — it is on offer — but cannot be chosen.
    final enabled = {for (final item in combo.items!) item.value: item.enabled};
    expect(enabled, {'cax11': false, 'cx22': true});
    // And the architecture is on the label, so a choice reads as what it
    // is rather than as a cheaper size.
    expect(find.textContaining('cx22 · x86'), findsOneWidget);
  });

  testWidgets('the suggested name is legal even for an awkward instance name',
      (tester) async {
    // A default the form rejects the moment it opens is worse than none: a
    // leading underscore would suggest a name starting with '-', and a long
    // instance name would overrun what a provider accepts.
    final provider = FakeCloudProvider(
      catalogueValue: const CloudCatalogue(
        serverTypes: [CloudServerType(id: '22', name: 'cx22')],
        locations: [CloudLocation(id: '1', name: 'nbg1')],
        images: [CloudImage(id: 'ubuntu-24.04', name: 'ubuntu-24.04')],
      ),
    );
    final backend = FakeDeployBackend(instances: ['_${'A' * 90}']);
    await pump(
      tester,
      CloudPage(
        provider: provider,
        backend: backend,
        service: CloudDeployService(provider: provider, backend: backend),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-cloud-deploy')));
    await tester.pumpAndSettle();

    final name = tester
        .widget<TextBox>(find.byKey(const ValueKey('test-cloud-server-name')))
        .controller!
        .text;
    expect(cloudNamePattern.hasMatch(name), isTrue, reason: name);
  });

  // On WSL a pull is an import and nothing else. On the Apple backend it
  // restores into a copy of the VM the deploy came from, which the user has
  // to have kept and stopped — so the dialog cannot say the same thing on
  // both backends.
  Future<void> openPull(WidgetTester tester, VmBackend backend) async {
    final provider = FakeCloudProvider(servers: [
      _server(labels: const {CloudServer.deployedInstanceLabel: 'Ubuntu'}),
    ]);
    await pump(
      tester,
      CloudPage(
        provider: provider,
        backend: backend,
        service: CloudDeployService(provider: provider, backend: backend),
      ),
    );
    await openRow(tester, 'deploy-1');
    await tester.tap(find.byKey(const ValueKey('test-cloud-pull-1')));
    await tester.pumpAndSettle();
  }

  testWidgets('the pull dialog describes a plain import by default',
      (tester) async {
    await openPull(tester, FakeDeployBackend());
    expect(find.textContaining('cloudpullbody-text'), findsOneWidget);
    expect(find.textContaining('cloudpullbodyclone-text'), findsNothing);
  });

  testWidgets('the pull dialog says so when a local base is restored onto',
      (tester) async {
    await openPull(tester, FakeDeployBackend(rootfsImportNeedsBase: true));
    expect(find.textContaining('cloudpullbodyclone-text'), findsOneWidget);
  });

  testWidgets('a backend that cannot export a rootfs says so instead of '
      'opening the form', (tester) async {
    final provider = FakeCloudProvider();
    final backend = FakeDeployBackend(rootfsExport: false);
    await pump(
      tester,
      CloudPage(
        provider: provider,
        backend: backend,
        service: CloudDeployService(provider: provider, backend: backend),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-cloud-deploy')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('test-cloud-deploy-dialog')), findsNothing);
    expect(messages, contains('clouddeploynotsupported-text'));
  });
}
