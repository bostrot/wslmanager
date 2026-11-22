// Turning a filled-in form into an engine's `run` argv.
//
// Kept apart from [ContainerService] because this is the half worth testing on
// its own: no process is launched here, and every rule about what a user may
// type lives in one place. The service does the running; this decides what it
// is allowed to run.
//
// ## Why the validation is strict
//
// Each field ends up as its own entry in the child's argv — `runInShell` is
// false locally, and the remote path rebuilds the argv on the far side
// (lib/api/remote_command.dart), so no shell ever re-splits these strings and
// quoting is not the concern. *Flag* injection is: an image called
// `--privileged` or a name of `--network=host` would be read by the engine as
// an option rather than a value, and the user would have handed themselves a
// container the form never offered. Hence the leading-dash refusal on every
// field, and a shape check on each of the structured ones.

import 'package:wsl2distromanager/api/containers/container_models.dart';

/// A form field that was filled in wrongly, named so the dialog can put the
/// message under the box it belongs to rather than in a toast.
class ContainerFieldError implements Exception {
  /// One of the `field*` constants on [ContainerCreateRequest].
  final String field;
  final String message;

  const ContainerFieldError(this.field, this.message);

  @override
  String toString() => message;
}

/// An image reference: `alpine`, `nginx:1.27`, `ghcr.io/owner/app@sha256:…`.
/// Deliberately looser than the registry grammar — the engine is the authority
/// on whether an image exists, and a wrong tag should come back in its own
/// words, not as a form error that guesses.
final RegExp _imagePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$');

/// Container and volume names, matching what the engines accept and what
/// [ContainerService] already requires of a ref it is handed.
final RegExp _namePattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$');

final RegExp _envKeyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

final RegExp _ipv4Pattern = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

/// An absolute container path, which is what the right-hand side of a `-v`
/// always is. Also what disambiguates a Windows source path: `C:\src:/dst`
/// has three colons' worth of ambiguity and only one `/dst`.
final RegExp _containerPathPattern = RegExp(r'^/[^:]*$');

/// A Windows source path, so `C:\data:/data` is not mistaken for a volume
/// called `C` mounted at `\data`.
final RegExp _windowsPathPattern = RegExp(r'^[A-Za-z]:[\\/][^:]*$');

/// Everything the create form collected, validated, ready to become argv.
class ContainerCreateRequest {
  static const String fieldImage = 'image';
  static const String fieldName = 'name';
  static const String fieldPorts = 'ports';
  static const String fieldVolumes = 'volumes';
  static const String fieldEnv = 'env';
  static const String fieldCommand = 'command';

  /// i18n keys the validators return, one per field plus the shared
  /// leading-dash refusal.
  static const String keyImage = 'containerimageinvalid-text';
  static const String keyName = 'containernameinvalid-text';
  static const String keyPort = 'containerportinvalid-text';
  static const String keyVolume = 'containervolumeinvalid-text';
  static const String keyEnv = 'containerenvinvalid-text';
  static const String keyCommand = 'containercommandinvalid-text';
  static const String keyFlagLike = 'containerflaglike-text';

  /// The image to run. The only required field.
  final String image;

  /// What to call the container, or empty to let the engine invent a name.
  final String name;

  /// `-p` values, already in `[ip:]host:container[/proto]` form.
  final List<String> ports;

  /// `-v` values, already in `source:/destination[:ro]` form.
  final List<String> volumes;

  /// `-e` values, already in `KEY=VALUE` form.
  final List<String> env;

  /// The command to run instead of the image's own, as argv. Empty means the
  /// image's entrypoint is left alone.
  final List<String> command;

  /// Whether the engine should delete the container once it exits (`--rm`).
  final bool removeOnExit;

  const ContainerCreateRequest({
    required this.image,
    this.name = '',
    this.ports = const [],
    this.volumes = const [],
    this.env = const [],
    this.command = const [],
    this.removeOnExit = false,
  });

