import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/cloud/cloud_deploy_service.dart';
import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/api/cloud/cloud_provider.dart';
import 'package:wsl2distromanager/api/cloud/hetzner_provider.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/empty_state.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';

/// Where a Hetzner API token comes from, shown next to the token box because
/// "paste your API token" is useless to somebody who has never made one.
const String hetznerTokenHelpUrl =
    'https://console.hetzner.cloud/projects';

/// The Cloud screen: the user's servers at a provider, plus the one-step
/// deploy of a local instance onto a new one and the pull back.
///
/// Its own destination for the same reason Containers has one
/// (bostrot/ai-tasks#57, #62): these machines are not instances this app owns
/// — they are somebody else's, they cost money by the hour, and "delete"
/// here means a disk that is gone rather than a local folder that can be
/// re-imported. Mixing them into the Home list would have made every verb on
/// that screen mean two things.
class CloudPage extends StatefulWidget {
  const CloudPage({super.key, this.provider, this.service, this.backend});

  /// Injected by tests; production builds one from the stored token.
  final CloudProvider? provider;

  /// Injected by tests; production builds one around [provider].
  final CloudDeployService? service;

  /// Injected by tests; production reads the host's backend.
  final VmBackend? backend;

  @override
  State<CloudPage> createState() => _CloudPageState();
}

class _CloudPageState extends State<CloudPage> {
  late CloudProviderId _providerId = activeCloudProviderId();
  CloudProvider? _provider;
  Future<List<CloudServer>>? _servers;

  /// The token box on the setup card. Only ever holds what the user just
  /// typed — a stored token is never read back into the UI.
  final TextEditingController _tokenController = TextEditingController();
  bool _connecting = false;

  /// Servers with an action in flight, so their buttons stay disabled until
  /// the provider has answered.
  final Set<String> _busy = {};

  /// The stage line shown while a deploy or a pull runs, or null when none
  /// is running. Both take minutes, so the screen says which minute it is in.
  String? _progress;

  VmBackend get _backend => widget.backend ?? vmBackend();

