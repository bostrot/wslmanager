// The section-aware, comment-preserving config model shared by WSL's two
// configuration files.
//
// ## Why this file exists
//
// `/etc/wsl.conf` and `%UserProfile%\.wslconfig` are the same INI-*like*
// format, and the app had two separate parsers for them — one correct
// (`WslConfFile`, written for P05-03) and one that was section-blind,
// case-sensitive, comment-blind and could not remove a key at all
// (`WSLApi.readConfig` / `setConfig`, the subject of P05-02). Rather than
// write the correct one a second time, the correct one moved here and both
// files now describe themselves with an [IniSchema].
//
// The two dialects differ in exactly four ways, all captured by the schema:
//
// * **Comment characters.** `wsl.conf` accepts `#` and `;`; `.wslconfig`
//   accepts only `#` and rejects `;` outright with
//   `wsl: Ungültiger Schlüsselname` (doc/audit/wsl-docs/runtime.md R-7).
// * **Value encoding.** `.wslconfig` `path` values need **escaped**
//   backslashes — a single `\` is `wsl: Ungültiges Escapezeichen` and the
//   line is discarded (R-6). `wsl.conf` values are taken verbatim.
// * **Line endings.** `wsl.conf` lives inside the distro and is written LF;
//   `.wslconfig` is a Windows file whose existing convention is preserved.
// * **The key tables**, which drive case-insensitive canonicalisation.
//
// Everything else — comments, blank lines, key order, unknown keys and the
// sections they sit in — survives the round trip unchanged. Both files are
// hand-edited by users, and a settings screen that reformats one on every
// Save is its own bug report.

/// A key spelling this model is willing to own.
///
/// Anything else on a line — `#memory`, `;memory`, a stray fragment — stays an
/// opaque raw line. That is what keeps a commented-out key from absorbing a
/// write, which is how the old `.wslconfig` writer's unanchored regex turned a
/// Save into a silent no-op (audit CC-5 / coverage-sweep S-3).
final RegExp _keyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_.\-]*$');

/// How one config dialect spells itself.
class IniSchema {
  /// The documented keys of each section, in their canonical spelling.
  ///
  /// Used to normalise spelling on read: both parsers are case-insensitive, so
  /// a hand-written `mountfstab = true` or `swapfile = …` is a valid spelling
  /// of `mountFsTab` / `swapFile`, but the widgets read their state under the
  /// spelling they use. Without this table such a file populates a key nothing
  /// renders (audit V-5, V-7).
  final Map<String, List<String>> keys;

  /// Line prefixes that make a line a comment.
  final List<String> commentPrefixes;

  /// Newline written back when the source does not say. `wsl.conf` is a Linux
  /// file, `.wslconfig` a Windows one.
  final String defaultNewline;

  /// Whether the source's own newline wins over [defaultNewline].
  final bool preserveNewline;

  /// Value as it should appear in the file. Identity where the dialect has no
  /// escaping.
  final String Function(String section, String key, String value)? encodeValue;

  /// Inverse of [encodeValue], applied on read.
  final String Function(String section, String key, String value)? decodeValue;

  const IniSchema({
    required this.keys,
    this.commentPrefixes = const <String>['#', ';'],
    this.defaultNewline = '\n',
    this.preserveNewline = false,
    this.encodeValue,
    this.decodeValue,
  });

  /// [section] in its documented spelling, or as written when it is not a
  /// section this app knows.
  String canonicalSection(String section) {
    final lower = section.trim().toLowerCase();
    for (final known in keys.keys) {
      if (known.toLowerCase() == lower) return known;
    }
    return section.trim();
  }

  /// [key] in its documented spelling within [section], or as written when the
  /// section or the key is unknown.
  String canonicalKey(String section, String key) {
    final lower = key.trim().toLowerCase();
    for (final known in keys[canonicalSection(section)] ?? const <String>[]) {
      if (known.toLowerCase() == lower) return known;
    }
    return key.trim();
  }

  /// The section [key] is documented under, or null when no section claims it.
  ///
  /// Only meaningful for a dialect whose key names are unique across sections.
  /// `.wslconfig` is such a dialect and depends on this to put a key back where
  /// WSL will read it: all seven `[experimental]` keys are **rejected** under
  /// `[wsl2]` and the setting silently stays off (audit R-4).
  String? documentedSection(String key) {
    final lower = key.trim().toLowerCase();
    for (final entry in keys.entries) {
      for (final known in entry.value) {
        if (known.toLowerCase() == lower) return entry.key;
      }
    }
    return null;
  }
}

