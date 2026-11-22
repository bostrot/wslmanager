// A "sandbox": an ordinary instance this app created to be an isolated
// playground for the AI chat — a WSL distro on Windows, a Linux VM on the
// Apple backend. The instance is real; the isolation is that the sandbox chat
// is handed only the `sandbox_*` tools (buildSandboxTools), which hardcode
// this one instance, so the model can run anything *inside* it but cannot see
// the host or any other instance.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/api/cancellation.dart';
import 'package:wsl2distromanager/api/app.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'dart:convert';
import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/mcp/todo_tools.dart';
import 'package:wsl2distromanager/api/todo_store.dart';
import 'package:wsl2distromanager/api/mcp/wsl_mcp_tools.dart';
import 'package:wsl2distromanager/api/mcp/wsl_terminal_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:wsl2distromanager/api/apple/apple_vm_api.dart';
import 'package:wsl2distromanager/api/apple/vm_image_catalog.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:wsl2distromanager/components/helpers.dart';

class SandboxService {
  SandboxService({VmBackend? backend, App? app, Dio? dio, VmImageCatalog? catalog})
      : _api = backend ?? vmBackend(),
        _app = app ?? App(),
        _dio = dio ?? Dio(),
        _catalog = catalog ?? vmImageCatalogBuilder();

  /// The backend the sandbox lives on. `wsl.exe` on Windows (or over SSH),
  /// `vmctl` on macOS — the two need different plumbing to *create* a
  /// sandbox, and nothing at all in common afterwards: the sandbox tools go
  /// through [VmBackend] either way.
  final VmBackend _api;
  final App _app;
  final Dio _dio;
  final VmImageCatalog _catalog;

  /// Registered names carry this prefix so a sandbox is recognisable in the
  /// distro list and never collides with a normal instance.
  static const String prefix = 'wslm-sandbox-';
  static const String _prefsKey = 'SandboxDistros';

  List<String> list() => prefs.getStringList(_prefsKey) ?? <String>[];

  bool isSandbox(String distro) => list().contains(distro);

  void _remember(String distro) {
    final all = list();
    if (!all.contains(distro)) {
      all.add(distro);
      prefs.setStringList(_prefsKey, all);
    }
  }

  void _forget(String distro) {
    final all = list()..remove(distro);
    prefs.setStringList(_prefsKey, all);
  }

  /// The catalog URL for [image] (an exact catalog key), or — when [image]
  /// is null — the newest Ubuntu entry, falling back to the first entry.
  String? _pickImageUrl(Map<String, String> links, String? image) {
    if (links.isEmpty) return null;
    if (image != null && links.containsKey(image)) return links[image];
    final ubuntu = links.entries
        .where((e) => e.key.toLowerCase().contains('ubuntu'))
        .toList()
      ..sort((a, b) => b.key.compareTo(a.key)); // newest label first
    return (ubuntu.isNotEmpty ? ubuntu.first : links.entries.first).value;
  }

  /// The distro name a sandbox called [name] registers under.
  String distroNameFor(String name) =>
      '$prefix${sanitizeDistroName(name)}';

  /// The stage of a sandbox creation in flight, or null when none is.
  ///
  /// App-global, not page state: creation takes minutes (a rootfs download),
  /// and living on the page meant switching tabs lost the progress display —
  /// the work carried on invisibly and its result surfaced nowhere.
  static final ValueNotifier<String?> creationStage =
      ValueNotifier<String?>(null);

  /// Whether a creation is currently running.
  static bool get isCreating => creationStage.value != null;

  /// Download progress of the current creation, 0..1, or null when unknown
  /// or idle — the rootfs is ~700 MB and a bare "downloading" told the user
  /// nothing for minutes.
  static final ValueNotifier<double?> creationProgress =
      ValueNotifier<double?>(null);

  static CancelToken? _creationCancelToken;
  static CancelSignal? _creationCancelSignal;

  /// Aborts the running creation: the download is torn down and the partial
  /// file deleted. Both backends have one in flight at most, and only the one
  /// that is running has a token to cancel.
  static void cancelCreation() {
    _creationCancelToken?.cancel();
    _creationCancelSignal?.cancel();
  }

  /// Creation refuses to start below this much free disk. The rootfs plus
  /// its imported VHD comfortably exceed 2 GB, and this machine has already
  /// demonstrated what 0 bytes free does to everything else (2026-08-31).
  static const int minFreeBytes = 3 * 1024 * 1024 * 1024;

