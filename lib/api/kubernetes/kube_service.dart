// Talking to Kubernetes clusters through the `kubectl` the user already has.
//
// The decision behind this file (bostrot/ai-tasks#61) is the containers one
// again: the app is a *front end*, not a client library. It shells out to
// `kubectl` with the user's own kubeconfig instead of speaking the API server
// protocol itself, which means every auth plugin that already works in their
// terminal — EKS, GKE, OIDC, a corporate exec credential helper — works here
// on the first try, on Windows and macOS alike, and nothing in this app has
// to be kept in step with the Kubernetes API.
//
// Two rules the rest of the file follows:
//
//  * **Never mutate the user's kubeconfig.** Switching clusters is a
//    `--context` flag on each command, never `kubectl config use-context`.
//    The app is one of several things looking at that file, and a tool that
//    silently repoints the terminal in the next tab is a tool nobody trusts.
//  * **Never fetch the whole cluster.** Ten clusters of a hundred apps is the
//    case this was written for: the list is one namespace of one context, and
//    a workload's pods are read only when its row is opened.

import 'dart:async';
import 'dart:convert';

import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/execution/models.dart';
import 'package:wsl2distromanager/api/kubernetes/kube_models.dart';
import 'package:wsl2distromanager/api/remote_target.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Preference key holding an explicit kubeconfig path. Absent means "let
/// kubectl find it", which is `KUBECONFIG` or `~/.kube/config`.
const String kubeConfigPathPrefKey = 'KubeConfigPath';

/// Namespace value standing for `--all-namespaces`. Not a legal namespace
/// name, so it can never collide with a real one.
const String kubeAllNamespaces = '*';

/// Namespace value standing for "pass no namespace flag at all", which is
/// what a cluster-scoped read (`get nodes`) needs: neither `--namespace` nor
/// `--all-namespaces` is legal there. The empty string is not a legal
/// namespace either, so this collides with nothing.
const String kubeNoNamespace = '';

/// Object names, namespaces and container names, as Kubernetes itself
/// defines them (RFC 1123). Because it cannot start with `-`, a crafted name
/// also cannot arrive as another flag on the command line.
final RegExp _namePattern = RegExp(r'^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$');

/// Resource kinds the way `kubectl get` takes them: `pods`, `svc`,
/// `deployments.apps`, `ingresses.networking.k8s.io`. Letters, digits, dots
/// and dashes only, never leading with a dash, so a kind read off a tool
/// argument cannot arrive as another flag.
final RegExp _kindPattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9.\-]{0,252}$');

/// Label selectors (`app=web,tier=front`, `app!=web`). One whitespace-free
/// token that cannot lead with a dash: every selector kubectl takes on a
/// command line already looks like this, and the spaces an `env in (a, b)`
/// form would need are exactly the part worth refusing.
final RegExp _selectorPattern = RegExp(r'^[^\s\-][^\s]*$');

/// Durations the way kubectl's `--since` writes them: `30s`, `15m`, `2h`.
final RegExp _durationPattern = RegExp(r'^[0-9]{1,6}[smh]$');

/// Output formats a generic read may ask for. An allowlist rather than a
/// pattern because `--output` also takes `jsonpath=…` and `go-template=…`,
/// which are a scripting language reached through a flag — far more surface
/// than "show me the object" needs.
const Set<String> kubeOutputFormats = {'wide', 'json', 'yaml', 'name'};

/// Context names are far looser than object names — a real EKS context is
/// `arn:aws:eks:eu-central-1:1234:cluster/prod` and a GKE one is
/// `gke_project_zone_cluster` — so this only enforces what safety needs: a
/// non-empty single line that cannot be read as a flag.
final RegExp _contextPattern = RegExp(r'^[^\s\-][^\s]*$');