enum _LineKind { raw, section, entry }

class _ConfigLine {
  _LineKind kind;

  /// Verbatim source text. Rewritten only for an entry this app changes, so
  /// every untouched line comes back out byte for byte.
  String text;

  /// Canonical name of the section this line sits in. Empty for the preamble.
  String section;

  /// Key spelling *as written in the file*, kept so an update edits the user's
  /// line rather than replacing it with a differently-spelled one.
  String key;

  /// Value as written, before [IniSchema.decodeValue].
  String rawValue;

  _ConfigLine(this.kind, this.text,
      {this.section = '', this.key = '', this.rawValue = ''});
}

/// A parsed INI-like config file.
///
/// Section and key matching is case-insensitive throughout, matching both WSL
/// parsers. Values are held decoded — what the user typed — and encoded once,
/// on the way out.
class IniConfigFile {
  final IniSchema schema;
  final List<_ConfigLine> _lines;
  final bool _trailingNewline;
  final String _newline;

  IniConfigFile._(
      this.schema, this._lines, this._trailingNewline, this._newline);

  /// Parse [text] under [schema]. An empty string is an empty config, which is
  /// what a machine with no `.wslconfig` and a distro with no `/etc/wsl.conf`
  /// both read as.
  IniConfigFile.parse(String text, IniSchema schema)
      : this._(schema, _parseLines(text, schema), _hasTrailingNewline(text),
            _detectNewline(text, schema));

  static bool _hasTrailingNewline(String text) =>
      text.isEmpty || text.endsWith('\n');

  static String _detectNewline(String text, IniSchema schema) {
    if (!schema.preserveNewline) return schema.defaultNewline;
    if (text.contains('\r\n')) return '\r\n';
    if (text.contains('\n')) return '\n';
    return schema.defaultNewline;
  }

  static List<_ConfigLine> _parseLines(String text, IniSchema schema) {
    if (text.isEmpty) return <_ConfigLine>[];

    final source = text.endsWith('\n')
        ? text.substring(0, text.length - 1).split('\n')
        : text.split('\n');

    final lines = <_ConfigLine>[];
    var currentSection = '';

    for (final rawLine in source) {
      // A file authored on Windows and copied into a distro keeps its CR.
      // Drop it on read; [serialize] puts the dialect's own ending back.
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final trimmed = line.trim();

      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        currentSection =
            schema.canonicalSection(trimmed.substring(1, trimmed.length - 1));
        lines
            .add(_ConfigLine(_LineKind.section, line, section: currentSection));
        continue;
      }

      // A comment or a blank line is opaque: never matched, never rewritten,
      // always preserved in place.
      final isComment =
          schema.commentPrefixes.any((prefix) => trimmed.startsWith(prefix));
      // A key outside any section is ignored by both parsers, so it is opaque
      // too — treating it as an entry would let a dialog edit a line that has
      // no effect.
      if (isComment || currentSection.isEmpty || !trimmed.contains('=')) {
        lines.add(_ConfigLine(_LineKind.raw, line, section: currentSection));
        continue;
      }

      final separator = trimmed.indexOf('=');
      final key = trimmed.substring(0, separator).trim();
      final value = trimmed.substring(separator + 1).trim();
      if (!_keyPattern.hasMatch(key)) {
        lines.add(_ConfigLine(_LineKind.raw, line, section: currentSection));
        continue;
      }

      lines.add(_ConfigLine(_LineKind.entry, line,
          section: currentSection, key: key, rawValue: value));
    }