  @override
  void initState() {
    super.initState();
    _connectStored();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  /// Build a provider from the injected one or the stored token, and load the
  /// server list when there is one.
  void _connectStored() {
    final injected = widget.provider;
    if (injected != null) {
      _provider = injected;
      _providerId = injected.id;
      _servers = _load();
      return;
    }
    final token = cloudToken(_providerId);
    if (token.isEmpty) return;
    _provider = buildCloudProvider(_providerId, token);
    _servers = _load();
  }

  Future<List<CloudServer>> _load() async {
    final provider = _provider;
    if (provider == null) return const [];
    return provider.listServers();
  }

  void _reload() {
    if (!mounted) return;
    // A block, not an arrow: `=> _servers = _load()` hands setState the
    // future as its return value and Flutter rejects that outright.
    setState(() {
      _servers = _load();
    });
  }

  CloudDeployService _deployService() =>
      widget.service ??
      CloudDeployService(provider: _provider!, backend: widget.backend);

  /// Verify the pasted token before storing it: a token that is wrong, or
  /// read-only when this needs read/write, otherwise only fails minutes later
  /// in the middle of a deploy.
  Future<void> _connect() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      Notify.message('cloudtokenmissing-text'.i18n(),
          severity: InfoBarSeverity.warning);
      return;
    }
    setState(() => _connecting = true);
    final candidate = buildCloudProvider(_providerId, token);
    try {
      await candidate.verifyToken();
    } catch (e) {
      if (mounted) setState(() => _connecting = false);
      Notify.message('$e', severity: InfoBarSeverity.error);
      return;
    }
    await prefs.setString(cloudProviderPrefKey, _providerId.id);
    await prefs.setString(cloudTokenPrefKey(_providerId), token);
    _tokenController.clear();
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _provider = candidate;
      _servers = _load();
    });
    Notify.message('cloudconnected-text'.i18n([_providerId.label]));
  }

  void _disconnect(BuildContext host) {
    dialog(
      hostContext: host,
      item: _providerId.label,
      title: 'clouddisconnectquestion-text'.i18n([_providerId.label]),
      body: 'clouddisconnectbody-text'.i18n(),
      submitText: 'clouddisconnect-text'.i18n(),
      submitInput: false,
      onSubmit: (_) async {
        await prefs.remove(cloudTokenPrefKey(_providerId));
        if (!mounted) return;
        setState(() {
          _provider = null;
          _servers = null;
        });
      },
    );
  }

  /// Run one provider action and reload, surfacing the provider's own words.
  Future<void> _act(
    CloudServer server,
    Future<void> Function() action,
    String okMessage,
  ) async {
    if (_busy.contains(server.id)) return;
    setState(() => _busy.add(server.id));
    try {
      await action();
      Notify.message(okMessage);
    } catch (e) {
      Notify.message('$e', severity: InfoBarSeverity.error);
    } finally {
      if (mounted) {
        setState(() => _busy.remove(server.id));
        _reload();
      }
    }
  }

  void _confirmDelete(BuildContext host, CloudServer server) {
    dialog(
      hostContext: host,
      item: server.name,
      title: 'clouddeletequestion-text'.i18n([server.name]),
      body: 'clouddeletebody-text'.i18n(),
      submitText: 'delete-text'.i18n(),
      submitInput: false,
      submitStyle: ButtonStyle(
        backgroundColor: ButtonState.all(Colors.red),
        foregroundColor: ButtonState.all(Colors.white),
      ),
      onSubmit: (_) async {
        await _act(
          server,
          () => _provider!.deleteServer(server.id),
          'clouddeleted-text'.i18n([server.name]),
        );
      },
    );
  }

  /// Ask for a local name, then bring the deployed instance back down.
  void _confirmPull(BuildContext host, CloudServer server) {
    final instance = server.deployedInstance;
    if (instance == null) return;
    dialog(
      hostContext: host,
      item: instance,
      title: 'cloudpullquestion-text'.i18n([instance]),
      body: _backend.features.rootfsImportNeedsBase
          ? 'cloudpullbodyclone-text'.i18n([instance])
          : 'cloudpullbody-text'.i18n([instance]),
      submitText: 'cloudpull-text'.i18n(),
      placeholder: 'cloudpullname-text'.i18n(),
      validateInput: (value) => cloudNamePattern.hasMatch(value.trim())
          ? null
          : 'cloudinvalidname-text'.i18n(),
      onSubmit: (value) async {
        await _runTransfer(() async {
          await _deployService().pullBack(
            server: server,
            instance: instance,
            localName: '$value'.trim(),
            onProgress: _onProgress,
          );
          Notify.message('cloudpulled-text'.i18n([instance, '$value'.trim()]));
        });
      },
    );
  }

  void _onProgress(DeployProgress progress) {
    if (!mounted) return;
    final label = cloudStageLabel(progress.stage);
    setState(() => _progress =
        progress.detail.isEmpty ? label : '$label — ${progress.detail}');
  }

  /// Wrap a deploy or a pull: one at a time, progress line while it runs,
  /// provider/ssh wording on failure, list refreshed either way.
  Future<void> _runTransfer(Future<void> Function() body) async {
    if (_progress != null) return;
    setState(() => _progress = cloudStageLabel(DeployStage.exporting));
    try {
      await body();
    } catch (e) {
      Notify.message('$e', severity: InfoBarSeverity.error);
    } finally {
      if (mounted) {
        setState(() => _progress = null);
        _reload();
      }
    }
  }

  void _openDeployForm(BuildContext host) async {
    final provider = _provider;
    if (provider == null) return;
    final service = _deployService();
    if (!service.canDeploy) {
      Notify.message('clouddeploynotsupported-text'.i18n(),
          severity: InfoBarSeverity.warning);
      return;
    }
    final instances = (await _backend.list(false)).all;
    if (instances.isEmpty) {
      Notify.message('clouddeploynoinstances-text'.i18n(),
          severity: InfoBarSeverity.warning);
      return;
    }
    CloudCatalogue catalogue;
    try {
      catalogue = await provider.catalogue();
    } catch (e) {
      Notify.message('$e', severity: InfoBarSeverity.error);
      return;
    }
    if (!mounted || !host.mounted) return;
    showDialog(
      context: host,
      builder: (context) => _DeployDialog(
        instances: instances,
        catalogue: catalogue,
        localArchitecture: service.localArchitecture,
        onDeploy: (request) => _runTransfer(() async {
          final server = await service.deploy(
            instance: request.instance,
            serverName: request.serverName,
            serverType: request.serverType,
            serverArchitecture: request.serverArchitecture,
            image: request.image,
            location: request.location,
            onProgress: _onProgress,
          );
          Notify.message(
              'clouddeployed-text'.i18n([request.instance, server.address]));
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context),
          if (_progress != null) _progressBar(context),
          Expanded(
            child: _provider == null
                ? _setupCard(context)
                : _serverList(context),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final connected = _provider != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
                child: Text('cloud-text'.i18n(),
                    style: FluentTheme.of(context).typography.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
                child: Text('cloudinfo-text'.i18n(),
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 12)),
              ),
            ],
          ),
        ),
        if (connected) ...[
          FilledButton(
            key: const ValueKey('test-cloud-deploy'),
            onPressed: _progress != null ? null : () => _openDeployForm(context),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(FluentIcons.cloud_upload),
                const SizedBox(width: 8),
                Text('clouddeploy-text'.i18n()),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Button(
            key: const ValueKey('test-cloud-refresh'),
            onPressed: _progress != null ? null : _reload,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(FluentIcons.refresh),
                const SizedBox(width: 8),
                Text('refresh-text'.i18n()),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Button(
            key: const ValueKey('test-cloud-disconnect'),
            onPressed: _progress != null ? null : () => _disconnect(context),
            child: Text('clouddisconnect-text'.i18n()),
          ),
        ],
      ],
    );
  }

  Widget _progressBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: InfoBar(
        key: const ValueKey('test-cloud-progress'),
        title: Text('clouddeployrunning-text'.i18n()),
        content: Text(_progress ?? ''),
        severity: InfoBarSeverity.info,
        isLong: true,
        action: const SizedBox.square(dimension: 20, child: ProgressRing()),
      ),
    );
  }

  /// The "connect an account" card, shown until a token verifies.
  Widget _setupCard(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            key: const ValueKey('test-cloud-setup'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('cloudconnect-text'.i18n(),
                    style: FluentTheme.of(context).typography.subtitle),
                const SizedBox(height: 4),
                Text('cloudconnectinfo-text'.i18n(),
                    style: TextStyle(color: secondaryTextColor(context))),
                const SizedBox(height: 16),
                Text('cloudprovider-text'.i18n()),
                const SizedBox(height: 4),
                ComboBox<String>(
                  key: const ValueKey('test-cloud-provider-combo'),
                  value: _providerId.id,
                  items: [
                    for (final provider in CloudProviderId.values)
                      ComboBoxItem(
                          value: provider.id, child: Text(provider.label)),
                  ],
                  onChanged: (id) {
                    final provider = CloudProviderId.byId(id);
                    if (provider == null) return;
                    setState(() => _providerId = provider);
                  },
                ),
                const SizedBox(height: 16),
                Text('cloudtoken-text'.i18n()),
                const SizedBox(height: 4),
                TextBox(
                  key: const ValueKey('test-cloud-token'),
                  controller: _tokenController,
                  obscureText: true,
                  maxLines: 1,
                  placeholder: 'cloudtokenplaceholder-text'.i18n(),
                ),
                const SizedBox(height: 4),
                Text('cloudtokenhint-text'.i18n([hetznerTokenHelpUrl]),
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 12)),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('test-cloud-connect'),
                  onPressed: _connecting ? null : _connect,
                  child: Text(_connecting
                      ? 'loading-text'.i18n()
                      : 'cloudconnectbtn-text'.i18n()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _serverList(BuildContext context) {
    return FutureBuilder<List<CloudServer>>(
      key: const ValueKey('test-cloud-list'),
      future: _servers,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return EmptyState(
            key: const ValueKey('test-cloud-error'),
            icon: FluentIcons.error,
            title: 'cloudproviderfailed-text'.i18n(),
            body: '${snapshot.error}',
          );
        }
        final servers = snapshot.data;
        if (servers == null) {
          return const Center(child: ProgressRing());
        }
        if (servers.isEmpty) {
          return EmptyState(
            key: const ValueKey('test-cloud-empty'),
            icon: FluentIcons.cloud_add,
            title: 'nocloudservers-text'.i18n(),
            body: 'nocloudservershint-text'.i18n(),
          );
        }
        return ListView.builder(
          itemCount: servers.length,
          itemBuilder: (context, index) => _row(context, servers[index]),
        );
      },
    );
  }

  Widget _row(BuildContext context, CloudServer server) {
    final busy = _busy.contains(server.id) || _progress != null;
    final running = server.state.isRunning;
    final instance = server.deployedInstance;
    final caption = [
      if (server.address.isNotEmpty) server.address,
      if (server.serverType.isNotEmpty) server.serverType,
      if (server.location.isNotEmpty) server.location,
      if (server.monthlyPrice.isNotEmpty)
        'cloudpermonth-text'.i18n(['${server.monthlyPrice} ${server.currency}']),
      if (instance != null) 'clouddeployedfrom-text'.i18n([instance]),
    ].where((part) => part.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Expander(
        key: ValueKey('test-cloud-server-${server.id}'),
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${server.name} (${_stateLabel(server.state)})'),
            Text(caption, style: FluentTheme.of(context).typography.caption),
          ],
        ),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            Button(
              key: ValueKey('test-cloud-toggle-${server.id}'),
              onPressed: busy
                  ? null
                  : () => _act(
                        server,
                        () => running
                            ? _provider!.powerOff(server.id)
                            : _provider!.powerOn(server.id),
                        (running ? 'cloudpoweredoff-text' : 'cloudpoweredon-text')
                            .i18n([server.name]),
                      ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(running ? FluentIcons.stop : FluentIcons.play),
                  const SizedBox(width: 10),
                  Text((running ? 'stop-text' : 'start-text').i18n()),
                ],
              ),
            ),
            if (server.address.isNotEmpty)
              Button(
                key: ValueKey('test-cloud-ssh-${server.id}'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: 'ssh $cloudRootUser@${server.address}'));
                  Notify.message('copied-text'.i18n());
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(FluentIcons.copy),
                    const SizedBox(width: 10),
                    Text('cloudcopyssh-text'.i18n()),
                  ],
                ),
              ),
            if (instance != null)
              Button(
                key: ValueKey('test-cloud-pull-${server.id}'),
                onPressed:
                    busy || !running ? null : () => _confirmPull(context, server),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(FluentIcons.cloud_download),
                    const SizedBox(width: 10),
                    Text('cloudpull-text'.i18n()),
                  ],
                ),
              ),
            Button(
              key: ValueKey('test-cloud-delete-${server.id}'),
              style: ButtonStyle(
                foregroundColor: ButtonState.all(destructiveColor(context)),
              ),
              onPressed: busy ? null : () => _confirmDelete(context, server),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.delete, color: destructiveColor(context)),
                  const SizedBox(width: 10),
                  Text('delete-text'.i18n()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _stateLabel(CloudServerState state) {
    switch (state) {
      case CloudServerState.running:
        return 'running-text'.i18n();
      case CloudServerState.off:
        return 'stopped-text'.i18n();
      default:
        return 'cloudstate-${state.name}-text'.i18n();
    }
  }
}

