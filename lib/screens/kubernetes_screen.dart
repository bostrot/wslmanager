import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_models.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_service.dart';
import 'package:wsl2distromanager/components/empty_state.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/base_dialog.dart';

/// What one load of the screen produced. Held as state rather than driven by
/// a FutureBuilder: the cluster and namespace pickers have to stay on screen
/// and keep their values while the next load runs, and a FutureBuilder has
/// nothing to draw them from between futures.
class KubeView {
  /// Whether `kubectl` answered at all.
  final bool installed;

  /// Contexts in the kubeconfig. Empty means there is nothing to connect to.
  final List<KubeContext> contexts;

  /// Namespaces of [contextName], never empty once a context is selected.
  final List<String> namespaces;

  /// The selected context, empty when [contexts] is.
  final String contextName;

  /// The selected namespace, or [kubeAllNamespaces].
  final String namespace;

  final List<KubeWorkload> workloads;

  /// Why the workload list is empty, when the cluster refused to produce one.
  ///
  /// Carried on the view rather than replacing it, so a cluster that will not
  /// answer still leaves the pickers on screen: "Unauthorized" on the
  /// production cluster must not trap the user on an error page with no way
  /// back to the one that works.
  final Object? workloadError;

  const KubeView({
    required this.installed,
    this.contexts = const [],
    this.namespaces = const [],
    this.contextName = '',
    this.namespace = '',
    this.workloads = const [],
    this.workloadError,
  });
}

/// The Kubernetes screen — the clusters in the user's kubeconfig, one
/// namespace at a time.
///
/// Written for the case in bostrot/ai-tasks#61: a developer with ten clusters
/// of a hundred apps each. Three things follow from that and shape the whole
/// screen.
///
///  * It is its own destination, not more rows on the instance list. A
///    workload lives in someone else's cluster, and "delete" there means
///    something entirely different from unregistering a distro.
///  * Nothing is listed that was not asked for: one context, one namespace,
///    and a name filter above the list. A pod list is fetched when a workload
///    row is opened, never for the whole namespace.
///  * Health is a colour before it is a number. With a hundred rows the
///    question is "what is broken", and reading `2/3` a hundred times is not
///    an answer.
class KubernetesPage extends StatefulWidget {
  const KubernetesPage({super.key, this.service});

  /// Injected by tests; production builds one per page.
  final KubeService? service;

  @override
  State<KubernetesPage> createState() => _KubernetesPageState();
}

class _KubernetesPageState extends State<KubernetesPage> {
  late final KubeService _service = widget.service ?? KubeService();

  KubeView? _view;
  Object? _error;
  bool _loading = true;

  /// Bumped on every load; a response from an older one is dropped. Switching
  /// clusters twice quickly otherwise repaints with the first cluster's
  /// workloads under the second cluster's name.
  int _token = 0;

  String? _selectedContext;
  String? _selectedNamespace;
  String _query = '';

  /// Contexts and namespaces come out of files and cheap API calls, but not
  /// on every picker change: the kubeconfig only changes when the user edits
  /// it, and Refresh is what re-reads it.
  List<KubeContext>? _contexts;
  final Map<String, List<String>> _namespaceCache = {};

  /// Workloads with an action in flight, so a second click cannot queue a
  /// second rollout behind the first.
  final Set<String> _busy = {};

  /// Pods per workload, fetched when its row is first opened.
  final Map<String, Future<List<KubePod>>> _pods = {};

  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _key(KubeWorkload workload) =>
      '${workload.namespace}/${workload.kind.plural}/${workload.name}';

