import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/shell.dart';
import 'package:wsl2distromanager/api/vm/vm_backend.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/logging.dart';

/// One `<ip> <hostname>` line this app owns in the host's hosts file.
class HostsEntry {
  const HostsEntry({
    required this.instance,
    required this.ip,
    required this.hostname,
  });

  /// The instance the address belongs to, kept so the UI can name it.
  final String instance;
  final String ip;
  final String hostname;

  /// The literal hosts-file line, with the instance name trailing as a
  /// comment: the block is machine-written, but a person reading
  /// `drivers\etc\hosts` still has to be able to tell where it came from.
  String get line => '$ip\t$hostname\t# $instance';

  @override
  bool operator ==(Object other) =>
      other is HostsEntry &&
      other.instance == instance &&
      other.ip == ip &&
      other.hostname == hostname;

  @override
  int get hashCode => Object.hash(instance, ip, hostname);

  @override
  String toString() => line;
}

/// Why a sync wrote nothing. `unchanged` is the common one and is not a
/// failure: the file already says what it should, so the user is not asked
/// to elevate for a no-op.
enum HostsSkip { unsupported, remote, unchanged }

/// What one sync did, so the caller can say it without guessing.
class HostsSyncResult {
  const HostsSyncResult({required this.entries, required this.skipped});

  const HostsSyncResult.written(this.entries) : skipped = null;

  final List<HostsEntry> entries;

  /// Null when the file was rewritten.
  final HostsSkip? skipped;

  bool get changed => skipped == null;
}

/// Keeps the host's hosts file in step with the running instances, so a
/// distro or VM can be reached by name instead of by an address that DHCP
/// changes on every boot (bostrot/wsl2-distro-manager#214).
///
/// The entries live between two markers, and everything outside them is
/// copied through untouched — the hosts file belongs to the user and to
/// whatever else writes it, and this app owns exactly its own block.
///
/// Both hosts files need administrator rights to write, so a sync that
/// would change nothing never asks for them: the desired block is rendered
/// first and compared against what is already on disk.
///
/// Backend-neutral on purpose. The addresses come from the instance itself
/// through [VmBackend.runInInstance], which WSL answers through `wsl.exe`
/// and the Apple backend over SSH, so the same code serves a WSL distro on
/// Windows and a Virtualization.framework VM on macOS.
class HostsFileService {
  HostsFileService({
    VmBackend? backend,
    Shell? shell,
    String? hostsPath,
  })  : _backend = backend,
        shell = shell ?? ProcessShell(),
        hostsPath = hostsPath ?? defaultHostsPath();

  /// The one the app runs with. `main` starts its timer and the Settings
  /// section drives the same object, so the two can never end up with a
  /// timer each.
  static final HostsFileService instance = HostsFileService();

  final VmBackend? _backend;
  final Shell shell;

  /// The file that is read and rewritten. Injectable so a test never goes
  /// near the real one.
  final String hostsPath;

  VmBackend get backend => _backend ?? vmBackend();

  static const String prefEnabled = 'HostsFileSync';
  static const String prefSuffix = 'HostsFileSuffix';

  static const String blockBegin =
      '# BEGIN WSL Manager — managed entries, edited automatically';
  static const String blockEnd = '# END WSL Manager';

  /// Separates the two halves of [probeCommand]'s output. No quotes and no
  /// leading dash: the command crosses a `bash -c` on WSL and an ssh command
  /// line on the Apple backend, and neither is a place to rely on quoting
  /// surviving, or on `echo` not reading `--x` as a flag.
  static const String probeMarker = '__WSLM__';

  /// Asked of every instance in one go: its own hostname, then its
  /// addresses. `hostname -I` is the short answer everywhere it exists;
  /// busybox (Alpine) has no `-I`, so `ip` and then `hostname -i` stand in.
  static const String probeCommand = 'hostname 2>/dev/null; echo $probeMarker; '
      'hostname -I 2>/dev/null || ip -4 -o addr show scope global 2>/dev/null '
      '|| hostname -i 2>/dev/null';

  /// Where the hosts file lives on this host.
  static String defaultHostsPath() => Platform.isWindows
      ? r'C:\Windows\System32\drivers\etc\hosts'
      : '/etc/hosts';

  /// The suffix a fresh install uses. `.wsl` is what the tool the feature
  /// request pointed at uses; a Mac has no WSL to name, so its VMs get
  /// `.vm`.
  static String get defaultSuffix => Platform.isWindows ? 'wsl' : 'vm';