/// Drives `kubectl` on the host.
class KubeService {
  /// Every command goes through the broker rather than `Process.run`, for the
  /// same reason the container service does: a `kubectl` pointed at an
  /// unreachable API server hangs for its own timeout, and a plain `run`
  /// would leave that child behind when this side stops waiting.
  final ExecutionBroker _broker;

  /// How long any single `kubectl` may take. Higher than the container
  /// default: these commands cross a network to an API server that may be on
  /// another continent.
  final Duration timeout;

  KubeService({
    Shell? shell,
    ExecutionBroker? broker,
    this.timeout = const Duration(seconds: 45),
  }) : _broker = broker ?? ExecutionBroker(shell: shell ?? ProcessShell());

  /// Whether `kubectl` answered `version --client`, cached for the life of
  /// the service — installing kubectl while the app is open is what
  /// [invalidateInstallCache] is for.
  bool? _installed;

  /// Same remote rule as the rest of the app: with a remote Windows host
  /// configured, the kubectl that matters is the one over there.
  bool get _useRemote {
    try {
      final enabled = prefs.getBool('UseRemoteWSL') ?? false;
      final target = prefs.getString('RemoteWSLTarget')?.trim() ?? '';
      return enabled && isValidRemoteTarget(target);
    } catch (_) {
      // Preferences not initialised (tests, early startup) — stay local.
      return false;
    }
  }