  /// Validate raw form text and build the request.
  ///
  /// [ports], [volumes] and [env] arrive as the multi-line text of their box —
  /// one entry per line, blank lines ignored, so a trailing newline is not an
  /// error. Throws [ContainerFieldError] naming the first field that is wrong.
  factory ContainerCreateRequest.parse({
    required String image,
    String name = '',
    String ports = '',
    String volumes = '',
    String env = '',
    String command = '',
    bool removeOnExit = false,
  }) {
    final imageValue = image.trim();
    final imageError = validateImage(imageValue);
    if (imageError != null) {
      throw ContainerFieldError(fieldImage, imageError);
    }
    final nameValue = name.trim();
    final nameError = validateName(nameValue);
    if (nameError != null) {
      throw ContainerFieldError(fieldName, nameError);
    }
    return ContainerCreateRequest(
      image: imageValue,
      name: nameValue,
      ports: _validatedLines(ports, fieldPorts, validatePort),
      volumes: _validatedLines(volumes, fieldVolumes, validateVolume),
      env: _validatedLines(env, fieldEnv, validateEnv),
      command: parseCommand(command),
      removeOnExit: removeOnExit,
    );
  }

  static List<String> _validatedLines(
    String raw,
    String field,
    String? Function(String) validate,
  ) {
    final values = <String>[];
    for (final line in raw.split('\n')) {
      final value = line.trim();
      if (value.isEmpty) continue;
      final error = validate(value);
      if (error != null) throw ContainerFieldError(field, error);
      values.add(value);
    }
    return values;
  }

  /// The argv after the engine's executable, for `wslc`, `docker` and
  /// `podman` alike — `run` and every flag used here is common to all three.
  ///
  /// Always detached: a GUI has no terminal to give the container, so `-it`
  /// would leave the engine waiting on a stdin that never arrives and the
  /// dialog hanging with it. A short-lived command still runs, and its output
  /// is on the row's Logs button.
  List<String> toArguments() {
    return [
      'run',
      '--detach',
      if (removeOnExit) '--rm',
      if (name.isNotEmpty) ...['--name', name],
      for (final port in ports) ...['--publish', port],
      for (final volume in volumes) ...['--volume', volume],
      for (final variable in env) ...['--env', variable],
      image,
      ...command,
    ];
  }

  /// A one-line description of what will be run, for the confirmation line
  /// and for the status bar afterwards.
  String get summary {
    final parts = <String>[
      if (name.isNotEmpty) name,
      image,
      if (ports.isNotEmpty) 'ports=${ports.join(',')}',
      if (volumes.isNotEmpty) 'volumes=${volumes.length}',
      if (env.isNotEmpty) 'env=${env.length}',
      if (removeOnExit) '--rm',
    ];
    return parts.join(' · ');
  }

  // --- field rules, shared by [parse] and the dialog's own inline hints ---
  //
  // Every one returns an **i18n key**, not a sentence, the same way
  // `validateVmResize` does: the dialog calls `.i18n()` on it. Literal syntax
  // (`8080:80`, `KEY=value`) stays out of the translations and lives in the
  // boxes' placeholders, where it is the same in every language.

  /// Null when [value] is a usable image reference, else the key saying why.
  static String? validateImage(String value) {
    if (_startsWithDash(value)) return keyFlagLike;
    if (value.isEmpty || !_imagePattern.hasMatch(value)) return keyImage;
    return null;
  }

  /// Null when [value] is a usable container name. Empty is allowed — the
  /// engine then makes one up.
  static String? validateName(String value) {
    if (value.isEmpty) return null;
    if (_startsWithDash(value)) return keyFlagLike;
    if (!_namePattern.hasMatch(value)) return keyName;
    return null;
  }

  /// Null when [value] is a usable `-p` mapping.
  ///
  /// Accepts `80`, `8080:80`, `127.0.0.1:8080:80` and any of those with
  /// `/tcp` or `/udp`. Binding to a host address is worth keeping easy: a
  /// container published on `127.0.0.1` is not on the network.
  static String? validatePort(String value) {
    if (_startsWithDash(value)) return keyFlagLike;
    var rest = value;
    final slash = rest.lastIndexOf('/');
    if (slash != -1) {
      final protocol = rest.substring(slash + 1);
      rest = rest.substring(0, slash);
      if (protocol != 'tcp' && protocol != 'udp') return keyPort;
    }
    final parts = rest.split(':');
    if (parts.length == 3) {
      if (!_ipv4Pattern.hasMatch(parts[0]) || !_isIpv4(parts[0])) {
        return keyPort;
      }
      return _portNumbers([parts[1], parts[2]]);
    }
    if (parts.length == 2) return _portNumbers([parts[0], parts[1]]);
    if (parts.length == 1) return _portNumbers([parts[0]]);
    return keyPort;
  }

