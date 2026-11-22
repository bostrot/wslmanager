import 'dart:convert';

/// One environment variable a snippet wants set before it runs.
///
/// A snippet author declares these in the `env:` block of the script's
/// `info.yml`; the app also finds undeclared ones in the script itself, and
/// those arrive here with nothing but a name.
class SnippetEnvVar {
  const SnippetEnvVar({
    required this.name,
    this.description = '',
    this.defaultValue = '',
    this.isRequired = false,
    this.secret = false,
  });

  /// The name the script reads, e.g. `RUNNER_TOKEN`.
  final String name;

  /// What to put in it, in the author's words. Empty for a variable that was
  /// found in the script rather than declared.
  final String description;

  /// Prefilled into the field, so a sensible value only has to be confirmed.
  final String defaultValue;

  /// Whether the snippet is worth starting without it.
  final bool isRequired;

  /// A token or a password: masked while typed and never remembered, so it
  /// cannot end up in prefs on disk.
  final bool secret;

  Map<String, dynamic> toJson() => {
        'name': name,
        if (description.isNotEmpty) 'description': description,
        if (defaultValue.isNotEmpty) 'default': defaultValue,
        if (isRequired) 'required': true,
        if (secret) 'secret': true,
      };
}

/// The environment side of running a snippet: which variables to ask for, and
/// the shell lines that set them.
///
/// Snippets used to carry their inputs as `token=""` lines the user had to
/// edit before pressing run — and, having edited them, kept a registration
/// token in prefs. Declared or detected variables are asked for instead, per
/// run (bostrot/ai-tasks#99).
class SnippetEnv {
  /// A shell identifier. Also the guard on everything that is interpolated
  /// into an `export`: the value travels encoded, the name cannot.
  static final RegExp _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// `$FOO` or `${FOO…}`, upper-case only — every lower-case name in the
  /// community scripts is a local, and the convention is worth trusting over
  /// a dialog full of noise. Two characters minimum for the same reason.
  static final RegExp _reference = RegExp(r'\$\{?([A-Z][A-Z0-9_]+)');

  /// `NAME=`, wherever it sits: on its own, after `export`, or as a
  /// one-command prefix. `=` with a space before it is a `test` comparison,
  /// not an assignment, and `==` never is.
  static final RegExp _assignment =
      RegExp(r'(?<![\w$])([A-Za-z_][A-Za-z0-9_]*)=(?!=)');

  /// The other two ways a script names a variable it fills itself: a loop
  /// variable and a `read`.
  static final RegExp _loopVariable =
      RegExp(r'\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b');
  static final RegExp _readVariables = RegExp(r'\bread\s+([^;|&<>()]*)');

  /// Names the shell, the login or `/etc/os-release` already provide. They
  /// are skipped while *detecting*; an author who really wants one as an
  /// input can still declare it in `env:` and it is asked for.
  static const Set<String> provided = {
    // Shell and login
    'HOME', 'PATH', 'USER', 'LOGNAME', 'PWD', 'OLDPWD', 'SHELL', 'SHLVL',
    'TERM', 'LANG', 'LANGUAGE', 'LC_ALL', 'LC_CTYPE', 'HOSTNAME', 'HOSTTYPE',
    'MACHTYPE', 'OSTYPE', 'IFS', 'RANDOM', 'REPLY', 'SECONDS', 'LINENO',
    'UID', 'EUID', 'PPID', 'FUNCNAME', 'BASH', 'BASH_SOURCE', 'BASH_VERSION',
    'TMPDIR', 'TMP', 'TEMP', 'PS1', 'PS2', 'MAIL', 'PAGER', 'EDITOR',
    'VISUAL', 'DISPLAY', 'SUDO_USER', 'SUDO_UID', 'SUDO_GID',
    'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME',
    // Set by the app's own environment and by apt
    'WSL_DISTRO_NAME', 'WSL_INTEROP', 'WSLENV', 'DEBIAN_FRONTEND',
    'DEBCONF_NONINTERACTIVE_SEEN',
    // /etc/os-release, which half the scripts source to branch on the distro
    'ID', 'ID_LIKE', 'NAME', 'VERSION', 'VERSION_ID', 'VERSION_CODENAME',
    'PRETTY_NAME', 'ANSI_COLOR', 'CPE_NAME', 'HOME_URL', 'SUPPORT_URL',
    'BUG_REPORT_URL', 'LOGO', 'BUILD_ID', 'VARIANT', 'VARIANT_ID',
    'DOCUMENTATION_URL', 'PRIVACY_POLICY_URL',
  };

  static bool isValidName(String name) => _name.hasMatch(name);

