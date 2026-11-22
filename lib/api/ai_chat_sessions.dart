// Previous conversations with the app assistant.
//
// The chat used to have exactly one transcript: whatever had been said since
// the last "clear", with clearing the only way to start from a clean context
// — and it threw the old conversation away (ai-tasks#104). A new chat files
// the running one here instead, so an earlier thread can be picked up again.
//
// Sandbox chats are not part of this: each of those is already a separate,
// per-distro conversation with its own store in [SandboxChat].

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wsl2distromanager/api/ai_service.dart';
import 'package:wsl2distromanager/components/helpers.dart';

/// One archived conversation.
class AiChatSession {
  const AiChatSession({
    required this.id,
    required this.messages,
    required this.updatedAt,
  });

  final String id;
  final List<AiMessage> messages;

  /// When the chat was last filed away — the history list is ordered by it.
  final DateTime updatedAt;

  /// How long a [title] may get before it is cut short.
  static const int maxTitleLength = 48;

  /// What the history list calls this chat: the first thing the user asked,
  /// folded onto one line. Empty when the chat holds no question at all — a
  /// run that only produced tool notes — and the panel labels those instead
  /// of showing a blank row.
  String get title {
    for (final message in messages) {
      if (message.role != 'user') continue;
      final line = message.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      return line.length <= maxTitleLength
          ? line
          : '${line.substring(0, maxTitleLength)}…';
    }
    return '';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory AiChatSession.fromJson(Map<String, dynamic> json) => AiChatSession(
        id: json['id'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        messages: (json['messages'] as List)
            .map((e) => AiMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// The store behind "New chat" and "Previous chats".
///
/// Prefs-backed like the live transcript itself, so the history survives a
/// restart. Notifies so the panel's flyout and the header repaint when a
/// chat is filed or reopened.
class AiChatSessions extends ChangeNotifier {
  AiChatSessions._();

  static final AiChatSessions instance = AiChatSessions._();

  static const String prefsKey = 'AiChatSessions';

  /// Which stored chat the live transcript came from, if any. Filing it
  /// again updates that entry rather than adding a second copy of the same
  /// thread.
  static const String currentPrefsKey = 'AiChatCurrentSession';

  /// The history is a convenience, not an archive: the oldest chats beyond
  /// this drop out rather than growing prefs without a bound.
  static const int maxSessions = 20;

  /// The clock the ids and timestamps are taken from, so a test can hold it
  /// still and file two chats inside one tick.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Distinguishes chats filed inside the same clock tick. `DateTime.now()`
  /// resolves to about 15ms on Windows, so two archives in quick succession
  /// can share a microsecondsSinceEpoch — and an id collision means the
  /// second chat replaces the first instead of joining it.
  static int _idSequence = 0;

  /// The blob [_decoded] was parsed from, so a repaint that changed nothing
  /// does not decode it again. The panel's header asks whether there is any
  /// history on every build — which, while a reply streams in, is every
  /// frame, and parsing twenty transcripts per frame is not free.
  String? _decodedFrom;
  List<AiChatSession>? _decoded;

  /// Newest first. A stored blob that cannot be read is treated as no
  /// history at all, exactly like the live transcript's own loader.
  ///
  /// The caller gets its own list: [archive] and [switchTo] rearrange what
  /// they are handed, and that must not reach into the cache.
  List<AiChatSession> list() {
    final stored = prefs.getString(prefsKey);
    if (stored == null || stored.isEmpty) return <AiChatSession>[];
    if (stored != _decodedFrom || _decoded == null) {
      _decodedFrom = stored;
      try {
        _decoded = (json.decode(stored) as List)
            .map((e) => AiChatSession.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _decoded = <AiChatSession>[];
      }
    }
    return List.of(_decoded!);
  }

  /// The id of the stored chat currently on screen, or null when the live
  /// transcript has never been filed.
  String? get currentId => prefs.getString(currentPrefsKey);

  /// Files [live] away and leaves nothing marked as current — what "New
  /// chat" does before the transcript is cleared. An empty transcript has
  /// nothing worth keeping, so it is dropped rather than filed.
  void archive(List<AiMessage> live) {
    final all = list();
    if (live.isNotEmpty) _fileInto(all, live);
    _save(all);
    _setCurrent(null);
    notifyListeners();
  }

  /// Swaps the chat on screen for the stored one: [live] is filed away, the
  /// chat under [id] is taken out of the history and returned so the caller
  /// can put it back on screen. Null when [id] is no longer there.
  ///
  /// One step rather than an archive followed by a read, so a full history
  /// cannot drop the very chat that is being opened.
  List<AiMessage>? switchTo(String id, List<AiMessage> live) {
    final all = list();
    final index = all.indexWhere((session) => session.id == id);
    if (index == -1) return null;
    final target = all.removeAt(index);
    if (live.isNotEmpty) _fileInto(all, live);
    _save(all);
    _setCurrent(target.id);
    notifyListeners();
    return target.messages;
  }

  /// Drops one stored chat.
  void remove(String id) {
    final all = list()..removeWhere((session) => session.id == id);
    _save(all);
    notifyListeners();
  }

  /// Forgets every stored chat. The live transcript is [AiService]'s to
  /// clear, and is left alone here.
  void clear() {
    prefs.remove(prefsKey);
    _setCurrent(null);
    notifyListeners();
  }

  /// Puts [live] at the top of [all] under the current id, replacing the
  /// entry it was opened from, and trims the tail past [maxSessions].
  void _fileInto(List<AiChatSession> all, List<AiMessage> live) {
    final id = currentId ??
        '${now().microsecondsSinceEpoch}-${_idSequence++}';
    all
      ..removeWhere((session) => session.id == id)
      ..insert(
        0,
        AiChatSession(
          id: id,
          messages: List.of(live),
          updatedAt: now(),
        ),
      );
    if (all.length > maxSessions) all.removeRange(maxSessions, all.length);
  }

  void _save(List<AiChatSession> all) {
    if (all.isEmpty) {
      prefs.remove(prefsKey);
      return;
    }
    prefs.setString(
        prefsKey, json.encode(all.map((s) => s.toJson()).toList()));
  }

  void _setCurrent(String? id) {
    if (id == null) {
      prefs.remove(currentPrefsKey);
    } else {
      prefs.setString(currentPrefsKey, id);
    }
  }
}
