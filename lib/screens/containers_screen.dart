import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/containers/container_models.dart';
import 'package:wsl2distromanager/api/containers/container_service.dart';
import 'package:wsl2distromanager/dialogs/create_container_dialog.dart';
import 'package:wsl2distromanager/components/empty_state.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';

/// Everything one load of the screen needs, so a single FutureBuilder covers
/// the three states that matter: no engine, an engine that will not answer,
/// and a list of containers.
class ContainerSnapshot {
  final List<ContainerEngine> engines;
  final List<ContainerInfo> containers;

  const ContainerSnapshot({required this.engines, required this.containers});
}

/// The Containers screen.
///
/// Deliberately its own destination rather than more rows on the Home list:
/// a container is not an instance, and the actions that look alike ("delete")
/// mean very different things on the two (bostrot/ai-tasks#57). What they do
/// share is this app's habit of never touching anything without saying so —
/// removing a container asks first, exactly like unregistering a distro.
class ContainersPage extends StatefulWidget {
  const ContainersPage({super.key, this.service});

  /// Injected by tests; production builds one per page.
  final ContainerService? service;

  @override
  State<ContainersPage> createState() => _ContainersPageState();
}

class _ContainersPageState extends State<ContainersPage> {
  late final ContainerService _service = widget.service ?? ContainerService();
  late Future<ContainerSnapshot> _snapshot;