  Future<KubeView> _load() async {
    if (!await _service.isInstalled()) {
      return const KubeView(installed: false);
    }
    final contexts = _contexts ??= await _service.contexts();
    if (contexts.isEmpty) return const KubeView(installed: true);

    final context = contexts.firstWhere(
      (candidate) => candidate.name == _selectedContext,
      orElse: () => contexts.firstWhere((candidate) => candidate.isCurrent,
          orElse: () => contexts.first),
    );
    final namespaces =
        _namespaceCache[context.name] ??= await _service.namespaces(context);

    // A namespace picked in another cluster usually does not exist in this
    // one, so the selection falls back to the context's own default rather
    // than asking the API server for a namespace that is not there.
    var namespace = _selectedNamespace ?? context.defaultNamespace;
    if (namespace != kubeAllNamespaces && !namespaces.contains(namespace)) {
      namespace = namespaces.contains(context.defaultNamespace)
          ? context.defaultNamespace
          : namespaces.first;
    }

    var workloads = <KubeWorkload>[];
    Object? workloadError;
    try {
      workloads = await _service.workloads(
          contextName: context.name, namespace: namespace);
      // Broken first, then by name: with a hundred rows the ones that need
      // attention have to be at the top rather than wherever the alphabet put
      // them.
      workloads.sort((a, b) {
        final byHealth =
            a.health.attentionRank.compareTo(b.health.attentionRank);
        if (byHealth != 0) return byHealth;
        return a.name.compareTo(b.name);
      });
    } on KubeException catch (e) {
      workloadError = e;
    }

    return KubeView(
      installed: true,
      contexts: contexts,
      namespaces: namespaces,
      contextName: context.name,
      namespace: namespace,
      workloads: workloads,
      workloadError: workloadError,
    );
  }

