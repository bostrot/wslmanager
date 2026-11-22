// Value types shared by the cloud layer.
//
// A cloud server is neither an instance nor a container: the provider owns
// its lifecycle, it costs money for every hour it exists, and it lives on the
// other side of a network the app cannot assume anything about. It therefore
// gets its own model and its own screen — the same reasoning that kept
// containers out of the Home list (bostrot/ai-tasks#57, #62).

/// A cloud provider the app can drive.
///
/// One enum value per provider rather than only a subclass: the id is what
/// gets written to preferences and what the UI switches on, and keeping the
/// human label next to it means no lookup table.
enum CloudProviderId {
  hetzner('hetzner', 'Hetzner Cloud');

  const CloudProviderId(this.id, this.label);

  /// Stable identifier, written to preferences.
  final String id;

  /// Name shown to the user.
  final String label;

  /// The provider stored under [id], or null when the value is stale — a
  /// provider the user had configured and a later build dropped.
  static CloudProviderId? byId(String? value) {
    for (final provider in CloudProviderId.values) {
      if (provider.id == value) return provider;
    }
    return null;
  }
}

/// Lifecycle state of a cloud server, normalised across providers.
///
/// Anything unrecognised lands on [unknown] rather than being dropped, so the
/// row still renders and the user can still delete a server they are paying
/// for.
enum CloudServerState {
  initializing,
  starting,
  running,
  stopping,
  off,
  deleting,
  migrating,
  rebuilding,
  unknown;

  /// Whether the server is up and should be reachable over SSH.
  bool get isRunning => this == running;

  /// Whether the provider is still working on it, so the screen keeps
  /// polling instead of treating this as a final answer.
  bool get isTransient =>
      this == initializing ||
      this == starting ||
      this == stopping ||
      this == deleting ||
      this == migrating ||
      this == rebuilding;

  static CloudServerState parse(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'initializing':
        return initializing;
      case 'starting':
        return starting;
      case 'running':
        return running;
      case 'stopping':
        return stopping;
      case 'off':
        return off;
      case 'deleting':
        return deleting;
      case 'migrating':
        return migrating;
      case 'rebuilding':
        return rebuilding;
      default:
        return unknown;
    }
  }
}

/// One server in the user's cloud project.
class CloudServer {
  /// Provider-assigned id, used to address it in every later call.
  final String id;

  final String name;

  final CloudServerState state;

  /// Public IPv4 address, or '' while the provider has not assigned one.
  final String ipv4;

  /// Public IPv6 address, or ''.
  final String ipv6;

  /// Server type as the provider names it (`cx22`, `cpx11`, …).
  final String serverType;

  /// Datacenter/location as the provider names it (`nbg1`, `hel1`, …).
  final String location;

  /// Image the server was created from, as the provider reports it.
  final String image;

  /// Monthly price including VAT in the project's currency, or '' when the
  /// provider did not say. Shown because a forgotten server is the expensive
  /// mistake this screen can cause.
  final String monthlyPrice;

  /// Currency of [monthlyPrice], e.g. `EUR`.
  final String currency;

  /// Labels the provider stores on the server. The app tags what it deploys
  /// (see [deployedInstanceLabel]) so it can offer to pull those back.
  final Map<String, String> labels;

  final CloudProviderId provider;

  const CloudServer({
    required this.id,
    required this.name,
    required this.state,
    required this.provider,
    this.ipv4 = '',
    this.ipv6 = '',
    this.serverType = '',
    this.location = '',
    this.image = '',
    this.monthlyPrice = '',
    this.currency = '',
    this.labels = const {},
  });

  /// The address SSH connects to. IPv4 first: a host without IPv6 is far
  /// more common than one without IPv4, and both are usually present.
  String get address => ipv4.isNotEmpty ? ipv4 : ipv6;

  /// The instance this app deployed here, or null when the server was not
  /// created by a deploy (or was created by hand in the provider's console).
  String? get deployedInstance {
    final value = labels[deployedInstanceLabel];
    return value == null || value.isEmpty ? null : value;
  }

  /// A one-line summary for the AI chat and log messages.
  String get summary {
    final parts = <String>[
      '$name (${state.name})',
      if (address.isNotEmpty) 'ip=$address',
      if (serverType.isNotEmpty) 'type=$serverType',
      if (location.isNotEmpty) 'location=$location',
      if (monthlyPrice.isNotEmpty) 'price=$monthlyPrice $currency/mo',
    ];
    return parts.join(' ');
  }

