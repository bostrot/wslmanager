/// A one-click local service — a storage backend, database or message
/// broker — installed into an existing instance (a WSL distro or a VM).
///
/// Recipes are the app's answer to "spin up MinIO / Postgres / Redis without
/// hand-writing a docker command". They are curated in code rather than
/// user-authored so the scripts are trustworthy and versioned with the app;
/// [QuickActionItem] stays the surface for arbitrary user scripts.
///
/// Every recipe runs the same shape of script: make sure Docker is present
/// and up, then run one container with a fixed name and a known host port.
/// The service surface — the dashboard or the endpoint — is [port], so the
/// UI, the MCP tools and the AI can all report where the thing now lives.
enum RecipeCategory { storage, database, broker }

class ServiceRecipe {
  const ServiceRecipe({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.image,
    required this.containerName,
    required this.port,
    this.dashboardPath = '',
    this.credentials = '',
    this.env = const {},
    this.extraArgs = const [],
    this.command = '',
  });

  /// Stable slug, used by the MCP tools and as the container name suffix.
  final String id;
  final String name;
  final RecipeCategory category;

  /// One line the picker and the tools show.
  final String description;

  /// The Docker image, tag included.
  final String image;

  /// Fixed container name inside the instance, so a recipe applied twice
  /// updates rather than piling up.
  final String containerName;

  /// Host port the primary surface (dashboard or endpoint) is published on.
  final int port;

  /// Path appended to `http://<host>:<port>` for a web dashboard, or '' when
  /// the surface is a raw endpoint (a database/broker port).
  final String dashboardPath;

  /// What to sign in with, shown after install — never a real secret store,
  /// just the fixed dev credentials the recipe sets.
  final String credentials;

  /// `-e KEY=VALUE` pairs passed to `docker run`.
  final Map<String, String> env;

  /// Extra `docker run` arguments (additional `-p`, `-v`, flags).
  final List<String> extraArgs;

  /// Optional command appended after the image.
  final String command;

  bool get hasDashboard => dashboardPath.isNotEmpty;

  /// The URL or endpoint the service is reachable at from the host running
  /// the instance. [host] is `127.0.0.1` for a local WSL distro and the
  /// guest IP for a VM.
  String surface(String host) => hasDashboard
      ? 'http://$host:$port$dashboardPath'
      : '$host:$port';

  /// The POSIX script that installs and (re)starts the service. Idempotent:
  /// it removes any prior container of the same name first, so re-applying a
  /// recipe is a clean restart, and it never assumes Docker is pre-installed
  /// — the base images this app creates do not have it.
  ///
  /// `sh`, not bash, and no unquoted interpolation of anything user-supplied:
  /// every field here is a code constant, and [dockerRunLine] is assembled
  /// from those constants alone.
  String buildScript() {
    return '''
set -e
if ! command -v docker >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache docker
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q docker
  fi
fi
(service docker start >/dev/null 2>&1 || rc-service docker start >/dev/null 2>&1 || dockerd >/dev/null 2>&1 &) || true
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do docker info >/dev/null 2>&1 && break; sleep 1; done
docker rm -f $containerName >/dev/null 2>&1 || true
docker pull $image >/dev/null 2>&1 || true
$dockerRunLine
echo RECIPE_OK''';
  }

  /// The single `docker run` line, built from the recipe's constants.
  String get dockerRunLine {
    final parts = <String>[
      'docker run -d',
      '--name $containerName',
      '--restart unless-stopped',
      '-p $port:$port',
      ...extraArgs,
      for (final entry in env.entries) '-e ${entry.key}=${entry.value}',
      image,
      if (command.isNotEmpty) command,
    ];
    return parts.join(' ');
  }
}
