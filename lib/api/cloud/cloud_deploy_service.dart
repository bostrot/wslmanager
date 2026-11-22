// Moving a local instance to a cloud server and back again.
//
// The shape of this (bostrot/ai-tasks#62) is the one thing worth explaining,
// because the obvious design does not work: you cannot take the disk of a
// local VM, upload it, and boot it at a provider. A cloud disk has to be
// partitioned the way that provider's firmware expects, carry its virtio
// drivers, and run cloud-init to pick up its own networking — a local
// instance has none of that, and shipping one produces a machine that never
// answers and a bill that keeps running.
//
// What *is* portable is the root filesystem. So a deploy is:
//
//   1. export the instance to a rootfs tarball,
//   2. create a stock server at the provider, whose cloud-init installs
//      Docker and nothing else,
//   3. `docker import` the tarball there and run it,
//
// which lands the user's whole setup — packages, dotfiles, /etc, their data —
// on a machine with a public address, in one step, on a base image that the
// provider itself keeps bootable. A pull is the same three steps read
// backwards: `docker export`, download, import locally.
//
// "Run it" has to mean more than keeping the container alive, though
// (bostrot/ai-tasks#84): a web server the instance served locally is expected
// to answer on the cloud address afterwards. So the container shares the
// server's network namespace — every port a service inside listens on is a
// port on the public address, without anyone having to list them in advance
// — and, when the root filesystem carries systemd, systemd is what runs as
// its PID 1, so the units the user enabled locally come up the way they did
// there. It gets the few privileges a booting systemd needs and nothing
// else, on purpose: systemd's own units already know not to configure a
// machine they have no capability to configure, which is what keeps the
// guest's networkd, udev and sysctl off the server ([_dockerRunArgs]). The
// deploy then waits for that boot to finish rather than for the process to
// exist. A root filesystem with no systemd is kept alive with `sleep` as
// before, and whatever it runs is the user's to start.
//
// Two things are checked before a byte is moved, because both would
// otherwise cost the user a long export and a billed server to find out:
// the server type's CPU architecture has to be the instance's (a provider
// sells both, and the programs in an arm64 rootfs do not run on an x86
// server or the other way round), and a boot that does fail is left on the
// server, stopped, with its log in the error — the evidence of what went
// wrong is worth more than a tidy server ([_checkContainerUp]).
//
// Step 1 and the last step are the backend's, not this file's
// ([VmBackend.exportRootfs] / [VmBackend.importRootfs]), because they are the
// only part that differs per backend: WSL hands over a rootfs tarball
// directly (`wsl --export --format tar`), while the Apple backend has to tar
// its running guest over SSH and, coming back, restore into a clone of the VM
// the deploy came from — a bare rootfs has no kernel to boot there. Nothing
// below cares which of the two it got.
//
// It also means this file re-uses the app's existing idea of a container as
// "a process tree the engine owns" rather than inventing a second one: the
// thing running up there is an ordinary container the user's own `docker ps`
// on that server shows.
//
// Note the SSH here is *not* [sshRemoteCommand]: that one wraps commands for
// a remote *Windows* host's login shell (PowerShell, cmd), which is exactly
// wrong for a Linux cloud server. These targets get POSIX quoting instead.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:wsl2distromanager/api/cloud/cloud_models.dart';
import 'package:wsl2distromanager/api/cloud/cloud_provider.dart';
import 'package:wsl2distromanager/api/execution/broker.dart';
import 'package:wsl2distromanager/api/execution/models.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// Instance and server names accepted from callers.
///
/// Nothing here reaches a shell unquoted, but a name is also a Docker image
/// tag, a Hetzner server name and a file name, and the intersection of what
/// those three accept is this. Leading `-` is excluded so a crafted name
/// cannot arrive as another flag.
final RegExp cloudNamePattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,61}$');

/// The user the app connects to a fresh cloud server as. Providers create
/// exactly one account on a stock image and this is it.
const String cloudRootUser = 'root';

/// The CPU architecture family a provider's wording means: `arm` for the
/// 64-bit ARM types (Hetzner says `arm`, others `arm64` or `aarch64`), `x86`
/// for the Intel/AMD ones (`x86`, `x86_64`, `amd64`, `x64`), '' for anything
/// else or nothing at all.
String cloudArchitectureFamily(String reported) {
  final value = reported.trim().toLowerCase();
  // Whole words only: a description that merely contains the letters is
  // not a family.
  if (RegExp(r'\b(arm|arm64|armv8|aarch64)\b').hasMatch(value)) return 'arm';
  if (RegExp(r'\b(x86|x86_64|x86-64|amd64|x64)\b').hasMatch(value)) {
    return 'x86';
  }
  return '';
}