  /// The image choices for the add-sandbox dialog, and what
  /// [createUbuntuSandbox]'s [image] accepts.
  ///
  /// Catalog keys on WSL (rootfs tarballs), cloud-image names on the Apple
  /// backend. Installer ISOs are left out on purpose: they need a human to
  /// click through an installer at the VM's console, which is no use to a
  /// sandbox that has to come up on its own.
  Future<List<String>> imageChoices() async {
    if (_api is AppleVmApi) {
      return VmImageCatalog.entries
          .where((entry) => entry.isCloudImage)
          .map((entry) => entry.name)
          .toList();
    }
    return (await _app.getDistroLinks()).keys.toList()..sort();
  }

  /// The catalog entry for [image] (a cloud-image name or slug), or — when
  /// [image] is null — the newest Ubuntu cloud image, falling back to any
  /// cloud image at all.
  VmIsoCatalogEntry? _pickVmImage(String? image) {
    if (image != null && image.trim().isNotEmpty) {
      final named = VmImageCatalog.entryFor(image) ??
          VmImageCatalog.entryById(image);
      // An installer ISO would sit at its own console waiting to be
      // installed; refuse rather than create a VM that never answers.
      return (named != null && named.isCloudImage) ? named : null;
    }
    final cloud =
        VmImageCatalog.entries.where((entry) => entry.isCloudImage).toList();
    if (cloud.isEmpty) return null;
    final ubuntu = cloud
        .where((entry) => entry.name.toLowerCase().contains('ubuntu'))
        .toList()
      ..sort((a, b) => b.name.compareTo(a.name)); // newest label first
    return ubuntu.isNotEmpty ? ubuntu.first : cloud.first;
  }

  /// Creates a sandbox from a catalog image ([image] is a catalog key on WSL,
  /// a cloud-image name on the Apple backend; null = newest Ubuntu). Returns
  /// the registered instance name. Progress is published on [creationStage] /
  /// [creationProgress] so any page (or none) can watch.
  Future<String> createUbuntuSandbox(String name, {String? image}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('A name is required.');
    if (isCreating) throw StateError('A sandbox is already being created.');
    final distro = distroNameFor(trimmed);

    creationStage.value = 'resolving';
    try {
      final api = _api;
      if (api is AppleVmApi) {
        await _createAppleSandbox(api, distro, image);
      } else {
        await _createWslSandbox(distro, trimmed, image);
      }
      _remember(distro);
      return distro;
    } finally {
      _creationCancelToken = null;
      _creationCancelSignal = null;
      creationProgress.value = null;
      creationStage.value = null;
    }
  }