  Future<void> _reload({bool rescan = false}) async {
    if (rescan) {
      _service.invalidateInstallCache();
      _contexts = null;
      _namespaceCache.clear();
    }
    final token = ++_token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final view = await _load();
      if (!mounted || token != _token) return;
      setState(() {
        _view = view;
        _selectedContext = view.contextName.isEmpty ? null : view.contextName;
        _selectedNamespace = view.namespace.isEmpty ? null : view.namespace;
        _refreshOpenPods(view);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Re-fetch the pods of the rows that are already open, and forget the
  /// rest.
  ///
  /// Dropping them all instead would leave an open row permanently blank
  /// after a restart — the Expander stays expanded, so nothing fires
  /// `onStateChanged` a second time and nothing would ask for pods again.
  /// Which is exactly the moment the user most wants to watch them come back.
  void _refreshOpenPods(KubeView view) {
    if (_pods.isEmpty) return;
    final open = _pods.keys.toSet();
    _pods.clear();
    for (final workload in view.workloads) {
      final key = _key(workload);
      if (!open.contains(key)) continue;
      _pods[key] =
          _service.pods(contextName: view.contextName, workload: workload);
    }
  }

  /// Run one cluster action and reload. The cluster's own message is what
  /// lands in the status bar — "exceeded quota" and "Forbidden" call for very
  /// different next steps, and a generic failure covers up both.
  Future<void> _act(
    KubeWorkload workload,
    Future<void> Function() action,
    String okMessage,
  ) async {
    final key = _key(workload);
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
        await _reload();
      }
    }
  }

  /// [host] is this page's own context: `dialog()` and `showDialog` default
  /// to the *home* screen's key, which is not mounted while this screen is
  /// the body (audit ST-04).
  Future<void> _showText(
      BuildContext host, String title, String text, String emptyText) async {
    await showDialog(
      context: host,
      builder: (context) => ContentDialog(
        key: const ValueKey('test-kube-text-dialog'),
        constraints: const BoxConstraints(maxWidth: 820),
        title: Text(title),
        content: SizedBox(
          height: 380,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? emptyText : text,
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

  /// [namespace] is the *pod's* own, not the picker's: with "All namespaces"
  /// selected the picker has no single value, and the pods on screen come
  /// from many.
  Future<void> _showPodLogs(
      BuildContext host, KubePod pod, String namespace) async {
    final view = _view;
    if (view == null) return;
    String text;
    try {
      text = await _service.podLogs(
        contextName: view.contextName,
        namespace: namespace,
        pod: pod.name,
      );
    } catch (e) {
      Notify.message('$e', severity: InfoBarSeverity.error);
      return;
    }
    if (!mounted || !host.mounted) return;
    await _showText(host, 'podlogs-text'.i18n([pod.name]), text,
        'nopodlogs-text'.i18n());
  }

  Future<void> _describe(BuildContext host, KubeWorkload workload) async {
    final view = _view;
    if (view == null) return;
    String text;
    try {
      text = await _service.describe(
          contextName: view.contextName, workload: workload);
    } catch (e) {
      Notify.message('$e', severity: InfoBarSeverity.error);
      return;
    }
    if (!mounted || !host.mounted) return;
    await _showText(host, 'describetitle-text'.i18n([workload.name]), text,
        'nodetails-text'.i18n());
  }

  void _askScale(BuildContext host, KubeWorkload workload) {
    final view = _view;
    if (view == null) return;
    dialog(
      hostContext: host,
      item: workload.name,
      title: 'scaletitle-text'.i18n([workload.name]),
      body: 'scalebody-text'.i18n(),
      placeholder: '${workload.desired}',
      submitText: 'scale-text'.i18n(),
      // Checked before the dialog pops, so a typo cannot reach the cluster as
      // a rejected request the user then has to go and read (audit CI-30).
      validateInput: (value) {
        final replicas = int.tryParse(value.trim());
        if (replicas == null || replicas < 0) return 'scaleinvalid-text'.i18n();
        return null;
      },
      onSubmit: (value) async {
        final replicas = int.parse(value.trim());
        await _act(
          workload,
          () => _service.scale(
              contextName: view.contextName,
              workload: workload,
              replicas: replicas),
          'scaledworkload-text'.i18n([workload.name, '$replicas']),
        );
      },
    );
  }

  void _confirmRestartPod(BuildContext host, KubePod pod, String namespace) {
    final view = _view;
    if (view == null) return;
    dialog(
      hostContext: host,
      item: pod.name,
      title: 'restartpodquestion-text'.i18n([pod.name]),
      body: 'restartpodbody-text'.i18n(),
      submitText: 'restart-text'.i18n(),
      submitInput: false,
      onSubmit: (_) async {
        try {
          await _service.deletePod(
              contextName: view.contextName,
              namespace: namespace,
              pod: pod.name);
          Notify.message('restartedpod-text'.i18n([pod.name]));
        } catch (e) {
          Notify.message('$e', severity: InfoBarSeverity.error);
        }
        if (mounted) await _reload();
      },
    );
  }

  List<KubeWorkload> _filtered(List<KubeWorkload> workloads) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return workloads;
    return workloads
        .where((workload) =>
            workload.name.toLowerCase().contains(query) ||
            workload.namespace.toLowerCase().contains(query) ||
            workload.images.any((image) => image.toLowerCase().contains(query)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context),
          if (view != null && view.contexts.isNotEmpty) ...[
            _pickers(context, view),
            const SizedBox(height: 10),
            if (view.workloadError == null) ...[
              _summary(context, view),
              const SizedBox(height: 6),
            ],
          ],
          Expanded(child: _body(context, view)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 4.0),
                child: Text('kubernetes-text'.i18n(),
                    style: FluentTheme.of(context).typography.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
                child: Text('kubernetesinfo-text'.i18n(),
                    style: TextStyle(
                        color: secondaryTextColor(context), fontSize: 12)),
              ),
            ],
          ),
        ),
        Button(
          key: const ValueKey('test-kubernetes-refresh'),
          onPressed: _loading ? null : () => _reload(rescan: true),
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

  /// Cluster, namespace and a name filter on one line — the three controls
  /// that stand between ten clusters of a hundred apps and the handful of
  /// rows the user came for.
  Widget _pickers(BuildContext context, KubeView view) {
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        InfoLabel(
          label: 'cluster-text'.i18n(),
          child: ComboBox<String>(
            key: const ValueKey('test-kubernetes-context'),
            value: view.contextName,
            items: [
              for (final context in view.contexts)
                ComboBoxItem(
                  value: context.name,
                  child: Tooltip(
                    message: context.name,
                    child: Text(context.label),
                  ),
                ),
            ],
            onChanged: _loading
                ? null
                : (value) {
                    if (value == null || value == view.contextName) return;
                    _selectedContext = value;
                    // The namespace belongs to the old cluster; _load picks
                    // the new context's default.
                    _selectedNamespace = null;
                    _reload();
                  },
          ),
        ),
        InfoLabel(
          label: 'namespace-text'.i18n(),
          child: ComboBox<String>(
            key: const ValueKey('test-kubernetes-namespace'),
            value: view.namespace,
            items: [
              ComboBoxItem(
                value: kubeAllNamespaces,
                child: Text('allnamespaces-text'.i18n()),
              ),
              for (final namespace in view.namespaces)
                ComboBoxItem(value: namespace, child: Text(namespace)),
            ],
            onChanged: _loading
                ? null
                : (value) {
                    if (value == null || value == view.namespace) return;
                    _selectedNamespace = value;
                    _reload();
                  },
          ),
        ),
        InfoLabel(
          label: 'filterworkloads-text'.i18n(),
          child: SizedBox(
            width: 240,
            child: TextBox(
              key: const ValueKey('test-kubernetes-filter'),
              controller: _search,
              placeholder: 'filterworkloadsplaceholder-text'.i18n(),
              prefix: const Padding(
                padding: EdgeInsets.only(left: 8.0),
                child: Icon(FluentIcons.filter),
              ),
              // Filtering is local to the list already in memory, so it can
              // happen per keystroke without touching the cluster.
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
        ),
      ],
    );
  }

  /// One line of counts. The point of the screen in five numbers: how much is
  /// here, how much is fine, and how much is not.
  Widget _summary(BuildContext context, KubeView view) {
    final workloads = view.workloads;
    final healthy = workloads
        .where((workload) => workload.health == WorkloadHealth.healthy)
        .length;
    final attention = workloads
        .where((workload) =>
            workload.health == WorkloadHealth.degraded ||
            workload.health == WorkloadHealth.down)
        .length;
    return Padding(
      padding: const EdgeInsets.only(left: 4.0),
      child: Text(
        key: const ValueKey('test-kubernetes-summary'),
        'kubesummary-text'.i18n(
            ['${workloads.length}', '$healthy', '$attention']),
        style: TextStyle(color: secondaryTextColor(context), fontSize: 12),
      ),
    );
  }

  Widget _body(BuildContext context, KubeView? view) {
    final failure = _error ?? view?.workloadError;
    if (failure != null) {
      return EmptyState(
        key: const ValueKey('test-kubernetes-error'),
        icon: FluentIcons.error,
        title: 'kubeclusterfailed-text'.i18n(),
        body: '$failure',
      );
    }
    if (view == null) return const Center(child: ProgressRing());
    if (!view.installed) {
      return EmptyState(
        key: const ValueKey('test-kubernetes-no-kubectl'),
        icon: FluentIcons.blocked,
        title: 'nokubectl-text'.i18n(),
        body: 'nokubectlhint-text'.i18n(),
      );
    }
    if (view.contexts.isEmpty) {
      return EmptyState(
        key: const ValueKey('test-kubernetes-no-context'),
        icon: FluentIcons.cloud,
        title: 'nokubecontext-text'.i18n(),
        body: 'nokubecontexthint-text'.i18n(),
      );
    }
    final workloads = _filtered(view.workloads);
    if (workloads.isEmpty) {
      final filtering = _query.trim().isNotEmpty;
      return EmptyState(
        key: ValueKey(
            filtering ? 'test-kubernetes-nomatch' : 'test-kubernetes-empty'),
        icon: filtering ? FluentIcons.filter : FluentIcons.package,
        title: filtering
            ? 'noworkloadmatch-text'.i18n([_query.trim()])
            : 'noworkloads-text'.i18n(),
        body: filtering
            ? 'noworkloadmatchhint-text'.i18n()
            : 'noworkloadshint-text'.i18n(),
      );
    }
    return ListView.builder(
      key: const ValueKey('test-kubernetes-list'),
      itemCount: workloads.length,
      itemBuilder: (context, index) => _row(context, view, workloads[index]),
    );
  }

  /// The colour that answers "is this one broken" before any text is read.
  Color _healthColor(BuildContext context, WorkloadHealth health) {
    final brightness = FluentTheme.of(context).brightness;
    switch (health) {
      case WorkloadHealth.healthy:
        return Colors.green.defaultBrushFor(brightness);
      case WorkloadHealth.degraded:
        return Colors.orange.defaultBrushFor(brightness);
      case WorkloadHealth.down:
        return destructiveColor(context);
      case WorkloadHealth.scaledToZero:
        return disabledTextColor(context);
    }
  }

  /// A pod's dot, on the same scale as a workload's: a pod that gave up is
  /// red, one that is merely not ready yet is amber.
  WorkloadHealth _podHealth(KubePod pod) {
    if (pod.isRunning) return WorkloadHealth.healthy;
    if (pod.phase == 'Failed' || pod.phase == 'Unknown') {
      return WorkloadHealth.down;
    }
    return WorkloadHealth.degraded;
  }

  String _healthLabel(WorkloadHealth health) {
    switch (health) {
      case WorkloadHealth.healthy:
        return 'healthy-text'.i18n();
      case WorkloadHealth.degraded:
        return 'degraded-text'.i18n();
      case WorkloadHealth.down:
        return 'kubedown-text'.i18n();
      case WorkloadHealth.scaledToZero:
        return 'scaledtozero-text'.i18n();
    }
  }

  Widget _row(BuildContext context, KubeView view, KubeWorkload workload) {
    final key = _key(workload);
    final busy = _busy.contains(key);
    final age = formatKubeAge(workload.created);
    // Kind, image and age tell two same-named workloads apart; the namespace
    // is only worth a column when the list spans all of them.
    final caption = [
      workload.kind.label,
      if (view.namespace == kubeAllNamespaces && workload.namespace.isNotEmpty)
        workload.namespace,
      if (workload.images.isNotEmpty) workload.images.first,
      if (age.isNotEmpty) age,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Expander(
        // Namespace and kind are in the key so a row keeps its own expanded
        // state when the list is re-sorted, or when another cluster happens
        // to have a workload of the same name.
        key: ValueKey('test-workload-$key'),
        onStateChanged: (expanded) {
          if (expanded) _loadPods(view, workload);
        },
        header: Row(
          children: [
            // Decoration next to text that already says the same thing, so
            // the dot itself is excluded from semantics (audit IA-10).
            ExcludeSemantics(
              child: Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: _healthColor(context, workload.health),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${workload.name} '
                      '(${_healthLabel(workload.health)} '
                      '${workload.readiness})'),
                  Text(caption,
                      style: FluentTheme.of(context).typography.caption),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                Button(
                  key: ValueKey('test-workload-restart-${workload.name}'),
                  onPressed: busy
                      ? null
                      : () => _act(
                            workload,
                            () => _service.restart(
                                contextName: view.contextName,
                                workload: workload),
                            'restartedworkload-text'.i18n([workload.name]),
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
                if (workload.kind.scalable)
                  Button(
                    key: ValueKey('test-workload-scale-${workload.name}'),
                    onPressed:
                        busy ? null : () => _askScale(context, workload),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(FluentIcons.number_field),
                        const SizedBox(width: 10),
                        Text('scale-text'.i18n()),
                      ],
                    ),
                  ),
                Button(
                  key: ValueKey('test-workload-describe-${workload.name}'),
                  onPressed: busy ? null : () => _describe(context, workload),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(FluentIcons.text_document),
                      const SizedBox(width: 10),
                      Text('details-text'.i18n()),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _podList(context, view, workload),
          ],
        ),
      ),
    );
  }

  void _loadPods(KubeView view, KubeWorkload workload) {
    final key = _key(workload);
    if (_pods.containsKey(key)) return;
    setState(() {
      _pods[key] =
          _service.pods(contextName: view.contextName, workload: workload);
    });
  }

  Widget _podList(BuildContext context, KubeView view, KubeWorkload workload) {
    final future = _pods[_key(workload)];
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<List<KubePod>>(
      key: ValueKey('test-workload-pods-${workload.name}'),
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('${snapshot.error}',
              style: TextStyle(color: destructiveColor(context), fontSize: 12));
        }
        final pods = snapshot.data;
        if (pods == null) {
          return const Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(width: 20, height: 20, child: ProgressRing()),
          );
        }
        if (pods.isEmpty) {
          return Text('nopods-text'.i18n(),
              style: TextStyle(
                  color: secondaryTextColor(context), fontSize: 12));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final pod in pods) _podRow(context, workload, pod),
          ],
        );
      },
    );
  }

  Widget _podRow(BuildContext context, KubeWorkload workload, KubePod pod) {
    final age = formatKubeAge(pod.created);
    final detail = [
      pod.phase,
      pod.readiness,
      if (pod.restarts > 0) 'kuberestarts-text'.i18n(['${pod.restarts}']),
      if (pod.node.isNotEmpty) pod.node,
      if (age.isNotEmpty) age,
    ].where((part) => part.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: _healthColor(context, _podHealth(pod)),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pod.name, style: const TextStyle(fontSize: 13)),
                Text(detail,
                    style: FluentTheme.of(context).typography.caption),
              ],
            ),
          ),
          Button(
            key: ValueKey('test-pod-logs-${pod.name}'),
            onPressed: () => _showPodLogs(context, pod, workload.namespace),
            child: Text('logs-text'.i18n()),
          ),
          const SizedBox(width: 8),
          Button(
            key: ValueKey('test-pod-restart-${pod.name}'),
            onPressed: () =>
                _confirmRestartPod(context, pod, workload.namespace),
            child: Text('restart-text'.i18n()),
          ),
        ],
      ),
    );
  }
}