/// The architecture family of the instances this machine exports, or ''
/// when it is neither of the two a provider sells.
///
/// Read off the machine rather than out of the archive: both backends
/// virtualise the host's own architecture (WSL 2 and Virtualization.framework
/// do not emulate), so an instance is arm64 on an Apple Silicon Mac or a
/// Windows-on-ARM machine and x86-64 everywhere else, and a 2 GB tarball
/// does not have to be opened to know it.
///
/// The app's own ABI is the answer except under emulation: the Windows build
/// is x64 only, and on an ARM64 PC it runs under x64 emulation with an ABI
/// that says `windows_x64` while every WSL distribution there is arm64.
/// Windows tells an emulated process about that in `PROCESSOR_ARCHITEW6432`,
/// which is consulted first; [environment] and [abi] exist so tests can
/// describe a machine other than the one running them.
String cloudLocalArchitecture({Abi? abi, Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final emulated = cloudArchitectureFamily(env['PROCESSOR_ARCHITEW6432'] ?? '');
  if (emulated.isNotEmpty) return emulated;
  final name = (abi ?? Abi.current()).toString(); // e.g. `macos_arm64`
  if (name.endsWith('_arm64')) return 'arm';
  if (name.endsWith('_x64') || name.endsWith('_ia32')) return 'x86';
  return '';
}

/// Marker cloud-init touches once Docker is up, so the deploy waits for a
/// *ready* machine rather than merely a reachable one. `docker version`
/// answering is not enough on its own — the daemon is installed part of the
/// way through the boot, and a deploy that raced it failed on the import.
const String cloudReadyMarker = '/run/wslmanager-ready';

/// Where systemd lives in a root filesystem, in the order it is looked for.
///
/// `/sbin/init` is deliberately not on the list: on a systemd distribution
/// it is a symlink to one of these, and on anything else it is SysV init,
/// OpenRC or BusyBox, none of which is worth being PID 1 of a container —
/// they would spawn gettys onto the server's console and little else.
const List<String> cloudSystemdCandidates = [
  '/usr/lib/systemd/systemd',
  '/lib/systemd/systemd',
];

/// Units masked for the boot of a deployed root filesystem.
///
/// Passed as `systemd.mask=` on systemd's argv, which is where a container's
/// PID 1 reads its "kernel command line" from — the image is a `docker
/// import` of a tarball and cannot carry a layer of mask symlinks of its
/// own. The list is short because the container's missing capabilities do
/// most of this job (see [_dockerRunArgs]); what is left is what would run
/// happily without any: cloud-init, which would set about provisioning a
/// machine the provider already provisioned, and the guest's sshd, which
/// shares port 22 with the server's own and must never be the one that wins
/// it — every command this file runs assumes `root@server` is the server.
/// Masking a unit a distribution does not ship is harmless.
const List<String> cloudMaskedUnits = [
  'cloud-init-local.service',
  'cloud-init-main.service',
  'cloud-init-network.service',
  'cloud-init.service',
  'cloud-config.service',
  'cloud-final.service',
  'ssh.service',
  'ssh.socket',
  'sshd.service',
  'sshd.socket',
];

/// cloud-init handed to the provider at create time.
///
/// Deliberately minimal: install Docker, enable it, touch the marker. Every
/// line here runs before the user can see the machine, so anything that can
/// fail silently is a support ticket nobody can debug.
const String cloudInitUserData = '''
#cloud-config
package_update: true
packages:
  - docker.io
runcmd:
  - [systemctl, enable, --now, docker]
  - [touch, $cloudReadyMarker]
''';

/// Quote one token for a POSIX shell.
///
/// `ssh host a b c` does not exec `a b c` — it joins its argv with spaces and
/// hands the string to the remote login shell, which parses it again. Every
/// token therefore has to survive one round of shell parsing, and single
/// quotes are the only form that does so without exception (`'` itself is
/// closed, escaped and reopened).
String posixQuote(String token) {
  if (token.isNotEmpty && RegExp(r'^[A-Za-z0-9_./:=@%+-]+$').hasMatch(token)) {
    return token;
  }
  return "'${token.replaceAll("'", r"'\''")}'";
}

/// A whole argv as one POSIX shell command line.
String posixCommandLine(List<String> args) => args.map(posixQuote).join(' ');

/// SSH options for a *cloud* target.
///
/// Spelled out rather than built on [getSshClientOptions] for two reasons.
///
/// `StrictHostKeyChecking=accept-new`: a server created thirty seconds ago is
/// in nobody's known_hosts, and under `BatchMode=yes` the default `ask` is a
/// refusal rather than a prompt — the deploy would fail on its first command
/// every single time. `accept-new` still refuses a host whose key *changed*,
/// which is the case worth refusing.
///
/// And no connection multiplexing: the shared options pin one fixed
/// `ControlPath` for the whole app, and a socket with no `%h` in it is a
/// master for whichever host reached it first. Sharing that with the remote
/// *Windows* target the rest of the app talks to would send these commands to
/// the wrong machine. OpenSSH takes the first value it is given for an
/// option, so this cannot be undone by appending an override — the shared
/// list simply must not be used here. A deploy opens a handful of connections
/// over several minutes, so there is nothing to multiplex anyway.
List<String> cloudSshOptions() => <String>[
      '-o',
      'BatchMode=yes',
      '-o',
      'PasswordAuthentication=no',
      '-o',
      'KbdInteractiveAuthentication=no',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-o',
      'ConnectTimeout=10',
      '-o',
      'ServerAliveInterval=30',
      '-o',
      'ServerAliveCountMax=3',
    ];

/// The full `ssh` argument list running [args] on a Linux cloud host.
List<String> cloudSshCommand(String target, List<String> args) => <String>[
      ...cloudSshOptions(),
      '--',
      target,
      posixCommandLine(args),
    ];

/// Deploys instances to cloud servers and pulls them back.
class CloudDeployService {
  CloudDeployService({
    required this.provider,
    Shell? shell,
    ExecutionBroker? broker,
    VmBackend? backend,
    this.sshDirectoryOverride,
    String? localArchitecture,
    this.commandTimeout = const Duration(minutes: 10),
    this.transferTimeout = const Duration(hours: 2),
    this.readyTimeout = const Duration(minutes: 10),
    this.pollInterval = const Duration(seconds: 5),
  })  : _broker = broker ?? ExecutionBroker(shell: shell ?? ProcessShell()),
        _backend = backend,
        localArchitecture = localArchitecture ?? cloudLocalArchitecture();

  final CloudProvider provider;
  final ExecutionBroker _broker;
  final VmBackend? _backend;

  /// The architecture family ([cloudArchitectureFamily]) of the instances
  /// this machine exports; '' turns the check off. Tests pass their own
  /// rather than inheriting whatever machine runs them.
  final String localArchitecture;

  /// How long one ordinary remote command may take.
  final Duration commandTimeout;

  /// How long an upload or a download may take. Transfers here are whole
  /// root filesystems over a home connection: gigabytes, uphill.
  final Duration transferTimeout;

  /// How long to wait for a new server to boot and finish cloud-init.
  final Duration readyTimeout;

  /// Gap between polls while waiting for a server or for cloud-init.
  final Duration pollInterval;

  /// Where to look for the user's SSH key pair. Null means `~/.ssh`; tests
  /// point it at a directory of their own rather than at the machine running
  /// them, whose keys are not something a test may depend on either way.
  final String? sshDirectoryOverride;

  VmBackend get backend => _backend ?? vmBackend();

  /// Whether this host can deploy at all.
  ///
  /// Gated on the backend, not the OS: what a deploy needs is an instance the
  /// backend can hand over as a root filesystem tarball. Both shipped
  /// backends can — WSL natively, the Apple one by reading the running guest
  /// — so this is a flag rather than a platform check for the backend that
  /// cannot.
  bool get canDeploy => backend.features.rootfsExport;

  /// Deploy [instance] onto a newly created server.
  ///
  /// Returns the server once the instance is running on it. Every stage is
  /// reported through [onProgress] — the whole thing takes minutes and a UI
  /// with no idea which minute it is in cannot be trusted.
  ///
  /// [serverArchitecture] is what the provider says [serverType] runs on
  /// (see [CloudServerType.architecture]). When it is known and is not this
  /// machine's, the deploy is refused here, before the export: the rootfs
  /// would import fine and then fail on its first `exec`, minutes and one
  /// billed server later.
  Future<CloudServer> deploy({
    required String instance,
    required String serverName,
    required String serverType,
    required String image,
    required String location,
    String serverArchitecture = '',
    void Function(DeployProgress progress)? onProgress,
  }) async {
    _checkName(instance, 'instance');
    _checkName(serverName, 'serverName');
    if (!canDeploy) {
      throw CloudException('Deploying is not supported for '
          '${backend.instanceNoun} instances on this backend.');
    }
    final wanted = cloudArchitectureFamily(serverArchitecture);
    if (wanted.isNotEmpty &&
        localArchitecture.isNotEmpty &&
        wanted != localArchitecture) {
      // "an arm", "an x86": both families happen to be said with a vowel.
      throw CloudException('$serverType is an $wanted server type, but the '
          '${backend.instanceNoun} instances on this machine are '
          '$localArchitecture: their programs cannot run there. Pick an '
          '$localArchitecture server type.');
    }

    void report(DeployStage stage, [String detail = '']) =>
        onProgress?.call(DeployProgress(stage, detail: detail));

    final tarPath = _localStagingPath(instance);
    try {
      report(DeployStage.exporting, instance);
      await backend.exportRootfs(instance, tarPath,
          onStatus: (detail) => report(DeployStage.exporting, detail));
      if (!await File(tarPath).exists()) {
        throw CloudException('Exporting $instance produced no file.');
      }

      report(DeployStage.creatingServer, serverName);
      final sshKeyIds = await _ensureSshKey();
      var server = await provider.createServer(
        name: serverName,
        serverType: serverType,
        image: image,
        location: location,
        sshKeyIds: sshKeyIds,
        userData: cloudInitUserData,
        labels: {
          CloudServer.managedLabel: 'true',
          CloudServer.deployedInstanceLabel: instance,
        },
      );

      report(DeployStage.waitingForServer, server.name);
      server = await waitForAddress(server);
      final target = '$cloudRootUser@${server.address}';

      report(DeployStage.waitingForDocker, server.address);
      await _waitForReady(target);

      final remoteTar = '/root/${p.basename(tarPath)}';
      report(DeployStage.uploading, server.address);
      await _upload(tarPath, target, remoteTar);

      report(DeployStage.importing, instance);
      await _run(target, ['docker', 'import', remoteTar, _imageTag(instance)],
          what: 'importing the root filesystem');

      report(DeployStage.starting, instance);
      final systemd = await _findSystemd(target, instance);
      await _run(target, _dockerRunArgs(instance, systemd),
          what: 'starting the container');
      await _checkContainerUp(target, instance, systemd);

      report(DeployStage.cleaningUp);
      // Best effort: the deploy has succeeded by now, and failing it over a
      // leftover tarball would be absurd.
      await _run(target, ['rm', '-f', remoteTar],
          what: 'removing the uploaded archive', allowFailure: true);

      report(DeployStage.done, server.address);
      return server;
    } finally {
      await _deleteQuietly(tarPath);
    }
  }

  /// Bring [instance] back from [server] as a local instance called
  /// [localName], leaving the cloud side untouched.
  ///
  /// The local name is separate on purpose: pulling onto the instance the
  /// deploy came from would destroy whatever the user did locally in the
  /// meantime, and importing onto an existing name fails rather than merging.
  /// The screen suggests `<instance>-cloud`. [instance] is still needed —
  /// it names the container on the server, and it is the base the Apple
  /// backend restores onto.
  Future<void> pullBack({
    required CloudServer server,
    required String instance,
    required String localName,
    String installLocation = '',
    void Function(DeployProgress progress)? onProgress,
  }) async {
    _checkName(instance, 'instance');
    _checkName(localName, 'localName');
    if (!canDeploy) {
      throw CloudException('Pulling back is not supported for '
          '${backend.instanceNoun} instances on this backend.');
    }
    if (server.address.isEmpty) {
      throw CloudException('${server.name} has no address to connect to.');
    }

    void report(DeployStage stage, [String detail = '']) =>
        onProgress?.call(DeployProgress(stage, detail: detail));

    final target = '$cloudRootUser@${server.address}';
    final remoteTar = '/root/$localName-pull.tar';
    final tarPath = _localStagingPath('$localName-pull');
    try {
      report(DeployStage.exporting, instance);
      await _run(target, ['docker', 'export', '--output', remoteTar, instance],
          what: 'exporting the container', timeout: transferTimeout);

      report(DeployStage.downloading, server.address);
      await _download(target, remoteTar, tarPath);

      report(DeployStage.importingLocally, localName);
      await backend.importRootfs(localName, tarPath,
          installLocation: installLocation,
          sourceInstance: instance,
          onStatus: (detail) => report(DeployStage.importingLocally, detail));

      report(DeployStage.cleaningUp);
      await _run(target, ['rm', '-f', remoteTar],
          what: 'removing the exported archive', allowFailure: true);
      report(DeployStage.done, localName);
    } finally {
      await _deleteQuietly(tarPath);
    }
  }

  /// The path of systemd inside the imported image, or '' when it has none.
  ///
  /// Asked of the image itself rather than guessed from the instance's
  /// distribution name: what matters is what the tarball carries, and a WSL
  /// Ubuntu without systemd enabled still ships the binary, so it boots here
  /// exactly like the VM does. Only the probe's own "no" — exit 1 — and an
  /// image with no `sh` to run it in mean "no systemd"; anything else is
  /// the server or its Docker failing, and a deploy that shrugged that off
  /// would quietly start the user's system without its services. The
  /// kernel refusing to run the image's `sh` at all is the one failure
  /// worth a sentence of its own ([_failureText]).
  Future<String> _findSystemd(String target, String instance) async {
    final image = _imageTag(instance);
    final probe = cloudSystemdCandidates
        .map((path) => 'if [ -x $path ]; then echo $path; exit 0; fi')
        .join('; ');
    final result = await _exec(
        'ssh',
        cloudSshCommand(target,
            ['docker', 'run', '--rm', image, 'sh', '-c', '$probe; exit 1']));
    if (const [1, 126, 127].contains(result.exitCode) &&
        !_isExecFormatError(result)) {
      return '';
    }
    if (result.exitCode != 0) {
      throw CloudException(
          _failureText('probing the root filesystem for systemd', result));
    }
    final found = result.stdout.trim();
    return cloudSystemdCandidates.contains(found) ? found : '';
  }

  /// The `docker run` that boots the imported root filesystem as [instance].
  ///
  /// `--network host` is the point of the whole exercise: a service listening
  /// on a port inside is reachable on that port of the server's address,
  /// whatever port it is.
  ///
  /// With [systemd] set the container boots it as PID 1, with what that
  /// needs and no more: CAP_SYS_ADMIN to mount its own tmpfs and namespaces,
  /// a writable view of the cgroup tree it was started in, and the
  /// container's AppArmor confinement lifted, which would otherwise deny
  /// every mount the capability allows. Not `--privileged` — that would also
  /// hand over the server's devices, its network configuration and its
  /// module and sysctl tables, and systemd's own units decide by exactly
  /// those whether they are on a real machine: networkd asks for
  /// CAP_NET_ADMIN, udev for a writable /sys, sysctl for a writable
  /// /proc/sys, modules-load for CAP_SYS_MODULE. The less the container has,
  /// the less has to be masked by name, and a firewall or a second Docker
  /// the user enabled inside simply fails to start instead of reconfiguring
  /// the server. It is also what makes an fstab from a cloud image
  /// harmless: with /sys read-only systemd ignores the EFI partition the
  /// tarball no longer has, where a privileged boot waits for it and ends in
  /// emergency mode.
  ///
  /// Without systemd, `sleep` keeps the container alive for `docker exec`.
  List<String> _dockerRunArgs(String instance, String systemd) => <String>[
        'docker',
        'run',
        '--detach',
        '--name',
        instance,
        '--restart',
        'unless-stopped',
        '--network',
        'host',
        if (systemd.isEmpty) ...[
          // A root filesystem has no entrypoint of its own, so the
          // container needs one process to keep it alive; everything the
          // user does afterwards is `docker exec` into it.
          '--init',
          _imageTag(instance),
          'sleep',
          'infinity',
        ] else ...[
          '--cap-add',
          'SYS_ADMIN',
          '--security-opt',
          'apparmor=unconfined',
          '--cgroupns',
          'host',
          '--volume',
          '/sys/fs/cgroup:/sys/fs/cgroup:rw',
          '--tmpfs',
          '/run',
          '--tmpfs',
          '/run/lock',
          // The signal systemd reads as "halt", and its own default of time
          // to stop the user's services cleanly — a database inside deserves
          // better than Docker's ten seconds.
          '--stop-signal',
          'SIGRTMIN+3',
          '--stop-timeout',
          '90',
          '--env',
          'container=docker',
          _imageTag(instance),
          systemd,
          for (final unit in cloudMaskedUnits) 'systemd.mask=$unit',
        ],
      ];

  /// Fail the deploy when [instance] did not come up on the server.
  ///
  /// `docker run --detach` reports success the moment the process is
  /// spawned, and a container that is alive is not the same as a system that
  /// booted: systemd stays PID 1 with a dead boot behind it when it falls
  /// into emergency mode. So the systemd branch asks systemd itself and only
  /// the `sleep` branch settles for the container's state.
  ///
  /// A container that failed is *kept*, stopped: what it logged is the only
  /// record of why a boot that works locally did not work there, and the
  /// error carries as much of it as fits — the container's own output and,
  /// under systemd, the journal's warnings. Stopping is what keeps it from
  /// coming back in a loop on a server the user is paying for: its policy is
  /// `unless-stopped`, under which a container stopped by hand stays down
  /// until a `docker start` brings it back on purpose, restart policy and
  /// all. The stop is given a short deadline rather than the container's own
  /// ninety seconds — a boot that wedged is not going to halt cleanly either,
  /// and the error is already known. The server itself is left for the user
  /// to look at or delete.
  Future<void> _checkContainerUp(
      String target, String instance, String systemd) async {
    final failure = systemd.isEmpty
        ? await _sleepContainerFailure(target, instance)
        : await _systemdBootFailure(target, instance);
    if (failure == null) return;
    // Both streams: an init that refuses to start says why on stderr.
    final log = await _exec('ssh',
        cloudSshCommand(target, ['docker', 'logs', '--tail', '20', instance]));
    var journal = systemd.isEmpty
        ? ''
        : await _inContainer(target, instance,
            ['journalctl', '--no-pager', '-p', 'warning', '-n', '30'],
            what: 'reading the journal');
    // journalctl's way of saying nothing was logged; not evidence.
    if (journal == '-- No entries --') journal = '';
    final detail = [
      failure,
      log.stdout.trim(),
      log.stderr.trim(),
      if (journal.isNotEmpty) 'Journal:\n$journal',
    ].where((part) => part.isNotEmpty).join('\n');
    await _run(target, ['docker', 'stop', '--time', '15', instance],
        what: 'stopping the failed container', allowFailure: true);
    throw CloudException('$instance did not come up on the server. The '
        'container was stopped and left there to look at ("docker logs '
        '$instance", "docker start $instance" on the server); the server '
        'is still running.\n$detail');
  }

  /// Why a `sleep` container is not running one poll interval after its
  /// start, or null when it is.
  Future<String?> _sleepContainerFailure(String target, String instance) async {
    await Future.delayed(pollInterval);
    final state = await _containerState(target, instance);
    return state == 'running 0' ? null : 'Container state: $state.';
  }

  /// Why a systemd boot did not reach a running system, or null when it did.
  ///
  /// `is-system-running --wait` returns once the boot is over, with
  /// `degraded` counting as booted: the guest's resolver is bound to fail on
  /// a port the server already owns, and one failed unit is not a failed
  /// system. Asked over `docker exec` as soon as the container exists —
  /// systemd's control socket is up before anything else, but a call that
  /// lands earlier still, or on a container Docker is already restarting,
  /// gets no state at all. Then the container is checked instead and the
  /// question repeated, until [readyTimeout] runs out.
  Future<String?> _systemdBootFailure(String target, String instance) async {
    final deadline = DateTime.now().add(readyTimeout);
    while (true) {
      final result = await _exec(
          'ssh',
          cloudSshCommand(target, [
            'docker',
            'exec',
            instance,
            'systemctl',
            'is-system-running',
            '--wait',
          ]),
          timeout: readyTimeout);
      final state = result.stdout.trim();
      if (state == 'running' || state == 'degraded') return null;
      if (const ['maintenance', 'stopping', 'offline'].contains(state)) {
        final failed = await _inContainer(
            target, instance, ['systemctl', '--failed', '--no-legend'],
            what: 'listing the failed units');
        return 'systemd reported "$state".'
            '${failed.isEmpty ? '' : '\nFailed units:\n$failed'}';
      }
      final container = await _containerState(target, instance);
      if (container != 'running 0') return 'Container state: $container.';
      if (!DateTime.now().isBefore(deadline)) {
        // A boot still "starting" after this long is one unit that never
        // finishes; name it, or the user is left guessing which of a
        // hundred it was.
        final jobs = await _inContainer(
            target, instance, ['systemctl', 'list-jobs', '--no-legend'],
            what: 'listing the pending jobs');
        return 'systemd did not finish booting within '
            '${readyTimeout.inMinutes} minutes'
            '${state.isEmpty ? '' : ' (state: $state)'}.'
            '${jobs.isEmpty ? '' : '\nStill starting:\n$jobs'}';
      }
      await Future.delayed(pollInterval);
    }
  }

  /// Run [args] inside [instance] for its output, '' when that fails: these
  /// are the diagnostics gathered on the way to an error, and a diagnostic
  /// that cannot be read is not a second error.
  Future<String> _inContainer(String target, String instance, List<String> args,
          {required String what}) =>
      _run(target, ['docker', 'exec', instance, ...args],
          what: what, allowFailure: true);

  /// `<status> <restart count>` of a container, e.g. `running 0`.
  Future<String> _containerState(String target, String instance) => _run(
        target,
        [
          'docker',
          'inspect',
          '--format',
          '{{.State.Status}} {{.RestartCount}}',
          instance,
        ],
        what: 'checking the container',
      );

  /// Poll [server] until the provider has given it a public address.
  ///
  /// A create answers immediately with `initializing` and no IP; connecting
  /// to '' is the first thing a naive deploy gets wrong.
  Future<CloudServer> waitForAddress(CloudServer server) async {
    if (server.address.isNotEmpty && !server.state.isTransient) return server;
    final deadline = DateTime.now().add(readyTimeout);
    var current = server;
    while (DateTime.now().isBefore(deadline)) {
      if (current.address.isNotEmpty && !current.state.isTransient) {
        return current;
      }
      await Future.delayed(pollInterval);
      current = await provider.getServer(server.id);
    }
    throw CloudException(
        '${server.name} did not come up within ${readyTimeout.inMinutes} '
        'minutes.');
  }

  /// Wait for sshd to answer and for cloud-init to have finished installing
  /// Docker, by testing for the marker file it touches last.
  Future<void> _waitForReady(String target) async {
    final deadline = DateTime.now().add(readyTimeout);
    String lastError = '';
    while (DateTime.now().isBefore(deadline)) {
      final result = await _exec(
        'ssh',
        cloudSshCommand(target, ['test', '-f', cloudReadyMarker]),
        timeout: const Duration(seconds: 30),
      );
      if (result.exitCode == 0) return;
      lastError = result.stderr.trim();
      await Future.delayed(pollInterval);
    }
    throw CloudException(
        'The server did not finish setting up within '
        '${readyTimeout.inMinutes} minutes.'
        '${lastError.isEmpty ? '' : '\n$lastError'}');
  }

  /// The SSH key ids a new server should accept, registering the user's own
  /// public key with the provider when it is not there yet.
  ///
  /// Without this the provider mails a root password instead, which nothing
  /// in this app can use — every step after the create is an SSH command, and
  /// the app's SSH options refuse password auth on purpose.
  Future<List<String>> _ensureSshKey() async {
    final publicKey = await _localPublicKey();
    if (publicKey.isEmpty) {
      throw const CloudException(
          'No SSH public key found. Create one with "ssh-keygen -t ed25519" '
          'and try again.');
    }
    final existing = await provider.listSshKeys();
    for (final key in existing) {
      if (key.fingerprint.isNotEmpty && _isLocalKey(key.fingerprint)) {
        return [key.id];
      }
    }
    // Names are unique per project, so a second machine uploading its own key
    // needs a name of its own.
    final created = await provider.createSshKey(
        'wslmanager-${_hostLabel()}-${DateTime.now().millisecondsSinceEpoch}',
        publicKey);
    return [created.id];
  }

  /// Whether a provider-reported fingerprint is the local key's.
  ///
  /// Hetzner reports an MD5 fingerprint, which cannot be recomputed here
  /// without a hash dependency, so the comparison is done against what the
  /// local `ssh-keygen` prints for the same file. When that is unavailable
  /// the answer is "no" and the key is uploaded again under a new name —
  /// wasteful but harmless, where a false *positive* would hand out a server
  /// nobody holds the key to.
  bool _isLocalKey(String fingerprint) =>
      _knownFingerprints.contains(_normaliseFingerprint(fingerprint));

  /// Fingerprints of the local public key, in every form `ssh-keygen` prints.
  final Set<String> _knownFingerprints = {};

  static String _normaliseFingerprint(String value) =>
      value.trim().toLowerCase().replaceAll('md5:', '').replaceAll('sha256:', '');

  /// The user's SSH public key, generating an ed25519 pair when they have
  /// none — the same thing the Apple backend does before it seeds a VM.
  Future<String> _localPublicKey() async {
    final sshDir = _sshDirectory();
    if (sshDir == null) return '';
    for (final name in const ['id_ed25519.pub', 'id_rsa.pub', 'id_ecdsa.pub']) {
      final file = File(p.join(sshDir.path, name));
      if (await file.exists()) {
        final content = (await file.readAsString()).trim();
        if (content.isNotEmpty) {
          await _rememberFingerprints(file.path);
          return content;
        }
      }
    }
    // No key at all: make one rather than sending the user to a terminal.
    final keyPath = p.join(sshDir.path, 'id_ed25519');
    final result = await _exec('ssh-keygen', [
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      keyPath,
      '-C',
      'wslmanager',
    ]);
    if (result.exitCode != 0) return '';
    final generated = File('$keyPath.pub');
    if (!await generated.exists()) return '';
    await _rememberFingerprints(generated.path);
    return (await generated.readAsString()).trim();
  }

  /// Ask `ssh-keygen` for the fingerprints of [publicKeyPath] in both hash
  /// forms, so a provider reporting either one is recognised.
  Future<void> _rememberFingerprints(String publicKeyPath) async {
    for (final hash in const ['md5', 'sha256']) {
      final result = await _exec(
          'ssh-keygen', ['-l', '-E', hash, '-f', publicKeyPath],
          timeout: const Duration(seconds: 15));
      if (result.exitCode != 0) continue;
      // "256 SHA256:abc… comment (ED25519)" — the fingerprint is field two.
      final fields = result.stdout.trim().split(RegExp(r'\s+'));
      if (fields.length > 1) {
        _knownFingerprints.add(_normaliseFingerprint(fields[1]));
      }
    }
  }

  /// The directory holding the user's key pair, or null when this machine
  /// has no home directory to look in.
  Directory? _sshDirectory() {
    final override = sshDirectoryOverride;
    if (override != null) return Directory(override);
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    return home.isEmpty ? null : Directory(p.join(home, '.ssh'));
  }

  String _hostLabel() {
    final name = Platform.localHostname.toLowerCase();
    final cleaned = name.replaceAll(RegExp(r'[^a-z0-9-]'), '-');
    return cleaned.isEmpty ? 'host' : cleaned;
  }

  Future<void> _upload(String localPath, String target, String remotePath) =>
      _transfer(
        localPath,
        (name) => [name, '$target:$remotePath'],
        'uploading the root filesystem',
      );

  Future<void> _download(String target, String remotePath, String localPath) =>
      _transfer(
        localPath,
        (name) => ['$target:$remotePath', name],
        'downloading the root filesystem',
      );

  /// Run one `scp`, naming the local side by *file name* from inside its own
  /// directory.
  ///
  /// scp splits an operand on the first colon into host and path, and a
  /// Windows path starts `C:` — upstream OpenSSH therefore reads
  /// `C:\Users\…\Ubuntu-cloud.tar` as "the file `\Users\…` on the host
  /// `C`". Microsoft's own Win32 port special-cases drive letters, but the
  /// `scp` first on PATH is just as often Git for Windows', which does not.
  /// A bare file name has no colon in it under any of them.
  Future<void> _transfer(
    String localPath,
    List<String> Function(String localName) operands,
    String what,
  ) async {
    final result = await _exec(
      'scp',
      ['-p', ...cloudSshOptions(), '--', ...operands(p.basename(localPath))],
      timeout: transferTimeout,
      workingDirectory: p.dirname(localPath),
    );
    if (result.exitCode != 0) {
      throw CloudException(_failureText(what, result));
    }
  }

  /// Run one command on the cloud server.
  Future<String> _run(
    String target,
    List<String> args, {
    required String what,
    bool allowFailure = false,
    Duration? timeout,
  }) async {
    final result = await _exec('ssh', cloudSshCommand(target, args),
        timeout: timeout ?? commandTimeout);
    if (result.exitCode != 0 && !allowFailure) {
      throw CloudException(_failureText(what, result));
    }
    return result.stdout.trim();
  }

  Future<ExecutionResult> _exec(String command, List<String> args,
      {Duration? timeout, String? workingDirectory}) {
    return _broker.run(ExecutionRequest(
      command: command,
      arguments: args,
      workingDirectory: workingDirectory,
      timeout: timeout ?? commandTimeout,
      runInShell: false,
    ));
  }

  String _failureText(String what, ExecutionResult result) {
    if (result.error is TimeoutException) {
      return 'Timed out while $what.';
    }
    final detail = result.stderr.trim().isNotEmpty
        ? result.stderr.trim()
        : result.stdout.trim();
    final suffix = detail.isEmpty ? '' : '\n$detail';
    // The kernel refusing the image's own programs: a rootfs of the other
    // architecture. Docker reports it as a failed start (exit 125), which
    // read literally would be "the server cannot run containers".
    final hint = _isExecFormatError(result)
        ? '\nThe server cannot run the programs in this root filesystem: its '
            'CPU architecture is not this machine\'s'
            '${localArchitecture.isEmpty ? '' : ' ($localArchitecture)'}. '
            'Delete the server and deploy again onto a server type of the '
            'same architecture.'
        : '';
    return 'Failed while $what (exit ${result.exitCode}).$suffix$hint';
  }

  static bool _isExecFormatError(ExecutionResult result) =>
      result.exitCode != 0 &&
      result.stderr.toLowerCase().contains('exec format error');

  /// The image a deployed instance is imported as. Tagged under one prefix so
  /// `docker images` on the server says where these came from.
  String _imageTag(String instance) => 'wslmanager/${instance.toLowerCase()}';

  String _localStagingPath(String name) =>
      p.join(getTmpPath().path, '$name-cloud.tar');

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A leftover file in the tmp folder is not worth failing a deploy that
      // otherwise worked, and not worth a message either.
    }
  }

  void _checkName(String value, String field) {
    if (!cloudNamePattern.hasMatch(value)) {
      throw ArgumentError.value(value, field, 'not a valid name');
    }
  }
}