/// What the deploy form collected.
class DeployRequest {
  final String instance;
  final String serverName;
  final String serverType;

  /// What the catalogue says [serverType] runs on, '' when it did not say.
  final String serverArchitecture;
  final String image;
  final String location;

  const DeployRequest({
    required this.instance,
    required this.serverName,
    required this.serverType,
    this.serverArchitecture = '',
    required this.image,
    required this.location,
  });
}

/// The one-screen deploy form: which instance, and the three choices the
/// provider needs to make a machine for it.
class _DeployDialog extends StatefulWidget {
  const _DeployDialog({
    required this.instances,
    required this.catalogue,
    required this.onDeploy,
    this.localArchitecture = '',
  });

  final List<String> instances;
  final CloudCatalogue catalogue;
  final void Function(DeployRequest request) onDeploy;

  /// The architecture family of the instances on offer, so the preselected
  /// server type is one they can run on. '' preselects the first type.
  final String localArchitecture;

  @override
  State<_DeployDialog> createState() => _DeployDialogState();
}

class _DeployDialogState extends State<_DeployDialog> {
  late String _instance = widget.instances.first;
  String? _serverType;
  String? _location;
  String? _image;
  late final TextEditingController _name =
      TextEditingController(text: _suggestName(widget.instances.first));
  String? _validation;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// A server name that is legal everywhere and unlikely to collide: the
  /// instance, lowercased, plus a short timestamp.
  ///
  /// The suggestion has to satisfy [cloudNamePattern] on its own — a default
  /// the form rejects the moment it opens is worse than no default. So the
  /// leading character is forced to be alphanumeric (an instance called
  /// `_work` would otherwise suggest `-work-…`, which reads as a flag) and
  /// the base is trimmed to leave room for the suffix inside the 62-character
  /// limit.
  static String _suggestName(String instance) {
    final stamp = DateTime.now().millisecondsSinceEpoch.remainder(100000);
    final suffix = '-$stamp';
    var base = instance
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'^[^a-z0-9]+'), '');
    if (base.isEmpty) base = 'instance';
    final room = 62 - suffix.length;
    if (base.length > room) base = base.substring(0, room);
    return '$base$suffix';
  }

  /// The default image: the newest Ubuntu on offer, because it is what the
  /// vast majority of rootfs images this app manages are built on and what
  /// `docker.io` installs cleanly from.
  String? get _defaultImage {
    final ubuntu = widget.catalogue.images
        .where((image) => image.name.startsWith('ubuntu-'))
        .toList()
      ..sort((a, b) => b.name.compareTo(a.name));
    if (ubuntu.isNotEmpty) return ubuntu.first.id;
    return widget.catalogue.images.isEmpty
        ? null
        : widget.catalogue.images.first.id;
  }

  /// The preselected server type: the first one of the instances' own
  /// architecture, because the list is alphabetical and at Hetzner that puts
  /// the ARM types (`cax…`) before the x86 ones — a default that would fail
  /// every deploy from an x86 machine.
  String? get _defaultServerType {
    final types = widget.catalogue.serverTypes;
    if (types.isEmpty) return null;
    return types.firstWhere(_canRunHere, orElse: () => types.first).name;
  }

  /// Whether the instances can run on [type]: either side not saying its
  /// architecture counts as yes, the service's own check being the backstop.
  bool _canRunHere(CloudServerType type) {
    final local = widget.localArchitecture;
    final family = cloudArchitectureFamily(type.architecture);
    return local.isEmpty || family.isEmpty || family == local;
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = widget.catalogue;
    _serverType ??= _defaultServerType;
    _location ??=
        catalogue.locations.isEmpty ? null : catalogue.locations.first.name;
    _image ??= _defaultImage;

    return ContentDialog(
      key: const ValueKey('test-cloud-deploy-dialog'),
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text('clouddeploy-text'.i18n()),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('clouddeployinfo-text'.i18n(),
                style: TextStyle(color: secondaryTextColor(context))),
            const SizedBox(height: 16),
            _field(
              'clouddeployinstance-text'.i18n(),
              ComboBox<String>(
                key: const ValueKey('test-cloud-instance-combo'),
                isExpanded: true,
                value: _instance,
                items: [
                  for (final instance in widget.instances)
                    ComboBoxItem(value: instance, child: Text(instance)),
                ],
                onChanged: (instance) {
                  if (instance == null) return;
                  setState(() {
                    _instance = instance;
                    _name.text = _suggestName(instance);
                  });
                },
              ),
            ),
            _field(
              'clouddeployservername-text'.i18n(),
              TextBox(
                key: const ValueKey('test-cloud-server-name'),
                controller: _name,
                maxLines: 1,
              ),
            ),
            _field(
              'clouddeploytype-text'.i18n(),
              ComboBox<String>(
                key: const ValueKey('test-cloud-type-combo'),
                isExpanded: true,
                value: _serverType,
                items: [
                  // A type of the other architecture is shown, so the user
                  // sees it is on offer, but cannot be chosen: nothing in
                  // the instance would run on it.
                  for (final type in catalogue.serverTypes)
                    ComboBoxItem(
                        value: type.name,
                        enabled: _canRunHere(type),
                        child: Text(type.label)),
                ],
                onChanged: (type) => setState(() => _serverType = type),
              ),
            ),
            _field(
              'clouddeploylocation-text'.i18n(),
              ComboBox<String>(
                key: const ValueKey('test-cloud-location-combo'),
                isExpanded: true,
                value: _location,
                items: [
                  for (final location in catalogue.locations)
                    ComboBoxItem(
                        value: location.name, child: Text(location.label)),
                ],
                onChanged: (location) => setState(() => _location = location),
              ),
            ),
            _field(
              'clouddeployimage-text'.i18n(),
              ComboBox<String>(
                key: const ValueKey('test-cloud-image-combo'),
                isExpanded: true,
                value: _image,
                items: [
                  for (final image in catalogue.images)
                    ComboBoxItem(value: image.id, child: Text(image.label)),
                ],
                onChanged: (image) => setState(() => _image = image),
              ),
            ),
            if (_validation != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(_validation!,
                    style: TextStyle(color: destructiveColor(context))),
              ),
            const SizedBox(height: 8),
            Text('clouddeploywarning-text'.i18n(),
                style: TextStyle(
                    color: secondaryTextColor(context), fontSize: 12)),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('test-cloud-deploy-submit'),
          onPressed: _submit,
          child: Text('clouddeploystart-text'.i18n()),
        ),
        Button(
          child: Text('cancel-text'.i18n()),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (!cloudNamePattern.hasMatch(name)) {
      setState(() => _validation = 'cloudinvalidname-text'.i18n());
      return;
    }
    final serverType = _serverType;
    final location = _location;
    final image = _image;
    if (serverType == null || location == null || image == null) {
      setState(() => _validation = 'clouddeployincomplete-text'.i18n());
      return;
    }
    final architecture = widget.catalogue.serverTypes
        .firstWhere((type) => type.name == serverType,
            orElse: () => const CloudServerType(id: '', name: ''))
        .architecture;
    Navigator.pop(context);
    widget.onDeploy(DeployRequest(
      instance: _instance,
      serverName: name,
      serverType: serverType,
      serverArchitecture: architecture,
      image: image,
      location: location,
    ));
  }

  Widget _field(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 4),
            child,
          ],
        ),
      );
}

/// The user-facing name of a deploy stage. Public so the tests and the
/// screen agree on one mapping rather than two.
String cloudStageLabel(DeployStage stage) =>
    'cloudstage-${stage.name.toLowerCase()}-text'.i18n();