    return lines;
  }

  bool _matches(_ConfigLine line, String section, String key) =>
      line.kind == _LineKind.entry &&
      line.section.toLowerCase() == section.toLowerCase() &&
      line.key.toLowerCase() == key.toLowerCase();

  String _decode(_ConfigLine line) {
    final decode = schema.decodeValue;
    if (decode == null) return line.rawValue;
    return decode(line.section, schema.canonicalKey(line.section, line.key),
        line.rawValue);
  }

  String _encode(String section, String key, String value) {
    final encode = schema.encodeValue;
    if (encode == null) return value;
    return encode(section, schema.canonicalKey(section, key), value);
  }

  /// The value of `[section] key`, or null when the key is not in the file.
  ///
  /// "Absent" and "empty" are different answers: a documented default only
  /// applies to the first.
  String? get(String section, String key) {
    final s = schema.canonicalSection(section);
    final k = schema.canonicalKey(s, key);
    for (final line in _lines) {
      if (_matches(line, s, k)) return _decode(line);
    }
    return null;
  }

  /// True when `[section] key` has a line in the file, whatever its value.
  bool contains(String section, String key) => get(section, key) != null;

  /// The canonical section `key` currently sits in, or null when it is not in
  /// the file. Checked before [IniSchema.documentedSection] so a key a user put
  /// somewhere unexpected is edited where it is rather than duplicated.
  String? sectionOf(String key) {
    final lower = key.trim().toLowerCase();
    for (final line in _lines) {
      if (line.kind != _LineKind.entry || line.section.isEmpty) continue;
      // Either spelling counts: the one in the file, or the documented one the
      // file's spelling normalises to.
      if (line.key.toLowerCase() == lower ||
          schema.canonicalKey(line.section, line.key).toLowerCase() == lower) {
        return line.section;
      }
    }
    return null;
  }

  /// Every key in the file, by canonical section and canonical key.
  ///
  /// A section that is present but empty appears with an empty map.
  Map<String, Map<String, String>> toMap() {
    final config = <String, Map<String, String>>{};
    for (final line in _lines) {
      if (line.kind == _LineKind.section) {
        config.putIfAbsent(line.section, () => <String, String>{});
      } else if (line.kind == _LineKind.entry) {
        config.putIfAbsent(line.section, () => <String, String>{})[
            schema.canonicalKey(line.section, line.key)] = _decode(line);
      }
    }
    return config;
  }

  /// Set `[section] key` to [value], creating the section if it is missing.
  ///
  /// An existing key keeps the spelling it has in the file; only its value
  /// changes. That matters more than tidiness: WSL resolves a duplicate key to
  /// its **first** occurrence, so an appended camelCase line next to an
  /// existing lower-case one is a line that never wins (audit R-8).
  ///
  /// A new key is written in its documented spelling, after the last key of its
  /// section rather than at the end of the file.
  void set(String section, String key, String value) {
    final s = schema.canonicalSection(section);
    final k = schema.canonicalKey(s, key);
    final encoded = _encode(s, k, value);

    for (final line in _lines) {
      if (_matches(line, s, k)) {
        line.rawValue = encoded;
        line.text = '${line.key} = $encoded';
        return;
      }
    }

    // Append after the section's last meaningful line rather than at the end
    // of the file: a key that lands under the *next* header is a key WSL reads
    // as belonging to another section.
    var header = -1;
    var anchor = -1;
    for (var i = 0; i < _lines.length; i++) {
      final line = _lines[i];
      if (line.section.toLowerCase() != s.toLowerCase()) continue;
      if (line.kind == _LineKind.section) header = i;
      if (line.kind == _LineKind.entry || line.text.trim().isNotEmpty) {
        anchor = i;
      }
    }

    final entry = _ConfigLine(_LineKind.entry, '$k = $encoded',
        section: s, key: k, rawValue: encoded);

    if (header < 0) {
      if (_lines.isNotEmpty && _lines.last.text.trim().isNotEmpty) {
        _lines.add(_ConfigLine(_LineKind.raw, '', section: s));
      }
      _lines.add(_ConfigLine(_LineKind.section, '[$s]', section: s));
      _lines.add(entry);
      return;
    }

    _lines.insert((anchor > header ? anchor : header) + 1, entry);
  }

  /// Remove `[section] key` from the file. Returns whether a line went away.
  ///
  /// This is the third state the tri-state toggles need: returning a key to
  /// *unset* has to delete its line, not write a default back, or the
  /// documented default can never take over again (audit CC-11, and the reason
  /// P05-04 could not ship before P05-02).
  bool remove(String section, String key) {
    final s = schema.canonicalSection(section);
    final k = schema.canonicalKey(s, key);
    final before = _lines.length;
    _lines.removeWhere((line) => _matches(line, s, k));
    return _lines.length != before;
  }

  /// The whole file as it should be written back.
  String serialize() {
    if (_lines.isEmpty) return '';
    final body = _lines.map((line) => line.text).join(_newline);
    return _trailingNewline ? '$body$_newline' : body;
  }
}
