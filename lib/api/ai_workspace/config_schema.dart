// A tool's configuration described as a tree the UI can render without
// knowing anything about the tool.
//
// Every AI Workspace tool keeps its settings in its own file with its own
// keys, and those keys change with every release. Hard-coding a form per tool
// would be wrong the day after it shipped, so the shape comes from the tool
// itself: OpenCode publishes a JSON Schema, OpenClaw prints one
// (`openclaw config schema`), and anything that publishes none gets a schema
// inferred from the values its config file actually holds.

import 'dart:convert';

/// How one setting is edited.
enum ConfigFieldKind {
  /// A single-line string.
  text,

  /// `integer` in JSON Schema — whole numbers only.
  integer,

  /// `number` — decimals allowed.
  number,

  boolean,

  /// A fixed set of values (`enum`, or an `anyOf` of `const`s).
  choice,

  /// Anything the form cannot express as a single control — arrays, free-form
  /// maps, unions of objects. Edited as raw JSON, so no setting is
  /// unreachable just because it is shaped oddly.
  json,
}

/// One editable setting.
class ConfigField {
  /// Path from the config root, e.g. `['gateway', 'auth', 'mode']`.
  final List<String> path;
  final String label;
  final String? description;
  final ConfigFieldKind kind;

  /// Allowed values for [ConfigFieldKind.choice], in schema order.
  final List<String> choices;

  /// The tool's own default, shown as placeholder text so an empty field
  /// reads as "whatever the tool does by default" rather than "empty".
  final Object? defaultValue;

  /// Obscured in the UI. Set for keys that name a credential — those values
  /// are also never written back unless the user typed a new one, because
  /// what was read is usually a redaction rather than the secret itself.
  final bool secret;

  /// Shown but not editable: the setting is real, and this app has no safe
  /// way to change it (Open WebUI's container environment, for one).
  final bool readOnly;

  const ConfigField({
    required this.path,
    required this.label,
    this.description,
    required this.kind,
    this.choices = const [],
    this.defaultValue,
    this.secret = false,
    this.readOnly = false,
  });

  /// Dotted form of [path] — the key the UI and the save patch agree on.
  String get key => path.join('.');
}

/// A group of settings: one object in the config file.
class ConfigSection {
  final List<String> path;
  final String label;
  final String? description;
  final List<ConfigField> fields;
  final List<ConfigSection> sections;

  const ConfigSection({
    required this.path,
    required this.label,
    this.description,
    this.fields = const [],
    this.sections = const [],
  });

  String get key => path.join('.');

  /// Nothing to render — an object whose properties were all dropped.
  bool get isEmpty =>
      fields.isEmpty && sections.every((section) => section.isEmpty);

  /// Every field under this section, depth first, in schema order.
  Iterable<ConfigField> get allFields sync* {
    yield* fields;
    for (final section in sections) {
      yield* section.allFields;
    }
  }
}

/// The whole editable shape of one tool's configuration.
class ConfigSchema {
  final ConfigSection root;

  /// True when the source schema was deeper than [maxDepth] allowed, so some
  /// objects are edited as raw JSON instead of as their own section. The
  /// dialog says so rather than pretending the tree is complete.
  final bool truncated;

  const ConfigSchema({required this.root, this.truncated = false});

  static const ConfigSchema empty =
      ConfigSchema(root: ConfigSection(path: [], label: ''));

  Iterable<ConfigField> get fields => root.allFields;

  bool get isEmpty => root.isEmpty;

  ConfigField? fieldAt(String key) {
    for (final field in fields) {
      if (field.key == key) return field;
    }
    return null;
  }

  /// Builds the tree from a JSON Schema document.
  ///
  /// Handles the two dialects the tools actually publish: draft-07
  /// (`definitions`, OpenClaw) and 2020-12 (`$defs`, OpenCode). `$ref` is
  /// resolved against the document itself and guarded against the recursive
  /// definitions both of them contain — OpenCode's `Config.agent` references
  /// a type that references `Config` again, which without the guard is an
  /// infinite tree.
  ///
  /// [maxDepth] is how many levels of sections are built; objects below it
  /// become a single [ConfigFieldKind.json] field, which keeps them editable
  /// without expanding a schema that is 2 MB of nesting (OpenClaw's is).
  factory ConfigSchema.fromJsonSchema(
    Map<String, dynamic> document, {
    int maxDepth = 3,
  }) {
    final builder = _SchemaBuilder(document, maxDepth);
    final root = builder.section(document, const [], '');
    return ConfigSchema(root: root, truncated: builder.truncated);
  }

