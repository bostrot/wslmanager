// What the AI assistant changed on the user's machine during one chat turn,
// filed as a snippet once the turn ends. One chat session keeps one
// snippet: the first turn that changes something creates it, and every later
// turn of the same conversation appends its own section to it ([appendTo]).
//
// The transcript only says "ran vm_create_linux" — no arguments, no output
// — and it is one long scroll that is gone after "Clear chat". A run that
// created or changed an instance deserves a record the user can read
// afterwards, run again against a fresh instance, and share like any other
// snippet (ai-tasks#77). The snippet body is a bash script: the shell
// commands the assistant ran are kept as they were, everything else it did
// is a comment above them, so Run on the Snippets screen replays the shell
// part and the comments say what the rest was.
//
// Which tools count, and which of their arguments name the instance or hold
// the command, is declared on each tool ([McpTool.recording]) — not here.

import 'dart:convert';

import 'package:wsl2distromanager/api/mcp/mcp_server.dart';
import 'package:wsl2distromanager/api/quick_actions.dart';

/// One tool call that created or changed an instance.
class RecordedToolCall {
  RecordedToolCall({
    required this.tool,
    required this.recording,
    required this.arguments,
    required this.result,
  });

  final String tool;
  final ToolRecording recording;
  final Map<String, dynamic> arguments;

  /// What the tool returned — its output, or the error text the model was
  /// handed — already cut to what the record keeps. A failed step is part
  /// of the record too.
  final String result;

