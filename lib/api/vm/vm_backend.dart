import 'dart:io';

import '../process_output.dart';

/// Used to store the instances of a backend in a list.
class Instances {
  List<String> running = [];
  List<String> all = [];
  Instances(this.all, this.running);
}

/// What a [VmBackend] can do beyond the shared lifecycle surface.
///
/// The UI reads these flags instead of checking `Platform.isWindows`: a
/// feature is tied to the *backend* driving the instances, not to the host OS
/// — remote WSL runs the WSL backend from a Linux host, and a future backend
/// (e.g. KVM) would bring its own combination.
class VmFeatures {
  /// `/etc/wsl.conf` / `.wslconfig` style configuration editing.
  final bool wslConfig;

  /// Quick actions that run scripted commands inside an instance.
  final bool quickActions;

  /// Packaging an instance as a distributable archive (.wsl packages).
  final bool packaging;

  /// Mounting external disks into instances.
  final bool mountDisk;

  /// The AI Workspace screen (runs inside a dedicated WSL distro).
  final bool aiWorkspace;

  /// Compacting an instance's virtual disk from the UI.
  final bool cleanup;

  /// Opening an instance in VS Code / a file explorer on the host.
  final bool hostIntegration;

  /// Whether templates are superseded here (WSL has distro packages;
  /// the Apple backend keeps templates as a first-class feature).
  final bool templatesDeprecated;

  /// Creating brand-new virtual machines (empty disk, installer ISO or
  /// restore image) rather than importing root filesystems.
  final bool createVm;

  /// An attachable serial console, for driving an instance from a terminal
  /// without any display window.
  final bool serialConsole;

  /// The backend can hand out an instance's root filesystem as a plain tar
  /// archive, and build a local instance back out of one. That is what makes
  /// an instance portable to somewhere else entirely — the cloud deploy
  /// imports one straight into a container on the server
  /// (bostrot/ai-tasks#62).
  ///
  /// WSL does it natively (`wsl --export --format tar`). The Apple backend
  /// cannot: its export is a raw disk, with a partition table and a
  /// bootloader, which no `docker import` can read — so it takes the long way
  /// round and tars the *running guest's* root filesystem over SSH instead.
  /// See [VmBackend.exportRootfs].
  final bool rootfsExport;

  /// Restoring a root filesystem needs an existing local instance as its
  /// base, because the backend cannot boot a bare filesystem — the Apple
  /// backend's VMs start through EFI and need the kernel and partition table
  /// only a real disk carries. The pull-back wording says so, because the
  /// user has to keep that instance around and stopped.
  final bool rootfsImportNeedsBase;

  /// The instance has a login account of its own — one the user may have to
  /// type at a console — so the app can show them what it is. WSL distros
  /// have no such thing: `wsl.exe` drops straight into a shell.
  final bool guestCredentials;

  /// A saved cloud-init configuration can be handed to a new instance and
  /// runs on its first boot. The Apple backend seeds every Linux VM through
  /// cloud-init already; on WSL it is cloud-init's own WSL datasource,
  /// reading `%USERPROFILE%\.cloud-init\<distro>.user-data` — a file this
  /// app can only write on the machine `wsl.exe` runs on.
  final bool cloudInit;

  const VmFeatures({
    this.wslConfig = false,
    this.quickActions = false,
    this.packaging = false,
    this.mountDisk = false,
    this.aiWorkspace = false,
    this.cleanup = false,
    this.hostIntegration = false,
    this.templatesDeprecated = false,
    this.createVm = false,
    this.serialConsole = false,
    this.guestCredentials = false,
    this.rootfsExport = false,
    this.rootfsImportNeedsBase = false,
    this.cloudInit = false,
  });
}

/// One command run inside an instance: what it printed and how it ended.
///
/// The sandbox tools need the exit code, not just the text — "the command
/// failed" and "the command printed nothing" are different answers to give a
/// model, and each backend reports them on its own channels.
class VmCommandOutput {
  final int exitCode;
  final String stdout;
  final String stderr;

  const VmCommandOutput(this.exitCode, this.stdout, this.stderr);

  bool get ok => exitCode == 0;

  /// stdout when there is any, else stderr — a failing command often says
  /// everything it has to say on the other channel.
  String get text => stdout.trim().isNotEmpty ? stdout.trim() : stderr.trim();
}

/// The backend-independent surface for managing virtual machine instances.
///
/// [WSLApi] implements it on top of `wsl.exe` (local or over SSH), and
/// `AppleVmApi` on top of Apple's Virtualization.framework via the bundled
/// `vmctl` helper. Screens, templates, the MCP server and the AI chat tools
/// talk to this type so they work on every platform; anything WSL-specific
/// stays on [WSLApi] and is gated behind [features].
abstract class VmBackend {
  /// Stable identifier, e.g. `wsl` or `applevirt`.
  String get backendId;

  /// Word used for an instance in backend-specific messages ("distro"/"VM").
  String get instanceNoun;

  /// File extension templates and exports use, without the dot.
  /// WSL exports ext4 tarballs; the Apple backend uses raw disk images.
  String get templateExtension => 'ext4';

  VmFeatures get features;

  /// Whether this backend is driving a remote host rather than this machine.
  bool get isRemote => false;

  /// Label of the remote target, or '' when local.
  String get remoteLabel => '';

  /// The most recent successful [list] answer, kept so transient failures can
  /// fall back to the last known state.
  Instances lastDistroList = Instances([], []);