  /// Only a hosts file this app can actually reach is worth offering, and
  /// only for instances running on this machine: a remote WSL host's distro
  /// addresses are reachable from *that* machine, and writing them here
  /// would point names at addresses this one cannot route to.
  bool get isSupported =>
      (Platform.isWindows || Platform.isMacOS) && !backend.isRemote;

  bool get enabled => (prefs.getBool(prefEnabled) ?? false) && isSupported;

  String get suffix {
    final stored = prefs.getString(prefSuffix);
    if (stored == null) return defaultSuffix;
    return sanitizeSuffix(stored);
  }

  Future<void> setEnabled(bool value) => prefs.setBool(prefEnabled, value);

  Future<void> setSuffix(String value) =>
      prefs.setString(prefSuffix, sanitizeSuffix(value));

  /// A suffix is a DNS label, so it is lowercased and stripped of anything
  /// that cannot appear in one — including the leading dot people type.
  static String sanitizeSuffix(String value) {
    final cleaned = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9.-]'), '')
        .replaceAll(RegExp(r'^[.-]+'), '')
        .replaceAll(RegExp(r'[.-]+$'), '');
    return cleaned;
  }

  /// The name an instance is reachable under: its own hostname when the
  /// guest has a real one, else the instance name, made into a DNS label
  /// and given the suffix.
  static String hostnameFor(String instance, String guestHostname,
      {required String suffix}) {
    final guest = _label(guestHostname);
    final base =
        (guest.isEmpty || guest == 'localhost') ? _label(instance) : guest;
    if (base.isEmpty) return '';
    if (suffix.isEmpty) return base;
    if (base.endsWith('.$suffix')) return base;
    return '$base.$suffix';
  }

  static String _label(String value) {
    final cleaned = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9.-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^[.-]+'), '')
        .replaceAll(RegExp(r'[.-]+$'), '');
    return cleaned;
  }

  /// Splits [probeCommand]'s output into the guest hostname and the first
  /// routable IPv4 it reported. Either half may be missing — a guest that
  /// is still booting answers with neither.
  static HostsProbe parseProbe(String output) {
    final parts = output.split(probeMarker);
    final head = parts.isEmpty ? '' : parts.first;
    final tail = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    return HostsProbe(
        hostname: head.trim().split('\n').first.trim(), ip: ipv4From(tail));
  }

  static final RegExp _ipv4 = RegExp(r'\b(\d{1,3}(?:\.\d{1,3}){3})\b');

  /// The first address in [output] that a host can actually talk to:
  /// loopback, link-local and anything with an octet over 255 are not it.
  static String? ipv4From(String output) {
    for (final match in _ipv4.allMatches(output)) {
      final candidate = match.group(1)!;
      final octets = candidate.split('.').map(int.parse).toList();
      if (octets.any((o) => o > 255)) continue;
      if (octets[0] == 127) continue;
      if (octets[0] == 0) continue;
      if (octets[0] == 169 && octets[1] == 254) continue;
      return candidate;
    }
    return null;
  }

  /// The block as it should appear, markers included, with no trailing
  /// newline — [applyBlock] owns the line endings around it.
  static String renderBlock(List<HostsEntry> entries, String eol) {
    return [blockBegin, ...entries.map((e) => e.line), blockEnd].join(eol);
  }

  /// [content] with this app's block replaced by [entries], or appended when
  /// there is no block yet. An empty [entries] removes the block entirely,
  /// which is what turning the feature off has to do.
  ///
  /// Everything outside the markers survives byte for byte, including the
  /// file's own line endings: Windows hosts files are CRLF and a tool that
  /// silently rewrites the whole file as LF is a tool nobody trusts twice.
  static String applyBlock(String content, List<HostsEntry> entries) {
    final eol = content.contains('\r\n') ? '\r\n' : '\n';
    // Split on LF and drop the CR with it, so every line downstream is plain
    // text and [eol] alone decides what goes back between them. Keeping the
    // CR on the line instead left the last preserved line ending in CR CRLF.
    final lines = content
        .split('\n')
        .map((l) => l.endsWith('\r') ? l.substring(0, l.length - 1) : l)
        .toList();
    final begin = lines.indexWhere((l) => l.trimRight() == blockBegin);
    var kept = lines;

    if (begin != -1) {
      // An unterminated block — a half-written file, a hand edit that took
      // the end marker with it — takes only its own opening line with it.
      // Dropping everything after it instead would delete entries this app
      // never wrote.
      var end = begin;
      for (var i = begin + 1; i < lines.length; i++) {
        if (lines[i].trimRight() == blockEnd) {
          end = i;
          break;
        }
      }
      kept = [...lines.sublist(0, begin), ...lines.sublist(end + 1)];
    }

    // Trailing blank lines left behind by a removed block would otherwise
    // pile up one sync at a time.
    while (kept.isNotEmpty && kept.last.trim().isEmpty) {
      kept.removeLast();
    }

    final normalized = kept.join(eol);

    if (entries.isEmpty) {
      return normalized.isEmpty ? '' : '$normalized$eol';
    }
    final prefix = normalized.isEmpty ? '' : '$normalized$eol$eol';
    return '$prefix${renderBlock(entries, eol)}$eol';
  }

  /// Ask each of [instances] where it is and what it calls itself. An
  /// instance that does not answer — still booting, no network yet — is left
  /// out rather than written with a stale address.
  Future<List<HostsEntry>> collect(List<String> instances) async {
    final entries = <HostsEntry>[];
    final taken = <String>{};
    for (final instance in instances) {
      try {
        final out = await backend.runInInstance(instance, probeCommand,
            timeout: const Duration(seconds: 20));
        if (!out.ok) continue;
        final probe = parseProbe(out.stdout);
        final ip = probe.ip;
        if (ip == null) continue;
        final hostname = hostnameFor(instance, probe.hostname, suffix: suffix);
        // Two guests that report the same hostname would otherwise write two
        // lines for one name, and whichever came first would win silently.
        if (hostname.isEmpty || !taken.add(hostname)) continue;
        entries.add(HostsEntry(instance: instance, ip: ip, hostname: hostname));
      } catch (e, stack) {
        logDebug(e, stack, 'hosts_file_service');
      }
    }
    entries.sort((a, b) => a.hostname.compareTo(b.hostname));
    return entries;
  }

  /// Read the hosts file, or '' when it is not there yet. Reading needs no
  /// elevation on either platform.
  Future<String> readHostsFile() async {
    final file = File(hostsPath);
    if (!await file.exists()) return '';
    // A hand-edited hosts file can carry a comment in the machine's old code
    // page, which is not valid UTF-8. That must not take the whole feature
    // down, so the odd byte becomes U+FFFD instead of an exception.
    return const Utf8Decoder(allowMalformed: true)
        .convert(await file.readAsBytes());
  }

  /// Write [entries] into the hosts file, asking the user to elevate only
  /// when the file would actually change.
  Future<HostsSyncResult> apply(List<HostsEntry> entries) async {
    if (!isSupported) {
      return HostsSyncResult(
          entries: entries,
          skipped: backend.isRemote ? HostsSkip.remote : HostsSkip.unsupported);
    }
    // One write at a time. The staged file has one name, so the poll and a
    // press of "write now" landing together would have each pull it out from
    // under the other's elevated copy.
    final previous = _writes;
    final done = Completer<void>();
    _writes = done.future;
    await previous;
    try {
      return await _apply(entries);
    } finally {
      done.complete();
    }
  }

  Future<void> _writes = Future<void>.value();

  Future<HostsSyncResult> _apply(List<HostsEntry> entries) async {
    final current = await readHostsFile();
    final desired = applyBlock(current, entries);
    if (desired == current) {
      return HostsSyncResult(entries: entries, skipped: HostsSkip.unchanged);
    }
    await _writeElevated(desired);
    // The elevation path has more than one way to fail quietly — a prompt
    // the user dismissed, a copy that never ran — so whether it worked is
    // read back off the file rather than taken from an exit code.
    if (await readHostsFile() != desired) {
      throw HostsFileException('hostsfilenotwritten-text'.i18n());
    }
    return HostsSyncResult.written(entries);
  }

  /// Collect the running instances' addresses and write them out.
  Future<HostsSyncResult> sync({List<String>? instances}) async {
    if (!isSupported) {
      return HostsSyncResult(
          entries: const [],
          skipped: backend.isRemote ? HostsSkip.remote : HostsSkip.unsupported);
    }
    final running = instances ?? await backend.listRunning();
    return apply(await collect(running));
  }

  /// Take this app's block back out of the hosts file.
  Future<HostsSyncResult> clear() => apply(const []);

  /// The batch an elevated Windows shell runs: replace the file, then drop
  /// the resolver cache so a name that used to point somewhere else stops
  /// doing so. `copy` rather than `move`, because the hosts file's own ACL
  /// has to survive the write.
  static String windowsBatch(String stagedPath, String hostsPath) => '''
@echo off
copy /y "$stagedPath" "$hostsPath" > nul
if %errorlevel% neq 0 exit /b 1
ipconfig /flushdns > nul
exit /b 0
''';

  /// The shell line an elevated macOS run executes. Single quotes cannot
  /// appear in either path — both are app-controlled — so the quoting holds.
  static String macosCommand(String stagedPath, String hostsPath) =>
      "/bin/cp '$stagedPath' '$hostsPath' && "
      "/usr/bin/dscacheutil -flushcache && "
      "/usr/bin/killall -HUP mDNSResponder";

  /// AppleScript asks for the password itself, with the app's name on the
  /// prompt, which is the only elevation path a sandboxed GUI app has.
  static String osascriptScript(String stagedPath, String hostsPath) {
    final command =
        macosCommand(stagedPath, hostsPath).replaceAll(r'\', r'\\').replaceAll(
              '"',
              r'\"',
            );
    return 'do shell script "$command" with administrator privileges';
  }

  Future<void> _writeElevated(String content) async {
    final staged = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}wslm_hosts.txt');
    await staged.writeAsString(content);
    try {
      if (Platform.isWindows) {
        await _writeElevatedWindows(staged.path);
      } else {
        await _writeElevatedMacos(staged.path);
      }
    } finally {
      try {
        if (await staged.exists()) await staged.delete();
      } catch (_) {}
    }
  }

  /// The PowerShell one-liner that raises the batch to administrator.
  ///
  /// `$ErrorActionPreference` is what makes a dismissed prompt fail: without
  /// it `Start-Process` only writes an error, `$p` stays null, and
  /// `exit $p.ExitCode` exits *zero* — a cancelled elevation reported as a
  /// successful write.
  static String windowsElevationScript(String batPath) =>
      "\$ErrorActionPreference = 'Stop'; "
      '\$p = Start-Process "$batPath" -Verb RunAs -WindowStyle Hidden '
      '-Wait -PassThru; exit \$p.ExitCode';

  Future<void> _writeElevatedWindows(String stagedPath) async {
    final batFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}wslm_hosts.bat');
    await batFile.writeAsString(windowsBatch(stagedPath, hostsPath));
    try {
      final result = await shell.run(
          'powershell', ['-Command', windowsElevationScript(batFile.path)]);
      if (result.exitCode != 0) {
        throw HostsFileException(_text(result.stderr));
      }
    } finally {
      try {
        if (await batFile.exists()) await batFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _writeElevatedMacos(String stagedPath) async {
    final result = await shell
        .run('osascript', ['-e', osascriptScript(stagedPath, hostsPath)]);
    if (result.exitCode != 0) {
      throw HostsFileException(_text(result.stderr));
    }
  }

  static String _text(Object? stream) {
    final text = (stream ?? '').toString().trim();
    return text.isEmpty ? '' : text;
  }

  Timer? _timer;
  String _lastBlock = '';

  /// How often the running set is re-read. The hosts file is only rewritten
  /// when the rendered block changes, so a tick that finds nothing new costs
  /// one `hostname -I` per running instance and never prompts.
  static const Duration autoSyncInterval = Duration(seconds: 20);

  /// Follow the running instances for as long as the app is open.
  void startAutoSync() {
    if (_timer != null || !enabled) return;
    unawaited(_tick());
    _timer = Timer.periodic(autoSyncInterval, (_) => unawaited(_tick()));
  }

  void stopAutoSync() {
    _timer?.cancel();
    _timer = null;
    _lastBlock = '';
  }

  Future<void> _tick() async {
    if (!enabled) {
      stopAutoSync();
      return;
    }
    var block = '';
    try {
      final entries = await collect(await backend.listRunning());
      block = renderBlock(entries, '\n');
      // Nothing moved since the last tick: not even the hosts file is read.
      if (block == _lastBlock) return;
      await apply(entries);
      _lastBlock = block;
    } catch (e, stack) {
      logError(e, stack, 'hosts_file_service');
      // Remembered even though it failed: the usual failure is a prompt the
      // user dismissed, and asking again twenty seconds later, forever, is
      // worse than waiting for the next time something actually moves.
      _lastBlock = block;
    }
  }
}

/// The hosts file could not be written — almost always a declined elevation
/// prompt.
class HostsFileException implements Exception {
  HostsFileException(this.details);

  final String details;

  @override
  String toString() => details;
}

/// What one instance answered [HostsFileService.probeCommand] with.
class HostsProbe {
  const HostsProbe({required this.hostname, required this.ip});

  /// The name the guest calls itself, '' when it did not say.
  final String hostname;

  /// Its first routable IPv4, null while it has none.
  final String? ip;
}