  /// Windows: download a rootfs tarball and `wsl --import` it.
  Future<void> _createWslSandbox(
      String distro, String trimmed, String? image) async {
    final cancelToken = _creationCancelToken = CancelToken();
    final tmp = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'wslm-sandbox-${trimmed.hashCode}.tar.gz';
    try {
      // Refuse up front rather than fail mid-download: a full disk here took
      // the whole machine down with it, not just this feature.
      final api = _api;
      final free = api is WSLApi
          ? await api.freeSpaceBytes(
              prefs.getString('DistroPath') ?? Directory.systemTemp.path)
          : null;
      if (free != null && free < minFreeBytes) {
        throw Exception('sandbox-disk-space');
      }

      await _refuseIfTaken(distro);

      final links = await _app.getDistroLinks();
      final url = _pickImageUrl(links, image);
      if (url == null) {
        throw StateError('No matching image is available in the catalog.');
      }

      creationStage.value = 'downloading';
      await _dio.download(url, tmp, cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
        creationProgress.value = total > 0 ? received / total : null;
      });

      creationProgress.value = null;
      creationStage.value = 'importing';
      await _api.import(distro, '', tmp);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) throw const CancelledException();
      rethrow;
    } finally {
      try {
        File(tmp).deleteSync();
      } catch (_) {}
    }
  }

  /// macOS: download a cloud image and have `vmctl` seed a VM from it, then
  /// boot it headless.
  ///
  /// Unlike a WSL distro, a VM is not started by the first command that wants
  /// it — it has to boot, and cloud-init has to finish, before anything can
  /// reach it over SSH. So creation starts it and waits, best effort: a guest
  /// that has not answered by [bootProbeAttempts] is still a created sandbox
  /// (the image is downloaded, the VM exists), and the chat's first command
  /// reports the real state rather than this throwing away several GB of
  /// download over a slow boot.
  Future<void> _createAppleSandbox(
      AppleVmApi api, String distro, String? image) async {
    final cancel = _creationCancelSignal = CancelSignal();
    final entry = _pickVmImage(image);
    if (entry == null) {
      throw StateError('No matching image is available in the catalog.');
    }

    await _refuseIfTaken(distro);

    creationStage.value = 'downloading';
    final imagePath = await _catalog.download(entry, cancelSignal: cancel,
        onProgress: (received, total) {
      creationProgress.value = total > 0 ? received / total : null;
    });
    cancel.throwIfCancelled();

    creationProgress.value = null;
    creationStage.value = 'creating';
    await api.createLinuxVm(distro,
        imagePath: imagePath,
        diskSizeGb: sandboxDiskGb,
        cpus: sandboxCpus,
        memoryGb: sandboxMemoryGb);
    // Registered before the boot, not after it: a VM that fails to start is
    // still a VM on disk, and one this list never learned about is one the
    // page shows no delete button for — the name would stay taken with no
    // way back to it from the UI.
    _remember(distro);

    creationStage.value = 'starting';
    await api.startHeadless(distro);
    for (var attempt = 0; attempt < bootProbeAttempts; attempt++) {
      cancel.throwIfCancelled();
      final probe = await api.probeGuestAccess(distro);
      if (probe.ok) return;
      await Future<void>.delayed(bootProbeDelay);
    }
  }

  /// A name already on the backend is a collision, not something to import
  /// over: the existing instance would be replaced or the import would fail
  /// halfway.
  Future<void> _refuseIfTaken(String distro) async {
    final existing = await _api.list(false);
    if (existing.all.any((d) => d.toLowerCase() == distro.toLowerCase())) {
      throw StateError('A distro named "$distro" already exists.');
    }
  }

  /// Sizing for a sandbox VM on the Apple backend — the same shape the AI
  /// Workspace VM uses, which is enough for a package manager and a build.
  static const int sandboxDiskGb = 32;
  static const int sandboxCpus = 2;
  static const int sandboxMemoryGb = 4;

  /// How long creation waits for a freshly booted guest to answer over SSH.
  /// A cloud image runs cloud-init end to end before sshd is up; overridable
  /// so tests do not sit through a boot's worth of sleeps.
  static int bootProbeAttempts = 40;
  static Duration bootProbeDelay = const Duration(seconds: 3);

  /// Unregisters a sandbox distro, drops it from the list and deletes its
  /// chat transcript.
  Future<void> deleteSandbox(String distro) async {
    // `vmctl delete` refuses a running VM, and a sandbox is left running by
    // its own creation — so stop it first. A WSL distro is unregistered
    // running or not and needs no such step.
    if (_api is AppleVmApi) {
      try {
        await _api.stop(distro);
      } catch (_) {
        // Already stopped, or gone: the delete below says so properly.
      }
    }
    await _api.remove(distro);
    _forget(distro);
    SandboxChat.dropTranscript(distro);
  }
}

/// A chat confined to one sandbox distro: its own persistent transcript and
/// only the `sandbox_*` tools (plus the app's task-queue tools), reusing
/// [AiService]'s provider loop. "All the LLM sees is the inside of the
/// sandbox."
class SandboxChat {
  SandboxChat._(this.distro, {AiService? service})
      : _ai = service ?? AiService() {
    _load();
  }

  @visibleForTesting
  SandboxChat.forTesting(this.distro, {AiService? service})
      : _ai = service ?? AiService();

  /// One live instance per sandbox, so closing and reopening the panel comes
  /// back to the same conversation instead of a fresh empty one.
  static final Map<String, SandboxChat> _instances = {};
  factory SandboxChat.of(String distro) =>
      _instances.putIfAbsent(distro, () => SandboxChat._(distro));

  static String _prefsKeyFor(String distro) => 'SandboxChat_$distro';

  /// Sandboxes that have a stored transcript — the "last sessions" list.
  static List<String> sessions() => SandboxService()
      .list()
      .where((d) =>
          _instances[d]?.history.isNotEmpty == true ||
          (prefs.getString(_prefsKeyFor(d))?.isNotEmpty ?? false))
      .toList();

  /// Deletes the stored transcript (used when the sandbox itself goes).
  static void dropTranscript(String distro) {
    _instances.remove(distro);
    prefs.remove(_prefsKeyFor(distro));
  }

  final String distro;
  final AiService _ai;
  final List<AiMessage> _history = [];