  /// Builds the tree from the values a config file already holds.
  ///
  /// The fallback for a tool that publishes no schema: the keys it is using
  /// are the keys worth showing, and their current types say how to edit
  /// them. Types only — no value is copied into the schema.
  factory ConfigSchema.inferred(
    Map<String, dynamic> values, {
    int maxDepth = 3,
    bool readOnly = false,
  }) {
    ConfigSection build(Map<String, dynamic> map, List<String> path, int depth) {
      final fields = <ConfigField>[];
      final sections = <ConfigSection>[];
      for (final entry in map.entries) {
        final childPath = [...path, entry.key];
        final value = entry.value;
        if (value is Map<String, dynamic> && depth < maxDepth) {
          if (value.isEmpty) continue;
          sections.add(build(value, childPath, depth + 1));
          continue;
        }
        fields.add(ConfigField(
          path: childPath,
          label: humanizeKey(entry.key),
          kind: _inferKind(value),
          secret: isSecretKey(entry.key),
          readOnly: readOnly,
        ));
      }
      return ConfigSection(
        path: path,
        label: path.isEmpty ? '' : humanizeKey(path.last),
        fields: fields,
        sections: sections,
      );
    }

    return ConfigSchema(root: build(values, const [], 0));
  }

  static ConfigFieldKind _inferKind(Object? value) {
    if (value is bool) return ConfigFieldKind.boolean;
    if (value is int) return ConfigFieldKind.integer;
    if (value is num) return ConfigFieldKind.number;
    if (value is String) return ConfigFieldKind.text;
    return ConfigFieldKind.json;
  }
}

/// `gatewayPort` / `gateway_port` / `gateway-port` all read as "Gateway Port".
/// Only used where the schema offers no `title` of its own.
String humanizeKey(String key) {
  final spaced = key
      .replaceAll(RegExp(r'[_\-.]+'), ' ')
      .replaceAllMapped(RegExp(r'(?<=[a-z0-9])([A-Z])'), (m) => ' ${m[1]}')
      .trim();
  if (spaced.isEmpty) return key;
  return spaced
      .split(RegExp(r'\s+'))
      .map((word) =>
          word.length <= 1 ? word.toUpperCase() : word[0].toUpperCase() + word.substring(1))
      .join(' ');
}

/// Whether a key names a credential. Deliberately broad: showing a token in
/// plain text in a dialog someone screen-shares is the expensive mistake, and
/// obscuring one field too many costs a click on the reveal button.
bool isSecretKey(String key) =>
    RegExp(r'(token|secret|password|passphrase|api[-_]?key|credential)',
            caseSensitive: false)
        .hasMatch(key);

/// Reads [path] out of a decoded config document, or null when any step is
/// missing.
Object? valueAtPath(Map<String, dynamic> data, List<String> path) {
  Object? current = data;
  for (final segment in path) {
    if (current is! Map) return null;
    if (!current.containsKey(segment)) return null;
    current = current[segment];
  }
  return current;
}

/// Turns `{'gateway.port': 19001}` into `{'gateway': {'port': 19001}}`.
///
/// The shape every writer here wants: OpenClaw's `config patch` merges a
/// nested object recursively, and a whole-file write merges the same object
/// into the document it just read. Changed keys only, so nothing the user did
/// not touch is rewritten.
Map<String, dynamic> nestedPatch(Map<String, Object?> changes) {
  final root = <String, dynamic>{};
  for (final entry in changes.entries) {
    final path = entry.key.split('.');
    var node = root;
    for (var i = 0; i < path.length - 1; i++) {
      final next = node[path[i]];
      if (next is Map<String, dynamic>) {
        node = next;
      } else {
        final created = <String, dynamic>{};
        node[path[i]] = created;
        node = created;
      }
    }
    node[path.last] = entry.value;
  }
  return root;
}

/// Merges [patch] into [target] in place, the way both writers apply it:
/// objects merge recursively, scalars replace, and null removes the key.
///
/// Null is a deletion rather than a written `null` because that is what
/// clearing a field in the form means, and it is what OpenClaw's own
/// `config patch` does with one — a file writer that left `"model": null`
/// behind would hand the tool a value it never accepts.
void applyPatch(Map<String, dynamic> target, Map<String, dynamic> patch) {
  for (final entry in patch.entries) {
    final existing = target[entry.key];
    final value = entry.value;
    if (value == null) {
      target.remove(entry.key);
      continue;
    }
    if (existing is Map<String, dynamic> && value is Map<String, dynamic>) {
      applyPatch(existing, value);
    } else {
      target[entry.key] = value;
    }
  }
}