  /// Reads the `env:` block of an `info.yml`.
  ///
  /// Strict, like the rest of the manifest parsing in `quick_actions.dart`: a
  /// malformed block is a mistake in the manifest, and a snippet that
  /// silently dropped the variable it needs would run and fail halfway
  /// instead.
  static List<SnippetEnvVar> parse(dynamic raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw Exception('env must be a list of variables');
    }
    final vars = <SnippetEnvVar>[];
    final seen = <String>{};
    for (final entry in raw) {
      if (entry is! Map) {
        throw Exception('every env entry must be a mapping');
      }
      for (final key in ['description', 'default']) {
        if (entry[key] is Map || entry[key] is List) {
          throw Exception('env $key must be text');
        }
      }
      final name = entry['name'];
      if (name is! String || !isValidName(name)) {
        throw Exception('env entry has no usable name');
      }
      if (!seen.add(name)) {
        throw Exception('env declares $name twice');
      }
      final isRequired = entry['required'] ?? false;
      final secret = entry['secret'] ?? false;
      if (isRequired is! bool || secret is! bool) {
        throw Exception('env $name: required and secret are yes/no');
      }
      vars.add(SnippetEnvVar(
        name: name,
        description: _scalar(entry['description']),
        defaultValue: _scalar(entry['default']),
        isRequired: isRequired,
        secret: secret,
      ));
    }
    return vars;
  }

  /// [parse], but a malformed block costs only the dialog.
  ///
  /// Manifests come from a public repository and are read by the community
  /// browser, which drops a script it cannot parse: one bad `env:` block must
  /// not make a script vanish from the list. The snippet still runs, and the
  /// variables its script reads are found by [detect] instead.
  static List<SnippetEnvVar> parseOrEmpty(dynamic raw) {
    try {
      return parse(raw);
    } catch (_) {
      return const [];
    }
  }

  /// The block as it goes back into prefs. Flow-style JSON, which is valid
  /// YAML, so the same parser reads it back.
  static String toYamlValue(List<SnippetEnvVar> vars) =>
      jsonEncode(vars.map((v) => v.toJson()).toList());

  /// The block as the community repo writes it: one entry per variable,
  /// indented under `env:`. Values are JSON-quoted, which is also a valid
  /// YAML double-quoted scalar, so a description with a colon or a `#` in it
  /// stays one string.
  static String toBlockYaml(List<SnippetEnvVar> vars) {
    if (vars.isEmpty) return '';
    final lines = <String>['env:'];
    for (final variable in vars) {
      lines.add('  - name: ${variable.name}');
      if (variable.description.isNotEmpty) {
        lines.add('    description: ${jsonEncode(variable.description)}');
      }
      if (variable.defaultValue.isNotEmpty) {
        lines.add('    default: ${jsonEncode(variable.defaultValue)}');
      }
      if (variable.isRequired) lines.add('    required: true');
      if (variable.secret) lines.add('    secret: true');
    }
    return '${lines.join('\n')}\n';
  }

  /// Every variable to ask for before running [script]: the ones it declares,
  /// or — when it declares none — the ones it reads without setting them.
  ///
  /// A declared block is taken as complete. An author who writes one decides
  /// exactly what the dialog shows, and can leave an alias or an internal
  /// knob out of it instead of having the app guess at both.
  static List<SnippetEnvVar> prompts(
          List<SnippetEnvVar> declared, String script) =>
      declared.isNotEmpty ? declared : detect(script);

  /// Variables [script] reads from its environment without setting them
  /// itself — how a snippet written before `env:` existed still gets a
  /// dialog, and how a hand-written local snippet gets one at all.
  static List<SnippetEnvVar> detect(String script) {
    final code = _code(script);
    final assigned = _assigned(code);
    final found = <String>[];
    for (final match in _reference.allMatches(code)) {
      final name = match.group(1)!;
      if (provided.contains(name)) continue;
      if (assigned.contains(name)) continue;
      if (found.contains(name)) continue;
      found.add(name);
    }
    return found.map((name) => SnippetEnvVar(name: name)).toList();
  }

  /// The script without its comment lines. A variable named only in prose is
  /// not one the script reads, and the word "read" in a sentence is not a
  /// `read` command that would fill one.
  static String _code(String script) => script
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('#'))
      .join('\n');

  /// Names the script sets for itself.
  ///
  /// `TOKEN="${TOKEN:-}"` does not count: falling back to its own value is
  /// how a script says "from the environment, or empty", which is exactly the
  /// variable we want to ask for.
  static Set<String> _assigned(String script) {
    final assigned = <String>{};
    for (final line in script.split('\n')) {
      for (final match in _assignment.allMatches(line)) {
        final name = match.group(1)!;
        final rest = line.substring(match.end);
        if (RegExp('\\\$\\{?${RegExp.escape(name)}\\b').hasMatch(rest)) {
          continue;
        }
        assigned.add(name);
      }
      for (final match in _loopVariable.allMatches(line)) {
        assigned.add(match.group(1)!);
      }
      for (final match in _readVariables.allMatches(line)) {
        // Options and prompts are not variable names; a bare word is.
        for (final word in match.group(1)!.split(RegExp(r'\s+'))) {
          if (isValidName(word)) assigned.add(word);
        }
      }
    }
    return assigned;
  }

  /// What the user actually filled in: empty entries drop out, so an
  /// untouched optional variable stays unset in the guest instead of being
  /// exported as an empty string.
  static Map<String, String> filled(Map<String, String> entered) {
    final values = <String, String>{};
    entered.forEach((name, value) {
      if (!isValidName(name) || value.isEmpty) return;
      values[name] = value;
    });
    return values;
  }

  /// The `export` lines that put [env] in front of a snippet.
  ///
  /// Each value travels base64-encoded and is decoded in the guest, for the
  /// same reason the Apple backend sends the whole script that way: a token
  /// or a password is arbitrary text, and a `$`, a backtick or a quote in it
  /// would otherwise be read by one of the shells it passes through.
  static List<String> exportLines(Map<String, String> env) {
    final lines = <String>[];
    env.forEach((name, value) {
      if (!isValidName(name) || value.isEmpty) return;
      final encoded = base64.encode(utf8.encode(value));
      lines.add('export $name="\$(printf %s $encoded | base64 -d)"');
    });
    if (lines.isEmpty) return lines;
    return ['# Values entered for this run.', ...lines];
  }

  static String _scalar(dynamic value) => value == null ? '' : value.toString();
}