  void _load() {
    final stored = prefs.getString(_prefsKeyFor(distro));
    if (stored == null || stored.isEmpty) return;
    try {
      final list = json.decode(stored) as List;
      _history
        ..clear()
        ..addAll(
            list.map((e) => AiMessage.fromJson(e as Map<String, dynamic>)));
    } catch (_) {}
  }

  void _persist() {
    prefs.setString(_prefsKeyFor(distro),
        json.encode(_history.map((m) => m.toJson()).toList()));
  }

  List<McpTool>? _toolsOverride;
  List<McpTool> get _tools => _toolsOverride ??= [
        // One backend instance for both: the tools and the terminal sessions
        // have to talk to the same host — wsl.exe on Windows, vmctl on macOS.
        ...() {
          final backend = vmBackend();
          return buildSandboxTools(
              backend, WslTerminalManager(wslApi: backend), distro);
        }(),
        // The task queue works in the sandbox chat too — the todo tools touch
        // only the app's own list, never the host.
        ...buildTodoTools(TodoStore.instance),
      ];

  @visibleForTesting
  set toolsForTesting(List<McpTool> value) => _toolsOverride = value;

  List<AiMessage> get history => List.unmodifiable(_history);

  bool get canSend =>
      AiService.featuresEnabled &&
      LicenseManager().isPro &&
      _ai.hasAiConfigured;

  /// What the sandbox is called in the prompt: a WSL distro on Windows, a VM
  /// on the Apple backend. The model reasons about the environment it is told
  /// it is in, so a macOS sandbox described as a WSL distro invites advice
  /// about `wsl.exe` that has nothing to act on.
  String get _environmentNoun => vmBackend() is AppleVmApi
      ? 'a Linux virtual machine'
      : 'a WSL distro';

  String get _systemPrompt => '''
You are an assistant confined to a single sandboxed Linux environment ($_environmentNoun named "$distro"). Everything you do happens INSIDE it through the sandbox_* tools — you cannot see or affect the user's own machine or any other instance, and there is no such thing to reach. Use sandbox_run_command to inspect and work inside the sandbox. After acting, say briefly what you did. Keep answers concise.
You also have a task queue (todo_list, todo_add, todo_set_done, todo_remove). When the user asks you to work through their tasks, read the list, do each one inside the sandbox, and mark it done with todo_set_done as soon as you finish it.''';

  Future<String> send(String query,
      {void Function()? onUpdate, CancelSignal? cancel}) async {
    if (!AiService.featuresEnabled) throw Exception('ai-disabled');
    if (!LicenseManager().isPro) throw Exception('pro-required');
    if (!_ai.hasAiConfigured) throw Exception('byok-required');
    _history.add(AiMessage(
        role: 'user', content: query, timestamp: DateTime.now()));
    _persist();
    onUpdate?.call();
    return _completeFromHistory(onUpdate: onUpdate, cancel: cancel);
  }

  /// Retry after a failed send: the user message is already in the history.
  Future<String> retryLast(
      {void Function()? onUpdate, CancelSignal? cancel}) async {
    if (!AiService.featuresEnabled) throw Exception('ai-disabled');
    if (!LicenseManager().isPro) throw Exception('pro-required');
    if (!_ai.hasAiConfigured) throw Exception('byok-required');
    return _completeFromHistory(onUpdate: onUpdate, cancel: cancel);
  }

  Future<String> _completeFromHistory(
      {void Function()? onUpdate, CancelSignal? cancel}) async {
    try {
      // A throwaway sandbox is neither a VM being created nor one being
      // edited, so its commands are not filed as a snippet the Snippets
      // screen would offer to run in a real instance (ai-tasks#77).
      final reply = await _ai.runAgentOn(_history, _tools,
          recordRun: false,
          onUpdate: onUpdate,
          systemPrompt: _systemPrompt,
          persist: _persist,
          cancel: cancel);
      _history.add(AiMessage(
          role: 'assistant', content: reply, timestamp: DateTime.now()));
      _persist();
      onUpdate?.call();
      return reply;
    } on CancelledException {
      // A cancel keeps what already happened; only the reply is absent.
      _persist();
      rethrow;
    } catch (e) {
      // Roll back partial tool notes but keep the user's message, so the
      // panel's retry (retryLast) re-runs it without a retype.
      while (_history.isNotEmpty && _history.last.role != 'user') {
        _history.removeLast();
      }
      _persist();
      rethrow;
    }
  }

  void clear() {
    _history.clear();
    _persist();
  }
}