  String get _remoteTarget {
    try {
      return prefs.getString('RemoteWSLTarget')?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// The kubeconfig the user pinned in settings, or empty for kubectl's own
  /// lookup (`KUBECONFIG`, then `~/.kube/config`).
  String get kubeConfigPath {
    try {
      return prefs.getString(kubeConfigPathPrefKey)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Pin [path] as the kubeconfig, or clear the pin with an empty string.
  Future<void> setKubeConfigPath(String path) async {
    final value = path.trim();
    if (value.isEmpty) {
      await prefs.remove(kubeConfigPathPrefKey);
    } else {
      await prefs.setString(kubeConfigPathPrefKey, value);
    }
    invalidateInstallCache();
  }

  /// Forget the probe result, so the next call looks for kubectl again.
  void invalidateInstallCache() => _installed = null;

  /// Whether `kubectl` is on the host's PATH.
  ///
  /// The client version is asked for rather than the full one: `kubectl
  /// version` without `--client` also contacts the API server, so a perfectly
  /// installed kubectl with an unreachable cluster would read as "not
  /// installed" and send the user off to install something they have.
  Future<bool> isInstalled() async {
    final cached = _installed;
    if (cached != null) return cached;
    final result = await _run(['version', '--client', '--output=json']);
    return _installed = result.exitCode == 0;
  }

  /// Every context in the kubeconfig, current one flagged.
  ///
  /// `config view` reads the file only — no cluster is contacted, so this
  /// stays fast with ten clusters, and it is the one call that still answers
  /// when every cluster is unreachable. kubectl redacts credentials in this
  /// output by default and nothing here asks it not to.
  Future<List<KubeContext>> contexts() async {
    final result = await _run(['config', 'view', '--output=json']);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'config view'));
    }
    return parseContexts(result.stdout);
  }

  /// Namespaces of [context], or the context's own default when the cluster
  /// will not list them.
  ///
  /// A developer account is very often allowed to work inside its namespace
  /// and not to enumerate the cluster's, and that `Forbidden` must not empty
  /// the screen — the namespace they can actually use is the one that
  /// matters. Any other failure (unreachable, expired credentials) surfaces
  /// through the workload call right after, with kubectl's own wording.
  Future<List<String>> namespaces(KubeContext context) async {
    final result =
        await _run([..._contextArgs(context.name), 'get', 'namespaces',
            '--output=json']);
    if (result.exitCode != 0) return [context.defaultNamespace];
    final names = parseNames(result.stdout);
    if (names.isEmpty) return [context.defaultNamespace];
    return names;
  }

  /// Deployments, StatefulSets and DaemonSets of one namespace — or of every
  /// namespace when [namespace] is [kubeAllNamespaces].
  ///
  /// One `get` for the three kinds rather than three: it is one round trip
  /// and one error to report instead of three that can disagree.
  Future<List<KubeWorkload>> workloads({
    required String contextName,
    required String namespace,
  }) async {
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(namespace),
      'get',
      WorkloadKind.values.map((kind) => kind.plural).join(','),
      '--output=json',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'get workloads'));
    }
    return parseWorkloads(result.stdout);
  }

  /// The pods belonging to [workload]. Fetched per row, when the row is
  /// opened — a namespace of a hundred apps has thousands of pods and none of
  /// them belong on a list the user is scrolling past.
  ///
  /// A workload the API server returned without a selector gets an empty
  /// list rather than an unfiltered `get pods`: in a namespace of a hundred
  /// apps that would put every other team's pods under this one's row.
  Future<List<KubePod>> pods({
    required String contextName,
    required KubeWorkload workload,
  }) async {
    final selector = workload.selectorArgument;
    if (selector.isEmpty) return const [];
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(workload.namespace),
      'get',
      'pods',
      '--selector=$selector',
      '--output=json',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'get pods'));
    }
    return parsePods(result.stdout);
  }

  /// The last [lines] of a pod's log.
  ///
  /// [container] empty means `--all-containers`, rather than a container
  /// picker: a pod with a sidecar otherwise answers "a container name must be
  /// specified", which is an error about the tool rather than about the app
  /// being debugged. Naming one is still worth having when the sidecar is the
  /// noisy half.
  ///
  /// [previous] reads the log of the *last terminated* container, which is
  /// the only place the reason for a CrashLoopBackOff is written — the
  /// running container is a fresh one that has not failed yet.
  ///
  /// [since] bounds the window (`5m`, `2h`) so "what happened since the
  /// deploy" does not mean reading a day of log.
  Future<String> podLogs({
    required String contextName,
    required String namespace,
    required String pod,
    int lines = 300,
    String container = '',
    bool previous = false,
    String since = '',
    bool timestamps = false,
  }) async {
    _checkName(pod, 'pod');
    if (lines <= 0) {
      throw ArgumentError.value(lines, 'lines', 'must be greater than zero');
    }
    if (container.isNotEmpty) _checkName(container, 'container');
    if (since.isNotEmpty && !_durationPattern.hasMatch(since)) {
      throw ArgumentError.value(
          since, 'since', 'must be a duration like 30s, 15m or 2h');
    }
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(namespace),
      'logs',
      pod,
      if (container.isEmpty)
        '--all-containers=true'
      else
        '--container=$container',
      if (previous) '--previous=true',
      if (since.isNotEmpty) '--since=$since',
      if (timestamps) '--timestamps=true',
      '--tail=$lines',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'logs $pod'));
    }
    // A container that only ever writes diagnostics writes them to kubectl's
    // stderr; dropping that would show an empty log for a crashing pod.
    return [result.stdout.trimRight(), result.stderr.trimRight()]
        .where((part) => part.isNotEmpty)
        .join('\n');
  }

  /// Roll the workload's pods, the way `kubectl rollout restart` does:
  /// replacements are started before the old pods go, so this is the safe
  /// "turn it off and on again" for a running app.
  Future<String> restart({
    required String contextName,
    required KubeWorkload workload,
  }) async {
    _checkName(workload.name, 'workload');
    final result = await _run([
      ..._contextArgs(contextName),
      ..._namespaceArgs(workload.namespace),
      'rollout',
      'restart',
      workload.kind.ref(workload.name),
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'rollout restart'));
    }
    return result.stdout.trim();
  }

  /// Set the workload's replica count.
  Future<String> scale({
    required String contextName,
    required KubeWorkload workload,
    required int replicas,
  }) async {
    _checkName(workload.name, 'workload');
    if (!workload.kind.scalable) {
      throw ArgumentError.value(workload.kind.label, 'kind', 'cannot be scaled');
    }
    if (replicas < 0) {
      throw ArgumentError.value(replicas, 'replicas', 'must not be negative');
    }
    final result = await _run([
      ..._contextArgs(contextName),
      ..._namespaceArgs(workload.namespace),
      'scale',
      workload.kind.ref(workload.name),
      '--replicas=$replicas',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'scale'));
    }
    return result.stdout.trim();
  }

  /// Delete one pod. Its controller starts a replacement immediately, which
  /// is why this is offered as the per-pod restart rather than as a delete.
  Future<String> deletePod({
    required String contextName,
    required String namespace,
    required String pod,
  }) async {
    _checkName(pod, 'pod');
    final result = await _run([
      ..._contextArgs(contextName),
      ..._namespaceArgs(namespace),
      'delete',
      'pod',
      pod,
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'delete pod $pod'));
    }
    return result.stdout.trim();
  }

  /// `kubectl describe` for a workload — the events at the bottom are where
  /// the reason for a failing rollout actually is.
  Future<String> describe({
    required String contextName,
    required KubeWorkload workload,
  }) async {
    _checkName(workload.name, 'workload');
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(workload.namespace),
      'describe',
      workload.kind.ref(workload.name),
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'describe'));
    }
    return result.stdout.trimRight();
  }

  // ---------------------------------------------------------------------
  // Read-only cluster inspection (bostrot/ai-tasks#67).
  //
  // The screen only ever needed workloads, their pods and their logs. An
  // agent debugging a cluster needs the rest of what someone would type at a
  // terminal — events, Services, Ingresses, ConfigMap *names*, node
  // pressure — and needs it without ever being able to change anything. So
  // the verb is hardcoded in every method below (`get`, `describe`, `top`)
  // and only the noun comes from the caller: there is no argument shape here
  // that reaches `apply`, `delete` or `edit`.
  // ---------------------------------------------------------------------

  /// Pods of one namespace, optionally narrowed by a label [selector].
  ///
  /// Unlike [pods] this is not tied to a workload: "what is not Running in
  /// this namespace" is the first question asked about a cluster, and it has
  /// no workload to hang off yet.
  Future<List<KubePod>> podsInNamespace({
    required String contextName,
    required String namespace,
    String selector = '',
  }) async {
    if (selector.isNotEmpty && !_selectorPattern.hasMatch(selector)) {
      throw ArgumentError.value(selector, 'selector', 'not a label selector');
    }
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(namespace),
      'get',
      'pods',
      if (selector.isNotEmpty) '--selector=$selector',
      '--output=json',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'get pods'));
    }
    return parsePods(result.stdout);
  }

  /// `kubectl get <kind>` for any resource, rendered in [output] format.
  ///
  /// The generic reader: Services, Ingresses, PVCs, CRDs and everything else
  /// this app will never grow a screen for. [namespace] takes
  /// [kubeAllNamespaces] for a whole-cluster read and [kubeNoNamespace] for a
  /// cluster-scoped kind such as `nodes`, which rejects both namespace flags.
  Future<String> getResource({
    required String contextName,
    required String namespace,
    required String kind,
    String name = '',
    String selector = '',
    String output = 'wide',
  }) async {
    _checkKind(kind);
    if (name.isNotEmpty) _checkName(name, 'name');
    if (selector.isNotEmpty && !_selectorPattern.hasMatch(selector)) {
      throw ArgumentError.value(selector, 'selector', 'not a label selector');
    }
    if (!kubeOutputFormats.contains(output)) {
      throw ArgumentError.value(output, 'output',
          'must be one of ${kubeOutputFormats.join(", ")}');
    }
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(namespace),
      'get',
      kind,
      if (name.isNotEmpty) name,
      if (selector.isNotEmpty) '--selector=$selector',
      '--output=$output',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'get $kind'));
    }
    return result.stdout.trimRight();
  }

  /// `kubectl describe <kind>/<name>` for any resource.
  ///
  /// [describe] does this for a [KubeWorkload]; this is the same thing for a
  /// pod, a node or a Service, where the Events section at the bottom is
  /// usually the whole answer ("0/3 nodes are available: insufficient cpu").
  Future<String> describeResource({
    required String contextName,
    required String namespace,
    required String kind,
    required String name,
  }) async {
    _checkKind(kind);
    _checkName(name, 'name');
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(namespace),
      'describe',
      kind,
      name,
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'describe $kind/$name'));
    }
    return result.stdout.trimRight();
  }

  /// Recent events of a namespace, oldest first the way `kubectl get events`
  /// sorts them, so the tail is what just happened.
  ///
  /// [warningsOnly] drops the Normal ones — a busy namespace prints a Normal
  /// event for every pull, start and scale, and the Warnings are the reason
  /// anyone opened this.
  Future<String> events({
    required String contextName,
    required String namespace,
    bool warningsOnly = false,
  }) async {
    final result = await _run([
      ..._contextArgs(contextName),
      ..._readNamespaceArgs(namespace),
      'get',
      'events',
      '--sort-by=.lastTimestamp',
      if (warningsOnly) '--field-selector=type=Warning',
      '--output=wide',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(_failureText(result, 'get events'));
    }
    return result.stdout.trimRight();
  }

  /// CPU and memory actually being used, from `kubectl top`.
  ///
  /// Needs metrics-server in the cluster, which plenty of clusters do not
  /// run — that failure comes back with kubectl's own wording rather than
  /// being papered over, because "install metrics-server" is the answer and
  /// nothing this app does can substitute for it.
  Future<String> top({
    required String contextName,
    required String namespace,
    bool nodes = false,
    String selector = '',
  }) async {
    if (selector.isNotEmpty && !_selectorPattern.hasMatch(selector)) {
      throw ArgumentError.value(selector, 'selector', 'not a label selector');
    }
    final result = await _run([
      ..._contextArgs(contextName),
      // `top nodes` is cluster-scoped and rejects a namespace flag.
      if (!nodes) ..._readNamespaceArgs(namespace),
      'top',
      nodes ? 'nodes' : 'pods',
      if (!nodes && selector.isNotEmpty) '--selector=$selector',
    ]);
    if (result.exitCode != 0) {
      throw KubeException(
          _failureText(result, 'top ${nodes ? "nodes" : "pods"}'));
    }
    return result.stdout.trimRight();
  }

  void _checkKind(String value) {
    if (!_kindPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'kind', 'not a valid resource kind');
    }
  }

  List<String> _contextArgs(String contextName) {
    _checkContext(contextName);
    return ['--context=$contextName'];
  }

  List<String> _namespaceArgs(String namespace) {
    if (namespace == kubeAllNamespaces) return ['--all-namespaces'];
    _checkName(namespace, 'namespace');
    return ['--namespace=$namespace'];
  }

  /// [_namespaceArgs] plus the [kubeNoNamespace] case, for the reads alone.
  ///
  /// Deliberately not folded into [_namespaceArgs]: the three mutating
  /// methods ([restart], [scale], [deletePod]) keep that one, and there an
  /// empty namespace has to stay the error it has always been. A workload
  /// whose object came back without `metadata.namespace` would otherwise
  /// fall through to the context's own namespace and delete a same-named pod
  /// in the wrong one — silently, which is the worst way for it to happen.
  /// A read landing in the wrong namespace shows the user the wrong list;
  /// a delete landing there is not recoverable.
  List<String> _readNamespaceArgs(String namespace) {
    // A cluster-scoped read takes neither flag, and leaving both off is also
    // what makes kubectl fall back to the context's own namespace.
    if (namespace == kubeNoNamespace) return const [];
    return _namespaceArgs(namespace);
  }

  void _checkName(String value, String what) {
    if (!_namePattern.hasMatch(value)) {
      throw ArgumentError.value(value, what, 'not a valid Kubernetes name');
    }
  }

  void _checkContext(String value) {
    if (!_contextPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'context', 'not a valid context name');
    }
  }

  /// Run one kubectl command, locally or over SSH.
  ///
  /// Ordinary failures come back as a non-zero result rather than an
  /// exception — "kubectl is not installed" is the answer [isInstalled] is
  /// asking for. A timeout is the exception: there is no exit code to read,
  /// and "no workloads" would be the wrong thing to show for a cluster that
  /// never answered.
  Future<ExecutionResult> _run(List<String> arguments) async {
    // The kubeconfig flag goes first so it applies to every subcommand, and
    // is left off entirely when unset so kubectl keeps its own lookup order.
    final path = kubeConfigPath;
    final full = [
      if (path.isNotEmpty) '--kubeconfig=$path',
      ...arguments,
    ];
    final remote = _useRemote;
    final result = await _broker.run(ExecutionRequest(
      command: remote ? 'ssh' : 'kubectl',
      arguments:
          remote ? sshRemoteCommand(_remoteTarget, 'kubectl', full) : full,
      timeout: timeout,
      runInShell: false,
    ));
    if (result.error is TimeoutException) {
      throw KubeException(
          'kubectl did not answer within ${timeout.inSeconds}s: '
          'kubectl ${arguments.join(' ')}');
    }
    return result;
  }

  String _failureText(ExecutionResult result, String what) {
    final detail = result.stderr.trim().isNotEmpty
        ? result.stderr.trim()
        : result.stdout.trim();
    final suffix = detail.isEmpty ? '' : '\n$detail';
    return 'kubectl failed to run "$what" (exit ${result.exitCode}).$suffix';
  }

  static const String _noKubectlMessage =
      'kubectl was not found. Install it and make sure its command is on your '
      'PATH, then refresh.';

  /// Message shown when the host has no kubectl. Public so the screen and any
  /// other caller say the same thing.
  static String get noKubectlMessage => _noKubectlMessage;

  /// Contexts out of `kubectl config view -o json`.
  ///
  /// Static and public because parsing is the part worth testing on its own.
  /// Malformed output yields an empty list rather than throwing: a kubeconfig
  /// with no contexts and one this app cannot read both mean "there is
  /// nothing to connect to", which the screen already explains.
  static List<KubeContext> parseContexts(String output) {
    final root = _decodeObject(output);
    if (root == null) return [];
    final current = root['current-context'];
    final entries = root['contexts'];
    if (entries is! List) return [];
    final contexts = <KubeContext>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final name = entry['name'];
      if (name is! String || name.isEmpty) continue;
      final detail = entry['context'];
      contexts.add(KubeContext(
        name: name,
        cluster: detail is Map ? _string(detail['cluster']) : '',
        namespace: detail is Map ? _string(detail['namespace']) : '',
        isCurrent: name == current,
      ));
    }
    return contexts;
  }

  /// `metadata.name` of every item in a `kubectl get … -o json` list.
  static List<String> parseNames(String output) {
    return _items(output)
        .map((item) => _string(_metadata(item)['name']))
        .where((name) => name.isNotEmpty)
        .toList();
  }

  /// Workload rows out of `kubectl get deployments,statefulsets,daemonsets
  /// -o json`.
  ///
  /// Items of a kind this screen does not list are skipped rather than
  /// guessed at: a cluster with an aggregated API server can return kinds
  /// nobody here has a replica rule for.
  static List<KubeWorkload> parseWorkloads(String output) {
    final workloads = <KubeWorkload>[];
    for (final item in _items(output)) {
      final kind = WorkloadKind.byApiKind(_string(item['kind']));
      if (kind == null) continue;
      final metadata = _metadata(item);
      final name = _string(metadata['name']);
      if (name.isEmpty) continue;
      final spec = item['spec'] is Map ? item['spec'] as Map : const {};
      final status = item['status'] is Map ? item['status'] as Map : const {};

      // A DaemonSet has no `spec.replicas`: the number it wants is however
      // many nodes match, which only the status knows.
      final int desired;
      final int ready;
      if (kind == WorkloadKind.daemonSet) {
        desired = _int(status['desiredNumberScheduled']);
        ready = _int(status['numberReady']);
      } else {
        // `spec.replicas` defaults to 1 when the manifest omits it, exactly
        // as the API server does.
        desired = spec['replicas'] == null ? 1 : _int(spec['replicas']);
        ready = _int(status['readyReplicas']);
      }

      workloads.add(KubeWorkload(
        name: name,
        namespace: _string(metadata['namespace']),
        kind: kind,
        desired: desired,
        ready: ready,
        images: _images(spec),
        selector: _selector(spec),
        created: _time(metadata['creationTimestamp']),
      ));
    }
    return workloads;
  }

  /// Pod rows out of `kubectl get pods -o json`.
  static List<KubePod> parsePods(String output) {
    final pods = <KubePod>[];
    for (final item in _items(output)) {
      final metadata = _metadata(item);
      final name = _string(metadata['name']);
      if (name.isEmpty) continue;
      final spec = item['spec'] is Map ? item['spec'] as Map : const {};
      final status = item['status'] is Map ? item['status'] as Map : const {};
      final statuses = status['containerStatuses'];
      var ready = 0;
      var total = 0;
      var restarts = 0;
      if (statuses is List) {
        for (final container in statuses) {
          if (container is! Map) continue;
          total++;
          if (container['ready'] == true) ready++;
          restarts += _int(container['restartCount']);
        }
      }
      // A pod that has not been scheduled yet has no container statuses at
      // all; the spec still says how many containers it will have, which
      // keeps the row reading "0/2" instead of "0/0".
      if (total == 0 && spec['containers'] is List) {
        total = (spec['containers'] as List).length;
      }
      pods.add(KubePod(
        name: name,
        phase: _string(status['phase']),
        readyContainers: ready,
        totalContainers: total,
        restarts: restarts,
        node: _string(spec['nodeName']),
        created: _time(metadata['creationTimestamp']),
      ));
    }
    return pods;
  }

  static List<String> _images(Map spec) {
    final template = spec['template'];
    if (template is! Map) return const [];
    final podSpec = template['spec'];
    if (podSpec is! Map) return const [];
    final containers = podSpec['containers'];
    if (containers is! List) return const [];
    final images = <String>[];
    for (final container in containers) {
      if (container is! Map) continue;
      final image = _string(container['image']);
      if (image.isNotEmpty && !images.contains(image)) images.add(image);
    }
    return images;
  }

  static Map<String, String> _selector(Map spec) {
    final selector = spec['selector'];
    if (selector is! Map) return const {};
    final labels = selector['matchLabels'];
    if (labels is! Map) return const {};
    final pairs = <String, String>{};
    labels.forEach((key, value) {
      if (key is String && value is String) pairs[key] = value;
    });
    return pairs;
  }

  static List<Map> _items(String output) {
    final root = _decodeObject(output);
    final items = root?['items'];
    if (items is! List) return const [];
    return items.whereType<Map>().toList();
  }

  static Map _metadata(Map item) =>
      item['metadata'] is Map ? item['metadata'] as Map : const {};

  /// kubectl writes plain text on some paths (a plugin warning, a deprecation
  /// notice) and that is not this function's failure to report — every caller
  /// treats "nothing parseable" as "nothing there".
  static Map? _decodeObject(String output) {
    if (output.trim().isEmpty) return null;
    try {
      final decoded = json.decode(output);
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static String _string(Object? value) => value is String ? value : '';

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}