  /// Label key carrying the name of the instance a deploy put on the server.
  ///
  /// Stored on the *server* rather than in this app's preferences on purpose:
  /// the pairing then survives a reinstall, and a second machine signing in
  /// with the same API token sees the same servers as deployable-from/to.
  /// Hetzner label keys allow `[a-z0-9A-Z._-]`, so no dots-as-namespace here.
  static const String deployedInstanceLabel = 'wslmanager-instance';

  /// Label key marking a server this app created at all.
  static const String managedLabel = 'wslmanager';
}

/// One server type (a size) offered by the provider.
class CloudServerType {
  final String id;

  /// What the user picks it by, e.g. `cx22`.
  final String name;

  final String description;
  final int cores;
  final double memoryGb;
  final int diskGb;

  /// Monthly price including VAT, or '' when unknown.
  final String monthlyPrice;
  final String currency;

  /// Architecture the type runs, e.g. `x86` or `arm`. A rootfs built for one
  /// will not run on the other, which is the single most likely way a deploy
  /// silently produces a broken container.
  final String architecture;

  const CloudServerType({
    required this.id,
    required this.name,
    this.description = '',
    this.cores = 0,
    this.memoryGb = 0,
    this.diskGb = 0,
    this.monthlyPrice = '',
    this.currency = '',
    this.architecture = '',
  });

  /// `cx22 · x86 · 2 vCPU · 4 GB · 40 GB · 3.79 EUR/mo`
  ///
  /// The architecture sits right after the name because it is the one
  /// attribute that decides whether a deploy can work at all, and a type's
  /// name (`cax11`, `cpx11`) does not say it.
  String get label {
    final parts = <String>[
      name,
      if (architecture.isNotEmpty) architecture,
      if (cores > 0) '$cores vCPU',
      if (memoryGb > 0) '${_trim(memoryGb)} GB',
      if (diskGb > 0) '$diskGb GB',
      if (monthlyPrice.isNotEmpty) '$monthlyPrice $currency/mo',
    ];
    return parts.join(' · ');
  }

  static String _trim(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';
}

/// One location (a datacenter region) offered by the provider.
class CloudLocation {
  final String id;
  final String name;
  final String description;
  final String country;
  final String city;

  const CloudLocation({
    required this.id,
    required this.name,
    this.description = '',
    this.country = '',
    this.city = '',
  });

  /// `nbg1 · Nuremberg, DE`
  String get label {
    final where = [city, country].where((p) => p.isNotEmpty).join(', ');
    return where.isEmpty ? name : '$name · $where';
  }
}

/// One base image (an operating system) offered by the provider.
class CloudImage {
  final String id;
  final String name;
  final String description;

  /// Architecture the image is built for, matching [CloudServerType].
  final String architecture;

  const CloudImage({
    required this.id,
    required this.name,
    this.description = '',
    this.architecture = '',
  });

  String get label => description.isEmpty ? name : description;
}

/// An SSH public key registered with the provider, so a freshly created
/// server accepts the user's own key for `root`.
class CloudSshKey {
  final String id;
  final String name;
  final String fingerprint;

  const CloudSshKey({
    required this.id,
    required this.name,
    this.fingerprint = '',
  });
}

/// What the provider offers, fetched once when the deploy form opens.
class CloudCatalogue {
  final List<CloudServerType> serverTypes;
  final List<CloudLocation> locations;
  final List<CloudImage> images;

  const CloudCatalogue({
    this.serverTypes = const [],
    this.locations = const [],
    this.images = const [],
  });
}

/// Raised when a provider call fails or the app is not configured for one.
/// Carries the provider's own message so the UI can show it instead of a
/// generic failure — "server type is not available in this location" is worth
/// reading and "deploy failed" is not.
class CloudException implements Exception {
  final String message;

  const CloudException(this.message);

  @override
  String toString() => message;
}

/// A step in a deploy or a pull, for the progress line in the UI.
///
/// The stages are the ones a user waits differently long for: creating a
/// server is seconds, exporting and transferring a root filesystem is
/// minutes, and knowing which one is running is the difference between
/// "still working" and "stuck".
enum DeployStage {
  exporting,
  creatingServer,
  waitingForServer,
  waitingForDocker,
  uploading,
  importing,
  starting,
  downloading,
  importingLocally,
  cleaningUp,
  done,
}

/// One progress report from [CloudDeployService].
class DeployProgress {
  final DeployStage stage;

  /// Extra detail for the stage, e.g. the server's address. May be empty.
  final String detail;

  const DeployProgress(this.stage, {this.detail = ''});
}
