// Value types for the Kubernetes layer.
//
// The shape here follows the containers layer (bostrot/ai-tasks#57) for the
// same reason: a cluster workload is not an [Instance] the app owns, it is
// something a cluster somewhere else owns and this app reads. What is new is
// the scale — a dev with ten clusters of a hundred apps each — so every type
// below carries the little that a *list row* needs and nothing more. The
// heavy per-object detail (`describe`, logs, pods) is fetched when a row is
// opened, never for the whole list.

/// The kinds of workload the screen lists, in the order they are shown.
///
/// Deliberately the three a developer deploys, not everything the API server
/// has: Jobs and CronJobs come and go on their own schedule and would bury a
/// list of long-running apps, and the rest (ReplicaSets, Pods) are what these
/// three own rather than something anyone deploys by hand.
enum WorkloadKind {
  deployment('Deployment', 'deployments', scalable: true),
  statefulSet('StatefulSet', 'statefulsets', scalable: true),
  // A DaemonSet's replica count is "one per matching node", so `kubectl
  // scale` refuses it — the Scale action is hidden rather than offered and
  // then rejected by the API server.
  daemonSet('DaemonSet', 'daemonsets', scalable: false);

  const WorkloadKind(this.label, this.plural, {required this.scalable});

  /// Name shown to the user, and the one the API server uses.
  final String label;

  /// What `kubectl get` is asked for.
  final String plural;

  /// Whether `kubectl scale` accepts this kind.
  final bool scalable;

  /// `deployment/name`, the form every `kubectl` verb accepts.
  String ref(String name) => '${plural.substring(0, plural.length - 1)}/$name';

  /// The kind behind an API object's `kind` field, or null for anything the
  /// screen does not list.
  static WorkloadKind? byApiKind(String? kind) {
    for (final value in WorkloadKind.values) {
      if (value.label == kind) return value;
    }
    return null;
  }
}

/// How a workload is doing, reduced to the four states a list row can show at
/// a glance. This is the whole point of the screen: with a hundred apps in a
/// namespace, the answer to "what is broken" has to be a colour, not a table
/// of numbers to read.
enum WorkloadHealth {
  /// Every replica the spec asks for is ready.
  healthy,

  /// Some replicas are ready and some are not — a rollout in flight, or a
  /// pod that keeps dying.
  degraded,

  /// The spec asks for replicas and none of them are ready.
  down,

  /// Scaled to zero on purpose. Not a failure, and must not read as one.
  scaledToZero;

  /// Where this sits in a list that puts what needs attention first —
  /// deliberately not the declaration order, which reads healthiest-first.
  ///
  /// Scaled to zero comes last, below healthy: it is a workload someone
  /// parked, and it has even less claim on the reader's attention than one
  /// that is running fine.
  int get attentionRank {
    switch (this) {
      case WorkloadHealth.down:
        return 0;
      case WorkloadHealth.degraded:
        return 1;
      case WorkloadHealth.healthy:
        return 2;
      case WorkloadHealth.scaledToZero:
        return 3;
    }
  }
}

/// One context out of a kubeconfig — a cluster the user can talk to.
class KubeContext {
  /// The context's name, which is what `--context` takes. Cloud providers
  /// generate long ones (`arn:aws:eks:eu-central-1:…:cluster/prod`), so the
  /// UI shows [label] and the commands use this.
  final String name;

  /// The cluster the context points at.
  final String cluster;

  /// The namespace the context defaults to, empty when it sets none — in
  /// which case Kubernetes itself means `default`.
  final String namespace;

  /// Whether this is the kubeconfig's `current-context`.
  final bool isCurrent;

  const KubeContext({
    required this.name,
    this.cluster = '',
    this.namespace = '',
    this.isCurrent = false,
  });

  /// The namespace commands should use when the user picked none.
  String get defaultNamespace => namespace.isEmpty ? 'default' : namespace;

  /// A short name for the picker. An EKS/GKE context name is a full ARN or a
  /// `gke_project_zone_cluster` string; the tail is the part that tells ten
  /// clusters apart, and the whole name is still there as the tooltip.
  String get label {
    final slash = name.lastIndexOf('/');
    if (slash != -1 && slash < name.length - 1) return name.substring(slash + 1);
    return name;
  }
}

/// A Deployment, StatefulSet or DaemonSet as one list row.
class KubeWorkload {
  final String name;
  final String namespace;
  final WorkloadKind kind;

  /// Replicas the spec asks for. For a DaemonSet this is the number of nodes
  /// it should be running on.
  final int desired;

  /// Replicas that are ready right now.
  final int ready;

  /// Container images, deduplicated, in the order the pod template lists
  /// them. The image is how a dev recognises their own app in a list.
  final List<String> images;

  /// The pod selector as label pairs, used to fetch this workload's pods
  /// without a second round trip to read the spec back.
  final Map<String, String> selector;

  /// Creation timestamp, or null when the object did not carry one.
  final DateTime? created;

  const KubeWorkload({
    required this.name,
    required this.namespace,
    required this.kind,
    required this.desired,
    required this.ready,
    this.images = const [],
    this.selector = const {},
    this.created,
  });

  WorkloadHealth get health {
    if (desired == 0) return WorkloadHealth.scaledToZero;
    if (ready >= desired) return WorkloadHealth.healthy;
    if (ready > 0) return WorkloadHealth.degraded;
    return WorkloadHealth.down;
  }

  /// `2/3`, the readiness column every Kubernetes tool prints.
  String get readiness => '$ready/$desired';

  /// The `--selector` argument that finds this workload's pods, or empty when
  /// the object has no selector (which nothing the API server returns for
  /// these three kinds actually does).
  String get selectorArgument =>
      selector.entries.map((e) => '${e.key}=${e.value}').join(',');
}

/// One pod under a workload.
class KubePod {
  final String name;

  /// `Running`, `Pending`, `Succeeded`, `Failed`, `Unknown` — the API's own
  /// phase, kept verbatim so an unexpected value still renders.
  final String phase;

  /// Containers ready out of containers in the pod.
  final int readyContainers;
  final int totalContainers;

  /// Restarts summed over the pod's containers. The number a dev looks at
  /// first when something is crash-looping.
  final int restarts;

  /// The node the pod was scheduled on, empty while it is still pending.
  final String node;

  final DateTime? created;

  const KubePod({
    required this.name,
    required this.phase,
    this.readyContainers = 0,
    this.totalContainers = 0,
    this.restarts = 0,
    this.node = '',
    this.created,
  });

  bool get isRunning => phase == 'Running' && readyContainers >= totalContainers;

  String get readiness => '$readyContainers/$totalContainers';
}

/// Raised when `kubectl` is missing, or when it answers with a failure. Holds
/// the cluster's own message: "Unauthorized" and "connection refused" need
/// very different reactions and only kubectl knows which one happened.
class KubeException implements Exception {
  final String message;

  const KubeException(this.message);

  @override
  String toString() => message;
}

/// Compact age of [created], the way `kubectl get` prints it: the largest
/// unit that still has a digit, so a list of a hundred rows stays one column
/// wide. Empty for an object without a timestamp.
String formatKubeAge(DateTime? created, {DateTime? now}) {
  if (created == null) return '';
  final delta = (now ?? DateTime.now().toUtc()).difference(created.toUtc());
  if (delta.isNegative) return '0s';
  if (delta.inDays >= 1) return '${delta.inDays}d';
  if (delta.inHours >= 1) return '${delta.inHours}h';
  if (delta.inMinutes >= 1) return '${delta.inMinutes}m';
  return '${delta.inSeconds}s';
}