  String? _stringArg(String? key) {
    if (key == null) return null;
    final value = arguments[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  /// The instance this call touched, when the tool names one.
  String? get target => _stringArg(recording.target);

  /// The shell command that ran inside the instance, for tools that take one.
  String? get shellCommand => _stringArg(recording.shell);

  bool get supporting => recording.supporting;
}

class AiRunRecorder {
  AiRunRecorder({required this.request, DateTime? startedAt})
      : startedAt = startedAt ?? DateTime.now();

  /// The user message that started the run — the snippet's description.
  final String request;
  final DateTime startedAt;

  final List<RecordedToolCall> calls = [];

  /// How much of a tool's output the record keeps per call. Enough to see
  /// whether a step worked, not the whole `apt-get` log.
  static const int maxResultLines = 6;
  static const int maxResultChars = 400;

  /// The description field of a snippet is one line in the list.
  static const int maxDescriptionChars = 120;

  /// True until a call that changes something on its own has been recorded;
  /// a run made only of supporting calls (a VM start) files nothing.
  bool get isEmpty => !calls.any((c) => !c.supporting);

  /// Records the call when [tool] declares a recording; anything else is
  /// ignored, so the agent loop can hand over every call it makes.
  void record(McpTool tool, Map<String, dynamic> arguments, String result) {
    final recording = tool.recording;
    if (recording == null) return;
    calls.add(RecordedToolCall(
      tool: tool.name,
      recording: recording,
      arguments: arguments,
      result: _cutResult(result),
    ));
  }

  /// Instances touched, in first-seen order.
  List<String> get targets {
    final seen = <String>[];
    for (final call in calls) {
      final t = call.target;
      if (t != null && !seen.contains(t)) seen.add(t);
    }
    return seen;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// `2026-09-14 10:07`, local time — what the user's clock showed.
  String get _stamp => '${startedAt.year}-${_two(startedAt.month)}-'
      '${_two(startedAt.day)} ${_two(startedAt.hour)}:${_two(startedAt.minute)}';

  /// The snippet editor accepts only `[a-zA-Z0-9._-]` in a name, since the
  /// name doubles as a folder name when a snippet is shared. Runs of other
  /// characters become one dash, and none is left at either end.
  static String _nameSafe(String text) => text
      .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// `ai-run-<instance>-<date>-<time>`; the instance is left out when no
  /// call named one. Unique among [existingNames]: a second run against the
  /// same instance within the minute gets a `-2` rather than overwriting the
  /// first, since [QuickAction.addToPrefs] updates by name.
  String snippetName({Iterable<String> existingNames = const []}) {
    final t = targets;
    final base = _nameSafe([
      'ai-run',
      if (t.isNotEmpty) t.first,
      _stamp.replaceAll(':', ''),
    ].join('-'));
    final taken = existingNames.toSet();
    var name = base;
    for (var n = 2; taken.contains(name); n++) {
      name = '$base-$n';
    }
    return name;
  }

  /// The request on one line, cut to fit the list.
  String get description {
    final oneLine = request.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= maxDescriptionChars) return oneLine;
    return '${oneLine.substring(0, maxDescriptionChars - 1)}…';
  }

  static String _cutResult(String result) {
    final full = result.trim();
    var text = full.split('\n').take(maxResultLines).join('\n');
    if (text.length > maxResultChars) text = text.substring(0, maxResultChars);
    return text.length < full.length ? '$text…' : text;
  }

  /// [text] as comment lines, with `$`, backticks and backslashes escaped.
  ///
  /// The comments carry tool output and the user's own words, which nothing
  /// vetted. WSLApi.runCmds writes a snippet into the distro line by line
  /// through `echo "…"`, and inside double quotes the shell still expands
  /// `$(…)`, `$VAR` and backticks — as root, before the script even runs,
  /// comment or not. Escaped, that writer puts the original text into the
  /// file; the macOS runner sends the script base64-encoded and keeps the
  /// backslashes, which is harmless in a comment.
  static String _comment(String text, {String indent = ''}) => text
      .split('\n')
      .map((line) => line.isEmpty
          ? '#'
          : '# $indent${line.replaceAllMapped(RegExp(r'[\\$`]'), (m) => '\\${m[0]}')}')
      .join('\n');

  /// `key="value" key2=3` for everything but the shell command itself, which
  /// [toScript] prints as script lines.
  static String _renderArguments(RecordedToolCall call) {
    final parts = <String>[];
    call.arguments.forEach((key, value) {
      if (key == call.recording.shell) return;
      parts.add('$key=${jsonEncode(value)}');
    });
    return parts.join(' ');
  }

  static String _singleQuoted(String text) =>
      "'${text.replaceAll("'", r"'\''")}'";

  /// The command as the snippet runs it. A snippet runs as root in the
  /// login directory, so a call that named a `cwd` or a `user` is wrapped to
  /// run the same way it did — replaying `npm install` as root in `/root`
  /// is not the run the record claims to repeat.
  static String _shellLines(RecordedToolCall call, String command) {
    var body = command.trim();
    final cwd = call._stringArg('cwd');
    if (cwd != null) body = 'cd ${_singleQuoted(cwd)} && {\n$body\n}';
    final user = call._stringArg('user');
    if (user != null && user != 'root') {
      body = 'su -s /bin/sh ${_singleQuoted(user)} -c ${_singleQuoted(body)}';
    }
    return body;
  }

  /// The snippet body.
  String toScript() {
    final b = StringBuffer();
    b.writeln('#!/bin/bash');
    b.writeln('# Recorded by the AI assistant in WSL Manager on $_stamp.');
    b.writeln(_comment('Request: ${request.trim()}'));
    final t = targets;
    if (t.isNotEmpty) b.writeln(_comment('Instances: ${t.join(', ')}'));
    b.writeln('#');
    b.writeln('# The shell commands the assistant ran are kept as they were; '
        'everything');
    b.writeln('# else it did is noted as a comment above, with what the tool '
        'reported');
    b.writeln('# below. Run this against a fresh instance to repeat the '
        'shell part.');
    _writeCalls(b);
    return b.toString();
  }

  /// This turn as a section appended to the session's snippet: its own
  /// request and instances, then its calls numbered from 1. The section
  /// carries its instances because the snippet's single `distro` field
  /// cannot say which step ran where once a session touched several.
  String toFollowUpSection() {
    final b = StringBuffer();
    b.writeln('# --- Follow-up on $_stamp ---');
    b.writeln(_comment('Request: ${request.trim()}'));
    final t = targets;
    if (t.isNotEmpty) b.writeln(_comment('Instances: ${t.join(', ')}'));
    _writeCalls(b);
    return b.toString();
  }

  void _writeCalls(StringBuffer b) {
    for (var i = 0; i < calls.length; i++) {
      final call = calls[i];
      b.writeln();
      final args = _renderArguments(call);
      b.writeln(
          _comment('${i + 1}. ${call.tool}${args.isEmpty ? '' : ' $args'}'));
      final command = call.shellCommand;
      if (command != null) b.writeln(_shellLines(call, command));
      if (call.result.isNotEmpty) {
        b.writeln(_comment(call.result, indent: '   '));
      }
    }
  }

  /// [existing] — the snippet an earlier turn of this chat filed — with this
  /// turn appended. Name and description stay those of the first turn; the
  /// content keeps whatever is there (edits made in the editor included) and
  /// gains a section at the end; the instances are the union, first-seen
  /// order, so the snippet still lists every instance the session touched.
  QuickActionItem appendTo(QuickActionItem existing) {
    final instances = <String>[];
    void add(Object? value) {
      if (value is String && value.trim().isNotEmpty) {
        if (!instances.contains(value.trim())) instances.add(value.trim());
      } else if (value is Iterable) {
        value.forEach(add);
      }
    }

    add(existing.distro);
    add(targets);
    return QuickActionItem(
      name: existing.name,
      description: existing.description,
      version: existing.version,
      author: existing.author,
      license: existing.license,
      git: existing.git,
      distro: instances.isEmpty
          ? ''
          : (instances.length == 1 ? instances.single : instances),
      env: existing.env,
      content: '${existing.content.trimRight()}\n\n${toFollowUpSection()}',
    );
  }

  /// The snippet as it would be saved; [existingNames] keeps the name unique.
  QuickActionItem toSnippet({Iterable<String> existingNames = const []}) {
    final t = targets;
    // A string for the usual single instance, the way hand-written snippets
    // carry it; a list only when the run touched several.
    final dynamic distro = t.isEmpty ? '' : (t.length == 1 ? t.single : t);
    return QuickActionItem(
      name: snippetName(existingNames: existingNames),
      description: description,
      version: '1.0.0',
      distro: distro,
      content: toScript(),
    );
  }

  /// Files the record on the Snippets screen and returns it, or null when
  /// nothing worth recording ran. With [sessionSnippet] — the name of the
  /// snippet an earlier turn of the same chat filed — the turn is appended
  /// to that snippet instead, unless it has been deleted since.
  QuickActionItem? save({String? sessionSnippet}) {
    if (isEmpty) return null;
    final existing =
        sessionSnippet == null ? null : QuickAction().byName(sessionSnippet);
    final item = existing != null
        ? appendTo(existing)
        : toSnippet(existingNames: QuickAction().names());
    QuickAction.addToPrefs(item);
    return item;
  }
}