  /// Null when [value] is a usable `-v` mapping.
  static String? validateVolume(String value) {
    if (_startsWithDash(value)) return keyFlagLike;
    var rest = value;
    final mode = _trailingMode(rest);
    if (mode != null) {
      rest = rest.substring(0, rest.length - mode.length - 1);
    }
    final split = _splitVolume(rest);
    if (split == null) return keyVolume;
    final source = split[0];
    final destination = split[1];
    if (source.isEmpty) return keyVolume;
    if (!_containerPathPattern.hasMatch(destination)) return keyVolume;
    final looksLikePath =
        source.startsWith('/') || _windowsPathPattern.hasMatch(source);
    if (!looksLikePath && !_namePattern.hasMatch(source)) return keyVolume;
    return null;
  }

  /// Null when [value] is a usable `KEY=VALUE` pair. The value itself is not
  /// policed: it is one argv entry, and a password with a space in it is a
  /// perfectly ordinary thing to pass an image.
  static String? validateEnv(String value) {
    final equals = value.indexOf('=');
    if (equals <= 0) return keyEnv;
    if (!_envKeyPattern.hasMatch(value.substring(0, equals))) return keyEnv;
    return null;
  }

  /// Split a typed command into argv the way a shell would, minus the parts a
  /// shell does that would be a lie here: no variable expansion, no globbing,
  /// no operators. Single and double quotes group, and nothing else is special.
  ///
  /// `sh -c "echo hello world"` therefore reaches the engine as three
  /// arguments, which is what someone typing it expects.
  static List<String> parseCommand(String raw) {
    final tokens = <String>[];
    final current = StringBuffer();
    var hasToken = false;
    String? quote;
    for (final rune in raw.trim().runes) {
      final char = String.fromCharCode(rune);
      if (quote != null) {
        if (char == quote) {
          quote = null;
        } else {
          current.write(char);
        }
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
        hasToken = true;
        continue;
      }
      if (char == ' ' || char == '\t' || char == '\n' || char == '\r') {
        if (hasToken) {
          tokens.add(current.toString());
          current.clear();
          hasToken = false;
        }
        continue;
      }
      current.write(char);
      hasToken = true;
    }
    if (quote != null) {
      throw const ContainerFieldError(fieldCommand, keyCommand);
    }
    if (hasToken) tokens.add(current.toString());
    return tokens;
  }

  static bool _startsWithDash(String value) => value.startsWith('-');

  static String? _portNumbers(List<String> values) {
    for (final value in values) {
      final port = int.tryParse(value);
      if (port == null || port < 1 || port > 65535) return keyPort;
    }
    return null;
  }

  static bool _isIpv4(String value) {
    for (final part in value.split('.')) {
      final octet = int.tryParse(part);
      if (octet == null || octet > 255) return false;
    }
    return true;
  }

  /// The `:ro` / `:rw` suffix, or null when there is none.
  static String? _trailingMode(String value) {
    for (final mode in const ['ro', 'rw']) {
      if (value.endsWith(':$mode')) return mode;
    }
    return null;
  }

  /// Source and destination of a `-v`, split at the colon that starts the
  /// container path. Returns null when there is no such colon.
  ///
  /// Scanned from the **right**, because the container path is the last
  /// segment and a source may hold colons of its own: `D:/data:/data` splits
  /// after `D:/data`, and taking the first colon instead would hand back a
  /// source of `D` and a destination of `/data:/data` — which is no path at
  /// all, so a perfectly good Windows mapping would be rejected.
  static List<String>? _splitVolume(String value) {
    for (var i = value.length - 1; i >= 0; i--) {
      if (value[i] != ':') continue;
      final destination = value.substring(i + 1);
      if (destination.startsWith('/')) {
        return [value.substring(0, i), destination];
      }
    }
    return null;
  }
}

/// Thrown by [ContainerService.create] when the engine refused the run, so the
/// dialog can tell "your form is wrong" from "the engine said no".
class ContainerCreateException extends ContainerException {
  const ContainerCreateException(super.message);
}