/// Decodes a config file that may be JSONC/JSON5: `//` and `/* */` comments
/// and trailing commas are all things these tools write into their own
/// defaults (OpenCode ships `opencode.jsonc`, OpenClaw documents JSON5).
///
/// Strings are walked rather than regex-replaced so a `//` inside a value —
/// every URL has one — survives.
Map<String, dynamic> decodeRelaxedJson(String source) {
  final out = <String>[];
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    if (char == '"' || char == "'") {
      final quote = char;
      out.add(char);
      i++;
      while (i < source.length) {
        final inner = source[i];
        out.add(inner);
        i++;
        if (inner == r'\' && i < source.length) {
          out.add(source[i]);
          i++;
          continue;
        }
        if (inner == quote) break;
      }
      continue;
    }
    // A trailing comma, dropped where it is found. Doing this with one regex
    // over the finished text also rewrote a `, }` that was inside a string
    // value — `{"note": "a, }"}` came back as `{"note": "a }"}`.
    if (char == '}' || char == ']') {
      var back = out.length - 1;
      while (back >= 0 && out[back].trim().isEmpty) {
        back--;
      }
      if (back >= 0 && out[back] == ',') out.removeAt(back);
    }
    if (char == '/' && i + 1 < source.length) {
      final next = source[i + 1];
      if (next == '/') {
        while (i < source.length && source[i] != '\n') {
          i++;
        }
        continue;
      }
      if (next == '*') {
        i += 2;
        while (i + 1 < source.length &&
            !(source[i] == '*' && source[i + 1] == '/')) {
          i++;
        }
        i = i + 2 <= source.length ? i + 2 : source.length;
        continue;
      }
    }
    out.add(char);
    i++;
  }

  final decoded = jsonDecode(out.join());
  if (decoded is Map<String, dynamic>) return decoded;
  throw const FormatException('Config file is not a JSON object');
}

/// Walks a JSON Schema document into [ConfigSection]s.
class _SchemaBuilder {
  final Map<String, dynamic> document;
  final int maxDepth;
  bool truncated = false;

  /// `$ref`s currently being expanded. Both published schemas are recursive.
  final Set<String> _active = {};

  /// `$ref`s of the sections open on the current path — the same guard one
  /// level up, so a type that contains itself stops at its first repeat
  /// rather than at [maxDepth].
  final Set<String> _open = {};

  _SchemaBuilder(this.document, this.maxDepth);

  ConfigSection section(
    Map<String, dynamic> node,
    List<String> path,
    String label, {
    int depth = 0,
    String? description,
  }) {
    final resolved = resolve(node);
    final properties = resolved['properties'];
    final fields = <ConfigField>[];
    final sections = <ConfigSection>[];
    if (properties is Map<String, dynamic>) {
      for (final entry in properties.entries) {
        // The schema pointer a config file carries to get editor completion.
        // Editing it is never what anyone came for.
        if (entry.key == r'$schema') continue;
        final child = entry.value;
        if (child is! Map<String, dynamic>) continue;
        final childPath = [...path, entry.key];
        final childNode = resolve(child);
        final childLabel =
            (childNode['title'] as String?) ?? humanizeKey(entry.key);
        final childDescription = childNode['description'] as String?;
        if (_isObjectWithProperties(childNode)) {
          // A property that points back at a type already open on this path
          // (OpenCode's `agent` is a `Config` again) would otherwise expand
          // into `agent.agent.agent...` until [maxDepth] stopped it, which is
          // depth without meaning. It stays editable as raw JSON.
          final childRef = child[r'$ref'];
          final cyclic = childRef is String && _open.contains(childRef);
          if (depth + 1 > maxDepth || cyclic) {
            truncated = true;
            fields.add(ConfigField(
              path: childPath,
              label: childLabel,
              description: childDescription,
              kind: ConfigFieldKind.json,
              secret: isSecretKey(entry.key),
            ));
            continue;
          }
          if (childRef is String) _open.add(childRef);
          final built = section(
            childNode,
            childPath,
            childLabel,
            depth: depth + 1,
            description: childDescription,
          );
          if (childRef is String) _open.remove(childRef);
          if (!built.isEmpty) sections.add(built);
          continue;
        }
        fields.add(_field(childNode, childPath, childLabel, childDescription));
      }
    }
    return ConfigSection(
      path: path,
      label: label,
      description: description,
      fields: fields,
      sections: sections,
    );
  }

  bool _isObjectWithProperties(Map<String, dynamic> node) {
    final properties = node['properties'];
    return properties is Map<String, dynamic> && properties.isNotEmpty;
  }

  ConfigField _field(
    Map<String, dynamic> node,
    List<String> path,
    String label,
    String? description,
  ) {
    final choices = _choices(node);
    final kind = choices.isNotEmpty
        ? ConfigFieldKind.choice
        : _kindOf(_typeOf(node));
    return ConfigField(
      path: path,
      label: label,
      description: description,
      kind: kind,
      choices: choices,
      defaultValue: node['default'],
      secret: isSecretKey(path.last),
    );
  }