  /// Containers with an action in flight, so their row's buttons stay
  /// disabled until the engine has answered. A second click on Stop while
  /// the first is still running makes the engine print an error about a
  /// container that is already stopping.
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _snapshot = _load();
  }

  Future<ContainerSnapshot> _load() async {
    final engines = await _service.availableEngines();
    if (engines.isEmpty) {
      return const ContainerSnapshot(engines: [], containers: []);
    }
    final containers = await _service.listAll();
    return ContainerSnapshot(engines: engines, containers: containers);
  }

  void _reload({bool rescanEngines = false}) {
    if (rescanEngines) _service.invalidateEngineCache();
    if (!mounted) return;
    setState(() {
      _snapshot = _load();
    });
  }

  /// Run one engine action and reload. Failures land in the status bar with
  /// the engine's own wording — "port is already allocated" is worth reading
  /// and a generic "action failed" is not.
  Future<void> _act(
    ContainerInfo container,
    Future<void> Function() action,
    String okMessage,
  ) async {
    final key = '${container.engine.executable}/${container.ref}';
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await action();
      Notify.message(okMessage);
    } catch (e) {
      Notify.message('$e', severity: InfoBarSeverity.error);
    } finally {
      if (mounted) {
        setState(() => _busy.remove(key));
        _reload();
      }
    }
  }

  /// [host] is this page's own context: `dialog()` and `showDialog` default
  /// to the *home* screen's key, which is not mounted while this screen is
  /// the body (audit ST-04).
  void _showLogs(BuildContext host, ContainerInfo container) async {
    String text;
    try {
      text = await _service.logs(container.engine, container.ref);
    } catch (e) {
      Notify.message('$e', severity: InfoBarSeverity.error);
      return;
    }
    if (!mounted || !host.mounted) return;
    showDialog(
      context: host,
      builder: (context) => ContentDialog(
        key: const ValueKey('test-container-logs-dialog'),
        constraints: const BoxConstraints(maxWidth: 720),
        title: Text('containerlogs-text'.i18n([container.ref])),
        content: SizedBox(
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? 'nologs-text'.i18n() : text,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
            ),
          ),
        ),
        actions: [
          Button(
            child: Text('close-text'.i18n()),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  void _confirmRemove(BuildContext host, ContainerInfo container) {
    dialog(
      hostContext: host,
      item: container.ref,
      title: 'deletecontainerquestion-text'.i18n([container.ref]),
      body: 'deletecontainerbody-text'.i18n(),
      submitText: 'delete-text'.i18n(),
      submitInput: false,
      submitStyle: ButtonStyle(
        backgroundColor: ButtonState.all(Colors.red),
        foregroundColor: ButtonState.all(Colors.white),
      ),
      onSubmit: (_) async {
        await _act(
          container,
          // A running container is only removed after the user asked for it
          // by name in this dialog; without the force flag the engine would
          // refuse and the answer would be an error nobody can act on.
          () => _service.remove(container.engine, container.ref,
              force: container.state.isRunning),
          'deletedcontainer-text'.i18n([container.ref]),
        );
      },
    );
  }

  /// Open the create form, carrying the engines this screen already probed so
  /// the dialog does not pay for a second probe.
  void _create(BuildContext host, ContainerSnapshot data) {
    showCreateContainerDialog(
      host,
      service: _service,
      engines: data.engines,
      active: _service.preferredEngine,
      onCreated: _reload,
    );
  }

  @override
  Widget build(BuildContext context) {
    // One builder over the whole screen, not just the list: the Create button
    // is only usable once an engine has been found, and that answer arrives
    // with the same snapshot the rows come from.
    return FutureBuilder<ContainerSnapshot>(
      key: const ValueKey('test-container-list'),
      future: _snapshot,
      builder: (context, snapshot) {
        final data = snapshot.hasError ? null : snapshot.data;
        return Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context, data),
              Expanded(child: _body(context, snapshot)),
            ],
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, ContainerSnapshot? data) {
    final canCreate = data != null && data.engines.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
                child: Text('containers-text'.i18n(),
                    style: FluentTheme.of(context).typography.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
                child: Text('containersinfo-text'.i18n(),
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 12)),
              ),
            ],
          ),
        ),
        FilledButton(
          key: const ValueKey('test-containers-create'),
          onPressed: canCreate ? () => _create(context, data) : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.add),
              const SizedBox(width: 8),
              Text('createcontainer-text'.i18n()),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Button(
          key: const ValueKey('test-containers-refresh'),
          onPressed: () => _reload(rescanEngines: true),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(FluentIcons.refresh),
              const SizedBox(width: 8),
              Text('refresh-text'.i18n()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, AsyncSnapshot<ContainerSnapshot> snapshot) {
    if (snapshot.hasError) {
      return EmptyState(
        key: const ValueKey('test-containers-error'),
        icon: FluentIcons.error,
        title: 'containerenginefailed-text'.i18n(),
        body: '${snapshot.error}',
      );
    }
    final data = snapshot.data;
    if (data == null) {
      return const Center(child: ProgressRing());
    }
    if (data.engines.isEmpty) {
      return EmptyState(
        key: const ValueKey('test-containers-no-engine'),
        icon: FluentIcons.blocked,
        title: 'nocontainerengine-text'.i18n(),
        body: 'nocontainerenginehint-text'.i18n(),
      );
    }
    if (data.containers.isEmpty) {
      return EmptyState(
        key: const ValueKey('test-containers-empty'),
        icon: FluentIcons.package,
        title: 'nocontainers-text'.i18n(),
        body: 'nocontainershint-text'.i18n(),
      );
    }
    return ListView.builder(
      itemCount: data.containers.length,
      itemBuilder: (context, index) => _row(context, data.containers[index]),
    );
  }

  Widget _row(BuildContext context, ContainerInfo container) {
    final busy = _busy.contains('${container.engine.executable}/${container.ref}');
    final running = container.state.isRunning;
    // Image, engine and ports say which of two same-named containers this is;
    // the state word is in the header where the eye already is.
    final caption = [
      container.image,
      container.engine.label,
      if (container.ports.isNotEmpty) container.ports,
    ].where((part) => part.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Expander(
        key: ValueKey('test-container-${container.engine.executable}-${container.ref}'),
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(running
                ? '${container.ref} (${'running-text'.i18n()})'
                : '${container.ref} (${'stopped-text'.i18n()})'),
            Text(caption, style: FluentTheme.of(context).typography.caption),
          ],
        ),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            Button(
              key: ValueKey('test-container-toggle-${container.ref}'),
              onPressed: busy
                  ? null
                  : () => _act(
                        container,
                        () => running
                            ? _service.stop(container.engine, container.ref)
                            : _service.start(container.engine, container.ref),
                        (running
                                ? 'stoppedcontainer-text'
                                : 'startedcontainer-text')
                            .i18n([container.ref]),
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
            Button(
              key: ValueKey('test-container-restart-${container.ref}'),
              onPressed: busy
                  ? null
                  : () => _act(
                        container,
                        () => _service.restart(container.engine, container.ref),
                        'restartedcontainer-text'.i18n([container.ref]),
                      ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.refresh),
                  const SizedBox(width: 10),
                  Text('restart-text'.i18n()),
                ],
              ),
            ),
            Button(
              key: ValueKey('test-container-logs-${container.ref}'),
              onPressed: busy ? null : () => _showLogs(context, container),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.text_document),
                  const SizedBox(width: 10),
                  Text('logs-text'.i18n()),
                ],
              ),
            ),
            Button(
              key: ValueKey('test-container-delete-${container.ref}'),
              style: ButtonStyle(
                foregroundColor: ButtonState.all(destructiveColor(context)),
              ),
              onPressed: busy ? null : () => _confirmRemove(context, container),
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
}