  /// All instances plus which of them are running.
  Future<Instances> list(bool showDocker);

  /// Names of the currently running instances.
  Future<List<String>> listRunning();

  /// Start an instance and present it to the user (terminal window on WSL,
  /// VM window on the Apple backend).
  Future<void> start(String distribution,
      {String startPath = '', String startUser = '', String startCmd = ''});

  /// Stop one instance.
  Future<String> stop(String distribution);

  /// Stop everything the backend is running.
  Future<String> shutdown();

  /// Delete an instance permanently.
  Future<String> remove(String distribution);

  /// Export an instance to [location].
  Future<String> export(String distribution, String location, {String? format});

  /// Write [instance]'s root filesystem to [tarPath] as a plain tar archive —
  /// no partition table, no bootloader, nothing machine-specific: the thing
  /// `docker import` and `wsl --import` both read.
  ///
  /// Only meaningful when [VmFeatures.rootfsExport] is set. The default is
  /// the backend's own export asked for in tar format, which is exactly what
  /// WSL does; a backend whose export is a disk image (the Apple one)
  /// overrides this with a route of its own.
  ///
  /// [onStatus] carries the sub-steps a caller may want to show — a backend
  /// that has to boot the instance first spends minutes before the first byte
  /// is written.
  Future<void> exportRootfs(String instance, String tarPath,
      {void Function(String detail)? onStatus}) async {
    _requireRootfsSupport();
    await export(instance, tarPath, format: 'tar');
  }

  /// Build a local instance called [name] out of the root filesystem tarball
  /// at [tarPath], leaving every existing instance alone.
  ///
  /// [sourceInstance] is the local instance the rootfs originally came from,
  /// when the caller knows it. A backend that can boot a bare root filesystem
  /// ignores it; one that cannot (the Apple backend needs a kernel and a
  /// bootloader, which only a real disk carries) uses it as the base to
  /// restore onto.
  Future<void> importRootfs(String name, String tarPath,
      {String installLocation = '',
      String sourceInstance = '',
      void Function(String detail)? onStatus}) async {
    _requireRootfsSupport();
    await import(name, installLocation, tarPath);
  }

  void _requireRootfsSupport() {
    if (!features.rootfsExport) {
      throw UnsupportedError(
          '$backendId cannot move a $instanceNoun as a root filesystem.');
    }
  }

  /// Import an instance from [filename] as [distribution].
  Future<String> import(
      String distribution, String installLocation, String filename,
      {bool isVhd = false});

  /// Run one shell command inside an instance as root, returning stdout.
  Future<String> execCmdAsRoot(String distribution, String cmd);

  /// Run [command] inside [instance] through its shell, reporting the exit
  /// code alongside the output.
  ///
  /// Distinct from [execCmdAsRoot], which throws the exit code away: this is
  /// what the AI sandbox runs, and a model told only "(no output)" about a
  /// command that failed will happily build on top of it. [cwd] empty means
  /// the user's default directory.
  Future<VmCommandOutput> runInInstance(
    String instance,
    String command, {
    String user = 'root',
    String cwd = '',
    Duration timeout = const Duration(minutes: 5),
  });

  /// Read a whole text file from inside [instance], or null when it could not
  /// be read — a distinction callers depend on: a missing file is empty and
  /// may be created, an unreachable one must never be overwritten.
  Future<String?> readInstanceFile(String instance, String path);

  /// Write [content] to [path] inside [instance] as root, whole file at once.
  /// Returns whether the write actually happened.
  Future<bool> writeInstanceFile(String instance, String path, String content);

  /// Start a persistent interactive shell inside an instance. Callers drive
  /// stdin/stdout themselves and must kill the process when done.
  Future<Process> startShell(String distribution, {String? user});

  /// Human-readable disk size of an instance, or null when unknown.
  Future<String?> getSize(String distribution);

  /// Where an instance's storage lives on the host.
  String currentDistroPath(String distribution);

  /// The user commands run as by default.
  Future<String> getDefaultUser(String distribution);

  /// Run a snippet — a list of shell lines — inside [instance] as [user]
  /// (root by default), surfacing output in a terminal window. Used by the
  /// Snippets screen and the per-row quick-action menu; fire-and-forget.
  ///
  /// [env] is exported in front of the snippet, which is how the values the
  /// user typed into the snippet's env dialog reach it. Each backend encodes
  /// them for its own transport, so a value may contain anything — a
  /// password's `$` or a token's quote included.
  Future<void> runCommands(String instance, List<String> commands,
      {String? user, Map<String, String> env = const {}});

  /// Duplicate an instance under a new name.
  Future<String> copy(String distribution, String newName);

  /// Show an instance's storage in the host file manager.
  void startExplorer(String distribution);

  /// Synchronous, cheap on-disk size label for the list rows, or '' when
  /// unknown.
  String instanceSizeLabel(String distribution) => '';

  /// The full trailing label for a list row. Defaults to the size; backends
  /// with more to say (the Apple backend adds the guest IP) override it.
  String instanceMetaLabel(String distribution) =>
      instanceSizeLabel(distribution);

  /// Convert process bytes to readable text.
  ///
  /// Despite the name this is not UTF-8 only: wsl.exe's own messages are
  /// UTF-16LE and are decoded as such, see [decodeProcessOutput].
  String utf8Convert(List<int> bytes) {
    if (bytes.isEmpty) {
      return '';
    }

    final decoded = decodeProcessOutput(bytes);
    // Keep common whitespace while stripping other control characters.
    return decoded.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
  }
}