  /// `enum`, or the `anyOf`/`oneOf` of single-value `const`s that both
  /// TypeScript schema generators emit for a string union
  /// (`"local" | "remote"` in OpenClaw's `gateway.mode`).
  List<String> _choices(Map<String, dynamic> node) {
    final direct = node['enum'];
    if (direct is List && direct.isNotEmpty) {
      return direct.whereType<Object>().map((v) => '$v').toList();
    }
    for (final key in ['anyOf', 'oneOf']) {
      final branches = node[key];
      if (branches is! List || branches.isEmpty) continue;
      final values = <String>[];
      var allConst = true;
      for (final branch in branches) {
        if (branch is! Map<String, dynamic>) {
          allConst = false;
          break;
        }
        final resolved = resolve(branch);
        if (resolved.containsKey('const')) {
          values.add('${resolved['const']}');
          continue;
        }
        final nested = resolved['enum'];
        if (nested is List && nested.isNotEmpty) {
          values.addAll(nested.map((v) => '$v'));
          continue;
        }
        allConst = false;
        break;
      }
      if (allConst && values.isNotEmpty) return values;
    }
    return const [];
  }

  /// The type to edit as. A union that is not a set of constants (OpenCode's
  /// `autoupdate` is `boolean | object`) keeps its first scalar branch, so it
  /// stays a switch rather than dropping to raw JSON.
  String? _typeOf(Map<String, dynamic> node) {
    final type = node['type'];
    if (type is String) return type;
    if (type is List) {
      for (final entry in type) {
        if (entry is String && entry != 'null') return entry;
      }
      return null;
    }
    for (final key in ['anyOf', 'oneOf']) {
      final branches = node[key];
      if (branches is! List) continue;
      for (final branch in branches) {
        if (branch is! Map<String, dynamic>) continue;
        final resolved = resolve(branch);
        final branchType = resolved['type'];
        if (branchType is String &&
            branchType != 'null' &&
            branchType != 'object' &&
            branchType != 'array') {
          return branchType;
        }
      }
    }
    return null;
  }

  ConfigFieldKind _kindOf(String? type) {
    switch (type) {
      case 'boolean':
        return ConfigFieldKind.boolean;
      case 'integer':
        return ConfigFieldKind.integer;
      case 'number':
        return ConfigFieldKind.number;
      case 'string':
        return ConfigFieldKind.text;
      default:
        return ConfigFieldKind.json;
    }
  }

  /// Follows `$ref` and folds `allOf` members into one node.
  ///
  /// A ref already being expanded resolves to an empty node, which ends the
  /// recursion and leaves that property as a raw-JSON field rather than
  /// hanging the app.
  Map<String, dynamic> resolve(Map<String, dynamic> node, {int hops = 0}) {
    final ref = node[r'$ref'];
    if (ref is String && hops < 16) {
      if (_active.contains(ref)) return const {};
      final target = _lookup(ref);
      if (target == null) return node;
      _active.add(ref);
      try {
        final resolved = resolve(target, hops: hops + 1);
        final merged = <String, dynamic>{...resolved};
        for (final entry in node.entries) {
          if (entry.key == r'$ref') continue;
          merged[entry.key] = entry.value;
        }
        return _foldAllOf(merged, hops);
      } finally {
        _active.remove(ref);
      }
    }
    return _foldAllOf(node, hops);
  }

  Map<String, dynamic> _foldAllOf(Map<String, dynamic> node, int hops) {
    final allOf = node['allOf'];
    if (allOf is! List || allOf.isEmpty || hops >= 16) return node;
    final merged = <String, dynamic>{...node}..remove('allOf');
    final properties = <String, dynamic>{
      if (merged['properties'] is Map<String, dynamic>)
        ...merged['properties'] as Map<String, dynamic>,
    };
    for (final member in allOf) {
      if (member is! Map<String, dynamic>) continue;
      final resolved = resolve(member, hops: hops + 1);
      final memberProperties = resolved['properties'];
      if (memberProperties is Map<String, dynamic>) {
        properties.addAll(memberProperties);
      }
      for (final entry in resolved.entries) {
        if (entry.key == 'properties') continue;
        merged.putIfAbsent(entry.key, () => entry.value);
      }
    }
    if (properties.isNotEmpty) merged['properties'] = properties;
    return merged;
  }

  /// Local pointers only (`#/$defs/X`, `#/definitions/X`). A schema that
  /// points at another document gets no network call from here.
  Map<String, dynamic>? _lookup(String ref) {
    if (!ref.startsWith('#/')) return null;
    Object? current = document;
    for (final rawSegment in ref.substring(2).split('/')) {
      final segment =
          rawSegment.replaceAll('~1', '/').replaceAll('~0', '~');
      if (current is! Map<String, dynamic>) return null;
      current = current[segment];
    }
    return current is Map<String, dynamic> ? current : null;
  }
}
