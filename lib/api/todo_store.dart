// A small task queue the AI chat can work through: the user adds todos (and
// checks them off) in the chat panel, and the assistant is given tools to
// read the list and mark items done as it completes them, so it can be told
// "work on these" and keep going until the queue is empty.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wsl2distromanager/components/helpers.dart';

class TodoItem {
  TodoItem({required this.id, required this.text, this.done = false});
  final int id;
  String text;
  bool done;

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'done': done};
  factory TodoItem.fromJson(Map<String, dynamic> j) => TodoItem(
        id: j['id'] as int,
        text: j['text'] as String,
        done: j['done'] as bool? ?? false,
      );
}

class TodoStore extends ChangeNotifier {
  TodoStore._();
  static final TodoStore instance = TodoStore._();

  final List<TodoItem> _items = [];
  int _nextId = 1;
  bool _loaded = false;

  List<TodoItem> get items => List.unmodifiable(_items);
  bool get hasOpen => _items.any((t) => !t.done);
  int get openCount => _items.where((t) => !t.done).length;

  void _load() {
    if (_loaded) return;
    _loaded = true;
    final stored = prefs.getString('AiTodos');
    if (stored != null && stored.isNotEmpty) {
      try {
        final list = jsonDecode(stored) as List;
        _items
          ..clear()
          ..addAll(list.map((e) => TodoItem.fromJson(e as Map<String, dynamic>)));
        _nextId = _items.fold<int>(0, (m, t) => t.id > m ? t.id : m) + 1;
      } catch (_) {}
    }
  }

  void _persist() {
    prefs.setString(
        'AiTodos', jsonEncode(_items.map((e) => e.toJson()).toList()));
  }

  TodoItem add(String text) {
    _load();
    final item = TodoItem(id: _nextId++, text: text.trim());
    _items.add(item);
    _persist();
    notifyListeners();
    return item;
  }

  bool setDone(int id, bool done) {
    _load();
    for (final t in _items) {
      if (t.id == id) {
        t.done = done;
        _persist();
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  bool remove(int id) {
    _load();
    final before = _items.length;
    _items.removeWhere((t) => t.id == id);
    if (_items.length != before) {
      _persist();
      notifyListeners();
      return true;
    }
    return false;
  }

  void clearCompleted() {
    _load();
    _items.removeWhere((t) => t.done);
    _persist();
    notifyListeners();
  }

  void clearAll() {
    _load();
    _items.clear();
    _persist();
    notifyListeners();
  }

  /// A compact rendering for a tool result: `#id [x] text`.
  String render() {
    _load();
    if (_items.isEmpty) return 'The task list is empty.';
    return _items
        .map((t) => '#${t.id} [${t.done ? "x" : " "}] ${t.text}')
        .join('\n');
  }
}
